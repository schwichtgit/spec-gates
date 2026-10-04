#!/bin/bash
set -euo pipefail

# Spec-conformance gate tests (feature 002): parser, executor, enforcement.
#
# Regression guards for the spec's success criteria:
#   SC-001 -- a Complete feature with a failing accept block blocks the run,
#             naming the feature and criterion;
#   SC-002 -- a Complete feature with an unchecked task blocks the run,
#             naming the task;
# plus fail-closed parsing (FR-005), timeout (R4), mutation detection (R5),
# --accept informational execution, include/exclude policy filtering, and
# the GATES_SPEC_EXEC recursion guard.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-spec-test)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

expect() { # <name> <actual> <wanted>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (got $2, want $3)"
        FAIL=$((FAIL + 1))
    fi
}

expect_contains() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (output does not contain: $3)"
        FAIL=$((FAIL + 1))
    fi
}

# Project the runtime into <dir> with a caller-supplied policy body. Minimal
# policies enable no linters, so the spec gate is the only live gate. The
# fixture is a git work tree: outside one, blocks fail closed (#136).
project() { # <dir> <policy-json>
    local dir="$1" policy="$2"
    mkdir -p "$dir/.specify/gates/lib"
    git init -q "$dir" >/dev/null 2>&1
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
}

MINIMAL='{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }'

# Write a fixture feature: spec.md with the given Status, tasks.md verbatim.
mkfeature() { # <dir> <name> <status>   (tasks.md body on stdin)
    local dir="$1" name="$2" status="$3"
    mkdir -p "$dir/specs/$name"
    printf '# Feature Specification: %s\n\n**Status**: %s\n' "$name" "$status" \
        >"$dir/specs/$name/spec.md"
    cat >"$dir/specs/$name/tasks.md"
}

