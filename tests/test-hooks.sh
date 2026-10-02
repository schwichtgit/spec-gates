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
HOOKS="$REPO_ROOT/extension/runtime/hooks/claude"
GITHOOKS="$REPO_ROOT/extension/runtime/hooks/git"

PASS=0
FAIL=0
TOTAL=0

# Hooks are executed by path, never as `bash <hook>`: Claude Code and git
# run them through their shebang (#!/bin/bash), which on macOS is the stock
# bash 3.2. Invoking them through the PATH bash (often 5.x) hid a 3.2-only
# syntax error in validate-pr.sh until it shipped in 0.3.4.

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
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    [[ -d "$REPO_ROOT/node_modules" ]] && ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
    cat >"$dir/.specify/gates/policy.json" <<JSON
{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "$cmd" } } }
JSON
}

# True if the pinned node linters are installed (npm ci has run).
have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

# ===========================================================================
# Part A: self-contained hooks
# ===========================================================================
echo "=== protect-files.sh ==="
check "allowed file (src/main.ts)" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"src/main.ts\"}}' | '$HOOKS/protect-files.sh'"
check "blocked .env" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env\"}}' | '$HOOKS/protect-files.sh'"
check "blocked id_rsa" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\"config/id_rsa\"}}' | '$HOOKS/protect-files.sh'"
check "allowed .env.example" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.example\"}}' | '$HOOKS/protect-files.sh'"
check "allowed .env.template" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.template\"}}' | '$HOOKS/protect-files.sh'"
check "blocked .env.local" 2 bash -c "echo '{\"tool_input\":{\"file_path\":\".env.local\"}}' | '$HOOKS/protect-files.sh'"
check "fail-open bad JSON" 0 bash -c "echo 'not-json' | '$HOOKS/protect-files.sh'"

echo ""
echo "=== validate-bash.sh ==="
check "allowed ls" 0 bash -c "echo '{\"tool_input\":{\"command\":\"ls -la\"}}' | '$HOOKS/validate-bash.sh'"
check "blocked rm -rf /" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf /"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
check "blocked rm -rf ~" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf ~"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
check "blocked rm -rf /var/data" 2 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf /var/data"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
# rm guard (#68): whole-word rm, root/home as a complete argument, absolute
# paths blocked unless under a temp root. Payloads go through jq so quoting
# stays readable. Literal $TMPDIR / $HOME in the payloads are intended.
# shellcheck disable=SC2016
rmcheck() { # <name> <expect> <command>
    check "$1" "$2" bash -c "printf '%s' \"\$1\" | jq -Rc '{tool_input:{command:.}}' | '$HOOKS/validate-bash.sh'" _ "$3"
}
rmcheck "rm: brainstorm / is not rm" 0 'echo brainstorm /'
rmcheck "rm: temp dir path allowed" 0 'rm -rf /tmp/build-x'
rmcheck "rm: quoted temp path with space allowed" 0 'rm -rf "/tmp/build x"'
rmcheck "rm: macOS per-user temp allowed" 0 'rm -rf /var/folders/ab/cd/T/z'
# shellcheck disable=SC2016
rmcheck "rm: \$TMPDIR path allowed" 0 'rm -rf $TMPDIR/probe'
rmcheck "rm: git rm unaffected" 0 'git rm -r --cached docs/'
rmcheck "rm: later ls / is not an rm target" 0 'rm -rf build && ls /'
rmcheck "rm: root wildcard blocked" 2 'rm -rf /*'
# shellcheck disable=SC2016
rmcheck "rm: \$HOME blocked" 2 'rm -rf $HOME'
rmcheck "rm: /bin/rm on root blocked" 2 '/bin/rm -rf /'
rmcheck "rm: root as a later argument blocked" 2 'rm -rf ./build /'
rmcheck "rm: /tmp itself blocked" 2 'rm -rf /tmp'
rmcheck "rm: system path blocked" 2 'cd x && rm -rf /opt/app'
check "allowed rm -rf ./build" 0 bash -c 'echo '"'"'{"tool_input":{"command":"rm -rf ./build"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
check "blocked git push --force" 2 bash -c 'echo '"'"'{"tool_input":{"command":"git push --force origin main"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
check "blocked fork bomb" 2 bash -c 'echo '"'"'{"tool_input":{"command":":(){ :|:& };:"}}'"'"' | '"'$HOOKS/validate-bash.sh'"''
check "fail-open bad JSON" 0 bash -c "echo 'not-json' | '$HOOKS/validate-bash.sh'"

