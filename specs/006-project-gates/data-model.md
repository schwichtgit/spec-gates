# Data Model: Project Gates per Boundary

Entities from [spec.md](spec.md), shapes decided in
[research.md](research.md). Policy keys are specified in
[contracts/policy-gates.md](contracts/policy-gates.md); report and
attestation shapes in [contracts/verify-report.md](contracts/verify-report.md).

## Project gate

A named check the project declares under `hooks.verify-quality.gates`.

| Field       | Type                         | Required | Default                       | Rule                                                   |
| ----------- | ---------------------------- | -------- | ----------------------------- | ------------------------------------------------------ |
| (key)       | string                       | yes      |                               | `^[a-z0-9][a-z0-9_-]{0,39}$`, not a reserved name (R2) |
| `command`   | string                       | yes      |                               | non-empty; run with `sh -c` from the project root      |
| `severity`  | `error` / `warning` / `info` | no       | `error`                       | maps a non-zero exit to fail / warn / warn             |
| `timeout_s` | integer 1 to 86400           | no       | `gate_timeout_s`, else 600    | exceeding it fails the gate                            |
| `skip_at`   | list of `agent`, `git`       | no       | none (runs at every boundary) | non-empty, no duplicates, never `ci`                   |

Relationships: belongs to the `verify-quality` hook; runs after the
orchestrator's gates, in key order. Merged per key with a baseline policy's
gates (feature 003).

## Boundary skip declaration

The statement "item X does not run at boundary Y". For a project gate it is
the gate's `skip_at`; feature 007 attaches the same declaration to accept
blocks. Evaluated by one function, reported in one shape:

- **Evaluation**: at boundary `b`, the item is skipped when `b` is in its
  `skip_at`. At `ci` and at `none` (no `--boundary`) nothing is skipped.
- **Report**: result `skipped`, reason `skipped by declaration at <b>`,
  attestation field `declared_skip: "<b>"`. Never counted as passed; never
  counted toward `failed` or `warnings`.

## Gate set of a boundary

Derived, not stored: every declared project gate, minus those whose
`skip_at` names the boundary. CI's gate set is always the full set. The
parity gate compares it with the gates the run actually ran (R7).

## Gate entry (attestation), extended

The existing `gateEntry` (feature 001 contract) gains one optional field:

| Field           | Type            | When present                                               |
| --------------- | --------------- | ---------------------------------------------------------- |
| `declared_skip` | `agent` / `git` | the gate was skipped by a declaration naming this boundary |

Project gates carry `bin`, `version`, `pinned`, `candidates` and `checked`
as `null` (they are commands, not resolved tools). Results stay
`pass`, `fail`, `warn`, `skipped`, `planned`.

## Policy-wide settings (verify-quality hook)

| Key              | Type                         | Default   | Meaning                                     |
| ---------------- | ---------------------------- | --------- | ------------------------------------------- |
| `gate_timeout_s` | integer 1 to 86400           | 600       | time limit for project gates without one    |
| `test_severity`  | `error` / `warning` / `info` | `warning` | severity of `task test` (task orchestrator) |

## State transitions of a project gate in one run

```text
declared --(boundary in skip_at)--> skipped (declared_skip)
declared --(runs)--> exit 0 ------------------> pass
                 \--> exit non-zero, error ---> fail
                 \--> exit non-zero, other ---> warn
                 \--> exit 126/127 -----------> fail (command not found or not executable)
                 \--> over its time limit ----> fail (timeout after <n>s [at load <x>])
```

`--dry-run` records every declared gate as `planned`, skipped ones included,
with the skip named in the detail.
