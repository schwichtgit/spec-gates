#!/bin/bash
set -euo pipefail

# PreToolUse hook for Bash commands.
# Reads JSON from stdin, parses the command field, blocks destructive patterns.
# Exit 2 = block. Exit 0 = allow, or (with the JSON below on stdout) ask.
#
# Never a silent allow (issue #83): without jq, or when the input is not
# valid JSON, the command is read in raw mode (see raw_field) and every
# block rule still applies. A state the hook cannot judge -- an internal
# error, a command it cannot decode -- returns a PreToolUse "ask" decision,
# so a human confirms the call instead of the hook guessing either way.

# ask <reason>: hand the decision to the human (PreToolUse "ask"). Static
# printf, no jq: this must work in exactly the states where jq is missing.
ask() {
    local r="${1//\\/\\\\}"
    r="${r//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "gates: $r"
    exit 0
}

trap 'ask "validate-bash.sh failed unexpectedly (line $LINENO); run /speckit.gates.doctor"' ERR

# raw_field <name>: print the decoded value of the JSON string field <name>
# from $INPUT without jq. A JSON string is a regular language, so the sed
# match is exact for it; escapes are decoded below. Returns 1 when the
# field is absent and 2 when the value uses an escape this decoder does not
# handle (\uXXXX could spell a blocked word) or the key appears more than
# once (which one the hook reads would be a guess, #121), which the caller
# turns into "ask".
raw_field() {
    local v n
    n="$({ grep -oE '"'"$1"'"[[:space:]]*:' <<<"$INPUT" || true; } | awk 'END { print NR }')"
    [[ "${n:-0}" -gt 1 ]] && return 2
    # The leading "=" tells an empty value ("") apart from no match.
    v="$(printf '%s' "$INPUT" | tr '\n' ' ' \
        | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/=\1/p')"
    if [[ -z "$v" ]]; then
        # The key is there but its value is not a plain string: undecidable.
        grep -qE '"'"$1"'"[[:space:]]*:' <<<"$INPUT" && return 2
        return 1
    fi
    v="${v#=}"
    [[ "$v" == *'\u'* ]] && return 2
    # bash 3.2's ${v//...} is quadratic in the number of matches: a long
    # value would hang the decode below, so it is undecidable here (#117).
    [[ "${#v}" -gt 16384 ]] && return 2
    v="${v//\\\\/$'\001'}"
    v="${v//\\\"/\"}"
    v="${v//\\\//\/}"
    v="${v//\\n/$'\n'}"
    v="${v//\\t/$'\t'}"
    v="${v//\\r/}"
    v="${v//$'\001'/\\}"
    printf '%s' "$v"
}

# Every rule below is an `if ... | grep` test: without grep each one is
# silently false, which would turn the hook into an allow-all.
for _tool in grep sed tr awk; do
    command -v "$_tool" >/dev/null 2>&1 \
        || ask "$_tool not found, so validate-bash cannot check this command; run /speckit.gates.doctor"
done

INPUT=$(cat /dev/stdin)
DEGRADED=""
if command -v jq >/dev/null 2>&1 && printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
else
    if command -v jq >/dev/null 2>&1; then
        DEGRADED="the hook input is not valid JSON"
    else
        DEGRADED="jq not found"
    fi
    rc=0
    COMMAND="$(raw_field command)" || rc=$?
    [[ "$rc" -eq 2 ]] && ask "cannot decode the command without jq ($DEGRADED); confirm it is safe"
    # No command field at all: nothing here says the call is harmless.
    [[ "$rc" -eq 1 ]] && ask "no command found in the hook input without jq ($DEGRADED); confirm the call"
fi

if [[ -z "$COMMAND" ]]; then
    exit 0
fi
LROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

BLOCKED=""

# Destructive filesystem operations (#68). `rm` must be a whole word (a path
# prefix such as /bin/rm is fine), so "brainstorm /" does not match. Two
# rules over each rm command segment:
#   1. root, root wildcard, or home as a complete argument -- always blocked;
#   2. any other absolute path -- blocked unless under a temp root (/tmp,
#      /private/tmp, /var/folders, /private/var/folders, $TMPDIR), so
#      `rm -rf /tmp/build` is fine while `rm -rf /var/data` is not.
# POSIX classes only: \b and \s differ between GNU grep (Linux/CI) and BSD
# grep (macOS).
# shellcheck disable=SC2016
RM_TARGET='(/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\$\{HOME\}|\$\{HOME\}/|"\$HOME"|"\$HOME/")'
if grep -qE '(^|[^[:alnum:]_.-])rm[[:space:]]+([^;&|]*[[:space:]])?'"$RM_TARGET"'([[:space:]]|[;&|)]|$)' <<<"$COMMAND"; then
    BLOCKED="Destructive rm command targeting root, home, or wildcard"
fi
if [[ -z "$BLOCKED" ]]; then
    while IFS= read -r _seg; do
        # shellcheck disable=SC2086  # deliberate word split of the arguments
        for _arg in ${_seg#*rm}; do
            _arg="${_arg#[\"\']}"
            _arg="${_arg%[\"\']}"
            # The quoted $TMPDIR patterns are literal on purpose: they match
            # the unexpanded command text.
            # shellcheck disable=SC2016
            case "$_arg" in
                /tmp/?* | /private/tmp/?* | /var/folders/?* | /private/var/folders/?*) ;;
                '$TMPDIR'/?* | '${TMPDIR}'/?*) ;;
                /*) BLOCKED="Destructive rm command on an absolute path outside the temp directories ($_arg)" ;;
            esac
        done
    done < <(echo "$COMMAND" | grep -oE '(^|[^[:alnum:]_.-])rm[[:space:]]+[^;&|]*' || true)
fi

# Force push
if grep -qE 'git\s+push\s+(.*\s)?(-f|--force)(\s|$)' <<<"$COMMAND"; then
    BLOCKED="git push --force"
fi

# Hard reset
if grep -qE 'git\s+reset\s+--hard' <<<"$COMMAND"; then
    BLOCKED="git reset --hard"
fi
if grep -qE 'git\s+clean\s+-[a-zA-Z]*f' <<<"$COMMAND"; then
    BLOCKED="git clean -f"
fi
if grep -qE 'git\s+checkout\s+\.$' <<<"$COMMAND"; then
    BLOCKED="git checkout . (discards all changes)"
fi
if grep -qE 'git\s+restore\s+\.$' <<<"$COMMAND"; then
    BLOCKED="git restore . (discards all changes)"
fi

# Dangerous permissions
if grep -qE 'chmod\s+(-R\s+)?777' <<<"$COMMAND"; then
    BLOCKED="chmod 777"
fi

# Disk destruction
if grep -qE '>\s*/dev/sd' <<<"$COMMAND"; then
    BLOCKED="Write to raw disk device"
