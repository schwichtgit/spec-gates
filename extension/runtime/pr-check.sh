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
#    text becomes the commit on the default branch.
# 2. Protected changes: every commit in the range that changes a
#    protected_files.extra path must declare it ("Protected-Change: <path>")
#    and name an approver ("Approved-By: <name>") -- the commit-msg rule via
#    gates_protected_check, re-checked server-side for commits that never
#    passed a local hook. The protected list per commit is the union of the
#    policies at the commit and its parent. Declarations in the PR/MR
#    description count for every commit (a squash merge keeps the
#    description, not the commit trailers).
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

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "pr-check: not inside a git repository" >&2
    exit 2
}
cd "$PROJECT_ROOT" || exit 2
POLICY_LIB="$PROJECT_ROOT/.specify/gates/lib/policy.sh"
if [[ ! -f "$POLICY_LIB" ]]; then
    echo "pr-check: $POLICY_LIB not found -- re-project the runtime (/speckit.gates.upgrade)" >&2
    exit 2
fi
# shellcheck source=/dev/null disable=SC1091
source "$POLICY_LIB"
MESSAGE_LIB="$PROJECT_ROOT/.specify/gates/lib/message.sh"
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
gitlab_fetch_description() { # -> full description on stdout, or return 1
    [[ -n "${CI_API_V4_URL:-}" && -n "${CI_PROJECT_ID:-}" && -n "${CI_MERGE_REQUEST_IID:-}" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    local url="$CI_API_V4_URL/projects/$CI_PROJECT_ID/merge_requests/$CI_MERGE_REQUEST_IID" json
    if [[ -n "${GATES_GITLAB_TOKEN:-}" ]] \
        && json="$(curl -fsS --max-time 20 -H "PRIVATE-TOKEN: $GATES_GITLAB_TOKEN" "$url" 2>/dev/null)" \
        && printf '%s' "$json" | jq -e 'has("description")' >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.description // ""'
        return 0
    fi
    if [[ -n "${CI_JOB_TOKEN:-}" ]] \
        && json="$(curl -fsS --max-time 20 -H "JOB-TOKEN: $CI_JOB_TOKEN" "$url" 2>/dev/null)" \
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

# --- 1. PR/MR text ---
if [[ -n "$DESCRIPTION_UNCHECKABLE" ]]; then
    # Fail closed: passing on the visible part would hide a violation in the
    # truncated tail.
    echo "pr-check: ERROR -- $DESCRIPTION_UNCHECKABLE" >&2
    FAILED=$((FAILED + 1))
elif [[ -n "$TITLE" || -n "${BODY//[[:space:]]/}" ]]; then
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
protected_range_check() { # -> 0 pass/skip, 1 violations, 2 setup error
    if ! gates_protected_trailer_enabled; then
        echo "pr-check: protected range skipped -- git.protected_change_trailer is false (protected files are refused at the git boundary)"
        return 0
    fi

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
        echo "pr-check: protected range skipped -- no pull/merge request range (pass --range or set GATES_COMMIT_RANGE)"
        return 0
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

    BODY_DECLARED="$(printf '%s\n' "$BODY" | gates_trailer_values protected-change)"
    BODY_APPROVERS="$(printf '%s\n' "$BODY" | gates_trailer_values approved-by)"

    COMMITS="$(git rev-list --no-merges --reverse "$BASE..$HEAD_REF")"
    CHECKED=0
    TOUCHING=0
    VIOLATIONS=0
    RANGE_CHANGED=""
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        CHECKED=$((CHECKED + 1))
        changed="$(git diff-tree -r --root --no-commit-id --name-only --no-renames "$c")"
        RANGE_CHANGED="$RANGE_CHANGED"$'\n'"$changed"
        protected="$(printf '%s\n' "$changed" | gates_match_protected "$(gates_protected_list "$c^" "$c" 2>/dev/null)")"
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
