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

# Bot PRs (#248): Dependabot and Renovate descriptions quote upstream
# release notes, so the GitHub template and the standalone pr snippet hand
# pr-check an empty body for them, and only for them.
BOT_GUARD="!contains(fromJSON('[\"dependabot[bot]\", \"renovate[bot]\"]'), github.event.pull_request.user.login) && github.event.pull_request.body || ''"
GH_SNIP="$(source "$REPO_ROOT/extension/runtime/lib/manifest.sh" && gates_ci_pr_snippet github)"
for src in template snippet; do
    if [[ "$src" == template ]]; then text="$(cat "$GH_T")"; else text="$GH_SNIP"; fi
    if grep -qF -- "GATES_PR_BODY: \${{ $BOT_GUARD }}" <<<"$text"; then
        pass "github $src skips the description of Dependabot and Renovate PRs"
    else
        fail "github $src checks bot-quoted release notes (or drops every description)"
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
    # The installer finds the pin (mise.lock, mise.toml or .tool-versions)
    # and says when there is none; a template grepping .tool-versions
    # itself misses a mise pin (#260).
    if grep -qF 'install-shellcheck.sh --pin || pin=$?' <<<"$(code_lines "$tpl")" \
        && ! grep -qF '.tool-versions' <<<"$(code_lines "$tpl")"; then
        pass "$name asks the installer for the pin"
    else
        fail "$name looks for the shellcheck pin itself"
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
    # The PR check runs the base revision's copy, not the PR's own (#166).
    # shellcheck disable=SC2016  # literal $base and $rt, as the templates have them
    if grep -qF 'git archive "$base" .specify/gates | tar -x -C "$rt"' <<<"$(code_lines "$tpl")" \
        && grep -qF 'GATES_RUNTIME_DIR="$rt/.specify/gates" bash "$rt/.specify/gates/pr-check.sh"' \
            <<<"$(code_lines "$tpl")"; then
        pass "$name runs the base revision's pr-check.sh"
    else
        fail "$name runs the pull request's own pr-check.sh"
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
# No job, the coverage job included, installs the unpinned distro package
# of shellcheck (#159).
if grep -qE '^shellcheck|[[:space:]]shellcheck([[:space:]]|$)' \
    <<<"$(code_lines "$REPO_ROOT/.github/workflows/ci.yml" | grep -E 'apt-get install')"; then
    fail "ci.yml installs the distro shellcheck"
else
    pass "no ci.yml job installs the distro shellcheck"
fi
COV_JOB="$(code_lines "$REPO_ROOT/.github/workflows/ci.yml" \
    | awk '/^  coverage:/ { on = 1; next } on && /^  [A-Za-z_-]+:/ { on = 0 } on')"
if grep -qE 'bash extension/runtime/install-shellcheck\.sh' <<<"$COV_JOB"; then
    pass "the coverage job installs shellcheck with the shipped installer"
else
    fail "the coverage job does not run extension/runtime/install-shellcheck.sh"
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

    # Project gates without skip_at (feature 006) run at every boundary:
    # the same results again, and the parity gate's set check passes.
    printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true",
        "gates": { "lint": { "command": "true" }, "soft": { "command": "exit 1", "severity": "warning" } } } } }' \
        >"$WORKDIR/.specify/gates/policy.json"
    A="$(run_boundary agent)"
    G="$(run_boundary git)"
    C="$(run_boundary ci)"
    if [[ "$A" == "$G" && "$G" == "$C" ]] \
        && [[ "$(jq -c '[.gates[] | [.name, .status]]' <<<"$C")" == '[["custom","pass"],["lint","pass"],["soft","warn"],["spec","pass"],["parity","pass"]]' ]]; then
        pass "project gates without skip_at: agent == git == ci, parity passes"
    else
        fail "project gates without skip_at: boundary results diverged or parity failed"
        printf 'agent: %s\ngit:   %s\nci:    %s\n' "$A" "$G" "$C"
    fi
fi

