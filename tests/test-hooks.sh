#!/bin/bash
set -euo pipefail

# Hook behaviour tests.
#
#   Part A: the self-contained Claude Code hooks (protect-files, validate-bash,
#           validate-pr, post-edit, format-changed) -- JSON on stdin, assert
#           exit code.
#   Part B: DELEGATION. The agent Stop hook (verify-quality.sh) and the git
#           pre-commit hook both route the quality gate through the single
#           verify.sh entrypoint. These tests project the runtime into temp
#           dirs and assert the fail-open / fail-closed contract end to end.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$REPO_ROOT/runtime/hooks/claude"
GITHOOKS="$REPO_ROOT/runtime/hooks/git"

PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1" expected_exit="$2"
    shift 2
    TOTAL=$((TOTAL + 1))
    local actual_exit=0
    "$@" >/dev/null 2>&1 || actual_exit=$?
    if [[ "$actual_exit" == "$expected_exit" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (exit=$actual_exit, expect=$expected_exit)"
        FAIL=$((FAIL + 1))
    fi
}

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-hooks)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

# Project the runtime into <dir> with a custom orchestrator whose command is
# <cmd> (use "true" to force a green gate, "false" to force a red one).
project_runtime() {
    local dir="$1" cmd="$2"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    cat >"$dir/.specify/gates/policy.json" <<JSON
{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "$cmd" } } }
JSON
}

# ===========================================================================
# Part A: self-contained hooks
# ===========================================================================
echo "=== protect-files.sh ==="
check "allowed file (src/main.ts)" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"src/main.ts\"}}' | bash '$HOOKS/protect-files.sh'"
check "blocked .env" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env\"}}' | bash '$HOOKS/protect-files.sh'"
check "blocked id_rsa" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\"config/id_rsa\"}}' | bash '$HOOKS/protect-files.sh'"
check "allowed .env.example" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.example\"}}' | bash '$HOOKS/protect-files.sh'"
check "blocked .env.local" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.local\"}}' | bash '$HOOKS/protect-files.sh'"
check "fail-open bad JSON" 0 bash -c "echo 'not-json' | bash '$HOOKS/protect-files.sh'"

echo ""
echo "=== validate-bash.sh ==="
check "allowed ls" 0 bash -c "echo '{\"tool_input\":{\"command\":\"ls -la\"}}' | bash '$HOOKS/validate-bash.sh'"
check "blocked rm -rf /" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf /"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "blocked rm -rf ~" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf ~"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "blocked rm -rf /var/data" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf /var/data"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "allowed rm -rf ./build" 0 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf ./build"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "blocked git push --force" 2 bash -c 'echo '"'"'{"tool_input":{"command":"git push --force origin main"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "blocked fork bomb" 2 bash -c 'echo '"'"'{"tool_input":{"command":":(){ :|:& };:"}}'"'"' | bash '"'$HOOKS/validate-bash.sh'"''
check "fail-open bad JSON" 0 bash -c "echo 'not-json' | bash '$HOOKS/validate-bash.sh'"

echo ""
echo "=== validate-pr.sh ==="
check "clean PR" 0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"feat: add auth\" --body \"Adds JWT\""}}'"'"' | bash '"'$HOOKS/validate-pr.sh'"''
check "AI-ism blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"I have fixed it\" --body \"desc\""}}'"'"' | bash '"'$HOOKS/validate-pr.sh'"''
check "non-PR skipped" 0 bash -c 'echo '"'"'{"tool_input":{"command":"npm install"}}'"'"' | bash '"'$HOOKS/validate-pr.sh'"''

echo ""
echo "=== post-edit.sh ==="
check "valid path exit 0" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"test.xyz\"}}' | bash '$HOOKS/post-edit.sh'"
check "empty path exit 0" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"\"}}' | bash '$HOOKS/post-edit.sh'"

echo ""
echo "=== format-changed.sh ==="
check "stop_hook_active true" 0 bash -c "echo '{\"stop_hook_active\": true}' | bash '$HOOKS/format-changed.sh'"

# ===========================================================================
# Part B: agent-boundary delegation (verify-quality.sh -> verify.sh)
# ===========================================================================
echo ""
echo "=== verify-quality.sh delegates to verify.sh (agent boundary) ==="
AGENT_PASS="$WORKDIR/agent-pass"
project_runtime "$AGENT_PASS" "true"
AGENT_FAIL="$WORKDIR/agent-fail"
project_runtime "$AGENT_FAIL" "false"

check "green gate -> allow stop" 0 \
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$AGENT_PASS' bash '$HOOKS/verify-quality.sh'"
check "failing gate -> block stop (exit 2)" 2 \
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$AGENT_FAIL' bash '$HOOKS/verify-quality.sh'"
check "loop guard (stop_hook_active) -> allow" 0 \
    bash -c "echo '{\"stop_hook_active\":true}' | CLAUDE_PROJECT_DIR='$AGENT_FAIL' bash '$HOOKS/verify-quality.sh'"
check "runtime not projected -> fail open" 0 \
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$WORKDIR/unprojected' bash '$HOOKS/verify-quality.sh'"

# ===========================================================================
# Part C: git-boundary delegation (pre-commit -> verify.sh)
# ===========================================================================
echo ""
echo "=== pre-commit delegates to verify.sh (git boundary) ==="
GF="$WORKDIR/gitrepo"
mkdir -p "$GF"
git -C "$GF" init -q -b main
git -C "$GF" config user.email t@example.com
git -C "$GF" config user.name tester
project_runtime "$GF" "true"
cp "$GITHOOKS/pre-commit" "$GF/.git/hooks/pre-commit"
chmod +x "$GF/.git/hooks/pre-commit"

# Seed main via the documented override so the branch is born.
( cd "$GF" && echo seed >seed.txt && git add seed.txt \
    && GATES_ALLOW_MAIN_COMMIT=1 git commit -q -m "chore: seed" ) >/dev/null 2>&1

check "block-main (born branch) blocks commit" 1 \
    bash -c "cd '$GF' && echo a >a.txt && git add a.txt && git commit -q -m 'x'"
check "feature branch + green gate -> commit passes" 0 \
    bash -c "cd '$GF' && git switch -q -c feat/x && git commit -q -m 'feat: add a'"
check "staged secret -> commit blocked" 1 \
    bash -c "cd '$GF' && printf 'AKIA%s\n' ABCDEFGHIJKLMNOP >s.txt && git add s.txt && git commit -q -m 'feat: s'"
( cd "$GF" && git reset -q s.txt >/dev/null 2>&1 && rm -f s.txt )

# Flip the gate red and confirm the commit is refused at the git boundary.
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "false" } } }' \
    >"$GF/.specify/gates/policy.json"
check "failing gate -> commit blocked" 1 \
    bash -c "cd '$GF' && echo b >b.txt && git add b.txt && git commit -q -m 'feat: b'"

# --- Summary ---
echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
