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
trap '[[ -n "${GATES_KEEP_TMP:-}" ]] || { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }' EXIT

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

# A setup step that is a test of its own: a failure is recorded and the
# suite goes on instead of stopping under set -e.
step() { # <name> <command...>
    local name="$1" rc=0
    shift
    "$@" >/dev/null 2>&1 || rc=$?
    expect "$name" "exit $rc" "exit 0"
}

expect_contains() { # <name> <haystack> <needle>
    TOTAL=$((TOTAL + 1))
    if grep -qF -- "$3" <<<"$2"; then
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
expect_contains "delta names a hook the new baseline adds (#135)" \
    "$(git -C "$UP" log -1 --format=%B gates/baseline-v1.10.0)" "- added (strengthened): hooks.markdownlint"

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

# --- refusals and edge paths (#98): every one named, nothing half-written ---
echo ""
echo "=== refusals and edge paths ==="

OUT="$(contract "$D" bogus)"
expect_contains "unknown subcommand prints usage" "$OUT" "usage: contract.sh sync"
expect_contains "unknown subcommand exits 1" "$OUT" "EXIT=1"
OUT="$(contract "$D" sync --bogus)"
expect_contains "sync: unknown flag named" "$OUT" "sync: unknown argument: --bogus"
expect_contains "sync: unknown flag exits 1" "$OUT" "EXIT=1"
OUT="$(contract "$DV" propose --bogus)"
expect_contains "propose: unknown flag named" "$OUT" "propose: unknown argument: --bogus"
OUT="$(contract "$DV" propose --rationale)"
expect_contains "propose: --rationale without a value refused" "$OUT" "rationale needs a value"
expect_contains "propose: --rationale without a value exits 1" "$OUT" "EXIT=1"

# Repos without extends: propose is a no-op, like sync.
DN="$WORKDIR/no-extends"
project "$DN" '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}'
OUT="$(contract "$DN" propose --rationale x)"
expect_contains "propose without extends: nothing to propose, exit 0" "$OUT" "no extends declared"
expect_contains "propose without extends exits 0" "$OUT" "EXIT=0"

# An overlay that is itself invalid is refused before any fetch.
DBAD="$WORKDIR/bad-overlay"
project "$DBAD" "$(overlay_for "$B" '.hooks.shellcheck = {"severity":"catastrophic"}')"
OUT="$(contract "$DBAD" sync)"
expect_contains "invalid policy.json refused" "$OUT" "policy.json itself fails validation"
expect_contains "invalid policy.json exits 2" "$OUT" "EXIT=2"
expect "no artifacts written for an invalid policy.json" "$(artifact_count "$DBAD")" 0

# A baseline whose policy.json is not JSON.
BJ="$WORKDIR/base-notjson"
git init -q "$BJ"
printf '{ "hooks": \n' >"$BJ/policy.json"
git -C "$BJ" add -A
git -C "$BJ" -c user.email=b@test -c user.name=baseline commit -qm broken
git -C "$BJ" tag v1.0.0
DJ="$WORKDIR/notjson"
project "$DJ" "$(overlay_for "$BJ" '.')"
OUT="$(contract "$DJ" sync)"
expect_contains "non-JSON baseline refused" "$OUT" "is not valid JSON"
expect_contains "non-JSON baseline exits 2" "$OUT" "EXIT=2"
expect "no artifacts written for a non-JSON baseline" "$(artifact_count "$DJ")" 0

# Baseline and overlay each valid, the merge not: the baseline's custom
# orchestrator loses its command to the overlay's empty one.
BM="$WORKDIR/base-custom"
mkbaseline "$BM" v1.0.0 '{"hooks":{"verify-quality":{"orchestrator":"custom","custom_command":"true","severity":"error"}}}'
DM="$WORKDIR/bad-merge"
project "$DM" "$(printf '%s' '{"hooks":{"verify-quality":{"custom_command":"","severity":"error"}}}' | jq -c --arg src "$BM" '. + {extends: {source: $src, version: "v1.0.0"}}')"
OUT="$(contract "$DM" sync)"
expect_contains "invalid effective policy refused" "$OUT" "merged effective policy fails validation"
expect_contains "invalid effective policy exits 2" "$OUT" "EXIT=2"
expect "no artifacts written for an invalid merge" "$(artifact_count "$DM")" 0

# sync --update needs a pin; propose needs a sync.
DNP="$WORKDIR/no-pin"
project "$DNP" "$(overlay_for "$B" '.')"
OUT="$(contract "$DNP" sync --update)"
expect_contains "update without a pin refused" "$OUT" "needs an existing pin"
expect_contains "update without a pin exits 2" "$OUT" "EXIT=2"
OUT="$(contract "$DNP" propose --rationale x)"
expect_contains "propose before sync refused" "$OUT" "not synced"
expect_contains "propose before sync exits 2" "$OUT" "EXIT=2"

# An update branch that already exists is never overwritten.
OUT="$(contract "$UP" sync --update)"
expect_contains "existing update branch refused" "$OUT" "already exists"
expect_contains "existing update branch exits 2" "$OUT" "EXIT=2"

# Outside a git work tree the update is printed, not committed.
DNG="$WORKDIR/no-git"
project "$DNG" "$(overlay_for "$B" '.')"
CLAUDE_PROJECT_DIR="$DNG" bash "$DNG/.specify/gates/contract.sh" sync >/dev/null
OUT="$(contract "$DNG" sync --update)"
expect_contains "no work tree: update printed" "$OUT" "update available: v1.0.0 -> v1.10.0"
expect_contains "no work tree exits 0" "$OUT" "EXIT=0"
expect "no work tree: pin unchanged" "$(jq -r '.version' "$DNG/.specify/gates/baseline.lock.json")" "v1.0.0"

# A source that lost its tags (or its pinned tag) is named, not guessed at.
BT="$WORKDIR/base-tags"
mkbaseline "$BT" v1.0.0 "$BASE_POLICY"
DT="$WORKDIR/lost-tags"
project "$DT" "$(overlay_for "$BT" '.hooks.shellcheck = {"severity":"warning"}')"
CLAUDE_PROJECT_DIR="$DT" bash "$DT/.specify/gates/contract.sh" sync >/dev/null
git -C "$BT" tag -d v1.0.0 >/dev/null
OUT="$(contract "$DT" sync --update)"
expect_contains "no tags at the source named" "$OUT" "no version tags found"
expect_contains "no tags at the source exits 2" "$OUT" "EXIT=2"
OUT="$(contract "$DT" propose --rationale "pinned tag gone")"
expect_contains "propose: missing pinned version named" "$OUT" "pinned version v1.0.0 not found"
expect_contains "propose: missing pinned version exits 2" "$OUT" "EXIT=2"

# --- #135: the update branch passes its own gates; overlays are partial ---
echo ""
echo "=== sync --update under active git hooks (#135) ==="

BH="$WORKDIR/base-hooked"
mkbaseline "$BH" v1.9.0 "$BASE_POLICY"
mkbaseline "$BH" v1.10.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.hooks.shellcheck.include += ["**/*.bash"]')"
HK="$WORKDIR/hooked"
project "$HK" "$(overlay_for "$BH" '.extends.version = "v1.9.0" | .protected_files = {"extra": [".specify/gates/policy.json"]}')"
mkdir -p "$HK/.specify/gates/hooks"
cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" "$REPO_ROOT/extension/runtime/hooks/git/commit-msg" \
    "$HK/.specify/gates/hooks/"
git init -q "$HK"
git -C "$HK" checkout -q -b main
git -C "$HK" config user.email u@test
git -C "$HK" config user.name updater
CLAUDE_PROJECT_DIR="$HK" bash "$HK/.specify/gates/contract.sh" sync >/dev/null
git -C "$HK" add -A
git -C "$HK" commit -qm "chore: adopt baseline v1.9.0"
for h in pre-commit commit-msg; do
    cp "$REPO_ROOT/extension/runtime/hooks/git/stub.sh" "$HK/.git/hooks/$h"
    chmod +x "$HK/.git/hooks/$h"
done
# A commit-msg rule refuses the update commit: the run must fail and
# leave neither the branch nor the worktree behind.
mkdir -p "$HK/.specify/gates/hooks.local.d/commit-msg"
# shellcheck disable=SC2016  # the rule's own $1
printf '%s\n' '#!/bin/bash' 'if grep -q "policy baseline" "$1"; then echo "updates are frozen" >&2; exit 1; fi' \
    >"$HK/.specify/gates/hooks.local.d/commit-msg/10-freeze.sh"
git -C "$HK" add -A
git -C "$HK" commit -q --no-verify -m "chore: freeze updates"
OUT="$(contract "$HK" sync --update)"
expect_contains "refused update commit exits 2" "$OUT" "EXIT=2"
expect_contains "refused update names the hook's cause" "$OUT" "updates are frozen"
expect "refused update leaves no branch" \
    "$(git -C "$HK" rev-parse --verify -q refs/heads/gates/baseline-v1.10.0 >/dev/null && echo yes || echo no)" no
expect "refused update leaves no worktree" "$(git -C "$HK" worktree list | wc -l | tr -d ' ')" 1
git -C "$HK" rm -q -r .specify/gates/hooks.local.d
git -C "$HK" commit -q --no-verify -m "chore: unfreeze updates"

OUT="$(contract "$HK" sync --update)"
expect_contains "retry after a refused update exits 0" "$OUT" "EXIT=0"
expect "update branch declares the new version" \
    "$(git -C "$HK" show gates/baseline-v1.10.0:.specify/gates/policy.json | jq -r '.extends.version')" v1.10.0
expect "policy.json diff is the version value only" \
    "$(git -C "$HK" diff main gates/baseline-v1.10.0 -- .specify/gates/policy.json | grep -c '^[-+][^-+]')" 2
git -C "$HK" worktree add -q "$WORKDIR/hooked-wt" gates/baseline-v1.10.0
expect "update branch passes its own gate" "$(gate "$WORKDIR/hooked-wt")" 0
git -C "$HK" worktree remove -f "$WORKDIR/hooked-wt"
BODY="$(git -C "$HK" log -1 --format=%B gates/baseline-v1.10.0)"
expect_contains "delta classifies an added include glob" "$BODY" "- strengthened: hooks.shellcheck.include"
expect_contains "commit declares the lock" "$BODY" "Protected-Change: .specify/gates/baseline.lock.json"
expect_contains "commit declares policy.json" "$BODY" "Protected-Change: .specify/gates/policy.json"
expect_contains "commit names the approver" "$BODY" "Approved-By: updater"

echo ""
echo "=== delta classification (#135) ==="
CL="$WORKDIR/classify"
mkdir -p "$CL"
printf '%s' '{"hooks":{"s":{"include":["a"],"exclude":["v"],"severity":"error"}},"git":{"block_main_commits":true,"protected_change_trailer":true,"conventional_commits":true,"forbid_ai_isms":true}}' >"$CL/old.json"
printf '%s' '{"hooks":{"s":{"include":["a","b"],"exclude":["v","w"],"severity":"error"},"m":{"severity":"error"}},"git":{"block_main_commits":false,"protected_change_trailer":false,"conventional_commits":false,"forbid_ai_isms":false}}' >"$CL/new.json"
devs() { # <mode>: printed delta lines for old -> new
    (
        # shellcheck source=/dev/null
        source "$REPO_ROOT/extension/runtime/lib/contract.sh"
        gates_contract_deviations "$CL/old.json" "$CL/new.json" "$1" | gates_contract_print_deviations "- " delta
    )
}
OUT="$(devs delta)"
expect_contains "added include glob is a strengthening" "$OUT" "- strengthened: hooks.s.include"
expect_contains "added exclude glob is a weakening" "$OUT" "- weakened: hooks.s.exclude"
for k in block_main_commits protected_change_trailer conventional_commits forbid_ai_isms; do
    expect_contains "git.$k true->false is a weakening" "$OUT" "- weakened: git.$k"
done
expect_contains "a hook the new side adds is one line" "$OUT" "- added (strengthened): hooks.m"
OUT="$(devs "")"
expect "overlay mode reports no strengthenings or additions" \
    "$(grep -cE 'strengthened|hooks\.m' <<<"$OUT")" 0

echo ""
echo "=== partial overlays (#135) ==="
OX="$WORKDIR/overlay-extends-only"
project "$OX" "$(jq -nc --arg src "$B" '{extends: {source: $src, version: "v1.0.0"}}')"
OUT="$(contract "$OX" sync)"
expect_contains "an overlay that is only extends syncs" "$OUT" "EXIT=0"
expect "extends-only repo gate passes" "$(gate "$OX")" 0
OP="$WORKDIR/overlay-partial"
project "$OP" "$(overlay_for "$B" '.hooks.shellcheck = {"exclude":["vendor/**","gen/**"]}')"
OUT="$(contract "$OP" sync)"
expect_contains "a partial hook overlay needs no severity" "$OUT" "EXIT=0"
expect_contains "the partial overlay's weakening is classified" "$OUT" "deviation (weakened): hooks.shellcheck.exclude"
OR="$WORKDIR/overlay-remove"
project "$OR" "$(overlay_for "$B" '.hooks.shellcheck = null')"
OUT="$(contract "$OR" sync)"
expect_contains "removing a hook with null syncs" "$OUT" "EXIT=0"
expect_contains "a removed hook is one weakened deviation" "$OUT" "deviation (weakened): hooks.shellcheck: removed"
expect "and only one" "$(grep -c 'hooks.shellcheck' <<<"$OUT")" 1
expect "removed-hook repo gate passes" "$(gate "$OR")" 0
OS="$WORKDIR/overlay-scalar-hook"
project "$OS" "$(overlay_for "$B" '.hooks.shellcheck = "off"')"
OUT="$(contract "$OS" sync)"
expect_contains "a non-object hook in the overlay is refused" "$OUT" "policy.json itself fails validation"
expect_contains "the refusal names the hook" "$OUT" "shellcheck: must be an object"

echo ""
echo "=== propose: minimal upstream diff (#135) ==="
BU="$WORKDIR/base-unsorted"
git init -q "$BU"
printf '%s' '{"spec":{"severity":"error","enabled":true},"hooks":{"shellcheck":{"severity":"error","orchestrator":"none","include":["**/*.sh"]}}}' \
    | jq . >"$BU/policy.json"
git -C "$BU" add -A
git -C "$BU" -c user.email=b@test -c user.name=baseline commit -qm "baseline"
git -C "$BU" tag v1.0.0
PU="$WORKDIR/unsorted"
project "$PU" "$(overlay_for "$BU" '.hooks.shellcheck = {"severity":"warning"}')"
CLAUDE_PROJECT_DIR="$PU" bash "$PU/.specify/gates/contract.sh" sync >/dev/null
OUT="$(contract "$PU" propose --rationale "shell is advisory here")"
expect_contains "propose on an unsorted upstream exits 0" "$OUT" "EXIT=0"
PATCH=""
for p in "$PU/.specify/gates/proposals/"*.patch; do
    [[ -f "$p" ]] && PATCH="$p" && break
done
expect "the proposal changes only the deviating line" "$(grep -cE '^[-+] +"' "$PATCH")" 2

# A consumer repo on <baseline-dir>@<version> with the projected git hooks
# active through the stub, adopted on main with hooks bypassed.
hooked_repo() { # <dir> <baseline-dir> <version> [overlay-jq-filter]
    local dir="$1" h
    project "$dir" "$(overlay_for "$2" ".extends.version = \"$3\" | .protected_files = {\"extra\": [\".specify/gates/policy.json\"]} | ${4:-.}")"
    mkdir -p "$dir/.specify/gates/hooks"
    cp "$REPO_ROOT/extension/runtime/hooks/git/pre-commit" "$REPO_ROOT/extension/runtime/hooks/git/commit-msg" \
        "$dir/.specify/gates/hooks/"
    git init -q "$dir"
    git -C "$dir" checkout -q -b main
    git -C "$dir" config user.email u@test
    git -C "$dir" config user.name updater
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/contract.sh" sync >/dev/null
    git -C "$dir" add -A
    git -C "$dir" commit -q --no-verify -m "chore: adopt baseline $3"
    for h in pre-commit commit-msg; do
        cp "$REPO_ROOT/extension/runtime/hooks/git/stub.sh" "$dir/.git/hooks/$h"
        chmod +x "$dir/.git/hooks/$h"
    done
}

