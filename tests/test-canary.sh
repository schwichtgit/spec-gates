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
skip() { # <name> <why>
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    echo "SKIP: $1 ($2)"
}

have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

# Project a full real-install layout into <dir>: runtime + canary next to it,
# Claude hooks under .claude/hooks/gates/, git pre-commit + commit-msg under
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
        "$REPO_ROOT/extension/runtime/canary.sh" \
        "$REPO_ROOT/extension/runtime/contract.sh" \
        "$REPO_ROOT/extension/runtime/pr-check.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    cp "$REPO_ROOT/extension/runtime/hooks/claude/"*.sh "$dir/.claude/hooks/gates/"
    cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" \
        "$REPO_ROOT/extension/runtime/hooks/git/commit-msg" \
        "$REPO_ROOT/extension/runtime/hooks/git/stub.sh" "$dir/.specify/gates/hooks/"
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
HOOK_CANARIES=bash,protect,secret,credential,protected,branding
expect "hook canaries ($HOOK_CANARIES) -> exit 0" \
    "$(canary "$FIX" --only "$HOOK_CANARIES")" 0
JSON="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only "$HOOK_CANARIES")"
expect "hook canaries: all six ran" \
    "$(printf '%s' "$JSON" | jq -r '.canaries | length')" 6
expect "hook canaries all report status=blocked" \
    "$(printf '%s' "$JSON" | jq -r '[.canaries[].status] | unique | join(",")')" blocked
expect "hook canaries report failed=0" \
    "$(printf '%s' "$JSON" | jq -r '.failed')" 0

# --- an inherited GATES_POLICY_FILE does not empty the sandboxes' policy (#196) ---
printf '%s' '{"hooks":{}}' >"$WORKDIR/min-policy.json"
PF_ONLY="secret,credential,protected,branding"
have_node_linters && PF_ONLY="format,markdown,$PF_ONLY"
expect "GATES_POLICY_FILE: no canary accepted ($PF_ONLY)" \
    "$(GATES_POLICY_FILE="$WORKDIR/min-policy.json" CLAUDE_PROJECT_DIR="$FIX" \
        bash "$FIX/.specify/gates/canary.sh" --json --only "$PF_ONLY" 2>/dev/null \
        | jq -r '[.canaries[] | select(.status != "blocked") | .id] | join(",")')" ""

# --- without git the suite cannot run, and says why (#172) ---
NOGIT="$WORKDIR/path-nogit"
mkdir -p "$NOGIT"
for t in bash sh jq cat grep sed awk head tail tr wc dirname basename mktemp rm cp mv ln env sort uniq cut date find mkdir chmod; do
    p="$(type -P "$t" 2>/dev/null)" && ln -sf "$p" "$NOGIT/$t"
done
rc=0
OUT="$(PATH="$NOGIT" CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" 2>&1)" || rc=$?
expect "no git: setup failure exit 2" "$rc" 2
expect "no git: names git" "$(grep -c 'canary: git not found' <<<"$OUT" || true)" 1

# --- full run + FR-006 isolation: nothing in the project tree is touched ---
echo ""
echo "=== full suite + sandbox isolation (FR-006) ==="
find "$FIX" | sort >"$WORKDIR/listing-before"
STAMP="$WORKDIR/stamp"
touch "$STAMP"
sleep 1
if python3 -c 'import json, re' >/dev/null 2>&1; then
    expect "full suite on healthy fixture -> exit 0" "$(canary "$FIX")" 0
else
    # Without python3 the PR hook refuses every PR command (#66), so the
    # prhook canary reports a gap; it must be the only one (#92).
    expect "no python3: the only gap is the PR hook" \
        "$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json 2>/dev/null \
            | jq -r '[.canaries[] | select(.status == "accepted") | .id] | join(",")')" prhook
fi
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

# --- SC-003: the spec canary catches a no-op accept-block runner ---
echo ""
echo "=== spec canary (feature 002, SC-003) ==="
expect "healthy fixture: spec canary blocked (exit 0)" \
    "$(canary "$FIX" --only spec)" 0