# Run the projected gate. GATES_SPEC_EXEC is cleared so this suite still
# tests the spec gate when it is itself invoked from inside an accept block
# (the dogfood case).
gate() { # <dir> [flag...]
    local dir="$1"
    shift
    local rc=0
    CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC \
        bash "$dir/.specify/gates/verify.sh" --boundary ci "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

gate_out() { # <dir> [flag...]: stdout+stderr, exit code appended as last line
    local dir="$1"
    shift
    local rc=0 out
    out="$(CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC \
        bash "$dir/.specify/gates/verify.sh" --boundary ci "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

gate_json() { # <dir> [flag...]: --json stdout only
    local dir="$1"
    shift
    CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC \
        bash "$dir/.specify/gates/verify.sh" --boundary ci --json "$@" 2>/dev/null || true
}

# --- parse: blocks discovered, fences and fenced checkboxes ignored ---
echo "=== parser: discovery, fence-awareness ==="

D="$WORKDIR/parse"
project "$D" "$MINIMAL"
mkfeature "$D" 100-parse Draft <<'EOF'
# Tasks

- [x] T001 First task

  ```accept
  # verifies: SC-001
  true
  echo done
  ```

- [ ] T002 Second task with a code sample

  ```bash
  - [ ] this checkbox is inside a fence and must not count
  false
  ```

- [x] T003 Third task

  ```accept
  true
  ```
EOF
expect "fixture with 2 accept blocks passes (informational)" "$(gate "$D")" 0
J="$(gate_json "$D")"
expect "2 blocks parsed" "$(printf '%s' "$J" | jq -r '.attestation.spec.parsed')" 2
expect "3 tasks counted (fenced checkbox ignored)" \
    "$(printf '%s' "$J" | jq -r '.attestation.spec.results[0].tasks_total')" 3
expect "1 task unchecked" \
    "$(printf '%s' "$J" | jq -r '.attestation.spec.results[0].tasks_unchecked')" 1
expect "spec gate entry present in gates[]" \
    "$(printf '%s' "$J" | jq -r '[.gates[] | select(.name == "spec")] | length')" 1

# --- parse: 4-backtick fences (prettier normalization of embedded ```) ---
echo ""
echo "=== parser: fence length (CommonMark / prettier) ==="

D="$WORKDIR/longfence"
project "$D" "$MINIMAL"
mkfeature "$D" 100-long Draft <<'EOF'
# Tasks

- [x] T001 Block whose body embeds a three-backtick fence

  ````accept
  # verifies: SC-100
  printf '%s\n' '  ```accept' '  exit 9' '  ```' >/dev/null
  true
  ````

- [ ] T002 A four-backtick code sample containing an accept-looking fence

  ````markdown
  ```accept
  false
  ```
  ````
EOF
expect "long-fence fixture passes (informational)" "$(gate "$D")" 0
J="$(gate_json "$D")"
expect "the ````accept block is parsed, the sample's inner fence is not" \
    "$(printf '%s' "$J" | jq -r '.attestation.spec.parsed')" 1
expect "2 tasks counted (fence interiors excluded)" \
    "$(printf '%s' "$J" | jq -r '.attestation.spec.results[0].tasks_total')" 2

# --- parse errors fail closed (FR-005) ---
echo ""
echo "=== parser: malformed blocks fail closed ==="

D="$WORKDIR/unterminated"
project "$D" "$MINIMAL"
mkfeature "$D" 100-bad Draft <<'EOF'
- [x] T001 Task

  ```accept
  true
EOF
OUT="$(gate_out "$D")"
expect_contains "unterminated fence fails the gate" "$OUT" "EXIT=2"
expect_contains "unterminated fence names file:line" "$OUT" "specs/100-bad/tasks.md:3: unterminated accept fence"

D="$WORKDIR/empty-block"
project "$D" "$MINIMAL"
mkfeature "$D" 100-empty Draft <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-009
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "comment-only block fails the gate" "$OUT" "EXIT=2"
expect_contains "comment-only block error names the shape" "$OUT" "no command lines"

D="$WORKDIR/orphan"
project "$D" "$MINIMAL"
mkfeature "$D" 100-orphan Draft <<'EOF'
Some prose, no task line yet.

```accept
true
```
EOF
OUT="$(gate_out "$D")"
expect_contains "orphan block fails the gate" "$OUT" "EXIT=2"
expect_contains "orphan block error names the shape" "$OUT" "no preceding task line"

# --- executor via --accept: informational, never blocks ---
echo ""
echo "=== --accept: informational execution ==="

D="$WORKDIR/accept"
project "$D" "$MINIMAL"
mkfeature "$D" 100-wip Draft <<'EOF'
- [x] T001 Passing criterion

  ```accept
  # verifies: SC-100
  true
  ```

- [ ] T002 Failing criterion

  ```accept
  # verifies: SC-101
  exit 7
  ```
EOF
expect "normal run: nothing executed, exit 0" "$(gate "$D")" 0
expect "normal run executed count is 0" \
    "$(gate_json "$D" | jq -r '.attestation.spec.executed')" 0
OUT="$(gate_out "$D" --accept 100-wip)"
expect_contains "--accept run stays exit 0" "$OUT" "EXIT=0"
expect_contains "--accept reports the pass" "$OUT" 'SC-100" -- pass'
expect_contains "--accept reports the failure with exit code" "$OUT" "exit 7, informational"
expect "--accept executed both blocks" \
    "$(gate_json "$D" --accept 100-wip | jq -r '.attestation.spec.executed')" 2
OUT="$(gate_out "$D" --accept nonexistent)"
expect_contains "--accept unknown feature exits 1" "$OUT" "EXIT=1"
expect_contains "--accept unknown feature names available" "$OUT" "unknown feature: nonexistent"

# --- no specs/ directory: trivial pass (FR-011) ---
echo ""
echo "=== no specs/: trivial pass ==="

D="$WORKDIR/nospecs"
project "$D" "$MINIMAL"
expect "repo without specs/ passes" "$(gate "$D")" 0
expect "attestation records zero features" \
    "$(gate_json "$D" | jq -r '.attestation.spec.features')" 0

# --- recursion guard ---
echo ""
echo "=== recursion guard ==="

D="$WORKDIR/recursion"
project "$D" "$MINIMAL"
mkfeature "$D" 100-rec Complete <<'EOF'
- [x] T001 Task

  ```accept
  false
  ```
EOF
RC=0
CLAUDE_PROJECT_DIR="$D" GATES_SPEC_EXEC=1 \
    bash "$D/.specify/gates/verify.sh" --boundary ci >/dev/null 2>&1 || RC=$?
expect "GATES_SPEC_EXEC=1 skips the spec gate (failing fixture passes)" "$RC" 0
J="$(CLAUDE_PROJECT_DIR="$D" GATES_SPEC_EXEC=1 \
    bash "$D/.specify/gates/verify.sh" --boundary ci --json 2>/dev/null || true)"
expect "guarded run has no spec gate entry" \
    "$(printf '%s' "$J" | jq -r '[.gates[] | select(.name == "spec")] | length')" 0
expect "guarded run has no attestation spec object" \
    "$(printf '%s' "$J" | jq -r '.attestation | has("spec")')" false

# --- enforcement: SC-001 / SC-002 regressions ---
echo ""
echo "=== enforcement on Complete features ==="

D="$WORKDIR/enforced-pass"
project "$D" "$MINIMAL"
mkfeature "$D" 200-done Complete <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-200
  true
  ```
EOF
expect "Complete + passing block passes" "$(gate "$D")" 0
expect "outcome is enforced-pass" \
    "$(gate_json "$D" | jq -r '.attestation.spec.results[0].outcome')" "enforced-pass"

D="$WORKDIR/enforced-fail"
project "$D" "$MINIMAL"
mkfeature "$D" 200-broken Complete <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-201
  exit 3
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "SC-001: failing block blocks the run" "$OUT" "EXIT=2"
expect_contains "SC-001: failure names the feature" "$OUT" "200-broken"
expect_contains "SC-001: failure names the criterion" "$OUT" "SC-201"
expect_contains "SC-001: failure names the exit code" "$OUT" "exit 3"
expect "outcome is enforced-fail" \
    "$(gate_json "$D" | jq -r '.attestation.spec.results[0].outcome')" "enforced-fail"

D="$WORKDIR/unchecked"
project "$D" "$MINIMAL"
mkfeature "$D" 200-drift Complete <<'EOF'
- [x] T001 Done task

  ```accept
  true
  ```

- [ ] T002 Forgotten task
EOF
OUT="$(gate_out "$D")"
expect_contains "SC-002: unchecked task blocks the run" "$OUT" "EXIT=2"
expect_contains "SC-002: failure names the unchecked task" "$OUT" "T002 Forgotten task"

# Precedence: task drift blocks even with zero accept blocks (analyze I2).
D="$WORKDIR/drift-noblocks"
project "$D" "$MINIMAL"
mkfeature "$D" 200-noblocks Complete <<'EOF'
- [ ] T001 Forgotten task, no accept blocks anywhere
EOF
OUT="$(gate_out "$D")"
expect_contains "unchecked task blocks despite zero blocks" "$OUT" "EXIT=2"

D="$WORKDIR/no-criteria"
project "$D" "$MINIMAL"
mkfeature "$D" 200-empty Complete <<'EOF'
- [x] T001 All done, but nothing executable
EOF
OUT="$(gate_out "$D")"
expect_contains "Complete with zero blocks stays informational" "$OUT" "EXIT=0"
expect "outcome is no-criteria" \
    "$(gate_json "$D" | jq -r '.attestation.spec.results[0].outcome')" "no-criteria"

# --- timeout (R4) and mutation (R5) ---
echo ""
echo "=== timeout and mutation detection ==="

D="$WORKDIR/timeout"
project "$D" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "timeout_s": 1 } }'
mkfeature "$D" 300-slow Complete <<'EOF'
- [x] T001 Hangs, in a child process that outlives a top-level kill

  ```accept
  bash -c 'sleep 2; touch late.txt'
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "hung block blocks the run" "$OUT" "EXIT=2"
expect_contains "timeout is named with the budget" "$OUT" "timeout after 1s"
# Issue #136: the watchdog kills the block's whole process group, so the
# child's late write never lands after verify has returned.
sleep 3
TOTAL=$((TOTAL + 1))
if [[ ! -e "$D/late.txt" ]]; then
    echo "PASS: timed-out block leaves no descendant running"
    PASS=$((PASS + 1))
else
    echo "FAIL: timed-out block's child kept running and wrote late.txt"
    FAIL=$((FAIL + 1))
fi

D="$WORKDIR/mutation"
project "$D" "$MINIMAL"
mkfeature "$D" 300-dirty Complete <<'EOF'
- [x] T001 Mutates the tree

  ```accept
  touch mutated.txt
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "mutating block blocks the run" "$OUT" "EXIT=2"
expect_contains "mutation names the changed path" "$OUT" "mutated.txt"
TOTAL=$((TOTAL + 1))
if [[ -f "$D/mutated.txt" ]]; then
    echo "PASS: mutated file is not auto-reverted"
    PASS=$((PASS + 1))
