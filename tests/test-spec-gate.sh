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
expect "--accept unknown feature: the list has no stray space (#226)" \
    "$(grep -cE '\(available: [^ )]+( [^ )]+)*\)' <<<"$OUT")" 1
# An unknown name is an argument error, refused before any gate runs
# (#179): under --dry-run too, and before the quality gate.
OUT="$(gate_out "$D" --dry-run --accept nonexistent)"
expect_contains "--dry-run --accept unknown feature exits 1" "$OUT" "EXIT=1"
expect "--json --accept unknown feature answers refused" \
    "$(gate_json "$D" --accept nonexistent | jq -r '.result')" refused
D2="$WORKDIR/acceptgate"
project "$D2" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "touch '"$D2"'/gate-ran" } } }'
mkfeature "$D2" 100-wip "Draft" <<'EOF'
- [ ] T001 something
EOF
OUT="$(gate_out "$D2" --accept nonexistent)"
expect_contains "--accept unknown feature with a quality gate exits 1" "$OUT" "EXIT=1"
expect "--accept unknown feature: the quality gate did not run" \
    "$([[ -e "$D2/gate-ran" ]] && echo ran || echo not-run)" not-run

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
# Issue #164: any caller can set the guard, so the skip is never silent.
expect "guarded run records the spec gate as skipped" \
    "$(printf '%s' "$J" | jq -r '[.gates[] | select(.name == "spec") | .status] | join(",")')" skipped
expect_contains "guarded run names the guard as the reason" \
    "$(printf '%s' "$J" | jq -r '.gates[] | select(.name == "spec") | .detail')" "GATES_SPEC_EXEC is set"
expect "guarded run attests the spec gate as skipped" \
    "$(printf '%s' "$J" | jq -r '[.attestation.gates[] | select(.name == "spec") | .result] | join(",")')" skipped
expect_contains "guarded attestation carries the reason" \
    "$(printf '%s' "$J" | jq -r '.attestation.gates[] | select(.name == "spec") | .reason')" "GATES_SPEC_EXEC is set"
expect "guarded run has no attestation spec object" \
    "$(printf '%s' "$J" | jq -r '.attestation | has("spec")')" false
OUT="$(CLAUDE_PROJECT_DIR="$D" GATES_SPEC_EXEC=1 \
    bash "$D/.specify/gates/verify.sh" --boundary ci 2>&1 || true)"
expect_contains "guarded text output shows the skipped spec gate" "$OUT" "[skipped] spec -- GATES_SPEC_EXEC is set"

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

# --- issue #236: every line of a block counts (errexit + pipefail) ---
echo ""
echo "=== errexit and pipefail (#236) ==="

D="$WORKDIR/errexit"
project "$D" "$MINIMAL"
mkfeature "$D" 210-errexit Complete <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-210
  false
  true
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "#236: a failing first line fails the block" "$OUT" "EXIT=2"
expect_contains "#236: the failure names the criterion" "$OUT" "SC-210"

D="$WORKDIR/pipefail"
project "$D" "$MINIMAL"
mkfeature "$D" 210-pipefail Complete <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-211
  false | cat
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "#236: a failing pipeline stage fails the block" "$OUT" "EXIT=2"
expect_contains "#236: the pipeline failure names the criterion" "$OUT" "SC-211"

D="$WORKDIR/neg-early"
project "$D" "$MINIMAL"
mkfeature "$D" 210-neg Draft <<'EOF'
- [x] T001 Task

  ```accept
  ! grep -q needle README
  true
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "#236: a non-last ! command is a parse error" "$OUT" "EXIT=2"
expect_contains "#236: the error names tasks.md:<line>" "$OUT" \
    "specs/210-neg/tasks.md:4: a ! command other than the last one"
expect_contains "#236: the error names a form that works" "$OUT" '! cmd || exit 1'

D="$WORKDIR/neg-last"
project "$D" "$MINIMAL"
printf 'text\n' >"$D/README"
mkfeature "$D" 210-neglast Complete <<'EOF'
- [x] T001 Task

  ```accept
  test -f README
  ! grep -q needle README
  # a trailing comment is not a command
  ```

- [x] T002 Task

  ```accept
  ! grep -q needle README || exit 1
  ! grep -q needle \
    README
  ```
EOF
expect "#236: a ! command on the last line, or with || exit 1, passes" "$(gate "$D")" 0

# #237: heredoc body and terminator lines are not commands after the `!`.
D="$WORKDIR/neg-heredoc"
project "$D" "$MINIMAL"
mkfeature "$D" 210-neghd Complete <<'EOF'
- [x] T001 Task

  ```accept
  ! grep -q needle <<END
  text
  true
  END
  ```

- [x] T002 Task

  ```accept
  ! grep -q needle <<'END'
  $(false)
  END
  ```

- [x] T003 Task

  ```accept
  cat >/dev/null <<A <<-"B"
  ! x
  A
	! y
	B
  ! grep -q needle <<-END
	text
	END
  ```
EOF
expect "#237: a ! command feeding a heredoc on the last line passes" "$(gate "$D")" 0

D="$WORKDIR/neg-heredoc-after"
project "$D" "$MINIMAL"
mkfeature "$D" 210-neghd2 Draft <<'EOF'
- [x] T001 Task

  ```accept
  ! grep -q needle <<END
  text
  END
  true
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "#237: a command after the heredoc still makes the ! non-last" "$OUT" \
    "specs/210-neghd2/tasks.md:4: a ! command other than the last one"

