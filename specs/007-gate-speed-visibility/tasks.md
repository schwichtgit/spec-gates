# Tasks: Gate Speed and Visibility

**Input**: Design documents from `/specs/007-gate-speed-visibility/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md),
[research.md](research.md), [data-model.md](data-model.md),
[contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: required (constitution Principle II); every new test is
mutation-checked against `main`. Each story ends with fenced `accept` blocks
the spec gate runs once this feature is Complete. Blocks that test the spec
gate call a fixture's `verify.sh` with `env -u GATES_SPEC_EXEC` (the
recursion guard accept blocks export), as feature 002's blocks do. Every
policy in a block gives each hook a `severity`. Exit codes: 0 green, 1
invalid policy or internal error, 2 a gate failed.

**Organization**: by user story; US1 to US3 are one PR (covering never ships
without its protection and its CI proof), US4 and US5 a second, polish a
third.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an
  unfinished task)
- **[Story]**: US1 to US5
- Paths are repository-relative; the runtime is `extension/runtime/`

---

## Phase 1: Setup

- [x] T001 Add `fx_spec_feature <dir> <feature> <task-id> <block-cmd> [<task-id> <block-cmd>...]` to `tests/lib/fixture.sh`: write `<dir>/specs/<feature>/spec.md` with `**Status**: Complete` and `tasks.md` with one checked task per pair (`- [x] <task-id> <feature> task`) followed by an accept block holding `<block-cmd>`; document it in the header comment

---

## Phase 2: Foundational

- [x] T002 Extend `extension/runtime/policy.schema.json` per contracts/policy-cover.md: `spec.cover` object with required `script` (string, minLength 1), required `at` (array, minItems 1, uniqueItems, items enum `agent`, `git`), optional `timeout_s` (integer 1 to 300, default 30), `additionalProperties: false`; descriptions say CI is never covered (Principle III) and the script is protected
- [x] T003 Extend `gates_validate_policy` in `extension/runtime/lib/policy.sh` with the same rules: `script` non-empty, not absolute, no `..` segment; `at` non-empty, unique, only `agent`/`git`, `ci` refused as "CI runs the full policy (constitution, Principle III)"; `timeout_s` integer 1 to 300; unknown keys refused; each refusal names `spec.cover.<key>` (exit 1 through verify.sh, as every invalid policy)
- [x] T004 Add accessors to `extension/runtime/lib/policy.sh`: `gates_cover_script` (the path or empty), `gates_cover_at` (compact JSON array or empty), `gates_cover_timeout` (default 30)
- [x] T005 [P] Tests in `tests/test-policy.sh`: each rule of T003 accepts the valid form and refuses the invalid one naming the key, including `at: ["ci"]` naming Principle III; a policy without `spec.cover` validates as before; mutation-check

**Checkpoint**: keys validate; nothing else changes.

---

## Phase 3: User Story 1 - Don't repeat what the run already proved (P1) #265

**Goal**: at a declared boundary the spec gate asks the covering script per
block; a clean one-line answer marks the block covered and it does not run.

**Independent Test**: quickstart sections 1 and 2.

- [x] T006 [US1] In `extension/runtime/verify.sh`, after policy validation: when `spec.cover` is declared and the script is not a regular file inside the project (resolve with `pwd -P`; refuse symlinks that leave the project), refuse the run (exit 1, no gate runs) naming the path (research R5)
- [x] T007 [US1] In the block loop of `gates_spec_run` (`extension/runtime/lib/spec-gate.sh`, the `while [[ $i -lt $nblocks ]]` loop), before `gates_spec_run_block`: when `gates_declared_skip "$GATES_BOUNDARY" "$(gates_cover_at)"` says this boundary is declared, extract the task id (`T[0-9]+` at the start of the task text, else `-`) and the block's ordinal among its task's blocks (from 1; research R14: the block is `<feature> <task-id>#<n>` everywhere it is named) and run `<script> <feature> <task-id> <block-file>` from the project root through `gates_run_watched` (`lib/watch.sh`) with `gates_cover_timeout`, capturing stdout alone (stderr to /dev/null) in a file under the run's temp dir (research R2)
- [x] T008 [US1] Decide covered in `extension/runtime/lib/spec-gate.sh`: exit 0 and exactly one non-empty line → covered; sanitize the line (drop control characters, cut to 200 characters, research R2); anything else (non-zero, 124 timeout, empty, several lines, a non-executable file) → run the block as today; a covered block does not run, does not count as passed or failed, and prints `spec: <feature>: "<label>" -- covered: <reason>` in text mode (`covered (informational): <reason>` for a feature run only through `--accept`, which records nothing as enforced)
- [x] T009 [US1] Tests in `tests/test-spec-gate.sh` (fixtures from T001): covered at git with the reason shown, the block's command not run (it touches a file that must not exist); at ci the script is not called (it touches a file) and the block runs; each "anything else" answer runs the block; a 2 s timeout on `sleep 60` runs the block within 7 s and leaves no `sleep`; no `spec.cover` runs every block; `at: ["git"]` does not cover at agent; `--boundary` absent covers nothing; `--accept` on an incomplete feature shows `covered (informational)`; a missing script refuses the run with exit 1; mutation-check each

  ```accept
  # verifies: FR-002, FR-003, FR-005
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"severity":"error","cover":{"script":"scripts/cover.sh","at":["agent","git"]}}}')"
  trap 'fx_cleanup "$d"' EXIT
  fx_spec_feature "$d" 900-demo T001 'false' T002 'true'
  mkdir -p "$d/scripts"
  printf '#!/bin/sh\n[ "$2" = T001 ] && { echo "proven by the test gate"; exit 0; }\nexit 1\n' >"$d/scripts/cover.sh"
  chmod +x "$d/scripts/cover.sh"
  v="$d/.specify/gates/verify.sh"
  out="$(CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$v" --boundary git 2>&1)"
  grep -q '900-demo: .* -- covered: proven by the test gate' <<<"$out"
  rc=0; CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$v" --boundary ci >/dev/null 2>&1 || rc=$?
  test "$rc" -eq 2
  ```

  ```accept
  # verifies: FR-001
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"severity":"error","cover":{"script":"scripts/cover.sh","at":["ci"]}}}')"
  trap 'fx_cleanup "$d"' EXIT
  rc=0; out="$(CLAUDE_PROJECT_DIR="$d" bash "$d/.specify/gates/verify.sh" --boundary git 2>&1)" || rc=$?
  test "$rc" -eq 1
  grep -q 'Principle III' <<<"$out"
  ```