# ===========================================================================
# Part 4: the parity gate's gate-set check (feature 006, research R7)
# ===========================================================================
# gates_declared_not_run is fed the declared set and this run's gate
# entries directly: a run of verify.sh cannot drop a gate on purpose.
echo ""
echo "=== parity: every declared gate ran, or was skipped by declaration ==="
unrun() { # <boundary> <declared-json> <gates-json>
    (
        # shellcheck source=../extension/runtime/lib/attest.sh disable=SC1091
        source "$REPO_ROOT/extension/runtime/lib/attest.sh"
        gates_declared_not_run "$@"
    )
}
expect_unrun() { # <name> <wanted> <boundary> <declared-json> <gates-json>
    local got
    got="$(unrun "$3" "$4" "$5")"
    if [[ "$got" == "$2" ]]; then
        pass "$1"
    else
        fail "$1 (got '$got', want '$2')"
    fi
}
DECL='[{"name":"lint","skip_at":[]},{"name":"build","skip_at":["agent"]}]'
RAN_LINT='{"name":"lint","result":"pass"}'
expect_unrun "ci: a declared gate missing from the run is named" \
    "declared gates not run at ci: build" ci "$DECL" "[$RAN_LINT]"
expect_unrun "ci: every gate missing is named, in declared order" \
    "declared gates not run at ci: lint, build" ci "$DECL" '[{"name":"spec","result":"pass"}]'
expect_unrun "ci: passes when every declared gate ran (fail and warn count as ran)" \
    "" ci "$DECL" '[{"name":"lint","result":"fail"},{"name":"build","result":"warn"}]'
expect_unrun "ci: a declared skip never covers a gate at ci" \
    "declared gates not run at ci: build" ci "$DECL" \
    "[$RAN_LINT,{\"name\":\"build\",\"result\":\"skipped\",\"declared_skip\":\"agent\"}]"
expect_unrun "agent: a gate skipped by a declaration naming agent is covered" \
    "" agent "$DECL" "[$RAN_LINT,{\"name\":\"build\",\"result\":\"skipped\",\"declared_skip\":\"agent\"}]"
expect_unrun "agent: a skip the declaration does not name (only git) fails" \
    "declared gates not run at agent: build" agent '[{"name":"build","skip_at":["git"]}]' \
    '[{"name":"build","result":"skipped","declared_skip":"agent"}]'
DECL_B='[{"name":"build","skip_at":["agent","git"]}]'
expect_unrun "git: a skip recorded for another boundary fails" \
    "declared gates not run at git: build" git "$DECL_B" \
    '[{"name":"build","result":"skipped","declared_skip":"agent"}]'
expect_unrun "agent: a skip without declared_skip (not a declaration) fails" \
    "declared gates not run at agent: build" agent "$DECL_B" '[{"name":"build","result":"skipped"}]'
expect_unrun "none (no --boundary): a declared skip does not cover" \
    "declared gates not run at none: build" none "$DECL_B" \
    '[{"name":"build","result":"skipped","declared_skip":"agent"}]'
expect_unrun "no declared gates: nothing to report" "" ci '[]' "[$RAN_LINT]"
expect_unrun "unreadable input fails closed" \
    "declared gates not run at ci: the gate set could not be compared" ci 'not-json' '[]'

# Through verify.sh: a runner that lists no project gate (stubbed in the
# projected lib/policy.sh) runs none, and parity names the declared one.
if command -v jq >/dev/null 2>&1; then
    PD="$(mktemp -d 2>/dev/null || mktemp -d -t gates-parity-set)"
    mkdir -p "$PD/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$PD/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$PD/.specify/gates/lib/"
    printf '%s' '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
        "gates": { "lint": { "command": "true" } } } } }' >"$PD/.specify/gates/policy.json"
    printf '\ngates_project_gate_names() { :; }\n' >>"$PD/.specify/gates/lib/policy.sh"
    rc=0
    out="$(CLAUDE_PROJECT_DIR="$PD" bash "$PD/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
    if [[ "$rc" == 2 ]] && grep -qx '  \[fail\] parity -- declared gates not run at ci: lint' <<<"$out"; then
        pass "verify.sh: parity fails naming a declared gate the run dropped (exit 2)"
    else
        fail "verify.sh: parity did not name the dropped gate (exit $rc): $out"
    fi
    rm -rf "$PD"
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
