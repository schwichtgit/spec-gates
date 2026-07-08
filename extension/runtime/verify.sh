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

# Path is resolved at runtime from the projected layout; the source= hint helps
# `shellcheck -x` runs, disable=SC1091 silences the unavoidable static miss.
# shellcheck source=lib/policy.sh disable=SC1091
source "$GATES_DIR/lib/policy.sh"
# shellcheck source=lib/attest.sh disable=SC1091
source "$GATES_DIR/lib/attest.sh"

FAILED=0
WARNINGS=0
declare -a RESULTS=()
declare -a ATT_GATES=()

record() { # name status detail
    RESULTS+=("{\"name\":\"$1\",\"status\":\"$2\",\"detail\":$(jq -Rn --arg d "$3" '$d')}")
}

# Append a GateEntry (attestation shape, data-model.md) for an evaluated
# gate. Empty strings become JSON null for the nullable fields.
att_gate() { # name bin version pinned candidates checked result reason duration_s
    ATT_GATES+=("$(jq -cn \
        --arg name "$1" --arg bin "$2" --arg version "$3" --arg pinned "$4" \
        --arg candidates "$5" --arg checked "$6" --arg result "$7" \
        --arg reason "$8" --arg duration "$9" '
        def num_or_null: if . == "" then null else tonumber end;
        def str_or_null: if . == "" then null else . end;
        { name: $name,
          bin: ($bin | str_or_null),
          version: ($version | str_or_null),
          pinned: ($pinned | str_or_null),
          candidates: ($candidates | num_or_null),
          checked: ($checked | num_or_null),
          result: $result,
          reason: $reason,
          duration_s: ($duration | tonumber) }')")
}

run_gate() { # name severity cmd...
    local name="$1" severity="$2"; shift 2
    if [[ "$DRY_RUN" == "1" ]]; then
        record "$name" "planned" "$*"
        return 0
    fi
    local start end rc=0
    start="$(date +%s)"
    "$@" >/tmp/gates-out.$$ 2>&1 || rc=$?
    end="$(date +%s)"

    # Check-mode metadata (##gates-meta##, emitted by formatter-dispatch) is
    # machinery, not gate output: parse it for the attestation entry, strip
    # it from the visible detail. Non-file gates (task/custom) have none.
    local meta binname="" bin="" candidates="" checked="" skipped=""
    meta="$(grep '##gates-meta##' /tmp/gates-out.$$ 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$meta" ]]; then
        binname="$(printf '%s' "$meta" | sed -n 's/.* binname=\([^ ]*\).*/\1/p')"
        candidates="$(printf '%s' "$meta" | sed -n 's/.* candidates=\([0-9]*\).*/\1/p')"
        checked="$(printf '%s' "$meta" | sed -n 's/.* checked=\([0-9]*\).*/\1/p')"
        skipped="$(printf '%s' "$meta" | sed -n 's/.* skipped=\([^ ]*\).*/\1/p')"
        bin="$(printf '%s' "$meta" | sed -n 's/.* bin=//p')"
    fi
    local detail
    detail="$(grep -v '##gates-meta##' /tmp/gates-out.$$ | tail -c 2000 || true)"
    rm -f /tmp/gates-out.$$

    local version="" pinned=""
    if [[ -n "$binname" ]]; then
        version="$(gates_tool_version "$binname" "$PROJECT_ROOT")"
        pinned="$(gates_pin_version "$binname" "$PROJECT_ROOT")"
    fi
    [[ -n "$bin" && "$bin" == "$PROJECT_ROOT/"* ]] && bin="${bin#"$PROJECT_ROOT"/}"

    # A missing tool is skipped with a reason, never pass (spec edge case).
    # The attestation reason carries no tool output: output can quote file
    # contents, which FR-011 keeps out of records.
    local result reason=""
    if [[ "$rc" -eq 0 && -n "$skipped" ]]; then
        result="skipped"; reason="$binname not installed"
    elif [[ "$rc" -eq 0 ]]; then
        result="pass"
    elif [[ "$severity" == "error" ]]; then
        result="fail"; reason="check failed"
    else
        result="warn"; reason="check failed (warning)"
    fi

    case "$result" in
        pass) record "$name" "pass" "" ;;
        skipped) record "$name" "skipped" "$reason" ;;
        fail) record "$name" "fail" "$detail"; FAILED=$((FAILED + 1)) ;;
        warn) record "$name" "warn" "$detail"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
    att_gate "$name" "$bin" "$version" "$pinned" "$candidates" "$checked" \
        "$result" "$reason" "$((end - start))"
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
        CUSTOM_CMD="$(gates_policy_get "verify-quality" "custom_command")"
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

ATT_ENABLED="$(gates_policy_section_get attestation enabled)"