**Checkpoint**: covering works where declared and nowhere else.

---

## Phase 4: User Story 2 - The covering script cannot be quietly changed (P1) #265

**Goal**: the declared script is protected at every boundary like the
policy file (research R4).

**Independent Test**: quickstart section 4.

- [ ] T010 [US2] In `gates_protected_list` (`extension/runtime/lib/policy.sh`), add the `spec.cover.script` path of the worktree policy and of every policy read at the given revisions, after the built-in entries, so commit-msg, pr-check's per-commit check (base, commit, parent policies) and the agent hooks protect it whatever `protected_files.extra` says; update the comment above `GATES_BUILTIN_PROTECTED`
- [ ] T011 [US2] Check every consumer of the protected list picks the path up without its own change: `extension/runtime/hooks/git/commit-msg`, `extension/runtime/pr-check.sh` (`ALWAYS_PROTECTED` and the per-commit union), `extension/runtime/hooks/claude/protect-files.sh` and `validate-bash.sh` (including their raw no-jq mode, which reads `policy.json` with grep: extend it so a declared cover script is asked about, failing toward ask); fix any that reads the list another way
- [ ] T012 [US2] Tests: `tests/test-hooks.sh` (commit-msg refuses an undeclared change to the script and accepts it with `Protected-Change` and `Approved-By`; protect-files asks on an edit to it, also in raw mode), `tests/test-pr-check.sh` (an undeclared change in the range is refused; a PR that adds `spec.cover` and the script together is judged with the script protected); mutation-check

  ```accept
  # verifies: FR-006
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"severity":"error","cover":{"script":"scripts/cover.sh","at":["git"]}}}')"
  trap 'fx_cleanup "$d"' EXIT
  ( cd "$d" && grep -qx 'scripts/cover.sh' <<<"$(export CLAUDE_PROJECT_DIR="$d"; source .specify/gates/lib/policy.sh && gates_protected_list)" )
  ```

