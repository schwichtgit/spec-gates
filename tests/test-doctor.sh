#!/bin/bash
set -euo pipefail

# doctor.sh: environment/prerequisite checks.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-doctor)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

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
echo "=== invalid policy is a failure, not 'not enabled' (#124) ==="
# <name> <policy-json> <needle>
doctor_invalid() {
    local d="$WORKDIR/invalid-$1"
    project "$d" "$2" yes
    expect "$1: doctor exits 1" "$(run_doctor "$d")" 1
    expect "$1: [MISSING] invalid policy" \
        "$(grep -qF '[MISSING] policy is invalid' "$d/out.txt" && echo yes || echo no)" yes
    expect "$1: the validator's error is shown" \
        "$(grep -qF -- "$3" "$d/out.txt" && echo yes || echo no)" yes
    expect "$1: no linter guessed as not enabled" \
        "$(grep -qF '(not enabled in policy)' "$d/out.txt" && echo yes || echo no)" no
}
doctor_invalid malformed '{"version":' 'is not valid JSON'
doctor_invalid empty-object '{}' 'top-level "hooks" object'
doctor_invalid severity-case '{ "hooks": { "prettier": {"include":["**/*.md"],"severity":"Error"} } }' 'invalid severity "Error"'

echo ""
echo "=== deprecated policy fields are flagged, not failed (#112) ==="
D="$WORKDIR/deprecated"
project "$D" '{ "hooks": { "shellcheck": {"include":["**/*.sh"],"orchestrator":"none","severity":"error"} } }' yes
RC_PLAIN="$(run_doctor "$D")"
TOTAL=$((TOTAL + 1))
if grep -q "has no effect (deprecated)" "$D/out.txt"; then
    echo "FAIL: flags a deprecated field the policy does not set"
    FAIL=$((FAIL + 1))
else
    echo "PASS: no deprecation line without the fields"
    PASS=$((PASS + 1))
fi
printf '%s' '{ "hooks": { "shellcheck": {"include":["**/*.sh"],"orchestrator":"none","severity":"error","on_missing_runner":"warn"}, "verify-quality": {"orchestrator":"none","severity":"error","on_missing_tests":"skip"} } }' \
    >"$D/.specify/gates/policy.json"
expect "deprecated fields do not change the exit code" "$(run_doctor "$D")" "$RC_PLAIN"
for f in shellcheck.on_missing_runner verify-quality.on_missing_tests; do
    TOTAL=$((TOTAL + 1))
    if grep -qF "[rec] hooks.$f has no effect (deprecated)" "$D/out.txt"; then
        echo "PASS: names hooks.$f"
        PASS=$((PASS + 1))
    else
        echo "FAIL: does not name hooks.$f"
        FAIL=$((FAIL + 1))
    fi
done

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
# git before 2.24 never runs pre-merge-commit (#148): a git that reports
# 2.23 gets the nudge, the real one does not.
expect "current git: no pre-merge-commit version nudge" \
    "$(grep -c 'never runs pre-merge-commit' "$GB/out.txt")" 0
OLDGIT="$WORKDIR/oldgit"
mkdir -p "$OLDGIT"
REALGIT="$(command -v git)"
# shellcheck disable=SC2016  # the wrapper script is written literally
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "git version 2.23.0"; exit 0; }\nexec "%s" "$@"\n' "$REALGIT" >"$OLDGIT/git"
chmod +x "$OLDGIT/git"
PATH="$OLDGIT:$PATH" run_doctor "$GB" >/dev/null
expect "git 2.23: doctor says pre-merge-commit never runs" \
    "$(grep -c 'git 2.23.0 is older than 2.24 and never runs pre-merge-commit' "$GB/out.txt")" 1
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
# A real install also registers the extension (otherwise it reads as an
# interrupted install, #74).
printf '{"extensions":{"gates":{"version":"9.9.9"}}}\n' >"$RV/.specify/extensions/.registry"
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
# doctor runs (and writes out.txt) on every host; only the exit-code case
# depends on the linters being installed, and healthy skips it visibly.
healthy "constitution without markers -> not a doctor failure" "$(run_doctor "$DN")" "$LACK_ALL"
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
printf 'on: push\njobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n      - run: bash .specify/gates/canary.sh\n      - run: bash .specify/gates/pr-check.sh\n' >"$DE/.github/workflows/ci.yml"
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
healthy "all-enforced constitution -> doctor exit 0" "$(run_doctor "$DE")" "$LACK_ALL"
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
lacks() { # <name> <dir> <fixed-string>: doctor output lacks the line
    TOTAL=$((TOTAL + 1))
    if grep -qF -- "$3" "$2/out.txt"; then
        echo "FAIL: $1 (unexpected line containing: $3)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $1"
        PASS=$((PASS + 1))
    fi
}
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
has "a held edit recommends the canary proof" "$U" "prove the gates still block: bash .specify/gates/doctor.sh --canary"
# The installed extension changes the held file (an upgrade): the hold now
# pins an old version, which doctor must say (#132).
printf '\n# newer upstream\n' >>"$U/.specify/extensions/gates/runtime/canary.sh"
run_doctor "$U" >/dev/null
has "a held file whose upstream changed is flagged" "$U" "[rec] held: .specify/gates/canary.sh — the installed extension changed this file since it was held"
cp "$U/.specify/extensions/gates/runtime/canary.sh" "$U/.specify/gates/canary.sh"
run_doctor "$U" >/dev/null
has "a hold equal to upstream is stale and fails" "$U" "[MISSING] stale hold: .specify/gates/canary.sh"
# project.sh --check exits 1 on the stale hold alone: the upgrade-safety
# line names the hold, not a re-projection that changes nothing (#214).
has "a stale hold is the named pending item" "$U" "[MISSING] stale holds — remove the lines listed below from .specify/gates/.upgrade-holds"
lacks "a stale hold is not called a stale projection" "$U" "the projection is not current"
printf '.specify/gates/hooks.local.d/x/1.sh\n' >"$U/.specify/gates/.upgrade-holds"
run_doctor "$U" >/dev/null
has "a hold inside hooks.local.d is redundant" "$U" "hooks.local.d is never touched by upgrades"
# A held deletion (#168) turns its check off: a missing agent hook exits
# 127, which Claude Code does not treat as a block.
printf '.claude/hooks/gates/protect-files.sh\n' >"$U/.specify/gates/.upgrade-holds"
mv "$U/.claude/hooks/gates/protect-files.sh" "$U/pf.sh.bak"
rc="$(run_doctor "$U")"
has "a held deletion fails" "$U" "[MISSING] held file is missing: .claude/hooks/gates/protect-files.sh"
has "and names the fix" "$U" "project.sh --take-upstream .claude/hooks/gates/protect-files.sh"
lacks "it is not reported as kept" "$U" "held: .claude/hooks/gates/protect-files.sh"
expect "doctor exits 1 on a held deletion" "$rc" "1"
rc=0
CLAUDE_PROJECT_DIR="$U" bash "$U/.specify/gates/doctor.sh" --ci >"$U/out.txt" 2>&1 || rc=$?
has "--ci: a held deletion fails" "$U" "[MISSING] held file is missing: .claude/hooks/gates/protect-files.sh"
expect "doctor --ci exits 1 on a held deletion" "$rc" "1"
# A held file emptied to 0 bytes is the same disablement (#203).
: >"$U/.claude/hooks/gates/protect-files.sh"
rc="$(run_doctor "$U")"
has "a held empty file fails" "$U" "[MISSING] held file is empty: .claude/hooks/gates/protect-files.sh"
lacks "the empty file is not reported as kept" "$U" "held: .claude/hooks/gates/protect-files.sh"
expect "doctor exits 1 on a held empty file" "$rc" "1"
mv "$U/pf.sh.bak" "$U/.claude/hooks/gates/protect-files.sh"
rm -f "$U/.specify/gates/.upgrade-holds"
mkdir -p "$U/.github/workflows"
printf 'on: push\njobs:\n  g:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n      - run: bash .specify/gates/canary.sh\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "a missing CI step fails" "$U" "[MISSING] CI pipeline lacks the 'pr' step from the template"
printf 'ci:pr\n' >"$U/.specify/gates/.upgrade-holds"
run_doctor "$U" >/dev/null
has "an acknowledged omission passes" "$U" "[ok]  CI step 'pr' omitted on purpose"
has "and the pipeline is otherwise complete" "$U" "[ok]  CI pipeline (.github/workflows/gates.yml) has every template step"
# ci: holds are judged like file holds (#139): one for a step the pipeline
# runs is stale, an id the template lacks is a stray line.
printf 'ci:canary\nci:bogus\n' >"$U/.specify/gates/.upgrade-holds"
run_doctor "$U" >/dev/null
has "a ci: hold for a step that runs is stale and fails" "$U" "[MISSING] stale hold: ci:canary but the pipeline runs the 'canary' step"
has "an unknown ci: id is flagged" "$U" "[rec] hold ci:bogus names no template step"
lacks "neither is reported as an omission" "$U" "omitted on purpose"
rm -f "$U/.specify/gates/.upgrade-holds"
# Commented-out and disabled steps are not wiring (#139).
cat >"$U/.github/workflows/gates.yml" <<'EOF'
on: push
jobs:
  gates:
    steps:
      - run: bash .specify/gates/verify.sh --boundary ci
      - name: Canaries
        run: "true"  # disabled: bash .specify/gates/canary.sh
      - name: PR
        if: false && github.event_name == 'pull_request'
        run: bash .specify/gates/pr-check.sh
