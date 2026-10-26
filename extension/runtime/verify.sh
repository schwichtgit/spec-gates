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
# THIS policy. tests/test-parity.sh asserts it.
#
# Usage:
#   verify.sh --boundary agent|git|ci [--json] [--dry-run] [--accept <feature|all>]
#
# --accept additionally executes the named incomplete feature(s)' accept
# blocks as informational output (feature 002); complete features are
# enforced on every run regardless.
#
# Exit codes: 0 = all gates green, 1 = internal error (bad arguments, no jq,
# no or invalid policy; no gate ran), 2 = gate failure.
#
# With --json, an exit-1 refusal still prints exactly one object on stdout,
# {"result":"refused","boundary":...,"reason":...}, next to the stderr
# message, so a workflow step never parses empty output.

BOUNDARY="unspecified"
JSON=0
DRY_RUN=0
ACCEPT_ARG=""

# --json is known before the argument loop so an argument error can answer
# in JSON too.
for _arg in "$@"; do [[ "$_arg" == "--json" ]] && JSON=1; done

json_str() { # <text>: JSON string literal; pure bash, jq may be missing
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
    s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037')"
    printf '"%s"' "$s"
}

refused() { # <reason>: the --json refusal object (if --json), exit 1
    if [[ "$JSON" == "1" ]]; then
        printf '{"result":"refused","boundary":%s,"reason":%s}\n' \
            "$(json_str "$BOUNDARY")" "$(json_str "$1")"
    fi
    exit 1
}

refuse() { # <message>: no gate ran; stderr message, exit 1
    echo "gates: $1" >&2
    refused "$1"
}

usage() { # <message>: argument error, exit 1
    echo "gates: $1" >&2
    echo "usage: verify.sh --boundary agent|git|ci [--json] [--dry-run] [--accept <feature|all>]" >&2
    refused "$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --boundary)
            [[ $# -ge 2 && "$2" != -* ]] || usage "--boundary needs a value (agent, git or ci)"
            # A second --boundary would replace the first: in CI,
            # `--boundary ci --boundary agent` runs the agent set (#198).
            [[ "$BOUNDARY" == unspecified ]] || usage "--boundary given more than once"
            case "$2" in
                agent | git | ci) BOUNDARY="$2" ;;
                *) usage "--boundary: invalid value: $2 (allowed: agent, git, ci)" ;;
            esac
            shift 2
            ;;
        --json)     JSON=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --accept)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || usage "--accept needs a feature name or all"
            ACCEPT_ARG="$2"
            shift 2
            ;;
        *) usage "unknown argument: $1" ;;
    esac
done
# Without --boundary the run is the 0.3.6 one (#216): every gate, boundary
# "unspecified". It warns instead of refusing, so callers written for
# 0.3.6 keep working after an upgrade; a later release may require it.
if [[ "$BOUNDARY" == "unspecified" ]]; then
    echo "gates: warning: verify.sh without --boundary is deprecated; it runs every gate as before, and a later release may refuse it. Pass --boundary agent|git|ci" >&2
fi
# Every gate command (project gates, the task and custom steps, the walk)
# can read the boundary it runs at (feature 006, FR-010); "none" is a run
# without --boundary, at which no skip declaration applies.
GATES_BOUNDARY="$BOUNDARY"
[[ "$BOUNDARY" == "unspecified" ]] && GATES_BOUNDARY="none"
export GATES_BOUNDARY

# GATES_POLICY_FILE replaces the whole policy (#196): set for one command
# it would drop every gate the repository declares. The git and CI
# boundaries judge the policy the repository commits, so they ignore it,
# and so does a run without --boundary (#216); at the agent boundary it
# applies. Either way the run says so (stderr, --json and the
# attestation's policy_override).
POLICY_OVERRIDE="${GATES_POLICY_FILE:-}"
POLICY_OVERRIDE_JSON=""
POLICY_OVERRIDE_APPLIED=""
POLICY_OVERRIDE_WHERE="at the $BOUNDARY boundary"
[[ "$BOUNDARY" == "unspecified" ]] && POLICY_OVERRIDE_WHERE="without --boundary"
if [[ -n "$POLICY_OVERRIDE" ]]; then
    case "$BOUNDARY" in
        git | ci | unspecified)
            unset GATES_POLICY_FILE
            POLICY_OVERRIDE_APPLIED=false
            echo "gates: GATES_POLICY_FILE=$POLICY_OVERRIDE is ignored $POLICY_OVERRIDE_WHERE; the repository's policy applies" >&2
            ;;
        *)
            POLICY_OVERRIDE_APPLIED=true
            echo "gates: GATES_POLICY_FILE=$POLICY_OVERRIDE replaces the repository's policy for this run" >&2
            ;;
    esac
    POLICY_OVERRIDE_JSON="{\"file\":$(json_str "$POLICY_OVERRIDE"),\"applied\":$POLICY_OVERRIDE_APPLIED}"
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_DIR="$PROJECT_ROOT/.specify/gates"
POLICY_FILE="$GATES_DIR/policy.json"