---

## Phase 5: User Story 3 - See every covered block, and prove CI never covers (P1) #265

**Goal**: covered blocks named in every report and counted apart; parity
fails at CI if anything was covered; canary `covered`.

**Independent Test**: quickstart section 5.

- [x] T013 [US3] In `extension/runtime/lib/spec-gate.sh`, count covered blocks per feature (`blocks_covered`) and overall (`SPEC_COVERED`); an enforced feature with every block passed or covered is `enforced-pass`; the spec gate's summary detail on a pass with covered blocks reads `<n> features, <m> blocks: <p> passed, <c> covered at <boundary>: <feature> <task-id>#<n>, ...`, naming every covered block, so the `--json` detail names them too (constitution, Principle III; contracts/report-timeline.md)
- [x] T014 [US3] Record covered blocks with feature 006's field: per-block entries in the spec results carry `result: "covered"`, the sanitized reason and `declared_skip: "<boundary>"` (the block entries themselves are T020; for this story add at least the covered entries, so T020 extends rather than replaces them)
- [ ] T015 [US3] Extend the synthetic parity gate in `extension/runtime/verify.sh`: at `ci`, any block with result `covered` fails parity (under `attestation.parity` severity) with `accept blocks covered at ci: <feature> <task-id>#<n>, ...` (research R6); add a test seam the parity tests can feed
- [ ] T016 [US3] In `gates_contract_deviations` (`extension/runtime/lib/contract.sh`): `spec.cover` added in the effective policy is ONE weakened deviation (`cover script added`) although additions are otherwise not deviations; `spec.cover.at` gaining a boundary is weakened, losing one strengthened; `script` and `timeout_s` are changed; a removed `spec.cover` is strengthened (contracts/policy-cover.md table)
- [ ] T017 [US3] In `extension/runtime/doctor.sh`: show the declaration (`[ok]  cover script scripts/cover.sh at agent, git (30s), protected`), `[fail]` when the script is missing, `[warn]` when it is not executable (every block will run)
- [ ] T018 [US3] Add canary `covered` to `extension/runtime/canary.sh` (research R12): a sandbox Complete feature whose single block fails and a script that always answers `covered by canary`, `at: ["agent", "git"]`; blocked when `verify.sh --boundary ci` exits 2 naming the block and `--boundary git` exits 0 reporting it covered; add it to `CANARY_SET`, the header comment and the counts (17 to 18) in README.md and docs/how-it-works.md; a test in `tests/test-canary.sh` where the canary is accepted (stub the spec gate's covered decision to cover at ci by appending a function override to the fixture's projected `lib/spec-gate.sh`, as the contract canary test stubs `gates_contract_check`)
- [ ] T019 [P] [US3] Tests: `tests/test-spec-gate.sh` (counts and text detail), `tests/test-parity.sh` (covered at ci fails parity; covered at git passes), `tests/test-contract.sh` (one case per row of the policy-cover.md table), `tests/test-doctor.sh` (the three doctor lines); mutation-check

  ```accept
  # verifies: FR-004, FR-009
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"severity":"error","cover":{"script":"scripts/cover.sh","at":["git"]}}}')"
  trap 'fx_cleanup "$d"' EXIT
  fx_spec_feature "$d" 900-demo T001 'true'
  mkdir -p "$d/scripts"
  printf '#!/bin/sh\necho "proven"\n' >"$d/scripts/cover.sh"
  chmod +x "$d/scripts/cover.sh"
  CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1
  tail -n 1 "$d/.specify/gates/attestations.jsonl" | jq -e '.spec.results[] | select(.feature == "900-demo") | .blocks_covered == 1 and (.blocks[0].result == "covered") and (.blocks[0].declared_skip == "git")' >/dev/null
  ```

  ```accept
  # verifies: FR-010, SC-002
  set -eu
  bash extension/runtime/canary.sh --only covered
  ```

**Checkpoint**: PR 1 of 007 (US1 to US3).

---

## Phase 6: User Story 4 - Per-block timings in the record (P2) #266

