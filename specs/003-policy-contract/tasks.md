# Tasks: Policy as Versioned Contract — Baseline Inheritance With Reviewable Drift

**Input**: Design documents from `/specs/003-policy-contract/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included — the spec's success criteria explicitly require them
(SC-001/SC-002/SC-003 "proven by a regression test", SC-002 canary
detection), and this repo's convention is that every behavior lands with
suite coverage. All tests use local fixture baseline repos (plain-path git
remotes in `mktemp -d`) — no network anywhere in the suite.

**Organization**: grouped by user story; US1 (inherit + prove) is the MVP
and independently deliverable. This file dogfoods 002's machinery: accept
blocks below are parsed on every run today and enforced once 003's Status
flips to `Complete` (last commit).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 (inherit + prove), US2 (reviewable updates), US3 (propose + evidence)

## Phase 1: Setup

**Purpose**: projection plumbing — unlike 002, this feature adds a new
projected entry script, so the lists need edits.

- [x] T001 Extend the projection surfaces for `contract.sh`: add it to the `cp` line in `.github/workflows/ci.yml`, to the file map in `extension/commands/speckit.gates.init.md` and `extension/commands/speckit.gates.upgrade.md`, and confirm `.gitignore` ignores `.specify/gates/contract.sh` (projected runtime copy) while NOT matching the three committed contract artifacts (`baseline.json`, `baseline.lock.json`, `policy.effective.json`); adjust `tests/test-ci-parity.sh` expectations if they enumerate projected files

---

## Phase 2: Foundational (schema + policy resolution + contract lib core)

**Purpose**: the optional `extends` section, effective-policy resolution,
and the pure functions every story consumes.

- [x] T002 Add the optional `extends` section (object: `source` string required, `version` string required, `file` string optional default `policy.json`; `additionalProperties: false`) to `extension/runtime/policy.schema.json`, and a commented example to `extension/runtime/policy-template.json` (absent by default — the feature is dormant out of the box)
- [x] T003 Extend `gates_validate_policy` in `extension/runtime/lib/policy.sh` to validate the `extends` section (required fields, types, unknown-field rejection — same pattern as the `spec` section)
- [x] T004 Implement effective-policy resolution in `gates_policy_file` (`extension/runtime/lib/policy.sh`): when `policy.json` declares `extends` and `policy.effective.json` exists, all accessors read the effective file; `GATES_POLICY_FILE` env override keeps absolute precedence; no `extends` → unchanged behavior (FR-001)
- [x] T005 [P] Add `extends` validation and resolution cases to `tests/test-policy.sh`: valid section, absent-section-ok, missing source/version, unknown field, non-object; resolution picks effective when present, `GATES_POLICY_FILE` still wins
- [x] T006 Create `extension/runtime/lib/contract.sh` with the pure core (no network): `jq -S` canonicalization helper, sha256 digest shim (reuse 001's dual-binary pattern), lock read/write, the R4 merge (`baseline * (overlay - extends)` + extends re-attached), the R5 deviation classifier (weakened/changed per defined-order fields), and the R6 invariant checks (artifacts present, snapshot digest = pin, recompute = effective bytes, declaration = pin)

**Checkpoint**: schema validates `extends`; accessors resolve the
effective policy; merge/classify/prove are unit-testable pure functions.

---

## Phase 3: User Story 1 — Inherit a versioned baseline, provably (Priority: P1) 🎯 MVP

**Goal**: `sync` fetches and pins a baseline, materializes the effective
policy, and the new `contract` gate proves integrity offline on every run —
drift fails closed, deviations are visible but never blocking.

**Independent Test**: quickstart Scenarios 1–3 — fixture baseline adopted
with one sync; every hand-tampered artifact blocks the next run naming
itself; a weakened rule prints a classified deviation without changing the
exit code; a repo without `extends` is byte-for-byte unaffected.

### Implementation for User Story 1

- [x] T007 [US1] Implement baseline fetch in `extension/runtime/lib/contract.sh` (research R2): clone into `mktemp -d` (shallow `--branch <version>` first, full clone + checkout fallback for SHAs), local-path sources, branch-name refusal, chained-baseline refusal (snapshot must not contain `extends`), schema validation of the fetched baseline — every failure named, prior artifacts untouched
- [x] T008 [US1] Create the projected entry script `extension/runtime/contract.sh` with the `sync` subcommand (contracts/cli-contracts.md): reads the declaration, fetches the declared version, writes pin + snapshot + effective canonicalized, validates the effective result, prints the deviation inventory, never touches `policy.json`, exit codes 0/1/2 as contracted
- [x] T009 [US1] Wire the synthetic `contract` gate into `extension/runtime/verify.sh` immediately after policy validation and before the tool gates: dormant when no `extends` (no gate entry); otherwise prove the four invariants fail-closed at error severity naming the drifted artifact and the repair command; deviations print informationally and never change the exit code; `--dry-run` lists the gate as `planned`
- [x] T010 [US1] Emit the attestation extension in `extension/runtime/verify.sh`: `contract` GateEntry in `gates[]` (synthetic, tool fields null, reason names the violated invariant) and the top-level `contract` object (source/version/digest/effective_sha256/deviations counts), both absent when dormant (FR-010)
- [x] T011 [P] [US1] Create `tests/test-contract.sh` (project-into-fixture pattern + a `mkbaseline` helper building a tagged fixture baseline repo): sync happy path writes three canonical artifacts (SC-001); the four invariant violations each block naming the artifact (SC-002); deviations classified per data-model table and informational (FR-006); dormant repo byte-identical behavior + no contract attestation (SC-006); sync failures (branch-name version, chained baseline, schema-invalid baseline, unreachable source) leave prior artifacts intact; offline verify after removing the fixture source
- [x] T012 [US1] Register `test-contract` in `tests/run.sh`

**Checkpoint**: US1 fully functional — a fixture org baseline is inherited,
pinned, enforced, and drift-proven at every boundary.

---

## Phase 4: User Story 2 — Adopt baseline updates as reviewable changes (Priority: P2)

**Goal**: `sync --update [version]` moves the pin on a branch with a
classified enforcement delta — never on the current branch, never silently.

**Independent Test**: quickstart Scenario 4 — tag `v1.1.0` in the fixture
baseline; `sync --update` produces the `gates/baseline-v1.1.0` branch with
pin+snapshot+effective in one commit while the current branch still
enforces `v1.0.0`; re-running at the highest tag reports already-up-to-date.

### Implementation for User Story 2

- [x] T013 [US2] Implement version discovery in `extension/runtime/lib/contract.sh` (research R7): `git ls-remote --tags` listing, peeled-ref stripping, `v?[0-9]*` filtering, and the awk numeric-segment comparator (no `sort -V` — BSD floor); `--update` with an explicit version bypasses discovery
- [x] T014 [US2] Implement `sync --update [VERSION]` delivery in `extension/runtime/contract.sh` (research R8): target = explicit version or highest tag; equal to pin → "already up to date" exit 0 touching nothing; otherwise branch `gates/baseline-<version>` from HEAD, one commit updating the three artifacts with old→new version, digests, and the classified enforcement delta in the body; `gh` PR when available + GitHub remote, else branch + instructions; outside a git work tree print the delta only; never commit to the current branch (SC-003)
- [x] T015 [P] [US2] Add update regression cases to `tests/test-contract.sh`: explicit-version update, highest-tag selection across `v1.0.0`/`v1.2.0`/`v1.10.0` (numeric, not lexicographic), already-up-to-date no-op, branch contains all three artifacts in one commit while the work tree still enforces the old pin (SC-003), schema-invalid new baseline refused with prior state intact

**Checkpoint**: US1 and US2 — the contract is versioned and updates only
through reviewable changes.

---

## Phase 5: User Story 3 — Propose upstream + evidence surfaces (Priority: P3)

**Goal**: `propose` closes the loop upstream; the contract gate leaves
attestation evidence, proves itself via a canary, and is doctor-visible.

**Independent Test**: quickstart Scenarios 5–6 — a deviation becomes a
complete upstream change request from one command; `doctor --canary --only
contract` is `blocked` healthy and the suite fails naming the contract gate
when the invariant check is stubbed.

### Implementation for User Story 3

- [x] T016 [US3] Implement the `propose` subcommand in `extension/runtime/contract.sh` + `lib/contract.sh` (research R9): live deviation inventory (empty → "nothing to propose" exit 0); clone the pinned source, apply the deviating paths onto the baseline document, branch `propose/<consumer>-<YYYYMMDD>`, commit body with origin repo, pinned version, per-deviation classification, and the required rationale (`--rationale` flag or interactive prompt); `gh` PR when possible, else patch under `.specify/gates/proposals/` + instructions
- [x] T017 [P] [US3] Add propose regression cases to `tests/test-contract.sh`: deviation applied onto the baseline document with origin/version/classification/rationale present (SC-005), nothing-to-propose exit 0 producing nothing, rationale refusal in non-interactive mode without `--rationale`
- [x] T018 [P] [US3] Add the optional `contract` property to `specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json` (additive; record stays `v: 1` per the forward-compatibility rule)
- [x] T019 [P] [US3] Add attestation-shape cases to `tests/test-attest.sh`: `contract` object fields and deviation counts correct, absent when dormant, GateEntry present with reason on drift
- [x] T020 [US3] Add the `contract` canary to `extension/runtime/canary.sh` (contracts/cli-contracts.md): sandboxed fixture baseline (plain-path remote inside the sandbox), sync, tamper `policy.effective.json`, sandboxed `verify.sh` must exit 2 naming the contract gate or the suite fails; wire into `--only`; ensure `project_sandbox` copies `contract.sh`

  ```accept
  # verifies: SC-002
  bash .specify/gates/doctor.sh --canary --only contract
  ```

- [x] T021 [P] [US3] Add contract-canary cases to `tests/test-canary.sh`: healthy fixture `blocked`; invariant check stubbed to a no-op → suite exit 1 naming the contract gate
- [x] T022 [US3] Extend `extension/runtime/doctor.sh` with the contract section (FR-011): declaration/pin/snapshot-match/effective-match/deviation inventory from local info only, exit 1 on the four gate invariants, `[rec]` nudge when `extends` is declared but never synced
- [x] T023 [P] [US3] Add doctor contract cases to `tests/test-doctor.sh`: healthy report, each invariant violation fails, unsynced nudge
- [x] T024 [US3] Add the two extension commands: `extension/commands/speckit.gates.sync.md`, `extension/commands/speckit.gates.propose.md`, and register both in `extension/extension.yml` (7 commands; FR-013)

**Checkpoint**: all three stories functional and provable.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T025 Finalize this file's accept blocks (dogfood): reconcile with what got implemented and give SC-001–SC-005 each a `# verifies:` reference via offline mini-fixtures (this repo itself stays dormant — no `extends` here), keeping total enforced execution within 002's 30s block budget
- [ ] T026 [P] Document the contract in `README.md`: extends declaration, sync/propose commands, the three committed artifacts, deviation semantics, link `contracts/artifact-layout.md`
- [ ] T027 [P] Document the flow in `docs/how-it-works.md`: declare → sync → materialize → prove pipeline, deviation classification, reviewable updates, propose loop, attestation `contract` object, the new canary
- [ ] T028 Run quickstart.md Scenarios 1–8 end-to-end on macOS bash 3.2, record the contract-gate overhead delta against SC-004 in the PR description
- [ ] T029 Final check: `bash tests/run.sh` all green and the repo's own gate green (SC-006); the Status flip to `Complete` happens as the last commit of `/speckit-implement` once every box above is checked

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 has no dependencies (touches projection lists only)
- **Foundational (Phase 2)**: T002 → T003 → T004; T005 after T004; T006 independent of T002–T005 — BLOCKS all user stories
- **US1 (Phase 3)**: needs T002–T004 (schema + resolution) and T006 (core); T007 → T008 → T009 → T010; T011 in parallel once T007–T009 exist; T012 after T011
- **US2 (Phase 4)**: needs US1's fetch + artifacts; T013 → T014; T015 after T014
- **US3 (Phase 5)**: T016 needs T006's inventory + T007's clone machinery; T020 needs T009 (the gate it probes) and T001 (projection); T017/T018/T019/T021/T023 are parallel test/contract touches after their implementation tasks; T022 needs T006; T024 anytime after T008/T016
- **Polish (Phase 6)**: T025 after all US phases; T026/T027 parallel anytime after US3; T028–T029 last

