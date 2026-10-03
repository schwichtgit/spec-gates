#!/usr/bin/env bash
# local-hooks.sh -- project-owned rules that survive upgrades (#71).
#
# A project adds its own refusals as scripts in
#   .specify/gates/hooks.local.d/<hook>/*.sh
# where <hook> is protect-files, validate-bash, validate-pr, pre-commit or
# commit-msg. projection, upgrades and the manifest never touch that
# directory. Each hook runs the rules only after every shipped check
# allowed, so a rule can add a refusal but never remove one.
#
# Usage (sourced; bash 3.2):
#   gates_local_has <root> <hook>          # 0 if the hook has local rules
#   gates_run_local <root> <hook> [args]   # 0 = every rule allowed;
#                                          # 1 = refused, GATES_LOCAL_MSG set
#
# Each rule runs as `bash <rule> [args]` (execute bits do not matter), with
# GATES_LOCAL_STDIN on its stdin (the agent hooks pass the tool call JSON;
# the git hooks pass nothing), GATES_HOOK=<hook> and
# GATES_PROJECT_ROOT=<root> in its environment. Exit 0 allows; any other
# exit refuses, and the rule's stderr becomes the refusal message. Rules
# run in lexical order and the first refusal wins. A rule that cannot be
# read refuses: a rule the project wrote must never silently not run.

# shellcheck disable=SC2034   # library file; GATES_LOCAL_MSG is read by callers
GATES_LOCAL_MSG=""
GATES_LOCAL_STDIN="${GATES_LOCAL_STDIN:-}"

gates_local_has() { # <root> <hook>
    local f
    for f in "$1/.specify/gates/hooks.local.d/$2"/*.sh; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

gates_run_local() { # <root> <hook> [args...]
    local root="$1" hook="$2" f name out rc
    shift 2
    GATES_LOCAL_MSG=""
    for f in "$root/.specify/gates/hooks.local.d/$hook"/*.sh; do
        [[ -e "$f" ]] || continue
        name="${f##*/}"
        if [[ ! -f "$f" || ! -r "$f" ]]; then
            GATES_LOCAL_MSG="gates(local $hook/$name): the rule cannot be read, so it refuses"
            return 1
        fi
        rc=0
        out="$(printf '%s' "$GATES_LOCAL_STDIN" \
            | GATES_HOOK="$hook" GATES_PROJECT_ROOT="$root" bash "$f" "$@" 2>&1 >/dev/null)" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            GATES_LOCAL_MSG="gates(local $hook/$name): ${out:-refused (exit $rc)}"
            return 1
        fi
    done
    return 0
}
