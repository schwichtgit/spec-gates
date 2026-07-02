#!/bin/bash
# shellcheck shell=bash
set -uo pipefail

# spec-gates doctor: check the local environment has what the gate needs.
#
#   Required        -- the hooks and verify.sh cannot run without these.
#   Policy-enabled  -- linters your policy actually turns on; a missing one is
#                      an enforcement GAP (the gate silently skips that tool).
#   Recommended     -- optional; they enhance but are not required.
#
# Exit 0 = everything required (incl. policy-enabled linters) is present.
# Exit 1 = something required is missing.

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_LIB_DIR="$PROJECT_ROOT/.specify/gates/lib"

# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/policy.sh" ]] && source "$GATES_LIB_DIR/policy.sh"
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/formatter-dispatch.sh" ]] && source "$GATES_LIB_DIR/formatter-dispatch.sh"

MISSING=0
OK="  [ok]  "
BAD="  [MISSING] "
REC="  [rec] "
SKIP="  [--]  "

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a tool binary the way the gate does (node_modules/.bin -> PATH).
tool_bin() { # <binname>
    if declare -f _gates_tool_bin >/dev/null 2>&1; then
        _gates_tool_bin "$1" "$PROJECT_ROOT"
    elif have "$1"; then
        printf '%s\n' "$1"
    fi
}

# Is a policy linter enabled? (declares include globs)
policy_enables() { # <hook>
    declare -f gates_policy_list >/dev/null 2>&1 || return 1
    [[ -n "$(gates_policy_list "$1" include 2>/dev/null)" ]]
}

echo "=== spec-gates doctor ==="
echo "project: $PROJECT_ROOT"
echo ""

echo "Required:"
for t in jq git; do
    if have "$t"; then echo "${OK}$t"; else echo "${BAD}$t"; MISSING=$((MISSING + 1)); fi
done

echo ""
if [[ ! -f "$PROJECT_ROOT/.specify/gates/policy.json" ]]; then
    echo "Policy: none found at .specify/gates/policy.json (run /speckit.gates.init)"
else
    echo "Policy-enabled linters:"
    # hook name -> binary name
    for pair in "prettier:prettier" "markdownlint:markdownlint-cli2" "shellcheck:shellcheck"; do
        hook="${pair%%:*}"
        bin="${pair##*:}"
        if ! policy_enables "$hook"; then
            echo "${SKIP}$hook (not enabled in policy)"
        elif [[ -n "$(tool_bin "$bin")" ]]; then
            echo "${OK}$hook ($bin)"
        else
            echo "${BAD}$hook ($bin) — enabled in policy but not installed; the gate will skip it"
            MISSING=$((MISSING + 1))
        fi
    done
fi

echo ""
echo "Recommended (optional):"
have node && echo "${OK}node (to install pinned linters via npm ci)" \
    || echo "${REC}node — install pinned prettier/markdownlint-cli2 for reproducible gates"
have shfmt && echo "${OK}shfmt (shell auto-format in post-edit)" \
    || echo "${REC}shfmt — enables shell auto-formatting"
have task && echo "${OK}task (only needed for orchestrator: task)" \
    || echo "${REC}task — only if your policy uses orchestrator: task"

echo ""
if [[ "$MISSING" -gt 0 ]]; then
    echo "doctor: $MISSING required item(s) missing."
    exit 1
fi
echo "doctor: all required tooling present."
exit 0
