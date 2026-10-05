#!/bin/bash
# shellcheck shell=bash
set -uo pipefail

# spec-gates pull/merge request check -- CI boundary (issues #53, #56).
#
# Two checks that need PR/MR context only CI has, so they are deliberately
# NOT verify.sh gates (verify.sh checks the tree identically at every
# boundary):
#
# 1. PR/MR text: the title and description must pass the same message rules
#    as commit-msg (lib/message.sh: AI-isms, branding, emoji,
#    Co-Authored-By, conventional title). On squash-merge repositories this
#    text becomes the commit on the default branch. With a range, the
#    rules come from the base's policy (#147), like the check below.
# 2. Protected changes: every commit in the range that changes a
#    protected_files.extra path must declare it ("Protected-Change: <path>")
#    and name an approver ("Approved-By: <name>") -- the commit-msg rule via
#    gates_protected_check, re-checked server-side for commits that never
#    passed a local hook. The rules come from the policy at the base, not the
#    PR head (#123); the protected list per commit is the union of the
#    policies at the base, the commit and its parent, and policy.json plus
#    hooks.local.d are always protected. Merge commits are checked for the
#    paths they change against every parent. Declarations in the PR/MR
#    description count for every commit (a squash merge keeps the
#    description, not the commit trailers).
#
# A base whose policy is invalid stops the check (exit 2): its rules cannot
# be read, and reading nothing would pass everything (#166). A base with no
# policy at all (the PR that adopts spec-gates) is checked against the PR's
# own policy, with policy.json, the constitution, hooks.local.d and the
# contract artifacts protected whatever that policy says.
#
# The runtime libraries load from $GATES_RUNTIME_DIR/lib when it is set
# (default: the project's .specify/gates). The CI templates use it to run
# the base revision's pr-check.sh and lib against the PR checkout, so a PR
# cannot replace the code that judges it (#166).
#
# Usage:
#   pr-check.sh [--title <text>] [--body-file <file>] [--range <base>..<head>]
#
# Inputs, flag first, then the CI's own variables:
#   title  --title | $GATES_PR_TITLE | $CI_MERGE_REQUEST_TITLE | $CHANGE_TITLE
#   body   --body-file | $GATES_PR_BODY | $CI_MERGE_REQUEST_DESCRIPTION
#          (GitLab: when that is truncated, or unset before GitLab 16.7, the
#          full description is fetched from the API with $GATES_GITLAB_TOKEN
#          or $CI_JOB_TOKEN; a truncated one that cannot be fetched fails)
#   range  --range | $GATES_COMMIT_RANGE | origin/$GITHUB_BASE_REF..HEAD
#          (pull_request events) | $CI_MERGE_REQUEST_DIFF_BASE_SHA..HEAD |
#          origin/$CHANGE_TARGET..HEAD
# A check with no input is skipped: a push to the default branch has no PR.
#
# Exit codes: 0 = pass or skipped, 1 = violation(s), 2 = setup error (for
# example a range that cannot be resolved -- fetch full history).

RANGE="${GATES_COMMIT_RANGE:-}"
TITLE="${GATES_PR_TITLE:-${CI_MERGE_REQUEST_TITLE:-${CHANGE_TITLE:-}}}"
BODY_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --range) RANGE="${2:?--range needs <base>..<head>}"; shift 2 ;;
        --title) TITLE="${2?--title needs text}"; shift 2 ;;
        --body-file) BODY_FILE="${2:?--body-file needs a path}"; shift 2 ;;
        *) echo "pr-check: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Both are required: without jq the policy reader returns no protected
# paths, which would read as "nothing protected" and pass (#121).
for _tool in jq git; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "pr-check: $_tool is not installed -- install it in the CI image (apt-get install $_tool, apk add $_tool, brew install $_tool)" >&2
        exit 2
    fi
done
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "pr-check: not inside a git repository" >&2
    exit 2
}
RUNTIME_DIR="$PROJECT_ROOT/.specify/gates"
if [[ -n "${GATES_RUNTIME_DIR:-}" ]]; then
    RUNTIME_DIR="$(cd "$GATES_RUNTIME_DIR" 2>/dev/null && pwd)" || {
        echo "pr-check: GATES_RUNTIME_DIR is not a directory: $GATES_RUNTIME_DIR" >&2
        exit 2
    }
fi
cd "$PROJECT_ROOT" || exit 2
# The rules come from the base policy, or the checked-out one on an
# adoption PR, never from the environment (#196): an inherited
# GATES_POLICY_FILE is ignored, and said so.
if [[ -n "${GATES_POLICY_FILE:-}" ]]; then
    echo "pr-check: GATES_POLICY_FILE=$GATES_POLICY_FILE is ignored at the CI boundary; the repository's policy applies" >&2
    unset GATES_POLICY_FILE
