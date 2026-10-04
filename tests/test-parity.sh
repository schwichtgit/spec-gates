#!/bin/bash
set -euo pipefail

# Boundary parity test.
#
# The whole product rests on one claim: the quality gate is identical at every
# boundary because every boundary runs the same verify.sh with the same policy.
# This test asserts that three ways:
#
#   Part 1 (static)      -- each of the five boundaries invokes verify.sh with
#                           the boundary flag it should.
#   Part 2 (single impl) -- no boundary re-implements the gate; verify.sh is the
#                           only place the gate logic lives.
#   Part 3 (behavioural) -- running verify.sh at each boundary against one
#                           projected policy yields byte-identical gate results
#                           (only the boundary label differs).
#
# The old version of this file grepped scaffold CI files for the strings
# "prettier"/"shellcheck"; that asserted tool-name presence, not parity, and
# pointed at paths that no longer exist.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
FAILED=0
TOTAL=0

pass() {
    echo "PASS: $1"
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
}
fail() {
    echo "FAIL: $1"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
}

assert_invokes() { # <name> <file> <boundary>
    # Robust to the hooks invoking verify.sh through a variable ("$VERIFY"):
    # require both a reference to verify.sh and the correct --boundary flag,
    # rather than a single literal string.
    local name="$1" file="$2" boundary="$3"
    if [[ -f "$file" ]] \
        && grep -qF "verify.sh" "$file" \
        && grep -qF -- "--boundary $boundary" "$file"; then
        pass "$name routes through verify.sh --boundary $boundary"
    else
        fail "$name should invoke verify.sh with --boundary $boundary (file: $file)"
    fi
}

assert_absent() { # <name> <file> <needle>
    local name="$1" file="$2" needle="$3"
    if [[ -f "$file" ]] && grep -qF "$needle" "$file"; then
        fail "$name still contains a re-implemented gate ('$needle')"
    else
        pass "$name does not re-implement the gate ('$needle' absent)"
    fi
}

# ===========================================================================
# Part 1: every boundary invokes verify.sh
# ===========================================================================
echo "=== every boundary routes through verify.sh ==="
assert_invokes "CI/github" "$REPO_ROOT/extension/ci/github/gates.yml" "ci"
assert_invokes "CI/gitlab" "$REPO_ROOT/extension/ci/gitlab/gates.gitlab-ci.yml" "ci"
assert_invokes "CI/jenkins" "$REPO_ROOT/extension/ci/jenkins/Jenkinsfile.gates" "ci"
assert_invokes "agent hook" "$REPO_ROOT/extension/runtime/hooks/claude/verify-quality.sh" "agent"
assert_invokes "git hook" "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" "git"

# The projected CI templates carry the PR check and a hardened default:
# a consumer merging them must not be handed weaker settings than it has.
echo ""
echo "=== CI templates: PR check and hardening ==="
GH_T="$REPO_ROOT/extension/ci/github/gates.yml"
GL_T="$REPO_ROOT/extension/ci/gitlab/gates.gitlab-ci.yml"
for needle in "pr-check.sh" "fetch-depth: 0" "edited" "contents: read" \
    "persist-credentials: false" "concurrency:" "timeout-minutes:" "if [ -f package-lock.json ]"; do
    if grep -qF -- "$needle" "$GH_T"; then
        pass "github template has '$needle'"
    else
        fail "github template lacks '$needle'"
    fi
done
for needle in "pr-check.sh" 'GIT_DEPTH: "0"' "python3" "curl" "timeout:" "if [ -f package-lock.json ]"; do
    if grep -qF -- "$needle" "$GL_T"; then
        pass "gitlab template has '$needle'"
    else
        fail "gitlab template lacks '$needle'"
    fi
done

# Every template installs the tools the gate resolves (#138): the pinned,
# checksum-verified shellcheck through the projected installer, and the
# lockfile linters. Comment lines (# and //) do not count.
JK_T="$REPO_ROOT/extension/ci/jenkins/Jenkinsfile.gates"
code_lines() { grep -vE '^[[:space:]]*(#|//)' "$1"; }
for tpl in "$GH_T" "$GL_T" "$JK_T"; do
    name="${tpl#"$REPO_ROOT"/extension/ci/}"
    if grep -qE 'bash \.specify/gates/install-shellcheck\.sh' <<<"$(code_lines "$tpl")"; then
        pass "$name installs shellcheck with the projected installer"
    else
        fail "$name does not run .specify/gates/install-shellcheck.sh"
    fi
    if grep -qE '^shellcheck|[[:space:]]shellcheck([[:space:]]|$)' \
        <<<"$(code_lines "$tpl" | grep -E 'apt-get install' | grep -vE '^[[:space:]]*(sudo )?apt-get install -y -q shellcheck$')"; then
        fail "$name installs the distro shellcheck unconditionally"
    else
        pass "$name installs the distro shellcheck only without a pin"
    fi
    if grep -qE 'npm ci' <<<"$(code_lines "$tpl")"; then
        pass "$name installs the lockfile linters (npm ci)"
    else
        fail "$name does not run npm ci"
    fi
    if grep -qF 'bash .specify/gates/canary.sh' <<<"$(code_lines "$tpl")"; then
        pass "$name runs the canary suite (fails on a policy-enabled tool that is missing)"
    else
        fail "$name does not run canary.sh"
    fi
done
# shellcheck disable=SC2016  # a literal $WORKSPACE, as the Jenkinsfile has it
if grep -qF 'PATH+GATES=' <<<"$(code_lines "$JK_T")" \
    && grep -qF 'install-shellcheck.sh "$WORKSPACE@tmp/gates-bin"' <<<"$(code_lines "$JK_T")"; then
    pass "jenkins puts the installed shellcheck on the gate steps' PATH"