SPECJSON="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only spec)"
expect "spec canary reports status=blocked" \
    "$(printf '%s' "$SPECJSON" | jq -r '.canaries[0].status')" blocked
expect "doctor --canary --only spec propagates exit 0" \
    "$(rc=0; CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/doctor.sh" --canary --only spec >/dev/null 2>&1 || rc=$?; echo "$rc")" 0

# Stub the accept-block runner to a no-op: every block "passes", so the
# sandboxed spec gate accepts the failing fixture — the suite must fail
# naming the spec gate (the spec-gate analogue of the no-op-dispatch bug).
printf '\ngates_spec_run_block() { SPEC_BLOCK_DETAIL=""; return 0; }\n' \
    >>"$FIX/.specify/gates/lib/spec-gate.sh"
RC_SPEC=0
OUT_SPEC="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only spec 2>&1)" || RC_SPEC=$?
expect "no-op block runner -> suite fails (exit 1)" "$RC_SPEC" 1
expect "output names the spec canary as ACCEPTED" \
    "$(printf '%s' "$OUT_SPEC" | grep -c 'spec.*ACCEPTED\|ACCEPTED.*spec' || true)" 1
cp "$REPO_ROOT/extension/runtime/lib/spec-gate.sh" "$FIX/.specify/gates/lib/"
expect "restored runner -> spec canary green again (exit 0)" \
    "$(canary "$FIX" --only spec)" 0

# --- #236: the errexit canary catches a runner that judges the last line ---
echo ""
echo "=== errexit canary (#236) ==="
expect "healthy fixture: errexit canary blocked (exit 0)" \
    "$(canary "$FIX" --only errexit)" 0
# Run blocks without errexit and pipefail again: a block that fails on its
# first line and ends on `true` passes, which the canary must report.
sed 's/bash -eo pipefail "/bash "/' \
    "$REPO_ROOT/extension/runtime/lib/spec-gate.sh" >"$FIX/.specify/gates/lib/spec-gate.sh"
expect "the regressed runner was planted" \
    "$(grep -c 'bash -eo pipefail "' "$FIX/.specify/gates/lib/spec-gate.sh" || true)" 0
RC_ERR=0
OUT_ERR="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only spec,errexit 2>&1)" || RC_ERR=$?
expect "last-line-only runner -> suite fails (exit 1)" "$RC_ERR" 1
expect "output names the errexit canary as ACCEPTED" \
    "$(grep -c '^canary: errexit -- ACCEPTED' <<<"$OUT_ERR" || true)" 1
expect "the plain spec canary still blocks" \
    "$(grep -c '^canary: spec -- blocked' <<<"$OUT_ERR" || true)" 1
cp "$REPO_ROOT/extension/runtime/lib/spec-gate.sh" "$FIX/.specify/gates/lib/"
expect "restored runner -> errexit canary green again (exit 0)" \
    "$(canary "$FIX" --only errexit)" 0

# --- SC-002 (003): the contract canary catches a no-op drift check ---
echo ""
echo "=== contract canary (feature 003) ==="
expect "healthy fixture: contract canary blocked (exit 0)" \
    "$(canary "$FIX" --only contract)" 0
CONJSON="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only contract)"
expect "contract canary reports status=blocked" \
    "$(printf '%s' "$CONJSON" | jq -r '.canaries[0].status')" blocked

# Stub the invariant check to an unconditional pass: the tampered sandbox
# is accepted, so the suite must fail naming the contract gate.
cat >>"$FIX/.specify/gates/lib/contract.sh" <<'EOF'

gates_contract_check() {
    CONTRACT_STATUS="pass"
    CONTRACT_DETAIL=""
    CONTRACT_DEVIATIONS=""
    CONTRACT_WEAKENED=0
    CONTRACT_CHANGED=0
    CONTRACT_EFFECTIVE_SHA256=""
    CONTRACT_PIN_DIGEST=""
    CONTRACT_SOURCE="stub"
    CONTRACT_VERSION="v0"
    return 0
}
EOF
RC_CON=0
OUT_CON="$(CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only contract 2>&1)" || RC_CON=$?
expect "no-op drift check -> suite fails (exit 1)" "$RC_CON" 1
expect "output names the contract canary as ACCEPTED" \
    "$(printf '%s' "$OUT_CON" | grep -c 'contract.*ACCEPTED\|ACCEPTED.*contract' || true)" 1
