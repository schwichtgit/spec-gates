#!/bin/bash
set -euo pipefail

# INFRA-017 + INFRA-024: policy.sh loader and validator tests.
# Exercises gates_policy_get, gates_policy_list, and gates_validate_policy
# against fixture policy files in a single mktemp_d workdir.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/extension/runtime/lib/policy.sh"
# The shipped default policy is the extension's template (init seeds it into
# .specify/gates/policy.json). It must always pass the validator.
BUNDLED_POLICY="$REPO_ROOT/extension/runtime/policy-template.json"

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
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'gates-policy')"

# shellcheck source=../extension/runtime/lib/policy.sh
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

# 0.3.4 keys: protected_change_trailer + ai_branding (issues #47, #52).
NEW_GIT="$(write_policy new-git '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "protected_change_trailer": false,
           "ai_branding": { "terms": ["Gemini"], "allow_phrases": ["Acme Copilot"] } }
}')"
if gates_validate_policy "$NEW_GIT" >/dev/null 2>&1; then
    pass "git.protected_change_trailer + git.ai_branding accepted"
else
    fail "git.protected_change_trailer + git.ai_branding rejected"
    gates_validate_policy "$NEW_GIT" || true
fi

BAD_BRAND="$(write_policy bad-brand '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "protected_change_trailer": "yes",
           "ai_branding": { "terms": "Copilot", "allow_phrases": [""], "extra": [] } }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_BRAND" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'git: protected_change_trailer must be a boolean' \
    && echo "$ERR_OUT" | grep -q 'git: ai_branding.terms must be an array of strings' \
    && echo "$ERR_OUT" | grep -q 'git: ai_branding.allow_phrases entries must be non-empty strings' \
    && echo "$ERR_OUT" | grep -q 'git: ai_branding: unknown field "extra"'; then
    pass "malformed protected_change_trailer / ai_branding rejected"
else
    fail "malformed protected_change_trailer / ai_branding not rejected: $ERR_OUT"
fi

# 0.4.0 key: block_bulk_staging (issue #71).
BULK_OK="$(write_policy bulk-ok '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "block_bulk_staging": true }
}')"
if gates_validate_policy "$BULK_OK" >/dev/null 2>&1; then
    pass "git.block_bulk_staging accepted"
else
    fail "git.block_bulk_staging rejected"
fi
BULK_BAD="$(write_policy bulk-bad '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "git": { "block_bulk_staging": "yes" }
}')"
ERR_OUT="$(gates_validate_policy "$BULK_BAD" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'git: block_bulk_staging must be a boolean'; then
    pass "non-boolean git.block_bulk_staging rejected"
else
    fail "non-boolean git.block_bulk_staging not rejected: $ERR_OUT"
fi
if jq -e '.properties.git.properties.block_bulk_staging | .default == false and ."x-since" == "0.4.0"' \
    "$REPO_ROOT/extension/runtime/policy.schema.json" >/dev/null; then
    pass "schema documents block_bulk_staging (default false, x-since 0.4.0)"
else
    fail "schema entry for block_bulk_staging missing or wrong"
fi

# Nested accessor tells "absent" (defaults) from "present but empty".
if ! GATES_POLICY_FILE="$GOOD_SECTIONS" gates_policy_path_list git ai_branding terms >/dev/null \
    && [[ "$(GATES_POLICY_FILE="$NEW_GIT" gates_policy_path_list git ai_branding terms)" == "Gemini" ]] \
    && EMPTY_OUT="$(GATES_POLICY_FILE="$(write_policy empty-terms '{"hooks":{},"git":{"ai_branding":{"terms":[]}}}')" gates_policy_path_list git ai_branding terms)" \
    && [[ -z "$EMPTY_OUT" ]]; then
    pass "gates_policy_path_list: absent -> 1, list -> items, [] -> 0 with no output"
else
    fail "gates_policy_path_list absent/empty semantics wrong"
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

# --- 5c: attestation section (001) ---
echo ""
echo "=== attestation section ==="

GOOD_ATT="$(write_policy good-att '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "enabled": true, "max_records": 200, "parity": "error" }
}')"
if gates_validate_policy "$GOOD_ATT" >/dev/null 2>&1; then
    pass "valid attestation section accepted"
else
    fail "valid attestation section rejected"
    gates_validate_policy "$GOOD_ATT" || true
fi

NO_ATT="$(write_policy no-att '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }
}')"
if gates_validate_policy "$NO_ATT" >/dev/null 2>&1; then
    pass "absent attestation section accepted (defaults apply)"
else
    fail "absent attestation section rejected"
fi