echo ""
echo "=== validate-pr.sh ==="
check "clean PR" 0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"feat: add auth\" --body \"Adds JWT\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "AI-ism blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"I have fixed it\" --body \"desc\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "non-PR skipped" 0 bash -c 'echo '"'"'{"tool_input":{"command":"npm install"}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "PR mentioning CLAUDE.md / .claude allowed" 0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"docs: update CLAUDE.md\" --body \"edits .claude/hooks/foo.sh\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "PR with standalone Claude still blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"feat: x\" --body \"Generated by Claude\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
BF="$WORKDIR/pr-body.md"
printf 'I have made this seamless.\n' >"$BF"
check "PR --body-file with AI-ism blocked" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file $BF\"}}' | '$HOOKS/validate-pr.sh'"
check "PR -F with AI-ism blocked" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create -t \\\"feat: x\\\" -F $BF\"}}' | '$HOOKS/validate-pr.sh'"
check "gh pr edit --body with AI-ism blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr edit 5 --body \"I have made it seamless.\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
# --body-file the hook cannot read fails closed (issue #65); a leading
# $VAR / ${VAR} / ~ is resolved from the hook's environment.
BFD="$WORKDIR/bf"
mkdir -p "$BFD"
printf 'I have made this seamless.\n' >"$BFD/bad.md"
printf 'Adds a parser.\n' >"$BFD/ok.md"
check "PR --body-file \$VAR/bad resolved and blocked" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file \$GATES_BF/bad.md\"}}' | GATES_BF='$BFD' '$HOOKS/validate-pr.sh'"
check "PR --body-file \${VAR}/ok resolved and allowed" 0 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file \${GATES_BF}/ok.md\"}}' | GATES_BF='$BFD' '$HOOKS/validate-pr.sh'"
check "PR --body-file unreadable path refused" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file $BFD/missing.md\"}}' | '$HOOKS/validate-pr.sh'"
check "PR --body-file with unset variable refused" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file \$GATES_UNSET_VAR/ok.md\"}}' | '$HOOKS/validate-pr.sh'"
check "PR --body-file - (stdin) refused" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body-file -\"}}' | '$HOOKS/validate-pr.sh'"
check "gh pr edit without title/body allowed" 0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr edit 5 --add-label bug"}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "gh pr edit body-only (no title) allowed" 0 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr edit 5 --body \"Adds a parser.\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "glab mr create with AI-ism blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"glab mr create --title \"feat: x\" --description \"I have made it seamless.\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "glab mr update non-conventional title blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"glab mr update 3 --title \"add stuff\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''
check "PR with emoji body blocked" 2 bash -c 'echo '"'"'{"tool_input":{"command":"gh pr create --title \"feat: x\" --body \"Adds JWT ✨\""}}'"'"' | '"'$HOOKS/validate-pr.sh'"''

# Fail closed once a PR command matched (issue #66): a missing tool or a
# missing runtime blocks it; a non-PR command is unaffected. PATH is reduced
# to a shim holding only the tools listed, minus the one under test.
toolpath() { # <dir> <excluded-tool>... -> builds <dir> with symlinks
    local dir="$1" t x skip
    shift
    mkdir -p "$dir"
    for t in cat grep git head sed awk tail wc tr dirname basename perl python3 jq; do
        skip=0
        for x in "$@"; do [[ "$t" == "$x" ]] && skip=1; done
        [[ "$skip" -eq 1 ]] && continue
        command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$dir/$t"
    done
}
NOJQ="$WORKDIR/path-nojq"; toolpath "$NOJQ" jq
NOPY="$WORKDIR/path-nopy"; toolpath "$NOPY" python3
NOBOTH="$WORKDIR/path-noboth"; toolpath "$NOBOTH" python3 perl
PRCMD='{"tool_input":{"command":"gh pr create --title \"feat: x\" --body \"Adds a parser.\""}}'
check "PR hook: no jq -> PR command refused" 2 bash -c "printf '%s' '$PRCMD' | PATH='$NOJQ' '$HOOKS/validate-pr.sh'"
check "PR hook: no jq -> non-PR command still allowed" 0 bash -c "printf '%s' '{\"tool_input\":{\"command\":\"ls -la\"}}' | PATH='$NOJQ' '$HOOKS/validate-pr.sh'"
check "PR hook: no python3 -> PR command refused" 2 bash -c "printf '%s' '$PRCMD' | PATH='$NOPY' '$HOOKS/validate-pr.sh'"
check "PR hook: missing runtime lib -> PR command refused" 2 bash -c "printf '%s' '$PRCMD' | CLAUDE_PROJECT_DIR='$WORKDIR/no-runtime-here' '$HOOKS/validate-pr.sh'"
check "PR hook: clean PR still allowed with full tooling" 0 bash -c "printf '%s' '$PRCMD' | '$HOOKS/validate-pr.sh'"
printf 'feat: add a thing\n' >"$WORKDIR/emoji-msg.txt"
check "emoji rule: perl fallback when python3 is absent" 0 bash -c "PATH='$NOPY' '$GITHOOKS/commit-msg' '$WORKDIR/emoji-msg.txt'"
check "emoji rule: neither python3 nor perl -> message refused" 0 bash -c "out=\$(PATH='$NOBOTH' '$GITHOOKS/commit-msg' '$WORKDIR/emoji-msg.txt' 2>&1); rc=\$?; [[ \$rc -eq 1 ]] && printf '%s' \"\$out\" | grep -q 'Cannot check for emoji'"

echo ""
echo "=== post-edit.sh ==="
check "valid path exit 0" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"test.xyz\"}}' | '$HOOKS/post-edit.sh'"
check "empty path exit 0" 0 bash -c "echo '{\"tool_input\":{\"file_path\":\"\"}}' | '$HOOKS/post-edit.sh'"

echo ""
echo "=== format-changed.sh ==="
check "stop_hook_active true" 0 bash -c "echo '{\"stop_hook_active\": true}' | '$HOOKS/format-changed.sh'"

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
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$AGENT_PASS' '$HOOKS/verify-quality.sh'"
check "failing gate -> block stop (exit 2)" 2 \
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$AGENT_FAIL' '$HOOKS/verify-quality.sh'"
check "loop guard (stop_hook_active) -> allow" 0 \
    bash -c "echo '{\"stop_hook_active\":true}' | CLAUDE_PROJECT_DIR='$AGENT_FAIL' '$HOOKS/verify-quality.sh'"
check "runtime not projected -> fail open" 0 \
    bash -c "echo '{}' | CLAUDE_PROJECT_DIR='$WORKDIR/unprojected' '$HOOKS/verify-quality.sh'"

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

# policy git.block_main_commits=false lets a main commit through (green gate).
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "git": { "block_main_commits": false } }' \
    >"$GF/.specify/gates/policy.json"
