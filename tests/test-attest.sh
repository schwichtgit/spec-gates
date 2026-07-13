#!/bin/bash
set -euo pipefail

# Attestation-record tests (feature 001, US2): every verify.sh run leaves
# evidence — a schema-conformant record in the capped JSONL log, embedded in
# --json — and doctor fails on the no-op signature. The cap loop is SC-004's
# regression test; the forged no-op record is FR-004's.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$REPO_ROOT/specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t gates-attest)"
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
skip() { # <name> <why>
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    echo "SKIP: $1 ($2)"
}

have_node_linters() { [[ -x "$REPO_ROOT/node_modules/.bin/prettier" ]]; }

project() { # <dir> <policy-json>
    local dir="$1" policy="$2"
    mkdir -p "$dir/.specify/gates/lib"
    cp "$REPO_ROOT/extension/runtime/verify.sh" \
        "$REPO_ROOT/extension/runtime/doctor.sh" "$dir/.specify/gates/"
    cp "$REPO_ROOT/extension/runtime/lib/"*.sh "$dir/.specify/gates/lib/"
    printf '%s' "$policy" >"$dir/.specify/gates/policy.json"
    if [[ -d "$REPO_ROOT/node_modules" ]]; then
        ln -sfn "$REPO_ROOT/node_modules" "$dir/node_modules"
        # The lockfile travels with node_modules: it is the pin source (R2).
        cp "$REPO_ROOT/package-lock.json" "$dir/" 2>/dev/null || true
    fi
}

gate() { # <dir> [flag...]: run verify.sh, echo exit code
    local dir="$1"
    shift
    local rc=0
    CLAUDE_PROJECT_DIR="$dir" bash "$dir/.specify/gates/verify.sh" \
        --boundary ci "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

gate_json() { # <dir>: run verify.sh --json, echo stdout
    CLAUDE_PROJECT_DIR="$1" bash "$1/.specify/gates/verify.sh" \
        --boundary ci --json 2>/dev/null || true
}

CUSTOM_TRUE='{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } } }'
CUSTOM_FALSE='{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "false" } } }'
NONE_PRETTIER='{ "hooks": { "prettier": { "include": ["**/*.md"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'

# --- 1: every run leaves evidence, in the log and in --json ---
echo "=== record present in log and --json ==="
D="$WORKDIR/basic"
project "$D" "$CUSTOM_TRUE"
OUT="$(gate_json "$D")"
LOG="$D/.specify/gates/attestations.jsonl"
expect "--json has a top-level attestation key" \
    "$(printf '%s' "$OUT" | jq -r 'has("attestation")')" true
expect "log file exists with one record" \
    "$([[ -f "$LOG" ]] && wc -l <"$LOG" | tr -d ' ')" 1
expect "log record equals the embedded record" \
    "$(diff <(printf '%s' "$OUT" | jq -S .attestation) <(tail -1 "$LOG" | jq -S .) >/dev/null && echo same || echo differ)" same
CLAUDE_PROJECT_DIR="$D" bash "$D/.specify/gates/verify.sh" --boundary ci >/dev/null 2>&1 || true
expect "non-json run also appends (now two records)" \
    "$(wc -l <"$LOG" | tr -d ' ')" 2
expect "dry-run appends nothing" \
    "$(gate "$D" --dry-run >/dev/null; wc -l <"$LOG" | tr -d ' ')" 2

# --- 2: record shape matches the contract schema ---
echo ""
echo "=== record fields match the contract ==="
SHAPE_OK="$(tail -1 "$LOG" | jq -r '
    (.v == 1)
    and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.boundary == "ci")
    and (.policy_sha256 | test("^[0-9a-f]{64}$"))
    and ((.runtime_version == null) or ((.runtime_version | type) == "string"))
    and ((.exit | type) == "number")
    and ((.gates | type) == "array") and ((.gates | length) > 0)
    and ([.gates[]
        | ((.name | type) == "string")
        and (.result | IN("pass","fail","warn","skipped","planned"))
        and ((.duration_s | type) == "number") and (.duration_s >= 0)
        and (has("bin") and has("version") and has("pinned")
             and has("candidates") and has("checked") and has("reason"))
        ] | all)')"
