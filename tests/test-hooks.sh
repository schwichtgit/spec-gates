#!/bin/bash
set -euo pipefail

# Smoke tests for all 6 Claude Code hooks.
# Pipes JSON payloads to stdin and asserts exit codes.

HOOKS=".claude/hooks"
PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1" expected_exit="$2"
    shift 2
    TOTAL=$((TOTAL + 1))
    "$@" >/dev/null 2>&1 && actual_exit=0 || actual_exit=$?
    if [[ "$actual_exit" == "$expected_exit" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (exit=$actual_exit, expect=$expected_exit)"
        FAIL=$((FAIL + 1))
    fi
}

# --- protect-files.sh ---
echo "=== protect-files.sh ==="
check "allowed file (src/main.ts)"    0 bash -c "echo '{\"tool_input\":{\"file_path\":\"src/main.ts\"}}' | bash $HOOKS/protect-files.sh"
check "blocked .env"                  2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env\"}}' | bash $HOOKS/protect-files.sh"
check "blocked id_rsa"                2 bash -c "echo '{\"tool_input\":{\"file_path\":\"config/id_rsa\"}}' | bash $HOOKS/protect-files.sh"
check "allowed .env.example"          0 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.example\"}}' | bash $HOOKS/protect-files.sh"
check "blocked .env.local"            2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.local\"}}' | bash $HOOKS/protect-files.sh"
check "fail-open bad JSON"            0 bash -c "echo 'not-json' | bash $HOOKS/protect-files.sh"

echo ""
echo "=== validate-bash.sh ==="
check "allowed ls"                    0 bash -c "echo '{\"tool_input\":{\"command\":\"ls -la\"}}' | bash $HOOKS/validate-bash.sh"
check "blocked rm -rf /"              2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf /"}}'"'"' | bash '"$HOOKS"'/validate-bash.sh'
check "blocked git push --force"      2 bash -c 'echo '"'"'{"tool_input":{"command":"git push --force origin main"}}'"'"' | bash '"$HOOKS"'/validate-bash.sh'
check "blocked fork bomb"             2 bash -c 'echo '"'"'{"tool_input":{"command":":(){ :|:& };:"}}'"'"' | bash '"$HOOKS"'/validate-bash.sh'
check "fail-open bad JSON"            0 bash -c "echo 'not-json' | bash $HOOKS/validate-bash.sh"

echo ""
echo "=== validate-pr.sh ==="
check "clean PR"                      0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"feat: add auth\" --body \"Adds JWT\""}}'"'"' | bash '"$HOOKS"'/validate-pr.sh'
check "AI-ism blocked"                2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"I have fixed it\" --body \"desc\""}}'"'"' | bash '"$HOOKS"'/validate-pr.sh'
check "non-PR skipped"                0 bash -c 'echo '"'"'{"tool_input":{"command":"npm install"}}'"'"' | bash '"$HOOKS"'/validate-pr.sh'

echo ""
echo "=== post-edit.sh ==="
check "valid path exit 0"             0 bash -c "echo '{\"tool_input\":{\"file_path\":\"test.xyz\"}}' | bash $HOOKS/post-edit.sh"
check "empty path exit 0"             0 bash -c "echo '{\"tool_input\":{\"file_path\":\"\"}}' | bash $HOOKS/post-edit.sh"

echo ""
echo "=== format-changed.sh ==="
check "stop_hook_active true"         0 bash -c "echo '{\"stop_hook_active\": true}' | bash $HOOKS/format-changed.sh"

echo ""
echo "=== verify-quality.sh ==="
check "stop_hook_active true"         0 bash -c "echo '{\"stop_hook_active\": true}' | bash $HOOKS/verify-quality.sh"

# --- Summary ---
echo ""
echo "$PASS of $TOTAL tests passed."

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

exit 0