check "git.block_main_commits=false -> main commit allowed" 0 \
    bash -c "cd '$GF' && git switch -q main && echo c >c.txt && git add c.txt && git commit -q -m 'chore: c'"

# git.protected_change_trailer=false: pre-commit refuses a staged
# protected_files.extra entry outright (the pre-0.3.4 behaviour).
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "git": { "block_main_commits": false, "protected_change_trailer": false }, "protected_files": { "extra": ["secrets.txt", "infra/**"] } }' \
    >"$GF/.specify/gates/policy.json"
check "protected_files.extra -> staged listed file blocked" 1 \
    bash -c "cd '$GF' && echo x >secrets.txt && git add secrets.txt && git commit -q -m 'chore: s'"
check "protected_files.extra glob -> staged match blocked" 1 \
    bash -c "cd '$GF' && mkdir -p infra && echo x >infra/main.tf && git add infra/main.tf && git commit -q -m 'chore: tf'"

( cd "$GF" && git reset -q -- . >/dev/null 2>&1; rm -rf secrets.txt infra )

# Secret scan regression (issue #50): the whole gates runtime commits clean,
# while real credential assignments are still refused.
check "secret scan: entire runtime commits clean" 0 \
    bash -c "cd '$GF' && mkdir -p vendored && cp -R '$REPO_ROOT/extension/runtime/.' vendored/ && git add vendored && git commit -q -m 'chore: vendor runtime'"
check "secret scan: constitution.sh:178 prose line passes" 0 \
    bash -c "cd '$GF' && printf '%s\n' '  if (eq == 0) { bad = \"unparseable token: \" kv; break }' >prose.awk && git add prose.awk && git commit -q -m 'chore: prose'"
check "secret scan: api_key = \"AKIA...\" blocked" 1 \
    bash -c "cd '$GF' && printf 'api_key = \"%s\"\n' AKIAabcdefgh >k1.txt && git add k1.txt && git commit -q -m 'chore: k1'"
( cd "$GF" && git reset -q -- . >/dev/null 2>&1; rm -f k1.txt )
check "secret scan: token: 'abcdefgh12' blocked" 1 \
    bash -c "cd '$GF' && printf \"token: 'abcdefgh12'\\n\" >k2.txt && git add k2.txt && git commit -q -m 'chore: k2'"
( cd "$GF" && git reset -q -- . >/dev/null 2>&1; rm -f k2.txt )

