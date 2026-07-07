# Phase 1 Data Model: Provable Enforcement

Formal schema for the attestation record lives in
[contracts/attestation-record.schema.json](contracts/attestation-record.schema.json);
this document explains the entities, relationships, and rules.

## AttestationRecord

One per `verify.sh` invocation (pass or fail), at any boundary. Compact
single-line JSON in the log; identical object embedded in `--json` output.

| Field             | Type           | Rules                                                                                                      |
| ----------------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `v`               | integer        | Record schema version; `1` for this feature. Consumers must ignore unknown fields (forward compatibility). |
| `ts`              | string         | UTC ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` (R6).                                                                  |
| `boundary`        | string         | `agent` \| `git` \| `ci` \| `unspecified` (matches `--boundary`).                                          |
| `policy_sha256`   | string         | SHA-256 hex of the policy file bytes (R3). Identity, not semantics.                                        |
| `runtime_version` | string \| null | From `.specify/gates/.runtime-version` when present.                                                       |
| `exit`            | integer        | The run's overall exit code (0 green, 2 gate failure).                                                     |
| `gates`           | GateEntry[]    | One entry per evaluated gate, including the synthetic `parity` gate (R7). Order = evaluation order.        |

## GateEntry

| Field        | Type            | Rules                                                                                                                                     |
| ------------ | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `name`       | string          | Gate name (`prettier`, `markdownlint`, `shellcheck`, `custom`, `task-lint`, `task-test`, `parity`, …).                                    |
| `bin`        | string \| null  | Resolved binary path (project-relative when under the project). `null` when skipped/not applicable.                                       |
| `version`    | string \| null  | Detected tool version (R1). `null` when undetectable or not applicable.                                                                   |
| `pinned`     | string \| null  | Pinned version from the lockfile (R2). `null` = no pin source → exempt from parity.                                                       |
| `candidates` | integer \| null | Files matching include globs after excludes. `null` for non-file gates (custom/task/parity).                                              |
| `checked`    | integer \| null | Files the tool actually processed. Same nullability.                                                                                      |
| `result`     | string          | `pass` \| `fail` \| `warn` \| `skipped` \| `planned` (dry-run). A missing tool is `skipped` with `reason`, never `pass` (spec edge case). |
| `reason`     | string          | Empty on pass; failure detail / skip reason otherwise. Never file contents (FR-011).                                                      |
| `duration_s` | integer         | Whole seconds (R6).                                                                                                                       |

### GateEntry invariants

- `result = pass` with `candidates > 0` and `checked = 0` is the
  **suspected no-op** signature: doctor MUST fail on it (FR-004,
  Clarifications). No legitimate instance exists.
- `parity` entry: `result = fail` (severity `error`) or `warn` (severity
  `warning`) when any gate entry has `pinned != null` and
  `version != pinned`; `reason` names each drifted tool with both versions.

## AttestationLog

- Path: `.specify/gates/attestations.jsonl`; one AttestationRecord per line.
- Capped at `attestation.max_records` (default 200): append first, then if
  line count exceeds the cap, rewrite via `tail -n max` + atomic rename
  (R4). Readers never see partial lines.
- Gitignored by default (evidence, not source); committing is a per-project
  choice with no behavioral effect (parity needs no shared log).

## Canary

Not persisted — a Canary is a (probe, expected-rejection) pair executed in a
sandbox. Fixed v1 set (FR-005):

| ID        | Probe                                            | Exercises                   | Expected                |
| --------- | ------------------------------------------------ | --------------------------- | ----------------------- |
| `format`  | Prettier-dirty file in sandbox project           | `verify.sh` format gate     | exit 2, gate `fail`     |
| `shell`   | Script with an SC2086-class finding              | `verify.sh` shellcheck gate | exit 2, gate `fail`     |
| `bash`    | `rm -rf /` tool-call JSON on stdin               | `validate-bash.sh` hook     | exit 2                  |
| `protect` | `.env` edit tool-call JSON on stdin              | `protect-files.sh` hook     | exit 2                  |
| `secret`  | AWS-key-shaped string staged in sandbox git repo | `pre-commit` secret scan    | commit blocked (exit 1) |

Suite result: pass only if **every** canary is rejected; any accepted probe
fails the suite naming the canary and gate (US1). Skipped canaries (tool
genuinely absent in environment) are reported as skipped, and the suite
fails if a canary's required tool is policy-enabled but missing (consistent
with doctor's gap rule).

## Policy `attestation` section (extends policy.json)

```json
"attestation": {
  "enabled": true,
  "max_records": 200,
  "parity": "error"
}
```

| Field         | Type        | Rules                                                                                                             |
| ------------- | ----------- | ----------------------------------------------------------------------------------------------------------------- |
| `enabled`     | boolean     | Default `true`. `false` disables record writing AND the parity gate (canaries unaffected — they need no records). |
| `max_records` | integer ≥ 1 | Default `200`.                                                                                                    |
| `parity`      | string      | `error` \| `warning` \| `off`. Default `error` (Clarifications).                                                  |

Section is optional; absence = all defaults (FR-009). Validated by both
`policy.schema.json` and `gates_validate_policy` (unknown fields rejected,
types enforced — same pattern as the `git` section). User-owned per the
standing policy rules.

## Relationships

```text
policy.json ──(sha256)──> AttestationRecord.policy_sha256
package-lock.json ──(pins, R2)──> GateEntry.pinned
verify.sh run ──(1:1)──> AttestationRecord ──(append+cap)──> AttestationLog
GateEntry(version≠pinned) ──> parity GateEntry(fail|warn)   [same record]
AttestationRecord(latest) ──(no-op signature)──> doctor FAIL
Canary suite ──(reads nothing from, writes nothing to)──> AttestationLog
```