PARTIAL_ATT="$(write_policy partial-att '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "parity": "warning" }
}')"
if gates_validate_policy "$PARTIAL_ATT" >/dev/null 2>&1; then
    pass "partial attestation section accepted (parity only)"
else
    fail "partial attestation section rejected"
    gates_validate_policy "$PARTIAL_ATT" || true
fi

BAD_ATT_ENABLED="$(write_policy bad-att-enabled '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "enabled": "yes" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_ENABLED" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: enabled must be a boolean'; then
    pass "non-boolean attestation.enabled rejected"
else
    fail "non-boolean attestation.enabled not rejected: $ERR_OUT"
fi

BAD_ATT_ZERO="$(write_policy bad-att-zero '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "max_records": 0 }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_ZERO" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: max_records must be an integer >= 1'; then
    pass "attestation.max_records=0 rejected"
else
    fail "attestation.max_records=0 not rejected: $ERR_OUT"
fi

BAD_ATT_FLOAT="$(write_policy bad-att-float '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "max_records": 2.5 }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_FLOAT" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: max_records must be an integer >= 1'; then
    pass "non-integer attestation.max_records rejected"
else
    fail "non-integer attestation.max_records not rejected: $ERR_OUT"
fi

BAD_ATT_STR="$(write_policy bad-att-str '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "max_records": "200" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_STR" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: max_records must be an integer >= 1'; then
    pass "string attestation.max_records rejected"
else
    fail "string attestation.max_records not rejected: $ERR_OUT"
fi

BAD_ATT_PARITY="$(write_policy bad-att-parity '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "parity": "loud" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_PARITY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: invalid parity "loud"'; then
    pass "bogus attestation.parity rejected with value"
else
    fail "bogus attestation.parity not rejected: $ERR_OUT"
fi

BAD_ATT_KEY="$(write_policy bad-att-key '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": { "bogus": true }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_KEY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: unknown field "bogus"'; then
    pass "unknown attestation field rejected"
else
    fail "unknown attestation field not rejected: $ERR_OUT"
fi

BAD_ATT_SHAPE="$(write_policy bad-att-shape '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "attestation": "on"
}')"
ERR_OUT="$(gates_validate_policy "$BAD_ATT_SHAPE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'attestation: must be an object'; then
    pass "non-object attestation section rejected"
else
    fail "non-object attestation section not rejected: $ERR_OUT"
fi

# --- 5d: spec section (002) ---
echo ""
echo "=== spec section ==="

GOOD_SPEC="$(write_policy good-spec '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": { "enabled": true, "severity": "error", "include": ["*"], "exclude": [], "timeout_s": 30 }
}')"
if gates_validate_policy "$GOOD_SPEC" >/dev/null 2>&1; then
    pass "valid spec section accepted"
else
    fail "valid spec section rejected"
    gates_validate_policy "$GOOD_SPEC" || true
fi

NO_SPEC="$(write_policy no-spec '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }
}')"
if gates_validate_policy "$NO_SPEC" >/dev/null 2>&1; then
    pass "absent spec section accepted (defaults apply)"
else
    fail "absent spec section rejected"
fi

BAD_SPEC_SEV="$(write_policy bad-spec-sev '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": { "severity": "info" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_SPEC_SEV" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'spec: invalid severity "info"'; then
    pass "bogus spec.severity rejected with value"
else
    fail "bogus spec.severity not rejected: $ERR_OUT"
fi

BAD_SPEC_TIMEOUT="$(write_policy bad-spec-timeout '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": { "timeout_s": "30" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_SPEC_TIMEOUT" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'spec: timeout_s must be an integer >= 1'; then
    pass "string spec.timeout_s rejected"
else
    fail "string spec.timeout_s not rejected: $ERR_OUT"
fi

BAD_SPEC_INCLUDE="$(write_policy bad-spec-include '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": { "include": "002-*" }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_SPEC_INCLUDE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'spec: include must be an array of strings'; then
    pass "non-array spec.include rejected"
else
    fail "non-array spec.include not rejected: $ERR_OUT"
fi

BAD_SPEC_KEY="$(write_policy bad-spec-key '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": { "boundaries": ["ci"] }
}')"
ERR_OUT="$(gates_validate_policy "$BAD_SPEC_KEY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'spec: unknown field "boundaries"'; then
    pass "unknown spec field rejected"
else
    fail "unknown spec field not rejected: $ERR_OUT"
fi

BAD_SPEC_SHAPE="$(write_policy bad-spec-shape '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "spec": "on"
}')"
ERR_OUT="$(gates_validate_policy "$BAD_SPEC_SHAPE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'spec: must be an object'; then
    pass "non-object spec section rejected"
else
    fail "non-object spec section not rejected: $ERR_OUT"
fi

