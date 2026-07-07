#!/bin/bash
set -euo pipefail

# canary.sh behaviour tests: the gate's own proof that it still blocks.
#
# Regression guard for SC-001: the historical no-op-dispatch bug (check-mode
# silently gone, every file "passed") must be caught by the canary suite in
# a single run, naming the gate. Also asserts FR-006: a canary run never
# creates or modifies files in the user's project.
#
# Tool-dependent checks are skipped (not failed) when the tool is absent, so
# the suite stays portable; CI has the tools installed and exercises them.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-canary-test)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

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
skip() { # <name> <why>
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    echo "SKIP: $1 ($2)"
}

have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

# Project a full real-install layout into <dir>: runtime + canary next to it,
# Claude hooks under .claude/hooks/gates/, git pre-commit under
# .specify/gates/hooks/ — exactly where /speckit.gates.init puts them.
# The policy enables only the linters present in this environment so the
# healthy-suite expectation holds everywhere (a policy-enabled-but-missing
# tool is, correctly, a canary failure).
project_fixture() { # <dir>
    local dir="$1"
    mkdir -p "$dir/.specify/gates/lib" "$dir/.specify/gates/hooks" \
        "$dir/.claude/hooks/gates"
    cp "$REPO_ROOT/extension/runtime/verify.sh" \
        "$REPO_ROOT/extension/runtime/doctor.sh" \
        "$REPO_ROOT/extension/runtime/canary.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    cp "$REPO_ROOT/extension/runtime/hooks/claude/"*.sh "$dir/.claude/hooks/gates/"
    cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" "$dir/.specify/gates/hooks/"
    local policy='{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}'
    if have_node_linters; then
        policy="$(printf '%s' "$policy" | jq -c '.hooks.prettier = {"include":["**/*.md"],"orchestrator":"none","severity":"error"}')"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        policy="$(printf '%s' "$policy" | jq -c '.hooks.shellcheck = {"include":["**/*.sh"],"orchestrator":"none","severity":"error"}')"
    fi
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
    if [[ -d "$REPO_ROOT/node_modules" ]]; then
        ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
    fi
}

# Run the fixture's canary suite and echo its exit code.
canary() { # <dir> [flag...]
    local dir="$1"
    shift
    local rc=0
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/canary.sh" "$@" \
        >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

FIX="$WORKDIR/fixture"
project_fixture "$FIX"

# --- healthy suite: every canary blocked, exit 0 ---
echo "=== healthy checkout: canaries pass ==="
expect "hook canaries (bash,protect,secret) -> exit 0" \
    "$(canary "$FIX" --only bash,protect,secret)" 0
JSON="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only bash,protect,secret)"
expect "hook canaries all report status=blocked" \
    "$(printf '%s' "$JSON" | jq -r '[.canaries[].status] | unique | join(",")')" blocked
expect "hook canaries report failed=0" \
    "$(printf '%s' "$JSON" | jq -r '.failed')" 0

# --- full run + FR-006 isolation: nothing in the project tree is touched ---
echo ""
echo "=== full suite + sandbox isolation (FR-006) ==="
find "$FIX" | sort >"$WORKDIR/listing-before"
STAMP="$WORKDIR/stamp"
touch "$STAMP"
sleep 1
expect "full suite on healthy fixture -> exit 0" "$(canary "$FIX")" 0
find "$FIX" | sort >"$WORKDIR/listing-after"
expect "no file created or deleted in the project tree" \
    "$(diff "$WORKDIR/listing-before" "$WORKDIR/listing-after" >/dev/null 2>&1 && echo clean || echo dirty)" clean
expect "no file modified in the project tree" \
    "$(find "$FIX" -type f -newer "$STAMP" | wc -l | tr -d ' ')" 0

# --- --only subset ---
echo ""
echo "=== --only subset ==="
SUB="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only bash)"
expect "--only bash runs exactly one canary" \
    "$(printf '%s' "$SUB" | jq -r '.canaries | length')" 1
expect "--only bash runs the bash canary" \
    "$(printf '%s' "$SUB" | jq -r '.canaries[0].id')" bash
RC_BOGUS=0
CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only bogus \
    >/dev/null 2>&1 || RC_BOGUS=$?
expect "--only with an unknown id -> exit 1" "$RC_BOGUS" 1

# --- doctor delegation ---
echo ""
echo "=== doctor.sh --canary delegates ==="
RC_DOC=0
CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/doctor.sh" --canary --only protect \
    >/dev/null 2>&1 || RC_DOC=$?
expect "doctor --canary propagates canary exit 0" "$RC_DOC" 0

# --- SC-001: the historical no-op bug is caught in one run, naming the gate ---
echo ""
echo "=== broken dispatch is caught (SC-001) ==="
if have_node_linters; then
    printf '#!/bin/bash\nexit 0\n' >"$FIX/.specify/gates/lib/formatter-dispatch.sh"
    RC_BROKEN=0
    OUT="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only format 2>&1)" || RC_BROKEN=$?
    expect "no-op dispatch -> suite fails (exit 1)" "$RC_BROKEN" 1
    expect "output names the format canary as ACCEPTED" \
        "$(printf '%s' "$OUT" | grep -c 'format.*ACCEPTED\|ACCEPTED.*format' || true)" 1
    cp "$REPO_ROOT/extension/runtime/lib/formatter-dispatch.sh" "$FIX/.specify/gates/lib/"
    expect "restored dispatch -> suite green again (exit 0)" \
        "$(canary "$FIX" --only format)" 0
else
    skip "broken-dispatch canary checks" "run npm ci to install pinned prettier"
fi

# --- skipped semantics: absent tool, and the policy-enabled gap rule ---
echo ""
echo "=== skipped vs enforcement-gap semantics ==="
if command -v prettier >/dev/null 2>&1; then
    skip "absent-tool skip checks" "a global prettier is on PATH"
else
    NOPIN="$WORKDIR/no-linters"
    project_fixture "$NOPIN"
    rm -f "$NOPIN/node_modules"
    printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' \
        >"$NOPIN/.specify/gates/policy.json"
    expect "tool absent + not policy-enabled -> skipped, exit 0" \
        "$(canary "$NOPIN" --only format)" 0
    SKIPJSON="$(CLAUDE_PROJECT_DIR="$NOPIN" bash "$NOPIN/.specify/gates/canary.sh" --json --only format)"
    expect "skip is reported as status=skipped" \
        "$(printf '%s' "$SKIPJSON" | jq -r '.canaries[0].status')" skipped
    printf '%s' '{"hooks":{"prettier":{"include":["**/*.md"],"orchestrator":"none","severity":"error"},"verify-quality":{"orchestrator":"none","severity":"error"}}}' \
        >"$NOPIN/.specify/gates/policy.json"
    expect "tool absent but policy-enabled -> enforcement gap, exit 1" \
        "$(canary "$NOPIN" --only format)" 1
fi

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
