#!/bin/bash
set -euo pipefail

# doctor.sh: environment/prerequisite checks.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-doctor)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

# Project doctor + runtime into <dir> with a caller-supplied policy, optionally
# linking the pinned node_modules so the linters resolve.
project() { # <dir> <policy-json> <link-node:yes|no>
    local dir="$1" policy="$2" link="$3"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/doctor.sh" "$REPO_ROOT/extension/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
    if [[ "$link" == "yes" && -d "$REPO_ROOT/node_modules" ]]; then
        ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
    fi
}

run_doctor() { # <dir> -> exit code
    local dir="$1" rc=0
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/doctor.sh" >"$dir/out.txt" 2>&1 || rc=$?
    echo "$rc"
}

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

# Doctor exits 1 whenever the host lacks a required tool: python3 (#66),
# and every linter the fixture's policy enables. A "healthy fixture -> exit
# 0" case proves nothing on such a host, so it is skipped there, visibly,
# naming the missing tool (#89). LACK_BASE covers every fixture, LACK_ALL
# the fixtures using $ALL (prettier, markdownlint, shellcheck).
LACK_BASE=""
python3 -c 'import json, re' >/dev/null 2>&1 || LACK_BASE="python3"
LACK_ALL="$LACK_BASE"
command -v shellcheck >/dev/null 2>&1 || LACK_ALL="${LACK_ALL:+$LACK_ALL, }shellcheck"
[[ -x "$REPO_ROOT/node_modules/.bin/prettier" && -x "$REPO_ROOT/node_modules/.bin/markdownlint-cli2" ]] \
    || LACK_ALL="${LACK_ALL:+$LACK_ALL, }node linters"
SKIPPED=0
healthy() { # <name> <actual-rc> <lacking-tools>: expect 0 unless the host lacks a tool
    if [[ -n "$3" ]]; then
        echo "SKIP: $1 (this host lacks $3)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    expect "$1" "$2" 0
}

ALL='{ "hooks": { "prettier": {"include":["**/*.md"],"orchestrator":"none","severity":"error"}, "markdownlint": {"include":["**/*.md"],"orchestrator":"none","severity":"error"}, "shellcheck": {"include":["**/*.sh"],"orchestrator":"none","severity":"error"} } }'

