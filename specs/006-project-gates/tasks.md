# Tasks: Project Gates per Boundary

**Input**: Design documents from `/specs/006-project-gates/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md),
[research.md](research.md), [data-model.md](data-model.md),
[contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: required. Constitution Principle II: every new gate class ships
with attestation output, a canary and test coverage, and every new test is
mutation-checked against `main` (break the code, see the test fail,
restore). Each story ends with fenced `accept` blocks the spec gate runs
once this feature is Complete.

**Organization**: tasks are grouped by user story; each story is one PR.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an
  unfinished task)
- **[Story]**: the user story (US1 to US4)
- Paths are repository-relative; the runtime is `extension/runtime/`

---

## Phase 1: Setup

**Purpose**: a fixture for the accept blocks and suites.

- [x] T001 Add `fx_gates_project <policy-json>` to `tests/lib/fixture.sh`: build on `fx_project`, copy `extension/runtime/*.sh`, `policy.schema.json`, `shellcheck.sha256`, `lib/*.sh` and `lib/known-releases.sha256` into `<dir>/.specify/gates/` (as CI's projection step does), write `<policy-json>` to `<dir>/.specify/gates/policy.json`, commit nothing, print the directory; document it in the file's header comment

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: the watchdog, the policy keys and the boundary variable every
story uses.

- [x] T002 Create `extension/runtime/lib/watch.sh` (bash 3.2): move `gates_spec_group_stop` from `lib/spec-gate.sh` into it as `gates_group_stop` (TERM, two-second grace, KILL), keep `gates_spec_group_stop` in `lib/spec-gate.sh` as a one-line wrapper so existing callers and tests are unchanged, and add `gates_run_watched <timeout-s> <outfile> <cmd...>` per research R3: run the command in its own job (`set -m` in a subshell) with stdin `/dev/null` and stdout and stderr to `<outfile>`, a timer subshell that writes a marker and calls `gates_group_stop`, `wait`; return the command's status, or 124 on timeout with `GATES_WATCH_DETAIL="timeout after <n>s"` plus the machine load from `gates_spec_load_avg` (as in `timeout after 2s at load 3.10`) when readable
- [x] T003 Source `lib/watch.sh` from `extension/runtime/lib/spec-gate.sh` and `extension/runtime/verify.sh`; confirm `tests/test-spec-gate.sh` still passes unchanged, and run `tests/test-manifest.sh` and `tests/test-project.sh` so the new projected file classifies as new on upgrade with no other change
- [x] T004 [P] Extend `extension/runtime/policy.schema.json` per contracts/policy-gates.md: under the hook definition add `gates` (object; property names `^[a-z0-9][a-z0-9_-]{0,39}$`; each value an object with required `command` (string, minLength 1), optional `severity` (enum `error`, `warning`, `info`), `timeout_s` (integer, minimum 1, maximum 86400), `skip_at` (array, minItems 1, uniqueItems, items enum `agent`, `git`), `additionalProperties: false`), `gate_timeout_s` (integer, minimum 1, maximum 86400, default 600) and `test_severity` (enum `error`, `warning`, `info`, default `warning`); an `if/then` that allows the three keys only when the hook is `verify-quality`; descriptions that say CI cannot be skipped (constitution Principle III)
- [x] T005 Extend `gates_validate_policy` in `extension/runtime/lib/policy.sh` with the same rules (the jq validator is what the runtime enforces): name pattern; reserved names `prettier`, `markdownlint`, `shellcheck`, `task-lint`, `task-test`, `custom`, `spec`, `contract`, `parity`, `policy`, `lock`, `constitution`; `command` present and non-empty; unknown gate keys; severity enum; `timeout_s`/`gate_timeout_s` integers 1 to 86400; `skip_at` non-empty, unique, only `agent`/`git`, with `ci` refused as "CI runs the full policy (constitution, Principle III)"; the three keys refused under any hook other than `verify-quality`; each refusal names the key path; the run is refused with exit 1 before any gate runs, like every invalid policy (#124)
- [x] T006 Add accessors to `extension/runtime/lib/policy.sh`: `gates_project_gate_names` (names in key order, one per line), `gates_project_gate_get <name> <field>`, `gates_project_gate_skip_at <name>` (compact JSON array or empty), and `gates_declared_skip <boundary> <skip_at-json>` per research R6 (prints `skipped by declaration at <boundary>` and returns 0 when `<boundary>` is in the list and is `agent` or `git`; returns 1 for `ci`, `none` and any other boundary); header comments say feature 007 reuses `gates_declared_skip`
- [x] T007 In `extension/runtime/verify.sh`, export `GATES_BOUNDARY` (`agent`, `git`, `ci`, or `none` when `--boundary` is absent) after argument parsing and before the first gate (research R5)
- [x] T008 [P] Tests in `tests/test-policy.sh`: every validation rule of T005 accepts the valid form and refuses the invalid one (verify.sh exit 1, no gate run) naming the key (one case per rule, including `skip_at: ["ci"]` naming Principle III and `gates` under `hooks.prettier`); a policy without the new keys validates as before
- [x] T009 [P] Tests in `tests/test-spec-gate.sh` and a new block in `tests/test-gate.sh`: `gates_run_watched` returns the command's status, returns 124 with `timeout after 2s` for `sleep 30` under a 2 s limit within 6 s, leaves no process of the stopped group running, and writes the command's output to the file; mutation-check (timer disabled, group stop disabled)

**Checkpoint**: keys validate, the watchdog works, every gate command sees
`GATES_BOUNDARY`; no behavior change for existing policies.

---

## Phase 3: User Story 1 - Declare project gates next to the built-in checks (Priority: P1) #243 A

**Goal**: project gates run after the orchestrator's gates, each reported as
its own gate in the text report, `--json` and the attestation
(contracts/verify-report.md).

**Independent Test**: quickstart sections 1 to 3.

- [x] T010 [US1] In `extension/runtime/verify.sh`, after the orchestrator `case`, run each project gate in key order: `run_gate <name> <severity> ...` through `gates_run_watched <timeout> <outfile> sh -c "<command>"` from the project root, with `<timeout>` = the gate's `timeout_s`, else `gate_timeout_s`, else 600; extend `run_gate` with an optional watched mode (or a `run_project_gate` wrapper) so output capture, the `##gates-fail##` summary rules, severity mapping, `FAILED`/`WARNINGS` and `att_gate` stay the single implementation
- [x] T011 [US1] Map the failure causes in `extension/runtime/verify.sh` per research R3 and R4: status 124 from the watchdog fails with reason and summary `timeout after <n>s [at load <x>]`; status 126 or 127 fails with reason `command not found or not executable` and the shell's message as summary; any other non-zero status maps by severity (`error` fails, `warning`/`info` warn); attestation reasons stay fixed strings (evidence hygiene); project gates attest `bin`, `version`, `pinned`, `candidates`, `checked` as null
- [x] T012 [US1] `--dry-run` in `extension/runtime/verify.sh` records each project gate as `planned` with its command and time limit in the detail
- [x] T013 [US1] Tests in `tests/test-gate.sh`: two project gates next to an enabled built-in walk appear after it in key order, each with its own result in text and `--json`; error severity fails the run, warning warns; `##gates-fail##` sets the summary; a 2 s limit on `sleep 30` fails within 6 s with `timeout after 2s`; a missing command fails with `command not found or not executable`; `GATES_BOUNDARY` is visible to the command at each boundary and `none` without `--boundary`; the `custom` orchestrator plus project gates runs both; a policy without `gates` produces the same report as before; mutation-check each
- [x] T014 [P] [US1] Tests in `tests/test-attest.sh`: the attestation line has one entry per project gate with `result`, `reason`, `duration_s` and null tool fields; a timed-out gate's reason is `timeout after <n>s` with no command output

  ```accept
  # verifies: FR-001, FR-002, FR-003, FR-004, FR-005
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error","gates":{"ok":{"command":"true"},"bad":{"command":"echo \"##gates-fail## bad gate failed\"; exit 1"},"soft":{"command":"exit 1","severity":"warning"},"slow":{"command":"sleep 30","timeout_s":2},"gone":{"command":"no-such-command-xyz"}}}}}')"
  trap 'fx_cleanup "$d"' EXIT
  rc=0; out="$(CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git 2>&1)" || rc=$?
  test "$rc" -eq 2
  grep -q '^  \[pass\] ok$' <<<"$out"
  grep -q '^  \[fail\] bad -- bad gate failed$' <<<"$out"
  grep -q '^  \[warn\] soft' <<<"$out"
  grep -q '^  \[fail\] slow -- timeout after 2s' <<<"$out"
  grep -q '^  \[fail\] gone' <<<"$out"
  tail -n 1 "$d/.specify/gates/attestations.jsonl" | jq -e '[.gates[].name] | index("ok") and index("bad") and index("soft") and index("slow") and index("gone")' >/dev/null
  ```

  ```accept
  # verifies: FR-006, FR-015
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error","gates":{"spec":{"command":"true"}}}}}')"
  trap 'fx_cleanup "$d"' EXIT
  rc=0; CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1 || rc=$?
  test "$rc" -eq 1
  printf '%s\n' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' >"$d/.specify/gates/policy.json"
  CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1
  ```

**Checkpoint**: Story 1 is useful on its own (PR 1 of 006).

---

## Phase 4: User Story 2 - Keep slow gates out of the agent boundary, never out of CI (Priority: P1) #243 B

**Goal**: `skip_at` skips a gate at the agent or git boundary, reported by
name everywhere; CI can never be skipped and the parity gate proves CI ran
every declared gate (constitution 1.1.0, Principle III).

**Independent Test**: quickstart sections 4 and 5.

- [x] T015 [US2] In `extension/runtime/verify.sh`, before running a project gate, call `gates_declared_skip "$BOUNDARY" "$(gates_project_gate_skip_at <name>)"`; when it skips, record the gate as `skipped` with detail `skipped by declaration at <boundary>`, start no process, do not count it as failed, warned or passed, and pass the boundary to `att_gate` as `declared_skip`
- [x] T016 [US2] Extend `att_gate` (in `extension/runtime/verify.sh`, and `extension/runtime/lib/attest.sh` if the entry shape lives there) with an optional `declared_skip` argument written as `"declared_skip": "<boundary>"` only when set; add the optional `declared_skip` property (`enum: ["agent", "git"]`) to `specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json`
- [x] T017 [US2] Extend the synthetic parity gate in `extension/runtime/verify.sh` per research R7: from the effective policy's gate names and this run's gate entries, fail parity (under `attestation.parity` severity) with `declared gates not run at <boundary>: <names>` when a declared gate neither ran (pass, fail, warn) nor was skipped by a declaration naming this boundary; at `ci` this means every declared gate ran; keep the tool-version check unchanged and report both problems when both occur
- [x] T018 [US2] In `extension/runtime/doctor.sh`, list each project gate: `[ok]  gate <name> (<severity>, <n>s): runs at every boundary` or `... : skipped by declaration at <b>[, <b>]` (research R9)
- [x] T019 [US2] In `gates_contract_deviations` (`extension/runtime/lib/contract.sh`), classify per research R10 and the table in contracts/policy-gates.md: `skip_at` under `hooks.verify-quality.gates.<name>` like `exclude` (gaining entries weakened, losing strengthened); a gate in the baseline and absent from the effective policy is one weakened deviation marked `removed` (as a removed hook); `test_severity` uses the severity rank; `command`, `timeout_s`, `gate_timeout_s` are `changed`; a gate the baseline lacks is not a deviation (delta mode: one strengthened line marked `added`)
- [x] T020 [US2] Add canary `project` to `extension/runtime/canary.sh` (research R12): a sandbox policy with gate `canary-fail` (`command: "exit 1"`, severity error, `skip_at: ["agent"]`); blocked when `verify.sh --boundary ci` exits 2 naming `canary-fail` and `verify.sh --boundary agent --json` reports it `skipped` with detail `skipped by declaration at agent`; add it to `CANARY_SET`, the header comment and the count (16 to 17); update `tests/test-canary.sh` counts and add a case where the canary is accepted, by appending a stub `gates_run_watched() { return 0; }` to the fixture's projected `lib/watch.sh` (as the contract canary test stubs `gates_contract_check`), and reported as an enforcement gap
- [x] T021 [US2] Tests in `tests/test-gate.sh`: `skip_at: ["agent"]` skips at agent (text, `--json`, attestation `declared_skip`, no process started: the command touches a file that must not exist) and runs at git and ci; `skip_at: ["git"]` runs at agent; `--boundary` absent runs every gate; a skipped gate never counts as passed; mutation-check
- [x] T022 [P] [US2] Tests in `tests/test-parity.sh`: the set check fails with `declared gates not run at ci: <name>` when a declared gate is missing from the CI run's entries (fed through the parity function or a test seam), passes when all ran, and at agent passes when the missing gate is skipped by a declaration naming agent but fails when the declaration names only git; `verify.sh` still yields identical results at every boundary for a policy without `skip_at`; mutation-check
- [x] T023 [P] [US2] Tests in `tests/test-contract.sh`: one case per row of the contracts/policy-gates.md deviation table, including a baseline gate removed by the overlay (weakened, removed) and an overlay-only gate (no deviation); mutation-check
- [x] T024 [P] [US2] Tests in `tests/test-doctor.sh`: the gate listing for a gate with and without `skip_at`
- [x] T025 [US2] Name what the gate lock's agent-boundary skip defers (FR-019, constitution Principle III): in `gates_lock_acquire` in `extension/runtime/verify.sh`, when the agent-boundary run skips because another run holds the lock, compute the gates this run would have run from the policy (the enabled built-in walk tools, the orchestrator steps, the project gates not skipped at agent by declaration, and `spec`, `contract` when the policy extends a baseline, `parity`) and append `; deferred: <names>` to the message; under `--json` add `"deferred": [<names>]`; when the policy cannot be read at that point, say `deferred: all gates (policy not read)`; tests in `tests/test-gate.sh` (hold the lock with a fake holder as the existing lock tests do): the message and `--json` list a project gate, a gate with `skip_at: ["agent"]` is not in `deferred` but is named in the same line as `skipped by declaration at agent: <names>` and under `--json` as `"declared_skip": [...]`; mutation-check

  ```accept
  # verifies: FR-007, FR-008, FR-010
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","gates":{"build":{"command":"echo boundary=$GATES_BOUNDARY; exit 1","skip_at":["agent"]}}}}}')"
  trap 'fx_cleanup "$d"' EXIT
  v="$d/.specify/gates/verify.sh"
  out="$(CLAUDE_PROJECT_DIR="$d" bash "$v" --boundary agent 2>&1)"
  grep -q '^  \[skipped\] build -- skipped by declaration at agent$' <<<"$out"
  tail -n 1 "$d/.specify/gates/attestations.jsonl" | jq -e '.gates[] | select(.name == "build") | .declared_skip == "agent" and .result == "skipped"' >/dev/null
  rc=0; out="$(CLAUDE_PROJECT_DIR="$d" bash "$v" --boundary ci 2>&1)" || rc=$?
  test "$rc" -eq 2
  grep -q 'boundary=ci' <<<"$out"
  ```

  ```accept
  # verifies: FR-007, SC-003
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","gates":{"build":{"command":"true","skip_at":["ci"]}}}}}')"
  trap 'fx_cleanup "$d"' EXIT
  rc=0; out="$(CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
  test "$rc" -eq 1
  grep -q 'Principle III' <<<"$out"
  ```

  ```accept
  # verifies: FR-017, SC-006
  set -eu
  bash extension/runtime/canary.sh --only project
  ```

**Checkpoint**: slow gates leave the Stop hook; CI provably runs them (PR 2
of 006).

---

## Phase 5: User Story 3 - Run the built-in walk from a custom command (Priority: P2) #243 C

**Goal**: `verify.sh --walk` is the documented, stable way to run the
built-in walk; doctor points custom commands at it.

**Independent Test**: quickstart section 6.

- [ ] T026 [US3] Add `--walk` to `extension/runtime/verify.sh` (research R8): run only the built-in per-tool walk (prettier, markdownlint, shellcheck when the policy enables each), whatever the orchestrator; skip the spec, contract, parity and project gates; write no attestation; take the gate lock unless nested (`GATES_LOCK_PID` set by the holder); honor `--boundary` and `--json`; exit codes as verify.sh; update the usage text
- [ ] T027 [US3] In `extension/runtime/doctor.sh`, a `[rec]` when `custom_command` or any project gate command contains `formatter-dispatch.sh`: `use \`bash .specify/gates/verify.sh --walk\` (stable)`
- [ ] T028 [US3] Tests in `tests/test-gate.sh`: `--walk` fails naming a badly formatted file and passes once fixed; it prints only built-in gates; it appends no attestation line; a custom orchestrator calling `verify.sh --walk` inside a gate run neither deadlocks nor writes a second attestation; mutation-check; and in `tests/test-doctor.sh` the `[rec]`

  ```accept
  # verifies: FR-013
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"prettier":{"include":["**/*.md"],"severity":"error"},"verify-quality":{"orchestrator":"custom","custom_command":"bash .specify/gates/verify.sh --walk","severity":"error"}}}')"
  trap 'fx_cleanup "$d"' EXIT
  printf '#  Bad   md\n\n\n- x\n' >"$d/bad.md"
  before="$(wc -l <"$d/.specify/gates/attestations.jsonl" 2>/dev/null || echo 0)"
  # The fixture has no node_modules: prettier comes from the repository's.
  rc=0; out="$(PATH="$PWD/node_modules/.bin:$PATH" CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git 2>&1)" || rc=$?
  test "$rc" -eq 2
  grep -q '^  \[fail\] custom' <<<"$out"
  after="$(wc -l <"$d/.specify/gates/attestations.jsonl")"
  test "$after" -eq "$((before + 1))"
  ```

**Checkpoint**: no project needs `lib/formatter-dispatch.sh` (PR 3 of 006).

---

## Phase 6: User Story 4 - Let a failing `task test` block (Priority: P3) #243 D

**Goal**: `test_severity` sets the `task-test` gate's severity; default
warning.

**Independent Test**: quickstart section 7.

- [ ] T029 [US4] In `extension/runtime/verify.sh`, read `hooks.verify-quality.test_severity` (default `warning`) for `run_gate "task-test"`; `task-lint` stays error
- [ ] T030 [US4] Tests in `tests/test-gate.sh` with a fake `task` on PATH whose `test` target fails: default warns (exit 0); `test_severity: "error"` fails (exit 2); mutation-check

  ```accept
  # verifies: FR-014
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"task","test_severity":"error"}}}')"
  trap 'fx_cleanup "$d"' EXIT
  mkdir "$d/bin"
  printf '#!/bin/sh\n[ "$1" = test ] && exit 1\nexit 0\n' >"$d/bin/task"
  chmod +x "$d/bin/task"
  rc=0; PATH="$d/bin:$PATH" CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1 || rc=$?
  test "$rc" -eq 2
  ```

**Checkpoint**: PR 4 of 006, or folded into PR 3.

---

## Phase 7: Polish & cross-cutting concerns

- [ ] T031 [P] Document project gates, `skip_at`, `GATES_BOUNDARY`, `gate_timeout_s`, `test_severity` and `--walk` in `docs/how-it-works.md` (policy reference and the boundary section, citing constitution Principle III) and `README.md` (one example policy; the parity paragraph mentions declared skips); say that project gates are not read-only by contract (unlike accept blocks) and that a timeout stops the gate's process group only
- [ ] T032 [P] Update `extension/commands/speckit.gates.verify.md` (report shape with skipped gates, `--walk`, `GATES_BOUNDARY`) and `extension/commands/speckit.gates.init.md` (mention project gates as a follow-up edit; init infers none)
- [ ] T033 [P] `CHANGELOG.md` `[Unreleased]`: `### Added` entries for project gates, `skip_at` and the parity set check, `--walk`, `test_severity` (#243); note the 17th canary and that an older runtime refuses the new keys
- [ ] T034 Run the full suite (`bash tests/run.sh`), `bash .specify/gates/verify.sh --boundary ci` and `bash .specify/gates/canary.sh` (17/17 blocked) on the final branch; run test-gate, test-spec-gate and test-parity under `/bin/bash` 3.2 and in a `node:26-slim` container with `CI=true` (mawk)
- [ ] T035 Walk quickstart.md sections 1 to 8 in a scratch project and record any deviation as a fix or a spec update
- [ ] T036 Set `**Status**: Complete` in `specs/006-project-gates/spec.md` last, so the spec gate enforces the accept blocks above from then on

