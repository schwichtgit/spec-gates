# Feature Specification: Gate Speed and Visibility

**Feature Branch**: `007-gate-speed-visibility`

**Created**: 2026-10-26

**Status**: Draft

**Input**: User description: "Gate speed and visibility (GitHub issues #265
and #266; constitution 1.1.0 Principle III; reuses feature 006's
declared-skip mechanism). Covered accept blocks: a project-declared script
may report that an accept block's work was already done by the same run, so
the block is not repeated, at the agent and git boundaries only, never at
CI, with the script protected, covered blocks reported as their own result,
and a canary. Timings, timeline and progress: per-block results and
durations in the attestation, a timeline file written as each gate and block
ends, and a progress file written as each starts and ends, which the
pre-commit hook can show on the terminal."

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Don't repeat what the run already proved (Priority: P1)

A maintainer's commit gate re-runs, in accept blocks, tests that the
project's own test gate passed seconds earlier in the same run. They provide
a small script that, given an accept block, answers "this block's work was
already done in this run, because ...". At the agent and git boundaries the
gate asks the script before running each block of a Complete feature; a
block the script vouches for is not run and is reported as covered with the
script's reason. At CI every block always runs.

**Why this priority**: it removes the largest avoidable cost in a downstream
commit gate (about 100 seconds of a 5 to 7 minute commit) without weakening
what CI proves.

**Independent Test**: in a project with a Complete feature whose accept block
fails when run, declare a covering script that vouches for that block; run
the gate at git and see the block reported covered and the run pass; run it
at CI and see the block run and the run fail.

**Acceptance Scenarios**:

1. **Given** a declared covering script that vouches for a block, **When**
   the gate runs at the git boundary, **Then** the block is not run, is
   reported as covered with the script's one-line reason, and does not fail
   the run.
2. **Given** the same policy, **When** the gate runs at the CI boundary,
   **Then** the script is not consulted and the block runs as today.
3. **Given** a covering script that exits non-zero, prints nothing, prints
   more than one line, or does not answer within its time limit, **When**
   the gate runs, **Then** the block runs as today.
4. **Given** no covering script declared, **When** the gate runs at any
   boundary, **Then** every block runs exactly as today.
5. **Given** a covering script whose answer is cut off by its time limit,
   **When** the gate runs, **Then** the script's process group is stopped
   and the block runs; the run is not held longer than the limit plus 5
   seconds by the script.

---

### User Story 2 - The covering script cannot be quietly changed (Priority: P1)

The covering script decides whether proof is skipped, so changing it is as
consequential as changing the policy. The maintainer wants the script
treated like the policy file: a change to it needs a declared, approved
protected change, at every boundary, whatever the policy says.

**Why this priority**: without it, a one-line edit to an ordinary project
script ("always answer covered") turns off accept-block enforcement at the
agent and git boundaries with no review trail.

**Independent Test**: declare a covering script; edit it and try to commit
and open a pull request without a protected-change declaration; both are
refused; with the declaration and an approver, both pass.

**Acceptance Scenarios**:

1. **Given** a declared covering script, **When** a commit changes it
   without a protected-change declaration and an approver, **Then** the
   commit is refused, as for the policy file.
2. **Given** the same, **When** a pull request carries such a commit,
   **Then** the pull request check refuses it.
3. **Given** the same, **When** the agent edits the script, **Then** the
   agent boundary treats it as a protected file.
4. **Given** a policy that names a covering script that does not exist or
   is not a regular file inside the project, **When** the policy is
   validated, **Then** it is refused naming the path.

---

### User Story 3 - See every covered block, and prove CI never covers (Priority: P1)

Reviewers and auditors need to see what was not run. Every covered block is
named in the text report, the machine-readable output and the attestation,
apart from passed blocks, with its reason. A canary proves at every run that
a script claiming to cover a failing block cannot make CI pass.

**Why this priority**: covering is only acceptable under the constitution if
it is visible and provably absent from CI (Principle III, 1.1.0).

**Independent Test**: run the gate at git with one covered and one passed
block; the report, the machine-readable output and the attestation each name
the covered block and count it apart from the passed one; the canary suite
reports the new canary blocked.

**Acceptance Scenarios**:

1. **Given** a run with covered blocks, **When** it ends, **Then** the
   summary line of the spec gate counts covered blocks apart from passed
   ones, and each covered block is named with its reason.
2. **Given** the same run, **When** the attestation is written, **Then** it
   records each covered block with its feature, task, reason and boundary,
   in the same declared-skip shape feature 006 uses for gates.