# --- 5e: extends section (003) ---
echo ""
echo "=== extends section ==="

GOOD_EXT="$(write_policy good-ext '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "extends": { "source": "https://github.com/acme/policy-baseline", "version": "v1.0.0", "file": "policy.json" }
}')"
if gates_validate_policy "$GOOD_EXT" >/dev/null 2>&1; then
    pass "valid extends section accepted"
else
    fail "valid extends section rejected"
    gates_validate_policy "$GOOD_EXT" || true
fi

EXT_NO_VERSION="$(write_policy ext-no-version '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "extends": { "source": "/tmp/baseline" }
}')"
ERR_OUT="$(gates_validate_policy "$EXT_NO_VERSION" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'extends: version is required'; then
    pass "extends without version rejected"
else
    fail "extends without version not rejected: $ERR_OUT"
fi

EXT_EMPTY_SOURCE="$(write_policy ext-empty-source '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "extends": { "source": "", "version": "v1.0.0" }
}')"
ERR_OUT="$(gates_validate_policy "$EXT_EMPTY_SOURCE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'extends: source must be a non-empty string'; then
    pass "empty extends.source rejected"
else
    fail "empty extends.source not rejected: $ERR_OUT"
fi

EXT_BAD_KEY="$(write_policy ext-bad-key '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "extends": { "source": "/tmp/baseline", "version": "v1.0.0", "branch": "main" }
}')"
ERR_OUT="$(gates_validate_policy "$EXT_BAD_KEY" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'extends: unknown field "branch"'; then
    pass "unknown extends field rejected"
else
    fail "unknown extends field not rejected: $ERR_OUT"
fi

EXT_BAD_SHAPE="$(write_policy ext-bad-shape '{
  "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } },
  "extends": "https://github.com/acme/policy-baseline@v1"
}')"
ERR_OUT="$(gates_validate_policy "$EXT_BAD_SHAPE" 2>&1 || true)"
if echo "$ERR_OUT" | grep -q 'extends: must be an object'; then
    pass "non-object extends section rejected"
else
    fail "non-object extends section not rejected: $ERR_OUT"
fi

# --- 5f: effective-policy resolution (003) ---
echo ""
echo "=== effective-policy resolution ==="

RESDIR="$WORKDIR/resolve/.specify/gates"
mkdir -p "$RESDIR"
printf '%s' '{ "hooks": {}, "extends": { "source": "/tmp/b", "version": "v1" } }' >"$RESDIR/policy.json"
printf '%s' '{ "hooks": {} }' >"$RESDIR/policy.effective.json"
GOT="$(env -u GATES_POLICY_FILE CLAUDE_PROJECT_DIR="$WORKDIR/resolve" bash -c "source '$LIB'; gates_policy_file")"
if [[ "$GOT" == "$RESDIR/policy.effective.json" ]]; then
    pass "extends + effective present -> resolver picks the effective policy"
else
    fail "resolver picked $GOT (want effective)"
fi

rm "$RESDIR/policy.effective.json"
GOT="$(env -u GATES_POLICY_FILE CLAUDE_PROJECT_DIR="$WORKDIR/resolve" bash -c "source '$LIB'; gates_policy_file")"
if [[ "$GOT" == "$RESDIR/policy.json" ]]; then
    pass "extends without effective -> resolver falls back to the overlay"
else
    fail "resolver picked $GOT (want overlay)"
fi

printf '%s' '{ "hooks": {} }' >"$RESDIR/policy.json"
printf '%s' '{ "hooks": {} }' >"$RESDIR/policy.effective.json"
GOT="$(env -u GATES_POLICY_FILE CLAUDE_PROJECT_DIR="$WORKDIR/resolve" bash -c "source '$LIB'; gates_policy_file")"
if [[ "$GOT" == "$RESDIR/policy.json" ]]; then
    pass "no extends -> resolver ignores a stray effective file"
else
    fail "resolver picked $GOT (want overlay; dormant repo)"
fi

printf '%s' '{ "hooks": {}, "extends": { "source": "/tmp/b", "version": "v1" } }' >"$RESDIR/policy.json"
GOT="$(GATES_POLICY_FILE="$WORKDIR/override.json" CLAUDE_PROJECT_DIR="$WORKDIR/resolve" bash -c "source '$LIB'; gates_policy_file")"
if [[ "$GOT" == "$WORKDIR/override.json" ]]; then
    pass "GATES_POLICY_FILE override still wins over contract resolution"
else
    fail "resolver picked $GOT (want the env override)"
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

# --- 7: schema rules the validator used to miss (#124) ---
# verify.sh now refuses whatever this rejects, so a validator that passes a
# schema-invalid policy is a gate that silently drops checks.
echo ""
echo "=== schema-invalid shapes rejected ==="

