#!/bin/bash
set -euo pipefail

# pr-check.sh tests (issues #53, #56): the CI-boundary PR/MR check.
#
#   - PR/MR text runs through the shared message rules (lib/message.sh).
#   - Protected-Change declarations are enforced per commit across the
#     range, from commit trailers or from the PR/MR description.
#   - GitHub, GitLab and Jenkins contexts resolve from their own variables;
#     no PR context -> skipped; an unresolvable range -> exit 2.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

expect() { # <name> <actual> <wanted>
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (got $2, want $3)"
        FAIL=$((FAIL + 1))
    fi
}

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-prcheck)"
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

# Fixture: a bare origin with main (protected c.md), and a feature branch
# with one plain commit and one that changes c.md without a trailer.
git init -q --bare "$WORKDIR/origin.git"
W="$WORKDIR/work"
git clone -q "$WORKDIR/origin.git" "$W" 2>/dev/null
git -C "$W" config user.email t@example.com
git -C "$W" config user.name tester
git -C "$W" checkout -q -b main
mkdir -p "$W/.specify/gates/lib"
cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$W/.specify/gates/lib/"
cp "$REPO_ROOT/extension/runtime/pr-check.sh" "$W/.specify/gates/"
printf '%s\n' '{ "hooks": {}, "protected_files": { "extra": ["c.md"] } }' >"$W/.specify/gates/policy.json"
echo c >"$W/c.md"
(
    cd "$W"
    git add -A && git commit -q -m "chore: seed" && git push -q origin main
    git checkout -q -b feat/x
    echo a >a.txt && git add a.txt && git commit -q -m "feat: add a"
    echo more >>c.md && git add c.md && git commit -q -m "docs: amend c"
) >/dev/null 2>&1
BASE="$(git -C "$W" rev-parse main)"

# Run pr-check in the fixture with a clean CI environment plus <env...>.
run() { # <env-assignment>... -> exit code
    local rc=0
    (cd "$W" && env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u CI_MERGE_REQUEST_DIFF_BASE_SHA \
        -u CI_MERGE_REQUEST_TITLE -u CI_MERGE_REQUEST_DESCRIPTION -u CHANGE_TARGET -u CHANGE_TITLE \
        -u GATES_PR_TITLE -u GATES_PR_BODY -u GATES_COMMIT_RANGE -u CLAUDE_PROJECT_DIR \
        -u CI_MERGE_REQUEST_IID -u CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED -u CI_API_V4_URL \
        -u CI_PROJECT_ID -u CI_JOB_TOKEN -u GATES_GITLAB_TOKEN \
        "$@" bash .specify/gates/pr-check.sh) >"$WORKDIR/out.txt" 2>&1 || rc=$?
    echo "$rc"
}
GH=(GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main)
DECL=$'\n\nProtected-Change: c.md\nApproved-By: Reviewer'

echo "=== no PR context ==="
expect "push to main (no title, body, or range) -> skipped, exit 0" "$(run)" 0
expect "skip is reported" "$(grep -c 'skipped' "$WORKDIR/out.txt")" 2

echo ""
echo "=== GitHub pull_request context ==="
expect "undeclared protected commit -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.")" 1
expect "the offending commit is named" "$(grep -c 'docs: amend c' "$WORKDIR/out.txt")" 1
expect "declaration in the PR body covers the commit -> exit 0" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.$DECL")" 0
expect "CRLF body from the web form -> still parsed, exit 0" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY=$'Adds a.\r\n\r\nProtected-Change: c.md\r\nApproved-By: Reviewer\r\n')" 0
expect "body declaration without approver -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY=$'Adds a.\n\nProtected-Change: c.md')" 1
expect "body declares a path the range does not touch -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.$DECL"$'\nProtected-Change: z.md')" 1
expect "AI-ism in the PR body -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="I have made this seamless.$DECL")" 1
expect "non-conventional PR title -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="Update stuff" GATES_PR_BODY="Adds a.$DECL")" 1
expect "emoji in the PR body -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a. 🤖$DECL")" 1
expect "branded term in the PR body -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Written with Copilot.$DECL")" 1
expect "plain attribution line in the PR body -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a."$'\n\n'"Generated with Claude Code$DECL")" 1
expect "the attribution line is the reported violation" \
    "$(grep -c 'Agent attribution line detected' "$WORKDIR/out.txt")" 1
expect "markdown-link attribution line in the PR body -> exit 1" \
    "$(run "${GH[@]}" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a."$'\n\n'"Generated with [Claude Code](https://claude.com/claude-code)$DECL")" 1
expect "the linked attribution line is the reported violation" \
    "$(grep -c 'Agent attribution line detected' "$WORKDIR/out.txt")" 1

echo ""
echo "=== GitLab merge_request context ==="
expect "MR variables resolve the range; undeclared -> exit 1" \
    "$(run CI_MERGE_REQUEST_DIFF_BASE_SHA="$BASE" CI_MERGE_REQUEST_TITLE="feat: x" CI_MERGE_REQUEST_DESCRIPTION="Adds a.")" 1
