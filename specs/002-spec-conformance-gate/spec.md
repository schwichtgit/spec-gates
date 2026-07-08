# Feature Specification: Spec Conformance — Acceptance Criteria as Executable Gates

**Feature Branch**: `002-spec-conformance-gate`

**Created**: 2026-07-07

**Status**: Draft

**Input**: User description: "spec-conformance gate: acceptance criteria in
tasks.md become executable accept blocks; verify.sh gains a spec gate class;
converge drift becomes enforceable"

## Context

Feature 001 made the _tool_ gates self-evidencing: every run leaves an
attestation, canaries prove the gates still block, and parity is verified
against committed pins. But the artifact this whole system is named for — the
spec — is still enforced by nothing. Acceptance criteria live in `tasks.md`
and `spec.md` as prose; whether they hold is asserted by whoever checks the
task boxes. `converge` can _report_ drift between the spec and the codebase,
but its output is advisory: a feature can be declared complete while its
criteria silently stop holding, and no boundary will ever object.

This feature makes the spec a boundary. An acceptance criterion can be
expressed as an executable **accept block** — a small command with expected
exit semantics, attached to the task or success criterion it verifies. A new
`spec` gate class in the gate runner discovers these blocks across the
project's feature directories and executes them with the same severity,
policy, attestation, and canary machinery as every other gate. For a feature
marked complete, an unchecked task or a failing accept block blocks the run —
"the spec is done" becomes a checked property, not a claim.

## Clarifications

### Session 2026-07-07

- Q: How should accept blocks be authored in a feature's `tasks.md`? → A: As
  a fenced code block with the `accept` info string, placed immediately
  after the task or criterion line it verifies (adjacency gives the
  association); multi-line commands allowed; an optional
  `# verifies: SC-00N` comment line makes the criterion reference explicit.
- Q: What marks a feature "complete" and turns on enforcement for it? → A:
  The existing `**Status**:` field in the feature's `spec.md` set to
  `Complete`. The field already exists in every feature spec, is
  human-auditable in the artifact of record, and existing features (whose
  Status still reads `Draft`) are untouched until explicitly marked.
- Q: At which boundaries do accept blocks actually execute? → A: All
  boundaries, every run — identical behavior at the agent, git, and CI
  boundaries preserves the parity thesis; the per-block timeout and the
  30-second whole-gate budget (SC-004) bound interactive latency, and the
  policy's `enabled`/`severity` remain the escape hatches.
- Q: Do accept blocks of features not marked complete execute during normal
  gate runs? → A: No — parse-only (malformed blocks still fail the gate);
  their execution is on demand (explicit gate-runner flag or doctor) and is
  informational. Blocks execute automatically, and enforce, once the
  feature's Status is `Complete`. Normal-run cost stays proportional to
  shipped features.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Acceptance criteria run as checks (Priority: P1)

A feature author writing `tasks.md` attaches an accept block to a task or
success criterion: a one-line command that exits zero exactly when the
criterion holds (e.g., "the canary suite fails when a gate is stubbed" becomes
a command that stubs a gate in a sandbox and asserts the suite exits nonzero).
When the gate runs at any boundary, the `spec` gate discovers every feature
directory and parses its accept blocks; for complete features (and for any
feature on demand) it executes each block and reports pass or fail **per
criterion**, naming the feature and the criterion it verifies.

**Why this priority**: this is the smallest independently valuable slice —
executable criteria are useful the moment they exist, even before any
enforcement wiring: a maintainer can run the gate's on-demand mode and see
which documented criteria demonstrably hold _today_, feature by feature.

**Independent Test**: add an accept block to a feature's `tasks.md`, run the
gate's on-demand execution for that feature, and see the per-criterion
result; flip the command to a failing one and see the named failure.

**Acceptance Scenarios**:

1. **Given** a feature whose accept blocks all pass, **When** the gate runs,
   **Then** the `spec` gate reports pass and the per-criterion results name
   each verified criterion.
2. **Given** an accept block whose command exits nonzero, **When** the gate
   runs, **Then** the result names the feature, the criterion, and the
   command's exit status, and shows its captured output.
3. **Given** a malformed accept block (unparseable annotation), **When** the
   gate runs, **Then** the `spec` gate fails naming the file and location —
   a criterion that cannot be parsed is never silently skipped.

---

### User Story 2 - Completion is enforced, not asserted (Priority: P2)

A feature is explicitly marked complete. From that moment, every boundary
holds it to its own spec: if any task is left unchecked, or any accept block
fails, the gate run is blocked at the policy's severity, naming the feature
and the specific drift. Converge's advisory drift report becomes an
enforceable property — a regression that breaks a shipped feature's
acceptance criterion is caught by the very next gate run, not by the next
human who happens to reread the spec.

**Why this priority**: this is the enforcement payoff, but it depends on
Story 1's discovery and execution machinery, and it only bites for features
whose authors adopted accept blocks — so it lands second.

