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

# Run pr-check ($RUN_SCRIPT under $RUN_SHELL, default the checkout's copy under
# bash) in the fixture with a clean CI environment plus <env...>.
RUN_SCRIPT=.specify/gates/pr-check.sh
RUN_SHELL=(bash)
run() { # <env-assignment>... -> exit code
    local rc=0
    (cd "$W" && env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u CI_MERGE_REQUEST_DIFF_BASE_SHA \
        -u CI_MERGE_REQUEST_TITLE -u CI_MERGE_REQUEST_DESCRIPTION -u CHANGE_TARGET -u CHANGE_TITLE \
        -u GATES_PR_TITLE -u GATES_PR_BODY -u GATES_COMMIT_RANGE -u CLAUDE_PROJECT_DIR \
        -u CI_MERGE_REQUEST_IID -u CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED -u CI_API_V4_URL \
        -u CI_PROJECT_ID -u CI_JOB_TOKEN -u GATES_GITLAB_TOKEN -u GATES_RUNTIME_DIR \
        "$@" "${RUN_SHELL[@]}" "$RUN_SCRIPT") >"$WORKDIR/out.txt" 2>&1 || rc=$?
    echo "$rc"
}
GH=(GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main)
DECL=$'\n\nProtected-Change: c.md\nApproved-By: Reviewer'

echo "=== no PR context ==="
expect "push to main (no title, body, or range) -> skipped, exit 0" "$(run)" 0
expect "skip is reported" "$(grep -c 'skipped' "$WORKDIR/out.txt")" 2
# #196: an inherited GATES_POLICY_FILE does not replace the repository's rules.
printf '%s' '{ "hooks": {}, "git": { "conventional_commits": false } }' >"$WORKDIR/lax.json"
expect "GATES_POLICY_FILE is ignored: non-conventional title still -> exit 1" \
    "$(run GATES_POLICY_FILE="$WORKDIR/lax.json" GATES_PR_TITLE="Update stuff")" 1
expect "the ignored override is named" \
    "$(grep -c 'GATES_POLICY_FILE=.* is ignored at the CI boundary' "$WORKDIR/out.txt")" 1

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
# Without jq the protected list came out empty and an undeclared protected
# change passed (#121); pr-check now refuses to run and names jq.
NOJQ="$WORKDIR/path-nojq"
mkdir -p "$NOJQ"
for t in bash sh git python3 perl curl cat grep sed awk head tail tr wc dirname basename mktemp rm cp env sort uniq cut date; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$NOJQ/$t"
done
expect "no jq: undeclared protected commit -> setup error (exit 2)" \
    "$(run "${GH[@]}" PATH="$NOJQ" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.")" 2
expect "no jq: the refusal names jq" "$(grep -c 'jq is not installed' "$WORKDIR/out.txt")" 1
# Without git the refusal names git, not "not inside a git repository" (#122).
NOGIT="$WORKDIR/path-nogit"
mkdir -p "$NOGIT"
for t in bash sh jq python3 perl curl cat grep sed awk head tail tr wc dirname basename mktemp rm cp env sort uniq cut date; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$NOGIT/$t"
done
expect "no git: setup error (exit 2)" \
    "$(run "${GH[@]}" PATH="$NOGIT" GATES_PR_TITLE="feat: x" GATES_PR_BODY="Adds a.")" 2
expect "no git: the refusal says git is not installed" "$(grep -c 'git is not installed' "$WORKDIR/out.txt")" 1
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
echo "=== PR text is judged by the base policy too (#147) ==="
# The head relaxes the text rules in a properly declared commit, so only
# the text check decides the outcome.
(
    cd "$W"
    git checkout -q -b feat/relax-text "$BASE"
    printf '%s\n' '{ "hooks": {}, "git": { "forbid_ai_isms": false }, "protected_files": { "extra": ["c.md"] } }' \
        >.specify/gates/policy.json
    git add -A
    git commit -q -m "chore: relax the text rules" -m "Protected-Change: .specify/gates/policy.json
Approved-By: Reviewer"
) >/dev/null 2>&1
expect "head turns forbid_ai_isms off, its AI-ism body is still refused -> exit 1" \
    "$(run GATES_COMMIT_RANGE="$BASE..HEAD" GATES_PR_TITLE="feat: relax rules" GATES_PR_BODY="I have made this seamless.")" 1
expect "the refusal comes from the text rules" \
    "$(grep -c 'violates the message rules' "$WORKDIR/out.txt")" 1
expect "without a range the checkout's policy applies (nothing to compare against)" \
    "$(run GATES_PR_TITLE="feat: relax rules" GATES_PR_BODY="I have made this seamless.")" 0

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
echo "=== contract artifacts are built-in protected paths (#137) ==="
git -C "$W" checkout -q -- .specify/gates/policy.json
(cd "$W" && printf '{}\n' >.specify/gates/baseline.json && git add .specify/gates/baseline.json \
    && git commit -q -m "chore: edit the baseline snapshot") >/dev/null 2>&1
