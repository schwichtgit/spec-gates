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
    # Call the hook the way git does (#127): commit-msg gets the message
    # file, pre-commit and pre-merge-commit get no arguments (the
    # pre-commit framework's hook
    # refuses any). lefthook skips every pre-commit job while nothing is
    # staged, and its generated hook passes its arguments on to
    # `lefthook run`, so its hook gets --force.
    msg=""
    if [[ "$hook" == "commit-msg" ]]; then
        msg="$(mktemp 2>/dev/null || mktemp -t gates-probe)" || {
            GATES_PROBE_MSG="cannot create a probe message file"
            return 1
        }
        printf 'chore: gates probe\n' >"$msg"
        out="$(cd "$root" && GATES_PROBE=1 "$f" "$msg" 2>&1 </dev/null)" || true
        rm -f "$msg"
    elif grep -qs 'lefthook' "$f"; then
        out="$(cd "$root" && GATES_PROBE=1 "$f" --force 2>&1 </dev/null)" || true
    else
        out="$(cd "$root" && GATES_PROBE=1 "$f" 2>&1 </dev/null)" || true
    fi
    if grep -q "gates-probe:$hook:" <<<"$out"; then
        return 0
    fi
    if grep -q 'no matching staged files' <<<"$out"; then
        GATES_PROBE_MSG="git runs ${f#"$root"/}, but lefthook skipped the gates job because nothing is staged (stage a file and probe again)"
        return 1
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

# Does <file> call the projected gates <hook> on a line that can run (#128)?
# Commented lines do not count, and nothing after an unconditional
# top-level `exit` does (a line appended to a hook ending in `exit 0`
# never runs). An indented `exit` sits inside a block and does not end the
# scan. The rules hold for YAML too: `#` starts a comment there, and a
# top-level YAML key is never a bare `exit`.
gates_calls_through() { # <file> <hook>
    [[ -f "$1" ]] || return 1
    awk -v needle=".specify/gates/hooks/$2" '
        /^[[:space:]]*#/ { next }
        /^exit([[:space:];]|$)/ { exit 1 }
        index($0, needle) { found = 1; exit 0 }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# Does <file> end the script with a top-level `exit`? A line appended after
# it would never run.
gates_has_toplevel_exit() { # <file>
    [[ -f "$1" ]] && grep -qE '^exit([[:space:];]|$)' "$1"
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
        "$root/lefthook.yaml" "$root/.lefthook.yaml" "$root/lefthook-local.yml" \
        "$root/.pre-commit-config.yaml"; do
        gates_calls_through "$f" "$hook" && return 0
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

# --- Hook managers (#74b) ---------------------------------------------------
#
# A hook manager owns the git hooks: it generates the files git runs and
# reads its own, user-owned configuration. gates never edits the generated
# files (the next `husky`, `lefthook install` or `pre-commit install`
# rewrites them, silently dropping a call-through); it adds its entry to the
# configuration the manager reads, and only on request (--wire-manager).
#
#   gates_detect_manager <root>          # husky | lefthook | pre-commit | unknown
#                                        # (another core.hooksPath) | plain
#   gates_manager_file <root> <manager> <hook>   # the user-owned file (relative)
#   gates_manager_wired <root> <manager> <hook>  # 0 if the entry is there
#   gates_manager_entry <manager> <hook>         # the entry, as text
#   gates_manager_apply <root> <manager> <hook>  # append it; 1 if unsafe
#   gates_manager_install_hint <manager> <hook>  # the manager's install command

gates_detect_manager() { # <root>
    local root="$1" hp dir f
    hp="$(git -C "$root" config core.hooksPath 2>/dev/null || true)"
    case "$hp" in
        *.husky*) echo husky; return 0 ;;
    esac
    dir="$(gates_hooks_dir "$root" 2>/dev/null)" || dir=""
    for f in lefthook.yml .lefthook.yml lefthook.yaml .lefthook.yaml; do
        [[ -f "$root/$f" ]] && { echo lefthook; return 0; }
    done
    if [[ -n "$dir" ]] && grep -qs 'lefthook' "$dir/pre-commit" "$dir/commit-msg"; then
        echo lefthook
        return 0
    fi
    if [[ -f "$root/.pre-commit-config.yaml" ]] \
        || { [[ -n "$dir" ]] && grep -qs 'File generated by pre-commit' "$dir/pre-commit" "$dir/commit-msg"; }; then
        echo pre-commit
        return 0
    fi
    # Another core.hooksPath owns every hook. A single custom script in the
    # hooks directory owns only that hook, so it is judged per hook by the
    # caller, and the repo stays "plain".
    if [[ -n "$hp" ]]; then
        echo unknown
        return 0
    fi
    echo plain
}

gates_manager_file() { # <root> <manager> <hook>
    local f
    case "$2" in
        husky) printf '.husky/%s\n' "$3" ;;
        lefthook)
            for f in lefthook.yml .lefthook.yml lefthook.yaml .lefthook.yaml; do
                [[ -f "$1/$f" ]] && { printf '%s\n' "$f"; return 0; }
            done
            printf 'lefthook.yml\n'
            ;;
        pre-commit) printf '.pre-commit-config.yaml\n' ;;
        *) return 1 ;;
    esac
}

