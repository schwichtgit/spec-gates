# Contract: covering policy keys

Added to the `spec` section of `.specify/gates/policy.json`. Absent means
every accept block runs, as before.

```json
"spec": {
  "severity": "error",
  "cover": {
    "script": "scripts/accept-covered.sh",
    "at": ["agent", "git"],
    "timeout_s": 30
  }
}
```

## The script's interface

```text
<script> <feature> <task-id> <block-file>
```

- Run from the project root, with `GATES_BOUNDARY` set, under `timeout_s`.
- `<feature>`: the feature directory name (`006-project-gates`).
- `<task-id>`: the `T###` opening the task line, or `-`.
- `<block-file>`: a file holding the block's commands, readable for the
  duration of the call.
- **Covered**: exit 0 and exactly one non-empty line on stdout. The line
  is the reason (cut to 200 characters, control characters removed).
- **Not covered**: anything else; the block runs. Stderr is discarded. The
  script can never fail a block.

## Validation (refused, exit 1, no gate runs)

- `script` missing, empty, absolute, or containing a `..` segment;
- `at` missing, empty, with duplicates, or with a value other than `agent`
  and `git`; `ci` is refused with "CI runs the full policy (constitution,
  Principle III)";
- `timeout_s` not an integer from 1 to 300;
- an unknown key inside `cover`;
- at run time (verify.sh, not the validator): `script` not a regular file
  inside the project.

## Protection

The `script` path is protected like `policy.json`, whatever
`protected_files.extra` says. A commit or pull request that changes it needs
`Protected-Change: <path>` and `Approved-By: <name>`, and the agent hooks
treat it as protected.

## Policy contract (feature 003)

| Change in the effective policy vs the baseline | Class                  |
| ---------------------------------------------- | ---------------------- |
| `spec.cover` added                             | weakened (cover added) |
| `spec.cover.at` gains a boundary               | weakened               |
| `spec.cover.at` loses a boundary               | strengthened           |
| `spec.cover.script` or `timeout_s` changes     | changed                |
| `spec.cover` removed                           | strengthened           |
