#!/bin/bash
set -euo pipefail

# INFRA-017 + INFRA-024: policy.sh loader and validator tests.
# Exercises gates_policy_get, gates_policy_list, and gates_validate_policy
# against fixture policy files in a single mktemp_d workdir.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/runtime/lib/policy.sh"
# The shipped default policy is the extension's template (init seeds it into
# .specify/gates/policy.json). It must always pass the validator.
BUNDLED_POLICY="$REPO_ROOT/extension/templates/policy-template.json"

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

WORKDIR=""
trap '[[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'gates-policy')"

# shellcheck source=../runtime/lib/policy.sh
# shellcheck disable=SC1091
source "$LIB"

write_policy() {
    local name="$1" body="$2"
    local path="$WORKDIR/$name.json"
    printf '%s' "$body" >"$path"
    printf '%s\n' "$path"
}

# --- 1: bundled default policy validates ---
echo "=== bundled policy validates ==="

if gates_validate_policy "$BUNDLED_POLICY" >/dev/null 2>&1; then
    pass "bundled default policy passes validation"
else
    fail "bundled default policy failed validation"
    gates_validate_policy "$BUNDLED_POLICY" || true
fi

# --- 2: missing required fields ---
# INFRA-019 made orchestrator optional (defaults to "none" at the
# dispatcher) so the format-changed and post-edit hook stanzas, which are
# inline rather than orchestrator-dispatched, can omit it. severity is
# still required.
echo ""
echo "=== required fields enforced ==="

NO_ORCH="$(write_policy no-orch '{
  "hooks": { "verify-quality": { "severity": "error" } }
}')"
if gates_validate_policy "$NO_ORCH" >/dev/null 2>&1; then
    pass "missing orchestrator accepted (defaults to none)"
else
    fail "missing orchestrator should now be accepted"
fi

NO_SEV="$(write_policy no-sev '{
  "hooks": { "verify-quality": { "orchestrator": "none" } }
}')"
ERR_OUT="$(gates_validate_policy "$NO_SEV" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'missing required field "severity"'; then
    pass "missing severity detected"
else
    fail "missing severity not detected: $ERR_OUT"
fi

# --- 3: bogus enum values rejected ---
echo ""
echo "=== enum validation ==="

BOGUS_ORCH="$(write_policy bogus-orch '{
  "hooks": { "verify-quality": { "orchestrator": "bogus", "severity": "error" } }
}')"
ERR_OUT="$(gates_validate_policy "$BOGUS_ORCH" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'verify-quality: invalid orchestrator "bogus"'; then
    pass "bogus orchestrator rejected with hook name + value"
else
    fail "bogus orchestrator not rejected: $ERR_OUT"
fi

BOGUS_SEV="$(write_policy bogus-sev '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "loud" } }
}')"
ERR_OUT="$(gates_validate_policy "$BOGUS_SEV" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'invalid severity "loud"'; then
    pass "bogus severity rejected"
else
    fail "bogus severity not rejected: $ERR_OUT"
fi

# INFRA-025: on_missing_runner enum tightened to ["warn","skip"]
BOGUS_RUN="$(write_policy bogus-runner '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_runner": "bogus"
    }
  }
}')"
ERR_OUT="$(gates_validate_policy "$BOGUS_RUN" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'verify-quality: invalid on_missing_runner "bogus"'; then
    pass "INFRA-025: bogus on_missing_runner rejected with hook name + value"
else
    fail "INFRA-025: bogus on_missing_runner not rejected: $ERR_OUT"
fi

# "fail" is no longer accepted (INFRA-025 narrowed the enum)
FAIL_RUN="$(write_policy fail-runner '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_runner": "fail"
    }
  }
}')"
ERR_OUT="$(gates_validate_policy "$FAIL_RUN" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'verify-quality: invalid on_missing_runner "fail"'; then
    pass "INFRA-025: \"fail\" rejected (enum narrowed to warn|skip)"
else
    fail "INFRA-025: \"fail\" should be rejected: $ERR_OUT"
fi

WARN_RUN="$(write_policy warn-runner '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_runner": "warn"
    }
  }
}')"
if gates_validate_policy "$WARN_RUN" >/dev/null 2>&1; then
    pass "INFRA-025: on_missing_runner=\"warn\" accepted"
else
    fail "INFRA-025: on_missing_runner=\"warn\" rejected"
    gates_validate_policy "$WARN_RUN" || true