# <name> <policy-json> <rc> <needle>
rejects() {
    local f out rc=0
    f="$(write_policy "$1" "$2")"
    out="$(gates_validate_policy "$f" 2>&1)" || rc=$?
    if [[ "$rc" == "$3" ]] && grep -qF -- "$4" <<<"$out"; then
        pass "$1 rejected (rc $3)"
    else
        fail "$1: rc $rc, output: $out"
    fi
}
rejects empty-file '' 4 'top-level "hooks" object'
rejects two-documents '{"hooks":{}} {"hooks":5}' 4 'top-level "hooks" object'
rejects hook-string '{ "hooks": { "prettier": "on" } }' 5 'prettier: must be an object'
rejects hook-include-string '{ "hooks": { "prettier": { "severity": "error", "include": "*.md" } } }' 5 'prettier: include must be an array of strings'
rejects hook-exclude-number '{ "hooks": { "prettier": { "severity": "error", "exclude": [1] } } }' 5 'prettier: exclude entries must be strings'
rejects top-level-typo '{ "hooks": {}, "attestaton": { "enabled": false } }' 5 'unknown top-level field "attestaton"'
rejects timeout-negative '{ "hooks": {}, "spec": { "timeout_s": -1 } }' 5 'spec: timeout_s must be an integer >= 1'
rejects max-records-negative '{ "hooks": {}, "attestation": { "max_records": -1 } }' 5 'attestation: max_records must be an integer >= 1'
# A snapshot_exclude pattern of only *, ? and / exempts every untracked and
# ignored path from the accept-block read-only check (#199).
sxn=0
for sx in '*' '**' '**/*' '*/' '?*'; do
    sxn=$((sxn + 1))
    rejects "snapshot-exclude-wild-$sxn" "{ \"hooks\": {}, \"spec\": { \"snapshot_exclude\": [\"cache/\", \"$sx\"] } }" 5 \
        "spec: snapshot_exclude: \"$sx\" matches every path"
done
SX_OK="$(write_policy sx-ok '{ "hooks": {}, "spec": { "snapshot_exclude": ["cache/", "*.log", "**/tmp/**", ""] } }')"
if gates_validate_policy "$SX_OK" >/dev/null 2>&1; then
    pass "snapshot_exclude patterns naming a path are accepted"
else
    fail "snapshot_exclude patterns naming a path rejected"
fi
# The schema refuses the same patterns.
SX_SCHEMA="$(jq -r '.properties.spec.properties.snapshot_exclude.items.not.pattern' "$REPO_ROOT/extension/runtime/policy.schema.json")"
if [[ "$SX_SCHEMA" == '^[*/?]+$' ]]; then
    pass "schema refuses wildcard-only snapshot_exclude patterns"
else
    fail "schema snapshot_exclude items pattern: $SX_SCHEMA"
fi

# shellcheck disable=SC2016  # a literal "$schema" key
GOOD_TOP="$(write_policy good-top '{ "_comment": "x", "$schema": "./policy.schema.json", "hooks": {} }')"
if gates_validate_policy "$GOOD_TOP" >/dev/null 2>&1; then
    pass "_comment and \$schema accepted at the top level"
else
    fail "_comment or \$schema rejected"
fi

# The top-level keys the validator allows are exactly the schema's.
SCHEMA_TOP="$(jq -r '.properties | keys | join(",")' "$REPO_ROOT/extension/runtime/policy.schema.json")"
VALIDATOR_TOP="$(sed -n 's/^ *def top_keys: \[\(.*\)\];$/\1/p' "$REPO_ROOT/extension/runtime/lib/policy.sh" \
    | jq -rR 'split(", ") | map(fromjson) | sort | join(",")')"
if [[ -n "$SCHEMA_TOP" && "$SCHEMA_TOP" == "$VALIDATOR_TOP" ]]; then
    pass "validator top-level keys match the schema"
else
    fail "top-level keys differ: schema [$SCHEMA_TOP] validator [$VALIDATOR_TOP]"
fi

# --- project gates (feature 006): hooks.verify-quality.gates ---
echo ""
echo "=== project gate keys ==="
accepts() { # <name> <policy-json>
    local f out rc=0
    f="$(write_policy "$1" "$2")"
    out="$(gates_validate_policy "$f" 2>&1)" || rc=$?
    if [[ "$rc" == 0 ]]; then
        pass "$1 accepted"
    else
        fail "$1: rc $rc, output: $out"
    fi
}
# vq <verify-quality members>: a policy around them.
vq() { printf '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error", %s } } }' "$1"; }

