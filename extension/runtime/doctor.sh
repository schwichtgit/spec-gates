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

# --canary delegates to the canary suite (projected as a sibling of this
# script), propagating its exit code and output.
if [[ "${1:-}" == "--canary" ]]; then
    shift
    CANARY_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/canary.sh"
    if [[ ! -f "$CANARY_SH" ]]; then
        echo "doctor: canary.sh not found next to doctor.sh — re-project the runtime (/speckit.gates.init)" >&2
        exit 1
    fi
    exec bash "$CANARY_SH" "$@"
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_LIB_DIR="$PROJECT_ROOT/.specify/gates/lib"

# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/policy.sh" ]] && source "$GATES_LIB_DIR/policy.sh"
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/formatter-dispatch.sh" ]] && source "$GATES_LIB_DIR/formatter-dispatch.sh"
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/spec-gate.sh" ]] && source "$GATES_LIB_DIR/spec-gate.sh"
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/attest.sh" ]] && source "$GATES_LIB_DIR/attest.sh"
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/contract.sh" ]] && source "$GATES_LIB_DIR/contract.sh"

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

# No-op heuristic (FR-004): a gate that PASSED while checking none of its
# candidate files is the historical silent-no-op signature. No legitimate
# instance exists, so it is a doctor FAILURE, not a warning.
ATT_LOG="$PROJECT_ROOT/.specify/gates/attestations.jsonl"
if have jq && [[ -f "$ATT_LOG" ]]; then
    echo ""
    echo "Attestation evidence (latest record):"
    NOOP_GATES="$(tail -n 1 "$ATT_LOG" 2>/dev/null \
        | jq -r '(.gates // [])[]
            | select(.result == "pass" and ((.candidates // 0) > 0) and ((.checked // 0) == 0))
            | .name' 2>/dev/null || true)"
    if [[ -n "$NOOP_GATES" ]]; then
        for g in $NOOP_GATES; do
            echo "${BAD}suspected NO-OP gate: $g — latest run passed with candidates > 0 but checked = 0"
            MISSING=$((MISSING + 1))
        done
    else
        echo "${OK}no no-op signature"
    fi
fi

# Spec conformance (feature 002): what the spec gate sees. Discovery and
# parse counts are informational; a parse error is a doctor FAILURE (the
# gate fails closed on it, so surface it here with the same weight). A
# feature with every task checked but no Complete marker gets a nudge —
# enforcement is one Status flip away.
if declare -f gates_spec_features >/dev/null 2>&1 \
    && declare -f gates_policy_section_list >/dev/null 2>&1; then
    echo ""
    echo "Spec conformance (accept blocks in specs/*/tasks.md):"
    SPEC_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t gates-doctor-spec)"
    SPEC_FEATURES=0
    SPEC_BLOCKS=0
    SPEC_COMPLETE=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        SPEC_FEATURES=$((SPEC_FEATURES + 1))
        fdir="$PROJECT_ROOT/specs/$f"
        mkdir -p "$SPEC_TMP/$f"
        parse_out=""
        [[ -f "$fdir/tasks.md" ]] && parse_out="$(gates_spec_parse "$fdir/tasks.md" "$SPEC_TMP/$f")"
        nblocks=0
        tasks_total=0
        tasks_unchecked=0
        ferrors=0
        while IFS=$'\t' read -r tag a1 a2 rest; do
            [[ -z "$tag" ]] && continue
            case "$tag" in
                ERROR)
                    echo "${BAD}specs/$f/tasks.md:$a1: $a2"
                    MISSING=$((MISSING + 1))
                    ferrors=$((ferrors + 1))
                    ;;
                BLOCK) nblocks=$((nblocks + 1)) ;;
                TASKS)
                    tasks_total="$a1"
                    tasks_unchecked="$a2"
                    ;;
            esac
        done <<<"$parse_out"
        SPEC_BLOCKS=$((SPEC_BLOCKS + nblocks))
        if gates_spec_complete "$fdir/spec.md"; then
            SPEC_COMPLETE=$((SPEC_COMPLETE + 1))
            [[ "$ferrors" -eq 0 ]] \
                && echo "${OK}$f — Complete, $nblocks accept block(s), enforced"
        elif [[ "$tasks_total" -gt 0 && "$tasks_unchecked" -eq 0 ]]; then
            echo "${REC}$f — every task checked but Status is not Complete; set **Status**: Complete in spec.md to turn enforcement on"
        elif [[ "$ferrors" -eq 0 ]]; then
            echo "${SKIP}$f — $nblocks accept block(s), not enforced ($tasks_unchecked of $tasks_total tasks open)"
        fi
    done <<<"$(gates_spec_features "$PROJECT_ROOT")"
    rm -rf "$SPEC_TMP"
    echo "  $SPEC_FEATURES feature(s), $SPEC_BLOCKS accept block(s) parsed, $SPEC_COMPLETE complete"
