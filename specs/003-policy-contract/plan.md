# Implementation Plan: Policy as Versioned Contract — Baseline Inheritance With Reviewable Drift

**Branch**: `003-policy-contract` | **Date**: 2026-07-08 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-policy-contract/spec.md`

## Summary

Turn `policy.json` into the consumer side of a versioned contract. Three
deliverables, in priority order: (P1) **baseline inheritance with provable
pinning** — an optional `extends` declaration names a baseline policy at a
versioned git source; `sync` fetches it once, records a pin (version +
content digest), commits a local snapshot, and materializes a deterministic
effective policy (baseline ⊕ overlay) that every boundary enforces; a new
synthetic `contract` gate proves offline, on every run, that snapshot
matches pin and effective matches recomputation — drift fails closed. (P2)
**reviewable updates** — `sync --update` moves the pin to a newer baseline
version on a branch with a human-readable enforcement delta, never applying
it directly. (P3) **upstream proposals** — `propose` packages the overlay's
deviations from the baseline as a change request against the baseline
source, closing the governance loop.

Technical approach: extend the projected runtime in place, exactly as 001
and 002 landed. One new `lib/contract.sh` (sourced by `verify.sh`,
`doctor.sh`, and a new projected `contract.sh` entry script with
`sync`/`propose` subcommands) owns fetch, pin, snapshot, merge,
deviation classification, and drift proving; `verify.sh` evaluates the
synthetic `contract` gate immediately after policy validation (before the
tool gates — policy integrity precedes policy enforcement); `policy.sh` and
the JSON schema validate the new optional `extends` section; the
attestation record gains an optional `contract` object; two new extension
commands (`speckit.gates.sync`, `speckit.gates.propose`) wrap the script.
All bash 3.2 + jq + git, offline at verify time, following the established
projection and test patterns.

## Technical Context

**Language/Version**: Bash 3.2-compatible shell (macOS `/bin/bash` floor;
GNU bash 5 on CI must also pass — both exercised today).

**Primary Dependencies**: `jq` (merge, digest input canonicalization,
validation); `git` (fetching versioned baselines at sync time only;
already a soft dependency of the runtime); `shasum -a 256`/`sha256sum`
(digests — the same dual-binary shim 001's attestations use). No new
dependencies.

**Storage**: three committed artifacts in `.specify/gates/` next to the
user-owned `policy.json`: the baseline snapshot, the pin (lock file), and
the materialized effective policy. All plain JSON; no timestamps inside
(clean diffs, deterministic recomputation); audit timestamps live in
attestation records as today.

**Testing**: existing shell suites under `tests/` (`tests/run.sh`); new
`tests/test-contract.sh` using the project-into-fixture pattern with a
local fixture baseline git repo (file:// remotes — no network in tests);
canary addition in `tests/test-canary.sh`; attestation-shape cases in
`tests/test-attest.sh`; doctor cases in `tests/test-doctor.sh`.

**Target Platform**: the projected runtime inside any Spec Kit project
(macOS + Linux dev machines, Linux CI). Repos without an `extends`
declaration are byte-for-byte unaffected (FR-001, SC-006).

**Project Type**: CLI/hooks runtime (shell library projected into user
repos) — single project.

**Performance Goals**: `contract` gate adds ≤ 1s to a run (SC-004): one
digest of a small JSON file plus one jq merge and one comparison; no
subprocess fan-out. Sync latency is dominated by `git clone --depth 1` and
is interactive-command territory, not gate territory.

**Constraints**: verify performs zero network access (FR-005); identical
behavior at all three boundaries; fail closed on missing/mismatched
contract artifacts (FR-005/FR-007); deviations are informational only and
never change the exit code (FR-006, Clarifications); no file contents in
attestations (only digests/counts); single-level inheritance (chained
baselines refused at sync).

**Scale/Scope**: one baseline per repo; baseline policies are the same
small JSON documents policies are today (KBs); one new lib file, one new
entry script, one new test suite, two new command files; `verify.sh`,
`doctor.sh`, `canary.sh`, `policy.sh`, schema, template, CI projection
lists, and `extension.yml` touched.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

First plan evaluated against the ratified constitution (v1.0.0,
2026-07-08) rather than de-facto rules:

| Principle                         | This plan                                                                                                                                                           | Status |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| I. Fail Closed                    | Declared-but-unsynced contract fails verify naming the missing artifact; digest mismatch, tampered snapshot/effective, schema-invalid baseline all block with names | PASS   |
| II. Provable Enforcement          | Contract state is proven per run (recompute + digest), attested (FR-010), canaried (FR-012), and doctor-visible (FR-011); a new gate class ships with all three     | PASS   |
| III. One Policy, Three Boundaries | The effective policy is materialized once and read by the same `verify.sh` at every boundary; no boundary re-implements merge or drift logic                        | PASS   |
| IV. Projection, Not Dependency    | `lib/contract.sh` + `contract.sh` are projected like the rest; snapshot/pin/effective are committed so clone-and-run works offline; `policy.json` stays user-owned  | PASS   |
| V. The Spec Is a Boundary         | This feature runs as `specs/003-policy-contract/` with accept blocks planned in tasks.md; Status flip last                                                          | PASS   |
| Portability floor (bash 3.2, BSD) | Merge/classification in jq; version ordering via a small awk semver comparator (no `sort -V` — absent on BSD); digests via the existing dual-binary shim            | PASS   |
| Evidence, never content           | Attestation `contract` object carries source, version, digests, deviation counts — never policy contents                                                            | PASS   |
| User-owned configuration          | `extends` is optional; sync writes only the three derived artifacts, never `policy.json`; absence of `extends` changes nothing                                      | PASS   |

No violations; Complexity Tracking not needed. **Post-design re-check
(after Phase 1)**: unchanged — the design adds no new dependency, no
network at verify time, no second implementation of any gate, and no new
projection mechanism. The `contract` gate is a synthetic gate entry exactly
like `parity` and `spec`.

## Project Structure

### Documentation (this feature)

```text
specs/003-policy-contract/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── artifact-layout.md   # extends section, lock/snapshot/effective file formats
│   └── cli-contracts.md     # contract.sh sync|propose, verify/doctor behavior, attestation extension
└── tasks.md             # Phase 2 output (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
extension/
├── extension.yml                # + speckit.gates.sync, speckit.gates.propose (7 commands)
├── commands/
│   ├── speckit.gates.sync.md    # NEW: wraps contract.sh sync [--update [version]]
│   └── speckit.gates.propose.md # NEW: wraps contract.sh propose
└── runtime/
    ├── verify.sh                # + synthetic `contract` gate (after policy validation,
    │                            #   before tool gates), effective-policy selection
    ├── doctor.sh                # + contract state section (pin/snapshot/effective/deviations)
    ├── canary.sh                # + contract canary (tampered effective policy must be rejected)
    ├── contract.sh              # NEW: projected entry script — sync | propose subcommands
    ├── policy-template.json     # + commented-out extends example (absent by default)
    ├── policy.schema.json       # + optional `extends` section
    └── lib/
        ├── policy.sh            # + extends validation, effective-policy file resolution
        └── contract.sh          # NEW lib: fetch, pin, snapshot, merge, classify, prove

.github/workflows/ci.yml         # projection list + contract.sh
tests/
├── run.sh                       # + test-contract
├── test-contract.sh             # NEW: sync/pin/merge/drift/deviation/update/propose/dormant
├── test-canary.sh               # + contract canary coverage
├── test-attest.sh               # + attestation `contract` object cases
└── test-doctor.sh               # + contract state / drift-failure cases
```

**Structure Decision**: single project; all logic stays in the projected
runtime (`extension/runtime/`); one new lib file plus one new projected
entry script (`contract.sh` with subcommands — one projection touchpoint
instead of two separate scripts); tests stay repo-root (dev-only, not
shipped). The three contract artifacts live beside `policy.json` in
`.specify/gates/` and are committed (unlike the gitignored runtime copies).

## Complexity Tracking

No constitution violations to justify — table intentionally empty.
