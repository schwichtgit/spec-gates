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

ALL='{ "hooks": { "prettier": {"include":["**/*.md"],"orchestrator":"none","severity":"error"}, "markdownlint": {"include":["**/*.md"],"orchestrator":"none","severity":"error"}, "shellcheck": {"include":["**/*.sh"],"orchestrator":"none","severity":"error"} } }'

# jq + git are always present in the test environment, so "required" passes.
echo "=== all policy linters available -> exit 0 ==="
if [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; then
    D="$WORKDIR/ok"
    project "$D" "$ALL" yes
    expect "everything present -> exit 0" "$(run_doctor "$D")" 0
    if grep -q "all required tooling present" "$D/out.txt"; then
        echo "PASS: reports success"
        PASS=$((PASS + 1))
    else
        echo "FAIL: success message"
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
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
expect "healthy discovery -> exit 0" "$(run_doctor "$D")" 0
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
expect "all-checked-not-Complete -> still exit 0" "$(run_doctor "$D")" 0
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
expect "wired executable hooks -> exit 0" "$(run_doctor "$GB")" 0
if grep -q "pre-commit installed, executable, delegates" "$GB/out.txt"; then
    echo "PASS: healthy hook reported ok"
    PASS=$((PASS + 1))
else
    echo "FAIL: healthy hook report (got: $(grep 'pre-commit' "$GB/out.txt" | head -1))"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

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

rm "$GB/.git/hooks/pre-commit" "$GB/.git/hooks/commit-msg"
expect "hooks never installed -> nudge only, exit 0" "$(run_doctor "$GB")" 0
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
expect "healthy contract -> exit 0" "$(run_doctor "$D")" 0
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

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