else
    fail "jenkins installs shellcheck where the gate steps do not look"
fi

# The templates and this repository's CI run one node major (#148): the
# GitLab image tag, the GitHub template's and this repository's
# node-version. A different major resolves different linter behavior.
first_match() { # <ERE with one group> <file>: the group of the first matching line
    sed -nE "/$1/{s//\\1/p;q;}" "$2"
}
GH_NODE="$(first_match '^[[:space:]]*node-version:[[:space:]]*"?([0-9]+).*' "$GH_T")"
GL_NODE="$(first_match '^[[:space:]]*image:[[:space:]]*node:([0-9]+).*' "$GL_T")"
CI_NODE="$(first_match '^[[:space:]]*node-version:[[:space:]]*"?([0-9]+).*' "$REPO_ROOT/.github/workflows/ci.yml")"
if [[ -n "$GH_NODE" && "$GL_NODE" == "$GH_NODE" && "$CI_NODE" == "$GH_NODE" ]]; then
    pass "ci templates and this repository's CI use node $GH_NODE"
else
    fail "node majors differ: github template ${GH_NODE:-none}, gitlab image ${GL_NODE:-none}, ci.yml ${CI_NODE:-none}"
fi

# This repository's CI installs shellcheck with the shipped installer and
# its checksums, not a copy of its own that could drift from them (#148).
if grep -qE 'bash extension/runtime/install-shellcheck\.sh' <<<"$(code_lines "$REPO_ROOT/.github/workflows/ci.yml")"; then
    pass "ci.yml installs shellcheck with the shipped installer"
else
    fail "ci.yml does not run extension/runtime/install-shellcheck.sh"
fi
if [[ ! -e "$REPO_ROOT/.github/scripts/install-shellcheck.sh" && ! -e "$REPO_ROOT/.github/shellcheck.sha256" ]]; then
    pass "no second shellcheck installer or checksum file in .github"
else
    fail "a second shellcheck installer or checksum file exists in .github"
fi

# ===========================================================================
# Part 2: the gate lives in exactly one place
# ===========================================================================
echo ""
echo "=== no boundary re-implements the gate ==="
# The legacy per-language walk and the per-file lint walk must be gone; if they
# come back, the boundaries can silently diverge again.
assert_absent "agent hook" "$REPO_ROOT/extension/runtime/hooks/claude/verify-quality.sh" "run_legacy_walk"
assert_absent "git hook" "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" "lint_staged_files"

# ===========================================================================
# Part 3: identical results across boundaries
# ===========================================================================
echo ""
echo "=== verify.sh yields identical results at every boundary ==="

if ! command -v jq >/dev/null 2>&1; then
    fail "jq required for the behavioural parity check"
else
    WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-parity)"
    trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

    mkdir -p "$WORKDIR/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$WORKDIR/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$WORKDIR/.specify/gates/lib/"

    # A deterministic gate set: one passing custom gate. The boundary flag must
    # not change the outcome, only the reported label.
    printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } } }' \
        >"$WORKDIR/.specify/gates/policy.json"

    run_boundary() { # <boundary> -> JSON with the label and timing stripped
        # The embedded attestation record legitimately differs across
        # boundaries in its label, timestamp, and durations; everything else
        # (policy hash, tool versions, counts, results) must be identical --
        # that IS the parity claim, now with evidence attached.
        CLAUDE_PROJECT_DIR="$WORKDIR" bash "$WORKDIR/.specify/gates/verify.sh" \
            --boundary "$1" --json | jq -S '
            del(.boundary)
            | if has("attestation") then
                .attestation |= (del(.ts) | del(.boundary)
                  | .gates |= map(del(.duration_s)))
              else . end'
    }

    A="$(run_boundary agent)"
    G="$(run_boundary git)"
    C="$(run_boundary ci)"

    if [[ "$A" == "$G" && "$G" == "$C" ]]; then
        pass "agent == git == ci (identical gate results)"
    else
        fail "boundary results diverged"
        printf 'agent: %s\ngit:   %s\nci:    %s\n' "$A" "$G" "$C"
    fi

    # And the label itself must still be set correctly (sanity).
    LABEL="$(CLAUDE_PROJECT_DIR="$WORKDIR" bash "$WORKDIR/.specify/gates/verify.sh" \
        --boundary ci --json | jq -r '.boundary')"
    if [[ "$LABEL" == "ci" ]]; then
        pass "boundary label is reported (ci)"
    else
        fail "boundary label wrong: $LABEL"
    fi
fi

# --- version lockstep: every version-bearing file agrees ---
# The release workflow refuses a tag that disagrees, but that check fires
# at tag time; this one fires on every PR, so drift can never even reach a
# tag. extension.yml is the source of truth.
echo ""
echo "=== version lockstep (extension.yml == package.json) ==="

EXT_VERSION="$(sed -n 's/^  version: "\(.*\)"$/\1/p' "$REPO_ROOT/extension/extension.yml" | head -n 1)"
PKG_VERSION="$(jq -r '.version' "$REPO_ROOT/package.json")"
LOCK_VERSION="$(jq -r '.version' "$REPO_ROOT/package-lock.json" 2>/dev/null || echo "$PKG_VERSION")"
if [[ -n "$EXT_VERSION" && "$EXT_VERSION" == "$PKG_VERSION" && "$EXT_VERSION" == "$LOCK_VERSION" ]]; then
    pass "extension.yml, package.json, package-lock.json all at $EXT_VERSION"
else
    fail "version drift: extension.yml=$EXT_VERSION package.json=$PKG_VERSION package-lock.json=$LOCK_VERSION (fix: npm version <X.Y.Z> --no-git-tag-version and bump extension.yml together)"
fi

echo ""
echo "$PASSED of $TOTAL tests passed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