### User Story Dependencies

- **US1 (P1)**: independent — deliverable alone as the MVP
- **US2 (P2)**: builds on US1's fetch/pin/materialize machinery
- **US3 (P3)**: propose consumes US1's inventory; evidence surfaces attest and probe US1's gate

### Parallel Opportunities

- T005 alongside T006; T001 alongside all of Phase 2
- T011 (tests) alongside T009–T010 (gate wiring)
- After T014: T015, T016, T022 touch different files and can proceed in parallel
- T017/T018/T019/T021/T023 are all [P] test/contract touches on distinct files
- T026/T027 (docs) parallel with each other and with T025

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2 (projection + schema + resolution + contract core)
2. Phase 3 (US1): fetch, sync, gate, attestation, tests
3. **STOP and VALIDATE**: quickstart Scenarios 1–3 against a fixture
   baseline — adopt, tamper, watch it block; deviations visible
4. Ship as the MVP PR if desired (mirrors 001/002's US1-first sequence)

### Incremental Delivery

1. US1 → inheritance with provable pinning (MVP)
2. US2 → reviewable updates (SC-003 provable)
3. US3 → propose + attestation + canary + doctor (SC-005, FR-012 provable)
4. Polish → docs, dogfood closure, budgets (SC-004, SC-006)

Per the established workflow: recreate the feature branch from `main` each
session, delete stale squash-merged remote branches before pushing, prefer
one PR per phase/story for reviewability.

---

## Notes

- The accept block under T020 is this feature's first dogfood criterion —
  parsed (inert) today, enforced when 003 flips to `Complete` (T029).
  T025 finalizes the full set. This repository stays dormant (no `extends`
  in its own policy), so every block verifies via fixtures or the canary,
  never via a live contract here.
- T001 is real work this time (002's equivalent was verification-only):
  `contract.sh` is a new projected top-level script, which the CI
  projection, init/upgrade command maps, and the canary sandbox projector
  all need to learn about.
- The three contract artifacts are committed by design; double-check no
  existing `.gitignore` glob (e.g. `.specify/gates/*.json` — none today)
  accidentally swallows them (T001).