accepts pg-full "$(vq '"gate_timeout_s": 900, "test_severity": "error", "gates": {
    "lint": { "command": "npm run -s lint" },
    "unit_test-2": { "command": "npm test", "severity": "warning", "timeout_s": 86400 },
    "build": { "command": "make", "severity": "info", "timeout_s": 1, "skip_at": ["agent", "git"] },
    "dropped": null } ')"
accepts pg-empty-gates "$(vq '"gates": {}')"
rejects pg-name-upper "$(vq '"gates": { "Lint": { "command": "x" } }')" 5 \
    'verify-quality.gates.Lint: invalid gate name'
rejects pg-name-leading-dash "$(vq '"gates": { "-lint": { "command": "x" } }')" 5 \
    'verify-quality.gates.-lint: invalid gate name'
rejects pg-name-41 "$(vq '"gates": { "a1234567890123456789012345678901234567890": { "command": "x" } }')" 5 \
    'invalid gate name'
accepts pg-name-40 "$(vq '"gates": { "a123456789012345678901234567890123456789": { "command": "x" } }')"
for reserved in prettier markdownlint shellcheck task-lint task-test custom spec contract parity policy lock constitution; do
    rejects "pg-reserved-$reserved" "$(vq "\"gates\": { \"$reserved\": { \"command\": \"x\" } }")" 5 \
        "verify-quality.gates.$reserved: \"$reserved\" is a reserved gate name"
done
rejects pg-no-command "$(vq '"gates": { "lint": { "severity": "error" } }')" 5 \
    'verify-quality.gates.lint: missing required field "command"'
rejects pg-empty-command "$(vq '"gates": { "lint": { "command": "" } }')" 5 \
    'verify-quality.gates.lint.command: must be a non-empty string'
rejects pg-command-array "$(vq '"gates": { "lint": { "command": ["npm"] } }')" 5 \
    'verify-quality.gates.lint.command: must be a non-empty string'
rejects pg-unknown-key "$(vq '"gates": { "lint": { "command": "x", "boundaries": ["ci"] } }')" 5 \
    'verify-quality.gates.lint: unknown field "boundaries"'
rejects pg-gate-string "$(vq '"gates": { "lint": "npm run lint" }')" 5 \
    'verify-quality.gates.lint: must be an object'
rejects pg-gates-array "$(vq '"gates": [ { "command": "x" } ]')" 5 \
    'verify-quality.gates: must be an object keyed by gate name'
rejects pg-severity "$(vq '"gates": { "lint": { "command": "x", "severity": "fatal" } }')" 5 \
    'verify-quality.gates.lint.severity: invalid value "fatal"'
rejects pg-timeout-zero "$(vq '"gates": { "lint": { "command": "x", "timeout_s": 0 } }')" 5 \
    'verify-quality.gates.lint.timeout_s: must be an integer from 1 to 86400'
rejects pg-timeout-big "$(vq '"gates": { "lint": { "command": "x", "timeout_s": 86401 } }')" 5 \
    'verify-quality.gates.lint.timeout_s: must be an integer from 1 to 86400'
rejects pg-timeout-frac "$(vq '"gates": { "lint": { "command": "x", "timeout_s": 1.5 } }')" 5 \
    'verify-quality.gates.lint.timeout_s: must be an integer'
rejects pg-timeout-string "$(vq '"gates": { "lint": { "command": "x", "timeout_s": "60" } }')" 5 \
    'verify-quality.gates.lint.timeout_s: must be an integer'
rejects pg-gate-timeout-zero "$(vq '"gate_timeout_s": 0')" 5 \
    'verify-quality.gate_timeout_s: must be an integer from 1 to 86400'
rejects pg-gate-timeout-big "$(vq '"gate_timeout_s": 86401')" 5 \
    'verify-quality.gate_timeout_s: must be an integer from 1 to 86400'
accepts pg-gate-timeout-edges "$(vq '"gate_timeout_s": 86400')"
rejects pg-test-severity "$(vq '"test_severity": "fatal"')" 5 \
    'verify-quality.test_severity: invalid value "fatal"'
rejects pg-skip-ci "$(vq '"gates": { "build": { "command": "x", "skip_at": ["ci"] } }')" 5 \
    'verify-quality.gates.build.skip_at: "ci" is refused: CI runs the full policy (constitution, Principle III)'
rejects pg-skip-ci-mixed "$(vq '"gates": { "build": { "command": "x", "skip_at": ["agent", "ci"] } }')" 5 \
    'Principle III'
rejects pg-skip-empty "$(vq '"gates": { "build": { "command": "x", "skip_at": [] } }')" 5 \
    'verify-quality.gates.build.skip_at: must not be empty'