**Goal**: every evaluated block has an attestation entry with its result and
duration (research R7).

**Independent Test**: quickstart section 6, attestation part.

- [ ] T020 [US4] In `extension/runtime/lib/spec-gate.sh`, time each block (start and end with `date +%s`, a negative difference recorded as 0) and add one entry per evaluated block to the feature result's `blocks`: `{task, ordinal, verifies, result, reason, duration_s}` with `result` from the runner's return (0 pass, 1 fail, 2 timeout, 3 mutation) and fixed reasons (`check failed`, `timeout after <n>s`, `read-only check failed`), extending the covered entries of T014
- [ ] T021 [US4] Add `blocks_covered` and `blocks[]` (items: `task`, `ordinal` integer ≥ 1, `verifies` string or null, `result` enum, `reason`, `declared_skip` enum `agent`/`git`, `duration_s` integer ≥ 0) as optional properties to `specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json`
- [ ] T022 [US4] Tests in `tests/test-attest.sh` and `tests/test-spec-gate.sh`: two blocks of about 0 and 2 seconds give entries in order with durations 0 to 1 and 2 to 3; a failing, a timed-out and a mutating block get their results and fixed reasons with no block output; the attestation line validates against the extended schema; mutation-check

  ```accept
  # verifies: FR-011
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}},"spec":{"severity":"error"}}')"
  trap 'fx_cleanup "$d"' EXIT
  fx_spec_feature "$d" 900-demo T001 'true' T002 'sleep 2'
  CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1
  tail -n 1 "$d/.specify/gates/attestations.jsonl" | jq -e '.spec.results[] | select(.feature == "900-demo") | (.blocks | length) == 2 and .blocks[1].task == "T002" and .blocks[1].result == "pass" and .blocks[1].duration_s >= 2' >/dev/null
  ```

---

## Phase 7: User Story 5 - Watch a long run as it happens (P2) #266

**Goal**: timeline and progress files written as gates and blocks start and
end; pre-commit shows progress on a terminal (research R8 to R10).

**Independent Test**: quickstart section 6, timeline and progress parts.

