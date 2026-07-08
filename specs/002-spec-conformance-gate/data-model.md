# Phase 1 Data Model: Spec Conformance Gate

The authoring grammar for accept blocks lives in
[contracts/accept-block.md](contracts/accept-block.md); CLI and policy
surfaces in [contracts/cli-contracts.md](contracts/cli-contracts.md). This
document explains the entities, relationships, and rules.

## AcceptBlock

Parsed from a feature's `tasks.md` (R1). Not persisted — rebuilt on every
run; the parse boundary emits one JSON object per block.

| Field          | Type           | Rules                                                                        |
| -------------- | -------------- | ---------------------------------------------------------------------------- |
| `feature`      | string         | Feature directory name (e.g. `002-spec-conformance-gate`).                   |
| `file`         | string         | Project-relative path of the `tasks.md` it came from.                        |
| `line`         | integer        | 1-based line of the opening fence (parse-error anchoring, FR-005).           |
| `task`         | string         | Text of the nearest preceding task line (association by adjacency).          |
| `task_checked` | boolean        | Checkbox state of that task line.                                            |
| `verifies`     | string \| null | Criterion ID from a leading `# verifies:` comment line; `null` when absent.  |
| `commands`     | string         | The dedented command sequence (interior lines minus the `# verifies:` line). |

### AcceptBlock invariants

- An unterminated fence, a block with no command lines, or a block with no
  preceding task line is a **parse error**, not a skip (FR-005): the `spec`
  gate fails naming `file:line`.
- `commands` never appears in attestations (FR-008 counts/names only).

## FeatureConformance

One per discovered feature per run (R7: direct children of `specs/`
containing `spec.md`, lexicographic order).

| Field             | Type    | Rules                                                                                      |
| ----------------- | ------- | ------------------------------------------------------------------------------------------ |
| `feature`         | string  | Feature directory name.                                                                    |
| `complete`        | boolean | `spec.md` Status field equals `Complete` (R2).                                             |
| `tasks_total`     | integer | Checkbox task lines in `tasks.md`, fence-aware (R3). `0` when `tasks.md` absent.           |
| `tasks_unchecked` | integer | Unchecked among them.                                                                      |
| `blocks_parsed`   | integer | AcceptBlocks successfully parsed.                                                          |
| `blocks_executed` | integer | Blocks actually run this run (complete features always; incomplete only under `--accept`). |
| `blocks_passed`   | integer | Executed blocks with exit 0 and no tree mutation.                                          |
| `blocks_failed`   | integer | Executed blocks that failed (nonzero exit, timeout, or mutation — R4/R5).                  |
| `outcome`         | string  | `enforced-pass` \| `enforced-fail` \| `informational` \| `no-criteria`.                    |

### Outcome rules (FR-004)

| `complete` | Condition                                           | `outcome`       | Effect on run                    |
| ---------- | --------------------------------------------------- | --------------- | -------------------------------- |
| true       | `tasks_unchecked = 0` and `blocks_failed = 0`       | `enforced-pass` | none                             |
| true       | `tasks_unchecked > 0` or `blocks_failed > 0`        | `enforced-fail` | `spec` gate fail/warn (severity) |
| true       | `blocks_parsed = 0`                                 | `no-criteria`   | informational note, never blocks |
| false      | always (parse-only; executed only under `--accept`) | `informational` | never blocks                     |

A parse error in **any** feature (complete or not) fails the `spec` gate
regardless of outcome rules — fail closed precedes classification.

## Block execution result

Per executed block (drives `blocks_passed`/`blocks_failed` and failure
detail):

| Result     | Condition                                       | Reported as                                   |
| ---------- | ----------------------------------------------- | --------------------------------------------- |
| `pass`     | exit 0, no tree delta                           | criterion name only                           |
| `fail`     | nonzero exit                                    | feature, task/criterion, exit code, output    |
| `timeout`  | killed by watchdog (exit 143 after `timeout_s`) | feature, task/criterion, `timeout after <N>s` |
| `mutation` | `git status --porcelain` delta after run (R5)   | feature, task/criterion, changed paths        |

`skipped` is deliberately not a possible result (spec edge case): a missing
tool inside a block is a nonzero exit → `fail`.

## Attestation extension

The AttestationRecord (001 data model) gains:

- a **GateEntry** named `spec` in `gates[]` (synthetic, like `parity`):
  `candidates` = features discovered, `checked` = blocks executed, `result`
  = pass/fail/warn, `reason` names the failing features/criteria, other
  tool fields `null`.
- an optional top-level **`spec` object** (absent when the `spec` gate is
  policy-disabled):

| Field      | Type                 | Rules                                                              |
| ---------- | -------------------- | ------------------------------------------------------------------ |
| `features` | integer              | Features discovered.                                               |
| `parsed`   | integer              | Accept blocks parsed across all features.                          |
| `executed` | integer              | Blocks executed this run.                                          |
| `passed`   | integer              | Executed blocks that passed.                                       |
| `failed`   | integer              | Executed blocks that failed (incl. timeout/mutation).              |
| `results`  | FeatureConformance[] | Per-feature outcomes (fields above minus `commands`-level detail). |

Record schema version stays `v: 1` — the addition is a new optional field,
and 001 consumers must ignore unknown fields (forward compatibility rule).

## Canary (extends 001's fixed set)

| ID     | Probe                                                                                            | Exercises                    | Expected            |
| ------ | ------------------------------------------------------------------------------------------------ | ---------------------------- | ------------------- |
| `spec` | Sandbox feature `900-canary-fixture` with Status `Complete`, one checked task, one `false` block | `verify.sh` `spec` gate (R8) | exit 2, gate `fail` |

Suite semantics unchanged: any accepted probe fails the suite naming the
canary and gate.

## Policy `spec` section (extends policy.json)

```json
"spec": {
  "enabled": true,
  "severity": "error",
  "include": ["*"],
  "exclude": [],
  "timeout_s": 30
}
```

| Field       | Type        | Rules                                                                                    |
| ----------- | ----------- | ---------------------------------------------------------------------------------------- |
| `enabled`   | boolean     | Default `true`. `false` removes the `spec` gate entry and the attestation `spec` object. |
| `severity`  | string      | `error` \| `warning`. Default `error`. Applies to `enforced-fail` and parse errors.      |
| `include`   | string[]    | Feature-directory-name globs to enforce. Default `["*"]`.                                |
| `exclude`   | string[]    | Feature-directory-name globs to skip entirely (not discovered). Default `[]`.            |
| `timeout_s` | integer ≥ 1 | Per-block watchdog seconds (R4). Default `30`.                                           |

Section is optional; absence = all defaults (FR-007). Validated by both
`policy.schema.json` and `gates_validate_policy` (unknown fields rejected,
types enforced — same pattern as the `attestation` section). User-owned per
the standing policy rules.

## Relationships

```text
specs/<feature>/spec.md   ──(Status field, R2)──> FeatureConformance.complete
specs/<feature>/tasks.md  ──(parse, R1/R3)──> AcceptBlock[] + task counts
AcceptBlock ──(execute, R4/R5)──> block result ──> FeatureConformance counts
FeatureConformance[] ──(outcome rules)──> spec GateEntry(pass|fail|warn)
FeatureConformance[] ──(counts only)──> AttestationRecord.spec
verify.sh --accept <f|all> ──(informational execution)──> incomplete features
canary `spec` fixture ──(must be rejected)──> canary suite verdict
```