# Forbidden-file allowlist: template/example files are committable even when
# the base name looks sensitive; real secret files still blocked.
FF="$WORKDIR/forbidden.sh"
sed -n '/^check_forbidden_files() {/,/^}/p' "$GITHOOKS/pre-commit" >"$FF"
check "forbidden: .env.example allowed" 0 bash -c "source '$FF'; check_forbidden_files .env.example"
check "forbidden: config.sample allowed" 0 bash -c "source '$FF'; check_forbidden_files config.sample"
check "forbidden: .env.template allowed" 0 bash -c "source '$FF'; check_forbidden_files .env.template"
check "forbidden: .env blocked" 1 bash -c "source '$FF'; check_forbidden_files .env"
check "forbidden: .env.local blocked" 1 bash -c "source '$FF'; check_forbidden_files .env.local"

# ===========================================================================
# Part D: agent-boundary protect-files consumes protected_files.extra
# ===========================================================================
echo ""
echo "=== protect-files.sh consumes protected_files.extra ==="
PF="$WORKDIR/protect"
project_runtime "$PF" "true"
printf '%s' '{ "hooks": {}, "protected_files": { "extra": ["docs/internal.md", "infra/**"] } }' \
    >"$PF/.specify/gates/policy.json"
check "policy-listed exact path blocked" 2 \
    bash -c "echo '{\"tool_input\":{\"file_path\":\"docs/internal.md\"}}' | CLAUDE_PROJECT_DIR='$PF' '$HOOKS/protect-files.sh'"
check "policy-listed glob path blocked" 2 \
    bash -c "echo '{\"tool_input\":{\"file_path\":\"infra/prod.tf\"}}' | CLAUDE_PROJECT_DIR='$PF' '$HOOKS/protect-files.sh'"
check "non-listed path allowed" 0 \
    bash -c "echo '{\"tool_input\":{\"file_path\":\"docs/public.md\"}}' | CLAUDE_PROJECT_DIR='$PF' '$HOOKS/protect-files.sh'"

# ===========================================================================
# Part E: commit-msg toggles (git.conventional_commits, git.forbid_ai_isms)
# ===========================================================================
echo ""
echo "=== commit-msg toggles ==="
CM="$GITHOOKS/commit-msg"
MSGF="$WORKDIR/msg.txt"

printf 'add a thing without a type\n' >"$MSGF"
check "commit-msg: non-conventional blocked (default)" 1 bash -c "'$CM' '$MSGF'"
printf 'feat: add a thing\n\nA plain body line.\n' >"$MSGF"
check "commit-msg: clean conventional passes (default)" 0 bash -c "'$CM' '$MSGF'"
printf 'feat: add a thing\n\nI have done the work.\n' >"$MSGF"
check "commit-msg: ai-ism blocked (default)" 1 bash -c "'$CM' '$MSGF'"
printf 'docs: update CLAUDE.md and .claude/hooks\n' >"$MSGF"
check "commit-msg: CLAUDE.md / .claude refs allowed" 0 bash -c "'$CM' '$MSGF'"
printf 'chore: bump claude-opus-4 model id\n' >"$MSGF"
check "commit-msg: claude- kebab identifier allowed" 0 bash -c "'$CM' '$MSGF'"
printf 'feat: add a thing\n\nGenerated by Claude.\n' >"$MSGF"
check "commit-msg: standalone Claude still blocked" 1 bash -c "'$CM' '$MSGF'"

CMD="$WORKDIR/cmsg"
project_runtime "$CMD" "true"
printf '%s' '{ "hooks": {}, "git": { "conventional_commits": false, "forbid_ai_isms": false } }' \
    >"$CMD/.specify/gates/policy.json"
printf 'random subject no type\n\nI have done it, seamless work.\n' >"$MSGF"
check "commit-msg: both toggles off -> allowed" 0 \
    bash -c "cd '$CMD' && CLAUDE_PROJECT_DIR='$CMD' '$CM' '$MSGF'"

# ===========================================================================
# Part E2: protected-change trailers (issue #47). Both git hooks installed;
# protected paths pass only with a Protected-Change trailer per staged path
# plus Approved-By, judged against HEAD's policy as well as the worktree's.
# ===========================================================================
echo ""
echo "=== commit-msg: Protected-Change trailers ==="
PT="$WORKDIR/protected"
mkdir -p "$PT"
git -C "$PT" init -q -b main
git -C "$PT" config user.email t@example.com
git -C "$PT" config user.name tester
project_runtime "$PT" "true"
cp "$GITHOOKS/pre-commit" "$GITHOOKS/commit-msg" "$PT/.git/hooks/"
chmod +x "$PT/.git/hooks/pre-commit" "$PT/.git/hooks/commit-msg"
printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "git": { "block_main_commits": false }, "protected_files": { "extra": ["const.md", ".specify/gates/policy.json"] } }' \
    >"$PT/.specify/gates/policy.json"