if ! command -v jq >/dev/null 2>&1; then
    refuse "jq not found — cannot evaluate policy (run /speckit.gates.doctor)"
fi
# The spec gate proves with git that an accept block left the tree
# unchanged; without git that check would pass blind (#121). Exit 1 like
# jq: the Stop hook then lets the session end instead of locking it.
if ! command -v git >/dev/null 2>&1; then
    refuse "git not found — cannot check the working tree (run /speckit.gates.doctor)"
fi
if [[ ! -f "$POLICY_FILE" ]]; then
    refuse "no policy at $POLICY_FILE (run /speckit.gates.init)"
fi

# Path is resolved at runtime from the projected layout; the source= hint helps
# `shellcheck -x` runs, disable=SC1091 silences the unavoidable static miss.
# shellcheck source=lib/policy.sh disable=SC1091
source "$GATES_DIR/lib/policy.sh"
# shellcheck source=lib/attest.sh disable=SC1091
source "$GATES_DIR/lib/attest.sh"
# shellcheck source=lib/watch.sh disable=SC1091
source "$GATES_DIR/lib/watch.sh"
# shellcheck source=lib/spec-gate.sh disable=SC1091
source "$GATES_DIR/lib/spec-gate.sh"
# shellcheck source=lib/contract.sh disable=SC1091
source "$GATES_DIR/lib/contract.sh"

# The loader reads the policy fail-open (a missing or unreadable field is a
# default), so a malformed or schema-invalid policy would silently drop
# gates. Refuse it like a missing policy (#124), before any gate runs: the
# same exit 1, which the Stop hook treats as a setup error (it allows the
# stop and says why) and the git and CI boundaries as a failure.
if ! gates_validate_policy "$(gates_policy_file)"; then
    refuse "invalid policy, no gate ran; fix the errors above (run /speckit.gates.doctor)"
fi

# An unknown --accept name is an argument error: refuse it here, before
# any gate runs (also under --dry-run), not after the lint gates (#179).
if [[ -n "$ACCEPT_ARG" && "$ACCEPT_ARG" != "all" ]]; then
    if ! grep -qx -- "$ACCEPT_ARG" <<<"$(gates_spec_features "$PROJECT_ROOT")"; then
        AVAILABLE="$(gates_spec_features "$PROJECT_ROOT" | paste -sd ' ' -)"
        refuse "--accept: unknown feature: $ACCEPT_ARG (available: ${AVAILABLE:-none})"
    fi
fi

# ---------------------------------------------------------------------------
# Gate-level lock (#263): two runs in one working tree see each other's
# writes (build output, test files) and fail each other. A run holds the
# directory .specify/gates/.lock (mkdir is atomic; macOS has no flock),
# with its pid, boundary and process start time in .lock/owner. A second
# run at the agent boundary skips (exit 0: the Stop hook must not wait on
# a commit); at git, ci and without --boundary it waits up to
# GATES_LOCK_WAIT_S seconds (default 600), then refuses (exit 1). A lock
# whose process is gone is stale and taken over. A run started from
# inside the holder (an accept block, a hook it triggers) finds its
# holder's pid in GATES_LOCK_PID and runs without the lock. --dry-run
# takes no lock.
# ---------------------------------------------------------------------------
LOCK_DIR="$GATES_DIR/.lock"
LOCK_HELD=0
LOCK_PID=""
LOCK_BOUNDARY=""
LOCK_START=""

gates_proc_start() { # <pid>: its start time as ps prints it; empty if unknown
    ps -o lstart= -p "$1" 2>/dev/null || true
}

gates_lock_read() { # sets LOCK_PID, LOCK_BOUNDARY, LOCK_START from .lock/owner
    LOCK_PID=""; LOCK_BOUNDARY=""; LOCK_START=""
    [[ -f "$LOCK_DIR/owner" ]] || return 0
    { IFS= read -r LOCK_PID; IFS= read -r LOCK_BOUNDARY; IFS= read -r LOCK_START; } \
        <"$LOCK_DIR/owner" 2>/dev/null || true
    [[ "$LOCK_PID" =~ ^[0-9]+$ ]] || LOCK_PID=""
}