echo ""
echo "=== sync --update: no policy text in the commit message (#154) ==="
BW="$WORKDIR/base-words"
mkbaseline "$BW" v1.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.git = {"ai_branding": {"terms": ["Anthropic", "GPT", "Gemini"]}} | ._comment = "the baseline"')"
mkbaseline "$BW" v2.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.git = {"ai_branding": {"terms": ["Anthropic", "GPT", "Copilot", "OpenAI"]}} | ._comment = "a seamless baseline, Co-Authored-By: nobody"')"
mkbaseline "$BW" v3.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.git = {"ai_branding": {"terms": ["Anthropic", "GPT", "Copilot"]}} | .hooks."copilot-review" = {"include": ["**/*.none"], "orchestrator": "none", "severity": "error"}')"
WD="$WORKDIR/words"
hooked_repo "$WD" "$BW" v1.0.0
OUT="$(contract "$WD" sync --update v2.0.0)"
expect_contains "update adding a branding term commits" "$OUT" "EXIT=0"
BODY="$(git -C "$WD" log -1 --format=%B gates/baseline-v2.0.0 2>/dev/null || true)"
expect_contains "list change is summarized as counts" "$BODY" "- changed: git.ai_branding.terms: 2 added, 1 removed"
expect_contains "a text value is described, not quoted" "$BODY" "- changed: _comment: value changed"
expect "no branding term, AI-ism or trailer text from the baseline in the body" \
    "$(grep -ciE 'copilot|openai|gemini|seamless|co-authored-by' <<<"$BODY")" 0
