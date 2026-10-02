#!/bin/bash
set -euo pipefail

# PreToolUse hook for Bash commands that create or edit a pull/merge request:
# `gh pr create|edit` and `glab mr create|update`. Checks the title and body
# (inline, heredoc, or --body-file) with the shared message rules in
# lib/message.sh -- the same rules commit-msg and the CI PR check apply.
# Exit 0 = allow or not a PR command, Exit 2 = block (Claude Code convention).

trap 'exit 0' ERR

if ! command -v jq >/dev/null 2>&1; then
    echo "gates: jq not found, skipping hook" \
        "(run /speckit.gates.doctor)" >&2
    exit 0
fi

INPUT=$(cat /dev/stdin)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

if ! echo "$COMMAND" | grep -qE '(gh[[:space:]]+pr[[:space:]]+(create|edit)|glab[[:space:]]+mr[[:space:]]+(create|update))'; then
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "gates: python3 not found, skipping" \
        "PR validation" \
        "(run /speckit.gates.doctor)" >&2
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GATES_LIB_DIR="$PROJECT_ROOT/.specify/gates/lib"
if [[ ! -f "$GATES_LIB_DIR/message.sh" ]]; then
    echo "gates: $GATES_LIB_DIR/message.sh not found, skipping PR validation" \
        "(run /speckit.gates.doctor)" >&2
    exit 0
fi
# shellcheck source=/dev/null disable=SC1091
[[ -f "$GATES_LIB_DIR/policy.sh" ]] && source "$GATES_LIB_DIR/policy.sh"
# shellcheck source=/dev/null disable=SC1091
source "$GATES_LIB_DIR/message.sh"

# Extract title, inline body, and body file from the command line. The
# heredoc lives in a function, never inside $( ): macOS /bin/bash 3.2
# mis-parses a quoted heredoc within command substitution when its body
# holds \' and parentheses, and a syntax error exits 2 -- which Claude Code
# reads as "block", refusing every PR command.
pr_parts() { # <command>
    python3 - "$1" <<'PYEOF'
import json
import re
import sys

command = sys.argv[1] if len(sys.argv) > 1 else ""

def quoted(flags):
    pattern = r'(?:%s)(?:\s+|=)(?:"((?:\\.|[^"\\])*)"|\'([^\']*)\')' % "|".join(flags)
    m = re.search(pattern, command, re.DOTALL)
    if not m:
        return ""
    return m.group(1) if m.group(1) is not None else m.group(2)

def path(flags):
    pattern = r'(?:%s)(?:\s+|=)(?:"([^"]*)"|\'([^\']*)\'|(\S+))' % "|".join(flags)
    m = re.search(pattern, command)
    if not m:
        return ""
    return next(g for g in m.groups() if g is not None)

print(json.dumps({
    "title": quoted([r"--title", r"-t"]),
    "body": quoted([r"--body", r"-b", r"--description", r"-d"]),
    "body_file": path([r"--body-file", r"-F"]),
}))
PYEOF
}
PARTS=$(pr_parts "$COMMAND")

TITLE=$(printf '%s' "$PARTS" | jq -r '.title')
BODY=$(printf '%s' "$PARTS" | jq -r '.body')
BODY_FILE=$(printf '%s' "$PARTS" | jq -r '.body_file')

# The hook sees the command text before the shell expands it. Resolve a
# leading ~, $VAR or ${VAR} from this hook's environment (indirect expansion,
# never eval), then relative paths against $PWD. The quoted ~ and ${ below
# are literal on purpose: they match the UNexpanded command text.
# shellcheck disable=SC2088,SC2016
resolve_body_file() { # <path>
    local p="$1" name rest
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#"~/"}" ;;
        '${'*'}'*)
            name="${p#'${'}"; rest="${name#*'}'}"; name="${name%%'}'*}"
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${!name:-}" ]] && p="${!name}$rest"
            ;;
        '$'[A-Za-z_]*)
            name="${p#'$'}"; name="${name%%[!A-Za-z0-9_]*}"; rest="${p#'$'"$name"}"
            [[ -n "${!name:-}" ]] && p="${!name}$rest"
            ;;
    esac
    [[ "$p" != /* ]] && p="$PWD/$p"
    printf '%s\n' "$p"
}

# Fail closed (issue #65): a body this hook cannot read is a body it cannot
# check -- refuse instead of validating the title alone.
if [[ -n "$BODY_FILE" ]]; then
    if [[ "$BODY_FILE" == "-" ]]; then
        echo "PR validation failed:" >&2
        echo "ERROR: --body-file - (stdin) cannot be checked before the command runs." >&2
        echo "  Write the body to a file in a separate step and pass its path, or use --body." >&2
        exit 2
    fi
    RESOLVED="$(resolve_body_file "$BODY_FILE")"
    if [[ ! -f "$RESOLVED" || ! -r "$RESOLVED" ]]; then
        echo "PR validation failed:" >&2
        echo "ERROR: cannot read --body-file $BODY_FILE (resolved: $RESOLVED)." >&2
        echo "  Write the file in a separate step first and pass a readable path, or use --body." >&2
        exit 2
    fi
    BODY="$(cat "$RESOLVED")"
fi

if [[ -z "$TITLE" && -z "$BODY" ]]; then
    exit 0
fi

if ! VIOLATIONS=$(gates_message_check pr "$TITLE"$'\n\n'"$BODY" 2>&1); then
    echo "PR validation failed:" >&2
    printf '%s\n' "$VIOLATIONS" | grep -v '^WARN' >&2
    exit 2
fi

exit 0
