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
git_scan() {
    local seg t t2 q a base cdir sub n i dashdash
    local asg='^[A-Za-z_][A-Za-z0-9_]*='
    local -a w
    while IFS= read -r seg; do
        w=()
        read -r -a w <<<"$seg" || true
        n="${#w[@]}"
        i=0
        while [[ "$i" -lt "$n" ]]; do
            t="${w[i]}"
            if [[ ! "$t" =~ $asg ]]; then
                case "$t" in
                    sudo | env | command | exec | nohup | time | nice) ;;
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
        base="$CWD"
        if [[ -n "$cdir" ]]; then
            cdir="${cdir#[\"\']}"
            cdir="${cdir%[\"\']}"
            if [[ "$cdir" == /* ]]; then base="$cdir"; else base="$CWD/$cdir"; fi
        fi
        dashdash=0
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
                    if [[ "$t" == /* && -d "$t" ]] || [[ "$t" != /* && -d "$base/$t" ]]; then
                        printf 'BULK %s\n' "$a"
                    fi
                    ;;
            esac
        done
    done < <(printf '%s\n' "$COMMAND" | awk '{ gsub(/&&|\|\||;|\||&|\(|\)|`/, "\n"); print }')
    return 0
}
GIT_SCAN="$(git_scan)"
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
# allowed. The paths: the project's rules (hooks.local.d) plus
# protected_files.extra (glob entries by their literal prefix). Without
# jq, policy.json and the constitution are always checked, extra is read
# when it is a plain list of strings, and when it cannot be read a command
# that changes anything asks (#121). A path counts as named when it appears in the command, when one
# of its parent directories appears as a whole argument (`rm -rf
# .specify/gates`), or when the command first changes into it or a parent
# (`cd .specify/gates && ...`, `git -C`). Matching ignores case, after
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
if [[ -n "$DEGRADED" && -f "$POLICY" ]]; then
    rc=0
    RAW_EXTRA="$(raw_extra)" || rc=$?
    [[ "$rc" -eq 2 ]] && EXTRA_UNREAD=1
fi
protected_prefixes() {
    printf '%s\n' ".specify/gates/hooks.local.d"
    {
        if [[ -n "$DEGRADED" ]]; then
            printf '%s\n' ".specify/gates/policy.json" ".specify/memory/constitution.md"
            [[ -n "$RAW_EXTRA" ]] && printf '%s\n' "$RAW_EXTRA"
        elif [[ -f "$POLICY" ]]; then
            jq -r '(.protected_files.extra // [])[] | select(type == "string")' "$POLICY" 2>/dev/null || true
        fi
    } | sed -e 's/[*?[].*$//' -e 's:/*$::' | awk 'length($0) > 0' || true
}
# shellcheck disable=SC2016  # the backtick is a literal command separator
MUTATE_VERB='(^|[;&|(`[:space:]])(rm|rmdir|unlink|shred|mv|cp|ln|install|truncate|tee|chmod|chown|dd|rsync)[[:space:]]'
# shellcheck disable=SC2016
MUTATE_EDIT='(^|[;&|(`[:space:]])(sed|perl)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*i|(^|[;&|(`[:space:]])git[[:space:]]+(rm|mv|checkout|restore|reset|clean|stash)([[:space:]]|$)'
# shellcheck disable=SC2016
MUTATE_FIND='(^|[;&|(`[:space:]])find[[:space:]]([^;&|]*[[:space:]])?-(delete|exec|execdir|ok|okdir)([[:space:]]|$)'
# The command with path spellings normalized, lowercased.
# shellcheck disable=SC2016  # $PWD is literal command text here
NCMD="$(printf '%s\n' "$COMMAND" | awk -v root="$LROOT" '
    function strip(s, p,    i, out) {
        out = ""
        while ((i = index(s, p)) > 0) { out = out substr(s, 1, i - 1); s = substr(s, i + length(p)) }
        return out s
    }
    { s = strip($0, root "/"); s = strip(s, "\"$PWD\"/"); s = strip(s, "\"${PWD}\"/")
      s = strip(s, "$PWD/"); s = strip(s, "${PWD}/"); print s }' \
    | sed -E -e 's#//+#/#g' -e 's#/(\./)+#/#g' -e "s#(^|[[:space:]\"'=<>;&|(\`])(\./)+#\1#g" \
    | tr '[:upper:]' '[:lower:]')"
# A write redirect other than to /dev/null, /dev/std* or a file descriptor.
WRITE_REDIRECT=1
grep -q '>' <<<"$(sed -E -e 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr|tty)##g' \
    -e 's#[0-9]*>&[0-9-]+##g' -e 's#&>>?[[:space:]]*/dev/null##g' <<<"$NCMD")" || WRITE_REDIRECT=0
MUTATES=0
if grep -qE "$MUTATE_VERB|$MUTATE_EDIT|$MUTATE_FIND" <<<"$NCMD"; then
    MUTATES=1
fi
if [[ "$EXTRA_UNREAD" -eq 1 ]] && [[ "$MUTATES" -eq 1 || "$WRITE_REDIRECT" -eq 1 ]]; then
    defer_ask "policy protected_files.extra cannot be read ($DEGRADED); confirm this command changes no protected path"
fi
ere_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
# shellcheck disable=SC2016
TOKEN_START='(^|[[:space:]"'"'"'=<>;&|(`])'
# shellcheck disable=SC2016
TOKEN_END='(["'"'"'[:space:];&|)`]|$)'
while IFS= read -r _pp; do
    [[ -n "$_pp" ]] || continue
    _pp="$(tr '[:upper:]' '[:lower:]' <<<"$_pp")"
    _pre="$(ere_escape "$_pp")"
    _named=0
    _entered=0
    grep -qF -- "$_pp" <<<"$NCMD" && _named=1
    _dir="$_pp"
    while :; do
        _e="$(ere_escape "$_dir")"
        if grep -qE "(^|[;&|(\`[:space:]])(cd|pushd)[[:space:]]+[\"']?$_e/?[\"']?$TOKEN_END|[[:space:]]-c[[:space:]]+[\"']?$_e/?[\"']?$TOKEN_END" <<<"$NCMD"; then
            _entered=1
        fi
        # A parent directory counts only as a whole argument (or with a
        # glob under it) in the same command as the change, so `ls .specify
        # && rm build/x` stays allowed.
        if [[ "$_dir" != "$_pp" && "$MUTATES" -eq 1 ]] \
            && PAT="$TOKEN_START$_e(/[^[:space:];&|]*[*?[][^[:space:];&|]*)?/?$TOKEN_END" \
                MUT="$MUTATE_VERB|$MUTATE_EDIT|$MUTATE_FIND" awk '
                    { n = split($0, part, /&&|\|\||;|&/)
                      for (k = 1; k <= n; k++) if (part[k] ~ ENVIRON["PAT"] && part[k] ~ ENVIRON["MUT"]) hit = 1 }
                    END { exit !hit }' <<<"$NCMD"; then
            _named=1
        fi
        [[ "$_dir" == */* ]] || break
        _dir="${_dir%/*}"
    done
    if { [[ "$_named" -eq 1 && "$MUTATES" -eq 1 ]]; } \
        || { [[ "$_entered" -eq 1 ]] && [[ "$MUTATES" -eq 1 || "$WRITE_REDIRECT" -eq 1 ]]; } \
        || grep -qE ">>?[[:space:]]*[\"']?[^[:space:];&|]*$_pre" <<<"$NCMD"; then
        defer_ask "this command appears to modify the protected path $_pp; a human or a reviewed change makes that edit"
        break
    fi
done < <(protected_prefixes)

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