fi

# Git boundary wiring (issues #20/#23): an INSTALLED hook that git will
# not run is silent enforcement loss — the worst class. Non-executable or
# non-delegating installed hooks are enforcement GAPS (exit 1); hooks that
# were never installed get a [rec] nudge only (agent+CI-only repos are a
# legitimate setup). Zip installs drop execute bits (Python extraction),
# which is exactly how downstream repos end up in the gap state.
if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo ""
    echo "Git boundary (hooks git actually runs):"
    GIT_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-dir)"
    [[ "$GIT_DIR" != /* ]] && GIT_DIR="$PROJECT_ROOT/$GIT_DIR"
    HOOKS_PATH="$(git -C "$PROJECT_ROOT" config core.hooksPath 2>/dev/null || true)"
    HOOK_DIR="$GIT_DIR/hooks"
    if [[ -n "$HOOKS_PATH" ]]; then
        [[ "$HOOKS_PATH" != /* ]] && HOOKS_PATH="$PROJECT_ROOT/$HOOKS_PATH"
        HOOK_DIR="$HOOKS_PATH"
        echo "${REC}core.hooksPath is set ($HOOKS_PATH) — a hook manager may own this boundary; the checks below inspect that path"
    fi
    for h in pre-commit commit-msg; do
        hf="$HOOK_DIR/$h"
        if [[ ! -f "$hf" ]]; then
            echo "${REC}$h not installed — the git boundary is not enforced here (run /speckit.gates.init to wire it)"
        elif [[ ! -x "$hf" ]]; then
            echo "${BAD}$h installed but NOT executable — git silently skips it (fix: chmod +x ${hf#"$PROJECT_ROOT"/})"
            MISSING=$((MISSING + 1))
        elif ! grep -q 'gates\|verify.sh' "$hf" 2>/dev/null; then
            echo "${REC}$h is executable but does not reference the gates runtime — another tool owns it; gates checks may not run on commit"
        else
            echo "${OK}$h installed, executable, delegates to the gates runtime"
        fi
    done
fi

# Policy contract (feature 003): what the contract gate sees, from local
# information only. Doctor fails on exactly the drift conditions the gate
# blocks on; a declared-but-never-synced contract gets the actionable
# nudge alongside the failure (the gate is already blocking runs).
if declare -f gates_contract_check >/dev/null 2>&1 \
    && declare -f gates_sha256 >/dev/null 2>&1; then
    gates_contract_paths "$PROJECT_ROOT"
    if gates_contract_declared "$CONTRACT_OVERLAY"; then
        echo ""
        echo "Policy contract (extends baseline):"
        echo "  source: $CONTRACT_SOURCE @ $CONTRACT_VERSION ($CONTRACT_BASEFILE)"
        if [[ ! -f "$CONTRACT_LOCK" && ! -f "$CONTRACT_SNAPSHOT" && ! -f "$CONTRACT_EFFECTIVE" ]]; then
            echo "${BAD}declared but never synced -- gate runs fail closed until the contract is materialized"
            echo "${REC}run /speckit.gates.sync (or: bash .specify/gates/contract.sh sync) to pin and materialize"
            MISSING=$((MISSING + 1))
        else
            gates_contract_check "$PROJECT_ROOT"
            if [[ "$CONTRACT_STATUS" == "pass" ]]; then
                echo "${OK}pinned $CONTRACT_PIN_DIGEST"
                echo "${OK}snapshot matches the pin; effective policy matches recomputation"
                if [[ -n "$CONTRACT_DEVIATIONS" ]]; then
                    echo "  deviations: $CONTRACT_WEAKENED weakened, $CONTRACT_CHANGED changed"
                    # shellcheck disable=SC2034  # dev_rest swallows the JSON-path field
                    while IFS=$'\t' read -r dev_class dev_path dev_from dev_to dev_rest; do
                        [[ -z "$dev_class" ]] && continue
                        echo "  [dev]  ($dev_class) $dev_path: baseline $dev_from -> overlay $dev_to"
                    done <<<"$CONTRACT_DEVIATIONS"
                else
                    echo "${OK}no deviations -- the overlay only adds or strengthens"
                fi
            else
                echo "${BAD}$CONTRACT_DETAIL"
                MISSING=$((MISSING + 1))
            fi
        fi
    fi
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