# ---------------------------------------------------------------------------
# Synthetic parity gate (R7): every boundary compares the tool versions just
# detected against the lockfile pins, so agent, git, and CI runs are proven
# equivalent transitively — no attestation transport needed. Severity comes
# from attestation.parity (default error; warning reports without failing;
# off omits the entry). Disabled attestations disable parity too.
# ---------------------------------------------------------------------------
PARITY_SEV="$(gates_policy_section_get attestation parity)"
[[ -z "$PARITY_SEV" ]] && PARITY_SEV="error"
if [[ "$DRY_RUN" != "1" && "$ATT_ENABLED" != "false" && "$PARITY_SEV" != "off" ]]; then
    parity_input="[]"
    if [[ ${#ATT_GATES[@]} -gt 0 ]]; then
        parity_input="[$(IFS=,; printf '%s' "${ATT_GATES[*]}")]"
    fi
    PARITY_DRIFT="$(gates_pin_mismatches "$parity_input")"
    if [[ -z "$PARITY_DRIFT" ]]; then
        record "parity" "pass" ""
        att_gate "parity" "" "" "" "" "" "pass" "" 0
    elif [[ "$PARITY_SEV" == "error" ]]; then
        record "parity" "fail" "$PARITY_DRIFT"
        FAILED=$((FAILED + 1))
        att_gate "parity" "" "" "" "" "" "fail" "$PARITY_DRIFT" 0
    else
        record "parity" "warn" "$PARITY_DRIFT"
        WARNINGS=$((WARNINGS + 1))
        att_gate "parity" "" "" "" "" "" "warn" "$PARITY_DRIFT" 0
    fi
fi

# ---------------------------------------------------------------------------
# Attestation record (feature 001): one per non-dry run unless the policy
# disables it. A failure to hash or to write the log is a stderr warning
# only — evidence loss must never mask or manufacture a gate outcome.
# ---------------------------------------------------------------------------
EXIT_CODE=0
[[ "$FAILED" -gt 0 ]] && EXIT_CODE=2

ATTESTATION=""
if [[ "$DRY_RUN" != "1" && "$ATT_ENABLED" != "false" ]]; then
    if POLICY_SHA="$(gates_sha256 "$POLICY_FILE")"; then
        RUNTIME_VERSION=""
        if [[ -f "$GATES_DIR/.runtime-version" ]]; then
            RUNTIME_VERSION="$(head -n 1 "$GATES_DIR/.runtime-version" 2>/dev/null || true)"
        fi
        ATT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        att_joined=""
        if [[ ${#ATT_GATES[@]} -gt 0 ]]; then
            att_joined="$(IFS=,; printf '%s' "${ATT_GATES[*]}")"
        fi
        ATTESTATION="$(jq -cn --arg ts "$ATT_TS" --arg boundary "$BOUNDARY" \
            --arg sha "$POLICY_SHA" --arg rv "$RUNTIME_VERSION" \
            --argjson exit "$EXIT_CODE" --argjson gates "[$att_joined]" '
            { v: 1,
              ts: $ts,
              boundary: (if ["agent","git","ci"] | index($boundary) then $boundary else "unspecified" end),
              policy_sha256: $sha,
              runtime_version: (if $rv == "" then null else $rv end),
              exit: $exit,
              gates: $gates }')"
        MAX_RECORDS="$(gates_policy_section_get attestation max_records)"
        [[ -z "$MAX_RECORDS" ]] && MAX_RECORDS=200
        if ! gates_attest_append "$ATTESTATION" "$GATES_DIR/attestations.jsonl" "$MAX_RECORDS"; then
            echo "gates: warning: could not write $GATES_DIR/attestations.jsonl (gate outcome unaffected)" >&2
        fi
    else
        echo "gates: warning: attestation skipped — cannot hash policy (gate outcome unaffected)" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
# Note: "${RESULTS[@]}" on an empty array is an unbound-variable error under
# `set -u` on bash 3.2 (the default /bin/bash on macOS, where these hooks run),
# so every access is guarded by an element-count check.
if [[ "$JSON" == "1" ]]; then
    joined=""
    if [[ ${#RESULTS[@]} -gt 0 ]]; then
        joined="$(IFS=,; printf '%s' "${RESULTS[*]}")"
    fi
    if [[ -n "$ATTESTATION" ]]; then
        printf '{"boundary":"%s","failed":%d,"warnings":%d,"gates":[%s],"attestation":%s}\n' \
            "$BOUNDARY" "$FAILED" "$WARNINGS" "$joined" "$ATTESTATION"
    else
        printf '{"boundary":"%s","failed":%d,"warnings":%d,"gates":[%s]}\n' \
            "$BOUNDARY" "$FAILED" "$WARNINGS" "$joined"
    fi
else
    echo "gates: boundary=$BOUNDARY failed=$FAILED warnings=$WARNINGS"
    if [[ ${#RESULTS[@]} -gt 0 ]]; then
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
fi

exit "$EXIT_CODE"
