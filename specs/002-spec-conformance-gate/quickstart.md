# Quickstart Validation: Spec Conformance Gate

Runnable scenarios proving the feature end-to-end, mapped to the spec's
success criteria. Same doctrine as 001's quickstart: nothing counts as
verified until it has blocked (or passed) for real.

**Prerequisites**: repo checkout with the runtime projected
(`.specify/gates/` present), `jq`, `npm ci` done (pinned linters), macOS
`/bin/bash` 3.2 or Linux bash. Scenario 3 builds a disposable fixture
project in `mktemp -d` — no repo files are touched.

## Scenario 1 — Normal run while 002 is in progress (US1/US2, FR-004)

```sh
bash .specify/gates/verify.sh --boundary agent
```

**Expected**: exit 0. The report contains a `spec` gate `pass` entry and an
informational line for each discovered feature, e.g.
`spec: 002-spec-conformance-gate — N criteria parsed, not enforced (Status: Draft)`.
Nothing executed (001 and 002 are both incomplete), so the run cost is
discovery + parse only.

## Scenario 2 — On-demand execution of an incomplete feature (US1)

```sh
bash .specify/gates/verify.sh --boundary agent --accept 002-spec-conformance-gate
```

**Expected**: exit code unchanged from Scenario 1; per-criterion
informational results for 002's accept blocks (pass/fail per criterion,
named). While 002 is mid-implementation some criteria fail — visibly,
without blocking.

## Scenario 3 — Enforcement on a complete fixture (SC-001, SC-002)

Build a disposable fixture project (pattern from `tests/test-spec-gate.sh`)
with one feature whose `spec.md` says `**Status**: Complete` and whose
`tasks.md` has one checked task carrying one passing accept block.

```sh
bash .specify/gates/verify.sh --boundary agent   # inside the fixture
```

**Expected**: exit 0; `spec` gate `pass`.

Then, in the fixture:

1. Change the block's command to `false` → rerun → **exit 2**, `spec` gate
   `fail` naming the feature, the criterion, and exit code 1 (SC-001).
2. Restore the block; uncheck the task (`- [x]` → `- [ ]`) → rerun →
   **exit 2** naming the unchecked task (SC-002).
3. Restore; make the block `touch mutated.txt` → rerun → **exit 2** naming
   the mutation and path (FR-006); confirm `mutated.txt` was not reverted.
4. Restore; make the block `sleep 60` with `"timeout_s": 2` in the fixture
   policy → rerun → **exit 2** naming `timeout after 2s` (FR-003).
5. Remove the closing fence of the block → rerun → `spec` gate fails naming
   `tasks.md:<line>` (FR-005); doctor in the fixture also exits 1 on it.

## Scenario 4 — The spec gate proves itself (SC-003)

```sh
bash .specify/gates/doctor.sh --canary --only spec
```

**Expected**: `spec` canary `blocked` (the Complete-fixture-with-`false`
probe was rejected), suite exit 0. Then stub the accept-block runner in a
sandboxed runtime copy (pattern from `tests/test-canary.sh`) and rerun:
suite **exit 1** naming the spec gate.

## Scenario 5 — Overhead budgets (SC-004)

```sh
time bash .specify/gates/verify.sh --boundary agent          # parse-only cost
```

**Expected**: the delta versus a run with `spec.enabled: false` is ≤ 1s
while no blocks execute. Once 002 is Complete (Scenario 6), the full run
including its executed blocks stays ≤ 30s.

## Scenario 6 — Dogfood closure (SC-005)

After `/speckit-implement` finishes and every task is checked:

1. Flip `specs/002-spec-conformance-gate/spec.md` to `**Status**: Complete`.
2. `bash .specify/gates/verify.sh --boundary agent` → exit 0 with 002
   `enforced-pass`: the feature's own accept blocks are now enforced by the
   gate they shipped.
3. `jq '.spec' .specify/gates/attestations.jsonl | tail -n 1` (or the
   `--json` run's attestation) shows the `spec` object with non-zero
   `executed`/`passed` and 002's `enforced-pass` result (FR-008).

## Scenario 7 — Suites and self-gate stay green (SC-006)

```sh
bash tests/run.sh
```

**Expected**: all suites pass, including the new `test-spec-gate.sh` and
the extended `test-canary.sh`, on macOS/BSD and in CI (ubuntu/GNU). CI on
the PR must be green with the `spec` gate active.