3. **Given** a covering script that vouches for the canary's failing block,
   **When** the canary runs the gate at CI, **Then** the run fails; the
   canary reports blocked.

---

### User Story 4 - Per-block timings in the record (Priority: P2)

A maintainer wants to know which accept blocks are slow. The attestation
records, for every accept block of every Complete feature, its result
(passed, failed, timed out, covered) and its duration.

**Why this priority**: it is the data the timeline and the covering decision
rest on, and it is useful alone for finding slow blocks.

**Independent Test**: run the gate on a project with two accept blocks of
known duration; the attestation lists both with results and durations close
to the known values.

**Acceptance Scenarios**:

1. **Given** a run that executes accept blocks, **When** the attestation is
   written, **Then** each block has an entry with its feature, task,
   verifies label, result and duration in seconds.
2. **Given** a covered block, **When** the attestation is written, **Then**
   its entry has result covered and the time spent asking the script.

---

### User Story 5 - Watch a long run as it happens (Priority: P2)

In CI, a maintainer wants the log to show which gate or block took the time,
as collapsible sections. Locally, a developer committing wants to see
progress instead of a silent wait of several minutes.

**Why this priority**: diagnosing a slow gate today means reconstructing it
from report files after the fact.

**Independent Test**: run the gate with a timeline file and a progress file
named; the timeline gets one line per gate and per block as each ends, in
order; the progress file gets a line as each starts and ends; a commit in a
terminal shows progress lines while the gate runs.

**Acceptance Scenarios**:

1. **Given** a timeline file is named for the run, **When** each gate and
   each accept block ends, **Then** one line is appended with its name,
   boundary, start, end, result and reason, before the next one starts.
2. **Given** a progress file is named, **When** each gate and block starts
   and ends, **Then** one line is appended for each event.
3. **Given** a commit made from a terminal, **When** the pre-commit gate
   runs, **Then** the terminal shows a progress line as each gate and block
   starts and ends, and the final report as today.
4. **Given** neither file is named and no terminal, **When** the gate runs,
   **Then** its output is exactly as today.

---

### Edge Cases

- The covering script itself changes files: covering runs before the block's
  read-only snapshot; the script's writes are the project's, but a script
  that writes tracked files is reported by the next block's or gate's checks
  as any other write would be.
- The covering script vouches for a block of a feature that is not Complete:
  incomplete features' blocks run only on request (`--accept`) and are
  informational; the script is consulted there too, and the report shows the
  block as `covered (informational)`, recording nothing as enforced.
- A Complete feature with every block covered: the feature's outcome is
  passed, as when its blocks run; it is told apart by its covered count
  equalling its block count, and the spec gate's summary names each covered
  block.
- The gate lock defers an agent run: deferred blocks are named as part of
  the deferred spec gate, as feature 006 already does for gates.
- The timeline or progress file cannot be written (a read-only directory):
  the run continues and warns once; evidence loss never changes a gate
  outcome, as with the attestation today.
- A block's output is huge or binary: the timeline and progress lines carry
  names, times, results and fixed reasons only, never output.
- Two runs in one tree: the gate lock (0.4.2) serializes them, so timeline
  and progress lines never interleave from two runs.
- Clock changes during a run: durations are whole seconds from the system
  clock; a negative duration is recorded as 0.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The policy MAY declare a covering script: a project-relative
  path to a regular file inside the project, plus the boundaries where
  covering applies (agent, git, or both). CI MUST NOT be declarable; a policy
  that tries is refused at validation.
- **FR-002**: At a boundary the declaration names, before running each
  accept block, the gate MUST ask the covering script, passing the feature,
  the task, and the block's text, from the project root, under a time limit
  (30 seconds by default, configurable).
- **FR-003**: Exit status 0 with exactly one non-empty line on standard
  output MUST mark the block covered with that line as its reason; any other
  outcome (non-zero exit, no line, several lines, time limit exceeded, the
  script missing or not executable) MUST run the block as today. The
  covering script can never fail a block.
- **FR-004**: A covered block MUST NOT run, MUST NOT count as passed or
  failed, and MUST be reported by name with its reason in the text report,
  in the spec gate's summary (so the machine-readable output names it too)
  and in the attestation, using feature 006's declared-skip mechanism and
  shape.
- **FR-005**: At the CI boundary, at any boundary the declaration does not
  name, and in a run without a boundary, the covering script MUST NOT be run
  and every block MUST run.
