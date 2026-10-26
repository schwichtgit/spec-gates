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
# --dry-run lists every gate a run would evaluate, parity included (#199),
# and leaves it out where a run would (parity off, attestations disabled).
dry_parity() { # <dir>: the parity entry's status under --dry-run, or none
    CLAUDE_PROJECT_DIR="$1" bash "$1/.specify/gates/verify.sh" --boundary ci --dry-run --json 2>/dev/null \
        | jq -r '[.gates[] | select(.name == "parity") | .status] | if length == 0 then "none" else join(",") end'
}
expect "dry-run lists the parity gate as planned" "$(dry_parity "$D")" planned
DPO="$WORKDIR/dry-parity-off"
project "$DPO" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "attestation": { "parity": "off" } }'
expect "dry-run with parity off lists no parity gate" "$(dry_parity "$DPO")" none
project "$DPO" '{ "hooks": { "verify-quality": { "orchestrator": "custom", "severity": "error", "custom_command": "true" } }, "attestation": { "enabled": false } }'
expect "dry-run with attestations disabled lists no parity gate" "$(dry_parity "$DPO")" none
expect "the log is gitignored next to it (#69)" \
    "$(grep -cxF attestations.jsonl "$D/.specify/gates/.gitignore" 2>/dev/null)" 1
if git -C "$D" rev-parse --git-dir >/dev/null 2>&1 || git init -q "$D" >/dev/null 2>&1; then
    expect "git treats the log as ignored" \
        "$(git -C "$D" check-ignore -q .specify/gates/attestations.jsonl && echo ignored || echo tracked)" ignored
fi

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

# --- project gates (feature 006): one entry each, tool fields null ---
echo ""
echo "=== project gate entries ==="
DG="$WORKDIR/project-gates"
project "$DG" '{ "hooks": { "verify-quality": { "orchestrator": "none", "severity": "error",
    "gates": { "ok": { "command": "true" },
               "bad": { "command": "echo PG-OUTPUT-SECRET; exit 1" },
               "soft": { "command": "echo PG-OUTPUT-SECRET; exit 1", "severity": "warning" },
               "slow": { "command": "echo PG-OUTPUT-SECRET; sleep 30", "timeout_s": 2 } } } } }'
PGJ="$(gate_json "$DG")"
expect "one attestation entry per project gate, in key order" \
    "$(jq -c '[.attestation.gates[].name]' <<<"$PGJ")" '["ok","bad","soft","slow","spec","parity"]'
expect "each carries result, reason, duration_s and null tool fields" \
    "$(jq -c '[.attestation.gates[] | select(.name != "spec" and .name != "parity")
        | [.result, (if .name == "slow" then (.reason | startswith("timeout after ")) else .reason end),
           ((.duration_s | type) == "number"),
           .bin, .version, .pinned, .candidates, .checked]]' <<<"$PGJ")" \
    '[["pass","",true,null,null,null,null,null],["fail","check failed",true,null,null,null,null,null],["warn","check failed (warning)",true,null,null,null,null,null],["fail",true,true,null,null,null,null,null]]'
expect "a timed-out gate's reason is the time limit" \
    "$(jq -r '.attestation.gates[] | select(.name == "slow") | .reason
        | test("^timeout after 2s( at load [0-9.]+)?$")' <<<"$PGJ")" true
expect "no command output in the record" \
    "$(jq -c '.attestation' <<<"$PGJ" | grep -c 'PG-OUTPUT-SECRET' || true)" 0
expect "the log record matches the embedded one" \
    "$(tail -n 1 "$DG/.specify/gates/attestations.jsonl" | jq -cS . | cmp -s - <(jq -cS .attestation <<<"$PGJ") && echo same)" same

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

# A read-only .specify/gates (#122): one warning, no bash "Permission
# denied" leaking from the append, and doctor names the unwritable log.
# Root writes through any mode, so the case cannot be built as root.
if [[ "$(id -u)" -eq 0 ]]; then
    skip "read-only .specify/gates" "running as root, which ignores file modes"
