#!/bin/bash
set -euo pipefail

# PreToolUse hook for Bash commands.
# Reads JSON from stdin, parses the command field, blocks destructive patterns.
# Exit 0 = allow, Exit 1 = block.

trap 'exit 0' ERR

if ! command -v jq >/dev/null 2>&1; then
    echo "gates: jq not found, skipping hook" \
        "(run /speckit.gates.doctor)" >&2
    exit 0
fi

INPUT=$(cat /dev/stdin)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

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

exit 0