fi
if grep -qE 'mkfs\.' <<<"$COMMAND"; then
    BLOCKED="Format filesystem"
fi
if grep -qE 'dd\s+if=/dev/(zero|random)' <<<"$COMMAND"; then
    BLOCKED="dd from zero/random device"
fi

# Fork bomb
if grep -qF ':(){ :|:& };:' <<<"$COMMAND"; then
    BLOCKED="Fork bomb"
fi

# Environment destruction
if grep -qE '(unset\s+PATH|PATH=\s*$)' <<<"$COMMAND"; then
    BLOCKED="PATH destruction"
fi

# Pipe to shell
if grep -qE '(curl|wget)\s.*\|\s*(sh|bash)' <<<"$COMMAND"; then
    BLOCKED="Pipe remote content to shell"
fi

# A shipped "ask" waits until the project's rules have run: a local refusal
# is stronger than a question (#130). defer_ask keeps the first reason.
ASK=""
defer_ask() { [[ -n "$ASK" ]] || ASK="$1"; }

if [[ -z "$DEGRADED" ]]; then
    CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
else
    CWD="$(raw_field cwd || true)"
fi
[[ -n "$CWD" ]] || CWD="$LROOT"

# Bulk staging (#71): with policy git.block_bulk_staging on, refuse a
# `git add` that stages everything or a whole directory, so an untracked
# directory cannot be swept into a commit. Explicit files, -u and -p stay
# allowed. Agent boundary only: pre-commit sees the index, not how it was
# filled. bulk_staging_on: 0 on, 1 off, 2 the policy cannot be read.
bulk_staging_on() {
    local pf="$LROOT/.specify/gates/policy.json" v
    [[ -f "$pf" ]] || return 1
    if [[ -z "$DEGRADED" ]]; then
        v="$(jq -r '.git.block_bulk_staging // false' "$pf" 2>/dev/null)" || return 2
        [[ "$v" == "true" ]] && return 0
        return 1
    fi
    grep -qE '"block_bulk_staging"[[:space:]]*:[[:space:]]*true' <<<"$(tr '\n' ' ' <"$pf")" && return 0
    return 1
}

