# CLI Contracts: Spec Conformance Gate

Contracts for the runtime surfaces this feature adds or extends. Existing
behavior not listed here is unchanged; every extension below is
backward-compatible (additive fields, additive flags, unchanged exit-code
meanings).

## `verify.sh` (extended)

```text
verify.sh --boundary agent|git|ci [--json] [--dry-run] [--accept <feature|all>]
```

- **Unchanged**: existing flags, exit codes (`0` green, `1` internal error,
  `2` gate failure), human-readable report lines, attestation and parity
  behavior from 001.
- **Added — `spec` gate** (unless `spec.enabled` is `false`): a synthetic
  gate named `spec` evaluated after the tool gates and before `parity`.
  Per run it discovers features (direct children of `specs/` containing
  `spec.md`, minus `spec.exclude` globs), parses accept blocks from each
  `tasks.md`, and:
  - **parse error anywhere** → gate fails (at `spec.severity`) naming
    `file:line` for each error;
  - **complete features** (spec.md `**Status**: Complete`, matching
    `spec.include`) → executes their blocks; any unchecked task or failed
    block → gate fails (at `spec.severity`) naming feature, task/criterion,
    and cause (exit code, `timeout after <N>s`, or mutated paths);
  - **incomplete features** → parse-only; one informational report line
    (`spec: <feature> — N criteria parsed, not enforced (Status: <value>)`).
  - **no `specs/` directory** → gate passes with zero features (FR-011).
- **Added — `--accept <feature|all>`**: additionally executes accept blocks
  of the named incomplete feature(s) and prints per-criterion results as
  informational output. Never changes the exit code for incomplete
  features; complete features are enforced as always. Unknown feature name
  → exit 1 (internal error class) naming the available features.
- **`--dry-run`**: the `spec` gate reports `planned` like other gates; no
  discovery side effects to plan, so the entry is the gate name only.
- **Recursion guard**: block execution exports `GATES_SPEC_EXEC=1`; a
  `verify.sh` run that sees this variable skips the `spec` gate class
  entirely (no entry, no attestation `spec` object). An accept block that
  invokes `verify.sh` therefore cannot re-enter accept-block execution.
- **`--json`**: `gates[]` gains the `spec` GateEntry; the top-level
  attestation object gains the `spec` object (see data-model.md). Existing
  keys unchanged.

## `doctor.sh` (extended)

- **Added — discovery report** (normal run): a `spec gate` section printing
  features discovered, accept blocks parsed, and how many features are
  complete (under enforcement). Zero features is `[ok]` (trivial pass,
  FR-011).
- **Added — parse-error failure**: any accept-block parse error fails
  doctor (exit 1) naming `file:line` — same class as a required-tool gap.
- **Added — completion nudge**: a feature with every task checked but
  Status ≠ `Complete` prints a `[rec]` line suggesting the Status flip
  (informational, never fails).

## `canary.sh` (extended)

```text
canary.sh [--json] [--only <id>[,<id>...]]
```

- Canary set gains `spec` (see data-model.md): a sandbox feature
  `900-canary-fixture` marked Complete with a `false` accept block must be
  rejected by the sandboxed `verify.sh` run. Not rejected → suite exit 1
  naming the spec gate. `--only spec` selects it; `--json` shape unchanged
  (one more element in `canaries[]`).

## `policy.json` (extended, user-owned)

Optional `spec` section — defaults apply when absent (FR-007):

```json
"spec": {
  "enabled": true,
  "severity": "error",
  "include": ["*"],
  "exclude": [],
  "timeout_s": 30
}
```

Validated by `policy.schema.json` and `gates_validate_policy`: unknown
fields rejected; `enabled` boolean; `severity` ∈ `error|warning`;
`include`/`exclude` arrays of strings; `timeout_s` integer ≥ 1. Seeded with
explicit defaults in `policy-template.json`; `init` seeds, `upgrade` never
overwrites (standing rule).

## Attestation record (extended, `v: 1` unchanged)

- `gates[]` gains a synthetic `spec` GateEntry (`candidates` = features
  discovered, `checked` = blocks executed, tool fields `null`).
- Top-level optional `spec` object: `features`, `parsed`, `executed`,
  `passed`, `failed`, `results[]` (per-feature outcomes). Absent when the
  gate is policy-disabled. Additive optional field — 001's forward
  compatibility rule (consumers ignore unknown fields) makes this a
  non-breaking `v: 1` extension; `attestation-record.schema.json` (001
  contract) gains the optional property.

## CI templates (unchanged)

The `spec` gate rides inside `verify.sh`, which every CI template already
runs — no template change. (001's canary step automatically covers the new
`spec` canary since it runs the whole suite.)

## Compatibility statement

Projects that never adopt the new policy section get: `spec` gate on at
`error`, all features included, 30s block timeout — which is a no-op until
a feature directory contains accept blocks AND its spec is marked
`Complete`. Repositories without `specs/` see a trivially passing gate
entry and a zero-count `spec` attestation object. Existing `--json`
consumers keep working (additive key). Feature 001's `tasks.md` gains no
accept blocks in this feature (spec Assumptions); its Status remains
`Draft`, so it stays informational.