rejects pg-skip-dup "$(vq '"gates": { "build": { "command": "x", "skip_at": ["git", "git"] } }')" 5 \
    'verify-quality.gates.build.skip_at: duplicate entries'
rejects pg-skip-unknown "$(vq '"gates": { "build": { "command": "x", "skip_at": ["precommit"] } }')" 5 \
    'verify-quality.gates.build.skip_at: invalid boundary "precommit" (allowed: agent, git)'
rejects pg-skip-string "$(vq '"gates": { "build": { "command": "x", "skip_at": "agent" } }')" 5 \
    'verify-quality.gates.build.skip_at: must be an array'
for key in gates gate_timeout_s test_severity; do
    case "$key" in
        gates) val='{ "lint": { "command": "x" } }' ;;
        gate_timeout_s) val=600 ;;
        test_severity) val='"error"' ;;
    esac
    rejects "pg-$key-under-prettier" \
        "{ \"hooks\": { \"prettier\": { \"severity\": \"error\", \"$key\": $val } } }" 5 \
        "prettier: \"$key\" is allowed only under verify-quality"
done
# A policy without the new keys validates exactly as before.
accepts pg-none "$(vq '"custom_command": "true"')"

# The schema documents what the validator enforces.
SCHEMA="$REPO_ROOT/extension/runtime/policy.schema.json"
if [[ "$(jq -r '."$defs".projectGate.properties | keys | join(",")' "$SCHEMA")" \
    == "$(sed -n 's/^ *def gate_keys: \[\(.*\)\];$/\1/p' "$LIB" | jq -rR 'split(", ") | map(fromjson) | sort | join(",")')" ]]; then
    pass "schema project gate keys match the validator"
else
    fail "schema and validator project gate keys differ"
fi
if [[ "$(jq -r '."$defs".hook.properties.gates.propertyNames.not.enum | sort | join(",")' "$SCHEMA")" \
    == "$(sed -n '/def reserved_gates:/,/];/p' "$LIB" | tr -d '\n' \
        | sed 's/.*def reserved_gates: \(\[.*\]\);.*/\1/' | jq -r 'sort | join(",")')" ]]; then
    pass "schema reserves the built-in gate names"
else
    fail "schema reserved gate names differ"
fi
if jq -e '(."$defs".projectGate.properties.skip_at | .minItems == 1 and .uniqueItems == true and .items.enum == ["agent", "git"] and (.description | test("Principle III")))
    and (.properties.hooks.additionalProperties.properties | .gates == false and .gate_timeout_s == false and .test_severity == false)
    and (."$defs".hook.properties.gate_timeout_s | .minimum == 1 and .maximum == 86400 and .default == 600)
    and (."$defs".hook.properties.test_severity | .enum == ["error", "warning", "info"] and .default == "warning")' \
    "$SCHEMA" >/dev/null; then
    pass "schema: skip_at, gate_timeout_s, test_severity and the verify-quality-only rule"
else
    fail "schema entries for the project gate keys missing or wrong"
fi

# verify.sh refuses an invalid gate key before any gate runs (exit 1).
# shellcheck source=lib/fixture.sh disable=SC1091
source "$REPO_ROOT/tests/lib/fixture.sh"
PGD="$(fx_gates_project "$(vq '"gates": { "build": { "command": "touch ran", "skip_at": ["ci"] } }')")"
PG_RC=0
PG_OUT="$(CLAUDE_PROJECT_DIR="$PGD" bash "$PGD/.specify/gates/verify.sh" --boundary git 2>&1)" || PG_RC=$?
if [[ "$PG_RC" == 1 && ! -e "$PGD/ran" ]] && grep -q 'Principle III' <<<"$PG_OUT" \
    && ! grep -q '^gates: boundary=' <<<"$PG_OUT"; then
    pass "verify.sh refuses skip_at ci with exit 1 and runs no gate"
else
    fail "verify.sh on skip_at ci: rc $PG_RC, output: $PG_OUT"
fi
fx_cleanup "$PGD"

# --- accessors and the boundary-skip decision (feature 006) ---
echo ""
echo "=== project gate accessors ==="
PGA="$(write_policy pg-acc "$(vq '"gates": { "zeta": { "command": "echo z", "timeout_s": 5, "skip_at": ["agent"] }, "alpha": { "command": "echo a" }, "gone": null }')")"
if [[ "$(GATES_POLICY_FILE="$PGA" gates_project_gate_names | paste -sd , -)" == "zeta,alpha" ]]; then
    pass "gates_project_gate_names: key order, null gates left out"
else
    fail "gates_project_gate_names: $(GATES_POLICY_FILE="$PGA" gates_project_gate_names | paste -sd , -)"
