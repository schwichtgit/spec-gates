# Implementation Plan: Gate Speed and Visibility

**Branch**: `007-gate-speed-visibility` | **Date**: 2026-10-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/007-gate-speed-visibility/spec.md`

## Summary

`spec.cover` names a protected project script and the earlier boundaries
(`agent`, `git`) where it may vouch for accept blocks. Before each block at
those boundaries the spec gate asks it, through feature 006's watchdog, and
a one-line answer marks the block covered: not run, reported by name with the
reason, recorded with feature 006's `declared_skip` field. CI never asks,
and the parity gate fails if anything was covered there; a canary proves it.
The attestation gains per-block entries with results and durations;
`GATES_TIMELINE` and `GATES_PROGRESS` stream one line per gate and block as
they end (and start); pre-commit shows progress on a terminal. Decisions:
[research.md](research.md).

## Technical Context

**Language/Version**: bash 3.2-compatible shell (stock macOS floor), POSIX
awk/sed/grep (BSD and GNU, mawk).

**Primary Dependencies**: jq, git (unchanged); feature 006's `lib/watch.sh`
and `gates_declared_skip`.

**Storage**: `policy.json` (`spec.cover`), `attestations.jsonl` (per-block
entries), the timeline and progress files a caller names.

**Testing**: `tests/run.sh` suites: test-spec-gate, test-gate, test-policy,
test-attest, test-parity, test-contract, test-doctor, test-hooks,
test-pr-check, test-canary; canary suite (17 to 18); CI jobs including
`macos-bash32`. Every new test is mutation-checked.

**Target Platform**: macOS (bash 3.2) and Linux CI runners; GitHub, GitLab,
Jenkins pipelines (templates unchanged).

**Project Type**: Spec Kit extension (CLI runtime + command prose).

**Performance Goals**: a covered block costs only the script's answer (at
most `timeout_s`); timeline and progress add one append per event; nothing
measurable without the new keys and variables.

**Constraints**: fail closed (a missing declared script refuses the run;
anything but a clean "covered" answer runs the block); never cover at CI;
evidence hygiene (reasons are fixed strings or the script's sanitized line);
backward compatible output (FR-017).

**Scale/Scope**: tens of accept blocks per project; 5 stories.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

| Principle                         | Status | Notes                                                                                                                                                                                                                                            |
| --------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| I. Fail Closed                    | Pass   | A declared but missing script refuses the run; any answer but exit 0 with one line runs the block; a hung script is cut off and the block runs; unwritable timeline/progress files never change outcomes.                                        |
| II. Provable Enforcement          | Pass   | Covered blocks are attested per block; canary `covered` proves CI cannot be covered; mutation-checked tests per FR.                                                                                                                              |
| III. One Policy, Three Boundaries | Pass   | 1.1.0 text: covering only where `spec.cover.at` declares it (agent, git), never CI (refused at validation), every covered block named in report and attestation; the parity gate fails at CI if anything was covered. Uses 006's skip mechanism. |
| IV. Projection, Not Dependency    | Pass   | Copy-only runtime; no new projected script (the covering script is the project's own file); templates unchanged.                                                                                                                                 |
| V. The Spec Is a Boundary         | Pass   | Accept blocks per story in tasks.md; Status flips to Complete last.                                                                                                                                                                              |
| Portability floor                 | Pass   | `printf` appends, `/dev/stderr` for progress, `date +%H:%M:%S`; no associative arrays.                                                                                                                                                           |
| Evidence hygiene                  | Pass   | Timeline, progress and attestation carry names, times, results and fixed or sanitized reasons only.                                                                                                                                              |

The covering script itself decides what is skipped, so it is protected like
the policy (R4): a change to it is a reviewed, approved change at every
boundary. Post-design re-check: unchanged, all pass.

## Project Structure

### Documentation (this feature)

```text
specs/007-gate-speed-visibility/
├── plan.md
├── research.md            # R1-R13
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── policy-cover.md    # spec.cover keys, the script interface, protection, contract classes
│   └── report-timeline.md # report, attestation blocks[], parity, timeline, progress
├── checklists/requirements.md
└── tasks.md               # /speckit-tasks
```

### Source Code (repository root)

```text
extension/runtime/
├── verify.sh              # cover script existence check, timeline/progress for gates,
│                          # parity: nothing covered at ci, spec summary detail
├── doctor.sh              # cover declaration, protection, executable bit
├── canary.sh              # canary `covered` (18th)
├── policy.schema.json     # spec.cover
├── hooks/git/pre-commit   # GATES_PROGRESS=/dev/stderr on a terminal
└── lib/
    ├── spec-gate.sh       # ask the script per block, covered result, per-block
    │                      # entries and durations, timeline/progress for blocks
    ├── policy.sh          # validator rules, accessors, cover script in gates_protected_list
    ├── contract.sh        # spec.cover classification
    ├── attest.sh          # blocks[] and blocks_covered in spec results
    └── timeline.sh        # NEW: gates_timeline_line, gates_progress_line (one writer)

specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json
                           # blocks_covered, blocks[]

tests/                     # test-spec-gate, test-gate, test-policy, test-attest,
                           # test-parity, test-contract, test-doctor, test-hooks,
                           # test-pr-check, test-canary

docs/how-it-works.md, README.md, extension/commands/*.md, CHANGELOG.md
```

**Structure Decision**: the existing layout plus one small library
(`lib/timeline.sh`) so gates and blocks share one writer for both files.

## Story order and PR plan

1. **US1 + US2 + US3 (P1)**, one PR: `spec.cover` keys and validation,
   asking the script, covered reporting through 006's mechanism, protection
   in `gates_protected_list`, parity at CI, doctor, contract classes, the
   `covered` canary. They ship together: covering without protection or the
   CI proof must never be released.
2. **US4 + US5 (P2)**, one PR: per-block attestation entries and
   durations, `lib/timeline.sh`, `GATES_TIMELINE`, `GATES_PROGRESS`, the
   pre-commit terminal view.
3. **Polish**: docs, CHANGELOG, quickstart walk, Status Complete.

## Complexity Tracking

None: the Constitution Check passes without exceptions.
