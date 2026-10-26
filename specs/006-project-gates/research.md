# Research: Project Gates per Boundary

Decisions for [plan.md](plan.md), each grounded in the runtime as of
`b639a01` (constitution 1.1.0 on main).

## R1. Policy shape: gates keyed by name, not a list

- **Decision**: `hooks.verify-quality.gates` is an object whose keys are gate
  names and whose values are gate definitions (`command`, `severity`,
  `timeout_s`, `skip_at`). Declared order is the object's key order.
- **Rationale**: the policy contract (feature 003, `lib/contract.sh`
  `gates_contract_deviations`) compares leaves reached through object keys
  and deliberately treats an array as one opaque leaf. With an object, each
  gate's `severity` is ranked by the existing rule (error < warning < info),
  a removed gate is a set of leaves gone, and a baseline's gates merge with
  an overlay's through the existing deep merge (`$base * $ov`), so a project
  can add gates to a baseline without restating them. Names are unique by
  construction (FR-006, half of it). jq keeps insertion order in
  `to_entries`, so order is still declarable.
- **Alternatives**: a list of `{name, ...}` (as the issue sketches): the
  contract would report any edit as one "changed" deviation of the whole
  list, the merge with a baseline would replace the list, and duplicate names
  need their own check. Rejected.

## R2. Where project gates run