expect "required fields + gate entry shape all conform" "$SHAPE_OK" true
expect "contract schema file exists (source of the assertions above)" \
    "$([[ -f "$SCHEMA" ]] && echo yes)" yes

if have_node_linters; then
    DT="$WORKDIR/tool-fields"
    project "$DT" "$NONE_PRETTIER"
    printf '# Title\n\nBody.\n' >"$DT/README.md"
    TOOL_OK="$(gate_json "$DT" | jq -r '.attestation.gates[0]
        | (.name == "prettier") and (.result == "pass")
        and (.version != null) and (.version == .pinned)
        and (.candidates >= 1) and (.checked == .candidates)
        and ((.bin | type) == "string")')"
    expect "tool gate carries bin/version=pin/candidates=checked" "$TOOL_OK" true
else
    skip "tool gate field check" "run npm ci to install pinned prettier"
fi

# --- 3: two identical runs differ only in ts/duration ---
echo ""
echo "=== determinism modulo ts/duration ==="
NORM='del(.ts) | .gates |= map(del(.duration_s))'
R1="$(gate_json "$D" | jq -cS ".attestation | $NORM")"
R2="$(gate_json "$D" | jq -cS ".attestation | $NORM")"
expect "identical runs produce identical records (modulo ts/duration)" \
    "$([[ "$R1" == "$R2" && -n "$R1" ]] && echo same || echo differ)" same

# --- 4: the log never exceeds max_records (SC-004) ---
echo ""
echo "=== cap loop (SC-004) ==="
DC="$WORKDIR/cap"
project "$DC" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "attestation": { "max_records": 5 } }'
i=0
while [[ $i -lt 15 ]]; do
    gate "$DC" >/dev/null
    i=$((i + 1))
done
CAP_LINES="$(wc -l <"$DC/.specify/gates/attestations.jsonl" | tr -d ' ')"
expect "15 runs with max_records=5 -> log holds 5 lines" "$CAP_LINES" 5
expect "capped log still parses line-by-line" \
    "$(jq -es 'length == 5' <"$DC/.specify/gates/attestations.jsonl" >/dev/null && echo yes || echo no)" yes

# --- 5: a missing tool is skipped, never pass ---
echo ""
echo "=== missing tool -> skipped (never pass) ==="
if command -v prettier >/dev/null 2>&1; then
    skip "missing-tool skip check" "a global prettier is on PATH"
else
    DM="$WORKDIR/missing"
    project "$DM" "$NONE_PRETTIER"
    rm -f "$DM/node_modules"
    printf '# Title\n\nBody.\n' >"$DM/README.md"
    MISS="$(gate_json "$DM" | jq -r '.attestation.gates[0] | "\(.result):\(.checked)"')"
    expect "absent prettier -> result=skipped, checked=0" "$MISS" "skipped:0"
    expect "skipped tool does not fail the run" "$(gate "$DM")" 0
fi

# --- 6: forged no-op record fails doctor, naming the gate (FR-004) ---
echo ""
echo "=== no-op signature fails doctor ==="
DN="$WORKDIR/noop"
project "$DN" "$CUSTOM_TRUE"
gate "$DN" >/dev/null
NLOG="$DN/.specify/gates/attestations.jsonl"
FORGED="$(tail -1 "$NLOG" | jq -c '.gates = [{"name":"prettier","bin":"node_modules/.bin/prettier","version":"3.9.4","pinned":"3.9.4","candidates":12,"checked":0,"result":"pass","reason":"","duration_s":0}]')"
printf '%s\n' "$FORGED" >>"$NLOG"
RC_DOC=0
DOC_OUT="$(CLAUDE_PROJECT_DIR="$DN" bash "$DN/.specify/gates/doctor.sh" 2>&1)" || RC_DOC=$?
expect "doctor exits 1 on the no-op signature" "$RC_DOC" 1
expect "doctor names the suspected gate" \
    "$(printf '%s' "$DOC_OUT" | grep -c 'NO-OP gate: prettier' || true)" 1

