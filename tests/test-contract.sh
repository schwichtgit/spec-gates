#!/bin/bash
set -euo pipefail

# Policy-contract tests (feature 003): sync, drift proving, deviations,
# reviewable updates, propose.
#
# Regression guards for the spec's success criteria:
#   SC-001 -- one declaration + one sync adopts a baseline, enforced after;
#   SC-002 -- hand-editing any contract artifact blocks the next run naming it;
#   SC-003 -- a baseline version bump only lands through a reviewable change;
#   SC-005 -- propose yields a complete change request;
#   SC-006 -- repos without extends are untouched.
# All fixtures use local plain-path git remotes -- no network anywhere.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-contract-test)"
trap '[[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT

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

expect_contains() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if printf '%s' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 (output does not contain: $3)"
        FAIL=$((FAIL + 1))
    fi
}

# Fixture baseline repo: git init + policy.json + tag. Re-invoke with a new
# tag (and optionally new content) to publish another version.
mkbaseline() { # <dir> <tag> <policy-json>
    local dir="$1" tag="$2" policy="$3"
    if [[ ! -d "$dir/.git" ]]; then
        git init -q "$dir"
        git -C "$dir" checkout -q -b main 2>/dev/null || true
    fi
    printf '%s' "$policy" | jq -S . >"$dir/policy.json"
    git -C "$dir" add -A
    git -C "$dir" -c user.email=b@test -c user.name=baseline commit -qm "baseline $tag" --allow-empty
    git -C "$dir" tag "$tag"
}

# Project the runtime into a consumer fixture with the given overlay policy.
project() { # <dir> <overlay-json>
    local dir="$1" overlay="$2"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" "$REPO_ROOT/extension/runtime/doctor.sh" \
        "$REPO_ROOT/extension/runtime/contract.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$overlay" >"$dir/.specify/gates/policy.json"
}