EOF
run_doctor "$U" >/dev/null
has "a step whose command is only in a comment is missing" "$U" "[MISSING] CI pipeline lacks the 'canary' step"
has "an if: false step is missing" "$U" "[MISSING] CI pipeline lacks the 'pr' step"
rm -f "$U/.github/workflows/gates.yml"
printf 'gates:\n  script:\n    - bash .specify/gates/verify.sh --boundary ci\n    # - bash .specify/gates/canary.sh\n    - bash .specify/gates/pr-check.sh\n' >"$U/.gitlab-ci.yml"
run_doctor "$U" >/dev/null
has "a commented GitLab step is missing" "$U" "[MISSING] CI pipeline lacks the 'canary' step"
rm -f "$U/.gitlab-ci.yml"
cat >"$U/Jenkinsfile" <<'EOF'
stage('Gates') {
    steps {
        sh 'bash .specify/gates/verify.sh --boundary ci'
        // sh 'bash .specify/gates/canary.sh'
        /* sh 'bash .specify/gates/pr-check.sh'
        */
    }
}
EOF
run_doctor "$U" >/dev/null
has "a // comment in a Jenkinsfile is not a step" "$U" "[MISSING] CI pipeline lacks the 'canary' step"
has "nor is a /* */ comment" "$U" "[MISSING] CI pipeline lacks the 'pr' step"
printf "// sh 'bash .specify/gates/verify.sh --boundary ci'\n" >"$U/Jenkinsfile"
run_doctor "$U" >/dev/null
has "a commented-out verify step is no gates pipeline" "$U" "no CI pipeline runs verify.sh --boundary ci"
rm -f "$U/Jenkinsfile"
# A pipeline that calls verify.sh but runs no live gates step is a gap, not
# a nudge (#171): a job under if: false, another --boundary.
mkdir -p "$U/.github/workflows"
printf 'on: push\njobs:\n  gates:\n    if: false\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
CIBAD="[MISSING] CI pipeline .github/workflows/gates.yml calls verify.sh but no 'verify.sh --boundary ci' step is proven to run and fail it"
has "a job under if: false is a missing gates step" "$U" "$CIBAD: no step that runs and can fail calls it"
lacks "and not a nudge" "$U" "no CI pipeline runs verify.sh --boundary ci"
printf 'on: push\njobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary git\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "verify.sh with another --boundary is a missing gates step" "$U" "$CIBAD: the verify.sh command is not in a form"
# Each unproven form names what to change (#198).
printf 'on: workflow_call\njobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "a workflow_call-only trigger names the trigger" "$U" "$CIBAD: the workflow does not run on push or pull_request"
printf 'on: push\njobs:\n  gates:\n    steps:\n      - run: bash .specify/gates/verify.sh --boundary ci\n        env:\n          GATES_SPEC_EXEC: "1"\n' >"$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "a weakening env names the variable" "$U" "$CIBAD: it sets GATES_SPEC_EXEC or GATES_POLICY_FILE"
rm -f "$U/.github/workflows/gates.yml"
printf 'gates:\n  script:\n    - echo start\n  after_script:\n    - bash .specify/gates/verify.sh --boundary ci\n' >"$U/.gitlab-ci.yml"
run_doctor "$U" >/dev/null
has "an after_script step names the key" "$U" "calls verify.sh but no 'verify.sh --boundary ci' step is proven to run and fail it: an after_script: command cannot fail the job"
rm -f "$U/.gitlab-ci.yml"
printf "stage('G') {\n  steps {\n    catchError(buildResult: 'SUCCESS', stageResult: 'SUCCESS') {\n      sh 'bash .specify/gates/verify.sh --boundary ci'\n    }\n  }\n}\n" >"$U/Jenkinsfile"
run_doctor "$U" >/dev/null
has "a catchError-wrapped step names the wrappers" "$U" "outside catchError, warnError and try"
rm -f "$U/Jenkinsfile"
# The shipped templates stay live on every platform.
cp "$REPO_ROOT/extension/ci/github/gates.yml" "$U/.github/workflows/gates.yml"
run_doctor "$U" >/dev/null
has "the GitHub template runs every step" "$U" "[ok]  CI pipeline (.github/workflows/gates.yml) has every template step"
rm -f "$U/.github/workflows/gates.yml"
cp "$REPO_ROOT/extension/ci/gitlab/gates.gitlab-ci.yml" "$U/.gitlab-ci.yml"
run_doctor "$U" >/dev/null
has "the GitLab template runs every step" "$U" "[ok]  CI pipeline (.gitlab-ci.yml) has every template step"
rm -f "$U/.gitlab-ci.yml"
cp "$REPO_ROOT/extension/ci/jenkins/Jenkinsfile.gates" "$U/Jenkinsfile"
run_doctor "$U" >/dev/null
has "the Jenkins template runs every step" "$U" "[ok]  CI pipeline (Jenkinsfile) has every template step"
rm -f "$U/Jenkinsfile"

# Inert forms a text check can recognize (#171), read the way doctor and the
# constitution ci surface read them: the fixture runs the gates step or not.
CIF="$WORKDIR/ci-forms"
# Called as `ci_form ... < <(printf ...)`, never at the end of a pipe: a
# piped function runs in a subshell and its counts would be lost.
ci_form() { # <name> <live|inert> <path under $CIF>; pipeline text on stdin
    mkdir -p "$(dirname "$CIF/$3")"
    cat >"$CIF/$3"
    local got
    got="$(bash -c 'source "$1/extension/runtime/lib/manifest.sh"
        if [[ -z "$(gates_ci_unproven "$2")" ]]; then echo live; else echo inert; fi' \
        _ "$REPO_ROOT" "$CIF/$3")"
    expect "ci step: $1" "$got" "$2"
    rm -f "$CIF/$3"
}
GHW=.github/workflows/ci.yml
GHJ='on: [push]
jobs:
  g:
    steps:'