fi
POLICY_LIB="$RUNTIME_DIR/lib/policy.sh"
if [[ ! -f "$POLICY_LIB" ]]; then
    echo "pr-check: $POLICY_LIB not found -- re-project the runtime (/speckit.gates.upgrade)" >&2
    exit 2
fi
# shellcheck source=/dev/null disable=SC1091
source "$POLICY_LIB"
MESSAGE_LIB="$RUNTIME_DIR/lib/message.sh"
if ! command -v gates_protected_check >/dev/null 2>&1 || [[ ! -f "$MESSAGE_LIB" ]]; then
    echo "pr-check: projected runtime predates pr-check.sh -- re-project it (/speckit.gates.upgrade)" >&2
    exit 2
fi
# shellcheck source=/dev/null disable=SC1091
source "$MESSAGE_LIB"
FAILED=0

BODY=""
if [[ -n "$BODY_FILE" ]]; then
    BODY="$(cat "$BODY_FILE" 2>/dev/null)" || {
        echo "pr-check: cannot read $BODY_FILE" >&2
        exit 2
    }
else
    BODY="${GATES_PR_BODY:-${CI_MERGE_REQUEST_DESCRIPTION:-}}"
fi

# GitLab MR pipelines (#67). The CI variable can be truncated
# (CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED=true), and GitLab before 16.7
# does not set it at all. In both cases fetch the full description through
# the API: GATES_GITLAB_TOKEN (a read_api token) first, then CI_JOB_TOKEN as
# a best effort (its API scope may not cover merge requests).
# http_get <header> <url>: body on stdout, nonzero on any failure. curl when
# present, else python3's urllib: slim CI images (the GitLab template's
# node:*-slim) ship without curl, while python3 is already required.
http_get() { # <header "Name: value"> <url>
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 20 -H "$1" "$2" 2>/dev/null
        return
    fi
    python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import sys, urllib.request

name, _, value = sys.argv[1].partition(":")
request = urllib.request.Request(sys.argv[2], headers={name.strip(): value.strip()})
with urllib.request.urlopen(request, timeout=20) as response:
    sys.stdout.write(response.read().decode("utf-8"))
PYEOF
}

gitlab_fetch_description() { # -> full description on stdout, or return 1
    [[ -n "${CI_API_V4_URL:-}" && -n "${CI_PROJECT_ID:-}" && -n "${CI_MERGE_REQUEST_IID:-}" ]] || return 1
    local url="$CI_API_V4_URL/projects/$CI_PROJECT_ID/merge_requests/$CI_MERGE_REQUEST_IID" json
    if [[ -n "${GATES_GITLAB_TOKEN:-}" ]] \
        && json="$(http_get "PRIVATE-TOKEN: $GATES_GITLAB_TOKEN" "$url")" \
        && printf '%s' "$json" | jq -e 'has("description")' >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.description // ""'
        return 0
    fi
    if [[ -n "${CI_JOB_TOKEN:-}" ]] \
        && json="$(http_get "JOB-TOKEN: $CI_JOB_TOKEN" "$url")" \
        && printf '%s' "$json" | jq -e 'has("description")' >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.description // ""'
        return 0
    fi
    return 1
}
DESCRIPTION_UNCHECKABLE=""
if [[ -z "$BODY_FILE" && -z "${GATES_PR_BODY:-}" ]]; then
    if [[ "${CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED:-}" == "true" ]]; then
        if FULL="$(gitlab_fetch_description)"; then
            BODY="$FULL"
            echo "pr-check: GitLab truncated the MR description; checking the full text fetched from the API"
        else
            DESCRIPTION_UNCHECKABLE="GitLab truncated the MR description and the full text could not be fetched (set GATES_GITLAB_TOKEN to a read_api token, or shorten the description)"
        fi
    elif [[ -n "${CI_MERGE_REQUEST_IID:-}" && -z "${CI_MERGE_REQUEST_DESCRIPTION+set}" ]]; then
        if FULL="$(gitlab_fetch_description)"; then
            BODY="$FULL"
            echo "pr-check: CI_MERGE_REQUEST_DESCRIPTION is not set (GitLab < 16.7); checking the description fetched from the API"
        else
            echo "pr-check: NOTICE -- CI_MERGE_REQUEST_DESCRIPTION is not set (GitLab < 16.7) and no API token is available; only the MR title is checked (set GATES_GITLAB_TOKEN to check the description)"
        fi
    fi
fi
# Web forms submit CRLF line endings.
BODY="$(printf '%s' "$BODY" | tr -d '\r')"
TITLE="$(printf '%s' "$TITLE" | tr -d '\r')"

