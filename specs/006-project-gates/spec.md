# Feature Specification: Project Gates per Boundary

**Feature Branch**: `006-project-gates`

**Created**: 2026-10-25

**Status**: Draft

**Input**: User description: "Project quality gates alongside the built-in
walk, selectable per boundary (GitHub issue #243; constitution v1.1.0
Principle III). Extra named gates next to the prettier/markdownlint/shellcheck
walk, each reported as its own gate; a gate may skip earlier boundaries by
declaration, never CI, with every skip named and the parity gate verifying CI
runs everything; a documented way to run the built-in walk from a custom
command; configurable severity for `task test`."

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Declare project gates next to the built-in checks (Priority: P1)

A maintainer of a project that uses spec-gates wants lint, type check, unit
tests with a coverage floor, and manifest validation to run through the gate
policy, at every boundary, next to the built-in formatting and lint checks.
They list the checks in the policy by name and command. Each one appears in
the gate report as its own gate with its own result, and a failing one blocks
exactly as a built-in gate does.

**Why this priority**: today the only way to add a check is to replace the
built-in walk with a custom script, which drops the built-in checks or makes
the project re-implement them through an undocumented internal script. This
story removes that either/or and is useful on its own, with no boundary
selection at all.

**Independent Test**: add two project gates to a policy (one passing, one
failing) next to an enabled built-in check; run the gate at each boundary and
confirm the report lists the built-in check and both project gates
separately, the failing gate fails the run, and the attestation records all
three.

**Acceptance Scenarios**:

1. **Given** a policy with the built-in walk enabled and project gates
   `lint` and `typecheck`, **When** the gate runs, **Then** the report lists
   the built-in checks, `lint` and `typecheck`, each with its own result.
2. **Given** a project gate with severity error whose command exits non-zero,
   **When** the gate runs, **Then** the run fails and the summary line names
   that gate and its failing line.
3. **Given** a project gate with severity warning whose command fails,
   **When** the gate runs, **Then** the run reports a warning for that gate
   and does not fail.
4. **Given** a project gate whose command prints a `##gates-fail##` line,
   **When** it fails, **Then** that line is the gate's summary, as for every
   other gate.
5. **Given** a project gate whose command does not finish within its time
   limit, **When** the gate runs, **Then** the gate fails with a timeout
   naming the limit, and its leftover processes are stopped.
6. **Given** a policy that names a project gate after a built-in gate
   (`prettier`, `spec`, `parity`, ...) or names two gates the same, **When**
   the policy is validated, **Then** it is rejected naming the duplicate.

---

### User Story 2 - Keep slow gates out of the agent boundary, never out of CI (Priority: P1)

The same maintainer has gates that are slow or need the network (a
production build, an online manifest validator). Running them when every
agent session ends costs minutes. They declare that these gates do not run at
the agent boundary. Commits and CI still run them. Every run that skips a
gate says so by name, and CI cannot be told to skip anything.

**Why this priority**: without it, projects either accept a slow Stop hook
or move checks out of the policy, which loses parity. The constitution
(Principle III, 1.1.0) allows the skip only in this declared, reported form,
and requires CI to run the full policy.

**Independent Test**: declare one gate that skips the agent boundary; run the
gate at the agent, git and CI boundaries; confirm the agent run reports the
gate as skipped by declaration and does not run it, and the git and CI runs
run it.

**Acceptance Scenarios**:

1. **Given** a gate declared to skip the agent boundary, **When** the gate
   runs at the agent boundary, **Then** the gate does not run and the
   summary, the machine-readable output and the attestation each list it as
   skipped by declaration at that boundary.
2. **Given** the same policy, **When** the gate runs at the git or CI
   boundary, **Then** the gate runs.
3. **Given** a policy that declares a gate skips the CI boundary, **When** the
   policy is validated, **Then** it is rejected: CI cannot be skipped.
4. **Given** any gate command, **When** it runs, **Then** it can read which
   boundary is running it, so the command itself can adapt (for example, a
   faster mode at git).
5. **Given** a policy with declared skips, **When** the health check runs,
   **Then** it lists each gate with the boundaries it skips.