else
    echo "FAIL: mutated file was removed (FR-006 forbids auto-revert)"
    FAIL=$((FAIL + 1))
fi

# Issue #136: a write to a file that is already dirty or untracked leaves
# the status line unchanged, so the runner compares content, not status.
D="$WORKDIR/mutation-dirty"
project "$D" "$MINIMAL"
printf 'base\n' >"$D/tracked.txt"
git -C "$D" add tracked.txt
git -C "$D" -c user.email=b@test -c user.name=baseline commit -qm base --no-verify
printf 'dirty\n' >>"$D/tracked.txt"
printf 'scratch\n' >"$D/untracked.txt"
mkfeature "$D" 300-reads Complete <<'EOF'
- [x] T001 Reads the dirty files without writing

  ```accept
  grep -q dirty tracked.txt
  grep -q scratch untracked.txt
  ```
EOF
expect "block reading dirty and untracked files passes" "$(gate "$D")" 0
mkfeature "$D" 300-reads Complete <<'EOF'
- [x] T001 Appends to an already-dirty tracked file

  ```accept
  echo more >>tracked.txt
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "write to a dirty tracked file blocks the run" "$OUT" "EXIT=2"
expect_contains "dirty-file mutation names the path" "$OUT" "working tree modified: tracked.txt"
mkfeature "$D" 300-reads Complete <<'EOF'
- [x] T001 Modifies an untracked file

  ```accept
  echo more >>untracked.txt
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "write to an untracked file blocks the run" "$OUT" "EXIT=2"
expect_contains "untracked-file mutation names the path" "$OUT" "working tree modified: untracked.txt"