# Resolve the PR/MR range and load the policy committed at its base, before
# either check runs. -> 0 resolved (BASE, HEAD_REF set; GATES_POLICY_FILE
# points at the base policy when the base has one), 1 no range in this
# context, 2 setup error (message printed).
BASE_POLICY=""
trap '[[ -n "$BASE_POLICY" ]] && rm -f "$BASE_POLICY"' EXIT
resolve_range() {
    if [[ -z "$RANGE" ]]; then
        if [[ "${GITHUB_EVENT_NAME:-}" == pull_request* && -n "${GITHUB_BASE_REF:-}" ]]; then
            RANGE="origin/$GITHUB_BASE_REF..HEAD"
        elif [[ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]]; then
            RANGE="$CI_MERGE_REQUEST_DIFF_BASE_SHA..HEAD"
        elif [[ -n "${CHANGE_TARGET:-}" ]]; then
            RANGE="origin/$CHANGE_TARGET..HEAD"
        fi
    fi
    if [[ -z "$RANGE" ]]; then
        return 1
    fi
    if [[ "$RANGE" != *..* ]]; then
        echo "pr-check: --range must be <base>..<head>, got: $RANGE" >&2
        return 2
    fi
    BASE="${RANGE%%..*}"
    HEAD_REF="${RANGE##*..}"
    for ref in "$BASE" "$HEAD_REF"; do
        if ! git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
            echo "pr-check: cannot resolve '$ref' in this clone -- fetch full history (actions/checkout fetch-depth: 0)" >&2
            return 2
        fi
    done

    # The rules come from the base (#123, #147): the PR under review must
    # not be able to relax them, for its text or its protected changes. An
    # invalid base policy is a setup error, never an empty rule set (#166).
    # A base without a policy (the adoption PR) falls back to the
    # checked-out one, which must be valid too, and widens the
    # always-protected paths below.
    local err head_policy
    BASE_POLICY="$(mktemp 2>/dev/null || mktemp -t gates-policy)" || return 2
    if gates_policy_at_rev "$BASE" "$BASE_POLICY"; then
        if ! err="$(GATES_POLICY_FILE="$BASE_POLICY" gates_validate_policy "$BASE_POLICY" 2>&1)"; then
            echo "pr-check: ERROR -- the policy committed at the base ($BASE) is invalid, so its rules cannot be checked; fix .specify/gates/policy.json on the base branch first:" >&2
            printf '%s\n' "$err" | sed 's/^/  /' >&2
            return 2
        fi
        export GATES_POLICY_FILE="$BASE_POLICY"
    else
        rm -f "$BASE_POLICY"
        BASE_POLICY=""
        ADOPTION=true
        head_policy="$(gates_policy_file)"
        if [[ -f "$head_policy" ]] && ! err="$(gates_validate_policy "$head_policy" 2>&1)"; then
            echo "pr-check: ERROR -- the base ($BASE) has no policy and the pull request's own policy is invalid:" >&2
            printf '%s\n' "$err" | sed 's/^/  /' >&2
            return 2
        fi
        echo "pr-check: NOTICE -- the base ($BASE) has no .specify/gates/policy.json (adoption PR); checking against the pull request's own policy, with policy.json, the constitution, hooks.local.d and the contract artifacts protected regardless"
    fi
    return 0
}
ADOPTION=false
RANGE_RC=0
resolve_range || RANGE_RC=$?
# The rules cannot be read: checking the text against the checkout's policy
# would only add noise to the setup error.
[[ "$RANGE_RC" -eq 2 ]] && exit 2

# --- 1. PR/MR text ---
if [[ -n "$DESCRIPTION_UNCHECKABLE" ]]; then
    # Fail closed: passing on the visible part would hide a violation in the
    # truncated tail.
    echo "pr-check: ERROR -- $DESCRIPTION_UNCHECKABLE" >&2
    FAILED=$((FAILED + 1))
elif [[ -n "$TITLE" ]] || [[ "$BODY" =~ [^[:space:]] ]]; then
    if gates_message_check pr "$TITLE"$'\n\n'"$BODY"; then
        echo "pr-check: PR/MR title and description pass the message rules"
    else
        echo "pr-check: PR/MR title or description violates the message rules (see above)" >&2
        FAILED=$((FAILED + 1))
    fi
else
    echo "pr-check: text skipped -- no PR/MR title or description in this context"
fi

