# Implementation Plan: Constitution as Enforceable Contract — Guided Elicitation With Enforcement Wiring

**Branch**: `004-constitution-gate` | **Date**: 2026-07-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/004-constitution-gate/spec.md`

## Summary

Replace the blank-placeholder constitution experience with a guided,
corpus-backed elicitation whose output is enforceable by construction.
Three deliverables, in priority order: (P1) **the elicitation session** —
a new `speckit.gates.constitution` command runs a conversational
interview, offers principle fragments from a bundled versioned corpus
(statement + why + proposed enforcement surface), and assembles a filled
constitution in which every principle carries an enforcement annotation
or an explicit prose-only marker; (P2) **alignment** — the session derives
one concrete enforcement change per annotated principle (policy setting,
hook, CI check, accept block, scanner rule), presents the set as a
reviewable proposal, and applies it only on explicit approval; (P3)
**proof** — `doctor` gains a constitution section that verifies each
annotated surface exists and is active from local information, failing
(exit 1) on any gap, listing prose-only principles without failing.
`/speckit.gates.init` detects a placeholder/absent constitution and
offers the session (FR-014), closing the bumpy-onboarding loop.

Technical approach: same split the extension already uses — the command
markdown drives the conversation; a new projected `lib/constitution.sh`
plus a `constitution.sh` entry script own everything deterministic
(fragment loading/filtering, draft assembly from an answers/selections
file, annotation parsing, surface-activity checks, alignment-diff
computation). Annotations are inline HTML comment markers beside each
principle; the corpus ships as charter-compatible
`manifest.yml + fragments/**.md` with our metadata in frontmatter. All
bash 3.2 + jq, offline with the bundled corpus, remote registries fetched
only at session time via 003's fetch machinery.

## Technical Context

**Language/Version**: Bash 3.2-compatible shell (macOS floor; GNU bash 5
CI) for all runtime helpers; command markdown for the conversation.

**Primary Dependencies**: `jq` (answers/selections files, policy diffs),
POSIX awk/sed (annotation and frontmatter parsing), `git` only for
optional remote registries (reusing `gates_contract_fetch`). No new
dependencies.

**Storage**: annotations live inside `.specify/memory/constitution.md`
as inline HTML comment markers (survive prettier, hand-edits, and the
core command's rewrites); the bundled corpus ships in the extension at
`extension/constitution/` (manifest + fragments) and is NOT projected
(sessions require the extension; the projected lib/doctor only read
annotations, never the corpus); session scratch (answers, selections,
draft, proposal) lives in `mktemp -d`.

**Testing**: new `tests/test-constitution.sh` driving the deterministic
pipeline via answers/selections fixtures (the conversation itself is
command-markdown, tested at the helper boundary exactly like init's
policy-infer); doctor cases in `tests/test-doctor.sh`; suites must stay
green on macOS/BSD + Linux/GNU.

**Target Platform**: any Spec Kit project with the extension installed
(session-time); consumer repos after extension removal keep working —
doctor's constitution section reads annotations via the projected lib.

**Project Type**: CLI/hooks runtime + agent command — single project.

**Performance Goals**: doctor's constitution section ≤ 1s (SC-004);
bundled-corpus session fully offline; no verify.sh runtime change at all.

**Constraints**: never auto-fill constitution values (FR-006 — refuse
non-interactive runs without an answers file); user-owned files modified
only on explicit approval (FR-007, SC-003); augment mode never removes
existing content (FR-010); gap severity fixed at failure, prose-only
never fails (FR-009, Clarifications); zero behavior change for repos
that never opt in (FR-013, SC-006).

**Scale/Scope**: starter corpus ~30 fragments; one new lib, one new entry
script, one new command file, one new test suite; `doctor.sh`,
`speckit.gates.init.md`, projection lists, and `extension.yml` touched;
`verify.sh` untouched.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

Evaluated against constitution v1.0.0:

| Principle                         | This plan                                                                                                                                                              | Status |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| I. Fail Closed                    | Non-interactive without answers file → refuse, never guess; malformed annotations are doctor failures naming the line; gap = exit 1 naming principle + surface         | PASS   |
| II. Provable Enforcement          | The feature IS the proof layer for governance: annotations are claims, doctor verifies them per run, dogfooded on this repo's own constitution (SC-007); suite-covered | PASS   |
| III. One Policy, Three Boundaries | No boundary logic changes; the elicitation is authoring tooling — enforcement still flows exclusively through the existing surfaces it wires up                        | PASS   |
| IV. Projection, Not Dependency    | `lib/constitution.sh` + `constitution.sh` projected like the rest; doctor works after extension removal; the corpus intentionally stays extension-side (session-only)  | PASS   |
| V. The Spec Is a Boundary         | Feature runs as `specs/004-constitution-gate/` with accept blocks planned; Status flip last                                                                            | PASS   |
| Portability floor (bash 3.2, BSD) | Frontmatter/annotation parsing in awk/sed; answers/selections in jq; no new tools                                                                                      | PASS   |
| Evidence, never content           | Doctor reports principle names and surface identifiers, never constitution prose bodies in machine records                                                             | PASS   |
| User-owned configuration          | Alignment proposals apply only on explicit approval (SC-003 byte-identical on decline); constitution edits always shown before writing; augment mode preserves content | PASS   |

One deliberate scope note (not a violation): 004 adds a **doctor**
section, not a verify.sh gate class — constitution health is a
diagnosis-time concern like the no-op signature, so the attestation
record and canary suite are intentionally untouched. Should a future
feature promote constitution health to a run gate, principle II's full
surface (attestation + canary) applies then. **Post-design re-check
(after Phase 1)**: unchanged — no new dependency, no network at
verify/doctor time, no second implementation of any gate.

## Project Structure

### Documentation (this feature)

```text
specs/004-constitution-gate/
├── plan.md                       # This file
├── research.md                   # Phase 0 output
├── data-model.md                 # Phase 1 output
├── quickstart.md                 # Phase 1 output
├── contracts/                    # Phase 1 output
│   ├── annotation-format.md      # inline marker grammar + fragment/corpus formats
│   └── cli-contracts.md          # constitution.sh subcommands, doctor section, init hookup
└── tasks.md                      # Phase 2 output (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
extension/
├── extension.yml                     # + speckit.gates.constitution (8 commands)
├── commands/
│   ├── speckit.gates.constitution.md # NEW: the conversational interview + session flow
│   └── speckit.gates.init.md         # + offer the session on placeholder/absent constitution (FR-014)
├── constitution/                     # NEW: bundled corpus (NOT projected; session-time only)
│   ├── manifest.yml                  # charter-compatible: mandatory/recommended/optional tiers
│   └── fragments/                    # <category>/<name>.md, frontmatter metadata + body
└── runtime/
    ├── constitution.sh               # NEW: projected entry script — draft | align | check
    ├── doctor.sh                     # + constitution section (annotations → surface activity, exit 1 on gap)
    └── lib/
        └── constitution.sh           # NEW lib: fragment/frontmatter parsing, corpus filtering,
                                      #   draft assembly, annotation grammar, surface checks, policy diffs

.github/workflows/ci.yml              # projection list + constitution.sh
tests/
├── run.sh                            # + test-constitution
├── test-constitution.sh              # NEW: draft/annotate/align/check pipeline via fixtures
└── test-doctor.sh                    # + constitution-section cases
```

**Structure Decision**: single project; deterministic logic in the
projected runtime, conversation in command markdown — the exact split
init and the contract feature use. The corpus lives extension-side
(`extension/constitution/`) because sessions require the extension anyway
and consumer repos must not carry ~30 fragments they never read; the
annotations in each repo's constitution are the projected, durable part.

## Complexity Tracking

No constitution violations to justify — table intentionally empty.