fi
if [[ "$(GATES_POLICY_FILE="$PGA" gates_project_gate_get zeta command)|$(GATES_POLICY_FILE="$PGA" gates_project_gate_get zeta timeout_s)|$(GATES_POLICY_FILE="$PGA" gates_project_gate_get alpha severity)|$(GATES_POLICY_FILE="$PGA" gates_project_gate_get nope command)" == "echo z|5||" ]]; then
    pass "gates_project_gate_get: scalars, empty when missing"
else
    fail "gates_project_gate_get wrong"
fi
if [[ "$(GATES_POLICY_FILE="$PGA" gates_project_gate_skip_at zeta)|$(GATES_POLICY_FILE="$PGA" gates_project_gate_skip_at alpha)" == '["agent"]|' ]]; then
    pass "gates_project_gate_skip_at: compact array, empty when absent"
else
    fail "gates_project_gate_skip_at wrong"
fi
while IFS='|' read -r want boundary list; do
    [[ -n "$want" ]] || continue
    got="$(gates_declared_skip "$boundary" "$list")" && rc=0 || rc=$?
    if [[ "$rc:$got" == "$want" ]]; then
        pass "gates_declared_skip $boundary $list -> $want"
    else
        fail "gates_declared_skip $boundary $list: got $rc:$got, want $want"
    fi
done <<'EOF'
0:skipped by declaration at agent|agent|["agent"]
0:skipped by declaration at git|git|["agent","git"]
1:|git|["agent"]
1:|agent|["git"]
1:|ci|["ci"]
1:|ci|["agent","git","ci"]
1:|none|["agent","git"]
1:|unspecified|["agent"]
1:|agent|
1:|agent|"agent"
EOF

# --- the covering script (feature 007): spec.cover ---
echo ""
echo "=== spec.cover keys ==="
# sc <cover-json>: a policy whose spec section declares it.
sc() { printf '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "severity": "error", "cover": %s } }' "$1"; }
accepts cover-full "$(sc '{ "script": "scripts/accept-covered.sh", "at": ["agent", "git"], "timeout_s": 30 }')"
accepts cover-min "$(sc '{ "script": "cover.sh", "at": ["git"] }')"
accepts cover-timeout-edges "$(sc '{ "script": "a/b.sh", "at": ["agent"], "timeout_s": 300 }')"
accepts cover-timeout-one "$(sc '{ "script": "./a..b/c.sh", "at": ["agent"], "timeout_s": 1 }')"
rejects cover-string "$(sc '"scripts/cover.sh"')" 5 'spec.cover: must be an object'
rejects cover-no-script "$(sc '{ "at": ["git"] }')" 5 'spec.cover.script: missing required field'
rejects cover-empty-script "$(sc '{ "script": "", "at": ["git"] }')" 5 'spec.cover.script: must be a non-empty string'
rejects cover-script-number "$(sc '{ "script": 7, "at": ["git"] }')" 5 'spec.cover.script: must be a non-empty string'
rejects cover-script-abs "$(sc '{ "script": "/usr/bin/true", "at": ["git"] }')" 5 'spec.cover.script: must be a project-relative path, not absolute'
rejects cover-script-dotdot "$(sc '{ "script": "scripts/../../x.sh", "at": ["git"] }')" 5 'spec.cover.script: must not contain a .. segment'
rejects cover-script-dotdot-lead "$(sc '{ "script": "../x.sh", "at": ["git"] }')" 5 'spec.cover.script: must not contain a .. segment'
rejects cover-no-at "$(sc '{ "script": "c.sh" }')" 5 'spec.cover.at: missing required field'
rejects cover-at-empty "$(sc '{ "script": "c.sh", "at": [] }')" 5 'spec.cover.at: must not be empty'
rejects cover-at-string "$(sc '{ "script": "c.sh", "at": "git" }')" 5 'spec.cover.at: must be an array of boundaries'
rejects cover-at-ci "$(sc '{ "script": "c.sh", "at": ["ci"] }')" 5 \
    'spec.cover.at: "ci" is refused: CI runs the full policy (constitution, Principle III)'
rejects cover-at-ci-mixed "$(sc '{ "script": "c.sh", "at": ["git", "ci"] }')" 5 'Principle III'
rejects cover-at-unknown "$(sc '{ "script": "c.sh", "at": ["precommit"] }')" 5 \
    'spec.cover.at: invalid boundary "precommit" (allowed: agent, git)'
rejects cover-at-dup "$(sc '{ "script": "c.sh", "at": ["git", "git"] }')" 5 'spec.cover.at: duplicate entries'
rejects cover-timeout-zero "$(sc '{ "script": "c.sh", "at": ["git"], "timeout_s": 0 }')" 5 \
    'spec.cover.timeout_s: must be an integer from 1 to 300'