# --- 7: attestation.enabled=false -> no log, no key ---
echo ""
echo "=== attestation.enabled=false ==="
DD="$WORKDIR/disabled"
project "$DD" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "attestation": { "enabled": false } }'
OUT_D="$(gate_json "$DD")"
expect "no attestation key in --json" \
    "$(printf '%s' "$OUT_D" | jq -r 'has("attestation")')" false
expect "no log file written" \
    "$([[ -e "$DD/.specify/gates/attestations.jsonl" ]] && echo exists || echo absent)" absent
expect "gate still runs and passes" "$(gate "$DD")" 0

# --- 8: evidence loss never changes the gate outcome ---
echo ""
echo "=== log-write failure is a warning, not a result ==="
DW="$WORKDIR/unwritable"
project "$DW" "$CUSTOM_TRUE"
mkdir -p "$DW/.specify/gates/attestations.jsonl" # a directory: append must fail
RC_W=0
ERR_W="$(CLAUDE_PROJECT_DIR="$DW" bash "$DW/.specify/gates/verify.sh" --boundary ci 2>&1 >/dev/null)" || RC_W=$?
expect "green gate stays exit 0 despite unwritable log" "$RC_W" 0
expect "stderr carries a warning about the log" \
    "$(printf '%s' "$ERR_W" | grep -c 'could not write' || true)" 1

# --- 9: the record's exit field tracks the gate outcome ---
echo ""
echo "=== exit field tracks the outcome ==="
DF="$WORKDIR/red"
project "$DF" "$CUSTOM_FALSE"
expect "red gate exits 2" "$(gate "$DF")" 2
RED="$(tail -1 "$DF/.specify/gates/attestations.jsonl" | jq -r '"\(.exit):\(.gates[0].result)"')"
expect "record shows exit=2 and result=fail" "$RED" "2:fail"

# --- 10: the synthetic parity gate (US3) ---
echo ""
echo "=== parity gate: pins vs resolved versions (SC-002) ==="
if have_node_linters; then
    DP="$WORKDIR/parity"
    project "$DP" "$NONE_PRETTIER"
    printf '# Title\n\nBody.\n' >"$DP/README.md"

    PAR_OK="$(gate_json "$DP" | jq -r '.attestation.gates[] | select(.name == "parity") | .result')"
    expect "versions match pins -> parity pass" "$PAR_OK" pass

    # Stub drift by editing the pin in the fixture's own lockfile copy.
    jq '.packages["node_modules/prettier"].version = "9.9.9"' \
        "$DP/package-lock.json" >"$DP/pl.tmp" && mv "$DP/pl.tmp" "$DP/package-lock.json"
    RC_DRIFT=0
    DRIFT_OUT="$(CLAUDE_PROJECT_DIR="$DP" bash "$DP/.specify/gates/verify.sh" --boundary ci 2>&1)" || RC_DRIFT=$?
    expect "version drift -> gate fails (exit 2)" "$RC_DRIFT" 2
    expect "report names the tool and both versions" \
        "$(printf '%s' "$DRIFT_OUT" | grep -c 'parity -- prettier: resolved 3\..*, pinned 9\.9\.9 (run npm ci)' || true)" 1
    DRIFT_REC="$(tail -1 "$DP/.specify/gates/attestations.jsonl" \
        | jq -r '.gates[] | select(.name == "parity") | "\(.result):\(.reason | contains("pinned 9.9.9"))"')"
    expect "attestation carries the parity fail entry with reason" "$DRIFT_REC" "fail:true"

    # Severity warning: same drift reports without failing.
    jq '. + {"attestation": {"parity": "warning"}}' "$DP/.specify/gates/policy.json" \
        >"$DP/p.tmp" && mv "$DP/p.tmp" "$DP/.specify/gates/policy.json"
    expect "severity warning -> exit 0 despite drift" "$(gate "$DP")" 0
    WARN_REC="$(tail -1 "$DP/.specify/gates/attestations.jsonl" \
        | jq -r '.gates[] | select(.name == "parity") | .result')"
    expect "warning drift recorded as warn entry" "$WARN_REC" warn

    # Severity off: no parity entry anywhere.
    jq '.attestation.parity = "off"' "$DP/.specify/gates/policy.json" \
        >"$DP/p.tmp" && mv "$DP/p.tmp" "$DP/.specify/gates/policy.json"
    OFF_OUT="$(gate_json "$DP")"
    expect "parity off -> no entry in gates or attestation" \
        "$(printf '%s' "$OFF_OUT" | jq -r '([.gates[].name] + [.attestation.gates[].name]) | any(. == "parity")')" false

    # No pin source: tool attested but exempt from comparison.
    DU="$WORKDIR/unpinned"
    project "$DU" "$NONE_PRETTIER"
    rm -f "$DU/package-lock.json"
    printf '# Title\n\nBody.\n' >"$DU/README.md"
    UNPINNED="$(gate_json "$DU" | jq -r '.attestation.gates
        | "\(.[] | select(.name == "prettier") | .pinned):\(.[] | select(.name == "parity") | .result)"')"
    expect "unpinned tool (no lockfile) -> pinned null, parity pass" "$UNPINNED" "null:pass"