gates_manager_wired() { # <root> <manager> <hook>
    local f
    f="$(gates_manager_file "$1" "$2" "$3")" || return 1
    gates_calls_through "$1/$f" "$3"
}

gates_manager_entry() { # <manager> <hook>
    local arg=""
    case "$1" in
        husky)
            # shellcheck disable=SC2016  # written literally into .husky/<hook>
            printf 'bash "$(git rev-parse --show-toplevel)/.specify/gates/hooks/%s" "$@"\n' "$2"
            ;;
        lefthook)
            [[ "$2" == "commit-msg" ]] && arg=" {1}"
            printf '%s:\n  commands:\n    spec-gates:\n      run: bash .specify/gates/hooks/%s%s\n' "$2" "$2" "$arg"
            ;;
        pre-commit)
            printf -- '- repo: local\n  hooks:\n    - id: spec-gates-%s\n      name: spec-gates %s\n      entry: bash .specify/gates/hooks/%s\n      language: system\n' "$2" "$2" "$2"
            # pre-commit and pre-merge-commit (#148) take no file names and
            # run on every commit; commit-msg gets the message file.
            if [[ "$2" != "commit-msg" ]]; then
                printf '      pass_filenames: false\n      always_run: true\n      stages: [%s]\n' "$2"
            else
                printf '      stages: [commit-msg]\n'
            fi
            ;;
        *) return 1 ;;
    esac
}

# Append only where the result is certainly still valid: a husky script
# without a top-level `exit` (a line after it never runs); a lefthook block
# only when its top-level key, quoted or not, is absent; a pre-commit item
# only when `repos:` is the last top-level key and a block list (so the item
# lands in that list), at the indentation the file already uses. Tabs or
# any other layout: leave the file alone. gates_manager_appendable says
# whether the append is safe and, when not, sets GATES_MANAGER_WHY to the
# instruction for adding the entry by hand.
GATES_MANAGER_WHY=""
gates_manager_appendable() { # <root> <manager> <hook>
    local root="$1" mgr="$2" hook="$3" rel f last
    GATES_MANAGER_WHY=""
    rel="$(gates_manager_file "$root" "$mgr" "$hook")" || return 1
    f="$root/$rel"
    if [[ -f "$f" ]] && grep -q $'\t' "$f"; then
        GATES_MANAGER_WHY="$rel contains tabs, so gates does not edit it; add this by hand:"
        return 1
    fi
    case "$mgr" in
        husky)
            if gates_has_toplevel_exit "$f"; then
                GATES_MANAGER_WHY="$rel has a top-level exit, so an appended line would never run; add this line by hand, before any exit:"
                return 1
            fi
            ;;
        lefthook)
            if [[ -f "$f" ]] && grep -qE "^[\"']?${hook}[\"']?[[:space:]]*:" "$f"; then
                GATES_MANAGER_WHY="$rel already has a $hook: block; merge this spec-gates command into your existing $hook: block by hand:"
                return 1
            fi
            ;;
        pre-commit)
            if [[ ! -f "$f" ]]; then
                GATES_MANAGER_WHY="$rel does not exist; create it with a repos: list holding this item:"
                return 1
            fi
            last="$(grep -E "^[\"']?[A-Za-z_][A-Za-z0-9_-]*[\"']?[[:space:]]*:" "$f" | tail -n 1 | cut -d: -f1 | tr -d "\"' ")"
            if [[ "$last" != "repos" ]] || ! grep -qE "^[\"']?repos[\"']?[[:space:]]*:[[:space:]]*(#.*)?$" "$f"; then
                GATES_MANAGER_WHY="$rel cannot be appended to safely (repos: is not the last top-level key, or is not a block list, as in repos: []); add this item to repos: by hand:"
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

gates_manager_apply() { # <root> <manager> <hook>
    local root="$1" mgr="$2" hook="$3" rel f nl="" ind="  " first
    gates_manager_appendable "$root" "$mgr" "$hook" || return 1
    rel="$(gates_manager_file "$root" "$mgr" "$hook")" || return 1
    f="$root/$rel"
    [[ -s "$f" && -n "$(tail -c 1 "$f")" ]] && nl=$'\n'
    case "$mgr" in
        husky)
            mkdir -p "$root/.husky" || return 1
            printf '%s%s' "$nl" "$(gates_manager_entry husky "$hook")"$'\n' >>"$f" || return 1
            ;;
        lefthook)
            printf '%s%s' "$nl" "$(gates_manager_entry lefthook "$hook")"$'\n' >>"$f" || return 1
            ;;
        pre-commit)
            first="$(sed -nE '/^ *- +repo:/{p;q;}' "$f")"
            [[ -n "$first" ]] && ind="$(sed -E 's/^( *).*/\1/' <<<"$first")"
            printf '%s%s' "$nl" "$(gates_manager_entry pre-commit "$hook" | sed "s/^/$ind/")"$'\n' >>"$f" || return 1
            ;;
        *) return 1 ;;
    esac
}

gates_manager_install_hint() { # <manager> <hook>
    case "$1" in
        lefthook) echo "lefthook install" ;;
        pre-commit) echo "pre-commit install --hook-type $2" ;;
        husky) echo "npx husky" ;;
    esac
}
