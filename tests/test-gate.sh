#!/bin/bash
set -euo pipefail

# verify.sh gate-behaviour tests: the orchestrator dispatch itself.
#
# Regression guard for three bugs found while wiring the boundaries:
#   - the default `none` orchestrator was a silent no-op (formatter-dispatch
#     had no --check CLI), so every file "passed";
#   - the `custom` orchestrator read the wrong policy field and never ran;
#   - an empty gate set crashed verify.sh under bash 3.2.
#
# Tool-dependent checks are skipped (not failed) when the tool is absent, so
# the suite stays portable; CI has the tools installed and exercises them.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-gate)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

# Project the runtime into <dir> with a caller-supplied policy body. Also link
# the repo's pinned node_modules so the gate resolves the same prettier /
# markdownlint-cli2 the product uses (the check-mode never auto-downloads).
project() { # <dir> <policy-json>
    local dir="$1" policy="$2"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
    if [[ -d "$REPO_ROOT/node_modules" ]]; then
        ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
    fi
}

# True if the pinned node linters are installed (npm ci has run).
have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

# Run verify.sh in <dir> and echo its exit code.
gate() { # <dir> [flag...]
    local dir="$1"
    shift
    local rc=0
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/verify.sh" \
        --boundary ci "$@" >/dev/null 2>&1 || rc=$?
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
skip() { # <name> <why>
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    echo "SKIP: $1 ($2)"
}

NONE_PRETTIER='{ "hooks": { "prettier": { "include": ["**/*.md"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
NONE_SHELL='{ "hooks": { "shellcheck": { "include": ["**/*.sh"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'

# --- default (none) orchestrator: prettier actually checks ---
echo "=== none orchestrator enforces prettier ==="
if have_node_linters; then
    D="$WORKDIR/pretty"
    project "$D" "$NONE_PRETTIER"
    printf '#Bad md\n\n\n- x\n' >"$D/README.md"
    expect "badly-formatted md -> gate fails (exit 2)" "$(gate "$D")" 2
    printf '# Title\n\nBody text.\n' >"$D/README.md"
    expect "prettier-clean md -> gate passes (exit 0)" "$(gate "$D")" 0
else
    skip "prettier none-orchestrator checks" "run npm ci to install pinned prettier"
fi

# --- default (none) orchestrator: shellcheck actually checks ---
echo ""
echo "=== none orchestrator enforces shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
    D="$WORKDIR/shell"
    project "$D" "$NONE_SHELL"
    # bad.sh must contain a literal unquoted $HOME (an SC2086 finding) so the
    # gate flags it; the single quotes below are intentional, not a mistake.
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nrm -rf $HOME/x\n' >"$D/bad.sh"
    expect "shellcheck finding -> gate fails (exit 2)" "$(gate "$D")" 2
    rm -f "$D/bad.sh"
    printf '#!/bin/bash\necho "ok"\n' >"$D/good.sh"
    expect "clean shell -> gate passes (exit 0)" "$(gate "$D")" 0
else
    skip "shellcheck none-orchestrator checks" "shellcheck not installed"
fi

# --- exclude globs are honored ---
echo ""
echo "=== exclude globs are honored ==="
if have_node_linters; then
    D="$WORKDIR/excl"
    project "$D" '{ "hooks": { "prettier": { "include": ["**/*.md"], "exclude": ["vendor/**"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
    mkdir -p "$D/vendor"
    printf '#bad\n\n\n- x\n' >"$D/vendor/junk.md"
    expect "bad file under excluded path -> gate passes" "$(gate "$D")" 0
else
    skip "exclude-glob check" "run npm ci to install pinned prettier"
fi

# --- custom orchestrator reads custom_command and maps exit codes ---
echo ""
echo "=== custom orchestrator ==="
DP="$WORKDIR/custom-pass"
project "$DP" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } } }'
expect "custom true -> pass (exit 0)" "$(gate "$DP")" 0
DF="$WORKDIR/custom-fail"
project "$DF" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "false" } } }'
expect "custom false -> fail (exit 2)" "$(gate "$DF")" 2

# --- empty gate set does not crash under bash 3.2, and --json is well-formed ---
echo ""
echo "=== empty gate set (bash 3.2 regression) ==="
DE="$WORKDIR/empty"
project "$DE" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
expect "no enabled tools -> clean exit 0" "$(gate "$DE")" 0
if command -v jq >/dev/null 2>&1; then
    JSON="$(CLAUDE_PROJECT_DIR="$DE" bash "$DE/.specify/gates/verify.sh" --boundary ci --json)"
    OK="$(printf '%s' "$JSON" | jq -e '.gates | type == "array"' >/dev/null 2>&1 && echo yes || echo no)"
    expect "--json emits a well-formed gates array" "$OK" yes
else
    skip "--json shape" "jq not installed"
fi

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