expect_contains "full message keeps the versions" "$BODY" "chore: update policy baseline v1.0.0 -> v2.0.0"
# A hook name is part of a path and can still trip the rules: the message
# falls back to counts only.
OUT="$(contract "$WD" sync --update v3.0.0)"
expect_contains "update whose paths trip the rules still commits" "$OUT" "EXIT=0"
BODY="$(git -C "$WD" log -1 --format=%B gates/baseline-v3.0.0 2>/dev/null || true)"
expect_contains "fallback message carries the counts" "$BODY" "Enforcement delta: 1 strengthened, 0 weakened, 2 changed"
expect "fallback message names no path" "$(grep -ci 'copilot' <<<"$BODY")" 0
expect_contains "fallback message keeps the trailers" "$BODY" "Protected-Change: .specify/gates/baseline.lock.json"

echo ""
echo "=== sync --update: a committer name the rules refuse (#159) ==="
# The name is a branding term of the baseline: the approver falls back to
# the committer email's local part.
WN="$WORKDIR/words-name"
hooked_repo "$WN" "$BW" v1.0.0
git -C "$WN" config user.name Anthropic
git -C "$WN" config user.email pat@test
OUT="$(contract "$WN" sync --update v2.0.0)"
expect_contains "update by a branded committer name commits" "$OUT" "EXIT=0"
BODY="$(git -C "$WN" log -1 --format=%B gates/baseline-v2.0.0 2>/dev/null || true)"
expect_contains "the approver is the email local part" "$BODY" "Approved-By: pat"
expect "the branded name is not in the message" "$(grep -ci 'anthropic' <<<"$BODY")" 0
# Standalone "Claude" in the name and the email: the fixed approver.
WC="$WORKDIR/words-claude"
hooked_repo "$WC" "$BW" v1.0.0
git -C "$WC" config user.name Claude
git -C "$WC" config user.email claude@test
OUT="$(contract "$WC" sync --update v2.0.0)"
expect_contains "update by a committer named Claude commits" "$OUT" "EXIT=0"
BODY="$(git -C "$WC" log -1 --format=%B gates/baseline-v2.0.0 2>/dev/null || true)"
expect_contains "the approver falls back to the fixed value" "$BODY" "Approved-By: the committer of this commit"
expect "the committer's name is in the commit, not the message" \
    "$(git -C "$WC" log -1 --format=%cn gates/baseline-v2.0.0 2>/dev/null || true)" Claude