rejects cover-timeout-big "$(sc '{ "script": "c.sh", "at": ["git"], "timeout_s": 301 }')" 5 \
    'spec.cover.timeout_s: must be an integer from 1 to 300'
rejects cover-timeout-frac "$(sc '{ "script": "c.sh", "at": ["git"], "timeout_s": 2.5 }')" 5 \
    'spec.cover.timeout_s: must be an integer from 1 to 300'
rejects cover-timeout-string "$(sc '{ "script": "c.sh", "at": ["git"], "timeout_s": "30" }')" 5 \
    'spec.cover.timeout_s: must be an integer from 1 to 300'
rejects cover-unknown "$(sc '{ "script": "c.sh", "at": ["git"], "command": "true" }')" 5 \
    'spec.cover.command: unknown field'
# Without spec.cover a policy validates as before.
accepts cover-none '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error" } }, "spec": { "severity": "error", "timeout_s": 5 } }'
if jq -e '.properties.spec.properties.cover
    | .additionalProperties == false and .required == ["script", "at"]
      and .properties.script.minLength == 1
      and (.properties.at | .minItems == 1 and .uniqueItems == true and .items.enum == ["agent", "git"])
      and (.properties.timeout_s | .minimum == 1 and .maximum == 300 and .default == 30)
      and (.description | test("Principle III") and test("protected"))' \
    "$SCHEMA" >/dev/null; then
    pass "schema: spec.cover keys, never ci, protected"
else
    fail "schema entry for spec.cover missing or wrong"
fi
CVA="$(write_policy cover-acc "$(sc '{ "script": "scripts/c.sh", "at": ["agent", "git"], "timeout_s": 7 }')")"
CVB="$(write_policy cover-acc-min "$(sc '{ "script": "c.sh", "at": ["git"] }')")"
CVN="$(write_policy cover-acc-none '{ "hooks": {} }')"
got="$(GATES_POLICY_FILE="$CVA" gates_cover_script)|$(GATES_POLICY_FILE="$CVA" gates_cover_at)|$(GATES_POLICY_FILE="$CVA" gates_cover_timeout)"
got="$got;$(GATES_POLICY_FILE="$CVB" gates_cover_timeout)"
got="$got;$(GATES_POLICY_FILE="$CVN" gates_cover_script)|$(GATES_POLICY_FILE="$CVN" gates_cover_at)|$(GATES_POLICY_FILE="$CVN" gates_cover_timeout)"
if [[ "$got" == 'scripts/c.sh|["agent","git"]|7;30;||30' ]]; then
    pass "gates_cover_script, gates_cover_at, gates_cover_timeout (default 30, empty when none)"
else
    fail "cover accessors: $got"
fi
CVD="$(fx_gates_project "$(sc '{ "script": "c.sh", "at": ["ci"] }')")"
printf '#!/bin/sh\necho covered\n' >"$CVD/c.sh"
chmod +x "$CVD/c.sh"
CV_RC=0
CV_OUT="$(CLAUDE_PROJECT_DIR="$CVD" bash "$CVD/.specify/gates/verify.sh" --boundary git 2>&1)" || CV_RC=$?
if [[ "$CV_RC" == 1 ]] && grep -q 'spec.cover.at: "ci" is refused' <<<"$CV_OUT" \
    && ! grep -q '^gates: boundary=' <<<"$CV_OUT"; then
    pass "verify.sh refuses spec.cover.at ci with exit 1 and runs no gate"
else
    fail "verify.sh on spec.cover.at ci: rc $CV_RC, output: $CV_OUT"
fi
fx_cleanup "$CVD"

# --- glob matcher: a pattern after a leading **/ (#220) ---
echo ""
echo "=== gates_glob_match: **/ prefix ==="
while IFS='|' read -r want path glob; do
    [[ -n "$want" ]] || continue
    got=no
    gates_glob_match "$path" "$glob" && got=yes
    if [[ "$got" == "$want" ]]; then
        pass "glob $glob vs $path -> $want"
    else
        fail "glob $glob vs $path: got $got, want $want"
    fi
done <<'EOF'
yes|README.md|**/*.md
yes|docs/a/b.md|**/*.md
yes|.claude/mind.mv2|**/.claude/mind.*
yes|x/.claude/mind.mv2|**/.claude/mind.*
yes|secrets/k.json|**/secrets/*.json
yes|.env|**/.env
no|README.txt|**/*.md
no|claude/mind.mv2|**/.claude/mind.*
no|xsecrets/k.json|**/secrets/*.json
EOF

echo ""
echo "$PASSED of $TOTAL tests passed"
if [[ "$FAILED" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
