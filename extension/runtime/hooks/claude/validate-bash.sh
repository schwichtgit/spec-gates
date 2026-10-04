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
# handle (\uXXXX could spell a blocked word), which the caller turns into
# "ask".
raw_field() {
    local v
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
for _tool in grep sed tr; do
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
# bulk_add_arg: print the first argument of a `git add` segment that stages
# in bulk; nothing when every argument is an explicit file or a flag.
bulk_add_arg() {
    local cwd seg a
    if [[ -z "$DEGRADED" ]]; then
        cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
    else
        cwd="$(raw_field cwd || true)"
    fi
    [[ -n "$cwd" ]] || cwd="$LROOT"
    while IFS= read -r seg; do
        grep -qE '^[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' <<<"$seg" \
            || continue
        set -f # word split the arguments without glob expansion
        # shellcheck disable=SC2086  # deliberate word split of the arguments
        for a in ${seg#*add}; do
            a="${a#[\"\']}"
            a="${a%[\"\']}"
            case "$a" in
                -A | --all | --no-ignore-removal | . | ./ | :/ | ':/*' | '*' | '.*' | */)
                    printf '%s\n' "$a"
                    set +f
                    return 0
                    ;;
                -*) ;;
                *)
                    if [[ "$a" == /* && -d "$a" ]] || [[ "$a" != /* && -d "$cwd/$a" ]]; then
                        printf '%s\n' "$a"
                        set +f
                        return 0
                    fi
                    ;;
            esac
        done
        set +f
    done < <(printf '%s\n' "$COMMAND" | awk '{ gsub(/&&|\|\||;|\||&/, "\n"); print }')
    return 0
}
if [[ -z "$BLOCKED" ]]; then
    BULK="$(bulk_add_arg)"
    if [[ -n "$BULK" ]]; then
        rc=0
        bulk_staging_on || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            BLOCKED="Bulk staging (git add $BULK) refused by policy git.block_bulk_staging; stage explicit paths"
        elif [[ "$rc" -eq 2 ]]; then
            ask "git add $BULK stages in bulk, and .specify/gates/policy.json cannot be read to check git.block_bulk_staging; run /speckit.gates.doctor"
        fi
    fi
fi

if [[ -n "$BLOCKED" ]]; then
    echo "BLOCKED: $BLOCKED" >&2
    echo "Command: $COMMAND" >&2
    exit 2
fi

# Protected paths through Bash (#95): Write/Edit to a protected path is
# refused by protect-files, but `rm`, `mv`, `sed -i`, a redirect or
# `git rm` reach it through here. Telling a modification from a read by
# the command text alone is a heuristic, so a command that appears to
# modify one asks the human instead of blocking; reads stay allowed. The
# paths: the project's rules (hooks.local.d) plus protected_files.extra
# (glob entries by their literal prefix; with jq only).
protected_prefixes() {
    printf '%s\n' ".specify/gates/hooks.local.d"
    local pf="$LROOT/.specify/gates/policy.json"
    [[ -z "$DEGRADED" && -f "$pf" ]] || return 0
    jq -r '(.protected_files.extra // [])[] | select(type == "string")' "$pf" 2>/dev/null \
        | sed -e 's/[*?[].*$//' -e 's:/*$::' | awk 'length($0) > 0' || true
}
# shellcheck disable=SC2016  # the backtick is a literal command separator
MUTATE_VERB='(^|[;&|(`[:space:]])(rm|rmdir|unlink|shred|mv|cp|ln|install|truncate|tee|chmod|chown|dd)[[:space:]]'
# shellcheck disable=SC2016
MUTATE_EDIT='(^|[;&|(`[:space:]])(sed|perl)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*i|(^|[;&|(`[:space:]])git[[:space:]]+(rm|mv|checkout|restore|reset|clean|stash)([[:space:]]|$)'
while IFS= read -r _pp; do
    [[ -n "$_pp" ]] || continue
    grep -qF -- "$_pp" <<<"$COMMAND" || continue
    _pre="$(printf '%s' "$_pp" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
    if grep -qE "$MUTATE_VERB|$MUTATE_EDIT" <<<"$COMMAND" \
        || grep -qE ">>?[[:space:]]*[\"']?[^[:space:];&|]*$_pre" <<<"$COMMAND"; then
        ask "this command appears to modify the protected path $_pp; a human or a reviewed change makes that edit"
    fi
done < <(protected_prefixes)

# Project-owned rules (#71) run once every shipped rule allowed, so they
# can add a refusal but never remove one.
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

if [[ -n "$DEGRADED" ]]; then
    echo "gates: validate-bash checked in raw mode ($DEGRADED); run /speckit.gates.doctor" >&2
fi
exit 0