fi

SKIP_RUN="$(write_policy skip-runner '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_runner": "skip"
    }
  }
}')"
if gates_validate_policy "$SKIP_RUN" >/dev/null 2>&1; then
    pass "INFRA-025: on_missing_runner=\"skip\" accepted"
else
    fail "INFRA-025: on_missing_runner=\"skip\" rejected"
    gates_validate_policy "$SKIP_RUN" || true
fi

MISSING_RUN="$(write_policy missing-runner '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error"
    }
  }
}')"
if gates_validate_policy "$MISSING_RUN" >/dev/null 2>&1; then
    pass "INFRA-025: missing on_missing_runner accepted (default applies)"
else
    fail "INFRA-025: missing on_missing_runner should be accepted"
    gates_validate_policy "$MISSING_RUN" || true
fi

# INFRA-026: on_missing_tests enum is ["warn","skip"], default skip.
BOGUS_TESTS="$(write_policy bogus-tests '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_tests": "bogus"
    }
  }
}')"
ERR_OUT="$(gates_validate_policy "$BOGUS_TESTS" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'verify-quality: invalid on_missing_tests "bogus"'; then
    pass "INFRA-026: bogus on_missing_tests rejected with hook name + value"
else
    fail "INFRA-026: bogus on_missing_tests not rejected: $ERR_OUT"
fi

WARN_TESTS="$(write_policy warn-tests '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_tests": "warn"
    }
  }
}')"
if gates_validate_policy "$WARN_TESTS" >/dev/null 2>&1; then
    pass "INFRA-026: on_missing_tests=\"warn\" accepted"
else
    fail "INFRA-026: on_missing_tests=\"warn\" rejected"
    gates_validate_policy "$WARN_TESTS" || true
fi

SKIP_TESTS="$(write_policy skip-tests '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "on_missing_tests": "skip"
    }
  }
}')"
if gates_validate_policy "$SKIP_TESTS" >/dev/null 2>&1; then
    pass "INFRA-026: on_missing_tests=\"skip\" accepted"
else
    fail "INFRA-026: on_missing_tests=\"skip\" rejected"
    gates_validate_policy "$SKIP_TESTS" || true
fi

MISSING_TESTS="$(write_policy missing-tests '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error"
    }
  }
}')"
if gates_validate_policy "$MISSING_TESTS" >/dev/null 2>&1; then
    pass "INFRA-026: missing on_missing_tests accepted (default applies)"
else
    fail "INFRA-026: missing on_missing_tests should be accepted"
    gates_validate_policy "$MISSING_TESTS" || true
fi

# --- 4: INFRA-024 custom requires custom_command ---
echo ""
echo "=== INFRA-024: custom orchestrator requires custom_command ==="

CUSTOM_OK="$(write_policy custom-ok '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "custom",
      "severity": "error",
      "custom_command": "my-checker --fast"
    }
  }
}')"
if gates_validate_policy "$CUSTOM_OK" >/dev/null 2>&1; then
    pass "custom + custom_command accepted"
else
    fail "custom + custom_command rejected"
    gates_validate_policy "$CUSTOM_OK" || true
fi

CUSTOM_NO_CMD="$(write_policy custom-no-cmd '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "custom",
      "severity": "error"
    }
  }
}')"
ERR_OUT="$(gates_validate_policy "$CUSTOM_NO_CMD" 2>&1 || true)"
if echo "$ERR_OUT" \
    | grep -q 'verify-quality: orchestrator "custom" requires non-empty "custom_command"'; then
    pass "custom without custom_command rejected with hook name"
else
    fail "custom without custom_command not rejected: $ERR_OUT"
fi

CUSTOM_EMPTY="$(write_policy custom-empty '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "custom",
      "severity": "error",
      "custom_command": ""
    }
  }
}')"
ERR_OUT="$(gates_validate_policy "$CUSTOM_EMPTY" 2>&1 || true)"
if echo "$ERR_OUT" \
    | grep -q 'verify-quality: orchestrator "custom" requires non-empty "custom_command"'; then
    pass "custom with empty custom_command rejected"
else
    fail "custom with empty custom_command not rejected: $ERR_OUT"
fi

# Validator should accept custom_command on a non-custom hook (forward-compat)
NONE_WITH_CMD="$(write_policy none-with-cmd '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "custom_command": "ignored"
    }
  }
}')"
if gates_validate_policy "$NONE_WITH_CMD" >/dev/null 2>&1; then
    pass "non-custom hook with custom_command accepted"
