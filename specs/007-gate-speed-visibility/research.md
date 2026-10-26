# Research: Gate Speed and Visibility

Decisions for [plan.md](plan.md), grounded in the runtime at `655eb08`
(feature 006 complete on main).

## R1. Policy shape: `spec.cover`

- **Decision**:

  ```json
  "spec": {
    "cover": {
      "script": "scripts/accept-covered.sh",
      "at": ["agent", "git"],
      "timeout_s": 30
    }
  }
  ```

  `script` (required): a project-relative path, no `..` segment, not
  absolute. `at` (required): non-empty, unique, only `agent` and `git`;
  `ci` is refused naming Principle III, as `skip_at` is (feature 006).
  `timeout_s`: integer 1 to 300, default 30.

- **Rationale**: a file can be protected (R4); a free-form command string
  cannot. `at` is required rather than defaulted so the declaration names
  every boundary where proof is skipped (Principle III: skips only where the
  policy declares them). It is the same list shape and value set as
  `skip_at`, so one helper evaluates both (R3).
- **Alternatives**: `spec.covered_command` (the downstream proposal): not
  protectable, and its boundary rule lived in the hook. Rejected.

## R2. The question and the answer

- **Decision**: for each accept block, at a boundary in `at`, the spec gate
  runs `<script> <feature> <task-id> <block-file>` from the project root
  through `gates_run_watched` (`lib/watch.sh`, feature 006) with
  `timeout_s`, stdout captured to its own file and stderr discarded.
  `<task-id>` is the `T###` that opens the task line, or `-`. `<block-file>`
  is the block's command file the runner already writes. Covered means
  exit status 0 and exactly one non-empty line on stdout. Anything else
  (non-zero, empty, several lines, timeout, the file not executable) runs
  the block.
- **Rationale**: FR-002, FR-003, FR-007. The watchdog stops the script's
  process group on timeout; reusing it keeps one implementation. Stderr is
  discarded so the reason is only what the script deliberately answers.
- **Reason hygiene** (FR-008): the line is cut to 200 characters and every
  control character is removed before it is shown or recorded.

## R3. One skip mechanism (reusing feature 006)

- **Decision**: whether a block may be covered at this boundary is
  `gates_declared_skip "$GATES_BOUNDARY" "<at-json>"` (lib/policy.sh, feature
  006), unchanged. A covered block is reported with result `covered`, the
  script's line as reason, and `declared_skip: "<boundary>"`, the same field
  name and value set as a skipped gate. The text report shows
  `spec: <feature>: "<label>" -- covered: <reason>`, and the spec gate's
  summary counts covered blocks apart from passed ones.
- **Rationale**: FR-004 and the 006 design (FR-009 there): one decision
  function and one attestation field for "not run by declaration at
  boundary X", whatever the item.

## R4. Protecting the script everywhere

- **Decision**: `gates_protected_list` (lib/policy.sh) adds the
  `spec.cover.script` path of every policy it reads (the worktree policy and
  the policies at the revisions it is given), next to the runtime's
  built-in entries. That list feeds commit-msg, pr-check's per-commit
  protected check (base, commit and parent policies) and the agent hooks
  (protect-files, validate-bash), so FR-006 holds at every boundary without
  a second list. The path's protection does not depend on
  `protected_files.extra`.
- **Rationale**: a pull request that both adds a covering script and
  declares it is judged by the union of the base and head policies, so the
  script added in the same change is protected in that change too.
- **Alternatives**: requiring projects to list the script under
  `protected_files.extra`: forgettable; Principle I (fail closed) prefers
  the runtime doing it.

## R5. A declared script that is missing

- **Decision**: the validator checks the path's shape only (R1). `verify.sh`
  refuses the run (exit 1, no gate runs) when `spec.cover` is declared and
  the script is not a regular file inside the project, naming the path;
  doctor reports `[fail]`. A script that exists but is not executable is not
  a refusal: every block then runs (FR-003), and doctor warns.
- **Rationale**: a declared but missing script is a broken configuration,
  refused like an invalid policy; refusing at validation would also refuse
  pr-check runs that read a base policy whose script was since moved.