echo "# c" >"$PT/const.md"
( cd "$PT" && git add -A ) >/dev/null 2>&1
PTM="$WORKDIR/pt-msg.txt"

printf 'chore: seed\n' >"$PTM"
check "protected: staged without trailer blocked" 1 bash -c "cd '$PT' && git commit -q -F '$PTM'"
printf 'chore: seed\n\nProtected-Change: const.md\nApproved-By: Reviewer\n' >"$PTM"
check "protected: trailer covering only some paths blocked" 1 bash -c "cd '$PT' && git commit -q -F '$PTM'"
printf 'chore: seed\n\nProtected-Change: const.md\nProtected-Change: .specify/gates/policy.json\n' >"$PTM"
check "protected: full trailers but no Approved-By blocked" 1 bash -c "cd '$PT' && git commit -q -F '$PTM'"
printf 'chore: seed\n\nProtected-Change: const.md\nProtected-Change: .specify/gates/policy.json\n\nApproved-By: Reviewer\n' >"$PTM"
check "protected: declaration outside the trailer block blocked" 1 bash -c "cd '$PT' && git commit -q -F '$PTM'"
printf 'chore: seed\n\nProtected-Change: const.md\nProtected-Change: .specify/gates/policy.json\nApproved-By: Reviewer\n' >"$PTM"
check "protected: correct trailers pass" 0 bash -c "cd '$PT' && git commit -q -F '$PTM'"

printf 'feat: a\n\nProtected-Change: const.md\nApproved-By: Reviewer\n' >"$PTM"
check "protected: trailer naming an unstaged path blocked" 1 \
    bash -c "cd '$PT' && echo a >a.txt && git add a.txt && git commit -q -F '$PTM'"
( cd "$PT" && git reset -q -- . >/dev/null 2>&1; rm -f a.txt )

# A `---` rule in the body is prose, not a patch divider; editor comments and
# the `git commit -v` scissors section are not part of the message.
printf 'docs: amend const\n\nIntro.\n\n---\n\nProtected-Change: const.md\nApproved-By: Reviewer\n' >"$PTM"
check "protected: trailers below a --- rule are read" 0 \
    bash -c "cd '$PT' && echo '## more' >>const.md && git add const.md && git commit -q -F '$PTM'"
printf 'docs: amend const again\n\nProtected-Change: const.md\nApproved-By: Reviewer\n# Please enter the commit message.\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\ndiff --git a/const.md b/const.md\n' >"$PTM"
check "protected: trailers above the scissors line are read" 0 \
    bash -c "cd '$PT' && echo '## again' >>const.md && git add const.md && git commit -q --cleanup=scissors -F '$PTM'"

printf '%s' '{ "hooks": {} }' >"$PT/.specify/gates/policy.json"
printf 'chore: drop protection\n' >"$PTM"
check "protected: weakening staged policy still needs a trailer (HEAD policy)" 1 \
    bash -c "cd '$PT' && git add -A && git commit -q -F '$PTM'"
( cd "$PT" && git reset -q --hard >/dev/null 2>&1 )

printf 'chore: remove const\n' >"$PTM"
check "protected: deleting a protected file needs a trailer" 1 \
    bash -c "cd '$PT' && git rm -q const.md && git commit -q -F '$PTM'"
printf 'chore: remove const\n\nProtected-Change: const.md\nApproved-By: Reviewer\n' >"$PTM"
check "protected: declared deletion passes" 0 bash -c "cd '$PT' && git commit -q -F '$PTM'"
printf 'chore: remove the const file\n\nProtected-Change: const.md\nApproved-By: Reviewer\n' >"$PTM"
check "protected: message-only amend of a declared commit passes" 0 \
    bash -c "cd '$PT' && git commit -q --amend -F '$PTM'"