- [ ] T023 [US5] Create `extension/runtime/lib/timeline.sh` (bash 3.2): `gates_timeline_line <name> <start> <end> <result> <reason>` appends `<name>\t<boundary>\t<start>\t<end>\t<result>\t<reason>` to `$GATES_TIMELINE` with one `printf` (tabs and newlines in fields replaced by spaces); `gates_progress_start <name>` and `gates_progress_end <name> <result> <seconds>` append `gates: <HH:MM:SS> start <name>` and `gates: <HH:MM:SS> end <name> <result> <n>s` to `$GATES_PROGRESS`; a failed append disables that file for the rest of the run and warns once (research R10); both are no-ops when the variable is unset; `verify.sh` reads `GATES_TIMELINE` and `GATES_PROGRESS` once at startup into internal variables and unsets both for every command it starts (gate commands, accept blocks, the covering script), so nested runs never write to the parent's files (research R15)
- [ ] T024 [US5] Call them from `run_gate` in `extension/runtime/verify.sh` (every tool, task, custom and project gate; a declared skip writes an end line with result `skipped`), from the spec, contract and parity gates, and from the block loop in `extension/runtime/lib/spec-gate.sh` (block name `accept <feature> <task-id>#<n>`; a covered block writes an end line with result `covered`); source `lib/timeline.sh` from verify.sh and spec-gate.sh
- [ ] T025 [US5] In `extension/runtime/hooks/git/pre-commit`, when stderr is a terminal (`[ -t 2 ]`) and `GATES_PROGRESS` is unset, run the quality gate with `GATES_PROGRESS=/dev/stderr`; otherwise change nothing
- [ ] T026 [US5] Tests: `tests/test-gate.sh` (timeline has one line per gate in order with fields as in contracts/report-timeline.md; progress has a start and an end per gate; an unwritable path warns once and changes no exit code; no variable set changes no output; the start line of a gate precedes its own output; a project gate and an accept block that run a nested `verify.sh` on another directory add no lines to the parent's files); `tests/test-spec-gate.sh` (block lines, covered blocks); `tests/test-hooks.sh` (pre-commit sets the variable only on a terminal: use `script(1)` where available, else a seam; skip with a reason where neither exists); mutation-check

  ```accept
  # verifies: FR-012, FR-013, FR-016
  set -eu
  . tests/lib/fixture.sh
  d="$(fx_gates_project '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error","gates":{"lint":{"command":"true"}}}},"spec":{"severity":"error"}}')"
  trap 'fx_cleanup "$d"' EXIT
  fx_spec_feature "$d" 900-demo T001 'true'
  GATES_TIMELINE="$d/t.tsv" GATES_PROGRESS="$d/p.txt" CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1
  t="$(printf '\t')"
  grep -q "^lint${t}git${t}[0-9]*${t}[0-9]*${t}pass" "$d/t.tsv"
  grep -q "^accept 900-demo T001#1${t}git${t}" "$d/t.tsv"
  grep -q '^gates: [0-9:]* start lint$' "$d/p.txt"
  grep -q '^gates: [0-9:]* end lint pass [0-9]*s$' "$d/p.txt"
  rc=0; GATES_TIMELINE=/nonexistent/dir/t.tsv CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary git >/dev/null 2>&1 || rc=$?
  test "$rc" -eq 0
  ```

**Checkpoint**: PR 2 of 007 (US4, US5).

---

## Phase 8: Polish & cross-cutting concerns

- [ ] T027 [P] Document `spec.cover` (the script interface, never at CI, protection, reporting), per-block attestation entries, `GATES_TIMELINE` (with a GitLab section-marker example from contracts/report-timeline.md) and `GATES_PROGRESS` in `docs/how-it-works.md` (spec conformance and evidence sections) and `README.md`
- [ ] T028 [P] Update `extension/commands/speckit.gates.verify.md` (covered blocks in the report; the two variables) and `extension/commands/speckit.gates.doctor.md` (the cover lines) where they describe output
- [ ] T029 [P] `CHANGELOG.md` `[Unreleased]` `### Added`: covered accept blocks (#265, with the four guards), per-block timings, timeline and progress, the pre-commit terminal view (#266); note the 18th canary and that adding `spec.cover` is a weakening contract deviation
- [ ] T030 Run the full suite (`bash tests/run.sh`), `bash .specify/gates/verify.sh --boundary ci` and `bash .specify/gates/canary.sh` (18/18 blocked); run test-spec-gate, test-gate, test-parity and test-hooks under `/bin/bash` 3.2 and in a `node:26-slim` container with `CI=true` (mawk)
- [ ] T031 Walk quickstart.md sections 1 to 7 in fixtures (write `.specify/gates/.runtime-version` so doctor sees a projected runtime) and record any deviation as a fix or a spec update
- [ ] T032 Set `**Status**: Complete` in `specs/007-gate-speed-visibility/spec.md` last

---

## Dependencies & Execution Order

- **Setup (T001)**: needed by the accept blocks and the spec-gate tests.
- **Foundational (T002 to T005)**: after T001; blocks every story. T002 and
  T003 together; T005 after them.
- **US1 (T006 to T009)**: after Foundational.
- **US2 (T010 to T012)**: after Foundational; independent of US1's code
  but ships with it.
- **US3 (T013 to T019)**: after US1 (it reports what US1 decides). T019 in
  parallel with T017 and T018.
- **US4 (T020 to T022)**: after US3 (T020 extends T014's entries).
- **US5 (T023 to T026)**: after US4 for the block lines; T023 alone can
  start after Foundational.
- **Polish (T027 to T032)**: after the stories; T032 last.

## Parallel Examples

```text
Foundational: T002 (schema)  ||  T003-T004 (lib/policy.sh)
US3:          T017 (doctor)  ||  T018 (canary)  ||  T019 (tests)
US5:          T023 (lib/timeline.sh) can start early
Polish:       T027  ||  T028  ||  T029
```

## Implementation Strategy

- **PR 1**: Setup, Foundational, US1, US2, US3. Covering ships only with
  its protection, its reporting and its CI proof.
- **PR 2**: US4 and US5.
- **PR 3**: Polish; Status Complete last.
- **0.5.0**: after 007 and the open bug fixes (#274, #279, #281).
