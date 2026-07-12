<!--
Sync Impact Report
- Version change: (template, unversioned) → 1.0.0
- Modified principles: none (initial ratification — template placeholders replaced)
- Added sections:
  - Core Principles (I. Fail Closed; II. Provable Enforcement; III. One Policy,
    Three Boundaries; IV. Projection, Not Dependency; V. The Spec Is a Boundary)
  - Additional Constraints (portability floor, evidence hygiene, pinned toolchain)
  - Development Workflow & Quality Gates
  - Governance
- Removed sections: none (all template slots filled)
- Templates requiring updates:
  - ✅ .specify/templates/plan-template.md — "Constitution Check" gate is a
    per-feature placeholder resolved at plan time; no structural change needed
  - ✅ .specify/templates/spec-template.md — no constitution references; aligned
  - ✅ .specify/templates/tasks-template.md — no constitution references; aligned
  - ✅ README.md — Development section suite count corrected (7 → 8) in this pass
- Follow-up TODOs: none
-->

# spec-gates Constitution

## Core Principles

### I. Fail Closed

<!-- gates:enforce surface=ci ref=canary -->

Anything the enforcement layer cannot read, parse, or demonstrably run MUST produce a
red result — never a silent skip. Malformed policy sections, unreadable acceptance
criteria, and unterminated fences block the run naming `file:line`. A tool that the
policy enables but the environment lacks is an enforcement gap and fails `doctor` and
the canary suite; it is never reported as a pass.

Rationale: this project's history contains three separate silent-no-op enforcement
bugs and one glob-union bypass. Every one of them "passed". A gate that can quietly
stop gating is worse than no gate, because it leaves the belief of coverage behind.

### II. Provable Enforcement

<!-- gates:enforce surface=ci ref=gates -->

Enforcement MUST leave evidence and MUST re-prove itself. Every `verify.sh` run
appends an attestation record (policy SHA-256, per-gate binary, version, pin,
candidate vs checked counts, result, duration). Canaries plant known violations in
disposable sandboxes and require the real entrypoints to reject them; an accepted
probe fails the suite naming the broken gate. `doctor` fails on the no-op signature
(`pass` with `candidates > 0` and `checked = 0`). New gate classes MUST ship with
their own canary and attestation surface before they are considered done.

Rationale: dogfooding is the test strategy. Arguments about coverage are replaced by
records of it; a broken gate is caught by a red canary step, not by an incident.

### III. One Policy, Three Boundaries

<!-- gates:enforce surface=policy ref=attestation.parity expect=error -->

`policy.json` is the single source of enforcement truth, and the same `verify.sh`
entrypoint runs at all three boundaries — agent (Claude Code hooks), git
(pre-commit), and CI. Boundary-specific behavior beyond `--boundary` labeling is
forbidden. Parity MUST be verified, not asserted: the synthetic `parity` gate
compares resolved tool versions against lockfile pins on every run, and drift fails
the run by default.

Rationale: the boundaries an agent could theoretically rewrite (its own hooks) are
backstopped by the ones it cannot (CI, branch protection) — but only if all three
provably run the same checks under the same policy.

### IV. Projection, Not Dependency

<!-- gates:enforce surface=ci ref=extension/runtime -->

The runtime is copied into the repository (`.specify/gates/`, `.claude/hooks/gates/`),
never symlinked or resolved from an installed extension. Enforcement MUST survive
extension removal, work for every collaborator on clone, and run offline in CI.
`policy.json` is user-owned: `init` seeds it, `upgrade` never overwrites it. The cost
of projection — drift between projected and source copies — is managed by
`.runtime-version`, `doctor`, and `upgrade`, and CI always projects fresh from source.

Rationale: an enforcement layer that disappears with its installer, or that needs
network access to run, fails exactly when it is needed most.

### V. The Spec Is a Boundary

<!-- gates:enforce surface=policy ref=spec.severity expect=error -->

Enhancements to this repository run as numbered spec-kit features (`specs/NNN-*/`)
through specify → clarify → plan → tasks → implement, gated by the repo's own gates.
Acceptance criteria are executable: success criteria land as fenced `accept` blocks
in the feature's `tasks.md`, and a feature whose `spec.md` declares
`**Status**: Complete` is enforced — any unchecked task or failing accept block
blocks the run. The Status flip to `Complete` is the final commit of an
implementation, made only when every task is checked and every block passes.

Rationale: a spec whose completion is asserted rather than enforced drifts exactly
like an unverified gate does. 002 shipped enforced by itself; later features get the
same treatment for free.

## Additional Constraints

- **Portability floor**: all runtime shell MUST run on macOS base — bash 3.2, BSD
  awk/sed, no `timeout(1)`, no associative arrays — and on Linux/GNU in CI. `jq` and
  `git` are the only hard runtime dependencies.
- **Evidence, never content**: attestation records carry hashes, versions, counts,
  and results — never file contents. Canary probes live in `mktemp` sandboxes and
  MUST NOT read user project files as probes nor write to the user's tree.
- **Pinned toolchain**: linters resolve `node_modules/.bin` first and are pinned via
  the lockfile; the lockfile is the shared source of truth that makes cross-boundary
  parity checkable. Accept blocks are read-only by contract and run under a watchdog.
- **User-owned configuration**: nothing in the runtime edits `policy.json` after
  `init`; schema validation rejects unknown fields instead of ignoring them.

## Development Workflow & Quality Gates

- The repo gates itself: CI projects the runtime from source and runs
  `verify.sh --boundary ci`, the canary suite, and all test suites on every PR. A red
  canary step means a broken gate, not a dirty tree.
- Every behavior lands with test-suite coverage in `tests/`, and every bug fix lands
  with a regression case that fails on the pre-fix code. Suites register in
  `tests/run.sh`.
- Feature branches are recreated from `main` per session; squash-merged remote
  branches are deleted before the next push. Prefer one PR per phase/story for
  reviewability.
- Commits follow Conventional Commits: no emoji, subject ≤ 72 characters, no
  AI-attribution trailers. PR descriptions record measured budgets (e.g. gate
  overhead) when a success criterion sets one.

## Governance

This constitution supersedes other practice documents where they conflict; README and
docs describe, the constitution prescribes. Amendments are made by PR that edits this
file, bumps the version per the policy below, updates the Sync Impact Report comment,
and propagates changes to the templates under `.specify/templates/` and to runtime
guidance docs in the same PR.

Versioning policy (semantic): MAJOR for removals or redefinitions of principles that
existing features relied on; MINOR for new principles or materially expanded
guidance; PATCH for clarifications and wording. Compliance is reviewed at two points:
the plan-phase "Constitution Check" gate in `plan-template.md` (violations must be
justified in the plan's complexity table or the design changes), and PR review
against the workflow rules above. The enforcement principles (I–III) are not
suspendable by policy configuration in this repository: disabling a gate class here
requires an amendment, not a `policy.json` edit.

**Version**: 1.0.0 | **Ratified**: 2026-07-08 | **Last Amended**: 2026-07-08