cp "$REPO_ROOT/extension/runtime/lib/contract.sh" "$FIX/.specify/gates/lib/"
expect "restored check -> contract canary green again (exit 0)" \
    "$(canary "$FIX" --only contract)" 0

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

# markdownlint had no canary, so a CI job that installed no linters stayed
# green under a policy enabling it (#138).
echo ""
echo "=== markdown canary (#138) ==="
if command -v markdownlint-cli2 >/dev/null 2>&1; then
    skip "markdownlint gap checks" "a global markdownlint-cli2 is on PATH"
else
    NOML="$WORKDIR/no-markdownlint"
    project_fixture "$NOML"
    rm -f "$NOML/node_modules"
    printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' \
        >"$NOML/.specify/gates/policy.json"
    expect "markdownlint absent + not policy-enabled -> skipped, exit 0" \
        "$(canary "$NOML" --only markdown)" 0
    printf '%s' '{"hooks":{"markdownlint":{"include":["**/*.md"],"orchestrator":"none","severity":"error"},"verify-quality":{"orchestrator":"none","severity":"error"}}}' \
        >"$NOML/.specify/gates/policy.json"
    expect "markdownlint absent but policy-enabled -> enforcement gap, exit 1" \
        "$(canary "$NOML" --only markdown)" 1
    expect "the gap names markdownlint" \
        "$(CLAUDE_PROJECT_DIR="$NOML" bash "$NOML/.specify/gates/canary.sh" --json --only markdown \
            | jq -r '.canaries[0].outcome' | grep -c 'markdownlint-cli2 is policy-enabled but not installed' || true)" 1
fi
if have_node_linters; then
    expect "markdownlint installed: markdown canary blocked (exit 0)" \
        "$(canary "$FIX" --only markdown)" 0
    printf '#!/bin/bash\nexit 0\n' >"$FIX/.specify/gates/lib/formatter-dispatch.sh"
    expect "no-op dispatch -> markdown canary fails (exit 1)" \
        "$(canary "$FIX" --only markdown)" 1
    cp "$REPO_ROOT/extension/runtime/lib/formatter-dispatch.sh" "$FIX/.specify/gates/lib/"
else
    skip "markdown canary blocking checks" "run npm ci to install pinned markdownlint-cli2"
fi

# Degraded hosts (#122): a canary that cannot run for a missing tool names
# that tool. PATH is a shim dir holding every tool the suite uses, minus
# the ones under test.
echo ""
echo "=== missing tools are named (#122) ==="
shim_path() { # <dir> <excluded-tool>...
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
shim_path "$WORKDIR/path-nopy" python3
PRJSON="$(PATH="$WORKDIR/path-nopy" CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --json --only prhook 2>/dev/null || true)"
expect "no python3: the prhook canary fails" \
    "$(jq -r '.failed' <<<"$PRJSON")" 1
expect "no python3: the prhook outcome names python3" \
    "$(jq -r '.canaries[0].outcome' <<<"$PRJSON" | grep -c 'python3 with the json module is not installed' || true)" 1
shim_path "$WORKDIR/path-nosha" sha256sum shasum
RC_NOSHA=0
OUT_NOSHA="$(PATH="$WORKDIR/path-nosha" CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.specify/gates/canary.sh" --only contract 2>&1)" || RC_NOSHA=$?
expect "no SHA-256 tool: the contract canary fails (exit 1, not a setup error)" "$RC_NOSHA" 1
expect "no SHA-256 tool: the outcome names sha256sum and shasum" \
    "$(grep -c 'neither sha256sum nor shasum is installed' <<<"$OUT_NOSHA" || true)" 1

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