# jq + git are always present in the test environment, so "required" passes.
echo "=== all policy linters available -> exit 0 ==="
if [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; then
    D="$WORKDIR/ok"
    project "$D" "$ALL" yes
    healthy "everything present -> exit 0" "$(run_doctor "$D")" "$LACK_ALL"
    if [[ -z "$LACK_ALL" ]]; then # skipped with the case above otherwise
        TOTAL=$((TOTAL + 1))
        if grep -q "all required tooling present" "$D/out.txt"; then
            echo "PASS: reports success"
            PASS=$((PASS + 1))
        else
            echo "FAIL: success message"
            FAIL=$((FAIL + 1))
        fi
    fi
else
    echo "SKIP: linters-present case (run npm ci)"
fi

echo ""
echo "=== policy enables a linter that is not installed -> exit 1 ==="
# No node_modules link: prettier/markdownlint unavailable (unless globally
# installed). Guard: only meaningful when there is no global prettier.
if ! command -v prettier >/dev/null 2>&1; then
    D="$WORKDIR/missing"
    project "$D" '{ "hooks": { "prettier": {"include":["**/*.md"],"orchestrator":"none","severity":"error"} } }' no
    expect "enabled-but-missing linter -> exit 1" "$(run_doctor "$D")" 1
    if grep -q "enabled in policy but not installed" "$D/out.txt"; then
        echo "PASS: names the gap"
        PASS=$((PASS + 1))
    else
        echo "FAIL: gap message"
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
else
    echo "SKIP: missing-linter case (global prettier present)"
fi

echo ""
echo "=== disabled linter is reported as skipped, not missing ==="
D="$WORKDIR/disabled"
project "$D" '{ "hooks": { "shellcheck": {"include":["**/*.sh"],"orchestrator":"none","severity":"error"} } }' yes
run_doctor "$D" >/dev/null
if grep -q "prettier (not enabled in policy)" "$D/out.txt"; then
    echo "PASS: disabled linter shown as not-enabled"
    PASS=$((PASS + 1))
else
    echo "FAIL: disabled linter handling"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

echo ""
echo "=== spec conformance section (feature 002) ==="
MINIMAL='{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }'

D="$WORKDIR/spec-counts"
project "$D" "$MINIMAL" no
mkdir -p "$D/specs/100-done" "$D/specs/200-wip"
printf '# Done\n\n**Status**: Complete\n' >"$D/specs/100-done/spec.md"
cat >"$D/specs/100-done/tasks.md" <<'EOF'
- [x] T001 Task

  ```accept
  true
  ```
EOF
printf '# WIP\n\n**Status**: Draft\n' >"$D/specs/200-wip/spec.md"
cat >"$D/specs/200-wip/tasks.md" <<'EOF'
- [ ] T001 Open task

  ```accept
  false
  ```
EOF
healthy "healthy discovery -> exit 0" "$(run_doctor "$D")" "$LACK_BASE"
if grep -q "2 feature(s), 2 accept block(s) parsed, 1 complete" "$D/out.txt"; then
    echo "PASS: discovery counts reported"
    PASS=$((PASS + 1))
else
    echo "FAIL: discovery counts (got: $(grep 'feature(s)' "$D/out.txt" || echo none))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

D="$WORKDIR/spec-parse-error"
project "$D" "$MINIMAL" no
mkdir -p "$D/specs/100-broken"
printf '# Broken\n\n**Status**: Draft\n' >"$D/specs/100-broken/spec.md"
cat >"$D/specs/100-broken/tasks.md" <<'EOF'
- [x] T001 Task

  ```accept
  true
EOF
expect "parse error -> exit 1" "$(run_doctor "$D")" 1
if grep -q "specs/100-broken/tasks.md:3: unterminated accept fence" "$D/out.txt"; then
    echo "PASS: parse error names file:line"
    PASS=$((PASS + 1))
else
    echo "FAIL: parse-error naming (got: $(grep 'tasks.md' "$D/out.txt" || echo none))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

D="$WORKDIR/spec-nudge"
project "$D" "$MINIMAL" no
mkdir -p "$D/specs/100-ready"
printf '# Ready\n\n**Status**: Draft\n' >"$D/specs/100-ready/spec.md"
cat >"$D/specs/100-ready/tasks.md" <<'EOF'
- [x] T001 Task one
- [x] T002 Task two
EOF
healthy "all-checked-not-Complete -> still exit 0" "$(run_doctor "$D")" "$LACK_BASE"
if grep -q "\[rec\] 100-ready — every task checked but Status is not Complete" "$D/out.txt"; then
    echo "PASS: completion nudge shown"
    PASS=$((PASS + 1))
else
    echo "FAIL: completion nudge (got: $(grep '100-ready' "$D/out.txt" || echo none))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

echo ""
echo "=== git boundary wiring (issues #20/#23) ==="

GB="$WORKDIR/git-boundary"
project "$GB" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' no
git init -q "$GB"
cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" \
    "$REPO_ROOT/extension/runtime/hooks/git/commit-msg" "$GB/.git/hooks/"
chmod +x "$GB/.git/hooks/pre-commit" "$GB/.git/hooks/commit-msg"
healthy "wired executable hooks -> exit 0" "$(run_doctor "$GB")" "$LACK_BASE"
if grep -q "pre-commit installed, executable, delegates" "$GB/out.txt"; then
    echo "PASS: healthy hook reported ok"
    PASS=$((PASS + 1))
else
    echo "FAIL: healthy hook report (got: $(grep 'pre-commit' "$GB/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

if grep -q "protected-change trailer enabled" "$GB/out.txt"; then
    echo "PASS: protected-change trailer reported enabled by default"
    PASS=$((PASS + 1))
else
    echo "FAIL: protected-change trailer default (got: $(grep 'protected-change' "$GB/out.txt" || echo none))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "git": { "protected_change_trailer": false } }' \
    >"$GB/.specify/gates/policy.json"
healthy "protected-change trailer off -> still exit 0" "$(run_doctor "$GB")" "$LACK_BASE"
if grep -q "protected-change trailer disabled" "$GB/out.txt"; then
    echo "PASS: protected-change trailer reported disabled"
    PASS=$((PASS + 1))
else
    echo "FAIL: protected-change trailer disabled report (got: $(grep 'protected-change' "$GB/out.txt" || echo none))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' \
    >"$GB/.specify/gates/policy.json"

chmod -x "$GB/.git/hooks/commit-msg"
expect "non-executable installed hook -> exit 1 (silent enforcement loss)" "$(run_doctor "$GB")" 1
if grep -q "commit-msg installed but NOT executable" "$GB/out.txt"; then
    echo "PASS: exec-bit gap named with the fix"
    PASS=$((PASS + 1))
else
    echo "FAIL: exec-bit gap naming (got: $(grep 'commit-msg' "$GB/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
chmod +x "$GB/.git/hooks/commit-msg"

# Copied hooks (pre-#59 install) -> the [rec] nudge toward the stub.
if grep -q "is a copied hook" "$GB/out.txt"; then
    echo "PASS: copied hooks get the stub nudge"
    PASS=$((PASS + 1))
else
    echo "FAIL: copied-hook nudge missing"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Stubs (issue #59): ok while the branch's projected hooks exist, a
# failure when they are missing (the stub would skip = unenforced branch).
mkdir -p "$GB/.specify/gates/hooks"
cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" \
    "$REPO_ROOT/extension/runtime/hooks/git/commit-msg" "$GB/.specify/gates/hooks/"
for h in pre-commit commit-msg; do
    cp "$REPO_ROOT/extension/runtime/hooks/git/stub.sh" "$GB/.git/hooks/$h"
    chmod +x "$GB/.git/hooks/$h"
done
healthy "stub hooks with projected targets -> exit 0" "$(run_doctor "$GB")" "$LACK_BASE"
if grep -q "commit-msg installed as a stub" "$GB/out.txt" && ! grep -q "is a copied hook" "$GB/out.txt"; then
    echo "PASS: stub recognized, no copied-hook nudge"
    PASS=$((PASS + 1))
else
    echo "FAIL: stub recognition (got: $(grep 'commit-msg' "$GB/out.txt" | head -2))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
# Linked worktree: hooks live in the shared directory, not the
# worktree's .git/worktrees/<name>/hooks; doctor must look there.
( cd "$GB" && git config user.email t@example.com && git config user.name tester \
    && git add -A && git commit -q --no-verify -m "chore: seed" ) >/dev/null 2>&1
GW="$WORKDIR/git-boundary-wt"
git -C "$GB" worktree add -q -b feat/wt "$GW" >/dev/null 2>&1
cp "$GB/.specify/gates/doctor.sh" "$GW/.specify/gates/" 2>/dev/null || true
healthy "linked worktree with stubs -> exit 0" "$(run_doctor "$GW")" "$LACK_BASE"
if grep -q "commit-msg installed as a stub" "$GW/out.txt"; then
    echo "PASS: doctor finds the shared hooks from a linked worktree"
    PASS=$((PASS + 1))
else
    echo "FAIL: worktree hook lookup (got: $(grep 'commit-msg' "$GW/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
git -C "$GB" worktree remove --force "$GW" >/dev/null 2>&1 || true

rm "$GB/.specify/gates/hooks/commit-msg"
expect "stub with missing projected hook -> exit 1" "$(run_doctor "$GB")" 1
rm -rf "$GB/.specify/gates/hooks"

rm "$GB/.git/hooks/pre-commit" "$GB/.git/hooks/commit-msg"
healthy "hooks never installed -> nudge only, exit 0" "$(run_doctor "$GB")" "$LACK_BASE"
if grep -q "pre-commit not installed" "$GB/out.txt"; then
    echo "PASS: uninstalled hooks get the [rec] nudge"
    PASS=$((PASS + 1))
else
    echo "FAIL: uninstalled-hook nudge (got: $(grep 'pre-commit' "$GB/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

echo ""
echo "=== policy contract section (feature 003) ==="

CB="$WORKDIR/contract-base"
git init -q "$CB"
printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"enabled":true}}' | jq -S . >"$CB/policy.json"
git -C "$CB" add -A
git -C "$CB" -c user.email=b@t -c user.name=b commit -qm base
git -C "$CB" tag v1.0.0

D="$WORKDIR/contract-ok"
project "$D" "$(jq -cn --arg src "$CB" '{hooks: {"verify-quality": {orchestrator: "none", severity: "error"}}, spec: {enabled: false}, extends: {source: $src, version: "v1.0.0"}}')" no
cp "$REPO_ROOT/extension/runtime/contract.sh" "$D/.specify/gates/"
CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/contract.sh" sync >/dev/null 2>&1
healthy "healthy contract -> exit 0" "$(run_doctor "$D")" "$LACK_BASE"
if grep -q "snapshot matches the pin" "$D/out.txt" && grep -q "deviations: 1 weakened" "$D/out.txt"; then
    echo "PASS: contract state and deviation inventory reported"
    PASS=$((PASS + 1))
else
    echo "FAIL: contract report (got: $(grep -E 'pinned|deviations' "$D/out.txt" | head -2))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

printf ' ' >>"$D/.specify/gates/policy.effective.json"
expect "drifted effective -> exit 1" "$(run_doctor "$D")" 1
if grep -q "effective policy drifted" "$D/out.txt"; then
    echo "PASS: drift named"
    PASS=$((PASS + 1))
else
    echo "FAIL: drift naming (got: $(grep 'MISSING' "$D/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

DU="$WORKDIR/contract-unsynced"
project "$DU" "$(jq -cn --arg src "$CB" '{hooks: {"verify-quality": {orchestrator: "none", severity: "error"}}, extends: {source: $src, version: "v1.0.0"}}')" no
expect "declared-but-unsynced -> exit 1" "$(run_doctor "$DU")" 1
if grep -q "declared but never synced" "$DU/out.txt" && grep -q "speckit.gates.sync" "$DU/out.txt"; then
    echo "PASS: unsynced failure carries the sync nudge"
    PASS=$((PASS + 1))
else
    echo "FAIL: unsynced nudge (got: $(grep -E 'synced' "$DU/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# --- no-op heuristic vs zero-accept-block features (issue #32) ---------------

# A Complete feature with zero accept blocks is a legitimate "nothing to
# check" (IaC/docs repos) — verify.sh must attest candidates=0 for the spec
# gate so doctor's no-op heuristic stays quiet and the repo can reach exit 0.
NZ="$WORKDIR/noop-zeroblocks"
project "$NZ" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' no
mkdir -p "$NZ/specs/010-infra"
cat >"$NZ/specs/010-infra/spec.md" <<'EOF'
# Infra Feature

**Status**: Complete
EOF
cat >"$NZ/specs/010-infra/tasks.md" <<'EOF'
# Tasks

- [x] T001 provision the thing
EOF
CLAUDE_PROJECT_DIR="$NZ" bash "$NZ/.specify/gates/verify.sh" --boundary agent >/dev/null 2>&1 || true
if [[ -f "$NZ/.specify/gates/attestations.jsonl" ]]; then
    SPEC_CAND="$(tail -n 1 "$NZ/.specify/gates/attestations.jsonl" \
        | jq -r '(.gates // [])[] | select(.name == "spec") | .candidates')"
    expect "zero-block Complete feature attests spec candidates=0" "$SPEC_CAND" "0"
else
    echo "FAIL: no attestation written for the zero-block fixture"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
fi
healthy "zero-block Complete feature -> doctor exit 0 (no no-op flag)" "$(run_doctor "$NZ")" "$LACK_BASE"
if grep -q "suspected NO-OP gate: spec" "$NZ/out.txt"; then
    echo "FAIL: doctor still flags spec as a no-op for a zero-block feature"
    FAIL=$((FAIL + 1))
else
    echo "PASS: no spec no-op false positive"
    PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))

# --- execute bits on projected scripts (issue #34) ----------------------------

# An agent hook that exists but is not executable is silently skipped by the
# agent boundary (settings.json invokes it by path) -> doctor FAILURE.
XB="$WORKDIR/execbits"
project "$XB" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' no
mkdir -p "$XB/.claude/hooks/gates"
printf '#!/bin/sh\nexit 0\n' >"$XB/.claude/hooks/gates/protect-files.sh"
chmod -x "$XB/.claude/hooks/gates/protect-files.sh"
expect "non-executable agent hook -> doctor exit 1" "$(run_doctor "$XB")" 1
if grep -q "agent hook not executable" "$XB/out.txt"; then
    echo "PASS: agent-hook exec gap named with the fix"
    PASS=$((PASS + 1))
else
    echo "FAIL: agent-hook exec gap not reported"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# Non-executable projected gates scripts are a [rec] nudge, never a failure.
chmod +x "$XB/.claude/hooks/gates/protect-files.sh"
chmod -x "$XB/.specify/gates/verify.sh"
healthy "non-executable gates script -> still exit 0" "$(run_doctor "$XB")" "$LACK_BASE"
if grep -q "projected script(s) not executable" "$XB/out.txt"; then
    echo "PASS: gates-script exec nudge shown"
    PASS=$((PASS + 1))
else
    echo "FAIL: gates-script exec nudge missing"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
chmod +x "$XB/.specify/gates/verify.sh"

# --- runtime projection version check (issue #33) -----------------------------

RV="$WORKDIR/runtime-version"
project "$RV" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' no
mkdir -p "$RV/.specify/extensions/gates"
printf 'extension:\n  id: gates\n  version: "9.9.9"\n' >"$RV/.specify/extensions/gates/extension.yml"
printf '0.0.1\n' >"$RV/.specify/gates/.runtime-version"
expect "runtime-version mismatch -> doctor exit 1" "$(run_doctor "$RV")" 1
if grep -q "projected runtime is 0.0.1 but the installed extension is 9.9.9" "$RV/out.txt"; then
    echo "PASS: mismatch names both versions and the upgrade command"
    PASS=$((PASS + 1))
else
    echo "FAIL: mismatch message missing"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

printf '9.9.9\n' >"$RV/.specify/gates/.runtime-version"
healthy "runtime-version match -> doctor exit 0" "$(run_doctor "$RV")" "$LACK_BASE"
if grep -q "matches the installed extension" "$RV/out.txt"; then
    echo "PASS: match reported ok"
    PASS=$((PASS + 1))
else
    echo "FAIL: match line missing"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -q "constitution corpus not found" "$RV/out.txt"; then
    echo "PASS: missing corpus surfaced as a nudge"
    PASS=$((PASS + 1))
else
    echo "FAIL: corpus-presence line missing"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# No installed extension (source-run repos like this one): section absent.
NX="$WORKDIR/no-ext"
project "$NX" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }' no
run_doctor "$NX" >/dev/null
if grep -q "Runtime projection" "$NX/out.txt"; then
    echo "FAIL: projection section shown without an installed extension"
    FAIL=$((FAIL + 1))
else
    echo "PASS: no projection section when no extension is installed"
    PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))

# --- constitution enforcement section (feature 004) --------------------------

# A constitution with an unwired annotated principle is a doctor gap (exit 1).
DC="$WORKDIR/const-gap"
project "$DC" "$ALL" no
mkdir -p "$DC/.specify/memory"
cat >"$DC/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Gap
<!-- gates:enforce surface=policy ref=attestation.parity expect=error -->
x
EOF
expect "constitution gap -> doctor exit 1" "$(run_doctor "$DC")" 1
if grep -q "Constitution enforcement" "$DC/out.txt" && grep -q "I. Gap" "$DC/out.txt"; then
    echo "PASS: doctor names the gapped principle"
    PASS=$((PASS + 1))
else
    echo "FAIL: doctor did not name the gapped principle"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# A constitution with NO markers gets the informational nudge, not a failure.
DN="$WORKDIR/const-nomark"
project "$DN" "$ALL" yes
mkdir -p "$DN/.specify/memory"
printf '# C\n\n## Core Principles\n\n### I. X\n\nprose, no marker\n' >"$DN/.specify/memory/constitution.md"
if [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; then
    healthy "constitution without markers -> not a doctor failure" "$(run_doctor "$DN")" "$LACK_ALL"
fi
if grep -q "no enforcement annotations" "$DN/out.txt"; then
    echo "PASS: doctor nudges an un-annotated constitution"
    PASS=$((PASS + 1))
else
    echo "FAIL: doctor missing the un-annotated nudge"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# A constitution whose markers are all satisfied adds no failure.
DE="$WORKDIR/const-ok"
project "$DE" "$ALL" yes
mkdir -p "$DE/.specify/memory" "$DE/.github/workflows"
printf 'jobs:\n  gates:\n    steps: []\n' >"$DE/.github/workflows/ci.yml"
cat >"$DE/.specify/memory/constitution.md" <<'EOF'
# C

## Core Principles

### I. Enforced
<!-- gates:enforce surface=ci ref=gates -->
x

### II. Prose
<!-- gates:enforce surface=prose -->
x
EOF
if [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; then
    healthy "all-enforced constitution -> doctor exit 0" "$(run_doctor "$DE")" "$LACK_ALL"
fi
if grep -q "I. Enforced" "$DE/out.txt" && grep -q "II. Prose" "$DE/out.txt"; then
    echo "PASS: doctor lists enforced and prose-only principles"
    PASS=$((PASS + 1))
else
    echo "FAIL: doctor did not list the principles"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# ===========================================================================
# Upgrade safety (#70): projection check, holds, CI drift. Line-level
# assertions: the fixture's overall exit also depends on host tooling.
# ===========================================================================
echo ""
echo "=== upgrade safety section (#70) ==="
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/fixture.sh"
has() { # <name> <dir> <fixed-string>: doctor output contains the line
    TOTAL=$((TOTAL + 1))
    if grep -qF -- "$3" "$2/out.txt"; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (no line containing: $3)"
        sed -n '/Upgrade safety/,/^$/p' "$2/out.txt" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
    fi
}
U="$(fx_project)"
(cd "$U" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
run_doctor "$U" >/dev/null
has "current projection reported" "$U" "[ok]  projection matches the installed extension"
has "no pipeline -> nudge" "$U" "no CI pipeline runs verify.sh --boundary ci"
printf '# local\n' >>"$U/.specify/gates/canary.sh"
run_doctor "$U" >/dev/null
has "an unheld local edit fails" "$U" "[MISSING] projected files were edited locally and are not held"
(cd "$U" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary --keep-local .specify/gates/canary.sh >/dev/null 2>&1)
run_doctor "$U" >/dev/null
has "a held edit is reported as kept" "$U" "[ok]  held: .specify/gates/canary.sh (differs from the installed extension, kept on purpose)"
has "and the projection is current again" "$U" "[ok]  projection matches the installed extension"
cp "$U/.specify/extensions/gates/runtime/canary.sh" "$U/.specify/gates/canary.sh"
run_doctor "$U" >/dev/null
has "a hold equal to upstream is stale and fails" "$U" "[MISSING] stale hold: .specify/gates/canary.sh"
printf '.specify/gates/hooks.local.d/x/1.sh\n' >"$U/.specify/gates/.upgrade-holds"
run_doctor "$U" >/dev/null
has "a hold inside hooks.local.d is redundant" "$U" "hooks.local.d is never touched by upgrades"
rm -f "$U/.specify/gates/.upgrade-holds"
mkdir -p "$U/.github/workflows"
printf 'steps:\n  - run: bash .specify/gates/verify.sh --boundary ci\n  - run: bash .specify/gates/canary.sh\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "a missing CI step fails" "$U" "[MISSING] CI pipeline lacks the 'pr' step from the template"
printf 'ci:pr\n' >"$U/.specify/gates/.upgrade-holds"
run_doctor "$U" >/dev/null
has "an acknowledged omission passes" "$U" "[ok]  CI step 'pr' omitted on purpose"
has "and the pipeline is otherwise complete" "$U" "[ok]  CI pipeline (.github/workflows/gates.yml) has every template step"
fx_cleanup "$U"
U="$(fx_project)"
(cd "$U" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary --no-agent-hooks >/dev/null 2>&1)
run_doctor "$U" >/dev/null
has "a --no-agent-hooks projection is checked as one" "$U" "[ok]  projection matches the installed extension"
fx_cleanup "$U"

echo ""
echo "=== constitution outside Core Principles (#82) ==="
DK="$WORKDIR/const82"
project "$DK" '{ "hooks": {} }' no
mkdir -p "$DK/.specify/memory"
printf '# C\n\n## Governance\n\n### Amendments\n<!-- gates:enforce surface=prose -->\n' >"$DK/.specify/memory/constitution.md"
run_doctor "$DK" >/dev/null
has "a marker outside Core Principles fails" "$DK" "[MISSING] constitution.md:6: malformed marker: gates:enforce marker outside Core Principles"
has "a missing Core Principles section is named" "$DK" "has no '## Core Principles' section"

echo ""
[[ "$SKIPPED" -gt 0 ]] && echo "$SKIPPED healthy-fixture case(s) skipped: this host lacks tools doctor requires."
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
