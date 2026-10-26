# Contract: project gate policy keys

Keys added to `hooks.verify-quality` in `.specify/gates/policy.json`. A
policy without them behaves exactly as in 0.4.x (FR-015).

## Example

```json
{
  "hooks": {
    "verify-quality": {
      "orchestrator": "none",
      "severity": "error",
      "gate_timeout_s": 900,
      "gates": {
        "lint": { "command": "npm run -s lint" },
        "typecheck": { "command": "npm run -s typecheck" },
        "test": { "command": "npm test -- --coverage", "timeout_s": 1200 },
        "build": { "command": "npm run -s build", "skip_at": ["agent"] },
        "manifest": {
          "command": "scripts/validate-manifest.sh",
          "severity": "warning",
          "skip_at": ["agent", "git"]
        }
      }
    }
  }
}
```

For the `task` orchestrator, `"test_severity": "error"` makes a failing
`task test` fail the run (default `warning`).

## Keys

| Key                      | Type                         | Default   | Notes                                            |
| ------------------------ | ---------------------------- | --------- | ------------------------------------------------ |
| `gates`                  | object                       | absent    | key = gate name; order of keys = run order       |
| `gates.<name>.command`   | string, non-empty            | required  | run as `sh -c "<command>"` from the project root |
| `gates.<name>.severity`  | `error` / `warning` / `info` | `error`   |                                                  |
| `gates.<name>.timeout_s` | integer, 1 to 86400          | see below | seconds                                          |
| `gates.<name>.skip_at`   | array of `agent`, `git`      | absent    | non-empty, unique; `ci` is never accepted        |
| `gate_timeout_s`         | integer, 1 to 86400          | 600       | default limit for gates without `timeout_s`      |
| `test_severity`          | `error` / `warning` / `info` | `warning` | `task` orchestrator only                         |

`gates`, `gate_timeout_s` and `test_severity` are accepted only under the
`verify-quality` hook.

## Validation (refused, exit 1, naming the key; no gate runs)

- a gate name outside `^[a-z0-9][a-z0-9_-]{0,39}$`;
- a reserved gate name: `prettier`, `markdownlint`, `shellcheck`,
  `task-lint`, `task-test`, `custom`, `spec`, `contract`, `parity`,
  `policy`, `lock`, `constitution`;
- a gate without `command`, or an empty one;
- an unknown key inside a gate;
- `skip_at` empty, with duplicates, or with any value other than `agent`
  and `git` (`ci` is refused with "CI runs the full policy (constitution,
  Principle III)");
- a `timeout_s` or `gate_timeout_s` that is not an integer in range;
- `gates`, `gate_timeout_s` or `test_severity` under any hook other than
  `verify-quality`.

## Environment for gate commands

Every gate command, the `task` and `custom` steps, and the built-in walk see
`GATES_BOUNDARY` set to `agent`, `git`, `ci`, or `none` (verify.sh run
without `--boundary`). At `none`, no `skip_at` applies.

## Policy contract (feature 003)

With a baseline (`extends`), gates merge per name. Deviation classes:

| Change in the effective policy vs the baseline       | Class                      |
| ---------------------------------------------------- | -------------------------- |
| a baseline gate is missing                           | weakened (removed)         |
| a gate's `skip_at` gains a boundary                  | weakened                   |
| a gate's `skip_at` loses a boundary                  | strengthened               |
| a gate's `severity` or `test_severity` moves right   | weakened                   |
| a gate's `command`, `timeout_s`, or `gate_timeout_s` | changed                    |
| a gate the baseline does not have                    | addition (not a deviation) |