---

## Dependencies & Execution Order

- **Setup (T001)**: none; needed by every accept block.
- **Foundational (T002 to T009)**: after T001; blocks all stories. T004 and
  T005 can run together (different files); T008 and T009 in parallel after
  them.
- **US1 (T010 to T014)**: after Foundational.
- **US2 (T015 to T025)**: after US1 (it skips the gates US1 runs). T022,
  T023 and T024 in parallel; T025 after T015.
- **US3 (T026 to T028)**: after Foundational; independent of US1 and US2
  apart from shared files (verify.sh, doctor.sh), so it follows US2 to
  avoid conflicts.
- **US4 (T029 to T030)**: after Foundational; small, may land with US3.
- **Polish (T031 to T036)**: after the stories; T036 last.

## Parallel Examples

```text
Foundational: T004 (schema)  ||  T005-T006 (lib/policy.sh)  ||  T002 (lib/watch.sh)
US1:          T013 (test-gate.sh)  ||  T014 (test-attest.sh)   after T010-T012
US2:          T022 (test-parity.sh)  ||  T023 (test-contract.sh)  ||  T024 (test-doctor.sh)
Polish:       T031  ||  T032  ||  T033
```

## Implementation Strategy

- **MVP**: Setup, Foundational and US1: project gates next to the built-in
  walk, with time limits, at every boundary. Ship as PR 1.
- **Increment 2**: US2, the boundary skips with the parity proof and the
  canary; the mechanism 007 reuses.
- **Increment 3**: US3 and US4 together.
- **Release**: 0.5.0 after 007 (#265, #266), or earlier with 006 alone if
  007 slips.
