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
# read (unreadable, a directory, a dangling symlink) refuses: a rule the
# project wrote must never silently not run. A rule still running after
# GATES_LOCAL_TIMEOUT seconds (default 10) is killed and refuses.

# shellcheck disable=SC2034   # library file; GATES_LOCAL_MSG is read by callers
GATES_LOCAL_MSG=""
GATES_LOCAL_STDIN="${GATES_LOCAL_STDIN:-}"

gates_local_has() { # <root> <hook>
    local f
    for f in "$1/.specify/gates/hooks.local.d/$2"/*.sh; do
        [[ -e "$f" || -L "$f" ]] && return 0
    done
    return 1
}

# _gates_local_exec <rule> [args...]: run one rule with GATES_LOCAL_STDIN on
# its stdin (a here-string: a rule that never reads stdin must not turn a
# large tool call into SIGPIPE), its stderr on stdout, and a watchdog. Exit
# 124 when the watchdog killed it.
_gates_local_exec() {
    local f="$1" limit="${GATES_LOCAL_TIMEOUT:-10}" pid wd rc=0 flag
    shift
    flag="$(mktemp 2>/dev/null || mktemp -t gates-local)" || return 1
    : >"$flag"
    # set -m gives the rule its own process group, so the watchdog can kill
    # whatever the rule started, not just the rule's shell.
    set -m
    GATES_HOOK="$GATES_LOCAL_HOOK" GATES_PROJECT_ROOT="$GATES_LOCAL_ROOT" \
        bash "$f" "$@" <<<"$GATES_LOCAL_STDIN" 2>&1 >/dev/null &
    pid=$!
    set +m
    (
        i=0
        while [[ "$i" -lt "$limit" ]]; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
            i=$((i + 1))
        done
        echo timeout >"$flag"
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -KILL -- "-$pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" || rc=$?
    if [[ -s "$flag" ]]; then
        # Timed out: let the watchdog finish its KILL of the whole group.
        wait "$wd" 2>/dev/null
        rc=124
    else
        kill "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
    fi
    rm -f "$flag"
    return "$rc"
}

gates_run_local() { # <root> <hook> [args...]
    local root="$1" hook="$2" f name out rc
    shift 2
    # Callers write `GATES_LOCAL_STDIN="$INPUT" gates_run_local ...`, and bash
    # exports a prefix assignment to a function for the call. Every program
    # started below would inherit the whole tool call, and Linux refuses to
    # exec one with an environment string over 128 KB (E2BIG), which read
    # as a refusal. It reaches the rule through a here-string instead.
    export -n GATES_LOCAL_STDIN 2>/dev/null || true
    GATES_LOCAL_MSG=""
    for f in "$root/.specify/gates/hooks.local.d/$hook"/*.sh; do
        [[ -e "$f" || -L "$f" ]] || continue
        name="${f##*/}"
        if [[ ! -f "$f" || ! -r "$f" ]]; then
            GATES_LOCAL_MSG="gates(local $hook/$name): the rule cannot be read, so it refuses"
            return 1
        fi
        rc=0
        out="$(GATES_LOCAL_HOOK="$hook" GATES_LOCAL_ROOT="$root" _gates_local_exec "$f" "$@")" || rc=$?
        if [[ "$rc" -eq 124 ]]; then
            GATES_LOCAL_MSG="gates(local $hook/$name): still running after ${GATES_LOCAL_TIMEOUT:-10}s, so it refuses"
            return 1
        fi
        if [[ "$rc" -ne 0 ]]; then
            GATES_LOCAL_MSG="gates(local $hook/$name): ${out:-refused (exit $rc)}"
            return 1
        fi
    done
    return 0
}
