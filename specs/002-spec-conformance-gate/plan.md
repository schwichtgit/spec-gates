# Implementation Plan: Spec Conformance — Acceptance Criteria as Executable Gates

**Branch**: `002-spec-conformance-gate` | **Date**: 2026-07-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-spec-conformance-gate/spec.md`

## Summary

Make the spec an enforceable boundary. Three deliverables, in priority
order: (P1) an **accept-block runner** — fenced `accept` code blocks in a
feature's `tasks.md` are discovered, parsed, and executed per criterion by a
new `spec` gate class in `verify.sh`; (P2) **completion enforcement** — a
feature whose `spec.md` Status is `Complete` blocks the run when any task is
unchecked or any accept block fails, while incomplete features are
parse-only during normal runs with on-demand informational execution
(Clarifications, 2026-07-07); (P3) **provable-enforcement integration** —
the `spec` gate appears in attestation records with parse/execute/pass/fail
counts, the canary suite gains a spec-gate canary, and doctor reports
discovery and fails on unparseable blocks.

Technical approach: extend the projected runtime in place, mirroring how 001
landed. A new `lib/spec-gate.sh` (sourced by `verify.sh`) owns discovery,
parsing, execution, timeout, and mutation detection; `verify.sh` evaluates a
synthetic `spec` gate after the tool gates (before parity) and gains an
`--accept <feature|all>` flag for on-demand runs; `policy.sh` and the JSON
schema validate the new optional `spec` policy section; the attestation
record gains an optional `spec` object. All bash 3.2 + jq, following the
established projection/test patterns.

## Technical Context

**Language/Version**: Bash 3.2-compatible shell (macOS `/bin/bash` 3.2.57 is
the floor; GNU bash 5 on CI must also pass — both are exercised today).

**Primary Dependencies**: `jq` (only hard dependency, FR-012); markdown
parsing with the POSIX toolbox already in use (awk/sed/grep, BSD + GNU
compatible); no `timeout(1)` dependency (absent on macOS base — research
R4's watchdog pattern instead).

**Storage**: none beyond the existing attestation log — the `spec` object
rides inside the per-run attestation record; accept blocks live in each
feature's committed `tasks.md`.

**Testing**: existing shell suites under `tests/` (`tests/run.sh`); new
`tests/test-spec-gate.sh` following the project-into-fixture pattern
(sandbox project with fixture features in Draft/Complete states); canary
addition covered in `tests/test-canary.sh`; macOS/BSD + Linux/GNU both must
stay green.

**Target Platform**: the projected runtime inside any Spec Kit project
(macOS + Linux dev machines, Linux CI); repositories without a `specs/`
tree must pass trivially (FR-011).

**Project Type**: CLI/hooks runtime (shell library projected into user
repos) — single project.

**Performance Goals**: `spec` gate adds ≤ 1s to a run when no accept blocks
execute (discovery + parse only); full execution on this repository ≤ 30s
(SC-004); per-block timeout default 30s (FR-003).

**Constraints**: offline (no network); identical behavior at all three
boundaries (FR-003, Clarifications); fail closed on malformed blocks
(FR-005); accept blocks execute serially from the repo root; no file
contents in attestations (FR-008); never auto-revert user files (FR-006).

**Scale/Scope**: features are direct children of `specs/` (tens, not
thousands); one new lib file, one new test suite, `verify.sh`/`doctor.sh`/
`policy.sh`/`canary.sh`/schema/template touched; CI templates unchanged
(the gate step already runs `verify.sh`).

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

`.specify/memory/constitution.md` is still the unfilled init template — no
ratified project-specific gates exist. As in 001, the project's de-facto
design rules (README "Design rules" + established conventions) are applied
as the gate:

| De-facto rule                                                     | This plan                                                                                                                   | Status |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ------ |
| Fail closed: a gate that cannot demonstrably block is broken      | Malformed accept blocks fail the gate (FR-005); a spec-gate canary proves blocking (FR-009); missing tools fail, never skip | PASS   |
| One gate implementation, all boundaries (parity is structural)    | All logic in `lib/spec-gate.sh` + `verify.sh`; hooks and CI keep delegating; execution identical at every boundary (FR-003) | PASS   |
| `policy.json` is user-owned; init seeds, upgrade never overwrites | `spec` section is optional with defaults (enabled/error/all/30s); absence = defaults                                        | PASS   |
| bash 3.2 + jq only, offline                                       | Parser is awk/sed; timeout is a shell watchdog (R4), not `timeout(1)`; no new dependency                                    | PASS   |
| Projection, not symlinks; runtime survives extension removal      | `lib/spec-gate.sh` is projected like the other libs; gitignore/CI projection lists updated                                  | PASS   |
| Everything verified by running it for real (dogfood)              | 002's own `tasks.md` carries accept blocks (SC-005); quickstart breaks the gate deliberately and watches it block           | PASS   |

No violations; Complexity Tracking not needed. **Post-design re-check
(after Phase 1)**: unchanged — the design adds no new dependency, no new
projection mechanism, and no second implementation of any gate. The `spec`
gate is a synthetic gate entry exactly like 001's `parity`.

## Project Structure

### Documentation (this feature)

```text
specs/002-spec-conformance-gate/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── accept-block.md  # authoring grammar for fenced accept blocks
│   └── cli-contracts.md # verify.sh/doctor flags, policy section, attestation extension
└── tasks.md             # Phase 2 output (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
extension/runtime/
├── verify.sh                    # + synthetic `spec` gate (after tools, before parity),
│                                #   --accept <feature|all> on-demand flag
├── doctor.sh                    # + discovery report (features/blocks/complete),
│                                #   fails on unparseable blocks, all-checked-but-Draft nudge
├── canary.sh                    # + spec-gate canary (Complete fixture w/ failing block)
├── policy-template.json         # + seeded `spec` section (commented defaults)
├── policy.schema.json           # + `spec` section
└── lib/
    ├── policy.sh                # + `spec` section validation + accessors
    └── spec-gate.sh             # NEW: discovery, parse, execute, timeout, mutation check

tests/
├── run.sh                       # + test-spec-gate
├── test-spec-gate.sh            # NEW: parse/enforce/informational/timeout/mutation/no-specs
└── test-canary.sh               # + spec-gate canary coverage

specs/002-spec-conformance-gate/tasks.md   # dogfood: carries its own accept blocks (SC-005)
```

**Structure Decision**: single project; all enforcement logic stays in the
projected runtime (`extension/runtime/`), tests stay repo-root (dev-only,
not shipped) — identical to the existing layout; one new lib file, one new
test suite, no new directories.

## Complexity Tracking

No constitution violations to justify — table intentionally empty.