echo ""
echo "=== sync --update with git.protected_change_trailer false (#154) ==="
BO="$WORKDIR/base-trailer-off"
mkbaseline "$BO" v1.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.git = {"protected_change_trailer": false}')"
mkbaseline "$BO" v2.0.0 "$(printf '%s' "$BASE_POLICY" | jq -c '.git = {"protected_change_trailer": false} | .hooks.shellcheck.include += ["**/*.bash"]')"
TO="$WORKDIR/trailer-off"
step "trailer-off fixture is set up" hooked_repo "$TO" "$BO" v1.0.0
OUT="$(contract "$TO" sync --update)"
expect_contains "trailer-off update commits" "$OUT" "EXIT=0"
expect_contains "pre-commit names the verified update" "$OUT" "exactly a policy baseline update"
BODY="$(git -C "$TO" log -1 --format=%B gates/baseline-v2.0.0 2>/dev/null || true)"
expect_contains "trailer-off update still declares the lock for pr-check" "$BODY" "Protected-Change: .specify/gates/baseline.lock.json"
expect_contains "trailer-off update names the approver" "$BODY" "Approved-By: updater"
# The allowance is the exact shape only. Rebuild the update by hand on a
# fresh gates/baseline-v2.0.0 branch and vary it. Every step is a test of
# its own: a failed one is reported and the suite goes on (#159).
step "keep the update branch" git -C "$TO" branch -q -m gates/baseline-v2.0.0 keep-update
step "fresh update branch from main" git -C "$TO" switch -q -c gates/baseline-v2.0.0 main
# shellcheck disable=SC2329 # run through step
stage_update() {
    git -C "$TO" checkout -q keep-update -- .specify/gates/policy.json .specify/gates/baseline.json \
        .specify/gates/baseline.lock.json .specify/gates/policy.effective.json
}
hand_commit() { # -> output + EXIT line
    local rc=0 out
    out="$(cd "$TO" && env -u CLAUDE_PROJECT_DIR git commit -q -m "chore: update policy baseline by hand" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}
# shellcheck disable=SC2329 # run through step
jq_edit() { # <file under .specify/gates> <jq args...>: rewrite it in place
    local f="$TO/.specify/gates/$1"
    shift
    jq "$@" "$f" >"$TO/edit.tmp" && mv "$TO/edit.tmp" "$f"
}
# shellcheck disable=SC2329 # run through step
recompute_effective() {
    (
        # shellcheck source=/dev/null
        source "$REPO_ROOT/extension/runtime/lib/contract.sh"
        gates_contract_merge "$TO/.specify/gates/baseline.json" "$TO/.specify/gates/policy.json" \
            >"$TO/.specify/gates/policy.effective.json"
    )
}
step "stage the update" stage_update
printf 'x\n' >"$TO/notes.txt"
step "stage an extra file" git -C "$TO" add notes.txt
OUT="$(hand_commit)"
expect_contains "an extra staged file voids the allowance" "$OUT" "BLOCKED: policy-protected file staged"
step "unstage the extra file" git -C "$TO" rm -q --cached notes.txt
rm -f "$TO/notes.txt"
step "edit the snapshot" jq_edit baseline.json -S '.hooks.shellcheck.severity = "warning"'
step "stage the edited snapshot" git -C "$TO" add .specify/gates/baseline.json
OUT="$(hand_commit)"
expect_contains "a snapshot that does not match the lock is refused" "$OUT" "BLOCKED: policy-protected file staged"
step "restage the update" stage_update
# policy.json changing more than extends.version, effective recomputed to
# match: only the one-field rule catches it.
step "edit policy.json beyond the pin" jq_edit policy.json '.hooks.shellcheck = {"severity": "warning"}'
step "recompute the effective policy" recompute_effective
step "stage both" git -C "$TO" add .specify/gates/policy.json .specify/gates/policy.effective.json
OUT="$(hand_commit)"
expect_contains "a policy.json change beyond extends.version is refused" "$OUT" "BLOCKED: policy-protected file staged"
step "restage the exact update" stage_update
OUT="$(hand_commit)"
expect_contains "the exact update shape commits by hand too" "$OUT" "EXIT=0"
step "branch whose name misses the pin" git -C "$TO" switch -q -c gates/baseline-v9.9.9 keep-update~1
step "stage the update there" stage_update
OUT="$(hand_commit)"
expect_contains "a branch name that does not match the pin is refused" "$OUT" "BLOCKED: policy-protected file staged"

echo ""
echo "$PASS of $TOTAL tests passed"
if [[ "$FAIL" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