expect "declared in the MR description -> exit 0" \
    "$(run CI_MERGE_REQUEST_DIFF_BASE_SHA="$BASE" CI_MERGE_REQUEST_TITLE="feat: x" CI_MERGE_REQUEST_DESCRIPTION="Adds a.$DECL")" 0
expect "truncated description without API access -> fails closed" \
    "$(run CI_MERGE_REQUEST_DIFF_BASE_SHA="$BASE" CI_MERGE_REQUEST_TITLE="feat: x" CI_MERGE_REQUEST_DESCRIPTION="Adds a.$DECL" CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true)" 1

echo ""
echo "=== GitLab: truncated or missing description (#67) ==="
# A fake GitLab API served from disk: curl reads file:// URLs directly.
API="$WORKDIR/api"
mkdir -p "$API/projects/7/merge_requests"
mr_api() { # <description>
    jq -n --arg d "$1" '{iid: 3, title: "feat: x", description: $d}' >"$API/projects/7/merge_requests/3"
}
GL=(CI_MERGE_REQUEST_IID=3 CI_PROJECT_ID=7 "CI_API_V4_URL=file://$API" CI_MERGE_REQUEST_TITLE="feat: x"
    GATES_COMMIT_RANGE="$BASE..$BASE")
mr_api "Adds a."$'\n\n'"Tail line: I have made this seamless."
expect "truncated, no token -> fails closed (exit 1)" \
    "$(run "${GL[@]}" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true)" 1
expect "truncated failure names the fix" "$(grep -c 'GATES_GITLAB_TOKEN' "$WORKDIR/out.txt")" 1
expect "truncated, token -> full text fetched, tail violation caught (exit 1)" \
    "$(run "${GL[@]}" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true GATES_GITLAB_TOKEN=t)" 1
expect "the caught violation is the AI-ism in the tail" "$(grep -c 'Self-referential' "$WORKDIR/out.txt")" 1
mr_api "Adds a."$'\n\n'"A long but clean tail."
expect "truncated, token, clean full text -> exit 0" \
    "$(run "${GL[@]}" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true GATES_GITLAB_TOKEN=t)" 0
expect "truncated, CI_JOB_TOKEN fallback works -> exit 0" \
    "$(run "${GL[@]}" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true CI_JOB_TOKEN=j)" 0
# Without curl (slim CI images): the fetch falls back to python3's urllib.
NOCURL="$WORKDIR/path-nocurl"
mkdir -p "$NOCURL"
for t in bash sh git jq python3 perl cat grep sed awk head tail tr wc dirname basename mktemp rm cp env sort uniq cut date; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$NOCURL/$t"
done
mr_api "Adds a."$'\n\n'"Tail line: I have made this seamless."
if python3 -c 'import urllib.request' >/dev/null 2>&1; then
    expect "no curl: python3 fetch still finds the tail violation (exit 1)" \
        "$(run "${GL[@]}" PATH="$NOCURL" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true GATES_GITLAB_TOKEN=t)" 1
    expect "no curl: the violation came from the fetched tail" "$(grep -c 'Self-referential' "$WORKDIR/out.txt")" 1
else
    echo "SKIP: no curl, python3 fetch (this host lacks python3's urllib)"
