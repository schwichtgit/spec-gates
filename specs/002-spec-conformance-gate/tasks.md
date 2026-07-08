# Tasks: Spec Conformance — Acceptance Criteria as Executable Gates

**Input**: Design documents from `/specs/002-spec-conformance-gate/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included — the spec's success criteria explicitly require them
(SC-001/SC-002 "proven by a regression test", SC-003 canary detection), and
this repo's convention is that every behavior lands with suite coverage.

**Organization**: grouped by user story; US1 (accept blocks run as checks)
is the MVP and independently deliverable. This file also dogfoods the
feature: tasks below carry the project's first real `accept` blocks
(SC-005) — inert until the parser ships, enforced once this feature's
Status is flipped to `Complete`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 (criteria run), US2 (completion enforced), US3 (evidence + self-test)

## Phase 1: Setup

**Purpose**: confirm the projection plumbing needs no changes

- [x] T001 Verify projection coverage for the new lib file: `.gitignore` already ignores `.specify/gates/lib/`, `.github/workflows/ci.yml` projects `extension/runtime/lib/*.sh` by glob, and `extension/commands/speckit.gates.init.md` maps `lib/*.sh` — confirm all three cover `lib/spec-gate.sh` with no edits, and note it in the PR description

---

## Phase 2: Foundational (policy substrate + discovery)

**Purpose**: the optional `spec` policy section and the feature-discovery
core that every story consumes.

- [x] T002 Add `spec` section (enabled boolean, severity enum error|warning, include/exclude string arrays, timeout_s integer ≥ 1; additionalProperties false) to `extension/runtime/policy.schema.json`
- [x] T003 Extend `gates_validate_policy` in `extension/runtime/lib/policy.sh` to validate the `spec` section (types, enums, unknown-field rejection — same pattern as the `attestation` section)
- [x] T004 Seed explicit defaults (`"spec": { "enabled": true, "severity": "error", "include": ["*"], "exclude": [], "timeout_s": 30 }`) into `extension/runtime/policy-template.json` (depends on T002, T003)
- [x] T005 [P] Add `spec`-section validation cases (valid, absent-section-ok, bad severity, bad timeout type, unknown field) to `tests/test-policy.sh`
- [x] T006 Create `extension/runtime/lib/spec-gate.sh` with feature discovery (research R7): direct children of `specs/` containing `spec.md`, lexicographic order, `spec.exclude` glob filtering, zero features on missing `specs/` (FR-011)

**Checkpoint**: policy substrate validated; discovery returns deterministic
feature lists; user stories can start.

---

## Phase 3: User Story 1 — Acceptance criteria run as checks (Priority: P1) 🎯 MVP

**Goal**: fenced `accept` blocks in any feature's `tasks.md` are parsed and
executed per criterion, with fail-closed parse errors and on-demand
execution for features still in progress.

**Independent Test**: quickstart Scenarios 1–2 — normal run reports parsed
criteria informationally; `--accept 002-spec-conformance-gate` executes
this file's blocks and names each result; breaking a fence fails the gate
naming `tasks.md:<line>`.

### Implementation for User Story 1

- [x] T007 [US1] Implement the accept-block parser in `extension/runtime/lib/spec-gate.sh` (research R1): awk fence state machine emitting one JSON object per block (feature, file, line, task, task_checked, verifies, commands); parse errors for unterminated fence, command-less block, and block with no preceding task line, each naming `file:line` (FR-005)
- [x] T008 [US1] Implement the block executor in `extension/runtime/lib/spec-gate.sh`: serial execution from repo root, output captured and shown only on failure, watchdog timeout at `spec.timeout_s` (research R4, exit 143 → `timeout after <N>s`), mutation detection via `git status --porcelain` snapshots (research R5, never auto-revert), and the recursion sentinel (`GATES_SPEC_EXEC=1` exported around block execution)
- [x] T009 [US1] Wire the synthetic `spec` gate into `extension/runtime/verify.sh` after the tool gates and before `parity`: discovery + parse every run, parse errors fail at `spec.severity`, one informational line per incomplete feature (`spec: <feature> — N criteria parsed, not enforced (Status: <value>)`), honored `spec.enabled`, and the gate skipped entirely when `GATES_SPEC_EXEC=1` is set (recursion guard)
- [x] T010 [US1] Add `--accept <feature|all>` to `extension/runtime/verify.sh`: execute the named incomplete feature(s)' blocks with per-criterion informational results, never changing the exit code for incomplete features; unknown feature → exit 1 naming available features
- [x] T011 [P] [US1] Create `tests/test-spec-gate.sh` (project-into-fixture pattern from `tests/test-gate.sh`): parse cases (multi-line block, `# verifies:` extraction, non-accept fences ignored, checkbox inside a fence not counted, unterminated fence, empty block, orphan block), executor cases (pass, exit-code propagation, timeout, mutation named + not reverted), `--accept` behavior, missing-`specs/` trivial pass, recursion guard
- [x] T012 [US1] Register `test-spec-gate` in `tests/run.sh`

**Checkpoint**: US1 fully functional — criteria are executable and visible
on demand, parse errors block, nothing is enforced yet.

---

## Phase 4: User Story 2 — Completion is enforced, not asserted (Priority: P2)

**Goal**: a feature whose `spec.md` Status is `Complete` blocks the run on
any unchecked task or failing accept block, at the policy's severity.

**Independent Test**: quickstart Scenario 3 — a Complete fixture passes,
then blocks (named) on: a failing block, an unchecked task, a mutation, a
timeout, a broken fence.

### Implementation for User Story 2

- [x] T013 [US2] Implement completion detection in `extension/runtime/lib/spec-gate.sh` (research R2): `**Status**:` extraction from `spec.md`, exact `Complete` match, missing field/file → not complete
- [x] T014 [US2] Implement fence-aware task checkbox accounting in `extension/runtime/lib/spec-gate.sh` (research R3): `- [ ]`/`- [x]`/`- [X]` counts from `tasks.md`, code-fence interiors excluded, first unchecked task's text captured for the failure message
- [x] T015 [US2] Implement outcome classification and enforcement (data-model.md outcome rules) in `extension/runtime/lib/spec-gate.sh` + `verify.sh`: complete features execute blocks and fail the `spec` gate at `spec.severity` on `tasks_unchecked > 0` or `blocks_failed > 0` (naming feature + task/criterion + cause), `no-criteria` and incomplete features stay informational, `spec.include` globs bound enforcement
- [x] T016 [P] [US2] Add enforcement regression cases to `tests/test-spec-gate.sh`: Complete fixture + failing block blocks naming the criterion (SC-001), Complete fixture + unchecked task blocks naming the task (SC-002), `severity: warning` reports without blocking, include/exclude filtering, Complete-with-zero-blocks stays informational

  ````accept
  # verifies: SC-001
  set -eu
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  mkdir -p "$d/.specify/gates" "$d/specs/900-sc001"
  cp -R .specify/gates/lib "$d/.specify/gates/lib"
  cp .specify/gates/verify.sh "$d/.specify/gates/"
  printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' >"$d/.specify/gates/policy.json"
  printf '%s\n' '**Status**: Complete' >"$d/specs/900-sc001/spec.md"
  printf '%s\n' '- [x] T1 criterion-under-test' '' '  ```accept' '  exit 9' '  ```' >"$d/specs/900-sc001/tasks.md"
  rc=0
  out="$(CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  printf '%s' "$out" | grep -q '900-sc001'
  printf '%s' "$out" | grep -q 'criterion-under-test'
  printf '%s' "$out" | grep -q 'exit 9'
  ````

**Checkpoint**: US1 and US2 — the spec is now a boundary for any feature
that declares itself done.

---

## Phase 5: User Story 3 — The spec gate leaves evidence and proves itself (Priority: P3)

**Goal**: `spec` gate results land in attestation records, the canary
suite proves the gate still blocks, doctor reports what the gate sees.

**Independent Test**: quickstart Scenarios 4 and 6 — attestation `spec`
object carries counts; `doctor --canary --only spec` is `blocked` healthy
and the suite fails naming the spec gate when the runner is stubbed.

### Implementation for User Story 3

- [x] T017 [US3] Emit the attestation extension in `extension/runtime/verify.sh`: `spec` GateEntry in `gates[]` (candidates = features, checked = blocks executed) and the top-level `spec` object (features/parsed/executed/passed/failed/results[]), absent when `spec.enabled` is false (FR-008)
- [x] T018 [P] [US3] Add the optional `spec` property to `specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json` (additive, record stays `v: 1` per the forward-compatibility rule)
- [x] T019 [P] [US3] Add attestation-shape cases to `tests/test-attest.sh`: `spec` object counts present and correct, absent when policy-disabled, `results[]` outcomes match fixtures
- [x] T020 [US3] Add the `spec` canary to `extension/runtime/canary.sh` (research R8): sandbox feature `900-canary-fixture` with Status `Complete`, one checked task, one `false` accept block; sandboxed `verify.sh` must reject it or the suite fails naming the spec gate; wire into `--only`; unset `GATES_SPEC_EXEC` for the sandboxed run so the canary still probes the spec gate when invoked from inside an accept block (cli-contracts.md sentinel clearing)

  ```accept
  # verifies: SC-003
  bash .specify/gates/doctor.sh --canary --only spec
  ```

- [x] T021 [P] [US3] Add spec-canary cases to `tests/test-canary.sh`: healthy fixture `blocked`; accept-block runner stubbed to a no-op → suite exit 1 naming the spec gate (SC-003)
- [x] T022 [US3] Extend `extension/runtime/doctor.sh`: spec-gate discovery section (features found, blocks parsed, complete count), parse errors fail doctor (exit 1) naming `file:line`, `[rec]` nudge for all-tasks-checked-but-not-Complete features
- [x] T023 [P] [US3] Add doctor cases to `tests/test-doctor.sh`: discovery counts, parse-error failure, completion nudge

**Checkpoint**: all three stories functional and provable.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T024 Finalize this file's accept blocks (SC-005): reconcile the block commands above with what got implemented, add targeted blocks so SC-001–SC-004 each have a `# verifies:` reference, keep total enforced execution ≤ 30s (SC-004 budget) — `bash tests/test-spec-gate.sh` (4m15s wall) far exceeds the block watchdog, so SC-001/SC-002 verify via mini-fixtures instead

  ```accept
  # verifies: SC-002
  set -eu
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  mkdir -p "$d/.specify/gates" "$d/specs/900-sc002"
  cp -R .specify/gates/lib "$d/.specify/gates/lib"
  cp .specify/gates/verify.sh "$d/.specify/gates/"
  printf '%s' '{"hooks":{"verify-quality":{"orchestrator":"none","severity":"error"}}}' >"$d/.specify/gates/policy.json"
  printf '%s\n' '**Status**: Complete' >"$d/specs/900-sc002/spec.md"
  printf '%s\n' '- [x] T1 done-task' '- [ ] T2 forgotten-task' >"$d/specs/900-sc002/tasks.md"
  rc=0
  out="$(CLAUDE_PROJECT_DIR="$d" env -u GATES_SPEC_EXEC bash "$d/.specify/gates/verify.sh" --boundary ci 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  printf '%s' "$out" | grep -q 'unchecked task'
  printf '%s' "$out" | grep -q 'forgotten-task'
  ```

  ```accept
  # verifies: SC-004
  set -eu
  CLAUDE_PROJECT_DIR="$PWD"
  export CLAUDE_PROJECT_DIR
  . .specify/gates/lib/policy.sh
  . .specify/gates/lib/spec-gate.sh
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  start="$(date +%s)"
  for f in $(gates_spec_features "$PWD"); do
    mkdir -p "$tmp/$f"
    gates_spec_parse "specs/$f/tasks.md" "$tmp/$f" >/dev/null
  done
  end="$(date +%s)"
  [ $((end - start)) -le 1 ]
  ```

- [x] T025 [P] Document the spec gate in `README.md`: authoring accept blocks (link `contracts/accept-block.md` grammar), completion marker, policy `spec` section, `--accept` flag
- [x] T026 [P] Document the flow in `docs/how-it-works.md`: discovery → parse → execute → enforce pipeline, recursion guard, attestation `spec` object, the new canary
- [x] T027 Run quickstart.md Scenarios 1–5 and 7 end-to-end on macOS bash 3.2, record the parse-only overhead delta and full-run timing against SC-004 in the PR description
- [x] T028 Final check: `bash tests/run.sh` all green and the repo's own gate green with the `spec` gate active (SC-006); the Status flip to `Complete` (quickstart Scenario 6, SC-005 closure) happens as the last commit of `/speckit-implement` once every box above is checked

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — a verification-only task
- **Foundational (Phase 2)**: T002 → T003 → T004; T005 after T003; T006 independent of policy tasks — BLOCKS all user stories
- **US1 (Phase 3)**: needs T006 (discovery) + T002–T004 (timeout/severity config); T007 → T008 → T009 → T010; T011 in parallel once T007–T008 exist; T012 after T011
- **US2 (Phase 4)**: needs US1's parser/executor/gate wiring; T013/T014 parallel, then T015, then T016
- **US3 (Phase 5)**: T017 needs US2's outcome data; T020 needs US2 enforcement (the canary probes it); T018/T019/T021/T023 parallel to each other after their implementation tasks; T022 needs T007 (parser) + T013 (completion detection)
- **Polish (Phase 6)**: T024 after all US phases; T025/T026 parallel anytime after US3; T027–T028 last

### User Story Dependencies

- **US1 (P1)**: independent — deliverable alone as the MVP
- **US2 (P2)**: builds on US1's parse/execute machinery
- **US3 (P3)**: attests and probes US2's enforcement — lands last

### Parallel Opportunities

- T005 alongside T004; T006 alongside all of T002–T005
- T011 (tests) alongside T009–T010 (gate wiring)
- After T015: T016, T017, T022 touch different files and can proceed in parallel
- T018/T019/T021/T023 are all [P] test/contract touches on distinct files
- T025/T026 (docs) parallel with each other and with T024

---

## Parallel Example: User Story 3

```bash
# After T017 and T020 land, these four run concurrently (distinct files):
Task: "Add spec property to specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json"
Task: "Add attestation-shape cases to tests/test-attest.sh"
Task: "Add spec-canary cases to tests/test-canary.sh"
Task: "Add doctor cases to tests/test-doctor.sh"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2 (setup + policy substrate + discovery)
2. Phase 3 (US1): parser, executor, gate wiring, `--accept`
3. **STOP and VALIDATE**: quickstart Scenarios 1–2 against this very file's
   accept blocks — criteria visible and executable, nothing enforced
4. Ship as the MVP PR if desired (mirrors 001's US1-first PR sequence)

### Incremental Delivery

1. US1 → on-demand executable criteria (MVP)
2. US2 → enforcement for Complete features (SC-001, SC-002 provable)
3. US3 → attestation + canary + doctor (SC-003 provable)
4. Polish → docs, dogfood closure, budgets (SC-004–SC-006)

Per 001's workflow lessons: recreate the feature branch from `main` each
session, delete the stale squash-merged remote branch before pushing, and
prefer one PR per phase/story for reviewability.

---

## Notes

- The two `accept` blocks above are the first real ones in this repository
  (SC-005). They associate with T016 and T020 by adjacency and are inert
  until T007's parser exists; T024 finalizes the set before the Status
  flip.
- Recursion guard (T008/T009) is a design addition surfaced during task
  generation: an accept block that invokes `verify.sh` would otherwise
  re-enter the spec gate; the sentinel makes the inner run skip the `spec`
  gate class. Reflected in `contracts/accept-block.md` and
  `contracts/cli-contracts.md`.
- `.gitignore`, CI projection, and the init command all cover
  `lib/spec-gate.sh` via existing `lib/` globs (T001 confirms — no edits
  expected).