# ===========================================================================
# Part E2b: hook/runtime version skew. .git/hooks is shared by every branch,
# the projected runtime is not: a branch still on the v0.3.3 runtime must
# keep committing under the current hooks (message rules skipped with a
# warning) while protected files keep that runtime's refusal.
# ===========================================================================
echo ""
echo "=== hook/runtime version skew (current hooks, v0.3.3 runtime) ==="
if git -C "$REPO_ROOT" rev-parse -q --verify v0.3.3 >/dev/null 2>&1; then
    SK="$WORKDIR/skew"
    mkdir -p "$SK/.specify/gates/lib"
    git -C "$SK" init -q -b feat/old
    git -C "$SK" config user.email t@example.com
    git -C "$SK" config user.name tester
    for f in $(git -C "$REPO_ROOT" ls-tree --name-only v0.3.3 extension/runtime/lib/); do
        git -C "$REPO_ROOT" show "v0.3.3:$f" >"$SK/.specify/gates/lib/$(basename "$f")"
    done
    echo "0.3.3" >"$SK/.specify/gates/.runtime-version"
    printf '%s' '{ "hooks": {}, "protected_files": { "extra": ["const.md"] } }' >"$SK/.specify/gates/policy.json"
    cp "$GITHOOKS/pre-commit" "$GITHOOKS/commit-msg" "$SK/.git/hooks/"
    chmod +x "$SK/.git/hooks/pre-commit" "$SK/.git/hooks/commit-msg"
    check "skew: plain commit on a v0.3.3 branch still passes" 0 \
        bash -c "cd '$SK' && echo a >a.txt && git add -A && git commit -q -m 'feat: a' 2>'$WORKDIR/skew.err'"
    check "skew: the skipped message rules are announced" 0 \
        grep -q "predates the installed commit-msg hook" "$WORKDIR/skew.err"
    check "skew: protected file keeps the v0.3.3 refusal (pre-commit)" 1 \
        bash -c "cd '$SK' && echo c >const.md && git add const.md && git commit -q -F - <<<\$'docs: c\\n\\nProtected-Change: const.md\\nApproved-By: R' 2>'$WORKDIR/skew.err'"
    check "skew: the refusal comes from pre-commit's protected check" 0 \
        grep -q "BLOCKED: policy-protected file staged: const.md" "$WORKDIR/skew.err"
    ( cd "$SK" && git reset -q -- . >/dev/null 2>&1; rm -f const.md )
    echo "0.3.4" >"$SK/.specify/gates/.runtime-version"
    check "skew: a 0.3.4 runtime missing lib/message.sh fails closed" 1 \
        bash -c "cd '$SK' && echo b >b.txt && git add b.txt && git commit -q -m 'feat: b'"
else
    echo "SKIP: hook/runtime skew checks (tag v0.3.3 not available in this clone)"
fi

# ===========================================================================
# Part E2c: hook stubs (issue #59). .git/hooks holds the stub, which runs
# the CHECKED-OUT branch's .specify/gates/hooks/<name>: the hook version
# follows the branch, a branch without a projected hook is skipped, and a
# projected hook that lost its execute bit still runs.
# ===========================================================================
echo ""
echo "=== hook stubs follow the checked-out branch ==="
ST="$WORKDIR/stub"
mkdir -p "$ST/.specify/gates/hooks"
git -C "$ST" init -q -b feat/current
git -C "$ST" config user.email t@example.com
git -C "$ST" config user.name tester
project_runtime "$ST" "true"
cp "$GITHOOKS/pre-commit" "$GITHOOKS/commit-msg" "$ST/.specify/gates/hooks/"
for h in pre-commit commit-msg; do
    cp "$GITHOOKS/stub.sh" "$ST/.git/hooks/$h"
    chmod +x "$ST/.git/hooks/$h"
done
( cd "$ST" && git add -A && git commit -q -m "chore: seed" ) >/dev/null 2>&1
check "stub: the branch's commit-msg refuses a bad subject" 1 \
    bash -c "cd '$ST' && git commit -q --allow-empty -m 'bad subject'"
check "stub: the branch's commit-msg accepts a good subject" 0 \
    bash -c "cd '$ST' && git commit -q --allow-empty -m 'feat: good'"
chmod -x "$ST/.specify/gates/hooks/commit-msg"
check "stub: a projected hook without its execute bit still runs" 1 \
    bash -c "cd '$ST' && git commit -q --allow-empty -m 'bad subject'"
chmod +x "$ST/.specify/gates/hooks/commit-msg"
(
    cd "$ST" && git switch -q -c feat/other
    printf '#!/bin/bash\necho "other-branch hook ran" >&2\nexit 0\n' >.specify/gates/hooks/commit-msg
    git add -A && git commit -q --no-verify -m "chore: other hook"
) >/dev/null 2>&1
check "stub: another branch runs that branch's hook" 0 \
    bash -c "cd '$ST' && git commit -q --allow-empty -m 'bad subject' 2>'$WORKDIR/stub.err' && grep -q 'other-branch hook ran' '$WORKDIR/stub.err'"
check "stub: switching back restores this branch's hook" 1 \
    bash -c "cd '$ST' && git switch -q feat/current && git commit -q --allow-empty -m 'bad subject'"