gates_lock_alive() { # true if the process in LOCK_PID still runs (same start)
    [[ -n "$LOCK_PID" ]] || return 1
    kill -0 "$LOCK_PID" 2>/dev/null || ps -p "$LOCK_PID" >/dev/null 2>&1 || return 1
    # A reused pid (the holder died, e.g. kill -9 or a reboot) is another
    # process: compare start times when ps reports them.
    local now
    now="$(gates_proc_start "$LOCK_PID")"
    [[ -z "$LOCK_START" || -z "$now" || "$now" == "$LOCK_START" ]]
}

# shellcheck disable=SC2329  # called from the traps below
gates_lock_release() {
    rm -f "/tmp/gates-out.$$" "/tmp/gates-out.$$.timedout"
    [[ "$LOCK_HELD" == "1" ]] || return 0
    LOCK_HELD=0
    gates_lock_read
    [[ "$LOCK_PID" == "$$" ]] && rm -rf "$LOCK_DIR"
    return 0
}

gates_lock_acquire() {
    local limit="${GATES_LOCK_WAIT_S:-600}" waited=0 announced=0 unowned=0 own_start
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=600
    # Known before the mkdir, so owner follows it within a printf and a mv.
    own_start="$(gates_proc_start $$)"
    while :; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_HELD=1
            if ! printf '%s\n%s\n%s\n' "$$" "$BOUNDARY" "$own_start" \
                    >"$LOCK_DIR/owner.$$" 2>/dev/null \
                || ! mv -f "$LOCK_DIR/owner.$$" "$LOCK_DIR/owner" 2>/dev/null; then
                echo "gates: warning: could not write $LOCK_DIR/owner; another gate run may treat the lock as stale" >&2
            fi
            export GATES_LOCK_PID="$$"
            return 0
        fi
        if [[ ! -e "$LOCK_DIR" ]]; then
            # Not creatable (a read-only checkout): run unlocked, say so.
            echo "gates: warning: cannot create $LOCK_DIR; running without the gate lock" >&2
            return 0
        fi
        gates_lock_read
        if [[ -z "$LOCK_PID" ]]; then
            # The holder writes owner right after its mkdir; give it a few
            # seconds before an ownerless lock counts as stale.
            unowned=$((unowned + 1))
            if [[ "$unowned" -lt 3 ]]; then
                sleep 1
                waited=$((waited + 1))
                continue
            fi
        elif [[ "$LOCK_PID" == "${GATES_LOCK_PID:-}" ]] && gates_lock_alive; then
            return 0 # nested in the holder's run
        elif gates_lock_alive; then
            unowned=0
            if [[ "$BOUNDARY" == "agent" ]]; then
                local why="skipped: the gate run of pid $LOCK_PID ($LOCK_BOUNDARY) is in progress"
                echo "gates: $why" >&2
                if [[ "$JSON" == "1" ]]; then
                    printf '{"result":"skipped","boundary":%s,"reason":%s}\n' \
                        "$(json_str "$BOUNDARY")" "$(json_str "$why")"
                fi
                exit 0
            fi
            if [[ "$waited" -ge "$limit" ]]; then
                refuse "the gate run of pid $LOCK_PID ($LOCK_BOUNDARY) still holds $LOCK_DIR after ${limit}s, no gate ran (GATES_LOCK_WAIT_S sets the wait)"
            fi
            if [[ "$announced" == "0" ]]; then
                echo "gates: waiting for the gate run of pid $LOCK_PID ($LOCK_BOUNDARY)" >&2
                announced=1
            fi
            sleep 1
            waited=$((waited + 1))
            continue
        fi
        echo "gates: note: taking over the stale gate lock of pid ${LOCK_PID:-unknown} (${LOCK_BOUNDARY:-unknown}), which is no longer running" >&2
        unowned=0
        # Renamed first, then checked: of two runs taking over at once, the
        # later mv may catch the lock the first one just made, and puts it
        # back. Best effort; the window is a few file operations wide.
        local stale_pid="$LOCK_PID" moved="$LOCK_DIR.stale.$$"
        if mv "$LOCK_DIR" "$moved" 2>/dev/null; then
            LOCK_PID=""
            [[ -f "$moved/owner" ]] && { IFS= read -r LOCK_PID <"$moved/owner" || true; } 2>/dev/null
            # (mv onto an existing directory would move it inside.)
            if [[ -n "$LOCK_PID" && "$LOCK_PID" != "$stale_pid" && ! -e "$LOCK_DIR" ]] \
                && mv "$moved" "$LOCK_DIR" 2>/dev/null; then
                continue
            fi
            rm -rf "$moved" 2>/dev/null || true
        elif [[ -e "$LOCK_DIR" ]]; then
            echo "gates: warning: cannot remove the stale $LOCK_DIR; running without the gate lock" >&2
            return 0
        fi
    done
}