else
    skip "parity gate checks" "run npm ci to install pinned prettier"
fi

# --- 11: the spec object (feature 002, FR-008) ---
echo ""
echo "=== spec object: counts, outcomes, policy-disabled absence ==="

# GATES_SPEC_EXEC is cleared so these cases still exercise the spec gate
# when the suite itself runs from inside an accept block (the dogfood case).
spec_json() { # <dir>
    CLAUDE_PROJECT_DIR="$1" env -u GATES_SPEC_EXEC \
        bash "$1/.specify/gates/verify.sh" --boundary ci --json 2>/dev/null || true
}

DS="$WORKDIR/spec-shape"
project "$DS" "$CUSTOM_TRUE"
mkdir -p "$DS/specs/100-done" "$DS/specs/200-wip"
printf '# Done\n\n**Status**: Complete\n' >"$DS/specs/100-done/spec.md"
cat >"$DS/specs/100-done/tasks.md" <<'EOF'
- [x] T001 Task

  ```accept
  # verifies: SC-900
  true
  ```
EOF
printf '# WIP\n\n**Status**: Draft\n' >"$DS/specs/200-wip/spec.md"
cat >"$DS/specs/200-wip/tasks.md" <<'EOF'
- [ ] T001 Open task

  ```accept
  false
  ```
EOF
SPEC_OUT="$(spec_json "$DS")"
expect "attestation carries the spec object" \
    "$(printf '%s' "$SPEC_OUT" | jq -r '.attestation | has("spec")')" true
expect "spec counts: features/parsed/executed/passed/failed" \
    "$(printf '%s' "$SPEC_OUT" | jq -r '.attestation.spec | "\(.features):\(.parsed):\(.executed):\(.passed):\(.failed)"')" \
    "2:2:1:1:0"
expect "results[] outcome for the Complete feature is enforced-pass" \
    "$(printf '%s' "$SPEC_OUT" | jq -r '.attestation.spec.results[] | select(.feature == "100-done") | .outcome')" \
    "enforced-pass"
expect "results[] outcome for the Draft feature is informational" \
    "$(printf '%s' "$SPEC_OUT" | jq -r '.attestation.spec.results[] | select(.feature == "200-wip") | .outcome')" \
    "informational"
# Issue #32: candidates/checked count ENFORCED-feature accept blocks, not
# features — the Draft feature's parsed-but-unexecuted block contributes to
# neither, and a zero-block Complete feature yields candidates=0 instead of
# the false no-op signature.
expect "spec gate entry: candidates=enforced blocks, checked=executed" \
    "$(printf '%s' "$SPEC_OUT" | jq -r '.attestation.gates[] | select(.name == "spec") | "\(.candidates):\(.checked):\(.result)"')" \
    "1:1:pass"
