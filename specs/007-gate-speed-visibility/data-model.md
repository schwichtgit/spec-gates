# Data Model: Gate Speed and Visibility

Entities from [spec.md](spec.md), shapes from [research.md](research.md).
Policy keys: [contracts/policy-cover.md](contracts/policy-cover.md). Report,
attestation, timeline and progress: [contracts/report-timeline.md](contracts/report-timeline.md).

## Covering declaration (`spec.cover`)

| Field       | Type                   | Required | Default | Rule                                                        |
| ----------- | ---------------------- | -------- | ------- | ----------------------------------------------------------- |
| `script`    | string                 | yes      |         | project-relative, no `..` segment, not absolute; must exist |
| `at`        | list of `agent`, `git` | yes      |         | non-empty, unique, never `ci`                               |
| `timeout_s` | integer 1 to 300       | no       | 30      | per block                                                   |

The `script` path is protected at every boundary (R4).

## Block entry (attestation, per feature result)

| Field           | Type                                             | Notes                                      |
| --------------- | ------------------------------------------------ | ------------------------------------------ |
| `task`          | string                                           | `T###` from the task line, or `-`          |
| `verifies`      | string or null                                   | the block's `# verifies:` label            |
| `result`        | `pass`, `fail`, `timeout`, `mutation`, `covered` |                                            |
| `reason`        | string                                           | fixed runtime string, or the script's line |
| `declared_skip` | `agent` or `git`                                 | only for `covered`                         |
| `duration_s`    | integer, 0 or more                               | for `covered`, the time spent asking       |

Feature results gain `blocks_covered`; `blocks_executed` counts blocks run,
so `blocks_parsed = blocks_executed + blocks_covered` for an enforced
feature.

## Block lifecycle in one run

```text
parsed --(boundary not in cover.at, or no cover)--> run --> pass | fail | timeout | mutation
parsed --(boundary in cover.at)--> ask script --> covered (exit 0, one line)
                                             \--> run (anything else)  --> pass | fail | ...
```

At `ci` the left branch always applies.

## Timeline line

`<name>\t<boundary>\t<start>\t<end>\t<result>\t<reason>`; one per ended gate
or block. Block names: `accept <feature> <task-id>`.

## Progress line

`gates: <HH:MM:SS> start <name>` and
`gates: <HH:MM:SS> end <name> <result> <n>s`; one per start and end.
