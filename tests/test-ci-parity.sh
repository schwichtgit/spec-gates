#!/bin/bash
set -euo pipefail

# TEST-008: CI Platform Parity Test
# Validates that all 3 CI platforms implement equivalent quality gates.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
FAILED=0
TOTAL=0

assert_exit() {
  local name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name (expected to contain '$needle')"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains_ci() {
  local name="$1" haystack="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qiF "$needle"; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name (expected to contain '$needle', case-insensitive)"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name (file not found: $path)"
    FAILED=$((FAILED + 1))
  fi
}

SCAFFOLD="$REPO_ROOT/.claude-plugin/scaffold"

GITHUB_CI="$SCAFFOLD/github/.github/workflows/ci.yml"
GITLAB_CI="$SCAFFOLD/gitlab/.gitlab-ci.yml"
JENKINS_CI="$SCAFFOLD/jenkins/Jenkinsfile"
GITHUB_RELEASE="$SCAFFOLD/github/.github/workflows/release.yml"

# --- 1-3: CI config files exist ---
echo "=== CI config file existence ==="

assert_file_exists "GitHub ci.yml exists" "$GITHUB_CI"
assert_file_exists "GitLab .gitlab-ci.yml exists" "$GITLAB_CI"
assert_file_exists "Jenkins Jenkinsfile exists" "$JENKINS_CI"

# Read file contents for string matching
GITHUB_CONTENT=""
GITLAB_CONTENT=""
JENKINS_CONTENT=""
RELEASE_CONTENT=""

[[ -f "$GITHUB_CI" ]] && GITHUB_CONTENT=$(cat "$GITHUB_CI")
[[ -f "$GITLAB_CI" ]] && GITLAB_CONTENT=$(cat "$GITLAB_CI")
[[ -f "$JENKINS_CI" ]] && JENKINS_CONTENT=$(cat "$JENKINS_CI")
[[ -f "$GITHUB_RELEASE" ]] && RELEASE_CONTENT=$(cat "$GITHUB_RELEASE")

# --- 4-6: ShellCheck present in all platforms ---
echo ""
echo "=== ShellCheck parity ==="

assert_contains_ci "GitHub ci.yml contains shellcheck" "$GITHUB_CONTENT" "shellcheck"
assert_contains_ci "GitLab .gitlab-ci.yml contains shellcheck" "$GITLAB_CONTENT" "shellcheck"
assert_contains_ci "Jenkins Jenkinsfile contains shellcheck" "$JENKINS_CONTENT" "shellcheck"

# --- 7-9: Markdownlint present in all platforms ---
echo ""
echo "=== Markdownlint parity ==="

assert_contains "GitHub ci.yml contains markdownlint" "$GITHUB_CONTENT" "markdownlint"
assert_contains "GitLab .gitlab-ci.yml contains markdownlint" "$GITLAB_CONTENT" "markdownlint"
assert_contains "Jenkins Jenkinsfile contains markdownlint" "$JENKINS_CONTENT" "markdownlint"

# --- 10-12: Prettier present in all platforms ---
echo ""
echo "=== Prettier parity ==="

assert_contains "GitHub ci.yml contains prettier" "$GITHUB_CONTENT" "prettier"
assert_contains "GitLab .gitlab-ci.yml contains prettier" "$GITLAB_CONTENT" "prettier"
assert_contains "Jenkins Jenkinsfile contains prettier" "$JENKINS_CONTENT" "prettier"

# --- 13: GitHub release.yml contains version validation ---
echo ""
echo "=== Release/tag validation ==="

TOTAL=$((TOTAL + 1))
if echo "$RELEASE_CONTENT" | grep -qF "plugin.json" && echo "$RELEASE_CONTENT" | grep -qiE '(TAG_VERSION|GITHUB_REF_NAME|tag)'; then
  echo "PASS: GitHub release.yml contains version validation (tag vs plugin.json)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: GitHub release.yml missing version validation"
  FAILED=$((FAILED + 1))
fi

# --- 14: GitLab .gitlab-ci.yml contains release/tag validation ---
TOTAL=$((TOTAL + 1))
if echo "$GITLAB_CONTENT" | grep -qF "plugin.json" && echo "$GITLAB_CONTENT" | grep -qiE '(CI_COMMIT_TAG|TAG_VERSION|tag)'; then
  echo "PASS: GitLab .gitlab-ci.yml contains release/tag validation"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: GitLab .gitlab-ci.yml missing release/tag validation"
  FAILED=$((FAILED + 1))
fi

# --- 15: Jenkins Jenkinsfile contains release/tag validation ---
TOTAL=$((TOTAL + 1))
if echo "$JENKINS_CONTENT" | grep -qiE '(buildingTag|TAG_NAME)'; then
  echo "PASS: Jenkins Jenkinsfile contains release/tag validation (buildingTag or TAG_NAME)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: Jenkins Jenkinsfile missing release/tag validation (buildingTag or TAG_NAME)"
  FAILED=$((FAILED + 1))
fi

echo ""
echo "$PASSED of $TOTAL tests passed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