expect "log record embeds the same spec object" \
    "$(diff <(printf '%s' "$SPEC_OUT" | jq -S '.attestation.spec') \
        <(tail -1 "$DS/.specify/gates/attestations.jsonl" | jq -S '.spec') >/dev/null \
        && echo same || echo differ)" same

DSD="$WORKDIR/spec-disabled"
project "$DSD" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "spec": { "enabled": false } }'
mkdir -p "$DSD/specs/100-done"
printf '# Done\n\n**Status**: Complete\n' >"$DSD/specs/100-done/spec.md"
cat >"$DSD/specs/100-done/tasks.md" <<'EOF'
- [x] T001 Task

  ```accept
  false
  ```
EOF
DIS_OUT="$(spec_json "$DSD")"
expect "spec.enabled=false -> no spec object in the record" \
    "$(printf '%s' "$DIS_OUT" | jq -r '.attestation | has("spec")')" false
expect "spec.enabled=false -> no spec gate entry" \
    "$(printf '%s' "$DIS_OUT" | jq -r '[.attestation.gates[] | select(.name == "spec")] | length')" 0

# --- 12: the contract object (feature 003, FR-010) ---
echo ""
echo "=== contract object: evidence, drift reason, dormant absence ==="

DCB="$WORKDIR/contract-base"
git init -q "$DCB"
printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"custom","severity":"error","custom_command":"true"}},"spec":{"enabled":true}}' \
    | jq -S . >"$DCB/policy.json"
git -C "$DCB" add -A
git -C "$DCB" -c user.email=b@t -c user.name=b commit -qm base
git -C "$DCB" tag v1.0.0

DCC="$WORKDIR/contract-consumer"
project "$DCC" "$(jq -cn --arg src "$DCB" '{hooks: {"verify-quality": {orchestrator: "custom", severity: "error", custom_command: "true"}}, spec: {enabled: false}, extends: {source: $src, version: "v1.0.0"}}')"
cp "$REPO_ROOT/extension/runtime/contract.sh" "$DCC/.specify/gates/"
CLAUDE_PROJECT_DIR="$DCC" bash "$DCC/.specify/gates/contract.sh" sync >/dev/null 2>&1
CON_OUT="$(spec_json "$DCC")"
expect "attestation carries the contract object" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation | has("contract")')" true
expect "contract source/version match the pin" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation.contract | "\(.source == "'"$DCB"'"):\(.version)"')" "true:v1.0.0"
expect "contract digest matches the lock" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation.contract.digest')" \
    "$(jq -r '.digest' "$DCC/.specify/gates/baseline.lock.json")"
expect "deviation counts recorded (spec.enabled weakened)" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation.contract.deviations | "\(.weakened):\(.changed)"')" "1:0"
expect "contract gate entry pass" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation.gates[] | select(.name == "contract") | .result')" "pass"
expect "policy_sha256 hashes the EFFECTIVE policy in a contract repo" \
    "$(printf '%s' "$CON_OUT" | jq -r '.attestation.policy_sha256')" \
    "$(shasum -a 256 "$DCC/.specify/gates/policy.effective.json" 2>/dev/null | cut -d' ' -f1 || sha256sum "$DCC/.specify/gates/policy.effective.json" | cut -d' ' -f1)"

printf ' ' >>"$DCC/.specify/gates/policy.effective.json"
DRIFT_OUT="$(spec_json "$DCC")"
expect "drifted contract gate entry carries the reason" \
    "$(printf '%s' "$DRIFT_OUT" | jq -r '.attestation.gates[] | select(.name == "contract") | .reason' | grep -c 'drifted')" 1

DORMANT_OUT="$(gate_json "$D")"
expect "dormant repo has no contract object" \
    "$(printf '%s' "$DORMANT_OUT" | jq -r '.attestation | has("contract")')" false

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
