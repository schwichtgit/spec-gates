# CLI Contracts: Provable Enforcement

Contracts for the runtime surfaces this feature adds or extends. Existing
behavior not listed here is unchanged; every extension below is
backward-compatible (additive fields, additive flags, unchanged exit-code
meanings).

## `verify.sh` (extended)

```text
verify.sh --boundary agent|git|ci [--json] [--dry-run]
```

- **Unchanged**: flags, exit codes (`0` green, `1` internal error, `2` gate
  failure), human-readable report lines.
- **Added — attestation**: every non-dry run appends one
  [AttestationRecord](attestation-record.schema.json) to
  `.specify/gates/attestations.jsonl` (capped per policy) unless
  `attestation.enabled` is `false`. `--json` output gains a top-level
  `"attestation"` key holding the same object; existing keys
  (`boundary`, `failed`, `warnings`, `gates`) are unchanged.
- **Added — parity gate** (unless `attestation.parity` is `off` or
  attestations disabled): a synthetic gate named `parity` evaluated after
  tool gates. Fails (severity `error`, the default) or warns (`warning`)
  when any tool's detected version differs from its lockfile pin; its
  `reason` names each drifted tool as
  `<tool>: resolved <version>, pinned <pinned> (run npm ci)`.
  Tools with no pin source are exempt (`pinned: null`).
- **Failure to write the log** (permissions, disk): reported as a warning
  on stderr; the gate result is not affected (evidence loss must not mask
  or manufacture a gate outcome).
- **Changed — skipped surfaces**: a policy-enabled tool that is not
  installed is reported as `skipped` (with a reason) in the report,
  `--json` `gates[]`, and the attestation record — never `pass` (spec
  edge case). Additive status value; the entry shape is unchanged.

## `canary.sh` (new, projected alongside `verify.sh`)

```text
canary.sh [--json] [--only <id>[,<id>...]]
```

- Runs the v1 canary set (`format`, `shell`, `bash`, `protect`, `secret` —
  see data-model.md) in disposable sandboxes; never reads or writes user
  project files (FR-006).
- Exit `0`: every executed canary was rejected as expected. Exit `1`: at
  least one canary was **not** rejected (output names each broken canary
  and its gate/hook) or a required tool for a policy-enabled canary is
  missing. Exit `2`: sandbox setup failure (fail closed, FR-006/edge case).
- `--json`: emits `{"canaries":[{"id","expected","outcome","status"}...],`
  `"failed":N}` with `status` ∈ `blocked` (good), `accepted` (broken gate),
  `skipped` (tool absent and not policy-enabled).
- `--only`: comma-separated subset by ID, for targeted diagnostics.

## `doctor.sh` (extended)

- **Added — no-op heuristic**: reads the latest attestation (when the log
  exists); any gate entry with `result=pass`, `candidates>0`, `checked=0`
  is reported as a suspected no-op gate and **fails doctor** (exit 1),
  naming the gate (FR-004, Clarifications).
- **Added — `--canary`**: delegates to `canary.sh`, propagating its exit
  code and output. Without the flag, doctor behavior is unchanged (plus the
  heuristic above).

## `policy.json` (extended, user-owned)

Optional `attestation` section — defaults apply when absent (FR-009):

```json
"attestation": { "enabled": true, "max_records": 200, "parity": "error" }
```

Validated by `policy.schema.json` and `gates_validate_policy`: unknown
fields rejected; `enabled` boolean; `max_records` integer ≥ 1; `parity` ∈
`error|warning|off`. Seeded with explicit defaults in
`policy-template.json` (strict JSON has no comments); `init` seeds,
`upgrade` never overwrites (standing rule).

## CI templates (extended)

`extension/ci/github/gates.yml` and this repo's `.github/workflows/ci.yml`
gain one step after the gate run:

```yaml
- name: Prove the gate still blocks (canaries)
  run: bash .specify/gates/canary.sh
```

GitLab/Jenkins templates gain the equivalent line. A red canary step means
a broken gate, not a dirty tree — the step's name says so.

## Compatibility statement

Projects that never adopt the new policy section get: attestations on with
defaults, parity at `error`, canaries available but only run where wired
(doctor/CI). Existing `--json` consumers keep working (additive key).
Records carry `v: 1`; any future breaking change increments `v` and
consumers must ignore unknown fields.
