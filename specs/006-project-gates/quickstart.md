# Quickstart: validating project gates per boundary

Runnable checks that the feature works end to end. Keys are in
[contracts/policy-gates.md](contracts/policy-gates.md); output shapes in
[contracts/verify-report.md](contracts/verify-report.md).

## Prerequisites

- A scratch git repository with the 0.5.0 runtime projected
  (`.specify/gates/`), jq, bash.
- A policy with the built-in walk enabled for Markdown (prettier and
  markdownlint include `**/*.md`) and one clean `README.md`.

## 1. Project gates run next to the built-in walk (Story 1)

Add to `hooks.verify-quality`:

```json
"gates": {
  "ok": { "command": "true" },
  "bad": { "command": "echo '##gates-fail## bad gate failed'; exit 1" },
  "soft": { "command": "exit 1", "severity": "warning" }
}
```

Run `bash .specify/gates/verify.sh --boundary git`.

Expected: exit 1; the report lists `prettier`, `markdownlint`, `ok` (pass),
`bad` (fail, `-- bad gate failed`), `soft` (warn); `failed=1 warnings=1`;
the last line of `.specify/gates/attestations.jsonl` has entries for `ok`,
`bad` and `soft`.

## 2. Time limit and a missing command (Story 1)

```json
"gates": {
  "slow": { "command": "sleep 30", "timeout_s": 2 },
  "gone": { "command": "no-such-command-xyz" }
}
```

Expected: `slow` fails within about 5 s with `timeout after 2s`; no `sleep`
from it is left running; `gone` fails with `command not found or not
executable`.

## 3. Refused policies (Stories 1 and 2)

Each of these makes `verify.sh` exit 2 naming the key: a gate named
`spec`; `"skip_at": ["ci"]`; `"skip_at": []`; a gate without `command`;
`"gates"` under `hooks.prettier`.

## 4. Skipping the agent boundary, never CI (Story 2)

```json
"gates": {
  "build": { "command": "echo \"boundary=$GATES_BOUNDARY\"; exit 1", "skip_at": ["agent"] }
}
```

- `verify.sh --boundary agent`: exit 0; the report shows
  `[skipped] build -- skipped by declaration at agent`; `--json` shows the
  same; the attestation entry has `"declared_skip": "agent"`; `parity`
  passes.
- `verify.sh --boundary git` and `--boundary ci`: exit 1; `build` fails and
  its output shows `boundary=git` / `boundary=ci`.
- `doctor.sh`: lists
  `gate build (error, 600s): skipped at agent by declaration`.

## 5. Parity catches a gate CI did not run (Story 2)

Run the parity check against a run in which a declared gate is missing at
CI (the test suite does this by feeding parity a gate list without it).
Expected: `[fail] parity -- declared gates not run at ci: build`.

## 6. The documented walk from a custom command (Story 3)

Set `"orchestrator": "custom"` and
`"custom_command": "bash .specify/gates/verify.sh --walk"`; add a
badly formatted `bad.md`.

Expected: `verify.sh --boundary git` fails the `custom` gate, whose summary
names `bad.md`; the walk wrote no attestation line of its own. With
`custom_command` calling `.specify/gates/lib/formatter-dispatch.sh`
instead, `doctor.sh` prints the `[rec]` for `--walk`.

## 7. `task test` severity (Story 4)

In a project with a Taskfile whose `test` task fails: with
`"orchestrator": "task"` the run warns (exit 0); with
`"test_severity": "error"` added, it fails (exit 1).

## 8. Backward compatibility and the canary

- A 0.4.2 policy (no new keys): the same gate list and results as 0.4.2.
- `bash .specify/gates/canary.sh`: 17 run, 17 blocked, including
  `project`.