if [[ "$DRY_RUN" != "1" ]]; then
    trap 'gates_lock_release' EXIT
    trap 'gates_lock_release; exit 130' INT
    trap 'gates_lock_release; exit 143' TERM
    gates_lock_acquire
fi

FAILED=0
WARNINGS=0
declare -a RESULTS=()
declare -a SUMMARIES=()
declare -a ATT_GATES=()
# Tools whose pins were looked up; the parity gate checks their pin
# sources for conflicts and unreadable mise files (#260).
declare -a PIN_TOOLS=()

# <summary> is the one line the text report prints for the gate; without
# it the report prints the first line of <detail>.
record() { # name status detail [summary]
    RESULTS+=("{\"name\":\"$1\",\"status\":\"$2\",\"detail\":$(jq -Rn --arg d "$3" '$d')}")
    SUMMARIES+=("${4:-}")
}

# Append a GateEntry (attestation shape, data-model.md) for an evaluated
# gate. Empty strings become JSON null for the nullable fields.
# [declared_skip] is the boundary a skip declaration named (feature 006):
# written only when set, so every other entry keeps the feature 001 shape.
att_gate() { # name bin version pinned candidates checked result reason duration_s [declared_skip]
    ATT_GATES+=("$(jq -cn \
        --arg name "$1" --arg bin "$2" --arg version "$3" --arg pinned "$4" \
        --arg candidates "$5" --arg checked "$6" --arg result "$7" \
        --arg reason "$8" --arg duration "$9" --arg declared_skip "${10:-}" '
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
          duration_s: ($duration | tonumber) }
        + (if $declared_skip == "" then {} else { declared_skip: $declared_skip } end)')")
}

# Watched mode (project gates, feature 006): run_project_gate sets
# WATCH_S to the gate's time limit and WATCH_CMD to its command for one
# run_gate call. The command then runs from the project root under
# gates_run_watched (lib/watch.sh), in this shell, so GATES_WATCH_DETAIL
# survives; everything else (output capture, the summary rules, the
# severity mapping, FAILED/WARNINGS, att_gate) is the same code path.
WATCH_S=""
WATCH_CMD=""

