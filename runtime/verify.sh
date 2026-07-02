#!/bin/bash
# shellcheck shell=bash
set -euo pipefail

# spec-gates: single verify entrypoint, invoked identically at all three
# enforcement boundaries.
#
#   Agent boundary : Claude Code Stop hook (verify-quality.sh delegates here)
#   Git boundary   : .git/hooks/pre-commit
#   CI boundary    : projected GitHub Actions / GitLab CI / Jenkins job
#
# The parity property — "if the agent boundary passed, git passes; if git
# passed, CI passes" — holds because every boundary runs THIS script with
# THIS policy. tests/test-ci-parity.sh asserts it.
#
# Usage:
#   verify.sh --boundary agent|git|ci [--json] [--dry-run]
#
# Exit codes: 0 = all gates green, 1 = internal error, 2 = gate failure.

BOUNDARY="unspecified"
JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --boundary) BOUNDARY="${2:?}"; shift 2 ;;
        --json)     JSON=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        *) echo "gates: unknown argument: $1" >&2; exit 1 ;;
    esac
done

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_DIR="$PROJECT_ROOT/.specify/gates"
POLICY_FILE="$GATES_DIR/policy.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "gates: jq not found — cannot evaluate policy (run /speckit.gates.doctor)" >&2
    exit 1
fi
if [[ ! -f "$POLICY_FILE" ]]; then
    echo "gates: no policy at $POLICY_FILE (run /speckit.gates.init)" >&2
    exit 1
fi

# shellcheck source=lib/policy.sh
source "$GATES_DIR/lib/policy.sh"

FAILED=0
WARNINGS=0
declare -a RESULTS=()

record() { # name status detail
    RESULTS+=("{\"name\":\"$1\",\"status\":\"$2\",\"detail\":$(jq -Rn --arg d "$3" '$d')}")
}

run_gate() { # name severity cmd...
    local name="$1" severity="$2"; shift 2
    if [[ "$DRY_RUN" == "1" ]]; then
        record "$name" "planned" "$*"
        return 0
    fi
    if "$@" >/tmp/gates-out.$$ 2>&1; then
        record "$name" "pass" ""
    else
        local detail; detail="$(tail -c 2000 /tmp/gates-out.$$)"
        if [[ "$severity" == "error" ]]; then
            record "$name" "fail" "$detail"; FAILED=$((FAILED + 1))
        else
            record "$name" "warn" "$detail"; WARNINGS=$((WARNINGS + 1))
        fi
    fi
    rm -f /tmp/gates-out.$$
}

# ---------------------------------------------------------------------------
# Gate dispatch. Orchestrator semantics carried over from CPF (ADR-005):
#   "none"   -> per-tool walk driven by policy include/exclude globs
#   "task"   -> `task lint` (error class) and `task test` (warning class)
#   "custom" -> policy-supplied command, exit code mapped via severity
# The per-tool walk delegates to lib/formatter-dispatch.sh in check mode.
# ---------------------------------------------------------------------------
ORCH="$(gates_policy_get "verify-quality" "orchestrator")"
[[ -z "$ORCH" ]] && ORCH="none"

case "$ORCH" in
    task)
        run_gate "task-lint" "error"   task lint
        run_gate "task-test" "warning" task test
        ;;
    custom)
        CUSTOM_CMD="$(gates_policy_get "verify-quality" "command")"
        SEV="$(gates_policy_get "verify-quality" "severity")"; [[ -z "$SEV" ]] && SEV="error"
        [[ -n "$CUSTOM_CMD" ]] && run_gate "custom" "$SEV" sh -c "$CUSTOM_CMD"
        ;;
    none|*)
        for tool in prettier markdownlint shellcheck; do
            # A hook is "enabled" when the policy declares include globs for it.
            if [[ -n "$(gates_policy_list "$tool" "include")" ]]; then
                SEV="$(gates_policy_get "$tool" "severity")"; [[ -z "$SEV" ]] && SEV="error"
                run_gate "$tool" "$SEV" \
                    bash "$GATES_DIR/lib/formatter-dispatch.sh" --check --tool "$tool" \
                         --project-root "$PROJECT_ROOT"
            fi
        done
        ;;
esac

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ "$JSON" == "1" ]]; then
    printf '{"boundary":"%s","failed":%d,"warnings":%d,"gates":[%s]}\n' \
        "$BOUNDARY" "$FAILED" "$WARNINGS" "$(IFS=,; echo "${RESULTS[*]}")"
else
    echo "gates: boundary=$BOUNDARY failed=$FAILED warnings=$WARNINGS"
    for r in "${RESULTS[@]}"; do
        name="$(printf '%s' "$r" | jq -r '.name')"
        status="$(printf '%s' "$r" | jq -r '.status')"
        detail="$(printf '%s' "$r" | jq -r '.detail' | head -n 1)"
        if [[ -n "$detail" ]]; then
            echo "  [$status] $name -- $detail"
        else
            echo "  [$status] $name"
        fi
    done
fi

[[ "$FAILED" -gt 0 ]] && exit 2
exit 0
