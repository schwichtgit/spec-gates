# Quickstart: validating gate speed and visibility

Runnable checks that the feature works end to end. Keys are in
[contracts/policy-cover.md](contracts/policy-cover.md); output shapes in
[contracts/report-timeline.md](contracts/report-timeline.md).

## Prerequisites

- A scratch project from `tests/lib/fixture.sh` `fx_gates_project` (the
  0.5.0 runtime projected), with `.specify/gates/.runtime-version` written
  so doctor sees a projected runtime.
- A Complete feature `specs/900-demo/` whose `tasks.md` has one checked
  task `T001` with an accept block that fails (`false`), and a second
  checked task `T002` whose block passes (`true`).
- Every hook in the policy has `severity` (accept-block policies need it).

## 1. Covered at git, run at CI (Stories 1, 3)

`scripts/cover.sh`:

```sh
#!/bin/sh
[ "$2" = T001 ] && { echo "proven by the test gate"; exit 0; }
exit 1
```

Policy `spec.cover`: `{"script": "scripts/cover.sh", "at": ["agent", "git"]}`.

- `verify.sh --boundary git`: exit 0; the report shows
  `spec: 900-demo: "T001 ..." -- covered: proven by the test gate`; the
  attestation's `spec.results[0].blocks` has T001 `covered` with
  `declared_skip: "git"` and T002 `pass`; `blocks_covered` is 1.
- `verify.sh --boundary ci`: exit 2; T001 runs and fails; the script was
  not called (make it touch a file: the file must not exist).

## 2. Anything but one line runs the block (Story 1)

Replace the script's answer in turn with: `exit 1`; `exit 0` and no output;
two lines; `sleep 60` with `"timeout_s": 2`; and make the file
non-executable. Each time, `verify.sh --boundary git` runs T001 and exits 2.
The `sleep` case ends within 7 seconds and leaves no `sleep` running.

## 3. Refused policies (Stories 1, 2)

Each makes `verify.sh` exit 1 naming the key: `"at": ["ci"]` (naming
Principle III); `"at": []`; `"script": "/etc/x"`; `"script": "../x"`;
`"timeout_s": 0`; and, at run time, a `script` that does not exist.

## 4. The script is protected (Story 2)

In a git repository with the policy committed: change `scripts/cover.sh`
and commit without trailers: refused by commit-msg. With
`Protected-Change: scripts/cover.sh` and `Approved-By: <name>`: accepted.
`pr-check.sh --range <base>..HEAD` refuses the undeclared change the same
way.

## 5. Parity and the canary (Story 3)

- The test suite feeds the parity check a CI run with a `covered` block:
  `[fail] parity -- accept blocks covered at ci: 900-demo T001`.
- `bash .specify/gates/canary.sh`: 18 run, 18 blocked, including `covered`.

## 6. Timings, timeline, progress (Stories 4, 5)

Make T002's block `sleep 2`.

- With `GATES_TIMELINE=$PWD/t.tsv GATES_PROGRESS=$PWD/p.txt`, run
  `verify.sh --boundary git`: `t.tsv` has a line per gate and one per block, with
  `accept 900-demo T002` lasting about 2 seconds; `p.txt` has a `start` and
  an `end` line for each; the attestation's T002 entry has `duration_s`
  of 2 or 3.
- `GATES_TIMELINE=/nonexistent/t.tsv verify.sh --boundary git`: one warning,
  the same exit code as without it.
- In a terminal, `git commit` in the project shows
  `gates: HH:MM:SS start ...` lines while pre-commit runs; `git commit ... 2>log` shows none in
  `log` beyond today's output.

## 7. Backward compatibility

A policy without `spec.cover`, with neither variable set: the same report and
exit code as 0.5.0 without this feature; `canary.sh` reports 18/18.