check "stub: deleting the branch's hooks fails closed, not open" 1 \
    bash -c "cd '$ST' && git rm -q .specify/gates/hooks/pre-commit .specify/gates/hooks/commit-msg && git commit -q -m 'chore: drop hooks' 2>'$WORKDIR/stub.err'"
check "stub: the refusal names the missing hook" 0 \
    grep -q "refused -- .specify/gates exists" "$WORKDIR/stub.err"
( cd "$ST" && git reset -q --hard >/dev/null 2>&1 )
(
    # --orphan empties the index and removes tracked files; drop leftovers.
    cd "$ST" && git switch -q --orphan pre-adoption && rm -rf .specify
) >/dev/null 2>&1
check "stub: a branch without a projected hook is skipped, not refused" 0 \
    bash -c "cd '$ST' && echo x >x.txt && git add x.txt && git commit -q -m 'any subject' 2>'$WORKDIR/stub.err' && grep -q 'skipped' '$WORKDIR/stub.err'"

# ===========================================================================
# Part E2d: linked worktrees. Hooks live in the shared hooks directory
# (git rev-parse --git-path hooks); the stub runs the worktree's own
# branch hook, and the hooks judge the worktree's policy even when an
# inherited CLAUDE_PROJECT_DIR points at the main checkout.
# ===========================================================================
echo ""
echo "=== linked worktrees ==="
WM="$WORKDIR/wt-main"
mkdir -p "$WM/.specify/gates/hooks"
git -C "$WM" init -q -b main
git -C "$WM" config user.email t@example.com
git -C "$WM" config user.name tester
project_runtime "$WM" "true"
cp "$GITHOOKS/pre-commit" "$GITHOOKS/commit-msg" "$GITHOOKS/stub.sh" "$WM/.specify/gates/hooks/"
printf '%s' '{ "hooks": {}, "git": { "block_main_commits": false }, "protected_files": { "extra": ["c.md"] } }' \
    >"$WM/.specify/gates/policy.json"