6. **Given** a CI run, **When** it completes, **Then** the parity check
   confirms that CI ran every gate the policy declares (the full set, which
   contains every earlier boundary's set), and a CI run that ran fewer gates
   than the policy declares fails the parity check naming the missing ones.

---

### User Story 3 - Run the built-in walk from a custom command (Priority: P2)

A project that keeps a custom orchestrator (its own script runs everything)
wants the built-in formatting and lint checks inside that script, without
depending on an internal file that may change between releases. It calls a
documented entry point that runs the built-in walk with the current policy
and returns its result.

**Why this priority**: with Story 1 most projects no longer need a custom
orchestrator, but existing ones call the internal script today and break
silently when it changes.

**Independent Test**: from a custom command, call the documented entry point
in a project with one badly formatted file; confirm it fails and names the
file, and passes once the file is fixed.

**Acceptance Scenarios**:

1. **Given** a custom orchestrator that calls the documented built-in walk,
   **When** a file violates an enabled built-in check, **Then** the walk
   fails and its output names the file.
2. **Given** the documented entry point, **When** the walk passes, **Then**
   it exits successfully and prints one result line per built-in check.
3. **Given** a project whose custom command calls the internal dispatch
   script directly, **When** the health check runs, **Then** it recommends
   the documented entry point.

---

### User Story 4 - Let a failing `task test` block (Priority: P3)

A project using the `task` orchestrator wants a failing test run to block a
commit, not just warn.

**Why this priority**: small and independent; the default stays a warning so
nothing changes for existing projects.

**Independent Test**: set the test step's severity to error in a `task`
project with a failing test; confirm the run fails; remove the setting and
confirm it warns as before.

**Acceptance Scenarios**:

1. **Given** the `task` orchestrator with the test severity set to error,
   **When** `task test` fails, **Then** the run fails.
2. **Given** the `task` orchestrator without the setting, **When** `task test`
   fails, **Then** the run warns, as today.

---

### Edge Cases

- A project gate's command is missing or not executable: the gate fails
  (fail closed) naming the command; it is never reported as passed or skipped.
- A gate declared to skip the agent boundary while the agent boundary run is
  also skipped by the gate lock (another run holds the working tree): the run
  reports the lock skip, as in 0.4.2; per-gate skips are reported only by runs
  that actually evaluate gates.
- A policy declares skips for the git boundary only: the agent boundary runs
  the gate; only git skips it.
- A policy declares a boundary name that does not exist: rejected at
  validation, naming the value.
- A project gate writes to tracked files: reported like any other gate's side
  effects; project gates are not read-only by contract (unlike accept
  blocks), and the documentation says so.
- The `custom` orchestrator plus project gates: both run; the project gates
  are additions, whatever the orchestrator.
- A gate prints more output than the report keeps: the summary still names
  its failing line (the 0.4.2 summary rules apply).
- An older runtime reading a policy with project gates: policy validation
  refuses the unknown keys rather than silently dropping the gates.
- Very many project gates: they run one after another in declared order, and
  each one's duration is recorded.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The policy MUST accept a list of project gates, each with a
  unique name, a command, and a severity (error, warning or info), run in
  addition to whatever the configured orchestrator runs.
- **FR-002**: Each project gate MUST be reported as its own gate in the text
  summary, the machine-readable output and the attestation, with result,
  reason, and duration.
- **FR-003**: Project gates MUST follow the existing gate rules for output
  capture, failure summary (including `##gates-fail##`) and severity mapping.
- **FR-004**: Each project gate MUST run under a time limit (a per-gate value,
  else a policy-wide default, else a documented built-in default); a gate
  that exceeds it fails naming the limit, and everything it started is
  stopped.
- **FR-005**: A project gate whose command cannot be started MUST fail, naming
  the command.
- **FR-006**: Gate names MUST NOT collide with built-in gate names or with
  each other; a policy that does is rejected at validation, naming the name.
- **FR-007**: A gate MAY declare earlier boundaries (agent, git) at which it
  does not run. The CI boundary MUST NOT be declarable; a policy that tries is
  rejected at validation.
- **FR-008**: A gate skipped at a boundary by declaration MUST be reported by
  name, with the reason `skipped by declaration at <boundary>`, in the
  summary, the machine-readable output and the attestation. It MUST NOT count
  as passed.
- **FR-009**: The boundary-skip declaration and its reporting MUST be one
  general mechanism ("this item does not run at boundary X, by declaration,
  reported"), usable for other gate items in later features (accept blocks in
  feature 007) without a second reporting shape.
- **FR-010**: Every gate command (project gates, `task`, `custom`, the
  built-in walk) MUST be able to read the running boundary from its
  environment.
- **FR-011**: The parity gate MUST verify at the CI boundary that every gate
  the policy declares ran, and fail naming any declared gate that did not run
  there. At earlier boundaries it MUST verify that every gate not run was
  skipped by a declaration that names that boundary.
- **FR-012**: The health check MUST list each project gate with the boundaries
  it skips, and flag a custom command that calls the internal dispatch script
  directly, recommending the documented entry point.
- **FR-013**: A documented, supported entry point MUST run the built-in walk
  alone with the current policy and report one result per built-in check,
  for use from custom commands; its interface is stable across minor releases.
- **FR-014**: The `task` orchestrator's test step MUST take a configurable
  severity; without the setting it stays a warning.
- **FR-015**: A policy without the new keys MUST behave exactly as before
  (same gates, same results, same output).
- **FR-016**: The policy schema and the policy contract MUST cover the new
  keys, so a baseline can pin them and a deviation (adding a skip, lowering a
  severity, raising a time limit) is detected as weakening.
- **FR-017**: A canary MUST prove that a failing project gate blocks, and that
  a gate declared to skip an earlier boundary still runs, and still blocks, at
  CI.
- **FR-018**: Project gates MUST be part of the attestation record with the
  same fields as other gates, plus the skipped boundaries where applicable.

### Key Entities

- **Project gate**: a named check the project declares: command, severity,
  time limit, boundaries it skips. Reported like a built-in gate.
- **Boundary skip declaration**: the statement "item X does not run at
  boundary Y", made in the policy, never naming CI. Shared with later
  features.
- **Gate set of a boundary**: the gates a boundary runs: every declared gate
  minus those whose declaration names that boundary. CI's set is always the
  full set.
- **Built-in walk**: the formatting and lint checks the runtime runs from the
  policy's include and exclude globs.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A project can add a lint, type check, test-with-coverage, and
  manifest check to its policy and see each as its own gate at all three
  boundaries, with no custom script and no reference to internal runtime
  files.
- **SC-002**: A gate declared to skip the agent boundary adds no time to the
  agent boundary run; the skip is named in 100% of agent runs that evaluate
  gates.
- **SC-003**: No policy can make CI skip a gate: every attempt is rejected at
  validation, and a CI run that ran fewer gates than declared fails.
- **SC-004**: Every existing policy (without the new keys) produces the same
  gate list and results before and after the upgrade.
- **SC-005**: A hung project gate never holds a run past its time limit plus
  a few seconds of cleanup.
- **SC-006**: The canary suite proves the new gate class blocks, at the CI
  boundary in particular, on every run.

## Assumptions

- Project gates run sequentially after the orchestrator's gates, in declared
  order; parallel execution is out of scope.
- The default time limit for a project gate is 600 seconds; projects set a
  shorter or longer value per gate or policy-wide.
- Commands run through the shell from the project root, like the existing
  `custom` command.
- Coverage floors, test frameworks and manifest validators are the project's
  own commands; spec-gates runs and reports them, it does not implement them.
- Skips are declared per gate; a skip for a whole class of gates or for the
  built-in walk is out of scope for this feature.
- The 0.4.2 gate lock's agent-boundary skip stays as is and is reported as
  today; it is a whole-run deferral, not a per-gate declaration.
- Accept blocks (the spec gate) keep their own time limit (`spec.timeout_s`);
  covered accept blocks are feature 007, which reuses FR-009's mechanism.