else
    fail "non-custom hook with custom_command rejected"
fi

# --- 5: loader getters ---
echo ""
echo "=== loader getters ==="

LOADER_FIX="$(write_policy loader '{
  "hooks": {
    "verify-quality": {
      "orchestrator": "task",
      "severity": "warning"
    },
    "prettier": {
      "include": ["**/*.md", "**/*.json"],
      "orchestrator": "none",
      "severity": "error"
    }
  }
}')"
export GATES_POLICY_FILE="$LOADER_FIX"

GOT="$(gates_policy_get verify-quality orchestrator)"
if [[ "$GOT" == "task" ]]; then
    pass "gates_policy_get scalar"
else
    fail "gates_policy_get scalar returned: $GOT"
fi

GOT="$(gates_policy_get verify-quality severity)"
if [[ "$GOT" == "warning" ]]; then
    pass "gates_policy_get severity"
else
    fail "gates_policy_get severity returned: $GOT"
fi

LIST_OUT="$(gates_policy_list prettier include | tr '\n' ',' )"
if [[ "$LIST_OUT" == "**/*.md,**/*.json," ]]; then
    pass "gates_policy_list array"
else
    fail "gates_policy_list returned: $LIST_OUT"
fi

# Missing field returns empty
GOT="$(gates_policy_get verify-quality custom_command)"
if [[ -z "$GOT" ]]; then
    pass "gates_policy_get missing field returns empty"
else
    fail "gates_policy_get missing field returned: $GOT"
fi

# Missing hook returns empty
GOT="$(gates_policy_get nonexistent orchestrator)"
if [[ -z "$GOT" ]]; then
    pass "gates_policy_get missing hook returns empty"
else
    fail "gates_policy_get missing hook returned: $GOT"
fi

unset GATES_POLICY_FILE

# --- 5b: top-level protected_files and git sections ---
echo ""
echo "=== protected_files + git sections ==="

GOOD_SECTIONS="$(write_policy good-sections '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "protected_files": { "extra": ["docs/secret.md"] },
  "git": { "block_main_commits": false, "conventional_commits": true }
}')"
if gates_validate_policy "$GOOD_SECTIONS" >/dev/null 2>&1; then
    pass "valid protected_files + git accepted"
else
    fail "valid protected_files + git rejected"
    gates_validate_policy "$GOOD_SECTIONS" || true
fi

BAD_GIT_TYPE="$(write_policy bad-git-type '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "block_main_commits": "yes" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_GIT_TYPE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'git: block_main_commits must be a boolean'; then
    pass "non-boolean git toggle rejected"
else
    fail "non-boolean git toggle not rejected: $ERR_OUT"
fi

BAD_GIT_KEY="$(write_policy bad-git-key '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "bogus": true }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_GIT_KEY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'git: unknown field "bogus"'; then
    pass "unknown git field rejected"
else
    fail "unknown git field not rejected: $ERR_OUT"
fi

BAD_PF="$(write_policy bad-pf '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "protected_files": { "extra": "not-an-array" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_PF" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'protected_files.extra: must be an array'; then
    pass "protected_files.extra non-array rejected"
else
    fail "protected_files.extra non-array not rejected: $ERR_OUT"
fi

BAD_PF_KEY="$(write_policy bad-pf-key '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "protected_files": { "bogus": [] }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_PF_KEY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'protected_files: unknown field "bogus"'; then
    pass "protected_files unknown field rejected"
else
    fail "protected_files unknown field not rejected: $ERR_OUT"
fi

# --- 6: malformed JSON ---
echo ""
echo "=== malformed JSON rejected ==="

BAD_JSON="$(write_policy bad '{ not valid json')"
ERR_OUT="$(gates_validate_policy "$BAD_JSON" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'not valid JSON'; then
    pass "malformed JSON rejected"
else
    fail "malformed JSON not rejected: $ERR_OUT"
fi

# Top-level non-object rejected
BAD_SHAPE="$(write_policy bad-shape '[]')"
ERR_OUT="$(gates_validate_policy "$BAD_SHAPE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'must be an object'; then
    pass "non-object root rejected"
else
    fail "non-object root not rejected: $ERR_OUT"
fi

echo ""
echo "$PASSED of $TOTAL tests passed"
if [[ "$FAILED" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
