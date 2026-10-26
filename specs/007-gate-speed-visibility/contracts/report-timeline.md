# Contract: report, attestation, timeline and progress

## Text report

A covered block of an enforced feature:

```text
spec: 006-project-gates: "FR-001, FR-002" -- covered: go test ./pkg/gates passed in this run (task test)
```

The spec gate's summary counts covered blocks apart from passed ones:

```text
  [pass] spec -- 6 features, 28 blocks: 25 passed, 3 covered at git: 006-project-gates T014#1, 006-project-gates T014#2, 007-gate-speed-visibility T009#1
```

With nothing covered, the report is unchanged.

## `--json`

The `spec` gate's entry is unchanged in shape; its `detail` is the summary
above, so it names every covered block (constitution, Principle III). The
attestation (below) lists them with their reasons.

## Attestation (`spec.results[]`)

```json
{
  "feature": "006-project-gates",
  "blocks_parsed": 7,
  "blocks_executed": 6,
  "blocks_passed": 6,
  "blocks_failed": 0,
  "blocks_covered": 1,
  "blocks": [
    {
      "task": "T014",
      "ordinal": 1,
      "verifies": "FR-001, FR-002",
      "result": "covered",
      "reason": "go test ./pkg/gates passed in this run (task test)",
      "declared_skip": "git",
      "duration_s": 0
    },
    {
      "task": "T024",
      "ordinal": 1,
      "verifies": "FR-007, FR-008, FR-010",
      "result": "pass",
      "reason": "",
      "duration_s": 4
    }
  ]
}
```

`result`: `pass`, `fail`, `timeout`, `mutation`, `covered`. The feature 001
attestation schema gains `blocks_covered` and `blocks[]` as optional
properties.

## Parity

At `ci`, any `covered` block fails parity:
`accept blocks covered at ci: 006-project-gates T014#1`.

## Timeline (`GATES_TIMELINE=<file>`)

One line per ended gate or block, appended as it ends; `<TAB>` stands for a
tab character:

```text
prettier<TAB>git<TAB>1793001200<TAB>1793001203<TAB>pass
accept 006-project-gates T014#1<TAB>git<TAB>1793001210<TAB>1793001210<TAB>covered<TAB>go test ./pkg/gates passed in this run (task test)
lint<TAB>git<TAB>1793001203<TAB>1793001240<TAB>fail<TAB>check failed
spec<TAB>git<TAB>1793001205<TAB>1793001262<TAB>pass
```

Fields: name, boundary, start, end (epoch seconds), result, reason (fixed
runtime strings, or a covered block's reason; never output). A CI step can
render sections from it, for example GitLab
`section_start:<start>:<name>` / `section_end:<end>:<name>` markers.

## Progress (`GATES_PROGRESS=<file>`)

```text
gates: 14:20:01 start prettier
gates: 14:20:03 end prettier pass 2s
gates: 14:20:05 start accept 006-project-gates T014#1
gates: 14:20:05 end accept 006-project-gates T014#1 covered 0s
```

The pre-commit hook sets `GATES_PROGRESS=/dev/stderr` when its stderr is a
terminal and the variable is unset, so a commit shows these lines live.

Both variables belong to the run they are given to: `verify.sh` reads them
once and unsets them for the commands it starts, so nested runs (fixtures,
sandboxes, accept blocks) never write to them.

## Unwritable timeline or progress file

One warning (`gates: warning: cannot write <file>; no further timeline lines
this run`), the file disabled for the rest of the run, outcomes unchanged.
