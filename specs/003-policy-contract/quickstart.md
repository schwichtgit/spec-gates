# Quickstart Validation: Policy as Versioned Contract

Runnable scenarios proving the feature end-to-end, mapped to the spec's
success criteria. Same doctrine as 001/002: nothing counts as verified
until it has blocked (or passed) for real. All scenarios use a **local
fixture baseline repo** (plain-path git remote in `mktemp -d`) — no
network, no repo files touched outside the fixtures.

**Prerequisites**: repo checkout with the runtime projected, `jq`, `git`.

## Scenario 1 — Adopt a baseline, provably (US1, SC-001)

Create a fixture baseline repo (a `policy.json` + a `v1.0.0` tag) and a
fixture consumer whose `policy.json` declares `extends` at `v1.0.0`.

```sh
bash .specify/gates/contract.sh sync          # inside the consumer fixture
bash .specify/gates/verify.sh --boundary agent
```

**Expected**: sync writes `baseline.json`, `baseline.lock.json`,
`policy.effective.json` (all `jq -S` canonical); verify exits 0 with a
`contract` gate `pass`; gate results reflect the merged policy (a rule only
the baseline enables is enforced in the consumer).

## Scenario 2 — Drift is blocked at the next run (US1, SC-002)

In the synced consumer, in turn:

1. Hand-edit `policy.effective.json` → verify → **exit 2**,
   `contract: effective policy drifted`.
2. Restore; hand-edit `baseline.json` → verify → **exit 2**, snapshot/pin
   digest mismatch named.
3. Restore; change `extends.version` in `policy.json` without syncing →
   verify → **exit 2**, declaration-vs-pin mismatch named.
4. Delete `baseline.lock.json` → verify → **exit 2**, `not synced` naming
   the missing file; `doctor` exits 1 on the same conditions.

## Scenario 3 — Deviations are visible, never blocking (US1, FR-006)

Set the consumer overlay to weaken one rule (baseline severity `error` →
overlay `warning`) and add one unrelated rule; re-sync; run verify.

**Expected**: exit 0; output carries
`contract: deviation (weakened): hooks.<x>.severity: baseline "error" -> overlay "warning"`;
the attestation `contract.deviations` counts `{ "weakened": 1, "changed": 0 }`;
the added rule is not a deviation.

## Scenario 4 — Reviewable update (US2, SC-003)

Tag `v1.1.0` in the fixture baseline (tightened rule), then in the consumer:

```sh
bash .specify/gates/contract.sh sync --update
```

**Expected**: a `gates/baseline-v1.1.0` branch exists whose single commit
updates pin + snapshot + effective together, with the enforcement delta in
the commit body; the current branch still enforces `v1.0.0` (verify green,
attestation shows the old version) until the branch is merged. `--update`
when already at the highest tag reports "already up to date" and writes
nothing.

## Scenario 5 — Propose upstream (US3, SC-005)

With the Scenario 3 deviation in place:

```sh
bash .specify/gates/contract.sh propose --rationale "docs repo: markdown-only, shell severity is noise"
```

**Expected**: a change request against the fixture baseline repo (branch
or patch under `.specify/gates/proposals/`) whose content applies the
deviation to the baseline document and whose message carries the origin
repo, pinned version, classification, and the rationale. With no
deviations, propose reports nothing to propose and exits 0.

## Scenario 6 — The gate proves itself (SC-002, FR-012)

```sh
bash .specify/gates/doctor.sh --canary --only contract
```

**Expected**: `contract` canary `blocked` (the tampered-effective sandbox
was rejected), suite exit 0. Stubbing the drift check to a no-op (pattern
from `tests/test-canary.sh`) must flip the suite to **exit 1** naming the
contract gate.

## Scenario 7 — Dormant repos unaffected + budgets (SC-004, SC-006)

```sh
time bash .specify/gates/verify.sh --boundary agent    # this repo: no extends
```

**Expected**: no `contract` gate entry, no attestation `contract` object,
suites green unmodified; in an extending fixture, the delta between a run
with and without the contract gate is ≤ 1s, and verify performs zero
network access (provable by running with network disabled).

## Scenario 8 — Suites and self-gate stay green (SC-006)

```sh
bash tests/run.sh
```

**Expected**: all suites pass, including the new `test-contract.sh`, on
macOS/BSD and Linux/GNU; this repository's own gate stays green with the
contract machinery active (dormant here — no `extends`).