echo c >"$WM/c.md"
WHOOKS="$(git -C "$WM" rev-parse --git-path hooks)"
[[ "$WHOOKS" != /* ]] && WHOOKS="$WM/$WHOOKS"
for h in pre-commit commit-msg; do
    cp "$GITHOOKS/stub.sh" "$WHOOKS/$h"
    chmod +x "$WHOOKS/$h"
done
( cd "$WM" && git add -A && git commit -q --no-verify -m "chore: seed" ) >/dev/null 2>&1
WT="$WORKDIR/wt-linked"
git -C "$WM" worktree add -q -b feat/wt "$WT" >/dev/null 2>&1
# The worktree's branch relaxes the subject rule; the main checkout keeps it.
printf '%s' '{ "hooks": {}, "git": { "block_main_commits": false, "conventional_commits": false }, "protected_files": { "extra": ["c.md"] } }' \
    >"$WT/.specify/gates/policy.json"
( cd "$WT" && git add -A && git commit -q --no-verify -m "chore: relax subjects" ) >/dev/null 2>&1
check "worktree: hooks run from the shared hooks directory" 1 \
    bash -c "cd '$WT' && echo x >>c.md && git add c.md && git commit -q -m 'docs: c'"
( cd "$WT" && git reset -q --hard >/dev/null 2>&1 )
check "worktree: the worktree's policy applies, not the inherited session's" 0 \
    bash -c "cd '$WT' && CLAUDE_PROJECT_DIR='$WM' git commit -q --allow-empty -m 'any subject'"
check "worktree: the main checkout still enforces its own policy" 1 \
    bash -c "cd '$WM' && git commit -q --allow-empty -m 'any subject'"

# ===========================================================================
# Part E3: configurable AI branding (git.ai_branding, issue #52)
# ===========================================================================
echo ""
echo "=== commit-msg: git.ai_branding ==="
AB="$WORKDIR/branding"
project_runtime "$AB" "true"
git -C "$AB" init -q
abcheck() { # <name> <expect> <msg>
    printf '%b' "$3" >"$MSGF"
    check "$1" "$2" bash -c "cd '$AB' && CLAUDE_PROJECT_DIR='$AB' '$CM' '$MSGF'"
}
abcheck "branding: default refuses Copilot" 1 'feat: Acme Copilot add-in\n'
abcheck "branding: default refuses GPT-4" 1 'feat: support GPT-4\n'
abcheck "branding: default ignores embedded substrings" 0 'feat: copilotage support\n'
abcheck "editor comments (# On branch ...) are not checked" 0 'feat: x\n\n# Please enter the commit message for your changes.\n# On branch feat/acme-copilot\n'
abcheck "scissors section (commit -v diff) is not checked" 0 'feat: x\n\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\ndiff --git a/x b/x\n+I have added a TODO for GPT\n'
printf '%s' '{ "hooks": {}, "git": { "ai_branding": { "allow_phrases": ["Acme Copilot", "feat/acme-copilot"] } } }' \
    >"$AB/.specify/gates/policy.json"
abcheck "branding: allow phrases pass" 0 'feat: Acme Copilot add-in\n\nFrom feat/acme-copilot.\n'
abcheck "branding: bare term elsewhere still refused" 1 'feat: Acme Copilot add-in\n\nWritten with Copilot.\n'
abcheck "branding: allow phrases are case-sensitive" 1 'feat: acme copilot add-in\n'
printf '%s' '{ "hooks": {}, "git": { "ai_branding": { "terms": [] } } }' >"$AB/.specify/gates/policy.json"
abcheck "branding: terms [] disables the term list" 0 'feat: OpenAI client\n'
abcheck "branding: terms [] keeps the standalone Claude rule" 1 'feat: x\n\nGenerated by Claude.\n'
printf '%s' '{ "hooks": {}, "git": { "ai_branding": { "allow_phrases": ["Claude Haiku"] } } }' >"$AB/.specify/gates/policy.json"
abcheck "branding: allow phrase also exempts standalone Claude" 0 'feat: support Claude Haiku\n'
check "validate-pr: allow phrase passes" 0 bash -c "printf '%s' '{\"hooks\":{},\"git\":{\"ai_branding\":{\"allow_phrases\":[\"Acme Copilot\"]}}}' >'$AB/.specify/gates/policy.json' && echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body \\\"Ships Acme Copilot\\\"\"}}' | CLAUDE_PROJECT_DIR='$AB' '$HOOKS/validate-pr.sh'"
check "validate-pr: bare term still refused" 2 bash -c "echo '{\"tool_input\":{\"command\":\"gh pr create --title \\\"feat: x\\\" --body \\\"Uses Copilot\\\"\"}}' | CLAUDE_PROJECT_DIR='$AB' '$HOOKS/validate-pr.sh'"

# ===========================================================================
# Part F: the auto-format hooks actually format (they resolve the runtime lib
# from .specify/gates/lib, not a script-relative path). Needs the pinned
# prettier; skips otherwise.
# ===========================================================================
echo ""
echo "=== auto-format hooks reformat files ==="
if have_node_linters; then
    PRETTIER="$REPO_ROOT/node_modules/.bin/prettier"
    NONE_MD='{ "hooks": { "prettier": { "include": ["**/*.md"], "orchestrator": "none", "severity": "error" }, "post-edit": { "severity": "warning" }, "format-changed": { "severity": "warning" } } }'

    # post-edit (PostToolUse): formats the single edited file.
    FMT="$WORKDIR/fmt"
    project_runtime "$FMT" "true"
    printf '%s' "$NONE_MD" >"$FMT/.specify/gates/policy.json"
    printf '#Bad md\n\n\n- x\n' >"$FMT/doc.md"
    check "post-edit: fixture starts prettier-dirty" 1 "$PRETTIER" --check "$FMT/doc.md"
    echo "{\"tool_input\":{\"file_path\":\"$FMT/doc.md\"}}" \
        | CLAUDE_PROJECT_DIR="$FMT" "$HOOKS/post-edit.sh" >/dev/null 2>&1 || true
    check "post-edit: file is prettier-clean afterwards" 0 "$PRETTIER" --check "$FMT/doc.md"

    # format-changed (Stop): formats tracked files that changed.
    FC="$WORKDIR/fchanged"
    mkdir -p "$FC"
    git -C "$FC" init -q -b main
    git -C "$FC" config user.email t@example.com
    git -C "$FC" config user.name tester
    project_runtime "$FC" "true"
    printf '%s' "$NONE_MD" >"$FC/.specify/gates/policy.json"
    printf '# Title\n\nBody.\n' >"$FC/doc.md"
    ( cd "$FC" && git add doc.md && git commit -q -m "seed" ) >/dev/null 2>&1
    printf '#Bad\n\n\n- x\n' >"$FC/doc.md"
    check "format-changed: target starts prettier-dirty" 1 "$PRETTIER" --check "$FC/doc.md"
    echo '{"stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$FC" "$HOOKS/format-changed.sh" >/dev/null 2>&1 || true
    check "format-changed: changed file is prettier-clean afterwards" 0 "$PRETTIER" --check "$FC/doc.md"
else
    echo "SKIP: auto-format hook checks (run npm ci to install pinned prettier)"
fi

# --- Summary ---
echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