## R6. Parity: nothing covered at CI

- **Decision**: the parity gate fails at `ci` (under `attestation.parity`
  severity) when any block entry has result `covered`, with reason
  `accept blocks covered at ci: <feature> <task-id>, ...`. Covering never
  runs at `ci` by construction (R1, R3), so this only fires if that
  construction breaks.
- **Rationale**: FR-009; Principle III ("parity MUST be verified, not
  asserted").

## R7. Per-block attestation entries

- **Decision**: each feature result in the attestation's `spec.results`
  gains `blocks`: one entry per evaluated block, in order:
  `{task, verifies, result, reason, duration_s}` plus `declared_skip` for a
  covered block. `result` is `pass`, `fail`, `timeout`, `mutation` (the
  read-only check) or `covered`; `reason` is a fixed string for runtime
  outcomes and the script's line for `covered`. Feature-level counters gain
  `blocks_covered`.
- **Rationale**: FR-011. The record stays small: a few fields per block, no
  output (evidence hygiene).

## R8. Timeline

- **Decision**: when `GATES_TIMELINE` names a file, every gate (in
  `run_gate`, plus the spec, contract and parity gates) and every accept
  block appends one line as it ends:
  `<name>\t<boundary>\t<start>\t<end>\t<result>\t<reason>` (epoch seconds;
  tabs and newlines in the reason replaced by spaces). Block names are
  `accept <feature> <task-id>`. The line is written with a single `printf`
  append so a reader never sees half a line.
- **Rationale**: FR-012, the downstream request verbatim. A CI step can turn
  the file into GitLab section markers or GitHub groups; the docs give a
  short example (spec Assumptions).

## R9. Progress, and the pre-commit view

- **Decision**: when `GATES_PROGRESS` names a file, every gate and block
  appends `gates: <HH:MM:SS> start <name>` when it starts and
  `gates: <HH:MM:SS> end <name> <result> <n>s` when it ends. The pre-commit
  hook sets `GATES_PROGRESS=/dev/stderr` for its verify.sh call when its
  stderr is a terminal and the variable is not already set, so the lines
  reach the terminal as they happen; otherwise it sets nothing.
- **Rationale**: FR-013, FR-014, SC-006. Appending to `/dev/stderr` needs no
  extra `tail` process and works on bash 3.2, Linux and macOS. Human-readable
  lines suit a terminal and a CI log equally; the machine-readable record is
  the timeline.

## R10. Unwritable files

- **Decision**: a failed append to the timeline or progress file disables
  that file for the rest of the run and prints one warning
  (`gates: warning: cannot write <file>; no further timeline lines this
run`). No gate outcome changes (FR-016), as with the attestation today.

## R11. Contract classification

- **Decision**: in `gates_contract_deviations`, `spec.cover` present in the
  effective policy and absent from the baseline is ONE weakened deviation
  (`cover script added`), even though additions are otherwise not
  deviations; `spec.cover.at` gaining a boundary is weakened, losing one
  strengthened; `script` and `timeout_s` changes are `changed`; a baseline
  `spec.cover` the effective policy drops is strengthened (not a deviation
  in default mode).
- **Rationale**: FR-018. A covering script skips proof, so adding one is the
  weakening a baseline exists to catch.

## R12. Canary

- **Decision**: one new canary, `covered`: a sandbox with a Complete feature
  whose single accept block fails, and a covering script that always answers
  `covered by canary`, `at: ["agent", "git"]`. Blocked means:
  `verify.sh --boundary ci` exits 2 naming the block, and
  `verify.sh --boundary git` exits 0 reporting the block covered (proving
  the mechanism works where declared). The suite grows from 17 to 18.
- **Rationale**: FR-010, Principle II.

## R13. Backward compatibility

- **Decision**: without `spec.cover`, `GATES_TIMELINE`, `GATES_PROGRESS` and
  a terminal at pre-commit, no code path changes output: the per-block
  attestation entries are additive fields inside the existing `spec`
  object, and the text report gains no lines.
- **Rationale**: FR-017, SC-007.