- **FR-006**: The declared covering script MUST be protected at every
  boundary like the policy file: a commit or pull request changing it needs
  a protected-change declaration and an approver, and the agent boundary
  treats it as protected, whatever else the policy lists.
- **FR-007**: A covering script that exceeds its time limit MUST have its
  process group stopped, and the block then runs.
- **FR-008**: The reason recorded for a covered block MUST be the script's
  one line, truncated to 200 characters, with control characters removed;
  no other script output is recorded.
- **FR-009**: The parity gate MUST fail at CI if any accept block was
  reported covered, naming the blocks.
- **FR-010**: A canary MUST prove that a covering script vouching for a
  failing block cannot make the CI boundary pass.
- **FR-011**: The attestation MUST record, for every accept block the run
  evaluated, its feature, task, verifies label, result (passed, failed,
  timeout, covered) and duration in seconds.
- **FR-012**: When the run is given a timeline file, the gate MUST append
  one tab-separated line per gate and per accept block as each ends: name,
  boundary, start and end (epoch seconds), result, reason. A block's name
  identifies it uniquely within the run, also when one task holds several
  blocks.
- **FR-013**: When the run is given a progress file, the gate MUST append
  one line as each gate and accept block starts and as each ends.
- **FR-014**: The pre-commit hook MUST show progress lines on the terminal
  while the gate runs when its standard error is a terminal, and MUST NOT
  change its output otherwise.
- **FR-015**: Timeline and progress lines MUST carry names, boundaries,
  times, results and fixed reasons only, never command or block output.
- **FR-016**: A timeline or progress file that cannot be written MUST NOT
  change any gate outcome; the run warns once. Only the run the files were
  given to writes them: commands it starts (gates, accept blocks, nested
  runs on other directories) MUST NOT write to them.
- **FR-017**: Without a covering script declared, a timeline or progress
  file named, or a terminal at pre-commit, every run MUST behave and print
  exactly as before.
- **FR-018**: The policy schema, the validator and the policy contract MUST
  cover the new keys; declaring a covering script, or adding a boundary to
  it, is a weakening deviation.
- **FR-019**: Doctor MUST show whether a covering script is declared, where
  it applies, and whether it is protected and executable.

### Key Entities

- **Covering script**: a project file the policy names, asked about each
  accept block at declared boundaries; answers covered with one line of
  reason, or anything else. Protected like the policy.
- **Covered block**: an accept block not run because the covering script
  vouched for it; a declared skip in feature 006's sense, with the script's
  reason. Never at CI.
- **Block entry**: the attestation record of one accept block in one run:
  feature, task, verifies label, result, duration, and the covered reason
  where applicable.
- **Timeline line**: one record per ended gate or block, for CI log
  sections.
- **Progress line**: one record per start or end of a gate or block, for a
  live view.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: In a project whose accept blocks repeat work its own test gate
  did, a commit gate with a covering script spends no time running the
  covered blocks (only the time to ask the script, at most its time limit
  per block).
- **SC-002**: At CI, 100% of accept blocks run in every run, whatever the
  covering script says; the canary proves it on every canary run.
- **SC-003**: Every covered block is named, with its reason, in 100% of runs
  that cover one: in the report, the machine-readable output and the
  attestation.
- **SC-004**: A change to the covering script without a protected-change
  declaration is refused at the git and pull request boundaries in 100% of
  attempts.
- **SC-005**: With a timeline file named, a CI log can show one section per
  gate and per block with its duration, written as each ends.
- **SC-006**: A developer committing from a terminal sees the name of the
  gate or block that is running before any of its own work starts.
- **SC-007**: Every existing policy, with no new keys and no files named,
  produces the same report and exit code as before.

## Assumptions

- The covering script is the project's own; spec-gates defines the
  question and the answer format, not how the script decides (a ledger of
  passed tests keyed by content, a test-cache lookup).
- The block's text is handed to the script as a file, so the script can
  read the commands the block would run.
- Covering applies to accept blocks only; gates themselves are skipped by
  feature 006's `skip_at`, not by the covering script.
- The covering time limit defaults to 30 seconds per block; a project with
  many blocks keeps its script fast.
- Durations are whole seconds; sub-second timing is out of scope.
- The progress view in pre-commit is plain lines on standard error, not a
  redrawn status line, so it works in any terminal and in logs.
- Rendering CI log sections (GitLab section markers, GitHub groups) from the
  timeline file is the project's pipeline step; spec-gates documents an
  example but does not write platform markers itself.