else
    DR="$WORKDIR/readonly"
    project "$DR" "$CUSTOM_TRUE"
    chmod a-w "$DR/.specify/gates"
    RC_R=0
    ERR_R="$(CLAUDE_PROJECT_DIR="$DR" bash "$DR/.specify/gates/verify.sh" --boundary ci 2>&1 >/dev/null)" || RC_R=$?
    expect "read-only gates dir: green gate stays exit 0" "$RC_R" 0
    expect "read-only gates dir: one warning that no evidence was written" \
        "$(grep -c 'left no evidence record' <<<"$ERR_R" || true)" 1
    expect "read-only gates dir: no shell error leaks" \
        "$(grep -c 'Permission denied' <<<"$ERR_R" || true)" 0
    RC_RD=0
    OUT_RD="$(CLAUDE_PROJECT_DIR="$DR" bash "$DR/.specify/gates/doctor.sh" 2>&1)" || RC_RD=$?
    expect "read-only gates dir: doctor fails" "$RC_RD" 1
    expect "read-only gates dir: doctor says attestations cannot be written" \
        "$(grep -c 'attestations cannot be written' <<<"$OUT_RD" || true)" 1
    chmod u+w "$DR/.specify/gates"
fi

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

    # A mise pin that disagrees with the lockfile fails parity naming both
    # sources, and an unreadable mise file fails it naming file:line (#260).
    DM="$WORKDIR/parity-mise"
    project "$DM" "$NONE_PRETTIER"
    printf '# Title\n\nBody.\n' >"$DM/README.md"
    LOCK_PRETTIER="$(jq -r '.packages["node_modules/prettier"].version' "$DM/package-lock.json")"
    printf '[tools]\n"npm:prettier" = "9.9.9"\n' >"$DM/mise.toml"
    RC_MC=0
    MC_OUT="$(CLAUDE_PROJECT_DIR="$DM" bash "$DM/.specify/gates/verify.sh" --boundary ci 2>&1)" || RC_MC=$?
    expect "mise pin conflicting with package-lock.json -> gate fails (exit 2)" "$RC_MC" 2
    expect "the parity report names both sources and versions" \
        "$(grep -cF "parity -- prettier: conflicting pins: package-lock.json pins $LOCK_PRETTIER, mise.toml pins 9.9.9 (pin one version)" <<<"$MC_OUT" || true)" 1
    printf '[tools]\n"npm:prettier" = "%s"\n' "$LOCK_PRETTIER" >"$DM/mise.toml"
    expect "mise pin agreeing with package-lock.json -> parity pass" \
        "$(gate_json "$DM" | jq -r '.attestation.gates[] | select(.name == "parity") | .result')" pass
    printf '[tools]\nprettier = "%s\n' "$LOCK_PRETTIER" >"$DM/mise.toml"
    RC_MB=0
    MB_OUT="$(CLAUDE_PROJECT_DIR="$DM" bash "$DM/.specify/gates/verify.sh" --boundary ci 2>&1)" || RC_MB=$?
    expect "unreadable mise.toml -> gate fails (exit 2)" "$RC_MB" 2
    expect "the parity report names the file and line" \
        "$(grep -cF 'parity -- mise.toml:2: unterminated string' <<<"$MB_OUT" || true)" 1
else
    skip "parity gate checks" "run npm ci to install pinned prettier"
fi

# --- 10b: pin sources (#260): package-lock.json, mise, .tool-versions ---
echo ""
echo "=== pin sources: mise.toml, mise.lock, .tool-versions (#260) ==="
pin_of() { # <tool> <dir> -> the pin gates_pin_version reports
    (source "$REPO_ROOT/extension/runtime/lib/attest.sh" && gates_pin_version "$1" "$2")
}
problems_of() { # <tool> <dir> -> gates_pin_problems' lines, "; "-joined
    (source "$REPO_ROOT/extension/runtime/lib/attest.sh" && gates_pin_problems "$1" "$2") \
        | awk '{ printf "%s%s", sep, $0; sep = "; " }'
}
DS="$WORKDIR/pins"
mkdir -p "$DS"
printf '# pins\nshellcheck 0.10.0\n' >"$DS/.tool-versions"
expect "no mise files: the .tool-versions pin, as before" "$(pin_of shellcheck "$DS")" "0.10.0"
expect "no mise files: no problem" "$(problems_of shellcheck "$DS")" ""
rm -f "$DS/.tool-versions"
cat >"$DS/mise.toml" <<'EOF'
# [tools] in a comment is no table
[env]
NOTE = "a # inside a string [tools]"
[tasks.lint]
run = """
[tools]
shellcheck = "6.6.6"
"""
depends = [
  ["fmt"],
  "check",
]
[tools]   # the tools
shellcheck = "0.11.0"
node = "22"
[settings]
shfmt = "9.9.9"
EOF
expect "mise.toml [tools] string: the pin" "$(pin_of shellcheck "$DS")" "0.11.0"
expect "mise.toml: no problem" "$(problems_of shellcheck "$DS")" ""
expect "mise.toml request that is no exact version pins nothing" "$(pin_of node "$DS")" ""
expect "a key in another table is no pin" "$(pin_of shfmt "$DS")" ""
cat >"$DS/mise.lock" <<'EOF'
# @generated by mise lock
lockfile_version = 2