expect "undeclared baseline.json commit -> exit 1" "$(run GATES_COMMIT_RANGE="HEAD^..HEAD")" 1
expect "the commit counts as touching a protected path" \
    "$(grep -c '1 touching protected paths' "$WORKDIR/out.txt")" 1
expect "declared baseline.json commit -> exit 0" \
    "$(cd "$W" && git commit -q --amend -m $'chore: edit the baseline snapshot\n\nProtected-Change: .specify/gates/baseline.json\nApproved-By: Reviewer' && run GATES_COMMIT_RANGE="HEAD^..HEAD")" 0

echo ""
echo "=== an invalid base policy is a setup error, not an empty rule set (#166) ==="
# A base whose policy cannot be read used to yield no rules: an undeclared
# constitution change passed with "0 touching protected paths".
CONST=".specify/memory/constitution.md"
bad_base() { # <branch> <policy text> -> base sha; head adds an undeclared constitution change
    (
        cd "$W"
        git checkout -q -b "$1" "$BASE"
        printf '%s\n' "$2" >.specify/gates/policy.json
        git add -A && git commit -q -m "chore: break the policy"
        git checkout -q -b "$1-head"
        mkdir -p .specify/memory && echo "# changed" >"$CONST"
        git add -A && git commit -q -m "docs: rewrite the constitution"
    ) >/dev/null 2>&1
    git -C "$W" rev-parse "$1"
}
BADBASE="$(bad_base base-badjson '{"hooks":')"
expect "base policy is not valid JSON -> setup error (exit 2)" "$(run GATES_COMMIT_RANGE="$BADBASE..HEAD")" 2
expect "the refusal names the invalid base policy" \
    "$(grep -c 'policy committed at the base .* is invalid' "$WORKDIR/out.txt")" 1
expect "the protected count is never printed" "$(grep -c 'touching protected paths' "$WORKDIR/out.txt")" 0
BADBASE="$(bad_base base-badshape '{ "hooks": { "x": "s" } }')"
expect "base policy has the wrong shape -> setup error (exit 2)" "$(run GATES_COMMIT_RANGE="$BADBASE..HEAD")" 2
expect "the validator's own finding is shown" "$(grep -c 'x: must be an object' "$WORKDIR/out.txt")" 1

echo ""
echo "=== adoption PR: the base has no policy (#166) ==="
HEADPOL='{ "hooks": {}, "protected_files": { "extra": ["c.md"] } }'
(
    cd "$W"
    git checkout -q -b base-nopolicy "$BASE"
    git rm -q .specify/gates/policy.json && git commit -q -m "chore: before adoption"
    git checkout -q -b feat/adopt
    printf '%s\n' "$HEADPOL" >.specify/gates/policy.json
    git add -A && git commit -q -m "chore: adopt spec-gates" \
        -m $'Protected-Change: .specify/gates/policy.json\nApproved-By: Reviewer'
    mkdir -p .specify/memory && echo "# principles" >"$CONST"
    git add -A && git commit -q -m "docs: add the constitution"
) >/dev/null 2>&1
NOPOL="$(git -C "$W" rev-parse base-nopolicy)"
expect "undeclared constitution change, no base policy -> exit 1" "$(run GATES_COMMIT_RANGE="$NOPOL..HEAD")" 1
expect "the constitution is named although the PR's policy does not list it" \
    "$(grep -c "without a declaration: $CONST" "$WORKDIR/out.txt")" 1
expect "the fallback to the PR's own policy is stated" "$(grep -c 'adoption PR' "$WORKDIR/out.txt")" 1
expect "declared constitution change, no base policy -> exit 0" \
    "$(cd "$W" && git commit -q --amend -m "docs: add the constitution" -m "Protected-Change: $CONST
Approved-By: Reviewer" && run GATES_COMMIT_RANGE="$NOPOL..HEAD")" 0
(cd "$W" && echo more >>c.md && git add c.md && git commit -q -m "docs: amend c") >/dev/null 2>&1
expect "no base policy: the PR's own protected list applies (undeclared c.md -> exit 1)" \
    "$(run GATES_COMMIT_RANGE="$NOPOL..HEAD")" 1
expect "no base policy, the PR's policy invalid in the checkout -> exit 2" \
    "$(cd "$W" && printf '{"hooks":\n' >.specify/gates/policy.json && run GATES_COMMIT_RANGE="$NOPOL..HEAD")" 2
expect "the refusal names the PR's invalid policy" "$(grep -c "pull request's own policy is invalid" "$WORKDIR/out.txt")" 1
git -C "$W" checkout -q -- .specify/gates/policy.json