D="$WORKDIR/neg-not-heredoc"
project "$D" "$MINIMAL"
mkfeature "$D" 210-neghd3 Draft <<'EOF'
- [x] T001 Task

  ```accept
  echo "<<END" '<<END' $((1<<2)) <<< x # <<END
  ! grep -q needle README
  true
  ```
EOF
OUT="$(gate_out "$D")"
expect_contains "#237: quoted, arithmetic, here-string and comment << open no heredoc" \
    "$OUT" "specs/210-neghd3/tasks.md:5: a ! command other than the last one"

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
# Load sources faked (#264): a load file in place of /proc/loadavg, and
# sysctl and uptime stubs first on PATH that fail unless told otherwise.
LOADSTUB="$WORKDIR/load-stubs"
mkdir -p "$LOADSTUB"
# shellcheck disable=SC2016  # stub scripts, expanded when they run
printf '#!/bin/sh\n[ -n "$FAKE_SYSCTL" ] || exit 1\nprintf "%%s\\n" "$FAKE_SYSCTL"\n' >"$LOADSTUB/sysctl"
# shellcheck disable=SC2016  # stub scripts, expanded when they run
printf '#!/bin/sh\n[ -n "$FAKE_UPTIME" ] || exit 1\nprintf "%%s\\n" "$FAKE_UPTIME"\n' >"$LOADSTUB/uptime"
chmod +x "$LOADSTUB/sysctl" "$LOADSTUB/uptime"
printf '48.20 30.10 20.00 3/512 4242\n' >"$WORKDIR/loadavg"
OUT="$(GATES_SPEC_LOADAVG_FILE="$WORKDIR/loadavg" PATH="$LOADSTUB:$PATH" gate_out "$D")"
expect_contains "hung block blocks the run" "$OUT" "EXIT=2"
expect_contains "timeout is named with the budget and the load" "$OUT" "timeout after 1s at load 48.20"
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
# No load source at all: the plain detail.
OUT="$(GATES_SPEC_LOADAVG_FILE="$WORKDIR/no-loadavg" PATH="$LOADSTUB:$PATH" gate_out "$D")"
expect_contains "no load source: still a timeout" "$OUT" "timeout after 1s"
expect "no load source: the detail names no load" "$(grep -c 'at load' <<<"$OUT")" 0
# The fallbacks, read directly: macOS sysctl braces, uptime in two styles.
# shellcheck disable=SC2016  # expanded by the inner bash
load_avg() { # [env...] -> gates_spec_load_avg output, or "none"
    env GATES_SPEC_LOADAVG_FILE="$WORKDIR/no-loadavg" PATH="$LOADSTUB:$PATH" "$@" bash -c \
        'source "$1/extension/runtime/lib/spec-gate.sh"; gates_spec_load_avg || printf none' _ "$REPO_ROOT"
}
expect "the load file comes first" "$(load_avg GATES_SPEC_LOADAVG_FILE="$WORKDIR/loadavg" FAKE_SYSCTL='{ 3.50 1.00 0.50 }')" "48.20"
expect "no load file: sysctl vm.loadavg (macOS braces)" "$(load_avg FAKE_SYSCTL='{ 3.50 1.00 0.50 }' FAKE_UPTIME='load average: 9.00')" "3.50"
expect "no sysctl: uptime, Linux style" \
    "$(load_avg FAKE_UPTIME=' 10:00:01 up 3 days,  2 users,  load average: 27.04, 20.00, 10.00')" "27.04"
expect "no sysctl: uptime, macOS style with a decimal comma" \
    "$(load_avg FAKE_UPTIME='10:00  up 3 days, 2 users, load averages: 2,50 1,00 0,90')" "2.50"
expect "unparsable sources: none" "$(load_avg FAKE_SYSCTL='unknown oid' FAKE_UPTIME='up 3 days')" "none"
# The group stop moved to lib/watch.sh (feature 006): spec-gate.sh loads it
# from its own directory, the old name still stops a group, and a watched
# command's timeout reports the load as an accept block's does.
# shellcheck disable=SC2016  # expanded by the inner bash
expect "spec-gate.sh alone: gates_spec_group_stop stops a process group" "$(bash -c '
    source "$1/extension/runtime/lib/spec-gate.sh"
    set -m
    sleep 30 &
    p=$!
    set +m
    t0=$SECONDS
    gates_spec_group_stop "$p"
    wait "$p" 2>/dev/null
    [[ $((SECONDS - t0)) -lt 5 ]] && echo stopped || echo alive' _ "$REPO_ROOT")" stopped
# shellcheck disable=SC2016  # expanded by the inner bash
expect "a watched command's timeout names the load" "$(GATES_SPEC_LOADAVG_FILE="$WORKDIR/loadavg" bash -c '
    source "$1/extension/runtime/lib/spec-gate.sh"
    rc=0
    gates_run_watched 1 "$2" sleep 20 || rc=$?
    printf "%s|%s" "$rc" "$GATES_WATCH_DETAIL"' _ "$REPO_ROOT" "$WORKDIR/watched.out")" "124|timeout after 1s at load 48.20"

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

# --- issue #164: repository state outside the working tree, and children ---
echo ""
echo "=== read-only check: git config, hooks, refs, ignored files, children ==="

# A committed fixture with a hook, an ignored directory and an ignored file,
# so HEAD, a hook and ignored content all exist before the block runs.
isofix() { # <dir> [policy-json]
    local dir="$1"
    project "$dir" "${2:-$MINIMAL}"
    printf 'cache/\n*.log\n' >"$dir/.gitignore"
    printf 'attestations.jsonl\n' >"$dir/.specify/gates/.gitignore"
    mkdir -p "$dir/cache"
    printf 'old\n' >"$dir/cache/data"
    printf 'old\n' >"$dir/run.log"
    printf '#!/bin/sh\nexit 0\n' >"$dir/.git/hooks/pre-commit"
    chmod +x "$dir/.git/hooks/pre-commit"
    git -C "$dir" add -A
    git -C "$dir" -c user.email=b@test -c user.name=baseline commit -qm base --no-verify
}

