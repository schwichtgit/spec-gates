#!/usr/bin/env bash
# managers.sh -- the git boundary as git actually runs it (#74).
#
# Usage (sourced; bash 3.2):
#   gates_hooks_dir <root>          # the directory git runs hooks from
#   gates_git_probe <root> <hook>   # run it: 0 = the hook reaches gates;
#                                   # else 1, with GATES_PROBE_MSG set
#   gates_hook_owner <root> <hook>  # gates | absent | other
#   gates_hook_static <root> <hook> # read it: is the call-through there?
#   gates_git_check <root> <hook> <probe:0|1>
#                                   # probe when gates owns the hook (or on
#                                   # request), static otherwise
#
# The probe runs the hook git would run (honoring core.hooksPath and linked
# worktrees) with GATES_PROBE=1 and a throwaway message file. The projected
# gates hooks answer with `gates-probe:<hook>:<version>` on stderr before
# reading any policy, so the marker proves the whole call chain -- a plain
# stub, husky, lefthook, the pre-commit framework, or a custom script --
# reaches gates, whichever rules the policy turns on or off. A hook that is
# missing, not executable (git skips it silently), or never prints the
# marker fails the probe.

# shellcheck disable=SC2034   # library file; GATES_PROBE_MSG is read by callers
GATES_PROBE_MSG=""

gates_hooks_dir() { # <root>
    local d
    d="$(git -C "$1" rev-parse --git-path hooks 2>/dev/null)" || return 1
    [[ "$d" == /* ]] || d="$1/$d"
    printf '%s\n' "$d"
}

gates_git_probe() { # <root> <hook>
    local root="$1" hook="$2" dir f msg out
    GATES_PROBE_MSG=""
    if ! dir="$(gates_hooks_dir "$root")"; then
        GATES_PROBE_MSG="not a git work tree"
        return 1
    fi
    f="$dir/$hook"
    if [[ ! -e "$f" ]]; then
        GATES_PROBE_MSG="${f#"$root"/} does not exist, so git runs no $hook hook"
        return 1
    fi
    if [[ ! -x "$f" ]]; then
        GATES_PROBE_MSG="${f#"$root"/} is not executable, so git skips it"
        return 1
    fi
    msg="$(mktemp 2>/dev/null || mktemp -t gates-probe)" || {
        GATES_PROBE_MSG="cannot create a probe message file"
        return 1
    }
    printf 'chore: gates probe\n' >"$msg"
    out="$(cd "$root" && GATES_PROBE=1 "$f" "$msg" 2>&1 </dev/null)" || true
    rm -f "$msg"
    if printf '%s\n' "$out" | grep -q "gates-probe:$hook:"; then
        return 0
    fi
    GATES_PROBE_MSG="git runs ${f#"$root"/}, but it does not reach the gates $hook hook (no probe answer)"
    return 1
}

# Who owns the hook git runs (#74): "gates" when it is the gates stub or a
# copied gates hook (the whole chain is gates code), "absent" when there is
# none, "other" for anything else (husky, lefthook, the pre-commit
# framework, a custom script).
gates_hook_owner() { # <root> <hook>
    local dir f
    dir="$(gates_hooks_dir "$1")" || { echo absent; return 0; }
    f="$dir/$2"
    if [[ ! -e "$f" ]]; then
        echo absent
    elif grep -q 'spec-gates hook stub\|Git commit-msg hook\.\|Git pre-commit hook --' "$f" 2>/dev/null; then
        echo gates
    else
        echo other
    fi
}

# Static check for a hook another tool owns: is the gates call-through in
# the file that tool reads? Running such a hook would also run that tool's
# own steps (husky's default pre-commit is `npm test`), with side effects
# and, under `sh -e`, a failing step that hides the gates line. So by
# default the chain is read, not run. Looks for the projected hook's path
# in the hook file itself and in the managers' user-owned configuration.
gates_hook_static() { # <root> <hook>
    local root="$1" hook="$2" dir f needle
    GATES_PROBE_MSG=""
    needle=".specify/gates/hooks/$hook"
    dir="$(gates_hooks_dir "$root")" || { GATES_PROBE_MSG="not a git work tree"; return 1; }
    for f in "$dir/$hook" "$root/.husky/$hook" "$root/lefthook.yml" "$root/.lefthook.yml" \
        "$root/lefthook-local.yml" "$root/.pre-commit-config.yaml"; do
        [[ -f "$f" ]] && grep -qF "$needle" "$f" && return 0
    done
    GATES_PROBE_MSG="git runs ${dir#"$root"/}/$hook, owned by another tool, and no file it reads calls $needle"
    return 1
}

# The check doctor and project.sh run per hook: the behavioral probe when
# gates owns the hook (only gates code runs) or when asked (<probe>=1);
# otherwise the static check. GATES_CHECK_KIND says which one ran.
GATES_CHECK_KIND=""
gates_git_check() { # <root> <hook> <probe:0|1>
    local owner
    owner="$(gates_hook_owner "$1" "$2")"
    if [[ "$owner" == "other" && "${3:-0}" != "1" ]]; then
        GATES_CHECK_KIND=static
        gates_hook_static "$1" "$2"
        return
    fi
    GATES_CHECK_KIND=probe
    gates_git_probe "$1" "$2"
}