# git_scan: read every simple command of $COMMAND that runs git -- behind
# environment assignments, env, command, sudo, exec, nohup, time or nice,
# and after git's global options (-C, -c, --no-pager, ...) -- and print one
# finding per line:
#   BULK <arg>   `git add`/`git stage` staging in bulk: -A, --all, `.`, a
#                directory (quoted or not), "$PWD", a glob or a pathspec
#                with magic (`:/`, `:(top)`), which git expands itself
#   BULKQ <arg>  an argument this check cannot resolve (an unbalanced quote,
#                an escaped space, a variable or a command substitution)
#   HOOKS <what> a git hook bypass: --no-verify, `commit -n`, or a
#                core.hooksPath setting
#   DESTRUCT <what>  a whole-tree discard (#170): `checkout`/`restore` of
#                `.`, `:/` or other pathspec magic, in any spelling and
#                position (`restore --staged` alone only unstages), and
#                `clean` with -f or --force anywhere
# Arguments come from xargs (`xargs git add < list`) are unknown (BULKQ).
# A `cd <dir>` segment moves the directory later relative paths resolve
# against; a `cd` this cannot resolve makes them unknown too.
git_scan() {
    local seg t t2 q a base cdir sub n i dashdash xa whole staged wtree
    local scwd="$CWD"
    local asg='^[A-Za-z_][A-Za-z0-9_]*='
    local -a w
    while IFS= read -r seg; do
        w=()
        read -r -a w <<<"$seg" || true
        n="${#w[@]}"
        [[ "$n" -gt 0 ]] || continue
        if [[ "${w[0]}" == cd || "${w[0]}" == pushd ]]; then
            t="${w[1]:-}"
            t="${t#[\"\']}"
            t="${t%[\"\']}"
            # shellcheck disable=SC2016  # literal command text
            case "$t" in
                '' | '~'* | *'$'* | *'`'* | -*) scwd="" ;;
                /*) scwd="$t" ;;
                *) [[ -n "$scwd" ]] && scwd="$scwd/$t" ;;
            esac
            continue
        fi
        i=0
        xa=0
        while [[ "$i" -lt "$n" ]]; do
            t="${w[i]}"
            if [[ ! "$t" =~ $asg ]]; then
                case "$t" in
                    sudo | env | command | exec | nohup | time | nice) ;;
                    xargs)
                        # xargs runs the command with arguments read
                        # elsewhere: skip its options up to the command.
                        xa=1
                        while [[ "$((i + 1))" -lt "$n" && "${w[i + 1]}" != git && "${w[i + 1]}" != */git ]]; do
                            i=$((i + 1))
                        done
                        ;;
                    -*) [[ "$i" -gt 0 ]] || break ;;
                    *) break ;;
                esac
            fi
            i=$((i + 1))
        done
        [[ "$i" -lt "$n" ]] || continue
        t="${w[i]}"
        [[ "$t" == git || "$t" == */git ]] || continue
        if grep -qiF 'core.hookspath' <<<"$seg"; then
            printf 'HOOKS %s\n' "core.hooksPath"
        fi
        cdir=""
        i=$((i + 1))
        while [[ "$i" -lt "$n" ]]; do
            t="${w[i]}"
            case "$t" in
                -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env)
                    [[ "$t" == -C ]] && cdir="${w[i + 1]:-}"
                    i=$((i + 2))
                    continue
                    ;;
                -*) ;;
                *) break ;;
            esac
            i=$((i + 1))
        done
        sub="${w[i]:-}"
        i=$((i + 1))
        base="$scwd"
        if [[ -n "$cdir" ]]; then
            cdir="${cdir#[\"\']}"
            cdir="${cdir%[\"\']}"
            if [[ "$cdir" == /* ]]; then base="$cdir"; elif [[ -n "$scwd" ]]; then base="$scwd/$cdir"; fi
        fi
        if [[ "$xa" -eq 1 && ( "$sub" == add || "$sub" == stage ) ]]; then
            printf 'BULKQ %s\n' "(arguments from xargs)"
        fi
        dashdash=0
        whole=""
        staged=0
        wtree=0
        while [[ "$i" -lt "$n" ]]; do
            a="${w[i]}"
            i=$((i + 1))
            if [[ "$dashdash" -eq 0 ]]; then
                case "$a" in
                    --) dashdash=1; continue ;;
                    --no-veri*) printf 'HOOKS %s\n' "$a"; continue ;;
                esac
                # `-n` is --no-verify for commit, also inside a cluster
                # (`-nm`), up to the first option that takes a value.
                if [[ "$sub" == commit && "$a" == -* && "$a" != --* ]] \
                    && [[ "${a%%[mFcCtSu]*}" == *n* ]]; then
                    printf 'HOOKS git commit %s\n' "$a"
                    continue
                fi
            fi
            t="${a//\"/}"
            t="${t//\'/}"
            case "$sub" in
                clean)
                    if [[ "$dashdash" -eq 0 ]]; then
                        case "$t" in
                            --force) printf 'DESTRUCT git clean %s\n' "$t" ;;
                            --*) ;;
                            -*f*) printf 'DESTRUCT git clean %s\n' "$t" ;;
                        esac
                    fi
                    continue
                    ;;
                checkout | restore)
                    if [[ "$dashdash" -eq 0 ]]; then
                        case "$t" in
                            --staged) staged=1; continue ;;
                            --worktree) wtree=1; continue ;;
                            --*) continue ;;
                            -*)
                                [[ "$t" == *S* ]] && staged=1
                                [[ "$t" == *W* ]] && wtree=1
                                continue
                                ;;
                        esac
                    fi
                    # The whole tree: `.`, `./`, `*`, `:/`, `:(top)` or
                    # other magic (the segment split may cut it at the
                    # parenthesis).
                    case "$t" in
                        . | ./ | '*' | ./'*' | :*) whole="$a" ;;
                    esac
                    continue
                    ;;
            esac
            [[ "$sub" == add || "$sub" == stage ]] || continue
            if [[ "$dashdash" -eq 0 ]]; then
                case "$a" in
                    -A | --all | --no-ignore-removal | --pathspec-from-file*)
                        printf 'BULK %s\n' "$a"
                        continue
                        ;;
                    --*) continue ;;
                    -*A*)
                        printf 'BULK %s\n' "$a"
                        continue
                        ;;
                    -*) continue ;;
                esac
            fi
            # Rejoin an argument the word split cut: a quoted name with a
            # space ("src dir") or an escaped one (src\ dir).
            while [[ "$i" -lt "$n" ]]; do
                t="${a//[!\"]/}"
                q="${a//[!\']/}"
                if [[ "$a" == *\\ ]]; then
                    a="${a%\\} ${w[i]}"
                elif [[ $((${#t} % 2)) -ne 0 || $((${#q} % 2)) -ne 0 ]]; then
                    a="$a ${w[i]}"
                else
                    break
                fi
                i=$((i + 1))
            done
            t="${a//\"/}"
            t="${t//\'/}"
            # Pathspec magic (`:/`, `:(top)`, `:!x`): git expands it, and
            # the segment split may have cut it at the parenthesis.
            if [[ "$t" == :* ]]; then
                printf 'BULK %s\n' "$a"
                continue
            fi
            q="${a//[!\"]/}"
            t2="${a//[!\']/}"
            if [[ "$t" == *\\ || $((${#q} % 2)) -ne 0 || $((${#t2} % 2)) -ne 0 ]]; then
                printf 'BULKQ %s\n' "$a"
                continue
            fi
            # The quoted patterns are literal command text, not expansions.
            # shellcheck disable=SC2016,SC2088
            case "$t" in
                '$PWD' | '$PWD/'* | '${PWD}' | '${PWD}/'* | '~' | '~/'*)
                    printf 'BULK %s\n' "$a"
                    ;;
                *'$'* | *'`'* | *\\*) printf 'BULKQ %s\n' "$a" ;;
                . | ./ | :* | */ | *[*?[]*) printf 'BULK %s\n' "$a" ;;
                *)
                    if [[ -z "$base" && "$t" != /* ]]; then
                        printf 'BULKQ %s\n' "$a"
                    elif [[ "$t" == /* && -d "$t" ]] || [[ "$t" != /* && -d "$base/$t" ]]; then
                        printf 'BULK %s\n' "$a"
                    fi
                    ;;
            esac
        done
        if [[ -n "$whole" ]] && { [[ "$sub" == checkout ]] || [[ "$staged" -eq 0 || "$wtree" -eq 1 ]]; }; then
            printf 'DESTRUCT git %s %s\n' "$sub" "$whole"
        fi
    done < <(printf '%s\n' "$COMMAND" | awk '
        # A `...` substitution is an argument this cannot resolve: it
        # stands in as $SUBST, and its own text is scanned as a command.
        { s = $0; inner = ""
          while (match(s, /`[^`]*`/)) {
              inner = inner "\n" substr(s, RSTART + 1, RLENGTH - 2)
              s = substr(s, 1, RSTART - 1) "$SUBST" substr(s, RSTART + RLENGTH)
          }
          s = s inner
          gsub(/&&|\|\||;|\||&|\(|\)|`/, "\n", s); print s }')
    return 0
}
GIT_SCAN="$(git_scan)"
DESTRUCT="$(awk '/^DESTRUCT / { sub(/^DESTRUCT /, ""); print; exit }' <<<"$GIT_SCAN")"
if [[ -n "$DESTRUCT" ]]; then
    BLOCKED="$DESTRUCT (discards uncommitted work)"
fi
if [[ -z "$BLOCKED" ]] && grep -q '^BULK' <<<"$GIT_SCAN"; then
    rc=0
    bulk_staging_on || rc=$?
    BULK="$(awk '/^BULK / { sub(/^BULK /, ""); print; exit }' <<<"$GIT_SCAN")"
    BULKQ="$(awk '/^BULKQ / { sub(/^BULKQ /, ""); print; exit }' <<<"$GIT_SCAN")"
    if [[ "$rc" -eq 0 && -n "$BULK" ]]; then
        BLOCKED="Bulk staging (git add $BULK) refused by policy git.block_bulk_staging; stage explicit paths"
    elif [[ "$rc" -eq 0 ]]; then
        defer_ask "git add $BULKQ may stage in bulk, which policy git.block_bulk_staging refuses, and this check cannot resolve the argument; confirm it names files"
    elif [[ "$rc" -eq 2 ]]; then
        defer_ask "git add ${BULK:-$BULKQ} stages in bulk, and .specify/gates/policy.json cannot be read to check git.block_bulk_staging; run /speckit.gates.doctor"
    fi
fi
HOOKS="$(awk '/^HOOKS / { sub(/^HOOKS /, ""); print; exit }' <<<"$GIT_SCAN")"
if [[ -n "$HOOKS" ]]; then
    defer_ask "this command bypasses the git hooks ($HOOKS), so the commit checks would not run; confirm it"
fi
# The spec gate's recursion guard: any verify.sh run that inherits it, a
# commit's hook included, skips the accept blocks (#164). Unsetting it
# (env -u) is fine; setting or exporting it asks.
if grep -qE '(^|[^A-Za-z0-9_])GATES_SPEC_EXEC\+?=|export[[:space:]]+([^;&|]*[[:space:]])?GATES_SPEC_EXEC([[:space:];&|]|$)' <<<"$COMMAND"; then
    defer_ask "this command sets GATES_SPEC_EXEC, so any verify.sh it runs skips the spec gate (accept blocks); confirm it"
fi
# Other variables that weaken enforcement (#196): another policy file, the
# git boundary's emergency skip and main-branch override, another pr-check
# runtime, the test-only projection without canaries. Unsetting is fine.
GATES_WEAK_VARS='GATES_POLICY_FILE|GATES_SKIP|GATES_ALLOW_MAIN_COMMIT|GATES_RUNTIME_DIR|GATES_TEST'
WEAK_SET="$(grep -oE "(^|[^A-Za-z0-9_])($GATES_WEAK_VARS)\+?=|export[[:space:]]+([^;&|]*[[:space:]])?($GATES_WEAK_VARS)([[:space:];&|]|$)" <<<"$COMMAND" || true)"
if [[ -n "$WEAK_SET" ]]; then
    WEAK_SET="$(grep -oE "$GATES_WEAK_VARS" <<<"$WEAK_SET" || true)"
    defer_ask "this command sets ${WEAK_SET%%$'\n'*}, which weakens what the gates enforce; confirm it"
fi

if [[ -n "$BLOCKED" ]]; then
    echo "BLOCKED: $BLOCKED" >&2
    echo "Command: $COMMAND" >&2
    exit 2
fi

# Protected paths through Bash (#95): Write/Edit to a protected path is
# refused by protect-files, but `rm`, `mv`, `sed -i`, a redirect,
# `find -delete` or `git rm` reach it through here. Telling a modification
# from a read by the command text alone is a heuristic, so a command that
# appears to modify one asks the human instead of blocking; reads stay
# allowed. The paths: the project's rules (hooks.local.d), the
# policy-contract artifacts (#137), policy.json and the constitution
# (always, whatever extra says, #165), plus protected_files.extra (glob
# entries by their literal prefix). Without jq, extra is read when it is a
# plain list of strings; when it cannot be read (no jq, or a policy that is
# malformed or fails validation) a command that changes anything asks
# (#121, #165). A path counts as named when it appears in the command, when one
# of its parent directories appears as a whole argument (`rm -rf
# .specify/gates`), when the command first changes into it or a parent
# (`cd .specify/gates && ...`, `git -C`), or relative to the input cwd
# (#191). Matching ignores case, after
# `./`, `//`, `/./`, "$PWD/" and the project root are normalized away
# (#130).
POLICY="$LROOT/.specify/gates/policy.json"
# raw_extra: protected_files.extra without jq, one entry per line. Returns
# 2 when the policy declares an extra this cannot read (escapes, values
# that are not strings, a layout other than a flat array).
raw_extra() {
    local flat body
    flat="$(tr '\n' ' ' <"$POLICY")"
    grep -qE '"extra"[[:space:]]*:' <<<"$flat" || return 0
    body="$(sed -nE 's/.*"protected_files"[[:space:]]*:[[:space:]]*\{[^{}]*"extra"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/=\1/p' <<<"$flat")"
    [[ -n "$body" ]] || return 2
    body="${body#=}"
    grep -qE '^[[:space:]]*("[^"\\]*"[[:space:]]*(,[[:space:]]*"[^"\\]*"[[:space:]]*)*)?$' <<<"$body" || return 2
    { grep -oE '"[^"\\]*"' <<<"$body" || true; } | sed -e 's/^"//' -e 's/"$//'
}
RAW_EXTRA=""
EXTRA_UNREAD=0
EXTRA_WHY="$DEGRADED"
if [[ -n "$DEGRADED" && -f "$POLICY" ]]; then
    rc=0
    RAW_EXTRA="$(raw_extra)" || rc=$?
    [[ "$rc" -eq 2 ]] && EXTRA_UNREAD=1
elif [[ -f "$POLICY" ]]; then
    # The jq reader below returns nothing for a malformed policy or an extra
    # that is not a list of strings, which would read as "nothing protected".
    # Same validation verify.sh and protect-files refuse on (#124, #165).
    _plib="$LROOT/.specify/gates/lib/policy.sh"
    if ! jq -e '(.protected_files.extra // []) | type == "array" and all(type == "string")' \
        "$POLICY" >/dev/null 2>&1; then
        EXTRA_UNREAD=1
    elif [[ -f "$_plib" ]] && bash -n "$_plib" 2>/dev/null \
        && ! (
            # shellcheck source=/dev/null disable=SC1090
            source "$_plib" && _pf="$(gates_policy_file)" \
                && { [[ ! -f "$_pf" ]] || gates_validate_policy "$_pf"; }
        ) >/dev/null 2>&1; then
        EXTRA_UNREAD=1
    fi
    EXTRA_WHY="the policy is malformed or invalid; run /speckit.gates.doctor"
fi
protected_prefixes() {
    printf '%s\n' ".specify/gates/hooks.local.d" ".specify/gates/baseline.json" \
        ".specify/gates/baseline.lock.json" ".specify/gates/policy.effective.json" \
        ".specify/gates/policy.json" ".specify/memory/constitution.md"
    {
        if [[ -n "$DEGRADED" ]]; then
            [[ -n "$RAW_EXTRA" ]] && printf '%s\n' "$RAW_EXTRA"
        elif [[ -f "$POLICY" ]]; then
            jq -r '(.protected_files.extra // [])[] | select(type == "string")' "$POLICY" 2>/dev/null || true
        fi
    } | sed -e 's/[*?[].*$//' -e 's:/*$::' | awk 'length($0) > 0' || true
}
# A verb counts after a separator, a path (/bin/rm) or the opening quote of
# a shell string (sh -c 'rm ...', eval "rm ..."), not of any quoted text
# (grep "rm "); a backslash (\rm) is normalized away below (#170). An
# interpreter one-liner (python3 -c, node -e, ...) may write any file, so
# it counts as a change when it names a protected path.
# shellcheck disable=SC2016  # the backtick is a literal command separator
VERB_START='(^|[;&|(`[:space:]/]|(-c|eval)[[:space:]]+["'"'"'])'
MUTATE_VERB="$VERB_START"'(rm|rmdir|unlink|shred|mv|cp|ln|install|truncate|tee|chmod|chown|dd|rsync)([[:space:]]|$)'
MUTATE_EDIT="$VERB_START"'(sed|perl)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*i|'"$VERB_START"'git[[:space:]]+(rm|mv|checkout|restore|reset|clean|stash)([[:space:]]|$)'
MUTATE_FIND="$VERB_START"'find[[:space:]]([^;&|]*[[:space:]])?-(delete|exec|execdir|ok|okdir)([[:space:]]|$)'
MUTATE_INTERP="$VERB_START"'(python[0-9.]*|perl|ruby|node|deno|bun)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*[ce]([[:space:]]|$)'
# The command with path spellings normalized, lowercased. The project root
# is stripped as given and as its real path (/tmp vs /private/tmp, a
# symlinked checkout; #165).
LREAL="$(cd "$LROOT" 2>/dev/null && pwd -P)" || LREAL=""
# shellcheck disable=SC2016  # $PWD is literal command text here
normalize() { printf '%s\n' "$1" | awk -v root="$LROOT" -v rroot="${LREAL:-$LROOT}" '
    function strip(s, p,    i, out) {
        out = ""
        while ((i = index(s, p)) > 0) { out = out substr(s, 1, i - 1); s = substr(s, i + length(p)) }
        return out s
    }
    { s = strip($0, root "/"); s = strip(s, rroot "/"); s = strip(s, "\"$PWD\"/"); s = strip(s, "\"${PWD}\"/")
      s = strip(s, "$PWD/"); s = strip(s, "${PWD}/"); print s }' \
    | sed -E -e 's#\\([^[:space:]\\])#\1#g' \
        -e 's#//+#/#g' -e 's#/(\./)+#/#g' -e "s#(^|[[:space:]\"'=<>;&|(\`])(\./)+#\1#g" \
    | awk '
        # Brace expansion, as the shell does it: policy.{json,x} names
        # policy.json (#170). One group per pass, a bounded number of passes.
        { for (k = 0; k < 20 && match($0, /[^[:space:]{}"'"'"'`]*\{[^{}[:space:]]*,[^{}[:space:]]*\}[^[:space:]{}"'"'"'`]*/); k++) {
              w = substr($0, RSTART, RLENGTH); o = index(w, "{"); c = index(w, "}")
              pre = substr(w, 1, o - 1); post = substr(w, c + 1)
              m = split(substr(w, o + 1, c - o - 1), alt, ","); out = ""
              for (j = 1; j <= m; j++) out = out (j > 1 ? " " : "") pre alt[j] post
              $0 = substr($0, 1, RSTART - 1) out substr($0, RSTART + RLENGTH)
          }
          print }' \
    | tr '[:upper:]' '[:lower:]'; }