[[tools.shellcheck]]
version = "0.11.1"
backend = "aqua:koalaman/shellcheck"
specifiers = ["latest"]

[tools.shellcheck."platforms.linux-x64"]
checksum = "sha256:00"
version = "7.7.7"

[[tools.node]]
version = "22.4.1"
EOF
expect "mise.lock's locked version overrides mise.toml" "$(pin_of shellcheck "$DS")" "0.11.1"
expect "mise.lock locks a request mise.toml leaves open" "$(pin_of node "$DS")" "22.4.1"
expect "mise.toml and its mise.lock are one source: no conflict" "$(problems_of shellcheck "$DS")" ""
rm -f "$DS/mise.lock"
printf '[tools]\n"aqua:koalaman/shellcheck" = "0.11.0"\n' >"$DS/mise.toml"
expect "backend-prefixed key: the pin" "$(pin_of shellcheck "$DS")" "0.11.0"
printf "[tools]\nshellcheck = { version = '0.11.0', os = [\"linux\"] }\n" >"$DS/mise.toml"
expect "inline-table value: its version" "$(pin_of shellcheck "$DS")" "0.11.0"
printf '[tools.shellcheck]\nversion = "0.11.0"\n' >"$DS/mise.toml"
expect "[tools.<tool>] table: its version" "$(pin_of shellcheck "$DS")" "0.11.0"
mkdir -p "$DS/.config"
printf '[tools]\nshellcheck = "0.11.0"\n' >"$DS/.config/mise.toml"
rm -f "$DS/mise.toml"
expect ".config/mise.toml is a documented project config" "$(pin_of shellcheck "$DS")" "0.11.0"
rm -rf "$DS/.config"
printf '[tools]\nshellcheck = "0.11.0"\n' >"$DS/mise.toml"
printf 'shellcheck 0.10.0\n' >"$DS/.tool-versions"
expect "mise ranks above .tool-versions" "$(pin_of shellcheck "$DS")" "0.11.0"
expect "mise and .tool-versions disagree: a problem naming both" "$(problems_of shellcheck "$DS")" \
    "shellcheck: conflicting pins: mise.toml pins 0.11.0, .tool-versions pins 0.10.0 (pin one version)"
printf 'shellcheck 0.11.0\n' >"$DS/.tool-versions"
expect "mise and .tool-versions agree: no problem" "$(problems_of shellcheck "$DS")" ""
rm -f "$DS/.tool-versions"
printf '[tools]\nshellcheck = "0.11.0"\n[tools\n' >"$DS/mise.toml"
expect "malformed table header: named as file:line" "$(problems_of shellcheck "$DS")" \
    "mise.toml:3: malformed table header"
printf '[tools]\nshellcheck = "0.11.0\n' >"$DS/mise.toml"
expect "unterminated string: named as file:line" "$(problems_of shellcheck "$DS")" \
    "mise.toml:2: unterminated string"
printf '[tools]\nshellcheck\n' >"$DS/mise.toml"
expect "line without key = value: named as file:line" "$(problems_of shellcheck "$DS")" \
    "mise.toml:2: expected key = value"
printf '[env]\nX = """\nopen\n' >"$DS/mise.toml"
expect "unterminated multi-line string: named at its first line" "$(problems_of shellcheck "$DS")" \
    "mise.toml:2: unterminated multi-line string"
printf '[tools]\nshellcheck = "0.11.0"\n' >"$DS/mise.toml"
printf '[[tools.shellcheck]]\nversion = 11\n' >"$DS/mise.lock"
expect "unreadable mise.lock: named as file:line" "$(problems_of shellcheck "$DS")" \
    "mise.lock:2: shellcheck: version is not a string"
rm -f "$DS/mise.lock" "$DS/mise.toml"
# The npm "shellcheck" package is a downloader wrapper whose version is no
# release of the linter, so package-lock.json pins only the node linters.
printf '{"lockfileVersion":3,"packages":{"node_modules/shellcheck":{"version":"0.5.0"},"node_modules/prettier":{"version":"3.3.3"}}}\n' \
    >"$DS/package-lock.json"