**Independent Test**: mark a sandbox feature complete with one accept block
passing (expect pass), then break the criterion's command (expect the run
blocked, feature and criterion named), then uncheck a task instead (expect
the run blocked naming the unchecked task).

**Acceptance Scenarios**:

1. **Given** a feature marked complete with all tasks checked and all accept
   blocks passing, **When** the gate runs, **Then** the `spec` gate passes.
2. **Given** a feature marked complete with a failing accept block, **When**
   the gate runs, **Then** the run is blocked at the configured severity,
   naming the feature and the failing criterion.
3. **Given** a feature marked complete with an unchecked task, **When** the
   gate runs, **Then** the run is blocked naming the feature and the
   unchecked task.
4. **Given** a feature not marked complete, **When** the gate runs, **Then**
   its accept blocks are parsed and validated but not executed, nothing
   about it blocks the run, and its execution results remain available on
   demand as informational output.

---

### User Story 3 - The spec gate leaves evidence and proves itself (Priority: P3)

A reviewer auditing a run sees the `spec` gate in the attestation record like
any other gate: how many features were discovered, how many accept blocks ran,
passed, failed, or were reported informationally, and for which features. The
canary suite gains a spec-gate canary — a sandboxed feature marked complete
with a deliberately failing accept block that the gate must reject — so a
broken spec gate is caught the same way a broken formatter gate is. Doctor
reports what the spec gate can see (features discovered, accept blocks
parsed, complete features under enforcement) and fails on unparseable blocks.

**Why this priority**: this integrates 002 into 001's provable-enforcement
machinery. It is what keeps the spec gate honest, but it presupposes both
prior stories.

**Independent Test**: run the gate and inspect the attestation's `spec`
entry; stub the accept-block runner to a no-op and run the canary suite
(expect a loud, named failure).

**Acceptance Scenarios**:

1. **Given** any gate run, **When** it completes, **Then** the attestation
   record contains a `spec` gate entry with features discovered and accept
   blocks run/passed/failed counts.
2. **Given** a spec gate whose execution has been stubbed to a no-op,
   **When** the canary suite runs, **Then** the suite exits nonzero naming
   the spec gate.
3. **Given** a project with feature directories, **When** doctor runs,
   **Then** it reports features discovered, accept blocks parsed, and
   complete features under enforcement.

---

### Edge Cases

- A feature directory has no `tasks.md`, or `tasks.md` has no accept blocks:
  the feature is reported with zero criteria; nothing fails. A feature
  **marked complete** with zero accept blocks is reported informationally
  (completion asserted but nothing executable to hold it to) — visible, not
  blocking.
- A feature has all tasks checked but is not marked complete: doctor nudges
  (informational) — enforcement never turns on implicitly.
- An accept block's command needs a tool that is not installed: the command
  exits nonzero and the criterion fails with the captured error — for a
  complete feature this blocks (fail closed); "skipped" is not an outcome an
  accept block can have.
- An accept block hangs: a per-block timeout (policy-configurable) kills it
  and the criterion fails naming the timeout.
- An accept block mutates the working tree (formats a file, writes an
  artifact outside temp space): the gate detects the tree change, fails that
  criterion naming the mutation, and never auto-reverts user files.
- An accept block is slow but legitimate: the timeout is configurable
  per-project; the default budget keeps the whole `spec` gate within the
  boundary's interactive tolerance.
- The repository is not a spec-kit project (no feature directories): the
  `spec` gate passes trivially and the attestation records zero features —
  projecting the gate into non-spec-kit consumer repos must not break them.
- Accept blocks contain arbitrary shell committed to the repo: they execute
  with the same trust as git hooks and CI steps already do; v1 executes the
  working tree's accept blocks, same as every other gate class (see
  Assumptions).
- Two features' accept blocks interfere (shared temp path, port): execution
  is serialized in deterministic order; blocks are documented as required to
  be self-contained and read-only.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The gate runner MUST gain a `spec` gate class that discovers
  every feature directory under the project's specs root and parses accept
  blocks from each feature's `tasks.md`, in deterministic order.
- **FR-002**: An accept block is a fenced code block with the `accept` info
  string placed immediately after the task or criterion line it verifies
  (association by adjacency); it MAY contain multiple command lines and an
  optional `# verifies: SC-00N` comment line naming the criterion
  explicitly. Exit 0 of the block's command sequence means the criterion
  holds; any nonzero exit means it does not.
- **FR-003**: Accept blocks MUST execute serially from the repository root,
  each under a per-block timeout (default 30 seconds, policy-configurable),
  with output captured and shown only on failure. Execution behavior MUST
  be identical at every boundary (agent, git, CI) — no boundary runs a
  reduced form of the `spec` gate.
