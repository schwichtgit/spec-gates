# Tasks: Constitution as Enforceable Contract — Guided Elicitation With Enforcement Wiring

**Input**: Design documents from `/specs/004-constitution-gate/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included — SC-001/SC-002/SC-003 are "proven by a regression
test", and this repo's convention is suite coverage for every behavior.
The deterministic pipeline (fragments/draft/align/check/detect) is what
gets tested; the conversational layer adds only approval prompts on top
of the same calls.

**Organization**: grouped by user story; US1 (guided elicitation) is the
MVP. This file dogfoods 002: accept blocks below are parsed on every run
and enforced once 004's Status flips to `Complete` (last task).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 (elicitation), US2 (alignment), US3 (proof + init)

## Phase 1: Setup

**Purpose**: projection plumbing for the new entry script.

- [ ] T001 Extend projection surfaces for `constitution.sh`: add it to the `cp` line in `.github/workflows/ci.yml`, the file maps in `extension/commands/speckit.gates.init.md` and `extension/commands/speckit.gates.upgrade.md`, and `.gitignore` (`.specify/gates/constitution.sh` is a projected runtime copy); confirm no ignore glob catches the constitution's annotation markers (they live in `.specify/memory/`, untouched by ignores)

---

## Phase 2: Foundational (parsers + corpus)

**Purpose**: the pure parsing core and the starter corpus every story
consumes.

- [ ] T002 Create `extension/runtime/lib/constitution.sh` with the pure core (no side effects): YAML-frontmatter splitter (awk, BSD-safe), `manifest.yml` tier parser, the `gates:enforce` annotation grammar parser (contracts/annotation-format.md — malformed markers reported with line numbers, one-marker-per-principle rule), and placeholder detection (bracket-token signature / byte-equal-to-template / absent)
- [ ] T003 [P] Author the bundled starter corpus at `extension/constitution/` (research R7): `manifest.yml` (mandatory: no-secrets, branch-first class; recommended: most others) plus ~30 fragments harvested from the CPF-8 baseline, Kahi's generalizable set, and this repo's constitution v1.0.0 — every fragment with id/statement/rationale/surface/ref/tags/provenance frontmatter and a constitution-ready body (contracts/annotation-format.md format)

**Checkpoint**: fragments parse, annotations parse, placeholder detection
works — all unit-testable without any command flow.

---

## Phase 3: User Story 1 — A real constitution from a guided session (Priority: P1) 🎯 MVP

**Goal**: interview → filtered candidate menu → selections → deterministic
annotated draft; augment mode preserves hand-written constitutions;
non-interactive runs refuse without answer files.

**Independent Test**: quickstart Scenarios 1–2 — profile-filtered menu,
byte-deterministic draft with a marker per principle, surface-less
selections refused, augment mode preserves every existing line.

### Implementation for User Story 1

- [ ] T004 [US1] Implement `fragments` in `extension/runtime/lib/constitution.sh` + entry script: profile-tag filtering and ranking (project-type/posture tags), mandatory tier first, TSV output per contracts/cli-contracts.md; missing profile = usage error
- [ ] T005 [US1] Implement `draft` in `extension/runtime/lib/constitution.sh`: assemble accepted/custom selections into the core template's section shape with one `gates:enforce` marker per principle; byte-deterministic for identical inputs; refuse (exit 2) any selection without a surface decision (FR-004); `--augment` preserves existing content verbatim, inserts annotations beside existing principles, appends additions in section order (FR-010); writes only to the caller-supplied `--out` path
- [ ] T006 [US1] Create the projected entry script `extension/runtime/constitution.sh`: subcommand dispatcher (`fragments | draft | align | check | detect`), shared flag parsing, exit codes 0/1/2 per contracts/cli-contracts.md; `detect` wired to T002's placeholder detection
- [ ] T007 [P] [US1] Create `tests/test-constitution.sh` (fixture answers/selections files): profile filtering (docs profile sees no infra fragments), mandatory-first ordering, draft determinism (two runs byte-identical), marker-per-principle output, zero bracket placeholders, surface-less selection refused, custom principles carry the same obligation, augment preserves every existing line and annotates in place, detect returns absent/placeholder/filled correctly
- [ ] T008 [US1] Register `test-constitution` in `tests/run.sh`
- [ ] T009 [US1] Create `extension/commands/speckit.gates.constitution.md`: the conversational session per contracts/cli-contracts.md — interview to profile, menu presentation (statement + why + surface, never bare names), per-candidate accept/adapt/decline with surface confirm/override and explicit prose-only choice, full draft diff before writing `.specify/memory/constitution.md`, refusal of non-interactive runs without answers+selections files (FR-006), closing handoff to the core `/speckit-constitution` command (FR-012)
- [ ] T010 [US1] Register the command and hook in `extension/extension.yml`: `speckit.gates.constitution` (8 commands total) and `hooks.before_constitution` with `optional: true` and a prompt naming what it does

**Checkpoint**: US1 fully functional — a fixture project goes from blank
to an annotated, ratifiable constitution with fixture answer files.

---

## Phase 4: User Story 2 — Constitution and enforcement cannot silently disagree (Priority: P2)

**Goal**: `align` computes per-principle surface state and concrete
proposed changes; applying is approval-gated; declining leaves the repo
byte-identical.

**Independent Test**: quickstart Scenario 3 — missing/active/
pending-boundary states computed correctly, overlay-targeted policy
changes, tree hash unchanged on decline.

### Implementation for User Story 2

- [ ] T011 [US2] Implement `align` in `extension/runtime/lib/constitution.sh` + entry script (research R4/R5): per-surface activity evaluation (policy against the enforced policy — 003 effective when live; agent-hook wired+executable; git-hook via the existing doctor logic; ci workflow contains check; accept block parses via spec-gate lib; scanner config mentions rule), `state=active|missing|pending-boundary`, concrete proposed change per missing surface (policy changes target the OVERLAY), TSV output, pure computation — no writes, no network
- [ ] T012 [P] [US2] Add alignment regression cases to `tests/test-constitution.sh`: each surface type active and missing, `expect=` mismatch = missing, pending-boundary for ci-without-CI-boundary, overlay targeting in a 003-contract fixture (proposed change lands in policy.json, effective recomputed by sync), SC-003 decline guarantee (tree hash before == after when nothing is applied)
- [ ] T013 [US2] Extend `extension/commands/speckit.gates.constitution.md` with the alignment flow: run `align`, present the proposal, apply approved changes change-by-change via the existing wiring steps (policy edit + re-sync when contract live, hook wiring from init's steps, `/speckit.gates.ci` pointer, accept-block stub, scanner snippet), emit the sync-impact summary (principle → surface → change)

**Checkpoint**: US1 + US2 — annotated constitutions can be brought to
zero-gap with explicit approvals only.

---

## Phase 5: User Story 3 — Unenforced principles are visible, permanently (Priority: P3)

**Goal**: `check` verdicts + the doctor constitution section (gap = exit 1
naming principle + surface; prose-only listed; unannotated informational)
and the init hookup.

**Independent Test**: quickstart Scenarios 4–6 — all-active passes,
disabling any surface fails naming it, malformed markers fail with line,
no-marker repos get one informational line, init offers the session on
placeholder detection.

### Implementation for User Story 3

- [ ] T014 [US3] Implement `check` in `extension/runtime/lib/constitution.sh` + entry script: one line per principle (`enforced | gap | prose-only`), unannotated count as a single summary line, exit 1 iff any gap or malformed marker (FR-009 fixed severity), reusing T011's surface evaluation
- [ ] T015 [US3] Extend `extension/runtime/doctor.sh` with the constitution section: runs only when a constitution exists and carries at least one marker (otherwise one informational line, FR-013), reports per-principle status, exit 1 on gaps/malformed markers naming principle + surface (+ line), local-only, ≤ 1s

  ```accept
  # verifies: SC-004
  set -eu
  start="$(date +%s)"
  bash .specify/gates/constitution.sh check >/dev/null
  end="$(date +%s)"
  [ $((end - start)) -le 1 ]
  ```

- [ ] T016 [P] [US3] Add check/doctor regression cases: `tests/test-constitution.sh` (all-active exit 0, each surface's gap named, malformed marker fails naming `constitution.md:<line>`, prose-only listed never failing, unannotated informational) and `tests/test-doctor.sh` (section present with markers, informational-only without, gap = doctor exit 1)
- [ ] T017 [US3] Wire init (FR-014): `extension/commands/speckit.gates.init.md` runs `constitution.sh detect` after policy inference, offers the session on `absent|placeholder` (one question, default skip, never forced), includes the constitution state in the final report

**Checkpoint**: all three stories functional — elicit, align, prove.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T018 Dogfood this repository (SC-007): augment-session its constitution — annotate the five principles with their real surfaces (I → fail-closed policy defaults, II → ci `gates` check + canary presence, III → `attestation.parity`, IV → projected runtime files, V → `spec` policy section), apply the alignment, and leave `constitution.sh check` + doctor reporting every principle enforced
- [ ] T019 Finalize this file's accept blocks: SC-001/SC-002/SC-003 via offline mini-fixtures (fixture corpus + selections → draft → tamper a surface → check catches it; decline path tree-hash), keep total enforced execution within the block budget alongside 002/003's blocks

  ```accept
  # verifies: SC-001
  set -eu
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/sel.json" <<'JSON'
  { "project_name": "P", "selections": [
    { "id": "workflow/branch-first", "surface": "git-hook", "ref": "pre-commit" },
    { "id": "security/no-secrets", "surface": "scanner", "ref": "gitleaks:default" },
    { "name": "Custom", "surface": "prose", "body": "b" }
  ] }
  JSON
  bash .specify/gates/constitution.sh draft --corpus extension/constitution --selections "$tmp/sel.json" --out "$tmp/d1.md"
  bash .specify/gates/constitution.sh draft --corpus extension/constitution --selections "$tmp/sel.json" --out "$tmp/d2.md"
  cmp -s "$tmp/d1.md" "$tmp/d2.md"
  [ "$(grep -c '^### ' "$tmp/d1.md")" = "$(grep -c 'gates:enforce' "$tmp/d1.md")" ]
  ! grep -Eq '\[[A-Z_][A-Z_][A-Z_]' "$tmp/d1.md"
  ```

  ```accept
  # verifies: SC-002
  set -eu
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.specify/memory" "$tmp/.specify/gates"
  printf '{ "attestation": { "parity": "off" } }\n' >"$tmp/.specify/gates/policy.json"
  cat >"$tmp/.specify/memory/constitution.md" <<'MD'
  # C

  ## Core Principles

  ### I. Gap
  <!-- gates:enforce surface=policy ref=attestation.parity expect=error -->
  x
  MD
  if CLAUDE_PROJECT_DIR="$tmp" bash .specify/gates/constitution.sh check --constitution "$tmp/.specify/memory/constitution.md" >/dev/null 2>&1; then
    exit 1
  fi
  ```

  ```accept
  # verifies: SC-003
  set -eu
  before="$(git status --porcelain=v1)"
  bash .specify/gates/constitution.sh align >/dev/null 2>&1 || true
  after="$(git status --porcelain=v1)"
  [ "$before" = "$after" ]
  ```

- [ ] T020 [P] Document in `README.md`: the guided constitution section (interview, corpus, annotations, alignment, doctor proof), the new command row (8 commands)
- [ ] T021 [P] Document the flow in `docs/how-it-works.md`: elicit → annotate → align → prove pipeline, the annotation grammar, charter interop, the fixed-severity gap doctrine
- [ ] T022 Run quickstart.md Scenarios 1–8 end-to-end on macOS bash 3.2, record the check budget against SC-004 in the PR description
- [ ] T023 Final check: `bash tests/run.sh` all green and the repo's own gate green (SC-006); flip 004's Status to `Complete` as the last commit once every box above is checked

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 independent (projection lists only)
- **Foundational (Phase 2)**: T002 blocks all subcommands; T003 [P] alongside T002 — together they BLOCK all user stories
- **US1 (Phase 3)**: T004/T005 need T002+T003; T006 needs T004/T005 signatures; T007 in parallel once T004–T006 exist; T008 after T007; T009 after T005/T006; T010 after T009
- **US2 (Phase 4)**: T011 needs T002 (annotations) + the 003 lib (effective policy) + spec-gate lib (accept parsing); T012 after T011; T013 after T011 and T009
- **US3 (Phase 5)**: T014 reuses T011's evaluation; T015 after T014; T016 after T014/T015; T017 needs T006 (`detect`)
- **Polish (Phase 6)**: T018 after US2+US3 (needs align+check); T019 after all US phases; T020/T021 [P] anytime after US3; T022–T023 last

### User Story Dependencies

- **US1 (P1)**: independent — deliverable alone as the MVP
- **US2 (P2)**: consumes US1's annotations
- **US3 (P3)**: reuses US2's surface evaluation; init hookup only needs US1's `detect`

### Parallel Opportunities

- T003 (corpus authoring) alongside T002 (parsers)
- T007 (tests) alongside T009/T010 (command + registration)
- T012 and T013 touch different files after T011
- T016 alongside T017; T020/T021 parallel with each other and T019

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2 (projection + parsers + corpus)
2. Phase 3 (US1): fragments, draft, detect, entry script, command, tests
3. **STOP and VALIDATE**: quickstart Scenarios 1–2 with fixture answer
   files — blank project to annotated draft, augment preserves
4. Ship as the MVP PR if desired (mirrors 001–003's US1-first sequence)

### Incremental Delivery

1. US1 → guided elicitation with annotations (MVP)
2. US2 → alignment (SC-002 provable, SC-003 decline guarantee)
3. US3 → check/doctor/init (the permanent proof + FR-014 onboarding)
4. Polish → dogfood this repo (SC-007), docs, budgets, Status flip

Per the established workflow: recreate the feature branch from `main`
each session, one PR per phase/story preferred, stale squash-merged
remotes are auto-deleted.

---

## Notes

- The accept block under T015 is inert until 004 flips Complete; T019
  finalizes the full set. It runs against THIS repo's constitution, which
  T018 annotates — so the block order (dogfood before Status flip)
  matters and is enforced by the task ordering above.
- The corpus (T003) is content, not plumbing: every fragment must carry
  provenance from the mined CPF-era corpus (Kahi, accelno, this repo's
  constitution) — an unattributed rule doesn't ship.
- `verify.sh` is untouched by this feature; anything that looks like it
  needs a verify change belongs to a future "constitution gate class"
  feature, not this one (plan.md scope note).