run_gate() { # name severity cmd...
    local name="$1" severity="$2"; shift 2
    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ -n "$WATCH_S" ]]; then
            record "$name" "planned" "$WATCH_CMD (time limit ${WATCH_S}s)"
        else
            record "$name" "planned" "$*"
        fi
        return 0
    fi
    local start end rc=0
    start="$(date +%s)"
    if [[ -n "$WATCH_S" ]]; then
        local here="$PWD"
        cd "$PROJECT_ROOT" || return 1
        gates_run_watched "$WATCH_S" "/tmp/gates-out.$$" "$@" || rc=$?
        cd "$here" || true
    else
        "$@" >/tmp/gates-out.$$ 2>&1 || rc=$?
    fi
    end="$(date +%s)"

    # Check-mode metadata (##gates-meta##, emitted by formatter-dispatch) is
    # machinery, not gate output: parse it for the attestation entry, strip
    # it from the visible detail. Non-file gates (task/custom) have none,
    # and a project gate's is never read: its command could print one and
    # claim a tool, counts or a skip.
    local meta="" binname="" bin="" candidates="" checked="" skipped=""
    if [[ -z "$WATCH_S" ]]; then
        meta="$(grep '##gates-meta##' /tmp/gates-out.$$ 2>/dev/null | tail -n 1 || true)"
    fi
    if [[ -n "$meta" ]]; then
        binname="$(printf '%s' "$meta" | sed -n 's/.* binname=\([^ ]*\).*/\1/p')"
        candidates="$(printf '%s' "$meta" | sed -n 's/.* candidates=\([0-9]*\).*/\1/p')"
        checked="$(printf '%s' "$meta" | sed -n 's/.* checked=\([0-9]*\).*/\1/p')"
        skipped="$(printf '%s' "$meta" | sed -n 's/.* skipped=\([^ ]*\).*/\1/p')"
        bin="$(printf '%s' "$meta" | sed -n 's/.* bin=//p')"
    fi
    # The detail keeps the output's last 2000 bytes, whose first line is
    # wherever the cut fell (#262). The summary is read from the whole
    # output instead: its last "##gates-fail## <text>" line (the file
    # linters' dispatch marks their first finding so), else, for a file
    # linter, the first non-empty line, and for a task or custom step,
    # which ends on its verdict, the last one. The marker is machinery
    # too and never shows in the detail.
    local detail summary
    detail="$(grep -v '##gates-meta##' /tmp/gates-out.$$ \
        | sed 's/##gates-fail##[[:space:]]*//' | tail -c 2000 || true)"
    summary="$(grep '##gates-fail##' /tmp/gates-out.$$ 2>/dev/null | tail -n 1 \
        | sed 's/.*##gates-fail##[[:space:]]*//' || true)"
    if [[ -z "$summary" ]]; then
        local pick='$'
        [[ -n "$meta" ]] && pick=1
        summary="$(grep -v '##gates-meta##' /tmp/gates-out.$$ \
            | grep -v '^[[:space:]]*$' | sed -n "${pick}p" || true)"
    fi
    rm -f /tmp/gates-out.$$

    local version="" pinned=""
    if [[ -n "$binname" ]]; then
        version="$(gates_tool_version "$binname" "$PROJECT_ROOT")"
        pinned="$(gates_pin_version "$binname" "$PROJECT_ROOT")"
        PIN_TOOLS+=("$binname")
    fi
    [[ -n "$bin" && "$bin" == "$PROJECT_ROOT/"* ]] && bin="${bin#"$PROJECT_ROOT"/}"

    # A missing tool is skipped with a reason, never pass (spec edge case).
    # The attestation reason carries no tool output: output can quote file
    # contents, which FR-011 keeps out of records.
    # A project gate that timed out or could not start fails whatever its
    # severity (fail closed, research R3/R4); the reasons are fixed strings.
    local result reason=""
    if [[ -n "$WATCH_S" && "$rc" -eq 124 && -n "${GATES_WATCH_DETAIL:-}" ]]; then
        result="fail"; reason="$GATES_WATCH_DETAIL"; summary="$GATES_WATCH_DETAIL"
    elif [[ -n "$WATCH_S" && ( "$rc" -eq 126 || "$rc" -eq 127 ) ]]; then
        result="fail"; reason="command not found or not executable"
        [[ -n "$summary" ]] || summary="$reason"
    elif [[ "$rc" -eq 0 && -n "$skipped" ]]; then
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
        fail) record "$name" "fail" "$detail" "$summary"; FAILED=$((FAILED + 1)) ;;
        warn) record "$name" "warn" "$detail" "$summary"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
    att_gate "$name" "$bin" "$version" "$pinned" "$candidates" "$checked" \
        "$result" "$reason" "$((end - start))"
}