expect "npm shellcheck wrapper alone: no pin" "$(pin_of shellcheck "$DS")" ""
expect "package-lock.json still pins a node linter" "$(pin_of prettier "$DS")" "3.3.3"
printf 'shellcheck 0.11.0\n' >"$DS/.tool-versions"
expect "npm shellcheck wrapper beside .tool-versions: the .tool-versions pin" \
    "$(pin_of shellcheck "$DS")" "0.11.0"
expect "npm shellcheck wrapper beside .tool-versions: no conflict" "$(problems_of shellcheck "$DS")" ""
rm -f "$DS/package-lock.json" "$DS/.tool-versions"

# --- 10c: the npm shellcheck wrapper in node_modules (#274) ---
# Its package.json carries the wrapper's version (0.5.0 here), no release
# of the linter. A shellcheck on PATH other than the wrapper runs and
# is the one versioned; the wrapper runs only without one, and then its
# version is what the binary answers (0.10.0 here), not its package's.
echo ""
echo "=== npm shellcheck wrapper: the binary that runs is versioned (#274) ==="
DW="$WORKDIR/sc-wrapper"
project "$DW" '{ "hooks": { "shellcheck": { "include": ["**/*.sh"], "exclude": [".specify/**"], "orchestrator": "none", "severity": "error" }, "verify-quality": { "orchestrator": "none", "severity": "error" } } }'
rm -f "$DW/node_modules" "$DW/package-lock.json"
mkdir -p "$DW/node_modules/.bin" "$DW/node_modules/shellcheck" "$WORKDIR/sc-real"
printf '{"name":"shellcheck","version":"0.5.0"}\n' >"$DW/node_modules/shellcheck/package.json"
# shellcheck disable=SC2016  # the fakes' own expansions
printf '#!/bin/sh\necho "$*" >>"%s"\n[ "$1" = --version ] && echo "version: 0.10.0"\nexit 0\n' \
    "$WORKDIR/sc-wrapper-ran" >"$DW/node_modules/.bin/shellcheck"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = --version ] && echo "version: 0.11.0"\nexit 0\n' >"$WORKDIR/sc-real/shellcheck"
chmod +x "$DW/node_modules/.bin/shellcheck" "$WORKDIR/sc-real/shellcheck"
printf 'shellcheck 0.11.0\n' >"$DW/.tool-versions"
printf '#!/bin/sh\necho ok\n' >"$DW/ok.sh"
sc_att() { # <PATH>: "<version>|<bin>|<parity result>" from a --json run
    PATH="$1" gate_json "$DW" | jq -r '.attestation.gates
        | "\(.[] | select(.name == "shellcheck") | .version)|\(.[] | select(.name == "shellcheck") | .bin)|\(.[] | select(.name == "parity") | .result)"'
}
rm -f "$WORKDIR/sc-wrapper-ran"
expect "wrapper in node_modules, shellcheck 0.11.0 on PATH: that binary runs, no drift" \
    "$(sc_att "$WORKDIR/sc-real:$PATH")" "0.11.0|shellcheck|pass"
expect "wrapper ahead on PATH (npm scripts): passed over, by full path" \
    "$(sc_att "$DW/node_modules/.bin:$WORKDIR/sc-real:$PATH")" "0.11.0|$WORKDIR/sc-real/shellcheck|pass"
expect "the wrapper never ran" "$([[ -e "$WORKDIR/sc-wrapper-ran" ]] && echo ran || echo idle)" idle
# Wrapper only: PATH holds just the tools the lookup needs.
mkdir -p "$WORKDIR/sc-tools"
for t in grep head; do ln -sf "$(command -v "$t")" "$WORKDIR/sc-tools/$t"; done
sc_lone() { # the resolved binary and its version, with no shellcheck on PATH
    # shellcheck disable=SC2123  # the narrowed PATH is the point
    (source "$REPO_ROOT/extension/runtime/lib/attest.sh" \
        && source "$REPO_ROOT/extension/runtime/lib/formatter-dispatch.sh" \
        && PATH="$WORKDIR/sc-tools" && b="$(_gates_tool_bin shellcheck "$DW")" \
        && printf '%s|%s' "${b#"$DW"/}" "$(gates_tool_version shellcheck "$DW" "$b")")
}
expect "wrapper only: it runs, versioned by its own answer, not package.json" \
    "$(sc_lone)" "node_modules/.bin/shellcheck|0.10.0"

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
# Accept blocks fail closed outside a git work tree (#136).
git init -q "$DS"
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