fi
# Neither curl nor python3 (#120): no fetcher at all, so the truncated
# description cannot be checked and the check fails closed, saying why.
NOFETCH="$WORKDIR/path-nofetch"
mkdir -p "$NOFETCH"
for t in "$NOCURL"/*; do
    [[ "$(basename "$t")" == python3 ]] || ln -sf "$(readlink "$t")" "$NOFETCH/$(basename "$t")"
done
expect "no curl, no python3: truncated description fails closed (exit 1)" \
    "$(run "${GL[@]}" PATH="$NOFETCH" CI_MERGE_REQUEST_DESCRIPTION="Adds a." CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true GATES_GITLAB_TOKEN=t)" 1
expect "no curl, no python3: says the full text could not be fetched" \
    "$(grep -c 'could not be fetched' "$WORKDIR/out.txt")" 1
mr_api "Adds a."$'\n\n'"A long but clean tail."
expect "GitLab < 16.7 (no description var), no token -> notice, title checked (exit 0)" \
    "$(run "${GL[@]}")" 0
expect "the < 16.7 notice is printed" "$(grep -c 'GitLab < 16.7' "$WORKDIR/out.txt")" 1
mr_api "I have made this seamless."
expect "GitLab < 16.7 with token -> description fetched and checked (exit 1)" \
    "$(run "${GL[@]}" GATES_GITLAB_TOKEN=t)" 1

echo ""
echo "=== Jenkins and explicit range ==="
git -C "$W" update-ref refs/remotes/origin/main "$BASE"
expect "Jenkins CHANGE_TARGET resolves the range -> exit 1" \
    "$(run CHANGE_TARGET=main CHANGE_TITLE="feat: x")" 1
expect "--range with trailer-declared commit -> exit 0" \
    "$(cd "$W" && git commit -q --amend -m $'docs: amend c\n\nProtected-Change: c.md\nApproved-By: Reviewer' && run GATES_COMMIT_RANGE="$BASE..HEAD")" 0
expect "unresolvable base (shallow clone) -> exit 2" "$(run GATES_COMMIT_RANGE="deadbeef..HEAD")" 2
expect "trailer rule switched off in the checkout only -> base rules apply, exit 1" \
    "$(cd "$W" && git commit -q --amend -m 'docs: amend c' && printf '%s\n' '{ "hooks": {}, "git": { "protected_change_trailer": false }, "protected_files": { "extra": ["c.md"] } }' >.specify/gates/policy.json && run GATES_COMMIT_RANGE="$BASE..HEAD")" 1
git -C "$W" checkout -q -- .specify/gates/policy.json

echo ""
echo "=== policy comes from the base, not the PR head (#123) ==="
OFF='{ "hooks": {}, "git": { "protected_change_trailer": false }, "protected_files": { "extra": ["c.md"] } }'
(
    cd "$W"
    git checkout -q -b feat/off "$BASE"
    printf '%s\n' "$OFF" >.specify/gates/policy.json
    echo more >>c.md
    git add -A && git commit -q -m "chore: relax policy"
) >/dev/null 2>&1
expect "PR head disables the trailer rule and edits c.md + policy.json -> exit 1" \
    "$(run GATES_COMMIT_RANGE="$BASE..HEAD")" 1
expect "the undeclared policy.json change is named" \
    "$(grep -c 'without a declaration: .specify/gates/policy.json' "$WORKDIR/out.txt")" 1
expect "the undeclared c.md change is named (base list applies)" \
    "$(grep -c 'without a declaration: c.md' "$WORKDIR/out.txt")" 1
# A base that has the trailer rule off: c.md is the git boundary's job, but a
# change to policy.json is still checked.
(
    cd "$W"
    git checkout -q -b base-off "$BASE"
    printf '%s\n' "$OFF" >.specify/gates/policy.json
    git add -A && git commit -q -m "chore: trailer off"
    git checkout -q -b feat/c-only
    echo more >>c.md && git add -A && git commit -q -m "docs: amend c"
) >/dev/null 2>&1
OFFBASE="$(git -C "$W" rev-parse base-off)"
expect "base has the trailer rule off, c.md only -> exit 0" \
    "$(run GATES_COMMIT_RANGE="$OFFBASE..HEAD")" 0
expect "the narrowed check is reported" \
    "$(grep -c 'checking only the always-protected paths' "$WORKDIR/out.txt")" 1
(
    cd "$W"
    printf '%s\n' '{ "hooks": {}, "git": { "protected_change_trailer": false } }' >.specify/gates/policy.json
    git add -A && git commit -q -m "chore: drop protection"
) >/dev/null 2>&1
expect "base has the trailer rule off, policy.json changed undeclared -> exit 1" \
    "$(run GATES_COMMIT_RANGE="$OFFBASE..HEAD")" 1

echo ""
echo "=== merge commits (#123) ==="
(
    cd "$W"
    git checkout -q -b feat/m "$BASE"
    echo a >a.txt && git add a.txt && git commit -q -m "feat: add a"
    git checkout -q -b side
    echo b >b.txt && git add b.txt && git commit -q -m "feat: add b"
    git checkout -q feat/m
    git merge -q --no-ff --no-commit side
    echo evil >>c.md && git add c.md
    git commit -q -m "chore: merge side"
) >/dev/null 2>&1
expect "merge commit edits c.md without a declaration -> exit 1" \
    "$(run GATES_COMMIT_RANGE="$BASE..HEAD")" 1
expect "the merge commit is named" "$(grep -c 'chore: merge side' "$WORKDIR/out.txt")" 1
expect "merge commit edits c.md, declared in its message -> exit 0" \
    "$(cd "$W" && git commit -q --amend -m "chore: merge side$DECL" && run GATES_COMMIT_RANGE="$BASE..HEAD")" 0
expect "merge commit edits c.md, declared in the PR body -> exit 0" \
    "$(cd "$W" && git commit -q --amend -m "chore: merge side" && run GATES_COMMIT_RANGE="$BASE..HEAD" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.$DECL")" 0
# Updating the PR branch from the base ("Update branch"): the merge brings in
# a c.md change already declared on the base, which is not the PR's change.
(
    cd "$W"
    git checkout -q -b main2 "$BASE"
    echo more >>c.md && git add c.md && git commit -q -m "docs: amend c$DECL"
    git checkout -q -b feat/u "$BASE"
    echo a >a.txt && git add a.txt && git commit -q -m "feat: add a"
    git merge -q --no-ff -m "chore: merge main" main2
) >/dev/null 2>&1
MAIN2="$(git -C "$W" rev-parse main2)"
expect "merging the base into the PR branch -> exit 0" \
    "$(run GATES_COMMIT_RANGE="$MAIN2..HEAD")" 0
expect "the merge is counted as checked" \
    "$(grep -c '2 commit(s) checked, 0 touching' "$WORKDIR/out.txt")" 1

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