# ---------------------------------------------------------------------------
# Contract gate (feature 003): when policy.json extends a versioned baseline,
# prove — offline, before any gate consults the policy — that the committed
# snapshot matches the pin, the effective policy matches recomputation, and
# the declaration matches what was synced. Policy integrity precedes policy
# enforcement, so this runs before the tool gates. Dormant (no extends): no
# gate entry at all. Deviations are informational and never change the exit
# code (FR-006).
# ---------------------------------------------------------------------------
CONTRACT_ATT_JSON=""
contract_start="$(date +%s)"
gates_contract_check "$PROJECT_ROOT"
contract_end="$(date +%s)"
if [[ "$CONTRACT_STATUS" != "dormant" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        record "contract" "planned" "baseline contract integrity (extends)"
    elif [[ "$CONTRACT_STATUS" == "pass" ]]; then
        record "contract" "pass" ""
        att_gate "contract" "" "" "" "" "" "pass" "" "$((contract_end - contract_start))"
        if [[ "$JSON" == "0" && -n "$CONTRACT_DEVIATIONS" ]]; then
            gates_contract_print_deviations "contract: deviation " <<<"$CONTRACT_DEVIATIONS"
        fi
    else
        # A broken contract is never a warning: fixed error severity (R6).
        record "contract" "fail" "$CONTRACT_DETAIL"
        FAILED=$((FAILED + 1))
        att_gate "contract" "" "" "" "" "" "fail" "$CONTRACT_DETAIL" "$((contract_end - contract_start))"
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
        CONTRACT_ATT_JSON="$(jq -cn --arg s "$CONTRACT_SOURCE" --arg v "$CONTRACT_VERSION" \
            --arg d "$CONTRACT_PIN_DIGEST" --arg e "$CONTRACT_EFFECTIVE_SHA256" \
            --argjson w "${CONTRACT_WEAKENED:-0}" --argjson c "${CONTRACT_CHANGED:-0}" '
            { source: $s, version: $v,
              digest: (if $d == "" then null else $d end),
              effective_sha256: (if $e == "" then null else $e end),
              deviations: { weakened: $w, changed: $c } }')"
    fi
fi

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

# ---------------------------------------------------------------------------
# Project gates (feature 006): hooks.verify-quality.gates, run after the
# orchestrator's gates whatever it is, one at a time in key order, each as
# `sh -c "<command>"` from the project root under its time limit (timeout_s,
# else gate_timeout_s, else 600). Each is its own gate in the report,
# --json and the attestation; the tool fields stay null (a command, not a
# resolved tool). A timeout or a command that cannot start (126, 127)
# fails; any other non-zero exit maps through the gate's severity.
# A gate whose skip_at names this boundary (agent or git; never ci) does not
# start: it is recorded as skipped "by declaration at <boundary>", counts as
# neither passed, failed nor warned, and its attestation entry carries
# declared_skip (gates_declared_skip, lib/policy.sh, research R6).
# ---------------------------------------------------------------------------
run_project_gate() { # name severity timeout-s command
    WATCH_S="$3"
    WATCH_CMD="$4"
    local rc=0
    run_gate "$1" "$2" sh -c "$4" || rc=$?
    WATCH_S=""
    WATCH_CMD=""
    return "$rc"
}

declare -a PROJECT_GATES=()
while IFS= read -r pg_name; do
    [[ -n "$pg_name" ]] && PROJECT_GATES+=("$pg_name")
done < <(gates_project_gate_names)
if [[ ${#PROJECT_GATES[@]} -gt 0 ]]; then
    PG_DEFAULT_S="$(gates_policy_get "verify-quality" "gate_timeout_s")"
    [[ -z "$PG_DEFAULT_S" ]] && PG_DEFAULT_S=600
    for pg_name in "${PROJECT_GATES[@]}"; do
        pg_sev="$(gates_project_gate_get "$pg_name" severity)"
        [[ -z "$pg_sev" ]] && pg_sev="error"
        pg_s="$(gates_project_gate_get "$pg_name" timeout_s)"
        [[ -z "$pg_s" ]] && pg_s="$PG_DEFAULT_S"
        if pg_skip="$(gates_declared_skip "$BOUNDARY" "$(gates_project_gate_skip_at "$pg_name")")"; then
            if [[ "$DRY_RUN" == "1" ]]; then
                record "$pg_name" "planned" "$(gates_project_gate_get "$pg_name" command) (time limit ${pg_s}s; $pg_skip)"
            else
                record "$pg_name" "skipped" "$pg_skip"
                att_gate "$pg_name" "" "" "" "" "" "skipped" "$pg_skip" 0 "$BOUNDARY"
            fi
            continue
        fi
        run_project_gate "$pg_name" "$pg_sev" "$pg_s" "$(gates_project_gate_get "$pg_name" command)"
    done
fi

# ---------------------------------------------------------------------------
# Spec-conformance gate (feature 002): fenced accept blocks in specs/*/tasks.md
# run as executable acceptance criteria. Complete features (spec.md Status:
# Complete) are enforced at spec.severity; the rest is informational.
# GATES_SPEC_EXEC is the recursion guard: accept blocks export it, so a block
# that invokes verify.sh does not re-enter accept-block execution. Any caller
# can set it, so a guarded run records the spec gate as skipped with the
# reason (text, --json and the attestation) instead of dropping it (#164).
# ---------------------------------------------------------------------------
SPEC_ENABLED="$(gates_policy_section_get spec enabled)"
SPEC_ATT_JSON=""
if [[ "$SPEC_ENABLED" != "false" && -n "${GATES_SPEC_EXEC:-}" ]]; then
    SPEC_SKIP_REASON="GATES_SPEC_EXEC is set (run from inside an accept block), so accept blocks did not run"
    record "spec" "skipped" "$SPEC_SKIP_REASON"
    if [[ "$DRY_RUN" != "1" ]]; then
        att_gate "spec" "" "" "" "" "" "skipped" "$SPEC_SKIP_REASON" 0
    fi
elif [[ "$SPEC_ENABLED" != "false" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        record "spec" "planned" "spec conformance (accept blocks)"
    else
        SPEC_SEV="$(gates_policy_section_get spec severity)"
        [[ -z "$SPEC_SEV" ]] && SPEC_SEV="error"
        spec_start="$(date +%s)"
        gates_spec_gate "$PROJECT_ROOT" "$ACCEPT_ARG" "$JSON"
        spec_end="$(date +%s)"
        # Attestation candidates/checked count accept blocks of ENFORCED
        # features, not features discovered: a Complete feature with zero
        # blocks is a legitimate "nothing to check", and counting features
        # made it indistinguishable from a silently broken gate — doctor's
        # no-op heuristic then false-positived on healthy IaC/docs repos
        # (issue #32). Enforced blocks that exist but never execute keep
        # producing the real no-op signature.
        SPEC_ENF_BLOCKS="$(jq -r \
            '[.[] | select(.outcome | startswith("enforced")) | .blocks_parsed] | add // 0' \
            <<<"$SPEC_RESULTS_JSON")"
        SPEC_ENF_EXECUTED="$(jq -r \
            '[.[] | select(.outcome | startswith("enforced")) | .blocks_executed] | add // 0' \
            <<<"$SPEC_RESULTS_JSON")"
        if [[ "$SPEC_RESULT" == "pass" ]]; then
            record "spec" "pass" ""
            att_gate "spec" "" "" "" "$SPEC_ENF_BLOCKS" "$SPEC_ENF_EXECUTED" \
                "pass" "" "$((spec_end - spec_start))"
        elif [[ "$SPEC_SEV" == "error" ]]; then
            record "spec" "fail" "$SPEC_DETAIL"
            FAILED=$((FAILED + 1))
            att_gate "spec" "" "" "" "$SPEC_ENF_BLOCKS" "$SPEC_ENF_EXECUTED" \
                "fail" "$SPEC_DETAIL" "$((spec_end - spec_start))"
        else
            record "spec" "warn" "$SPEC_DETAIL"
            WARNINGS=$((WARNINGS + 1))
            att_gate "spec" "" "" "" "$SPEC_ENF_BLOCKS" "$SPEC_ENF_EXECUTED" \
                "warn" "$SPEC_DETAIL" "$((spec_end - spec_start))"
        fi
        SPEC_ATT_JSON="$(jq -cn --argjson features "$SPEC_FEATURES" \
            --argjson parsed "$SPEC_PARSED" --argjson executed "$SPEC_EXECUTED" \
            --argjson passed "$SPEC_PASSED" --argjson failed "$SPEC_FAILED" \
            --argjson results "$SPEC_RESULTS_JSON" '
            { features: $features, parsed: $parsed, executed: $executed,
              passed: $passed, failed: $failed, results: $results }')"
    fi
fi

ATT_ENABLED="$(gates_policy_section_get attestation enabled)"

# ---------------------------------------------------------------------------
# Synthetic parity gate (R7): every boundary compares the tool versions just
# detected against the lockfile pins, so agent, git, and CI runs are proven
# equivalent transitively — no attestation transport needed. Severity comes
# from attestation.parity (default error; warning reports without failing;
# off omits the entry). Disabled attestations disable parity too. --dry-run
# lists it as planned, like every other gate it would run.
# ---------------------------------------------------------------------------
PARITY_SEV="$(gates_policy_section_get attestation parity)"
[[ -z "$PARITY_SEV" ]] && PARITY_SEV="error"
if [[ "$DRY_RUN" == "1" && "$ATT_ENABLED" != "false" && "$PARITY_SEV" != "off" ]]; then
    record "parity" "planned" "tool versions against lockfile pins"
elif [[ "$DRY_RUN" != "1" &&"$ATT_ENABLED" != "false" && "$PARITY_SEV" != "off" ]]; then
    parity_input="[]"
    if [[ ${#ATT_GATES[@]} -gt 0 ]]; then
        parity_input="[$(IFS=,; printf '%s' "${ATT_GATES[*]}")]"
    fi
    PARITY_DRIFT="$(gates_pin_mismatches "$parity_input")"
    # A pin the sources disagree on, or a mise file that cannot be read,
    # fails like drift: the comparison above would rest on a guess.
    # Each problem is named once, however many tools or configs repeat it.
    pin_problems=""
    if [[ ${#PIN_TOOLS[@]} -gt 0 ]]; then
        pin_problems="$(for pin_tool in "${PIN_TOOLS[@]}"; do
            gates_pin_problems "$pin_tool" "$PROJECT_ROOT"
        done | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep = "; " }')"
    fi
    [[ -n "$pin_problems" ]] && PARITY_DRIFT="$pin_problems${PARITY_DRIFT:+; $PARITY_DRIFT}"
    # The gate set (feature 006, research R7): every project gate the policy
    # declares ran, or, at agent and git, was skipped by a declaration naming
    # this boundary. At ci every declared gate must have run (constitution,
    # Principle III). Reported next to any version drift, not instead of it.
    if pg_declared="$(gates_project_gates_declared)"; then
        pg_unrun="$(gates_declared_not_run "$GATES_BOUNDARY" "$pg_declared" "$parity_input")"
    else
        pg_unrun="declared gates not run at $GATES_BOUNDARY: the policy's gate set could not be read"
    fi
    [[ -n "$pg_unrun" ]] && PARITY_DRIFT="${PARITY_DRIFT:+$PARITY_DRIFT; }$pg_unrun"
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
    # The hash is of the policy the run actually enforced: the materialized
    # effective policy in a contract repo, policy.json everywhere else.
    if POLICY_SHA="$(gates_sha256 "$(gates_policy_file)")"; then
        RUNTIME_VERSION=""
        if [[ -f "$GATES_DIR/.runtime-version" ]]; then
            RUNTIME_VERSION="$(head -n 1 "$GATES_DIR/.runtime-version" 2>/dev/null || true)"
        fi
        ATT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        att_joined=""
        if [[ ${#ATT_GATES[@]} -gt 0 ]]; then
            att_joined="$(IFS=,; printf '%s' "${ATT_GATES[*]}")"
        fi
        # The optional spec (002), contract (003) and policy_override (#196)
        # objects are additive; v stays 1 and consumers ignore unknown fields (001 rule).
        ATTESTATION="$(jq -cn --arg ts "$ATT_TS" --arg boundary "$BOUNDARY" \
            --arg sha "$POLICY_SHA" --arg rv "$RUNTIME_VERSION" \
            --argjson exit "$EXIT_CODE" --argjson gates "[$att_joined]" \
            --argjson spec "${SPEC_ATT_JSON:-null}" \
            --argjson contract "${CONTRACT_ATT_JSON:-null}" \
            --argjson override "${POLICY_OVERRIDE_JSON:-null}" '
            { v: 1,
              ts: $ts,
              boundary: (if ["agent","git","ci"] | index($boundary) then $boundary else "unspecified" end),
              policy_sha256: $sha,
              runtime_version: (if $rv == "" then null else $rv end),
              exit: $exit,
              gates: $gates }
            + (if $spec != null then { spec: $spec } else {} end)
            + (if $contract != null then { contract: $contract } else {} end)
            + (if $override != null then { policy_override: $override } else {} end)')"
        MAX_RECORDS="$(gates_policy_section_get attestation max_records)"
        [[ -z "$MAX_RECORDS" ]] && MAX_RECORDS=200
        if ! gates_attest_append "$ATTESTATION" "$GATES_DIR/attestations.jsonl" "$MAX_RECORDS"; then
            echo "gates: warning: could not write $GATES_DIR/attestations.jsonl, so this run left no evidence record (gate outcome unaffected; run /speckit.gates.doctor)" >&2
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
    override_field=""
    [[ -n "$POLICY_OVERRIDE_JSON" ]] && override_field=",\"policy_override\":$POLICY_OVERRIDE_JSON"
    if [[ -n "$ATTESTATION" ]]; then
        printf '{"boundary":"%s","failed":%d,"warnings":%d%s,"gates":[%s],"attestation":%s}\n' \
            "$BOUNDARY" "$FAILED" "$WARNINGS" "$override_field" "$joined" "$ATTESTATION"
    else
        printf '{"boundary":"%s","failed":%d,"warnings":%d%s,"gates":[%s]}\n' \
            "$BOUNDARY" "$FAILED" "$WARNINGS" "$override_field" "$joined"
    fi
else
    echo "gates: boundary=$BOUNDARY failed=$FAILED warnings=$WARNINGS"
    if [[ "$POLICY_OVERRIDE_APPLIED" == "true" ]]; then
        echo "  [override] policy -- GATES_POLICY_FILE=$POLICY_OVERRIDE was enforced instead of the repository's policy"
    elif [[ -n "$POLICY_OVERRIDE" ]]; then
        echo "  [override] policy -- GATES_POLICY_FILE=$POLICY_OVERRIDE was ignored $POLICY_OVERRIDE_WHERE"
    fi
    if [[ ${#RESULTS[@]} -gt 0 ]]; then
        i=0
        for r in "${RESULTS[@]}"; do
            name="$(printf '%s' "$r" | jq -r '.name')"
            status="$(printf '%s' "$r" | jq -r '.status')"
            detail="${SUMMARIES[i]}"
            i=$((i + 1))
            if [[ -z "$detail" ]]; then
                detail="$(jq -r '.detail' <<<"$r")"
                detail="${detail%%$'\n'*}"
            fi
            if [[ -n "$detail" ]]; then
                echo "  [$status] $name -- $detail"
            else
                echo "  [$status] $name"
            fi
        done
    fi
fi

exit "$EXIT_CODE"
