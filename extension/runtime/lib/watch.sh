#!/usr/bin/env bash
# watch.sh -- run a command under a time limit (feature 006, research R3).
#
# Sourced by verify.sh and lib/spec-gate.sh. Provides:
#   gates_group_stop <pgid>                       # TERM, 2 s grace, KILL
#   gates_run_watched <timeout-s> <outfile> <cmd...>
#
# Pure bash 3.2: stock macOS has no timeout(1). The command runs as a job
# of a `set -m` subshell, so it leads its own process group, and a timer
# subshell stops that group when the limit passes. A process that leaves
# the group (setsid, a double fork into a new session) is not stopped.
# Unlike accept blocks, watched commands are not read-only by contract, so
# the accept-block runner's lease and snapshot checks do not apply here.

# shellcheck disable=SC2034   # library file; GATES_WATCH_DETAIL is read by callers

# Stop process group <pgid>: TERM, a two-second grace, then KILL.
gates_group_stop() { # <pgid>
    local n=0
    kill -TERM -- -"$1" 2>/dev/null || return 0
    while [[ $n -lt 20 ]] && kill -0 -- -"$1" 2>/dev/null; do
        sleep 0.1
        n=$((n + 1))
    done
    kill -KILL -- -"$1" 2>/dev/null
    return 0
}

# Run <cmd...> with stdin /dev/null and stdout and stderr to <outfile>,
# from the current directory. Returns the command's status; on timeout
# its process group is stopped and the return is 124 with
# GATES_WATCH_DETAIL="timeout after <n>s[ at load <x>]". The timeout is
# told by the timer's marker, not by the status, so a command that exits
# 124 by itself leaves GATES_WATCH_DETAIL empty. Call it in the caller's
# own shell (not in $( )), or GATES_WATCH_DETAIL is lost.
gates_run_watched() { # <timeout-s> <outfile> <cmd...>
    local timeout="$1" outfile="$2" marker="$2.timedout" rc=0 load
    shift 2
    GATES_WATCH_DETAIL=""
    rm -f "$marker"
    (
        set -m
        "$@" >"$outfile" 2>&1 </dev/null &
        pid=$!
        trap 'kill -TERM -- -"$pid" 2>/dev/null' HUP INT TERM
        # The timer gets /dev/null stdio: it (and its sleep) must not hold
        # the caller's fds, or a caller capturing this run via $() would
        # wait on the pipe until the sleep expires. It is a job of its
        # own, so stopping it takes its sleep along.
        (
            sleep "$timeout"
            : >"$marker"
            gates_group_stop "$pid"
        ) >/dev/null 2>&1 </dev/null &
        watcher=$!
        crc=0
        wait "$pid" 2>/dev/null || crc=$?
        if [[ -f "$marker" ]]; then
            wait "$watcher" 2>/dev/null
        else
            kill -TERM -- -"$watcher" 2>/dev/null
            wait "$watcher" 2>/dev/null
        fi
        exit "$crc"
    ) 2>/dev/null || rc=$?
    if [[ -f "$marker" ]]; then
        rm -f "$marker"
        load=""
        if declare -F gates_spec_load_avg >/dev/null; then
            load="$(gates_spec_load_avg)" || load=""
        fi
        GATES_WATCH_DETAIL="timeout after ${timeout}s${load:+ at load $load}"
        return 124
    fi
    return "$rc"
}
