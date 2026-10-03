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
        printf '%s' "$INPUT" | grep -qE '"'"$1"'"[[:space:]]*:' && return 2
        return 1
    fi
    v="${v#=}"
    [[ "$v" == *'\u'* ]] && return 2
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
if echo "$COMMAND" | grep -qE '(^|[^[:alnum:]_.-])rm[[:space:]]+([^;&|]*[[:space:]])?'"$RM_TARGET"'([[:space:]]|[;&|)]|$)'; then
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
if echo "$COMMAND" | grep -qE 'git\s+push\s+(.*\s)?(-f|--force)(\s|$)'; then
    BLOCKED="git push --force"
fi

# Hard reset
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    BLOCKED="git reset --hard"
fi
if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
    BLOCKED="git clean -f"
fi
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+\.$'; then
    BLOCKED="git checkout . (discards all changes)"
fi
if echo "$COMMAND" | grep -qE 'git\s+restore\s+\.$'; then
    BLOCKED="git restore . (discards all changes)"
fi

# Dangerous permissions
if echo "$COMMAND" | grep -qE 'chmod\s+(-R\s+)?777'; then
    BLOCKED="chmod 777"
fi

# Disk destruction
if echo "$COMMAND" | grep -qE '>\s*/dev/sd'; then
    BLOCKED="Write to raw disk device"
fi
if echo "$COMMAND" | grep -qE 'mkfs\.'; then
    BLOCKED="Format filesystem"
fi
if echo "$COMMAND" | grep -qE 'dd\s+if=/dev/(zero|random)'; then
    BLOCKED="dd from zero/random device"
fi

# Fork bomb
if echo "$COMMAND" | grep -qF ':(){ :|:& };:'; then
    BLOCKED="Fork bomb"
fi

# Environment destruction
if echo "$COMMAND" | grep -qE '(unset\s+PATH|PATH=\s*$)'; then
    BLOCKED="PATH destruction"
fi

# Pipe to shell
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*(sh|bash)'; then
    BLOCKED="Pipe remote content to shell"
fi

if [[ -n "$BLOCKED" ]]; then
    echo "BLOCKED: $BLOCKED" >&2
    echo "Command: $COMMAND" >&2
    exit 2
fi

if [[ -n "$DEGRADED" ]]; then
    echo "gates: validate-bash checked in raw mode ($DEGRADED); run /speckit.gates.doctor" >&2
fi
exit 0