V='bash .specify/gates/verify.sh --boundary ci'
ci_form "a plain step is live" live "$GHW" < <(printf '%s\n      - run: %s\n' "$GHJ" "$V")
ci_form "echo prints the command" inert "$GHW" < <(printf '%s\n      - run: echo %s\n' "$GHJ" "$V")
ci_form "a quoted echo prints it" inert "$GHW" < <(printf '%s\n      - run: "echo %s"\n' "$GHJ" "$V")
ci_form "a command after an echo is not proven" inert "$GHW" < <(printf '%s\n      - run: echo start && %s\n' "$GHJ" "$V")
ci_form "|| true swallows the failure" inert "$GHW" < <(printf '%s\n      - run: %s || true\n' "$GHJ" "$V")
ci_form "|| : swallows the failure" inert "$GHW" < <(printf '%s\n      - run: %s || :\n' "$GHJ" "$V")
ci_form "&& ... || true swallows it too" inert "$GHW" < <(printf '%s\n      - run: %s && echo ok || true\n' "$GHJ" "$V")
ci_form "|| { ...; exit 1; } is not proven" inert "$GHW" < <(printf '%s\n      - run: %s || { echo failed; exit 1; }\n' "$GHJ" "$V")
ci_form "continue-on-error on the step" inert "$GHW" < <(printf '%s\n      - run: %s\n        continue-on-error: true\n' "$GHJ" "$V")
# shellcheck disable=SC2016  # literal pipeline text
ci_form "continue-on-error on the job" inert "$GHW" < <(printf 'on: push\njobs:\n  g:\n    continue-on-error: ${{ true }}\n    steps:\n      - run: %s\n' "$V")
ci_form "continue-on-error: false" live "$GHW" < <(printf '%s\n      - run: %s\n        continue-on-error: false\n' "$GHJ" "$V")
ci_form "--dry-run" inert "$GHW" < <(printf '%s\n      - run: %s --dry-run\n' "$GHJ" "$V")
ci_form "--boundary ci after another flag" live "$GHW" < <(printf '%s\n      - run: bash .specify/gates/verify.sh --json --boundary ci\n' "$GHJ")
ci_form "a boundary that only starts with ci" inert "$GHW" < <(printf '%s\n      - run: bash .specify/gates/verify.sh --boundary ci-skip\n' "$GHJ")
ci_form "exit 0 earlier in the run block" inert "$GHW" < <(printf '%s\n      - run: |\n          exit 0\n          %s\n' "$GHJ" "$V")
ci_form "exit 0; on the same line" inert "$GHW" < <(printf '%s\n      - run: exit 0; %s\n' "$GHJ" "$V")
# shellcheck disable=SC2016  # literal pipeline text
ci_form "a conditional exit 0" inert "$GHW" < <(printf '%s\n      - run: test -n "$SKIP" && exit 0; %s\n' "$GHJ" "$V")
# shellcheck disable=SC2016  # literal pipeline text
ci_form "exit 0 inside an if" inert "$GHW" < <(printf '%s\n      - run: |\n          if [ -n "$SKIP" ]; then\n          exit 0\n          fi\n          %s\n' "$GHJ" "$V")
ci_form "a heredoc before it" inert "$GHW" < <(printf '%s\n      - run: |\n          cat <<EOF\n          exit 0\n          EOF\n          %s\n' "$GHJ" "$V")
ci_form "exit 0 in another step" live "$GHW" < <(printf '%s\n      - run: exit 0\n      - run: %s\n' "$GHJ" "$V")
ci_form "a workflow_dispatch-only workflow" inert "$GHW" < <(printf 'on: workflow_dispatch\njobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "dispatch and schedule only" inert "$GHW" < <(printf 'on: [workflow_dispatch, schedule]\njobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "a block on: with dispatch and schedule only" inert "$GHW" < <(printf "on:\n  workflow_dispatch:\n  schedule:\n    - cron: '0 0 * * *'\njobs:\n  g:\n    steps:\n      - run: %s\n" "$V")
ci_form "dispatch plus push" live "$GHW" < <(printf 'on:\n  workflow_dispatch:\n  push:\n    branches: [main]\njobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "no on: key at all" inert "$GHW" < <(printf 'jobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "a GitLab job" live .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - %s\n' "$V")
ci_form "a GitLab hidden job" inert .gitlab-ci.yml < <(printf '.gates:\n  script:\n    - %s\n' "$V")
ci_form "a hidden job another extends" live .gitlab-ci.yml < <(printf '.gates:\n  script:\n    - %s\njob:\n  extends: .gates\n' "$V")
ci_form "a hidden job used by an alias" live .gitlab-ci.yml < <(printf '.gates: &g\n  script:\n    - %s\njob:\n  <<: *g\n' "$V")
ci_form "rules: - when: never" inert .gitlab-ci.yml < <(printf 'gates:\n  rules:\n    - when: never\n  script:\n    - %s\n' "$V")
ci_form "a conditional when: never rule" live .gitlab-ci.yml < <(printf "gates:\n  rules:\n    - if: '\$X'\n      when: never\n    - when: always\n  script:\n    - %s\n" "$V")
ci_form "when: never after a matching rule" live .gitlab-ci.yml < <(printf "gates:\n  rules:\n    - if: '\$CI_COMMIT_BRANCH'\n    - when: never\n  script:\n    - %s\n" "$V")
ci_form "a manual GitLab job" inert .gitlab-ci.yml < <(printf 'gates:\n  when: manual\n  script:\n    - %s\n' "$V")
ci_form "allow_failure: true" inert .gitlab-ci.yml < <(printf 'gates:\n  allow_failure: true\n  script:\n    - %s\n' "$V")
ci_form "exit 0 earlier in the script" inert .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - exit 0\n    - %s\n' "$V")
ci_form "exit 0 ends its own job only" live .gitlab-ci.yml < <(printf 'gates:\n  script:\n  - exit 0\n  - %s\nother:\n  script:\n  - %s\n' "$V" "$V")
ci_form "a conditional exit in an earlier item" inert .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - if [ -f x ]; then exit 0; fi\n    - %s\n' "$V")
ci_form "a Jenkins stage" live Jenkinsfile < <(printf "stage('G') { steps { sh '%s' } }\n" "$V")
ci_form "when { expression { false } }" inert Jenkinsfile < <(printf "stage('G') {\n  when { expression { false } }\n  steps {\n    sh '%s'\n  }\n}\n" "$V")
ci_form "when { expression { return false } }" inert Jenkinsfile < <(printf "stage('G') {\n  when {\n    expression { return false }\n  }\n  steps {\n    sh '%s'\n  }\n}\n" "$V")
ci_form "a Jenkins when on a branch" live Jenkinsfile < <(printf "stage('G') {\n  when { branch 'main' }\n  steps {\n    sh \"%s\"\n  }\n}\n" "$V")
ci_form "Jenkins || true" inert Jenkinsfile < <(printf "stage('G') { steps { sh '%s || true' } }\n" "$V")
ci_form "Jenkins echo" inert Jenkinsfile < <(printf "stage('G') { steps { sh 'echo %s' } }\n" "$V")
ci_form "Jenkins returnStatus: true" inert Jenkinsfile < <(printf "stage('G') { steps { sh script: '%s', returnStatus: true } }\n" "$V")
# Only a provable form counts (#198): the forms below can all pass with the
# gates failing, or cannot be shown not to.
ci_form "; exit 0 after it" inert "$GHW" < <(printf '%s\n      - run: %s; exit 0\n' "$GHJ" "$V")
ci_form "; true after it" inert "$GHW" < <(printf '%s\n      - run: %s; true\n' "$GHJ" "$V")
ci_form "true || before it" inert "$GHW" < <(printf '%s\n      - run: true || %s\n' "$GHJ" "$V")
ci_form "a quoted : no-op" inert "$GHW" < <(printf '%s\n      - run: ": %s"\n' "$GHJ" "$V")
ci_form "run in the background" inert "$GHW" < <(printf '%s\n      - run: %s &\n' "$GHJ" "$V")
ci_form "an if condition" inert "$GHW" < <(printf '%s\n      - run: if %s; then echo ok; fi\n' "$GHJ" "$V")
ci_form "a second --boundary" inert "$GHW" < <(printf '%s\n      - run: %s --boundary agent\n' "$GHJ" "$V")
ci_form "an env prefix" inert "$GHW" < <(printf '%s\n      - run: GATES_X=1 %s\n' "$GHJ" "$V")
ci_form "GATES_SPEC_EXEC in the step env" inert "$GHW" < <(printf '%s\n      - run: %s\n        env:\n          GATES_SPEC_EXEC: "1"\n' "$GHJ" "$V")
ci_form "GATES_POLICY_FILE in the workflow env" inert "$GHW" < <(printf 'env:\n  GATES_POLICY_FILE: x.json\n%s\n      - run: %s\n' "$GHJ" "$V")
ci_form "a workflow_call-only trigger" inert "$GHW" < <(printf 'on: workflow_call\njobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "a pull_request trigger" live "$GHW" < <(printf 'on:\n  pull_request:\njobs:\n  g:\n    steps:\n      - run: %s\n' "$V")
ci_form "the command in quotes" live "$GHW" < <(printf '%s\n      - run: "%s"\n' "$GHJ" "$V")
ci_form "--json after --boundary ci" live "$GHW" < <(printf '%s\n      - run: .specify/gates/verify.sh --boundary ci --json\n' "$GHJ")
ci_form "the last line of a run block" live "$GHW" < <(printf '%s\n      - run: |\n          set -e\n          npm ci\n          %s\n' "$GHJ" "$V")
ci_form "a line followed by another" inert "$GHW" < <(printf '%s\n      - run: |\n          %s\n          echo done\n' "$GHJ" "$V")
ci_form "a trap before it" inert "$GHW" < <(printf "%s\n      - run: |\n          trap 'exit 0' EXIT\n          %s\n" "$GHJ" "$V")
ci_form "a continuation into it" inert "$GHW" < <(printf '%s\n      - run: |\n          echo \\\n          %s\n' "$GHJ" "$V")
ci_form "GitLab ; exit 0 after it" inert .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - %s; exit 0\n' "$V")
ci_form "GitLab only: [tags]" inert .gitlab-ci.yml < <(printf 'gates:\n  only: [tags]\n  script:\n    - %s\n' "$V")
ci_form "GitLab only: a branch name" live .gitlab-ci.yml < <(printf 'gates:\n  only:\n    - main\n  script:\n    - %s\n' "$V")
ci_form "GitLab only: refs: [merge_requests]" live .gitlab-ci.yml < <(printf 'gates:\n  only:\n    refs:\n      - merge_requests\n  script:\n    - %s\n' "$V")
ci_form "GitLab except: [branches, merge_requests]" inert .gitlab-ci.yml < <(printf 'gates:\n  except: [branches, merge_requests]\n  script:\n    - %s\n' "$V")
ci_form "GitLab except: [branches]" inert .gitlab-ci.yml < <(printf 'gates:\n  except:\n    - branches\n  script:\n    - %s\n' "$V")
ci_form "GitLab except: [merge_requests]" live .gitlab-ci.yml < <(printf 'gates:\n  except: [merge_requests]\n  script:\n    - %s\n' "$V")
ci_form "GitLab workflow rules: - when: never" inert .gitlab-ci.yml < <(printf 'workflow:\n  rules:\n    - when: never\ngates:\n  script:\n    - %s\n' "$V")
ci_form "GitLab workflow rules that can match" live .gitlab-ci.yml < <(printf "workflow:\n  rules:\n    - if: '\$CI_COMMIT_BRANCH'\ngates:\n  script:\n    - %s\n" "$V")
ci_form "GitLab rules all conditional never" inert .gitlab-ci.yml < <(printf "gates:\n  rules:\n    - if: '\$A'\n      when: never\n    - if: '\$B'\n      when: manual\n  script:\n    - %s\n" "$V")
ci_form "GitLab after_script" inert .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - echo hi\n  after_script:\n    - %s\n' "$V")
ci_form "GitLab before_script" live .gitlab-ci.yml < <(printf 'gates:\n  before_script:\n    - %s\n  script:\n    - echo hi\n' "$V")
ci_form "GitLab variables: GATES_SPEC_EXEC" inert .gitlab-ci.yml < <(printf 'gates:\n  variables:\n    GATES_SPEC_EXEC: "1"\n  script:\n    - %s\n' "$V")
ci_form "GitLab last line of a - | block" live .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - |\n      npm ci\n      %s\n' "$V")
ci_form "GitLab a - | block line followed by another" inert .gitlab-ci.yml < <(printf 'gates:\n  script:\n    - |\n      %s\n      echo done\n' "$V")
ci_form "Jenkins catchError" inert Jenkinsfile < <(printf "stage('G') {\n  steps {\n    catchError(buildResult: 'SUCCESS', stageResult: 'SUCCESS') {\n      sh '%s'\n    }\n  }\n}\n" "$V")
ci_form "Jenkins try/catch" inert Jenkinsfile < <(printf "stage('G') {\n  steps {\n    script {\n      try {\n        sh '%s'\n      } catch (e) {}\n    }\n  }\n}\n" "$V")
ci_form "Jenkins after a try block" live Jenkinsfile < <(printf "stage('G') {\n  steps {\n    script {\n      try { sh 'make' } catch (e) {}\n    }\n    sh '%s'\n  }\n}\n" "$V")
ci_form "Jenkins ; exit 0 after it" inert Jenkinsfile < <(printf "stage('G') { steps { sh '%s; exit 0' } }\n" "$V")
ci_form "Jenkins sh(script: ...)" live Jenkinsfile < <(printf "stage('G') { steps { sh(script: '%s') } }\n" "$V")
ci_form "Jenkins last line of a ''' script" live Jenkinsfile < <(printf "stage('G') {\n  steps {\n    sh '''\n      npm ci\n      %s\n    '''\n  }\n}\n" "$V")
ci_form "Jenkins a ''' line followed by another" inert Jenkinsfile < <(printf "stage('G') {\n  steps {\n    sh '''\n      %s\n      echo done\n    '''\n  }\n}\n" "$V")
ci_form "Jenkins withEnv GATES_POLICY_FILE" inert Jenkinsfile < <(printf "stage('G') {\n  steps {\n    withEnv(['GATES_POLICY_FILE=x.json']) {\n      sh '%s'\n    }\n  }\n}\n" "$V")
fx_cleanup "$U"
U="$(fx_project)"
(cd "$U" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary --no-agent-hooks >/dev/null 2>&1)
run_doctor "$U" >/dev/null
has "a --no-agent-hooks projection is checked as one" "$U" "[ok]  projection matches the installed extension"
fx_cleanup "$U"

# #216: callers that run verify.sh without --boundary get a [rec]; the
# ones that pass it, comments and a continued --boundary do not.
echo ""
echo "=== callers without --boundary (#216) ==="
U="$(fx_project)"
(cd "$U" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
cat >"$U/package.json" <<'EOF'
{
  "scripts": {
    "gates": "bash .specify/gates/verify.sh",
    "gates:ci": "bash .specify/gates/verify.sh --boundary ci",
    "both": "bash .specify/gates/verify.sh --json && bash .specify/gates/verify.sh --boundary ci"
  }
}
EOF
printf 'gates:\n\tbash .specify/gates/verify.sh \\\n\t  --boundary ci\n# bash .specify/gates/verify.sh\nold:\n\t./.specify/gates/verify.sh --json\n' >"$U/Makefile"
printf 'tasks:\n  gates:\n    cmds:\n      - bash .specify/gates/verify.sh --boundary agent\n      - bash .specify/gates/verify.sh\n' >"$U/Taskfile.yml"
run_doctor "$U" >/dev/null
has "package.json script without --boundary -> rec" "$U" "[rec] package.json:3 runs verify.sh without --boundary"
has "a chained call without --boundary -> rec" "$U" "[rec] package.json:5 runs verify.sh without --boundary"
has "the rec names the fix" "$U" "add --boundary agent|git|ci"
has "Makefile recipe without --boundary -> rec" "$U" "[rec] Makefile:6 runs verify.sh without --boundary"
has "Taskfile command without --boundary -> rec" "$U" "[rec] Taskfile.yml:5 runs verify.sh without --boundary"
lacks "a script with --boundary is not named" "$U" "package.json:4 runs"
lacks "a continued --boundary is not named" "$U" "Makefile:2 runs"
lacks "a comment is not named" "$U" "Makefile:4 runs"
lacks "a Taskfile command with --boundary is not named" "$U" "Taskfile.yml:4 runs"
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
echo "=== install hygiene (#73) ==="
IH="$(fx_project)"
(cd "$IH" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
jq '.extensions.gates.registered_commands.claude = ["speckit.gates.doctor", "speckit.gates.init", "speckit.gates.verify", "speckit.gates.ci"]' \
    "$IH/.specify/extensions/.registry" >"$IH/reg.tmp" && mv "$IH/reg.tmp" "$IH/.specify/extensions/.registry"
mkdir -p "$IH/.claude/skills/speckit-gates-doctor" "$IH/.claude/commands" "$IH/elsewhere"
printf 'skill\n' >"$IH/.claude/skills/speckit-gates-doctor/SKILL.md"
printf 'command\n' >"$IH/.claude/commands/speckit.gates.init.md"
printf 'real\n' >"$IH/elsewhere/SKILL.md"
mkdir -p "$IH/.claude/skills/speckit-gates-verify"
ln -s "$IH/elsewhere/SKILL.md" "$IH/.claude/skills/speckit-gates-verify/SKILL.md"
ln -s "$IH/elsewhere/missing-dir" "$IH/.claude/skills/speckit-gates-ci"
run_doctor "$IH" >/dev/null
has "regular skill and command files pass" "$IH" "[ok]  2 registered gates command(s) installed as regular files"
has "a symlinked skill fails" "$IH" "[MISSING] speckit.gates.verify is a symlink"
has "a dangling skill fails" "$IH" "[MISSING] speckit.gates.ci is a dangling symlink"
jq '.extensions.gates.registered_commands.claude += ["speckit.gates.sync"]' \
    "$IH/.specify/extensions/.registry" >"$IH/reg.tmp" && mv "$IH/reg.tmp" "$IH/.specify/extensions/.registry"
run_doctor "$IH" >/dev/null
has "a registered command with no file fails" "$IH" "[MISSING] speckit.gates.sync is registered but has no skill or command file"
mkdir -p "$IH/.specify/extensions/gates/.specify-dev"
chmod 644 "$IH/.specify/extensions/gates/runtime/hooks/git/pre-commit"
run_doctor "$IH" >/dev/null
has "a --dev install is flagged" "$IH" "[rec] this is a --dev install"
has "vendored scripts without +x are flagged" "$IH" "1 installed extension script(s) lack the execute bit"
fx_cleanup "$IH"
echo ""
echo "=== git probe and --installed-only (#74) ==="
GPD="$(fx_project)"
(cd "$GPD" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
run_doctor "$GPD" >/dev/null
has "a wired stub passes the probe (pre-commit)" "$GPD" "[ok]  pre-commit probe: the hook git runs reaches the gates pre-commit hook"
has "a wired stub passes the probe (commit-msg)" "$GPD" "[ok]  commit-msg probe: the hook git runs reaches the gates commit-msg hook"
printf '#!/bin/sh\nexit 0\n' >"$GPD/.git/hooks/commit-msg"
chmod +x "$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
has "another tool's hook without the call-through fails (static)" "$GPD" "[MISSING] commit-msg (static): git runs .git/hooks/commit-msg, owned by another tool, and it does not call .specify/gates/hooks/commit-msg on a line that runs"
# A foreign hook that leaves a trace when it runs: doctor must not run it.
# shellcheck disable=SC2016  # the hook body is written literally
printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/ran.txt"\nexec bash "$(git rev-parse --show-toplevel)/.specify/gates/hooks/commit-msg" "$@"\n' >"$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
has "a foreign hook with the call-through passes (static)" "$GPD" "[ok]  commit-msg (static): another tool owns the hook and calls the gates commit-msg hook"
expect "doctor does not run a hook another tool owns" "$([[ -e "$GPD/ran.txt" ]] && echo ran || echo not-run)" "not-run"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git runs the full chain and it reaches gates" "$GPD" "[ok]  commit-msg probe: the hook git runs reaches the gates commit-msg hook"
expect "--probe-git did run the foreign hook" "$([[ -e "$GPD/ran.txt" ]] && echo ran || echo not-run)" "ran"
rm -f "$GPD/ran.txt"
# The probe calls hooks the way git does (#127). The pre-commit framework's
# hook refuses any argument; lefthook's gets `--job <gates job>` (passed on
# to `lefthook run`) so no other job runs, and no --force (#167): --force
# also ran jobs that rewrite files.
# shellcheck disable=SC2016  # the hook bodies are written literally
printf '#!/bin/sh\n# File generated by pre-commit\n[ $# -eq 0 ] || { echo "hook-impl for pre-commit expected 0 arguments but got $#" >&2; exit 1; }\nexec bash .specify/gates/hooks/pre-commit\n' >"$GPD/.git/hooks/pre-commit"
chmod +x "$GPD/.git/hooks/pre-commit"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: a pre-commit hook gets no arguments" "$GPD" "[ok]  pre-commit probe: the hook git runs reaches the gates pre-commit hook"
# shellcheck disable=SC2016
printf '#!/bin/sh\n# lefthook\ncase " $* " in *" --force "*) touch lint-ran.txt ;; esac\ncase " $* " in *" --job spec-gates "*) exec bash .specify/gates/hooks/pre-commit ;; esac\necho "lint (skip) no files for inspection"\n' >"$GPD/.git/hooks/pre-commit"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: lefthook runs the gates job alone" "$GPD" "[ok]  pre-commit probe: the hook git runs reaches the gates pre-commit hook"
expect "--probe-git: lefthook gets no --force (other jobs stay idle)" "$([[ -e "$GPD/lint-ran.txt" ]] && echo ran || echo not-run)" "not-run"
# The job name comes from the config the hook reads.
printf 'pre-commit:\n  jobs:\n    - name: lint\n      run: npx markdownlint-cli2 --fix {staged_files}\n    - name: my-gates\n      run: "bash .specify/gates/hooks/pre-commit # {files}"\n      files: echo lefthook.yml\n' >"$GPD/lefthook.yml"
# shellcheck disable=SC2016
printf '#!/bin/sh\n# lefthook\ncase " $* " in *" --job my-gates "*) exec bash .specify/gates/hooks/pre-commit ;; esac\necho "Error: no job matching spec-gates found"\n' >"$GPD/.git/hooks/pre-commit"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: lefthook runs the job the config names" "$GPD" "[ok]  pre-commit probe: the hook git runs reaches the gates pre-commit hook"
rm -f "$GPD/lefthook.yml"
# shellcheck disable=SC2016
printf '#!/bin/sh\n# lefthook\necho "spec-gates (skip) no matching staged files"\n' >"$GPD/.git/hooks/pre-commit"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: a lefthook skip is named" "$GPD" "lefthook skips the gates job while nothing is staged"
cp "$GPD/.specify/extensions/gates/runtime/hooks/git/stub.sh" "$GPD/.git/hooks/pre-commit"
rm -f "$GPD/ran.txt"
# A call-through that never runs does not count (#128), and a hook that
# merely mentions "gates" is not one that delegates to it.
printf '#!/bin/sh\n# delegates to gates later\nexit 0\n' >"$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
expect "a hook mentioning gates is not reported as delegating" \
    "$(grep -c 'commit-msg installed, executable, delegates to the gates runtime' "$GPD/out.txt")" "0"
has "a hook mentioning gates gets the not-calling note" "$GPD" "[rec] commit-msg is executable but does not call .specify/gates/hooks/commit-msg itself"
for body in '#!/bin/sh\n# bash .specify/gates/hooks/commit-msg "$@"\n' \
    '#!/bin/sh\nexit 0\nbash .specify/gates/hooks/commit-msg "$@"\n' \
    '#!/bin/sh\nexit\nbash .specify/gates/hooks/commit-msg "$@"\n'; do
    # shellcheck disable=SC2059  # the body carries the newline escapes
    printf "$body" >"$GPD/.git/hooks/commit-msg"
    run_doctor "$GPD" >/dev/null
    has "a call-through that never runs fails the static check" "$GPD" "[MISSING] commit-msg (static)"
done
# shellcheck disable=SC2016  # the hook body is written literally
printf '#!/bin/sh\nif [ -n "$SKIP" ]; then\n  exit 0\nfi\nbash .specify/gates/hooks/commit-msg "$@"\n' >"$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
has "an exit inside a block does not hide the call-through" "$GPD" "[ok]  commit-msg (static)"
has "a hook that calls the gates hook is reported as delegating" "$GPD" "[ok]  commit-msg installed, executable, delegates to the gates runtime"
# A plain script exits with its last command's status (#202): a call-through
# followed by more commands, without set -e, cannot refuse the commit. The
# probe proves it from the exit status of the hook git runs, not from the
# marker alone.
# shellcheck disable=SC2016  # the hook bodies are written literally
printf '#!/bin/sh\nbash .specify/gates/hooks/commit-msg "$@"\necho done\n' >"$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
has "a call-through whose status a later command replaces fails (static)" "$GPD" "[MISSING] commit-msg (static): git runs .git/hooks/commit-msg, owned by another tool, and it calls .specify/gates/hooks/commit-msg as"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: a refusal that does not reach git fails" "$GPD" "[MISSING] commit-msg (probe): git runs .git/hooks/commit-msg and it reaches the gates commit-msg hook, but it exits 0 although the gates hook refused"
# shellcheck disable=SC2016
printf '#!/bin/sh\nbash .specify/gates/hooks/commit-msg "$@" || true\n' >"$GPD/.git/hooks/commit-msg"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: a refusal masked by || true fails" "$GPD" "[MISSING] commit-msg (probe): git runs .git/hooks/commit-msg and it reaches the gates commit-msg hook, but it exits 0"
# shellcheck disable=SC2016
printf '#!/bin/sh\nset -e\nbash .specify/gates/hooks/commit-msg "$@"\necho done\n' >"$GPD/.git/hooks/commit-msg"
run_doctor "$GPD" >/dev/null
has "a call-through under set -e passes (static)" "$GPD" "[ok]  commit-msg (static)"
CLAUDE_PROJECT_DIR="$GPD" bash "$GPD/.specify/gates/doctor.sh" --probe-git >"$GPD/out.txt" 2>&1 || true
has "--probe-git: a refusal that reaches git passes" "$GPD" "[ok]  commit-msg probe: the hook git runs reaches the gates commit-msg hook, and its refusal reaches git"
# husky layout: generated shims in .husky/_, the call-through in .husky/<hook>.
mkdir -p "$GPD/.husky/_"
printf '#!/bin/sh\ntouch ran.txt\nexit 1\n' >"$GPD/.husky/_/commit-msg"
chmod +x "$GPD/.husky/_/commit-msg"
# shellcheck disable=SC2016  # the husky script is written literally
printf 'npx --no -- commitlint --edit "$1"\nbash .specify/gates/hooks/commit-msg "$@"\n' >"$GPD/.husky/commit-msg"
git -C "$GPD" config core.hooksPath .husky/_
run_doctor "$GPD" >/dev/null
has "husky: the call-through in .husky/<hook> passes (static)" "$GPD" "[ok]  commit-msg (static)"
expect "husky: doctor did not run the husky chain" "$([[ -e "$GPD/ran.txt" ]] && echo ran || echo not-run)" "not-run"
# husky 8 layout (#159): git runs .husky/<hook> itself, so a script without
# the execute bit is skipped although it calls the gates hook.
chmod 644 "$GPD/.husky/commit-msg"
git -C "$GPD" config core.hooksPath .husky
run_doctor "$GPD" >/dev/null
has "husky 8: a non-executable .husky/<hook> is flagged" "$GPD" "[MISSING] commit-msg installed but NOT executable"
expect "husky 8: no static pass for a hook git skips" "$(grep -c '\[ok\]  commit-msg (static)' "$GPD/out.txt")" "0"
chmod +x "$GPD/.husky/commit-msg"
run_doctor "$GPD" >/dev/null
has "husky 8: an executable .husky/<hook> passes (static)" "$GPD" "[ok]  commit-msg (static)"
lacks "husky 8: a wired manager hook gets no another-tool note (#167)" "$GPD" "commit-msg is executable but does not call"
# Lines after `exec <command>` or a one-line `if ...; then exit` never run
# (#167); `exec` with only redirections does not end the script.
# shellcheck disable=SC2016  # the husky scripts are written literally
for body in 'exec npm test\nbash .specify/gates/hooks/commit-msg "$@"\n' \
    'if true; then exit 0; fi\nbash .specify/gates/hooks/commit-msg "$@"\n'; do
    # shellcheck disable=SC2059  # the body carries the newline escapes
    printf "$body" >"$GPD/.husky/commit-msg"
    run_doctor "$GPD" >/dev/null
    has "husky: a call-through after the script ends fails (static)" "$GPD" "[MISSING] commit-msg (static)"
done
# shellcheck disable=SC2016
printf 'exec 2>&1\nbash .specify/gates/hooks/commit-msg "$@"\n' >"$GPD/.husky/commit-msg"
run_doctor "$GPD" >/dev/null
has "husky: exec with only a redirection does not end the scan" "$GPD" "[ok]  commit-msg (static)"
# A call-through counts only as a whole command whose status reaches git
# (#202): masked, backgrounded or never-run forms fail, and say so.
# shellcheck disable=SC2016  # the husky scripts are written literally
for body in 'bash .specify/gates/hooks/commit-msg "$@" || true\n' \
    'bash .specify/gates/hooks/commit-msg "$@" &\n' \
    'true || bash .specify/gates/hooks/commit-msg "$@"\n' \
    'echo bash .specify/gates/hooks/commit-msg\n' \
    ': bash .specify/gates/hooks/commit-msg\n'; do
    # shellcheck disable=SC2059  # the body carries the newline escapes
    printf "$body" >"$GPD/.husky/commit-msg"
    run_doctor "$GPD" >/dev/null
    has "husky: a call-through that cannot refuse fails (static)" "$GPD" "[MISSING] commit-msg (static): git runs .husky/commit-msg, owned by husky, and .husky/commit-msg calls .specify/gates/hooks/commit-msg only as"
done
# shellcheck disable=SC2016
printf 'bash .specify/gates/hooks/commit-msg "$@" || exit $?\n' >"$GPD/.husky/commit-msg"
run_doctor "$GPD" >/dev/null
has "husky: a call-through followed by || exit passes (static)" "$GPD" "[ok]  commit-msg (static)"
# Only the config of the manager that runs the hook counts (#167): husky
# owns commit-msg, so a stale .pre-commit-config.yaml calling gates does not.
printf 'npm test\n' >"$GPD/.husky/commit-msg"
printf 'repos:\n- repo: local\n  hooks:\n  - id: g\n    entry: bash .specify/gates/hooks/commit-msg\n    language: system\n    stages: [commit-msg]\n' >"$GPD/.pre-commit-config.yaml"
run_doctor "$GPD" >/dev/null
has "husky owns the hook: a stale pre-commit config does not pass" "$GPD" "[MISSING] commit-msg (static): git runs .husky/commit-msg, owned by husky"
rm -f "$GPD/.pre-commit-config.yaml"
git -C "$GPD" config --unset core.hooksPath
fx_cleanup "$GPD"

echo ""
echo "=== manager config read per hook (#167) ==="
GMW="$(fx_project)"
(cd "$GMW" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
# lefthook: generated hooks in .git/hooks; doctor reads lefthook.yml.
for h in pre-commit pre-merge-commit commit-msg; do
    printf '#!/bin/sh\n# lefthook generated\ntouch ran.txt\n' >"$GMW/.git/hooks/$h"
    chmod +x "$GMW/.git/hooks/$h"
done
lh_ok='pre-merge-commit:\n  commands:\n    spec-gates:\n      run: bash .specify/gates/hooks/pre-merge-commit\ncommit-msg:\n  commands:\n    spec-gates:\n      run: bash .specify/gates/hooks/commit-msg {1}\n'
# shellcheck disable=SC2059  # the YAML carries the newline escapes
printf "pre-commit:\n  commands:\n    lint:\n      run: echo user-lint\npre-push:\n  commands:\n    spec-gates:\n      run: bash .specify/gates/hooks/pre-commit\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: a call-through under another hook key fails" "$GMW" "[MISSING] pre-commit (static): git runs .git/hooks/pre-commit, owned by lefthook, and lefthook.yml calls .specify/gates/hooks/pre-commit only outside its pre-commit: block"
has "lefthook: the other hooks pass" "$GMW" "[ok]  commit-msg (static)"
lacks "lefthook: a wired hook gets no another-tool note" "$GMW" "commit-msg is executable but does not call"
# shellcheck disable=SC2059
printf "pre-commit:\n  commands:\n    spec-gates:\n      skip: true\n      run: \"bash .specify/gates/hooks/pre-commit # {files}\"\n      files: echo lefthook.yml\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: a skipped job fails" "$GMW" "but skip:/only: is set on the job or the pre-commit hook"
# shellcheck disable=SC2059
printf "pre-commit:\n  commands:\n    spec-gates:\n      run: bash .specify/gates/hooks/pre-commit\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: a pre-commit job skipped while nothing is staged fails" "$GMW" "but lefthook skips that job while nothing is staged"
# shellcheck disable=SC2059
printf "pre-commit:\n  commands:\n    spec-gates:\n      run: \"bash .specify/gates/hooks/pre-commit # {files}\"\n      files: echo lefthook.yml\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: the entry gates writes passes" "$GMW" "[ok]  pre-commit (static)"
expect "lefthook: doctor did not run the hooks" "$([[ -e "$GMW/ran.txt" ]] && echo ran || echo not-run)" "not-run"
# A run: that is not the gates hook as a whole command does not count
# (#202): the call in a shell comment, or its status masked.
for run in 'echo hi # bash .specify/gates/hooks/pre-commit {files}' \
    'bash .specify/gates/hooks/pre-commit || true # {files}'; do
    # shellcheck disable=SC2059
    printf "pre-commit:\n  commands:\n    spec-gates:\n      run: \"$run\"\n      files: echo lefthook.yml\n$lh_ok" >"$GMW/lefthook.yml"
    run_doctor "$GMW" >/dev/null
    has "lefthook: a run: that cannot refuse fails" "$GMW" "[MISSING] pre-commit (static): git runs .git/hooks/pre-commit, owned by lefthook, and lefthook.yml calls .specify/gates/hooks/pre-commit in job 'spec-gates', but its run: is not the gates hook as a whole command"
done
# The hook's exclude_tags: drops a job it names by tag (or by name).
# shellcheck disable=SC2059
printf "pre-commit:\n  exclude_tags: [gates]\n  commands:\n    spec-gates:\n      tags: [gates]\n      run: \"bash .specify/gates/hooks/pre-commit # {files}\"\n      files: echo lefthook.yml\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: a job excluded by tag fails" "$GMW" "or the hook's exclude_tags: names the job or its tags"
# shellcheck disable=SC2059
printf "pre-commit:\n  exclude_tags: [lint]\n  commands:\n    spec-gates:\n      tags: [gates]\n      run: \"bash .specify/gates/hooks/pre-commit # {files}\"\n      files: echo lefthook.yml\n$lh_ok" >"$GMW/lefthook.yml"
run_doctor "$GMW" >/dev/null
has "lefthook: exclude_tags naming another tag passes" "$GMW" "[ok]  pre-commit (static)"
# Wired in the config, but `lefthook install` never ran: no gates check
# runs on commit, so doctor fails and names the command.
rm -f "$GMW/.git/hooks/pre-commit"
rc="$(run_doctor "$GMW")"
has "lefthook: a wired hook git does not run fails" "$GMW" "[MISSING] pre-commit not installed — lefthook.yml calls the gates hook, but git runs no pre-commit hook until you run \`lefthook install\`"
expect "lefthook: doctor exits 1 until lefthook install" "$rc" "1"
has "lefthook: the upgrade-safety line names lefthook install (#214)" "$GMW" "[MISSING] the hook manager has not generated the git hooks it is wired for — run: lefthook install"
lacks "lefthook: a pending install is not called a stale projection" "$GMW" "the projection is not current"
# The manager owns the hooks, but its config has no gates entry: the
# upgrade-safety line names --wire-manager (#214).
printf 'pre-commit:\n  commands:\n    lint:\n      run: echo user-lint\n' >"$GMW/lefthook.yml"
for h in pre-commit pre-merge-commit commit-msg; do
    printf '#!/bin/sh\n# lefthook generated\ntouch ran.txt\n' >"$GMW/.git/hooks/$h"
    chmod +x "$GMW/.git/hooks/$h"
done
rc="$(run_doctor "$GMW")"
has "lefthook: unwired config names --wire-manager (#214)" "$GMW" "[MISSING] hook-manager wiring is pending — run: bash .specify/extensions/gates/runtime/project.sh --wire-manager"
lacks "lefthook: pending wiring is not called a stale projection" "$GMW" "the projection is not current"
expect "lefthook: pending wiring keeps doctor failing" "$rc" "1"
rm -f "$GMW/lefthook.yml" "$GMW/.git/hooks/"*
# The pre-commit framework: only items staged for the hook count.
printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\ntouch ran.txt\n' >"$GMW/.git/hooks/commit-msg"
chmod +x "$GMW/.git/hooks/commit-msg"
printf 'repos:\n- repo: local\n  hooks:\n  - id: g\n    entry: bash .specify/gates/hooks/commit-msg\n    language: system\n    stages: [pre-push]\n' >"$GMW/.pre-commit-config.yaml"
run_doctor "$GMW" >/dev/null
has "pre-commit: an item staged for another hook fails" "$GMW" "[MISSING] commit-msg (static): git runs .git/hooks/commit-msg, owned by pre-commit, and .pre-commit-config.yaml calls .specify/gates/hooks/commit-msg, but not in an item whose stages: include commit-msg"
printf 'repos:\n- repo: local\n  hooks:\n  - id: g\n    entry: bash .specify/gates/hooks/commit-msg\n    language: system\n    stages: [commit-msg]\n' >"$GMW/.pre-commit-config.yaml"
run_doctor "$GMW" >/dev/null
has "pre-commit: an item staged for the hook passes" "$GMW" "[ok]  commit-msg (static)"
# The entry must be the gates hook itself (#202), not a command naming it.
printf 'repos:\n- repo: local\n  hooks:\n  - id: g\n    entry: echo bash .specify/gates/hooks/commit-msg\n    language: system\n    stages: [commit-msg]\n' >"$GMW/.pre-commit-config.yaml"
run_doctor "$GMW" >/dev/null
has "pre-commit: an entry that only names the gates hook fails" "$GMW" "[MISSING] commit-msg (static): git runs .git/hooks/commit-msg, owned by pre-commit, and .pre-commit-config.yaml calls .specify/gates/hooks/commit-msg, but the item's entry: is not the gates hook itself"
fx_cleanup "$GMW"

echo ""
echo "=== the pre-commit framework's migration mode (#201) ==="
# `pre-commit install` after projection moves each stub to <hook>.legacy
# and runs it first on every call, failing the hook when it fails.
PCL="$(fx_project)"
(cd "$PCL" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
(cd "$PCL" && git add -A && git commit -q --no-verify -m "chore: adopt gates") >/dev/null 2>&1
for h in pre-commit pre-merge-commit commit-msg; do
    mv "$PCL/.git/hooks/$h" "$PCL/.git/hooks/$h.legacy"
    fx_precommit_hook "$PCL/.git/hooks" "$h"
done
rc="$(run_doctor "$PCL")"
healthy "migration mode: doctor passes while .legacy runs gates" "$rc" "$LACK_BASE"
has "migration mode: the moved stub is named" "$PCL" "[ok]  commit-msg is the pre-commit framework's hook and runs the gates stub it moved to commit-msg.legacy"
has "migration mode: the static check passes" "$PCL" "[ok]  pre-commit (static): another tool owns the hook and calls the gates pre-commit hook"
CLAUDE_PROJECT_DIR="$PCL" bash "$PCL/.specify/gates/doctor.sh" --probe-git >"$PCL/out.txt" 2>&1 || true
has "migration mode: --probe-git reaches gates through pre-commit.legacy" "$PCL" "[ok]  pre-commit probe: the hook git runs reaches the gates pre-commit hook"
has "migration mode: --probe-git reaches gates through commit-msg.legacy" "$PCL" "[ok]  commit-msg probe: the hook git runs reaches the gates commit-msg hook"
# A stub from before the fix refuses every commit under the moved name.
# shellcheck disable=SC2016  # the stub's line, matched literally
grep -v '^name="${name%\.legacy}"' "$PCL/.specify/extensions/gates/runtime/hooks/git/stub.sh" >"$PCL/.git/hooks/commit-msg.legacy"
rc="$(run_doctor "$PCL")"
expect "migration mode: an older moved stub fails doctor" "$rc" "1"
has "migration mode: the older stub is named with the fix" "$PCL" "[MISSING] commit-msg (static): git runs .git/hooks/commit-msg, owned by pre-commit, which first runs .git/hooks/commit-msg.legacy: an older gates stub that refuses every commit under that name (fix: re-run project.sh to refresh it)"
# Both the moved stub and a config item: gates runs twice.
cp "$PCL/.specify/extensions/gates/runtime/hooks/git/stub.sh" "$PCL/.git/hooks/commit-msg.legacy"
printf 'repos:\n- repo: local\n  hooks:\n  - id: g\n    entry: bash .specify/gates/hooks/commit-msg\n    language: system\n    stages: [commit-msg]\n' >"$PCL/.pre-commit-config.yaml"
run_doctor "$PCL" >/dev/null
has "migration mode: a double run is named" "$PCL" "[rec] commit-msg runs gates twice"
fx_cleanup "$PCL"

DOR="$(fx_project)"
OUT_IO="$(cd "$DOR" && CLAUDE_PROJECT_DIR="$DOR" bash .specify/extensions/gates/runtime/doctor.sh --installed-only 2>&1)" && rc=0 || rc=$?
expect "--installed-only on a dormant install exits 0" "$rc" "0"
expect "--installed-only reports the dormant state" \
    "$(grep -c 'installed; the runtime is not projected yet' <<<"$OUT_IO")" "1"
# The full run on a dormant install says nothing is projected (#128),
# instead of reporting the policy's linters as not enabled.
printf '{ "hooks": { "prettier": { "include": ["**/*.md"] } } }\n' >"$DOR/.specify/gates/policy.json"
OUT_IO="$(cd "$DOR" && CLAUDE_PROJECT_DIR="$DOR" bash .specify/extensions/gates/runtime/doctor.sh 2>&1)" && rc=0 || rc=$?
expect "the full run on a dormant install exits 1" "$rc" "1"
expect "the full run says the runtime is not projected" \
    "$(grep -c 'the gates runtime is not projected' <<<"$OUT_IO")" "1"
expect "the full run points at --installed-only" "$(grep -c 'doctor.sh --installed-only' <<<"$OUT_IO")" "1"
expect "no linter is reported as not enabled" "$(grep -c 'not enabled in policy' <<<"$OUT_IO")" "0"
mkdir -p "$DOR/.specify/gates"
printf '0.3.6\n' >"$DOR/.specify/gates/.runtime-version"
rm -rf "$DOR/.specify/extensions/gates"
printf '{"extensions":{}}\n' >"$DOR/.specify/extensions/.registry"
mkdir -p "$DOR/.specify/gates/lib"
cp "$REPO_ROOT/extension/runtime/doctor.sh" "$DOR/.specify/gates/"
cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$DOR/.specify/gates/lib/"
printf '{ "hooks": {} }\n' >"$DOR/.specify/gates/policy.json"
OUT_IO="$(CLAUDE_PROJECT_DIR="$DOR" bash "$DOR/.specify/gates/doctor.sh" --installed-only 2>&1)" && rc=0 || rc=$?
expect "--installed-only on a removed extension exits 1" "$rc" "1"
run_doctor "$DOR" >/dev/null
has "the full run names the half-done upgrade" "$DOR" "[MISSING] the gates extension was removed but not added back"
# 0.3.x never projected project.sh, so `project.sh --check` would exit
# 127 there: doctor names the add command instead (#203).
has "without a projected project.sh, the add command is named" "$DOR" "finish it: specify extension add gates --from"
lacks "without a projected project.sh, no project.sh --check advice" "$DOR" "project.sh --check prints"
cp "$REPO_ROOT/extension/runtime/project.sh" "$DOR/.specify/gates/"
run_doctor "$DOR" >/dev/null
has "with a projected project.sh, --check is the advice" "$DOR" "bash .specify/gates/project.sh --check prints the finishing command"
fx_cleanup "$DOR"

echo ""
echo "=== doctor --ci (#148) ==="
# A CI checkout has the projected runtime but no git hook stubs: those are
# installed into .git/hooks, which a clone never carries.
DCI="$(fx_project)"
(cd "$DCI" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
rm -f "$DCI/.git/hooks/pre-commit" "$DCI/.git/hooks/commit-msg"
run_doctor "$DCI" >/dev/null
has "without --ci, missing hook stubs read as a stale projection" "$DCI" "[MISSING] the projection is not current"
rc=0
CLAUDE_PROJECT_DIR="$DCI" bash "$DCI/.specify/gates/doctor.sh" --ci >"$DCI/out.txt" 2>&1 || rc=$?
has "--ci: the projection is current" "$DCI" "[ok]  projection matches the installed extension"
has "--ci: the git boundary is skipped, visibly" "$DCI" "git boundary not checked (--ci"
lacks "--ci: no stale-projection failure" "$DCI" "the projection is not current"
healthy "--ci on a healthy CI checkout exits 0" "$rc" "$LACK_BASE"
printf '# local\n' >>"$DCI/.specify/gates/canary.sh"
CLAUDE_PROJECT_DIR="$DCI" bash "$DCI/.specify/gates/doctor.sh" --ci >"$DCI/out.txt" 2>&1 || true
has "--ci still fails an unheld local edit" "$DCI" "[MISSING] projected files were edited locally and are not held"
fx_cleanup "$DCI"

echo ""
echo "=== degraded hosts name the missing tool (#122) ==="
# PATH is a shim dir holding every tool doctor uses, minus those under test.
doctor_path() { # <dir> <excluded-tool>...
    local dir="$1" t x skip_t
    shift
    mkdir -p "$dir"
    for t in bash sh cat grep sed awk head tail tr wc cut sort uniq env mkdir cp mv rm ln \
        mktemp dirname basename date find chmod touch printf git jq cmp python3 perl \
        sha256sum shasum; do
        skip_t=0
        for x in "$@"; do [[ "$t" == "$x" ]] && skip_t=1; done
        [[ "$skip_t" -eq 1 ]] && continue
        command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$dir/$t"
    done
    return 0
}
DNJ="$(fx_project)"
(cd "$DNJ" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
doctor_path "$WORKDIR/path-nojq" jq
PATH="$WORKDIR/path-nojq" CLAUDE_PROJECT_DIR="$DNJ" bash "$DNJ/.specify/gates/doctor.sh" >"$DNJ/out.txt" 2>&1 || true
has "no jq: the install state is reported as not checked" "$DNJ" "install state not checked: reading .specify/extensions/.registry needs jq"
lacks "no jq: no interrupted-install claim" "$DNJ" "interrupted install"
# Without jq the policy is unread, so no linter is "not enabled" (#172), and
# the jq line names the refusal and the extra-asks state the policy has.
lacks "no jq: no linter reported as not enabled" "$DNJ" "not enabled in policy"
has "no jq: the linters are reported as not checked" "$DNJ" "not checked: reading the policy needs jq"
has "no jq: the jq line says no gate runs" "$DNJ" "verify.sh refuses to run, so no gate runs"
lacks "no jq, no extra entries: no every-edit-asks claim" "$DNJ" "every edit asks"
jq '.protected_files.extra = ["docs/**"]' "$DNJ/.specify/gates/policy.json" >"$DNJ/p.tmp" \
    && mv "$DNJ/p.tmp" "$DNJ/.specify/gates/policy.json"
PATH="$WORKDIR/path-nojq" CLAUDE_PROJECT_DIR="$DNJ" bash "$DNJ/.specify/gates/doctor.sh" >"$DNJ/out.txt" 2>&1 || true
has "no jq: extra entries make every edit ask" "$DNJ" "protected_files.extra is set, so every edit asks"
PATH="$WORKDIR/path-nojq" CLAUDE_PROJECT_DIR="$DNJ" bash "$DNJ/.specify/gates/doctor.sh" --installed-only >"$DNJ/out.txt" 2>&1 || true
has "no jq, --installed-only: install state not checked" "$DNJ" "install state not checked"
lacks "no jq, --installed-only: no not-installed claim" "$DNJ" "the gates extension is not installed"
fx_cleanup "$DNJ"
DNT="$WORKDIR/notools"
project "$DNT" '{ "hooks": {} }' no
doctor_path "$WORKDIR/path-notools" git cmp sha256sum shasum
rc=0
PATH="$WORKDIR/path-notools" CLAUDE_PROJECT_DIR="$DNT" bash "$DNT/.specify/gates/doctor.sh" >"$DNT/out.txt" 2>&1 || rc=$?
expect "no git, cmp or SHA-256 tool: doctor fails" "$rc" 1
has "no git: install hint" "$DNT" "[MISSING] git — not installed"
has "no cmp: named" "$DNT" "[MISSING] cmp — not installed"
has "no SHA-256 tool: named" "$DNT" "[MISSING] sha256sum or shasum — neither is installed"

echo ""
echo "=== options: unknown ones refused, any order (#203) ==="
DFL="$WORKDIR/flags"
project "$DFL" '{ "hooks": {} }' no
# A stand-in canary suite that shows what it was given.
printf '#!/bin/bash\necho "canary-args:$*"\nexit 7\n' >"$DFL/.specify/gates/canary.sh"
doc_flags() { # <args...> -> exit code; output in $DFL/out.txt
    local rc=0
    CLAUDE_PROJECT_DIR="$DFL" bash "$DFL/.specify/gates/doctor.sh" "$@" >"$DFL/out.txt" 2>&1 || rc=$?
    echo "$rc"
}
for bad in --canry --probe-gti -x; do
    expect "$bad: usage error" "$(doc_flags "$bad")" "2"
    has "$bad: named as an unknown option" "$DFL" "doctor: unknown option: $bad"
    lacks "$bad: no checks ran" "$DFL" "=== spec-gates doctor"
done
expect "an unknown option after a known one: usage error" "$(doc_flags --ci --bogus)" "2"
expect "--canary first: the canary suite runs" "$(doc_flags --canary)" "7"
expect "--canary after canary options: the canary suite runs" "$(doc_flags --only bash --canary)" "7"
has "--canary passes canary.sh its options" "$DFL" "canary-args:--only bash"
expect "--ci --canary --probe-git: refused, not a plain run" "$(doc_flags --ci --canary --probe-git)" "2"
has "the refusal names the doctor options" "$DFL" "it takes none of: --ci --probe-git"
lacks "and runs no canary" "$DFL" "canary-args:"
doc_flags --ci --probe-git >/dev/null
has "--ci --probe-git: --ci honoured" "$DFL" "git boundary not checked (--ci"
doc_flags --probe-git --ci >/dev/null
has "--probe-git --ci: --ci honoured" "$DFL" "git boundary not checked (--ci"

echo ""
echo "=== git refuses the repository: dubious ownership (#203) ==="
DDB="$(fx_project)"
(cd "$DDB" && GATES_TEST=1 bash .specify/extensions/gates/runtime/project.sh --skip-canary >/dev/null 2>&1)
if ! (cd "$DDB" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git rev-parse --git-dir >/dev/null 2>&1); then
    rc=0
    (cd "$DDB" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 CLAUDE_PROJECT_DIR="$DDB" bash .specify/gates/doctor.sh) >"$DDB/out.txt" 2>&1 || rc=$?
    has "dubious ownership: the cause is named" "$DDB" "[MISSING] git boundary not checked: git refuses this repository (dubious ownership"
    has "dubious ownership: the fix is printed" "$DDB" "git config --global --add safe.directory '$DDB'"
    has "dubious ownership: the upgrade-safety line names it (#214)" "$DDB" "[MISSING] git refuses this repository (dubious ownership) — trust it with the safe.directory command below"
    lacks "dubious ownership: not called a stale projection" "$DDB" "the projection is not current"
    expect "dubious ownership: doctor exits 1" "$rc" "1"
else
    echo "SKIP: this git ignores GIT_TEST_ASSUME_DIFFERENT_OWNER"
fi
fx_cleanup "$DDB"
echo ""
[[ "$SKIPPED" -gt 0 ]] && echo "$SKIPPED healthy-fixture case(s) skipped: this host lacks tools doctor requires."
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