# Issue #136: outside a git work tree there is no mutation check, so the
# block fails closed instead of running unchecked.
D="$WORKDIR/no-git"
project "$D" "$MINIMAL"
rm -rf "$D/.git"
mkfeature "$D" 300-nogit Complete <<'EOF'
- [x] T001 Would pass

  ```accept
  true
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "block outside a git work tree blocks the run" "$OUT" "EXIT=2"
expect_contains "non-git failure names the cause" "$OUT" "cannot check for mutations: not a git work tree"

# --- policy: severity, include, exclude, enabled ---
echo ""
echo "=== policy knobs ==="

D="$WORKDIR/sev-warning"
project "$D" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "severity": "warning" } }'
mkfeature "$D" 400-warn Complete <<'EOF'
- [x] T001 Task

  ```accept
  false
  ```
EOF
expect "severity warning reports without blocking" "$(gate "$D")" 0
expect "gate entry is warn" \
    "$(gate_json "$D" | jq -r '.gates[] | select(.name == "spec") | .status')" "warn"

D="$WORKDIR/include"
project "$D" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "include": ["900-*"] } }'
mkfeature "$D" 400-outside Complete <<'EOF'
- [x] T001 Task

  ```accept
  false
  ```
EOF
expect "Complete feature outside include stays informational" "$(gate "$D")" 0
expect "outcome is informational" \
    "$(gate_json "$D" | jq -r '.attestation.spec.results[0].outcome')" "informational"

D="$WORKDIR/exclude"
project "$D" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "exclude": ["400-*"] } }'
mkfeature "$D" 400-hidden Complete <<'EOF'
- [ ] T001 Would fail, but the feature is excluded

  ```accept
  false
  ```
EOF
expect "excluded feature is not discovered" "$(gate "$D")" 0
expect "excluded feature absent from attestation" \
    "$(gate_json "$D" | jq -r '.attestation.spec.features')" 0

D="$WORKDIR/disabled"
project "$D" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "enabled": false } }'
mkfeature "$D" 400-off Complete <<'EOF'
- [ ] T001 Would fail, but the gate is disabled

  ```accept
  false
  ```
EOF
expect "disabled spec gate does not run" "$(gate "$D")" 0
expect "disabled gate leaves no attestation spec object" \
    "$(gate_json "$D" | jq -r '.attestation | has("spec")')" false

# --- a git hook's environment never reaches the caller's repo (#173) --------
# git runs hooks with GIT_DIR and GIT_INDEX_FILE set, absolute in a linked
# worktree. An accept block (and the canary suite) that builds a sandbox
# repository must not add, commit or tag in the caller's repository.
echo ""
echo "=== hook environment (#173) ==="
HE="$WORKDIR/hookenv"
project "$HE" "$MINIMAL"
git -C "$HE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: base"
WT="$WORKDIR/hookenv-wt"
git -C "$HE" worktree add -q "$WT" -b feat/x >/dev/null 2>&1
mkdir -p "$WT/.specify/gates/lib"
cp "$REPO_ROOT/extension/runtime/verify.sh" "$WT/.specify/gates/"
cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$WT/.specify/gates/lib/"
printf '%s' "$MINIMAL" >"$WT/.specify/gates/policy.json"
mkfeature "$WT" 001-sandbox Complete <<'MD'
- [x] T001 Build a sandbox repository

  ```accept
  d="$(mktemp -d)" && git init -q "$d" && echo x >"$d/f" && git -C "$d" add -A \
    && git -C "$d" -c user.email=a@b -c user.name=n commit -qm sandbox && git -C "$d" tag v9.9.9 && rm -rf "$d"
  ```
MD
echo staged >"$WT/staged.txt"
git -C "$WT" add staged.txt
GD="$(git -C "$WT" rev-parse --absolute-git-dir)"
BEFORE="$(git -C "$WT" diff --cached --name-only | sort | tr '\n' ' ')"
rc=0
(cd "$WT" && GIT_DIR="$GD" GIT_INDEX_FILE="$GD/index" env -u GATES_SPEC_EXEC \
    bash .specify/gates/verify.sh --boundary git >/dev/null 2>&1) || rc=$?
expect "hook env: the sandbox block passes" "$rc" 0
expect "hook env: no tag in the caller's repository" \
    "$(git -C "$HE" tag -l v9.9.9 | wc -l | tr -d ' ')" 0
expect "hook env: the caller's index is unchanged" \
    "$(git -C "$WT" diff --cached --name-only | sort | tr '\n' ' ')" "$BEFORE"
cp "$REPO_ROOT/extension/runtime/canary.sh" "$WT/.specify/gates/"
(cd "$WT" && GIT_DIR="$GD" GIT_INDEX_FILE="$GD/index" GATES_TEST=1 \
    bash .specify/gates/canary.sh --only contract,spec >/dev/null 2>&1) || true
expect "hook env: the canary sandboxes leave no tag in the caller's repository" \
    "$(git -C "$HE" tag -l | wc -l | tr -d ' ')" 0
expect "hook env: the canary leaves the caller's index unchanged" \
    "$(git -C "$WT" diff --cached --name-only | sort | tr '\n' ' ')" "$BEFORE"

echo ""
echo "$PASS of $TOTAL tests passed"
if [[ "$FAIL" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