echo ""
echo "=== the base revision's pr-check judges the PR (#166) ==="
# The PR (pushed with --no-verify) replaces pr-check.sh with `exit 0`,
# empties lib/policy.sh and changes c.md undeclared. Its own copy passes;
# the base's copy, run against the PR checkout, finds the violation.
(
    cd "$W"
    git checkout -q -b feat/sabotage "$BASE"
    printf '#!/bin/bash\nexit 0\n' >.specify/gates/pr-check.sh
    printf '# emptied\n' >.specify/gates/lib/policy.sh
    echo more >>c.md
    git add -A && git commit -q -m "chore: speed up the check"
) >/dev/null 2>&1
expect "the PR's own pr-check.sh passes its own sabotage -> exit 0" "$(run GATES_COMMIT_RANGE="$BASE..HEAD")" 0
RT="$WORKDIR/base-runtime"
mkdir -p "$RT"
git -C "$W" archive "$BASE" .specify/gates | tar -x -C "$RT"
RUN_SCRIPT="$RT/.specify/gates/pr-check.sh"
expect "the base's pr-check.sh with GATES_RUNTIME_DIR -> exit 1" \
    "$(run GATES_COMMIT_RANGE="$BASE..HEAD" GATES_RUNTIME_DIR="$RT/.specify/gates")" 1
expect "it names the undeclared c.md" "$(grep -c 'without a declaration: c.md' "$WORKDIR/out.txt")" 1
expect "GATES_RUNTIME_DIR that is not a directory -> exit 2" \
    "$(run GATES_COMMIT_RANGE="$BASE..HEAD" GATES_RUNTIME_DIR="$WORKDIR/nowhere")" 2

# The shipped CI templates do this themselves: each one's PR step, run as
# written against the sabotaged checkout, must use the base's copy.
GH_T="$REPO_ROOT/extension/ci/github/gates.yml"
GL_T="$REPO_ROOT/extension/ci/gitlab/gates.gitlab-ci.yml"
JK_T="$REPO_ROOT/extension/ci/jenkins/Jenkinsfile.gates"
Q="'''"
awk '/- name: Check the pull request/ { s = 1 } s && /run: \|$/ { r = 1; next } r { sub(/^          /, ""); print }' \
    "$GH_T" >"$WORKDIR/tpl-github.sh"
awk '/BASE revision/ { s = 1 } s && /^    - \|$/ { r = 1; next } r && /^  [a-z]/ { exit } r { sub(/^      /, ""); print }' \
    "$GL_T" >"$WORKDIR/tpl-gitlab.sh"
awk -v q="$Q" '/BASE revision/ { s = 1 } s && index($0, "sh " q) { r = 1; next } r && index($0, q) { exit } r' \
    "$JK_T" >"$WORKDIR/tpl-jenkins.sh"
git -C "$W" update-ref refs/remotes/origin/main "$BASE"
TPL_GH=(GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main GATES_PR_TITLE="feat: x")
TPL_GL=(CI_MERGE_REQUEST_DIFF_BASE_SHA="$BASE" CI_MERGE_REQUEST_TITLE="feat: x")
TPL_JK=(CHANGE_TARGET=main CHANGE_TITLE="feat: x")
for p in github gitlab jenkins; do
    case "$p" in
        github) RUN_SHELL=(bash -e -o pipefail) && envs=("${TPL_GH[@]}") ;;
        gitlab) RUN_SHELL=(sh) && envs=("${TPL_GL[@]}") ;;
        jenkins) RUN_SHELL=(sh) && envs=("${TPL_JK[@]}") ;;
    esac
    RUN_SCRIPT="$WORKDIR/tpl-$p.sh"
    expect "$p template: the step was extracted" "$(grep -c 'GATES_RUNTIME_DIR=' "$RUN_SCRIPT")" 1
    expect "$p template: sabotaged PR is judged by the base's pr-check -> exit 1" "$(run "${envs[@]}")" 1
    expect "$p template: the log says the base copy ran" \
        "$(grep -c "running the base revision's pr-check.sh" "$WORKDIR/out.txt")" 1
done
# A base without pr-check.sh (the PR adopting spec-gates): the PR's own copy
# runs, and the log says so.
(
    cd "$W"
    git checkout -q -b base-noruntime "$BASE"
    git rm -q .specify/gates/pr-check.sh && git commit -q -m "chore: before the runtime"
    git checkout -q -b feat/runtime
    git checkout -q "$BASE" -- .specify/gates/pr-check.sh
    echo more >>c.md
    git add -A && git commit -q -m "chore: add the runtime"
) >/dev/null 2>&1
NORT="$(git -C "$W" rev-parse base-noruntime)"
git -C "$W" update-ref refs/remotes/origin/main "$NORT"
for p in github gitlab jenkins; do
    case "$p" in
        github) RUN_SHELL=(bash -e -o pipefail) && envs=("${TPL_GH[@]}") ;;
        gitlab) RUN_SHELL=(sh) && envs=(CI_MERGE_REQUEST_DIFF_BASE_SHA="$NORT" CI_MERGE_REQUEST_TITLE="feat: x") ;;
        jenkins) RUN_SHELL=(sh) && envs=("${TPL_JK[@]}") ;;
    esac
    RUN_SCRIPT="$WORKDIR/tpl-$p.sh"
    expect "$p template: base without pr-check.sh -> the PR's copy runs (exit 1 on undeclared c.md)" \
        "$(run "${envs[@]}")" 1
    expect "$p template: the fallback is stated" "$(grep -c 'has no pr-check.sh' "$WORKDIR/out.txt")" 1
done
RUN_SCRIPT=.specify/gates/pr-check.sh
RUN_SHELL=(bash)

echo ""
echo "$PASS of $TOTAL tests passed."
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