- **FR-004**: A feature's completion marker is the `**Status**:` field in
  its `spec.md` set to `Complete` (any other value, or a missing field,
  means not complete). For a feature marked complete, the `spec` gate MUST
  enforce that every
  task is checked and every accept block passes, at the policy's severity
  (default `error`). For a feature not marked complete, accept blocks MUST
  be parsed and validated but not executed during normal runs; on-demand
  execution (explicit gate-runner flag or doctor) reports their results
  informationally and MUST NOT block.
- **FR-005**: A malformed accept block MUST fail the `spec` gate naming the
  file and location; unparseable criteria are never silently skipped.
- **FR-006**: If executing an accept block changes the working tree, the
  `spec` gate MUST fail that criterion naming the mutation; it MUST NOT
  auto-revert user files.
- **FR-007**: The policy schema MUST gain an optional `spec` section
  (enabled flag, severity, feature include/exclude patterns, per-block
  timeout) validated by both the JSON schema and the shell validator;
  absence of the section means `enabled: true`, `severity: error`, all
  features included, timeout 30s.
- **FR-008**: Every gate run's attestation record MUST include a `spec` gate
  entry with features discovered, accept blocks parsed, blocks
  executed/passed/failed, and per-feature outcomes, following the existing
  attestation rules (no file contents; counts, names, and results only).
- **FR-009**: The canary suite MUST gain a spec-gate canary: a sandboxed
  feature marked complete containing a deliberately failing accept block,
  which the `spec` gate must reject; a canary that is not rejected fails
  the suite naming the spec gate.
- **FR-010**: Doctor MUST report spec-gate discovery (features found, accept
  blocks parsed, complete features under enforcement), MUST fail on
  unparseable accept blocks, and SHOULD nudge when a feature has all tasks
  checked but no completion marker.
- **FR-011**: In a repository with no feature directories, the `spec` gate
  MUST pass trivially with an attestation entry recording zero features.
- **FR-012**: All new code MUST run on bash 3.2 (macOS `/bin/bash`) with
  `jq` as the only hard dependency, offline.

### Key Entities

- **Accept block**: an executable acceptance criterion — a fenced `accept`
  code block adjacent to the task or success criterion it verifies in a
  feature's `tasks.md`, containing the command sequence (exit 0 = holds)
  and an optional `# verifies:` criterion reference.
- **Completion marker**: the `**Status**: Complete` value in a feature's
  `spec.md` — the explicit per-feature declaration that turns informational
  reporting into enforcement.
- **`spec` gate class**: the gate-runner entry that discovers features, runs
  accept blocks, and folds results into severity/policy/attestation
  machinery like any other gate.
- **Policy `spec` section**: user-owned configuration (enabled, severity,
  feature include/exclude, timeout) following existing policy-ownership
  rules (init seeds, upgrade never overwrites).
- **Conformance result**: the per-feature outcome set (criteria passed /
  failed / informational, task drift) recorded in the attestation.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A feature marked complete with a deliberately failing accept
  block is blocked by the very next gate run at every boundary, with the
  feature and criterion named — proven by a regression test.
- **SC-002**: A feature marked complete with an unchecked task is blocked by
  the very next gate run, with the unchecked task named — proven by a
  regression test.
- **SC-003**: Stubbing the accept-block runner to a no-op is detected by the
  canary suite in a single run, naming the spec gate.
- **SC-004**: On a repository with no accept blocks, the `spec` gate adds no
  more than 1 second to a gate run; on this repository with its own accept
  blocks, the full `spec` gate completes within 30 seconds.
- **SC-005**: This feature ships dogfooded: its own success criteria are
  expressed as accept blocks in its own `tasks.md`, and the repository's
  gate enforces them once 002 is marked complete.
- **SC-006**: All existing test suites remain green and the repository's own
  gate (with the `spec` gate active) stays green in CI.

## Assumptions

- Accept blocks are trusted, repo-committed content — the same trust level
  as git hooks, CI steps, and the gate runtime itself. Sandboxing beyond
  timeout + mutation detection (e.g., containerization) is out of scope for
  v1.
- Accept blocks execute against the working tree, like every other gate
  class; verifying a historical revision's conformance is out of scope.
- The completion marker is maintained by the feature workflow (implement /
  converge mark features complete); enforcement never turns on implicitly
  from checkbox state alone, so adopting 002 cannot retroactively break
  existing features until they are explicitly marked.
- Feature 001's `tasks.md` is not retrofitted with accept blocks as part of
  this feature (it may be, later, as an independent chore); 002's own
  `tasks.md` is the dogfooding target (SC-005).
- The specs root is the project's existing feature-directory convention
  (`specs/` by default); multi-root discovery is out of scope.
- Accept blocks are read-only by contract; mutation detection (FR-006) is
  the enforcement backstop, not a sandbox guarantee.
- `converge` remains the tool that _diagnoses_ drift and appends remediation
  tasks; the `spec` gate is the boundary that _blocks_ on it. No change to
  converge's behavior is required for v1.
