# Implementation Plan: Project Gates per Boundary

**Branch**: `006-project-gates` | **Date**: 2026-10-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/006-project-gates/spec.md`

## Summary

Projects declare named gates under `hooks.verify-quality.gates` (an object
keyed by gate name: `command`, `severity`, `timeout_s`, `skip_at`). They run
after the orchestrator's gates, each under a watchdog, and are reported as
their own gates in the text report, `--json` and the attestation. `skip_at`
may name `agent` and `git`, never `ci`; a skipped gate is reported as
`skipped by declaration at <boundary>` with `declared_skip` in the
attestation, through one function feature 007 reuses. The parity gate
proves CI ran every declared gate. `verify.sh --walk` is the documented way
to run the built-in walk from a custom command; `test_severity` lets a
failing `task test` block. Decisions: [research.md](research.md).

## Technical Context

**Language/Version**: bash 3.2-compatible shell (stock macOS floor), POSIX
awk/sed/grep (BSD and GNU).

**Primary Dependencies**: jq, git (unchanged). No new runtime dependency;
no `timeout(1)`.

**Storage**: plain files in the consumer repo: `policy.json` (new keys),
`attestations.jsonl` (one new optional field).

**Testing**: `tests/run.sh` suites (bash): test-gate, test-policy,
test-attest, test-parity, test-contract, test-doctor, test-canary,
test-manifest; canary suite (16 to 17); CI jobs including `macos-bash32`.
Every new test is mutation-checked.

**Target Platform**: macOS (bash 3.2) and Linux CI runners; GitHub, GitLab,
Jenkins pipelines (templates unchanged: they already run
`verify.sh --boundary ci`).

**Project Type**: Spec Kit extension (CLI runtime + command prose).

**Performance Goals**: no measurable change for a policy without project
gates; a skipped gate costs no process start; watchdog overhead under 100 ms
per gate.

**Constraints**: fail closed (missing command, timeout, refused keys); CI
can never be skipped; backward compatible (FR-015); the attestation reason
carries no command output (evidence hygiene).

**Scale/Scope**: typical policies declare 2 to 10 project gates; 4 stories.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

| Principle                         | Status | Notes                                                                                                                                                                                                                               |
| --------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I. Fail Closed                    | Pass   | A command that cannot start, a timeout, and every invalid key fail (exit 1 or 2) naming the cause; a skipped gate never counts as passed; an older runtime refuses the new keys instead of dropping gates.                          |
| II. Provable Enforcement          | Pass   | Project gates carry attestation entries; new canary `project` proves a failing gate blocks and a declared skip never reaches CI; tests per FR.                                                                                      |
| III. One Policy, Three Boundaries | Pass   | 1.1.0 text: skips only by declaration (`skip_at`), never CI (refused at validation), reported by name in summary, `--json`, attestation and doctor; the parity gate verifies CI ran every declared gate (the 1.1.0 follow-up TODO). |
| IV. Projection, Not Dependency    | Pass   | Copy-only runtime; the new `lib/watch.sh` is enumerated by the projection like every `lib/*.sh`; CI templates unchanged.                                                                                                            |
| V. The Spec Is a Boundary         | Pass   | Accept blocks per story in tasks.md; Status flips to Complete last.                                                                                                                                                                 |
| Portability floor                 | Pass   | No associative arrays or `mapfile`; watchdog uses `set -m` and `kill` as the accept-block runner does.                                                                                                                              |
| Evidence hygiene                  | Pass   | Attestation reasons are fixed strings (`check failed`, `timeout after <n>s`, `skipped by declaration at <b>`), never command output.                                                                                                |

Post-design re-check (after Phase 1): unchanged, all pass. No complexity
justification needed.

## Project Structure

### Documentation (this feature)

```text
specs/006-project-gates/
├── plan.md              # this file
├── research.md          # Phase 0: decisions R1-R13
├── data-model.md        # Phase 1: project gate, skip declaration, gate set
├── quickstart.md        # Phase 1: runnable validation scenarios
├── contracts/
│   ├── policy-gates.md  # policy keys, validation, contract classes
│   └── verify-report.md # report, --json, attestation, parity, --walk, doctor
├── checklists/
│   └── requirements.md  # spec quality checklist
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
extension/runtime/
├── verify.sh                # GATES_BOUNDARY export, project gate dispatch,
│                            # declared skips, test_severity, --walk, parity set check
├── doctor.sh                # gate listing, formatter-dispatch [rec]
├── canary.sh                # canary `project` (17th)
├── policy.schema.json       # gates, gate_timeout_s, test_severity, skip_at
├── policy-template.json     # commented example stays minimal (no gates)
└── lib/
    ├── watch.sh             # NEW: gates_run_watched, gates_group_stop (moved)
    ├── spec-gate.sh         # sources lib/watch.sh for the group stop
    ├── policy.sh            # gates_validate_policy rules, gate accessors,
    │                        # gates_declared_skip (shared with feature 007)
    ├── contract.sh          # skip_at, removed gate, severity classes
    └── attest.sh            # declared_skip field in gate entries

extension/commands/
├── speckit.gates.verify.md  # --walk, project gates, GATES_BOUNDARY
└── speckit.gates.init.md    # mention project gates (no inference)

specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json
                             # optional declared_skip

tests/
├── test-gate.sh             # dispatch, report, timeout, missing command,
│                            # skips, GATES_BOUNDARY, --walk, test_severity
├── test-policy.sh           # validation rules
├── test-contract.sh         # deviation classes
├── test-attest.sh           # declared_skip entries
├── test-parity.sh           # set check; identical results with no gates
├── test-doctor.sh           # gate listing, [rec]
└── test-canary.sh           # 17 canaries

docs/how-it-works.md, README.md, CHANGELOG.md
```

**Structure Decision**: the existing runtime layout; one new library file
(`lib/watch.sh`) so the watchdog is shared rather than copied, and no new
projected script (`--walk` is a flag).

## Story order and PR plan

1. **US1 (P1)**: policy keys and validation (R1, R2, R13), `lib/watch.sh`
   (R3), dispatch and reporting (R4), `GATES_BOUNDARY` (R5), attestation.
2. **US2 (P1)**: `skip_at`, `gates_declared_skip` (R6), parity set check
   (R7), doctor listing (R9), contract classes (R10), canary (R12).
3. **US3 (P2)**: `verify.sh --walk` (R8) and the doctor `[rec]`.
4. **US4 (P3)**: `test_severity` (R11).

Each story ends with its accept blocks in tasks.md and the touched suites
green; the full suite and canary run once per PR.

## Complexity Tracking

None: the Constitution Check passes without exceptions.
