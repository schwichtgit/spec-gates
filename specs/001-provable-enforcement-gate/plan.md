# Implementation Plan: Provable Enforcement — Gate Run Attestations and Canary Self-Tests

**Branch**: `001-provable-enforcement-gate` | **Date**: 2026-07-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-provable-enforcement-gate/spec.md`

## Summary

Make enforcement self-evidencing. Three deliverables, in priority order:
(P1) a **canary suite** that proves in a sandbox that every gate and hook
still blocks known violations; (P2) **attestation records** — per-run
evidence (policy hash, resolved tool binaries + versions, candidate vs
checked file counts, results) appended to a capped JSONL log and embedded in
`verify.sh --json`; (P3) **pins-based parity verification** — each boundary
compares its resolved tool versions against the project's lockfile pins and
the policy content hash against the committed policy, so agent, git, and CI
runs are proven equivalent transitively with no attestation transport
(Clarifications, 2026-07-07).

Technical approach: extend the existing projected runtime in place —
`verify.sh` gains attestation emission and the parity gate; a new
`canary.sh` joins `verify.sh`/`doctor.sh` in `extension/runtime/`;
`doctor.sh` gains the no-op-gate failure heuristic and canary delegation;
`policy.sh` validates the new optional `attestation` section. All bash 3.2 +
jq, following the established projection/test patterns.

## Technical Context

**Language/Version**: Bash 3.2-compatible shell (macOS `/bin/bash` 3.2.57 is
the floor; GNU bash 5 on CI must also pass — both are exercised today).

**Primary Dependencies**: `jq` (only hard dependency, per FR-010); SHA-256
via `sha256sum`/`shasum -a 256` fallback chain (research R3); linters
resolved `node_modules/.bin` → PATH as today.

**Storage**: `.specify/gates/attestations.jsonl` — append-only JSONL, capped
(default 200 records), gitignored by default; no other state.

**Testing**: existing shell suites under `tests/` (`tests/run.sh`); new
`tests/test-attest.sh` and `tests/test-canary.sh` following the
project-into-fixture pattern; CI (ubuntu, GNU) + local (macOS, BSD) both
must stay green — cross-platform divergence is a known bug source here.

**Target Platform**: the projected runtime inside any Spec Kit project
(macOS + Linux dev machines, Linux CI).

**Project Type**: CLI/hooks runtime (shell library projected into user
repos) — single project.

**Performance Goals**: attestation overhead ≤ 1s per gate run (SC-003);
canary suite ≤ 30s in CI (SC-005).

**Constraints**: offline (no network); no file contents in attestations
(FR-011); canary sandbox never touches user files (FR-006); duration
granularity is whole seconds (bash 3.2 has no `EPOCHREALTIME` — research
R6).

**Scale/Scope**: log capped at `max_records` (default 200); 3 runtime
scripts touched + 1 added; 2 new test suites; policy schema + validator
extension; CI template gains a canary step.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

`.specify/memory/constitution.md` is still the unfilled init template — no
ratified project-specific gates exist. In its place, the project's de-facto
design rules (README "Design rules" + established conventions) are applied
as the gate:

| De-facto rule                                                     | This plan                                                                                                           | Status |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------ |
| Fail closed: a gate that cannot demonstrably block is broken      | Canaries make this a standing invariant; no-op heuristic is a doctor FAILURE                                        | PASS   |
| One gate implementation, all boundaries (parity is structural)    | Attestation + parity live in `verify.sh`/lib only; hooks and CI keep delegating; no boundary re-implements anything | PASS   |
| `policy.json` is user-owned; init seeds, upgrade never overwrites | `attestation` section is optional with defaults; absence = enabled/200/error                                        | PASS   |
| bash 3.2 + jq only, offline                                       | All new code follows FR-010; hashing uses a portable fallback chain                                                 | PASS   |
| Projection, not symlinks; runtime survives extension removal      | `canary.sh` is projected like `verify.sh`/`doctor.sh`; gitignore + CI projection updated                            | PASS   |
| Everything verified by running it for real (dogfood)              | quickstart.md defines end-to-end validation incl. deliberate gate-breaking                                          | PASS   |

No violations; Complexity Tracking not needed. **Post-design re-check
(after Phase 1)**: unchanged — the design adds no new dependency, no new
projection mechanism, and no second implementation of any gate. Recommend a
future `/speckit-constitution` run to ratify these rules formally.

## Project Structure

### Documentation (this feature)

```text
specs/001-provable-enforcement-gate/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── attestation-record.schema.json
│   └── cli-contracts.md
└── tasks.md             # Phase 2 output (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
extension/runtime/
├── verify.sh                    # + attestation emission, parity gate, log cap
├── doctor.sh                    # + no-op heuristic (FAIL), --canary delegation
├── canary.sh                    # NEW: sandboxed known-violation suite
├── policy-template.json         # + seeded attestation section (commented defaults)
├── policy.schema.json           # + attestation section
└── lib/
    ├── policy.sh                # + attestation section validation + accessors
    ├── formatter-dispatch.sh    # + candidate/checked counts surfaced to verify.sh
    └── attest.sh                # NEW: record build/append/cap, hashing, versions, pins

extension/ci/github/gates.yml    # + canary step
.github/workflows/ci.yml         # + canary step (self-enforcement)
.gitignore                       # + .specify/gates/attestations.jsonl

tests/
├── run.sh                       # + test-attest, test-canary
├── test-attest.sh               # NEW: record shape, cap, no-op heuristic, parity
└── test-canary.sh               # NEW: healthy pass, broken-gate detection, sandbox isolation
```

**Structure Decision**: single project; all enforcement logic stays in the
projected runtime (`extension/runtime/`), tests stay repo-root (dev-only,
not shipped) — identical to the existing layout, no new directories beyond
one lib file and one runtime script.

## Complexity Tracking

No constitution violations to justify — table intentionally empty.
