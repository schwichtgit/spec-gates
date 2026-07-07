# Quickstart Validation: Provable Enforcement

Runnable scenarios proving the feature end-to-end. Each maps to a user
story and a success criterion; contract details live in
[contracts/cli-contracts.md](contracts/cli-contracts.md) and the record
shape in
[contracts/attestation-record.schema.json](contracts/attestation-record.schema.json).

## Prerequisites

```bash
npm ci                      # pinned prettier + markdownlint-cli2
bash tests/run.sh           # baseline: all suites green before starting
# project the runtime as CI does:
mkdir -p .specify/gates/lib
cp extension/runtime/{verify.sh,doctor.sh,canary.sh} .specify/gates/
cp extension/runtime/lib/*.sh .specify/gates/lib/
cp extension/runtime/policy.schema.json .specify/gates/
```

## Scenario 1 — Canaries pass on a healthy gate (US1 / SC-005)

```bash
bash .specify/gates/canary.sh
echo "exit: $?"        # expect 0; every canary reported as blocked
```

Expected: five canaries (`format`, `shell`, `bash`, `protect`, `secret`)
each report `blocked`; total wall time well under 30s; `git status` shows
no new/modified user files (FR-006).

## Scenario 2 — A broken gate is caught in one run (US1 / SC-001)

Simulate the historical no-op bug (check-mode silently gone), then prove
the canary names it:

```bash
# break: replace the projected dispatch with a no-op that exits 0
printf '#!/bin/bash\nexit 0\n' > .specify/gates/lib/formatter-dispatch.sh
bash .specify/gates/canary.sh; echo "exit: $?"   # expect 1
# output must name the format (and shell) canaries as ACCEPTED = broken gate
# restore:
cp extension/runtime/lib/formatter-dispatch.sh .specify/gates/lib/
bash .specify/gates/canary.sh; echo "exit: $?"   # expect 0 again
```

## Scenario 3 — Every run leaves evidence (US2 / SC-003, SC-004)

```bash
CLAUDE_PROJECT_DIR="$PWD" bash .specify/gates/verify.sh --boundary ci --json \
  | jq '.attestation | {v, boundary, policy_sha256, gates: [.gates[] | {name, version, pinned, candidates, checked, result}]}'
tail -1 .specify/gates/attestations.jsonl | jq .   # same record, last line
```

Expected: record validates against the contract schema; each tool gate
shows `version` = its lockfile pin, `candidates`/`checked` > 0, `result:
pass`. Run twice; compare records ignoring `ts`/`duration_s` — identical.
For the cap (SC-004): loop the gate `max_records + 10` times and confirm
`wc -l < .specify/gates/attestations.jsonl` never exceeds the cap.

## Scenario 4 — No-op signature fails doctor (US2 / FR-004)

```bash
# forge a suspicious latest record: passing gate, candidates>0, checked=0
# (test suites do this by writing a crafted record into the log)
bash .specify/gates/doctor.sh; echo "exit: $?"   # expect 1, gate named
```

## Scenario 5 — Version drift blocks at the boundary (US3 / SC-002)

```bash
# resolve a different prettier than the pin (e.g., stub an older binary
# ahead of node_modules/.bin in the resolution path, or edit the pin in a
# scratch copy of package-lock.json)
CLAUDE_PROJECT_DIR="$PWD" bash .specify/gates/verify.sh --boundary ci
echo "exit: $?"   # expect 2: parity gate fails
# report must read like: parity -- prettier: resolved 3.5.3, pinned 3.9.4 (run npm ci)
```

With `"attestation": { "parity": "warning" }` in the policy, the same run
exits 0 and reports the drift as a warning; with `"parity": "off"` no
parity entry appears.

## Scenario 6 — The repo gates itself with all of this on (SC-006)

```bash
bash tests/run.sh                                   # all suites incl. new ones
CLAUDE_PROJECT_DIR="$PWD" bash .specify/gates/verify.sh --boundary ci
bash .specify/gates/canary.sh                       # green
# then: push a branch and confirm the CI workflow's canary step is green
```

## Cleanup

```bash
rm -f .specify/gates/attestations.jsonl   # evidence is disposable locally
git checkout -- .specify/gates 2>/dev/null || true
```