NCMD="$(normalize "$COMMAND")"
# Text that changes no file (#195): the literal message of a `git commit
# -m` (also a quoted "$(cat <<'EOF' ...)" heredoc) is blanked in BCMD, and
# PCMD also drops the segments of read-only commands (grep, cat, ls, ...),
# so `grep -n rm <protected path>` and a commit message that names one do
# not ask. A path named in either still counts (NCMD) when another segment
# changes files; a redirect is read from BCMD, so `grep x > <protected
# path>` still asks. A command whose quoting the tokenizer cannot follow
# exactly, or that also runs a shell, eval or xargs, is left as it is.
inert_awk() {
    cat <<'AWK'
    # mode=b: the command with literal commit messages blanked; mode=p:
    # also without its read-only segments. Anything whose quoting this
    # cannot follow exactly (an unbalanced quote, $'...', ${...}, a
    # command substitution other than the quoted heredoc, a heredoc, a
    # comment) and a command that feeds a shell, eval or xargs print the
    # command unchanged.
    function base(w) { sub(/.*\//, "", w); return w }
    function endword(   o) {
        if (!inw) return
        o = rw
        if (redir) redir = 0
        else if (cmd == "") {
            if (wt !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { cmd = base(wt); if (cmd == ".") guard = 1 }
        } else if (cmd == "git" && sub_ == "") {
            if (pend) pend = 0
            else if (wt ~ /^(-C|-c|--git-dir|--work-tree|--namespace)$/) pend = 1
            else if (wt !~ /^-/) sub_ = wt
        } else if (sub_ == "commit" && wlit) {
            if (prev ~ /^-[a-zA-Z]*m$/ || prev == "--message") o = "''"
            else if (wt ~ /^--message=/) o = "--message=''"
        }
        if (base(wt) ~ /^(sh|bash|zsh|dash|ksh|fish|eval|xargs|source|parallel)$/) guard = 1
        seg = seg o; prev = wt
        inw = 0; rw = ""; wt = ""; wlit = 1
    }
    function endseg() {
        endword()
        bout = bout seg
        if (cmd !~ /^(grep|egrep|fgrep|cat|head|tail|wc|ls|stat|diff|cmp|echo|printf|type|which|cd|pushd|popd|true)$/)
            pout = pout seg
        seg = ""; cmd = ""; sub_ = ""; pend = 0; prev = ""; redir = 0
    }
    function emit(c) { seg = seg c }
    # A "$(cat <<'X' ... X)" heredoc at position p of s: its end, or 0.
    # An unquoted delimiter counts only when the body expands nothing.
    function heredoc(p,    r, d, q, e, body, k) {
        r = substr(s, p)
        if (!match(r, /^\$\([ \t]*cat[ \t]*<<-?[ \t]*/)) return 0
        r = substr(r, RLENGTH + 1); e = RLENGTH
        q = 0
        if (match(r, /^'[A-Za-z0-9_]+'/) || match(r, /^"[A-Za-z0-9_]+"/)) { d = substr(r, 2, RLENGTH - 2); q = 1 }
        else if (match(r, /^\\[A-Za-z0-9_]+/)) { d = substr(r, 2, RLENGTH - 1); q = 1 }
        else if (match(r, /^[A-Za-z0-9_]+/)) d = substr(r, 1, RLENGTH)
        else return 0
        e += RLENGTH; r = substr(r, RLENGTH + 1)
        if (!match(r, /^[ \t]*\n/)) return 0
        e += RLENGTH; r = substr(r, RLENGTH + 1)
        body = "\n" r
        k = index(body, "\n" d "\n")
        if (k == 0) return 0
        if (!q && substr(body, 1, k) ~ /[$`\\]/) return 0
        r = substr(body, k + length(d) + 2)
        if (!match(r, /^[ \t\n]*\)/)) return 0
        return p + e + k + length(d) + RLENGTH - 1
    }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
        n = length(s); i = 1; wlit = 1
        while (i <= n) {
            c = substr(s, i, 1)
            if (c == "'") {
                j = index(substr(s, i + 1), "'")
                if (j == 0) { bail = 1; break }
                rw = rw substr(s, i, j + 1); wt = wt substr(s, i + 1, j - 1); inw = 1
                i += j + 1; continue
            }
            if (c == "\"") {
                inw = 1; rw = rw c; i++
                while (i <= n && substr(s, i, 1) != "\"") {
                    c = substr(s, i, 1)
                    if (c == "$" && substr(s, i + 1, 1) == "(") {
                        e = heredoc(i)
                        if (!e) { bail = 1; break }
                        rw = rw substr(s, i, e - i + 1); wt = wt "x"; i = e + 1; continue
                    }
                    if (c == "`" || (c == "$" && substr(s, i + 1, 1) == "{")) { bail = 1; break }
                    if (c == "$" || c == "\\") wlit = 0
                    if (c == "\\") { rw = rw substr(s, i, 2); wt = wt substr(s, i + 1, 1); i += 2; continue }
                    rw = rw c; wt = wt c; i++
                }
                if (bail || i > n) { bail = 1; break }
                rw = rw "\""; i++; continue
            }
            if (c == "\\") { rw = rw substr(s, i, 2); wt = wt substr(s, i + 1, 1); wlit = 0; inw = 1; i += 2; continue }
            if (c == " " || c == "\t") { endword(); emit(c); i++; continue }
            if (c == "`" || (c == "#" && !inw) || (c == "$" && substr(s, i + 1, 1) ~ /[('{]/) \
                || (c == "<" && substr(s, i + 1, 1) ~ /[(<]/) || (c == ">" && substr(s, i + 1, 1) == "(")) {
                bail = 1; break
            }
            if (c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
                endseg(); bout = bout c; pout = pout c; i++; continue
            }
            if (c == "<" || c == ">") { endword(); emit(c); redir = 1; i++; continue }
            if (c == "$") wlit = 0
            rw = rw c; wt = wt c; inw = 1; i++
        }
        if (!bail) endseg()
        if (bail || guard) print s
        else if (mode == "p") print pout
        else print bout
    }
AWK
}
INERT_AWK="$(inert_awk)"
BCMD="$(normalize "$(printf '%s\n' "$COMMAND" | awk -v mode=b "$INERT_AWK")")"
PCMD="$(normalize "$(printf '%s\n' "$COMMAND" | awk -v mode=p "$INERT_AWK")")"
# A write redirect other than to /dev/null, /dev/std* or a file descriptor.
WRITE_REDIRECT=1
grep -q '>' <<<"$(sed -E -e 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr|tty)##g' \
    -e 's#[0-9]*>&[0-9-]+##g' -e 's#&>>?[[:space:]]*/dev/null##g' <<<"$BCMD")" || WRITE_REDIRECT=0
MUTATES=0
if grep -qE "$MUTATE_VERB|$MUTATE_EDIT|$MUTATE_FIND|$MUTATE_INTERP" <<<"$PCMD"; then
    MUTATES=1
fi
if [[ "$EXTRA_UNREAD" -eq 1 ]] && [[ "$MUTATES" -eq 1 || "$WRITE_REDIRECT" -eq 1 ]]; then
    defer_ask "policy protected_files.extra cannot be read ($EXTRA_WHY); confirm this command changes no protected path"
fi
ere_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
# shellcheck disable=SC2016
TOKEN_START='(^|[[:space:]"'"'"'=<>;&|(`])'
# shellcheck disable=SC2016
TOKEN_END='(["'"'"'[:space:];&|)`]|$)'
# The session's working directory relative to the project root, lowercased
# (#191): Claude Code keeps the Bash directory between calls and sends it
# as cwd, so after `cd .specify/gates` a later `rm policy.json` names the
# policy. Empty at the root or outside the project.
CWD_REL=""
_creal="$(cd "$CWD" 2>/dev/null && pwd -P)" || _creal=""
for _c in "${CWD%/}" "$_creal"; do
    for _r in "$LROOT" "$LREAL"; do
        [[ -n "$_c" && -n "$_r" && "$_c" == "$_r"/* ]] || continue
        CWD_REL="$(tr '[:upper:]' '[:lower:]' <<<"${_c#"$_r"/}" | sed -E -e 's#//+#/#g' -e 's#(^|/)(\./)+#\1#g' -e 's#/\.?$##')"
        break 2
    done
done
# pp_spelled <spelling> <anchored>: set _named, _entered and _redirect when
# NCMD names <spelling> (or a parent of it) in a change, changes into it or
# redirects to it. An anchored spelling, one relative to cwd, counts only
# at the start of an argument.
pp_spelled() {
    local sp="$1" anch="$2" pre dir e head
    pre="$(ere_escape "$sp")"
    head=""
    [[ "$anch" -eq 1 ]] && head="$TOKEN_START"
    if [[ "$anch" -eq 0 ]]; then
        grep -qF -- "$sp" <<<"$NCMD" && _named=1
    else
        grep -qE -- "$head$pre(/|$TOKEN_END)" <<<"$NCMD" && _named=1
    fi
    dir="$sp"
    while :; do
        e="$(ere_escape "$dir")"
        if grep -qE "(^|[;&|(\`[:space:]])(cd|pushd)[[:space:]]+[\"']?$e/?[\"']?$TOKEN_END|[[:space:]]-c[[:space:]]+[\"']?$e/?[\"']?$TOKEN_END" <<<"$NCMD"; then
            _entered=1
        fi
        # A parent directory counts only as a whole argument (or with a
        # glob under it) in the same command as the change, so `ls .specify
        # && rm build/x` stays allowed.
        if [[ "$dir" != "$sp" && "$MUTATES" -eq 1 ]] \
            && PAT="$TOKEN_START$e(/[^[:space:];&|]*[*?[][^[:space:];&|]*)?/?$TOKEN_END" \
                MUT="$MUTATE_VERB|$MUTATE_EDIT|$MUTATE_FIND|$MUTATE_INTERP" awk '
                    { n = split($0, part, /&&|\|\||;|&/)
                      for (k = 1; k <= n; k++) if (part[k] ~ ENVIRON["PAT"] && part[k] ~ ENVIRON["MUT"]) hit = 1 }
                    END { exit !hit }' <<<"$PCMD"; then
            _named=1
        fi
        [[ "$dir" == */* ]] || break
        dir="${dir%/*}"
    done
    # Redirects read the command with commit-message text blanked (#195).
    if [[ "$anch" -eq 0 ]]; then
        grep -qE ">>?[[:space:]]*[\"']?[^[:space:];&|]*$pre" <<<"$BCMD" && _redirect=1
    else
        grep -qE ">>?[[:space:]]*[\"']?$pre(/|$TOKEN_END)" <<<"$BCMD" && _redirect=1
    fi
    return 0
}
while IFS= read -r _pp; do
    [[ -n "$_pp" ]] || continue
    _pp="$(tr '[:upper:]' '[:lower:]' <<<"$_pp")"
    _named=0
    _entered=0
    _redirect=0
    pp_spelled "$_pp" 0
    if [[ -n "$CWD_REL" ]]; then
        if [[ "$CWD_REL" == "$_pp" || "$CWD_REL" == "$_pp"/* ]]; then
            # The session is inside the protected directory.
            _entered=1
        elif [[ "$_pp" == "$CWD_REL"/* ]]; then
            pp_spelled "${_pp#"$CWD_REL"/}" 1
        fi
    fi
    if { [[ "$_named" -eq 1 && "$MUTATES" -eq 1 ]]; } \
        || { [[ "$_entered" -eq 1 ]] && [[ "$MUTATES" -eq 1 || "$WRITE_REDIRECT" -eq 1 ]]; } \
        || [[ "$_redirect" -eq 1 ]]; then
        defer_ask "this command appears to modify the protected path $_pp; a human or a reviewed change makes that edit"
        break
    fi
done < <(protected_prefixes)

# Links (#193): protect-files judges a Write/Edit by its real path, so a
# link that reaches a protected path, or one spelled past the text match
# above (`ln -s ".spec"ify g`), asks. Each ln argument is unquoted and
# resolved from the cwd and from the link's directory; it asks when it is,
# contains or lies under a protected path, or cannot be resolved ($VAR,
# `cmd`, a glob, ~user).
# ln_real <absolute path>: every symlink resolved, as protect-files does.
ln_real() {
    local todo="$1" out="" comp link hops=0
    while [[ -n "$todo" ]]; do
        while [[ "$todo" == /* ]]; do todo="${todo#/}"; done
        [[ -n "$todo" ]] || break
        if [[ "$todo" == */* ]]; then comp="${todo%%/*}"; todo="${todo#*/}"; else comp="$todo"; todo=""; fi
        case "$comp" in
            . | '') continue ;;
            ..) out="${out%/*}"; continue ;;
        esac
        if [[ -L "$out/$comp" ]]; then
            hops=$((hops + 1))
            [[ "$hops" -le 40 ]] && link="$(readlink "$out/$comp" 2>/dev/null)" && [[ -n "$link" ]] || return 1
            [[ "$link" == /* ]] && out=""
            todo="$link${todo:+/$todo}"
        else
            out="$out/$comp"
        fi
    done
    printf '%s' "${out:-/}"
}
# One line per ln command: its operands, unquoted (options dropped). ln
# counts as the command word, after a wrapper (sudo, env, xargs, ...) or
# an environment assignment, or as the start of an `sh -c` / eval string.
LN_SEGS="$(printf '%s\n' "$COMMAND" | tr ';&|()' '\n' | awk '
    { out = ""; on = 0; prev = ""
      for (i = 1; i <= NF; i++) {
          t = $i; gsub(/["'"'"'\\]/, "", t)
          if (!on) {
              n = split(t, p, "/")
              if (p[n] == "ln" && (prev == "" || prev ~ /^(sudo|env|command|exec|xargs|nohup|time|nice|builtin|-c|eval)$/ || prev ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) on = 1
              else if (t != "") prev = t
              continue
          }
          if (t ~ /^-/ || t == "") continue
          out = out (out == "" ? "" : " ") t
      }
      if (on && out != "") print out }')"
if [[ -n "$LN_SEGS" ]]; then
    _lroot="${LREAL:-$LROOT}"
    _lprot=()
    while IFS= read -r _pp; do
        [[ -n "$_pp" ]] && _lprot+=("$(ln_real "$_lroot/$_pp" || printf '%s' "$_lroot/$_pp")")
    done < <(protected_prefixes)
    shopt -s nocasematch
    while IFS= read -r _seg; do
        read -r -a _largs <<<"$_seg"
        _last="${_largs[${#_largs[@]} - 1]}"
        [[ "$_last" == /* ]] || _last="$CWD/$_last"
        _bases=("$CWD" "${_last%/*}")
        [[ -d "$_last" ]] && _bases+=("$_last")
        for _a in "${_largs[@]}"; do
            [[ "$_a" == \~/* ]] && _a="$HOME/${_a#\~/}"
            case "$_a" in
                *'$'* | *'`'* | *'*'* | *'?'* | *'['* | '~'*)
                    defer_ask "cannot resolve the ln argument $_a; confirm it links to no protected path"
                    continue
                    ;;
            esac
            for _b in "${_bases[@]}"; do
                _r="$_a"
                [[ "$_r" == /* ]] || _r="$_b/$_r"
                if ! _r="$(ln_real "$_r")"; then
                    defer_ask "cannot resolve the symlinks in the ln argument $_a; confirm it links to no protected path"
                    continue
                fi
                for _p in "${_lprot[@]}"; do
                    if [[ "$_r" == / || "$_r" == "$_p" || "$_p" == "$_r/"* || "$_r" == "$_p/"* ]]; then
                        defer_ask "this ln command links to or through the protected path ${_p#"$_lroot"/}; a human makes that link"
                        break 3
                    fi
                done
            done
        done
    done <<<"$LN_SEGS"
    shopt -u nocasematch
fi

# Secret files (#130): protect-files refuses Write/Edit of these; a command
# that names one (`cat .env`, `cp id_rsa x`) asks, since reading it puts
# the secret in the transcript. Same names and allowlist as protect-files.
SECRET_FILE="$(printf '%s\n' "$COMMAND" | tr '<>|;&()=,' '         ' | awk '
    { for (i = 1; i <= NF; i++) {
        t = $i; gsub(/["'"'"'`]/, "", t)
        n = split(t, parts, "/"); b = tolower(parts[n])
        if (b ~ /\.(example|sample|template)$/) continue
        if (b == ".env" || b ~ /^\.env\./ || b ~ /^(id_rsa|id_ed25519|id_ecdsa)/ \
            || b == "authorized_keys" || b == "known_hosts" \
            || b ~ /\.(pem|key|crt|p12|pfx|jks|keystore)$/ \
            || b ~ /^(credentials|credentials\.json|credentials\.yml|credentials\.yaml|\.netrc|\.pypirc|aws-credentials)$/ \
            || b ~ /^(gcloud-.*|service-account.*)\.json$/) { if (found == "") found = t }
    } }
    END { print found }')"
if [[ -n "$SECRET_FILE" ]]; then
    defer_ask "this command names the secret file $SECRET_FILE; confirm it does not expose a credential"
fi

# Project-owned rules (#71) run once every shipped rule allowed, so they
# can add a refusal but never remove one. They run before any "ask": a
# project refusal is stronger than a question.
if compgen -G "$LROOT/.specify/gates/hooks.local.d/validate-bash/*.sh" >/dev/null; then
    LLIB="$LROOT/.specify/gates/lib/local-hooks.sh"
    if [[ ! -f "$LLIB" ]] || ! bash -n "$LLIB" 2>/dev/null; then
        ask "local rules exist in hooks.local.d/validate-bash, but lib/local-hooks.sh cannot load; run /speckit.gates.doctor"
    fi
    # shellcheck source=/dev/null disable=SC1090
    source "$LLIB"
    if ! GATES_LOCAL_STDIN="$INPUT" gates_run_local "$LROOT" validate-bash; then
        echo "BLOCKED: $GATES_LOCAL_MSG" >&2
        echo "Command: $COMMAND" >&2
        exit 2
    fi
fi

[[ -n "$ASK" ]] && ask "$ASK"

if [[ -n "$DEGRADED" ]]; then
    echo "gates: validate-bash checked in raw mode ($DEGRADED); run /speckit.gates.doctor" >&2
fi
exit 0
