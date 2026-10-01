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

# Extract title, inline body, and body file from the command line.
PARTS=$(python3 - "$COMMAND" <<'PYEOF'
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
)

TITLE=$(printf '%s' "$PARTS" | jq -r '.title')
BODY=$(printf '%s' "$PARTS" | jq -r '.body')
BODY_FILE=$(printf '%s' "$PARTS" | jq -r '.body_file')
if [[ -n "$BODY_FILE" && "$BODY_FILE" != "-" ]]; then
    [[ "$BODY_FILE" != /* ]] && BODY_FILE="$PWD/$BODY_FILE"
    if [[ -f "$BODY_FILE" ]]; then
        BODY="$(cat "$BODY_FILE")"
    fi
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