# --- GATES_POLICY_FILE (#196): ignored at git/ci, applied elsewhere, always reported ---
echo "=== GATES_POLICY_FILE override is reported ==="
DPO="$WORKDIR/policy-override"
project "$DPO" "$CUSTOM_FALSE"
printf '%s' "$CUSTOM_TRUE" >"$WORKDIR/override-policy.json"
for b in git ci; do
    rc=0
    PO_OUT="$(GATES_POLICY_FILE="$WORKDIR/override-policy.json" CLAUDE_PROJECT_DIR="$DPO" \
        bash "$DPO/.specify/gates/verify.sh" --boundary "$b" --json 2>"$WORKDIR/po.err")" || rc=$?
    expect "$b boundary ignores GATES_POLICY_FILE (repository's failing policy enforced)" "$rc" 2
    expect "$b boundary --json reports the ignored override" \
        "$(printf '%s' "$PO_OUT" | jq -r '.policy_override | "\(.file == "'"$WORKDIR/override-policy.json"'"):\(.applied)"')" "true:false"
    expect "$b boundary attestation records the ignored override" \
        "$(printf '%s' "$PO_OUT" | jq -r '.attestation.policy_override.applied')" false
    expect "$b boundary names the override on stderr" \
        "$(grep -c 'is ignored at the '"$b"' boundary' "$WORKDIR/po.err")" 1
done
# #216: a run without --boundary ignores it like git and CI do.
rc=0
PO_OUT="$(GATES_POLICY_FILE="$WORKDIR/override-policy.json" CLAUDE_PROJECT_DIR="$DPO" \
    bash "$DPO/.specify/gates/verify.sh" --json 2>"$WORKDIR/po.err")" || rc=$?
expect "no --boundary ignores GATES_POLICY_FILE (repository's failing policy enforced)" "$rc" 2
expect "no --boundary --json reports unspecified and the ignored override" \
    "$(printf '%s' "$PO_OUT" | jq -r '"\(.boundary):\(.policy_override.applied):\(.attestation.boundary):\(.attestation.policy_override.applied)"')" \
    "unspecified:false:unspecified:false"
expect "no --boundary names the ignored override on stderr" \
    "$(grep -c 'GATES_POLICY_FILE=.* is ignored without --boundary' "$WORKDIR/po.err")" 1
PO_TEXT="$(GATES_POLICY_FILE="$WORKDIR/override-policy.json" CLAUDE_PROJECT_DIR="$DPO" \
    bash "$DPO/.specify/gates/verify.sh" 2>/dev/null || true)"
expect "no --boundary text report names the ignored override" \
    "$(grep -c '^  \[override\] policy -- GATES_POLICY_FILE=.* was ignored without --boundary' <<<"$PO_TEXT")" 1
rc=0
PO_OUT="$(GATES_POLICY_FILE="$WORKDIR/override-policy.json" CLAUDE_PROJECT_DIR="$DPO" \
    bash "$DPO/.specify/gates/verify.sh" --boundary agent --json 2>/dev/null)" || rc=$?
expect "agent boundary applies GATES_POLICY_FILE" "$rc" 0
expect "agent boundary attestation records the applied override and hashes it" \
    "$(printf '%s' "$PO_OUT" | jq -r '"\(.attestation.policy_override.applied):\(.attestation.policy_sha256)"')" \
    "true:$(shasum -a 256 "$WORKDIR/override-policy.json" 2>/dev/null | cut -d' ' -f1 || sha256sum "$WORKDIR/override-policy.json" | cut -d' ' -f1)"
PO_TEXT="$(GATES_POLICY_FILE="$WORKDIR/override-policy.json" CLAUDE_PROJECT_DIR="$DPO" \
    bash "$DPO/.specify/gates/verify.sh" --boundary agent 2>/dev/null || true)"
expect "text report names the applied override" \
    "$(grep -c '^  \[override\] policy -- GATES_POLICY_FILE=.* was enforced' <<<"$PO_TEXT")" 1
expect "no override, no policy_override field" \
    "$(gate_json "$DPO" | jq -r '"\(has("policy_override")):\(.attestation | has("policy_override"))"')" "false:false"

echo ""
echo "$PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