# Run a one-block Complete feature in a fresh fixture; prints gate output.
isoblock() { # <name> <block-body> [policy-json]
    local d="$WORKDIR/iso-$1"
    isofix "$d" "${3:-$MINIMAL}"
    # shellcheck disable=SC2016  # literal backticks and a %s placeholder
    printf -- '- [x] T001 Must leave the repository alone\n\n  ```accept\n%s\n  ```\n' "$2" \
        | mkfeature "$d" 500-iso Complete
    gate_out "$d"
}

OUT="$(isoblock hookspath '  git config core.hooksPath /dev/null')"
expect_contains "block switching core.hooksPath blocks the run" "$OUT" "EXIT=2"
expect_contains "config change is named" "$OUT" "git config modified: core.hookspath"

OUT="$(isoblock hookwrite '  printf "#!/bin/sh\\n" >.git/hooks/commit-msg')"
expect_contains "block writing a git hook blocks the run" "$OUT" "EXIT=2"
expect_contains "hook write is named" "$OUT" "git hooks modified: commit-msg"

OUT="$(isoblock hookchmod '  chmod -x .git/hooks/pre-commit')"
expect_contains "block disabling a hook's exec bit blocks the run" "$OUT" "EXIT=2"
expect_contains "hook mode change is named" "$OUT" "git hooks modified: pre-commit"

OUT="$(isoblock commit '  git -c user.email=a@test -c user.name=a commit -q --allow-empty --no-verify -m x')"
expect_contains "block committing blocks the run" "$OUT" "EXIT=2"
expect_contains "commit is named as a ref change" "$OUT" "refs modified: HEAD"

OUT="$(isoblock tag '  git tag v9')"
expect_contains "block tagging blocks the run" "$OUT" "EXIT=2"
expect_contains "tag is named" "$OUT" "refs modified: refs/tags/v9"

OUT="$(isoblock ignwrite '  echo new >>cache/data')"
expect_contains "block writing an ignored file blocks the run" "$OUT" "EXIT=2"
expect_contains "ignored write is named" "$OUT" "ignored files modified: cache/data"

OUT="$(isoblock ignbackdate '  echo new >>run.log
  touch -t 200001010000 run.log')"
expect_contains "backdating mtime does not hide an ignored write" "$OUT" "ignored files modified: run.log"

OUT="$(isoblock igncreate '  echo x >new.log')"
expect_contains "block creating an ignored file blocks the run" "$OUT" "ignored files modified: new.log"

OUT="$(isoblock igndelete '  rm -rf cache')"
expect_contains "block deleting an ignored directory blocks the run" "$OUT" "ignored files modified: cache"

OUT="$(isoblock remote '  git update-ref refs/remotes/origin/main HEAD
  git status >/dev/null
  cat cache/data run.log .git/hooks/pre-commit >/dev/null')"
expect_contains "reads and a remote-tracking ref update pass" "$OUT" "EXIT=0"