contract() { # <dir> <subcommand-args...>: stdout+stderr, exit appended
    local dir="$1"
    shift
    local rc=0 out
    out="$(CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/contract.sh" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

gate() { # <dir>: verify exit code (spec-gate sentinel cleared for dogfood)
    local dir="$1" rc=0
    CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC \
        bash "$dir/.specify/gates/verify.sh" --boundary ci >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

gate_out() { # <dir>: stdout+stderr + exit line
    local dir="$1" rc=0 out
    out="$(CLAUDE_PROJECT_DIR="$dir" env -u GATES_SPEC_EXEC \
        bash "$dir/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

gate_json() { # <dir>
    CLAUDE_PROJECT_DIR="$1" env -u GATES_SPEC_EXEC \
        bash "$1/.specify/gates/verify.sh" --boundary ci --json 2>/dev/null || true
}

artifact_count() { # <dir>: how many of the three contract artifacts exist
    local n=0 f
    for f in baseline.json baseline.lock.json policy.effective.json; do
        [[ -f "$1/.specify/gates/$f" ]] && n=$((n + 1))
    done
    echo "$n"
}

BASE_POLICY='{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"},"shellcheck":{"include":["**/*.sh","scripts/**"],"exclude":["vendor/**"],"orchestrator":"none","severity":"error"}},"spec":{"enabled":true,"severity":"error"},"attestation":{"parity":"error"}}'

overlay_for() { # <baseline-dir> <extra-jq-filter>
    printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' \
        | jq -c --arg src "$1" '. + {extends: {source: $src, version: "v1.0.0"}}' \
        | jq -c "$2"
}

# --- US1: sync adopts a baseline, provably (SC-001) ---
echo "=== sync: adopt + materialize ==="

B="$WORKDIR/base"
mkbaseline "$B" v1.0.0 "$BASE_POLICY"
D="$WORKDIR/adopt"
project "$D" "$(overlay_for "$B" '.')"
OUT="$(contract "$D" sync)"
expect_contains "sync succeeds" "$OUT" "EXIT=0"
expect_contains "sync names source@version" "$OUT" "@v1.0.0"
expect "three artifacts written" "$(artifact_count "$D")" 3
expect "snapshot is jq -S canonical" \
    "$(diff <(jq -S . "$D/.specify/gates/baseline.json") "$D/.specify/gates/baseline.json" >/dev/null && echo yes)" yes
expect "effective is jq -S canonical" \
    "$(diff <(jq -S . "$D/.specify/gates/policy.effective.json") "$D/.specify/gates/policy.effective.json" >/dev/null && echo yes)" yes
expect "lock digest matches the snapshot" \
    "$(jq -r '.digest' "$D/.specify/gates/baseline.lock.json")" \
    "sha256:$(shasum -a 256 "$D/.specify/gates/baseline.json" 2>/dev/null | cut -d' ' -f1 || sha256sum "$D/.specify/gates/baseline.json" | cut -d' ' -f1)"
expect "effective carries the baseline rule the overlay lacks" \
    "$(jq -r '.hooks.shellcheck.severity' "$D/.specify/gates/policy.effective.json")" "error"
expect "effective re-attaches extends verbatim" \
    "$(jq -r '.extends.version' "$D/.specify/gates/policy.effective.json")" "v1.0.0"
expect "synced repo gate passes" "$(gate "$D")" 0
expect "gate reports the contract entry" \
    "$(gate_json "$D" | jq -r '[.gates[] | select(.name == "contract")] | length')" 1

# The enforced policy is the effective one: shellcheck (baseline-only rule)
# must appear as a gate on a repo whose overlay never mentions it.
expect "baseline-enabled tool gate runs in the consumer" \
    "$(gate_json "$D" | jq -r '[.gates[] | select(.name == "shellcheck")] | length')" 1

# --- offline: verify needs no source access after sync ---
echo ""
echo "=== offline verify (FR-005) ==="
MOVED="$WORKDIR/base-moved"
mv "$B" "$MOVED"
expect "verify green with the baseline source gone" "$(gate "$D")" 0
mv "$MOVED" "$B"

# --- SC-002: every hand-tampered artifact blocks, named ---
echo ""
echo "=== drift: the four invariants block ==="

printf ' ' >>"$D/.specify/gates/policy.effective.json"
OUT="$(gate_out "$D")"
expect_contains "tampered effective blocks" "$OUT" "EXIT=2"
expect_contains "tampered effective named" "$OUT" "effective policy drifted"
CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/contract.sh" sync >/dev/null

printf '{}' >"$D/.specify/gates/baseline.json"
OUT="$(gate_out "$D")"
expect_contains "tampered snapshot blocks" "$OUT" "EXIT=2"
expect_contains "tampered snapshot named" "$OUT" "does not match the pin"
CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/contract.sh" sync >/dev/null

jq '.extends.version = "v2.0.0"' "$D/.specify/gates/policy.json" >"$D/p.tmp" && mv "$D/p.tmp" "$D/.specify/gates/policy.json"
OUT="$(gate_out "$D")"
expect_contains "edited declaration blocks" "$OUT" "EXIT=2"
expect_contains "edited declaration named precisely" "$OUT" "declaration changed since the last sync"
jq '.extends.version = "v1.0.0"' "$D/.specify/gates/policy.json" >"$D/p.tmp" && mv "$D/p.tmp" "$D/.specify/gates/policy.json"

rm "$D/.specify/gates/baseline.lock.json"
OUT="$(gate_out "$D")"
expect_contains "missing lock blocks" "$OUT" "EXIT=2"
expect_contains "missing lock named" "$OUT" "not synced (baseline.lock.json missing)"
CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/contract.sh" sync >/dev/null
expect "repo recovers after re-sync" "$(gate "$D")" 0

# --- deviations: classified, informational, attested (FR-006) ---
echo ""
echo "=== deviations: classification + informational ==="

DV="$WORKDIR/deviate"
project "$DV" "$(overlay_for "$B" '.hooks.shellcheck = {"include":["**/*.sh"],"exclude":["vendor/**","third_party/**"],"orchestrator":"none","severity":"warning"} | .hooks.markdownlint = {"include":["**/*.md"],"orchestrator":"none","severity":"error"} | .hooks."verify-quality" = {"orchestrator":"custom","custom_command":"true","severity":"error"} | .spec = {"enabled": false} | .attestation = {"parity": "warning"}')"
OUT="$(contract "$DV" sync)"
expect_contains "deviating sync still exits 0" "$OUT" "EXIT=0"
expect_contains "severity drop classified weakened" "$OUT" 'deviation (weakened): hooks.shellcheck.severity'
expect_contains "section enabled true->false classified weakened" "$OUT" 'deviation (weakened): spec.enabled'
expect_contains "parity severity drop classified weakened" "$OUT" 'deviation (weakened): attestation.parity'
expect_contains "narrowed include classified weakened" "$OUT" 'deviation (weakened): hooks.shellcheck.include'
expect_contains "widened exclude classified weakened" "$OUT" 'deviation (weakened): hooks.shellcheck.exclude'
expect_contains "orchestrator switch classified changed" "$OUT" 'deviation (changed): hooks.verify-quality.orchestrator'
OUT="$(gate_out "$DV")"
expect_contains "deviations never change the exit code" "$OUT" "EXIT=0"
expect_contains "gate output names the deviation" "$OUT" 'deviation (weakened): hooks.shellcheck.severity'
J="$(gate_json "$DV")"
expect "attestation counts weakened deviations" \
    "$(printf '%s' "$J" | jq -r '.attestation.contract.deviations.weakened')" 5
expect "attestation counts changed deviations (added hook is not one)" \
    "$(printf '%s' "$J" | jq -r '.attestation.contract.deviations.changed')" 1

DSTRONG="$WORKDIR/strengthen"
project "$DSTRONG" "$(overlay_for "$B" '.hooks.shellcheck = {"include":["**/*.sh","scripts/**","**/*.bash"],"exclude":[],"orchestrator":"none","severity":"error"}')"
OUT="$(contract "$DSTRONG" sync)"
expect_contains "pure strengthening reports no deviations" "$OUT" "no deviations"

# --- SC-006: dormant repos byte-for-byte unaffected ---
echo ""
echo "=== dormant: no extends, no contract machinery ==="

DN="$WORKDIR/dormant"
project "$DN" '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}'
OUT="$(contract "$DN" sync)"
expect_contains "sync on a dormant repo is a no-op" "$OUT" "nothing to sync"
expect "no artifacts appear" "$(artifact_count "$DN")" 0
expect "dormant gate passes" "$(gate "$DN")" 0
J="$(gate_json "$DN")"
expect "no contract gate entry" \
    "$(printf '%s' "$J" | jq -r '[.gates[] | select(.name == "contract")] | length')" 0
expect "no attestation contract object" \
    "$(printf '%s' "$J" | jq -r '.attestation | has("contract")')" false

# --- sync failure modes: named, prior state intact ---
echo ""
echo "=== sync failures fail closed ==="

BB="$WORKDIR/base-branchy"
mkbaseline "$BB" v1.0.0 "$BASE_POLICY"
DB="$WORKDIR/branch-pin"
project "$DB" "$(printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' | jq -c --arg src "$BB" '. + {extends: {source: $src, version: "main"}}')"
OUT="$(contract "$DB" sync)"
expect_contains "branch-name version refused" "$OUT" "EXIT=2"
expect_contains "branch refusal explains itself" "$OUT" "a moving pin is not a pin"

BCHAIN="$WORKDIR/base-chained"
mkbaseline "$BCHAIN" v1.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c --arg src "$BB" '. + {extends: {source: $src, version: "v1.0.0"}}')"
DC="$WORKDIR/chained"
project "$DC" "$(overlay_for "$BCHAIN" '.')"
OUT="$(contract "$DC" sync)"
expect_contains "chained baseline refused" "$OUT" "EXIT=2"
expect_contains "chained refusal names the limitation" "$OUT" "chained baselines are not supported"

BINVALID="$WORKDIR/base-invalid"
mkbaseline "$BINVALID" v1.0.0 '{"hooks":{"x":{"severity":"catastrophic"}}}'
DI="$WORKDIR/invalid"
project "$DI" "$(overlay_for "$BINVALID" '.')"
OUT="$(contract "$DI" sync)"
expect_contains "schema-invalid baseline refused" "$OUT" "EXIT=2"
expect_contains "validation failure surfaced" "$OUT" "fails policy validation"
expect "no artifacts written on refusal" "$(artifact_count "$DI")" 0

DU="$WORKDIR/unreachable"
project "$DU" "$(overlay_for "$WORKDIR/no-such-repo" '.')"
OUT="$(contract "$DU" sync)"
expect_contains "unreachable source refused" "$OUT" "EXIT=2"
expect_contains "unreachable source named" "$OUT" "could not fetch"

# Prior state survives a later failed sync.
jq '.extends.version = "v9.9.9"' "$D/.specify/gates/policy.json" >"$D/p.tmp" && mv "$D/p.tmp" "$D/.specify/gates/policy.json"
OUT="$(contract "$D" sync)"
expect_contains "sync to unknown version fails" "$OUT" "EXIT=2"
expect "prior pin untouched by the failed sync" \
    "$(jq -r '.version' "$D/.specify/gates/baseline.lock.json")" "v1.0.0"
jq '.extends.version = "v1.0.0"' "$D/.specify/gates/policy.json" >"$D/p.tmp" && mv "$D/p.tmp" "$D/.specify/gates/policy.json"

# --- US2: reviewable updates (SC-003) ---
echo ""
echo "=== sync --update: reviewable, never in place ==="

mkbaseline "$B" v1.2.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.hooks.markdownlint = {"include":["**/*.md"],"orchestrator":"none","severity":"error"}')"
mkbaseline "$B" v1.10.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.hooks.markdownlint = {"include":["**/*.md"],"orchestrator":"none","severity":"error"} | .hooks.shellcheck.severity = "error"')"

UP="$WORKDIR/updater"
project "$UP" "$(overlay_for "$B" '.')"
git init -q "$UP"
git -C "$UP" checkout -q -b main
git -C "$UP" config user.email u@test
git -C "$UP" config user.name updater
CLAUDE_PROJECT_DIR="$UP" bash "$UP/.specify/gates/contract.sh" sync >/dev/null
git -C "$UP" add -A
git -C "$UP" commit -qm "adopt baseline v1.0.0"

OUT="$(contract "$UP" sync --update)"
expect_contains "update run exits 0" "$OUT" "EXIT=0"
expect_contains "numeric tag ordering picks v1.10.0 (not v1.2.0)" "$OUT" "v1.0.0 -> v1.10.0"
expect "update branch exists" \
    "$(git -C "$UP" rev-parse --verify -q refs/heads/gates/baseline-v1.10.0 >/dev/null && echo yes)" yes
expect "work tree still enforces the old pin (SC-003)" \
    "$(jq -r '.version' "$UP/.specify/gates/baseline.lock.json")" "v1.0.0"
expect "work tree gate still green at the old pin" "$(gate "$UP")" 0
expect "branch commit updates all three artifacts together" \
    "$(git -C "$UP" show --name-only --format= gates/baseline-v1.10.0 | grep -cE 'baseline.json|baseline.lock.json|policy.effective.json')" 3
expect "branch lock carries the new version" \
    "$(git -C "$UP" show gates/baseline-v1.10.0:.specify/gates/baseline.lock.json | jq -r '.version')" "v1.10.0"
expect_contains "commit body carries the enforcement delta" \
    "$(git -C "$UP" log -1 --format=%B gates/baseline-v1.10.0)" "Enforcement delta"

OUT="$(contract "$UP" sync --update v1.2.0)"
expect_contains "explicit version honored" "$OUT" "v1.0.0 -> v1.2.0"
expect "explicit-version branch exists" \
    "$(git -C "$UP" rev-parse --verify -q refs/heads/gates/baseline-v1.2.0 >/dev/null && echo yes)" yes

OUT="$(contract "$UP" sync --update v1.0.0)"
expect_contains "already-up-to-date is a no-op" "$OUT" "already up to date"

# --- US3: propose (SC-005) ---
echo ""
echo "=== propose: deviations become an upstream change request ==="

OUT="$(contract "$DSTRONG" propose --rationale "should not be needed")"
expect_contains "no deviations -> nothing to propose, exit 0" "$OUT" "nothing to propose"
expect_contains "nothing-to-propose exits 0" "$OUT" "EXIT=0"

OUT="$(contract "$DV" propose </dev/null)"
expect_contains "non-interactive without --rationale refused" "$OUT" "EXIT=1"
expect_contains "refusal explains the rationale requirement" "$OUT" "rationale is required"

OUT="$(contract "$DV" propose --rationale "docs-only repo: shell severity is noise")"
expect_contains "propose exits 0" "$OUT" "EXIT=0"
PATCH=""
for p in "$DV/.specify/gates/proposals/"*.patch; do
    [[ -f "$p" ]] && PATCH="$p" && break
done
expect "patch written under proposals/" "$([[ -n "$PATCH" && -f "$PATCH" ]] && echo yes)" yes
expect_contains "patch carries the origin" "$(cat "$PATCH")" "Origin: deviate"
expect_contains "patch carries the pinned version" "$(cat "$PATCH")" "@v1.0.0"
expect_contains "patch carries the rationale" "$(cat "$PATCH")" "docs-only repo: shell severity is noise"
expect_contains "patch carries the classification" "$(cat "$PATCH")" "weakened: hooks.shellcheck.severity"
expect_contains "patch applies the deviation to the baseline document" "$(cat "$PATCH")" '"severity": "warning"'

echo ""
echo "$PASS of $TOTAL tests passed"
if [[ "$FAIL" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