# --- 2. Protected changes over the commit range ---
# Paths checked whatever the policy says: the runtime's built-in entries plus
# the policy file itself, so a PR cannot switch its own check off (#123).
ALWAYS_PROTECTED="$GATES_BUILTIN_PROTECTED"$'\n'".specify/gates/policy.json"
ALWAYS_NAMES="policy.json, hooks.local.d"
# Adoption PR: no base policy decides what is protected, so the constitution
# joins the list rather than depending on the policy the PR brings (#166).
if [[ "$ADOPTION" == "true" ]]; then
    ALWAYS_PROTECTED="$ALWAYS_PROTECTED"$'\n'".specify/memory/constitution.md"
    ALWAYS_NAMES="policy.json, the constitution, hooks.local.d"
fi
protected_range_check() { # -> 0 pass/skip, 1 violations, 2 setup error
    if [[ "$RANGE_RC" -eq 1 ]]; then
        echo "pr-check: protected range skipped -- no pull/merge request range (pass --range or set GATES_COMMIT_RANGE)"
        return 0
    fi
    [[ "$RANGE_RC" -eq 0 ]] || return 2
    FULL_LIST=true
    if ! gates_protected_trailer_enabled; then
        FULL_LIST=false
        echo "pr-check: git.protected_change_trailer is false -- checking only the always-protected paths ($ALWAYS_NAMES)"
    fi

    BODY_DECLARED="$(printf '%s\n' "$BODY" | gates_trailer_values protected-change)"
    BODY_APPROVERS="$(printf '%s\n' "$BODY" | gates_trailer_values approved-by)"

    # Merge commits included (#123): a merge is judged on its own edits.
    COMMITS="$(git rev-list --reverse "$BASE..$HEAD_REF")"
    CHECKED=0
    TOUCHING=0
    VIOLATIONS=0
    RANGE_CHANGED=""
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        CHECKED=$((CHECKED + 1))
        if git rev-parse -q --verify "$c^2" >/dev/null 2>&1; then
            # A merge: the protected candidates are the paths whose result
            # differs from every parent. A path equal to one parent came from
            # the base or from a commit in this range, checked on its own.
            # Declarations may name anything the merge brought in relative
            # to its first parent.
            candidates="$(git diff-tree -r -c --no-commit-id --name-only --no-renames "$c")"
            changed="$(git diff --name-only --no-renames "$c^1" "$c")"
        else
            changed="$(git diff-tree -r --root --no-commit-id --name-only --no-renames "$c")"
            candidates="$changed"
        fi
        RANGE_CHANGED="$RANGE_CHANGED"$'\n'"$changed"
        if [[ "$FULL_LIST" == "true" ]]; then
            patterns="$(gates_protected_list "$BASE" "$c^" "$c" 2>/dev/null)"$'\n'"$ALWAYS_PROTECTED"
        else
            patterns="$ALWAYS_PROTECTED"
        fi
        protected="$(printf '%s\n' "$candidates" | gates_match_protected "$patterns")"
        trailers="$(git log -1 --format=%B "$c" | git interpret-trailers --parse --no-divider 2>/dev/null)"
        declared="$(printf '%s\n' "$trailers" | gates_trailer_values protected-change)"
        approvers="$(printf '%s\n' "$trailers" | gates_trailer_values approved-by)"
        [[ -z "$protected" && -z "$declared" ]] && continue
        [[ -n "$protected" ]] && TOUCHING=$((TOUCHING + 1))
        # Description declarations cover every commit; whether they name a real
        # change is judged once against the whole range below.
        all_declared="$(printf '%s\n%s\n' "$declared" "$BODY_DECLARED" | awk 'NF')"
        all_approvers="$(printf '%s\n%s\n' "$approvers" "$BODY_APPROVERS" | awk 'NF')"
        out="$(gates_protected_check "$protected" "$changed"$'\n'"$BODY_DECLARED" "$all_declared" "$all_approvers" 2>&1)"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "commit $(git log -1 --format='%h %s' "$c"):" >&2
            printf '%s\n' "$out" | sed 's/^/  /' >&2
            VIOLATIONS=$((VIOLATIONS + rc))
        fi
    done <<<"$COMMITS"

    if [[ -n "$BODY_DECLARED" ]]; then
        out="$(gates_protected_check "" "$RANGE_CHANGED" "$BODY_DECLARED" "x" 2>&1)"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "pull/merge request description:" >&2
            printf '%s\n' "$out" | sed 's/^/  /' >&2
            VIOLATIONS=$((VIOLATIONS + rc))
        fi
    fi

    echo "pr-check: $RANGE -- $CHECKED commit(s) checked, $TOUCHING touching protected paths, $VIOLATIONS violation(s)"
    [[ "$VIOLATIONS" -gt 0 ]] && return 1
    return 0
}

rc=0
protected_range_check || rc=$?
[[ "$rc" -eq 2 ]] && exit 2
[[ "$rc" -ne 0 ]] && FAILED=$((FAILED + 1))
[[ "$FAILED" -gt 0 ]] && exit 1
exit 0