- **Decision**: after whatever the orchestrator runs (`none` walk, `task`,
  or `custom`), in declared order, one at a time. Gate names are
  `^[a-z0-9][a-z0-9_-]{0,39}$`; reserved names (built-in gate names, now and
  for the runtime's own report lines): `prettier`, `markdownlint`,
  `shellcheck`, `task-lint`, `task-test`, `custom`, `spec`, `contract`,
  `parity`, `policy`, `lock`, `constitution`.
- **Rationale**: additions, not replacements (spec edge case: custom plus
  project gates both run). Sequential keeps output and timing attributable
  and matches the existing dispatch. Reserving names keeps the summary,
  `--json` and attestation unambiguous.
- **Alternatives**: parallel execution (spec Assumptions: out of scope);
  namespacing (`project:lint`): longer names everywhere for no gain once
  reserved names are refused.

## R3. Time limit

- **Decision**: each project gate runs under `timeout_s` (per gate), else
  `hooks.verify-quality.gate_timeout_s` (policy-wide), else 600 s. On
  timeout the gate fails with reason `timeout after <n>s` (plus the machine
  load, as accept blocks report it since 0.4.2), and its process group is
  stopped (TERM, two-second grace, KILL). The `task` and `custom` steps keep
  running without a limit, as today.
- **Rationale**: there is no gate time limit today (only accept blocks have
  `spec.timeout_s`), so a hung step can hold the Stop hook. Adding a limit to
  the existing `task`/`custom` steps would change existing policies'
  behavior, which FR-015 forbids; a project that wants a limit there moves
  the command into `gates`. 600 s covers a production build on a slow
  runner and still bounds a hang.
- **Mechanism**: a new `lib/watch.sh` with `gates_run_watched <timeout-s>
<outfile> <cmd...>`: start the command as its own job (`set -m` in a
  subshell, as `gates_spec_run_block` does), a timer subshell that marks
  and stops the group, `wait`, and report 0/rc/timeout. It reuses the
  stop logic of `gates_spec_group_stop` by moving that function into
  `lib/watch.sh` (spec-gate.sh sources it). The accept-block runner keeps
  its own lease and snapshot machinery; converging the two runners is
  out of scope.
- **Limit (documented)**: a process that leaves the gate's process group
  (`setsid`, a double fork into a new session) is not stopped. Project gates
  are not read-only by contract, so the accept blocks' lease tracking is
  not applied to them.
- **Alternatives**: `timeout(1)`: absent on stock macOS, the portability
  floor. A per-gate limit only (no policy-wide default): forces repetition.

## R4. Commands that cannot start

- **Decision**: commands run through `sh -c` from the project root, as the
  `custom` command does. Exit status 126 or 127 fails the gate with reason
  `command not found or not executable`; the summary line shows the shell's
  message.
- **Rationale**: Fail Closed. The shell already distinguishes these codes,
  so no pre-parse of the command string is needed.

## R5. The boundary in the environment

- **Decision**: `verify.sh` exports `GATES_BOUNDARY` (`agent`, `git`, `ci`,
  or `none` when `--boundary` is absent) before the first gate, for every
  gate command, the orchestrator steps and the walk.
- **Rationale**: FR-010. One variable, set once, visible to nested runs.
  `none` (verify without `--boundary`, which warns since 0.4.0) applies no
  skip declarations, so it runs every gate: the safe side.

## R6. Declared skips: one mechanism for gates now, accept blocks later

- **Decision**: a gate may carry `skip_at`: a non-empty, duplicate-free list
  of `agent` and/or `git`. `ci` (and any other value) is refused by policy
  validation. One library function decides and describes a skip for any
  item: `gates_declared_skip <boundary> <skip_at-json>` prints
  `skipped by declaration at <boundary>` and returns 0 when the item is
  skipped at that boundary, 1 otherwise. The report shape is shared:
  result `skipped`, reason `skipped by declaration at <boundary>`, and an
  attestation field `declared_skip: "<boundary>"`, which distinguishes it
  from the existing tool-missing `skipped` (`declared_skip` absent).
  Feature 007 calls the same function for covered accept blocks and writes
  the same field into per-block entries.
- **Rationale**: FR-007 to FR-009. Making CI impossible to name keeps
  Principle III true by construction; the parity check (R7) proves it at
  runtime too.
- **Alternatives**: `boundaries: ["git", "ci"]` (an allow list, as the issue
  sketches): a list without `ci` would have to be refused or silently
  amended. A skip list cannot express "not at CI" at all. Rejected.

## R7. Parity: CI runs the full set

- **Decision**: the synthetic `parity` gate gains a second check next to the
  tool-version comparison. From the effective policy it computes the declared
  gate set; from this run's gate entries the set that ran (pass, fail, warn)
  and the set skipped by declaration. At `ci` every declared gate must have
  run; at `agent`/`git` every declared gate either ran or was skipped by a
  declaration naming this boundary. Any other outcome fails parity naming
  the gates, under `attestation.parity` severity (default error), with
  reason `declared gates not run at <boundary>: <names>`.
- **Rationale**: FR-011 and Principle III ("parity MUST be verified, not
  asserted"). Every boundary reads the same committed policy (GATES_POLICY_FILE
  is ignored at git and CI since #196), so "CI's set contains each earlier
  boundary's set" reduces to "CI ran every declared gate", checked on the run
  that matters.
- **Alternatives**: comparing attestations across machines: no shared store;
  the policy is the shared source.

## R8. The documented built-in walk

- **Decision**: `verify.sh --walk [--boundary <b>] [--json]` runs only the
  built-in per-tool walk (prettier, markdownlint, shellcheck, as enabled by
  the policy's include globs), whatever the orchestrator, and prints the
  usual report. It writes no attestation (the calling run records its own
  gate) and skips the spec, contract, parity and project gates. Inside a gate
  run it joins the holder's lock (GATES_LOCK_PID, as nested runs do since
  0.4.2); standalone it takes the lock. Exit codes as verify.sh.
- **Rationale**: FR-013 with no new projected script and no new interface
  beyond one flag; the flag is documented in
  `commands/speckit.gates.verify.md` and README as stable across minor
  releases.
- **Alternatives**: a new `walk.sh`: one more projected file and manifest
  entry for the same behavior. Rejected.

## R9. Doctor

- **Decision**: doctor lists each project gate with its severity, time limit
  and declared skips (`[ok]  gate lint (error, 600s): runs at every boundary`;
  `[ok]  gate build (error, 600s): skipped by declaration at agent`). A
  `custom_command` or gate command that names `formatter-dispatch.sh` gets a
  `[rec]` pointing to `verify.sh --walk`.
- **Rationale**: FR-012; visibility of every skip outside a run.

## R10. Contract classification

- **Decision**: in `gates_contract_deviations`, `skip_at` under a gate
  classifies like `exclude` (gaining entries is weakened, losing them
  strengthened); a gate present in the baseline and absent from the
  effective policy is ONE weakened deviation marked `removed` (as a removed
  hook is); `test_severity` and each gate's `severity` use the severity
  rank; `command`, `timeout_s` and `gate_timeout_s` changes are `changed`.
- **Rationale**: FR-016. A longer time limit is not less enforcement, so it is
  `changed`, not `weakened` (the spec's FR-016 example is corrected to match).

## R11. `task test` severity

- **Decision**: `hooks.verify-quality.test_severity` (`error`, `warning`,
  `info`), default `warning`, used for the `task-test` gate only.
- **Rationale**: FR-014; the existing `severity` key already means the
  `custom` command's severity, so a separate key avoids changing it.

## R12. Canary

- **Decision**: one new canary, `project`: a sandbox policy with a project
  gate `canary-fail` (`command: "exit 1"`, severity error,
  `skip_at: ["agent"]`). Blocked means: `verify.sh --boundary ci` exits 1
  and names the gate, and `--boundary agent --json` reports it `skipped`
  with `declared_skip: "agent"`. The suite grows from 16 to 17 canaries.
- **Rationale**: FR-017 and Principle II: proves the new gate class blocks,
  that a declared skip never reaches CI, and that the skip is reported.

## R13. Schema and validation

- **Decision**: `policy.schema.json` adds the keys under the hook definition
  with an `if/then` that permits `gates`, `gate_timeout_s` and
  `test_severity` only on `verify-quality`; `gates_validate_policy`
  (`lib/policy.sh`, the jq validator the runtime actually runs) enforces the
  same rules: name pattern, reserved names, `command` non-empty, severity
  enum, `timeout_s` and `gate_timeout_s` integers 1 to 86400, `skip_at`
  values. An older runtime refuses the new keys (`additionalProperties:
false`), so a policy written for 0.5.0 never silently loses its gates.
- **Rationale**: Fail Closed; the schema documents, the validator enforces,
  as for every existing key.

## R14. The gate lock's deferral names what it defers

- **Decision**: when an agent-boundary run skips because another run holds
  the lock (0.4.2, #263), its message and `--json` name the gates it would
  have run: `gates: skipped: the gate run of pid N (git) is in progress;
deferred: prettier, markdownlint, lint, spec, parity`, and
  `"deferred": [...]`. The list is computed from the policy (enabled
  built-in walk tools, orchestrator steps, project gates not skipped at
  agent by declaration, `spec`, `contract` when the policy extends a
  baseline, `parity`); a policy that cannot be read at that point gives
  `deferred: all gates (policy not read)`. Gates skipped at agent by
  declaration are named in the same line (`skipped by declaration at agent:
<names>`, `"declared_skip": [...]` under `--json`).
- **Rationale**: constitution 1.1.0, Principle III: "every gate or accept
  block a boundary does not run is reported by name". The 0.4.2 message
  named only the holder. `/speckit-analyze` found the gap (C1).
- **Alternatives**: a constitution PATCH saying a deferred run is reported as
  a whole: weakens the text just ratified. Rejected.