OUT="$(isoblock excluded '  echo new >>cache/data' \
    '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "snapshot_exclude": ["cache/**"] } }')"
expect_contains "spec.snapshot_exclude exempts an ignored path" "$OUT" "EXIT=0"

# "dir/" names the directory, like "dir/**" (#199): the ignored root and
# untracked files under it.
OUT="$(isoblock excldir '  echo new >>cache/data
  mkdir -p scratch && echo x >scratch/new.txt' \
    '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "snapshot_exclude": ["cache/", "scratch/"] } }')"
expect_contains "a trailing-slash snapshot_exclude exempts the directory" "$OUT" "EXIT=0"

# Nested repositories and worktrees (#263): other agents write in their
# own worktrees under an ignored directory while a block runs. A directory
# with its own .git (a directory or a worktree's .git file) is left out with
# everything under it; an ordinary ignored write still counts.
D="$WORKDIR/iso-nestedrepo"
isofix "$D"
git init -q "$D/cache/inner"
git -C "$D" worktree add -q -b agent-wt "$D/cache/wt" 2>/dev/null
# shellcheck disable=SC2016  # literal backticks
printf -- '- [x] T001 Must leave the repository alone\n\n  ```accept\n%s\n  ```\n' \
    '  echo x >>cache/inner/f; echo x >>cache/wt/f' \
    | mkfeature "$D" 500-iso Complete
OUT="$(gate_out "$D")"
expect_contains "writes inside nested repos and worktrees do not count (#263)" "$OUT" "EXIT=0"
# shellcheck disable=SC2016  # literal backticks
printf -- '- [x] T001 Must leave the repository alone\n\n  ```accept\n%s\n  ```\n' \
    '  echo x >>cache/wt/f; echo new >>cache/data' \
    | mkfeature "$D" 500-iso Complete
OUT="$(gate_out "$D")"
expect_contains "an ignored write next to a nested worktree still counts" "$OUT" \
    "ignored files modified: cache/data"
expect "the nested worktree is not named" "$(grep -c 'cache/wt' <<<"$OUT" || true)" 0

# A nested verify.sh (recursion guard set) appends its attestation; the gate
# exempts its own evidence log, and the nested run reports spec as skipped.
# shellcheck disable=SC2016  # block text, expanded when the block runs
OUT="$(isoblock nested '  out="$(CLAUDE_PROJECT_DIR="$PWD" bash .specify/gates/verify.sh --boundary ci)"
  grep -q "skipped. spec" <<<"$out"
  test -s .specify/gates/attestations.jsonl')"
expect_contains "nested verify.sh inside a block passes" "$OUT" "EXIT=0"

# The leftover children below record their pid when they start, live far
# longer than the gate takes to stop them, then act. Each check waits for
# the recorded pid to be gone (bounded) instead of a fixed time (#281): a
# stopped child never acts, a child the gate missed acts before it exits.
LATE="$WORKDIR/late.sh"
# shellcheck disable=SC2016  # the script's own expansions
printf '#!/bin/sh\necho $$ >"$1"\nshift\nsleep 30\n"$@"\n' >"$LATE"
late_child_done() { # <pidfile>: wait until the child it names has exited
    local n=0 pid
    while [[ ! -s "$1" && $n -lt 50 ]]; do
        sleep 0.1
        n=$((n + 1))
    done
    # No pid file: the child was stopped before it could write one.
    [[ -s "$1" ]] || return 0
    pid="$(cat "$1")"
    n=0
    while kill -0 "$pid" 2>/dev/null && [[ $n -lt 600 ]]; do
        sleep 0.1
        n=$((n + 1))
    done
}

OUT="$(isoblock child "  /bin/sh $LATE $WORKDIR/iso-child.pid touch late.txt &")"
expect_contains "block leaving a child running blocks the run" "$OUT" "EXIT=2"
expect_contains "leftover child is named" "$OUT" "left a process running"

# Issue #197: a child that leaves the process group (set -m) or the session
# (setsid after a fork) is found by the lease descriptor it inherited. The
# system binaries are named by path: macOS hides their environment from ps,
# so these pass only through the lease.
OUT="$(isoblock setm "  /bin/bash -c \"set -m; /bin/sh $LATE $WORKDIR/iso-setm.pid git config core.hooksPath /dev/null & disown\"")"
expect_contains "block leaving a set -m child running blocks the run" "$OUT" "EXIT=2"
expect_contains "detached child is named" "$OUT" "left a detached process running (stopped)"
OUT="$(isoblock setsid "  perl -e \"use POSIX; fork and exit; POSIX::setsid(); exec q(/bin/sh), q($LATE), q($WORKDIR/iso-setsid.pid), q(touch), q(late.txt)\"")"
expect_contains "block leaving a setsid child running blocks the run" "$OUT" "EXIT=2"
expect_contains "new-session child is named" "$OUT" "left a detached process running (stopped)"
# A runtime that closes inherited descriptors (Node's spawn passes only
# stdio) is found by the GATES_SPEC_BLOCK marker; on macOS a system shell
# hides it, so this runs where /proc exposes every environment.
if [[ -r /proc/self/environ ]]; then
    OUT="$(isoblock nodespawn "  node -e \"require('child_process').spawn('sh', ['$LATE', '$WORKDIR/iso-nodespawn.pid', 'touch', 'late.txt'], { detached: true, stdio: 'ignore' }).unref()\"")"
    expect_contains "child without the lease descriptor is found by its marker" "$OUT" \
        "left a detached process running (stopped)"
fi

for late_pid in child setm setsid nodespawn; do
    late_child_done "$WORKDIR/iso-$late_pid.pid"
done
TOTAL=$((TOTAL + 1))
if [[ ! -e "$WORKDIR/iso-child/late.txt" ]]; then
    echo "PASS: passing block's child is stopped, no late write"
    PASS=$((PASS + 1))
else
    echo "FAIL: passing block's child kept running and wrote late.txt"
    FAIL=$((FAIL + 1))
fi
expect "set -m child is stopped before it switches hooks off" \
    "$(git -C "$WORKDIR/iso-setm" config core.hooksPath || echo unset)" "unset"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$WORKDIR/iso-setsid/late.txt" ]]; then
    echo "PASS: setsid child is stopped, no late write"
    PASS=$((PASS + 1))
else
    echo "FAIL: setsid child kept running and wrote late.txt"
    FAIL=$((FAIL + 1))
fi
if [[ -r /proc/self/environ ]]; then
    TOTAL=$((TOTAL + 1))
    if [[ ! -e "$WORKDIR/iso-nodespawn/late.txt" ]]; then
        echo "PASS: marked child is stopped, no late write"
        PASS=$((PASS + 1))
    else
        echo "FAIL: marked child kept running and wrote late.txt"
        FAIL=$((FAIL + 1))
    fi
fi

OUT="$(isoblock skipflag '  git update-index --skip-worktree .gitignore')"
expect_contains "block setting skip-worktree blocks the run" "$OUT" "index flags modified: .gitignore"

# A file already flagged skip-worktree: status hides the edit, the hash not.
D="$WORKDIR/iso-skipwrite"
isofix "$D"
git -C "$D" update-index --skip-worktree .gitignore
# shellcheck disable=SC2016  # literal backticks
printf -- '- [x] T001 Must leave the repository alone\n\n  ```accept\n  echo x >>.gitignore\n  ```\n' \
    | mkfeature "$D" 500-iso Complete
OUT="$(gate_out "$D")"
expect_contains "write to a skip-worktree file blocks the run" "$OUT" "index flags modified: .gitignore"

OUT="$(isoblock attributes '  echo "* -diff" >.git/info/attributes')"
expect_contains "block writing .git/info/attributes blocks the run" "$OUT" "git info files modified: attributes"
OUT="$(isoblock infoexclude '  echo "*.md" >>.git/info/exclude')"
expect_contains "block writing .git/info/exclude blocks the run" "$OUT" "git info files modified: exclude"
# Issue #213: the first git gc writes .git/info/refs, a transport artifact.
OUT="$(isoblock infogc '  git gc -q')"
expect_contains "first git gc in a block passes (#213)" "$OUT" "EXIT=0"
OUT="$(isoblock infoserver '  git update-server-info')"
expect_contains "git update-server-info in a block passes" "$OUT" "EXIT=0"

# Issue #206: another worktree's activity is not the block's doing. Each
# fixture has a sibling worktree on branch "side" and a branch "stray" that
# no worktree has checked out; <where> picks the worktree the gate runs in.
# The block body may name the fixture paths as @MAIN@ and @SIB@.
wtblock() { # <name> <main|linked> <block-body>
    local d="$WORKDIR/iso-$1" body="$3" t
    isofix "$d"
    git -C "$d" worktree add -q "$d-wt" -b side >/dev/null 2>&1
    git -C "$d" branch stray
    t="$d"
    [[ "$2" == linked ]] && t="$d-wt"
    body="$(MAIN="$d" SIB="$d-wt" awk '{ gsub(/@MAIN@/, ENVIRON["MAIN"]); gsub(/@SIB@/, ENVIRON["SIB"]); print }' <<<"$body")"
    # shellcheck disable=SC2016  # literal backticks and a %s placeholder
    printf -- '- [x] T001 Must leave the repository alone\n\n  ```accept\n%s\n  ```\n' "$body" \
        | mkfeature "$t" 500-iso Complete
    gate_out "$t"
}
WTC='-c user.email=a@test -c user.name=a commit -q --allow-empty --no-verify -m x'

OUT="$(wtblock wtsibcommit main "  git -C @SIB@ $WTC")"
expect_contains "commit in a sibling worktree passes" "$OUT" "EXIT=0"
OUT="$(wtblock wtsibswitch main '  git -C @SIB@ switch -q -c other')"
expect_contains "branch switch in a sibling worktree passes" "$OUT" "EXIT=0"
OUT="$(wtblock wtsibadd main '  git worktree add -q -b fresh @MAIN@-wt2')"
expect_contains "sibling worktree added on a new branch passes" "$OUT" "EXIT=0"
OUT="$(wtblock wtsibremove main "  git -C @SIB@ $WTC && git worktree remove @SIB@")"
expect_contains "sibling worktree that commits and is removed passes" "$OUT" "EXIT=0"
OUT="$(wtblock wtmaincommit linked "  git -C @MAIN@ $WTC")"
expect_contains "commit in the main worktree passes in a linked one" "$OUT" "EXIT=0"

OUT="$(wtblock wtstray main '  git branch -D -q stray')"
expect_contains "deleting a branch checked out nowhere blocks the run" "$OUT" "refs modified: refs/heads/stray"
OUT="$(wtblock wtnew main '  git branch brandnew')"
expect_contains "creating a branch blocks the run" "$OUT" "refs modified: refs/heads/brandnew"
OUT="$(wtblock wtown linked "  git $WTC")"
expect_contains "commit on a linked worktree's own branch blocks the run" "$OUT" "refs modified: HEAD refs/heads/side"
OUT="$(wtblock wtlock linked '  git worktree lock @SIB@')"
expect_contains "locking its own linked worktree blocks the run" "$OUT" "worktrees modified: iso-wtlock-wt"
OUT="$(wtblock wtinner main '  git worktree add -q --detach inner')"
expect_contains "worktree added inside the project blocks the run" "$OUT" "working tree modified: inner/"

OUT="$(isoblock reaped '  sleep 30 &
  kill $!')"
expect_contains "block that stops its own child passes" "$OUT" "EXIT=0"
# The child takes a moment to exit on TERM; the block does not wait for it.
# shellcheck disable=SC2016  # block text, expanded when the block runs
OUT="$(isoblock slowexit '  bash -c '"'"'trap "kill \$c; sleep 0.2; exit 0" TERM; sleep 30 & c=$!; wait'"'"' &
  sleep 0.2
  kill $!')"
expect_contains "block whose stopped child is still exiting passes" "$OUT" "EXIT=0"

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

# --- covered accept blocks (feature 007, US1 and US3) ------------------------
# A covering script declared in spec.cover is asked about each block at the
# boundaries spec.cover.at names (agent, git); a clean one-line answer
# covers the block: not run, named with its reason. Everywhere else every
# block runs. Blocks and scripts mark that they ran with files outside the
# fixture repository, so the read-only check never sees them.
echo ""
echo "=== covered accept blocks (feature 007) ==="
# shellcheck source=lib/fixture.sh disable=SC1091
source "$REPO_ROOT/tests/lib/fixture.sh"
CVM="$WORKDIR/cover-marks"
mkdir -p "$CVM"
cv_project() { # <name> <cover-json, or "" for none>: fixture dir on stdout
    local d="$WORKDIR/cover-$1" spec='{ "severity": "error" }'
    [[ -n "$2" ]] && spec="{ \"severity\": \"error\", \"cover\": $2 }"
    project "$d" "{ \"hooks\": { \"verify-quality\": { \"orchestrator\": \"none\", \"severity\": \"error\" } }, \"spec\": $spec }"
    printf '%s\n' "$d"
}
cv_script() { # <dir> <sh body>: write the covering script scripts/cover.sh
    mkdir -p "$1/scripts"
    printf '#!/bin/sh\n%s\n' "$2" >"$1/scripts/cover.sh"
    chmod +x "$1/scripts/cover.sh"
}
cv_run() { # <dir> <boundary or ""> [flag...]: stdout+stderr, EXIT=<rc> last
    local dir="$1" b="$2" rc=0 out
    shift 2
    local args=()
    [[ -n "$b" ]] && args=(--boundary "$b")
    out="$(CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC -u GATES_POLICY_FILE \
        bash "$dir/.specify/gates/verify.sh" ${args[@]+"${args[@]}"} "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}
cv_last() { # <dir> <jq filter on the last attestation>
    tail -n 1 "$1/.specify/gates/attestations.jsonl" | jq -c "$2"
}
GIT_COVER='{ "script": "scripts/cover.sh", "at": ["git"] }'

# Covered at git: the reason is shown, the block's command never runs.
D="$(cv_project git "$GIT_COVER")"
fx_spec_feature "$D" 900-demo T001 "touch $CVM/git-block-ran" T002 "touch $CVM/git-t2-ran"
# shellcheck disable=SC2016  # expanded by the covering script
cv_script "$D" '[ "$2" = T001 ] || exit 1
echo "proven by $1 $2 at $GATES_BOUNDARY"; echo noise >&2'
OUT="$(cv_run "$D" git)"
expect_contains "covered: the report names the block and the reason" "$OUT" \
    'spec: 900-demo: "T001 900-demo task" -- covered: proven by 900-demo T001 at git'
expect "covered: the block's command did not run" "$([[ -e "$CVM/git-block-ran" ]] && echo ran || echo not-run)" not-run
expect "covered: the block the script declined ran" "$([[ -e "$CVM/git-t2-ran" ]] && echo ran || echo not-run)" ran
expect "covered: the run passes" "${OUT##*EXIT=}" 0
expect "covered: stderr of the script is not shown" "$(grep -c noise <<<"$OUT" || true)" 0
expect_contains "covered: the spec summary counts and names the covered block" "$OUT" \
    '[pass] spec -- 1 features, 2 blocks: 1 passed, 1 covered at git: 900-demo T001#1'
expect "covered: attestation counts (parsed, executed, passed, covered)" \
    "$(cv_last "$D" '.spec.results[0] | [.blocks_parsed, .blocks_executed, .blocks_passed, .blocks_failed, .blocks_covered, .outcome]')" \
    '[2,1,1,0,1,"enforced-pass"]'
# shellcheck disable=SC2016  # a jq program
expect "covered: the entries of the covered block and of the block that ran" \
    "$(cv_last "$D" '[.spec.results[0].blocks[] | (.duration_s | type == "number" and . >= 0) as $d | del(.duration_s) + {d: $d}]')" \
    '[{"task":"T001","ordinal":1,"verifies":null,"result":"covered","reason":"proven by 900-demo T001 at git","declared_skip":"git","d":true},{"task":"T002","ordinal":1,"verifies":null,"result":"pass","reason":"","d":true}]'
expect "covered: run-wide spec counts leave covered blocks out" \
    "$(cv_last "$D" '.spec | [.parsed, .executed, .passed, .failed]')" '[2,1,1,0]'
expect "covered: --json detail names the covered block" \
    "$(cv_run "$D" git --json | sed '$d' | jq -r '.gates[] | select(.name == "spec") | .detail')" \
    '1 features, 2 blocks: 1 passed, 1 covered at git: 900-demo T001#1'
rm -f "$CVM"/*

# At ci the script is never asked and every block runs.
cv_script "$D" "touch $CVM/ci-asked; echo covered"
OUT="$(cv_run "$D" ci)"
expect "ci: the covering script is not called" "$([[ -e "$CVM/ci-asked" ]] && echo called || echo not-called)" not-called
expect "ci: every block runs" "$(cv_last "$D" '.spec.results[0] | [.blocks_executed, .blocks_covered, [.blocks[].result]]')" '[2,0,["pass","pass"]]'
expect_contains "ci: nothing covered, the report is unchanged" "$OUT" '[pass] spec'
expect "ci: no covered line" "$(grep -c 'covered' <<<"$OUT" || true)" 0
# Without --boundary nothing is covered either.
rm -f "$CVM"/*
OUT="$(cv_run "$D" "")"
expect "no --boundary: the covering script is not called" "$([[ -e "$CVM/ci-asked" ]] && echo called || echo not-called)" not-called
expect "no --boundary: every block runs" "$(cv_last "$D" '.spec.results[0].blocks_executed')" 2
# at: ["git"] does not cover at agent.
OUT="$(cv_run "$D" agent)"
expect "agent, at git only: the script is not called" "$([[ -e "$CVM/ci-asked" ]] && echo called || echo not-called)" not-called
expect "agent, at git only: every block runs" "$(cv_last "$D" '.spec.results[0].blocks_executed')" 2
# at: ["agent", "git"] covers at agent.
D2="$(cv_project agent '{ "script": "scripts/cover.sh", "at": ["agent", "git"] }')"
fx_spec_feature "$D2" 900-demo T001 "touch $CVM/agent-block-ran"
cv_script "$D2" 'echo "agent ok"'
OUT="$(cv_run "$D2" agent)"
expect_contains "agent declared: the block is covered" "$OUT" 'task" -- covered: agent ok'
expect "agent declared: the block did not run" "$([[ -e "$CVM/agent-block-ran" ]] && echo ran || echo not-run)" not-run
expect "agent declared: declared_skip is agent" "$(cv_last "$D2" '.spec.results[0].blocks[0].declared_skip')" '"agent"'
# No spec.cover: every block runs, the report is unchanged.
D3="$(cv_project none "")"
fx_spec_feature "$D3" 900-demo T001 "touch $CVM/none-block-ran"
cv_script "$D3" "touch $CVM/none-asked; echo covered"
OUT="$(cv_run "$D3" git)"
expect "no spec.cover: the block runs, the script is not called" \
    "$([[ -e "$CVM/none-block-ran" ]] && echo ran)-$([[ -e "$CVM/none-asked" ]] && echo asked)" "ran-"
expect "no spec.cover: nothing covered, the block's entry says pass" \
    "$(cv_last "$D3" '.spec.results[0] | [.blocks_covered, [.blocks[] | .result, has("declared_skip")]]')" '[0,["pass",false]]'

# Any answer but exit 0 with exactly one non-empty line runs the block.
D4="$(cv_project answers '{ "script": "scripts/cover.sh", "at": ["git"], "timeout_s": 2 }')"
fx_spec_feature "$D4" 900-demo T001 "touch $CVM/answer-block-ran"
while IFS='|' read -r what body; do
    [[ -n "$what" ]] || continue
    rm -f "$CVM"/*
    cv_script "$D4" "$body"
    OUT="$(cv_run "$D4" git)"
    expect "not covered ($what): the block runs" \
        "$([[ -e "$CVM/answer-block-ran" ]] && echo ran || echo not-run)/$(grep -c -- '-- covered' <<<"$OUT" || true)" "ran/0"
done <<'EOF'
non-zero exit with one line|echo "covered"; exit 1
exit 0 with no output|exit 0
exit 0 with an empty line|echo
exit 0 with a blank line|echo "   "
exit 0 with two lines|echo one; echo two
exit 0 with a line and an empty one|echo one; echo
exit 124 with a line|echo covered; exit 124
EOF
rm -f "$CVM"/*
cv_script "$D4" 'echo covered'
chmod -x "$D4/scripts/cover.sh"
OUT="$(cv_run "$D4" git)"
expect "not covered (script not executable): the block runs" \
    "$([[ -e "$CVM/answer-block-ran" ]] && echo ran || echo not-run)/${OUT##*EXIT=}" "ran/0"
# A script over its time limit is stopped and the block runs.
rm -f "$CVM"/*
cv_script "$D4" 'sleep 67
echo late'
T0="$(date +%s)"
OUT="$(cv_run "$D4" git)"
T1="$(date +%s)"
expect "timeout: the block runs" "$([[ -e "$CVM/answer-block-ran" ]] && echo ran || echo not-run)" ran
expect "timeout: the run ends within 7s of a 2s limit" "$([[ $((T1 - T0)) -le 7 ]] && echo yes || echo "no ($((T1 - T0))s)")" yes
sleep 0.5
# shellcheck disable=SC2009  # pgrep -x matches the name, not "sleep 67"
expect "timeout: the script's sleep is stopped" \
    "$(ps -A -o command= 2>/dev/null | grep -c '^sleep 67$' || true)" 0

# Reason hygiene (FR-008): control characters removed, cut to 200.
D5="$(cv_project hygiene "$GIT_COVER")"
mkfeature "$D5" 900-demo Complete <<'MD'
- [x] T001 One task, two blocks

  ```accept
  true
  ```

  ```accept
  true
  ```
MD
# shellcheck disable=SC2016  # expanded by the covering script
cv_script "$D5" 'printf "a\tb\033[1mc%0300d\r\n" 0'
OUT="$(cv_run "$D5" git)"
WANT_REASON="ab[1mc$(printf '%0194d' 0)"
expect "hygiene: the recorded reason" "$(cv_last "$D5" '.spec.results[0].blocks[0].reason')" "\"$WANT_REASON\""
expect "hygiene: reason length is 200" "$(cv_last "$D5" '.spec.results[0].blocks[0].reason | length')" 200
expect "hygiene: two blocks of one task are #1 and #2" \
    "$(cv_last "$D5" '[.spec.results[0].blocks[] | "\(.task)#\(.ordinal)"]')" '["T001#1","T001#2"]'
expect_contains "hygiene: both are named in the summary" "$OUT" 'covered at git: 900-demo T001#1, 900-demo T001#2'

# A task line without a T### id is named "-".
D6="$(cv_project noid "$GIT_COVER")"
mkfeature "$D6" 900-demo Complete <<'MD'
- [x] Write the thing

  ```accept
  # verifies: FR-1
  true
  ```
MD
# shellcheck disable=SC2016  # expanded by the covering script
cv_script "$D6" 'echo "task $2"'
OUT="$(cv_run "$D6" git)"
expect_contains "no task id: the script gets - and the block is named -#1" "$OUT" \
    'spec: 900-demo: "FR-1" -- covered: task -'
expect "no task id: the entry" "$(cv_last "$D6" '.spec.results[0].blocks[0] | [.task, .ordinal, .verifies]')" '["-",1,"FR-1"]'

# A script that writes to the tree does not fail the next block as a
# mutation: that block's before-snapshot is taken after the script ran.
D7="$(cv_project writes "$GIT_COVER")"
fx_spec_feature "$D7" 900-demo T001 'true' T002 'true'
# shellcheck disable=SC2016  # expanded by the covering script
cv_script "$D7" '[ "$2" = T002 ] && echo x >cover-scratch.txt; exit 1'
OUT="$(cv_run "$D7" git)"
expect "script writes to the tree: the next block still passes" "${OUT##*EXIT=}" 0

# --accept on an incomplete feature: covered, informational.
D8="$(cv_project accept "$GIT_COVER")"
mkfeature "$D8" 900-draft Draft <<MD
- [x] T001 Draft task

  \`\`\`accept
  touch $CVM/draft-block-ran
  \`\`\`
MD
cv_script "$D8" 'echo "draft ok"'
rm -f "$CVM"/*
OUT="$(cv_run "$D8" git --accept 900-draft)"
expect_contains "--accept: the block is covered (informational)" "$OUT" \
    'spec: 900-draft: "T001 Draft task" -- covered (informational): draft ok'
expect "--accept: the block did not run" "$([[ -e "$CVM/draft-block-ran" ]] && echo ran || echo not-run)" not-run

# A declared script that is missing, or resolves outside the project,
# refuses the run: exit 1, no gate ran.
D9="$(cv_project missing "$GIT_COVER")"
fx_spec_feature "$D9" 900-demo T001 "touch $CVM/missing-block-ran"
for b in git ci; do
    OUT="$(cv_run "$D9" "$b")"
    expect "missing script ($b): exit 1" "${OUT##*EXIT=}" 1
    expect_contains "missing script ($b): the path is named" "$OUT" 'spec.cover.script scripts/cover.sh: not found; no gate ran'
    expect "missing script ($b): no gate ran" "$(grep -c '^gates: boundary=' <<<"$OUT" || true)/$([[ -e "$CVM/missing-block-ran" ]] && echo ran)" "0/"
done
mkdir -p "$D9/scripts"
printf '#!/bin/sh\necho covered\n' >"$WORKDIR/outside-cover.sh"
chmod +x "$WORKDIR/outside-cover.sh"
ln -s "$WORKDIR/outside-cover.sh" "$D9/scripts/cover.sh"
OUT="$(cv_run "$D9" git)"
expect_contains "symlink out of the project: refused" "$OUT" 'scripts/cover.sh: resolves outside the project; no gate ran'
expect "symlink out of the project: exit 1" "${OUT##*EXIT=}" 1
rm -f "$D9/scripts/cover.sh"
mkdir -p "$D9/scripts/cover.sh"
OUT="$(cv_run "$D9" git)"
expect_contains "a directory: refused" "$OUT" 'scripts/cover.sh: not a regular file; no gate ran'
rm -rf "$D9/scripts/cover.sh"
mkdir -p "$D9/lib"
printf '#!/bin/sh\necho "via link"\n' >"$D9/lib/real-cover.sh"
chmod +x "$D9/lib/real-cover.sh"
ln -s ../lib/real-cover.sh "$D9/scripts/cover.sh"
OUT="$(cv_run "$D9" git)"
expect_contains "symlink inside the project: followed" "$OUT" 'task" -- covered: via link'

# Block identity (research R14): <n> counts the blocks under one task line,
# so two tasks with the same text number their blocks independently.
D10="$(cv_project sametext "$GIT_COVER")"
mkfeature "$D10" 900-demo Complete <<'MD'
- [x] Do the thing

  ```accept
  true
  ```

- [x] Do the thing

  ```accept
  true
  ```

  ```accept
  true
  ```
MD
cv_script "$D10" 'echo ok'
OUT="$(cv_run "$D10" git)"
expect "same task text: each task numbers its own blocks" \
    "$(cv_last "$D10" '[.spec.results[0].blocks[] | "\(.task)#\(.ordinal)"]')" '["-#1","-#1","-#2"]'
expect_contains "same task text: the summary names them so" "$OUT" \
    'covered at git: 900-demo -#1, 900-demo -#1, 900-demo -#2'

# --- per-block entries (feature 007, US4) ------------------------------------
# Every evaluated block has an entry, in order, with its result, a fixed
# reason and its duration; the block's output never reaches the record.
echo ""
echo "=== per-block attestation entries (feature 007) ==="
D11="$(cv_project timings "")"
fx_spec_feature "$D11" 900-demo T001 'true' T002 '# verifies: FR-9
sleep 2'
cv_run "$D11" git >/dev/null
expect "timings: one entry per block, in order" \
    "$(cv_last "$D11" '[.spec.results[0].blocks[] | [.task, .ordinal, .verifies, .result, .reason]]')" \
    '[["T001",1,null,"pass",""],["T002",1,"FR-9","pass",""]]'
DUR="$(cv_last "$D11" '[.spec.results[0].blocks[].duration_s]')"
expect "timings: a quick block takes 0 to 1s, a sleep 2 block 2 to 3s (got $DUR)" \
    "$(jq -r '.[0] >= 0 and .[0] <= 1 and .[1] >= 2 and .[1] <= 3' <<<"$DUR")" true
D12="$WORKDIR/block-results"
project "$D12" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "severity": "error", "timeout_s": 2 } }'
fx_spec_feature "$D12" 900-demo T001 'echo BLOCK-OUTPUT-1; exit 3' T002 'echo BLOCK-OUTPUT-2; sleep 30' \
    T003 'echo BLOCK-OUTPUT-3 >written-by-block.txt'
OUT="$(cv_run "$D12" git)"
expect "results: the run fails" "${OUT##*EXIT=}" 2
expect "results: failed, timed out and mutating blocks with fixed reasons" \
    "$(cv_last "$D12" '[.spec.results[0].blocks[] | [.task, .result, .reason]]')" \
    '[["T001","fail","check failed"],["T002","timeout","timeout after 2s"],["T003","mutation","read-only check failed"]]'
expect "results: no block output or detail in the block entries" \
    "$(cv_last "$D12" '.spec.results[0].blocks' | grep -c -e 'BLOCK-OUTPUT' -e 'exit 3' -e 'written-by-block' || true)" 0
expect_contains "results: the report still shows the block's detail" "$OUT" 'FAILED (exit 3)'

echo ""
echo "$PASS of $TOTAL tests passed"
if [[ "$FAIL" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
