# Tasks: Provable Enforcement — Gate Run Attestations and Canary Self-Tests

**Input**: Design documents from `/specs/001-provable-enforcement-gate/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included — the spec's success criteria explicitly require them
(SC-001 "proven by a regression test", SC-004 "verified by a loop test"),
and this repo's convention is that every behavior lands with suite coverage.

**Organization**: grouped by user story; US1 (canaries) is the MVP and is
independently deliverable — it does not depend on Phase 2 (noted below).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1 (canaries), US2 (attestations), US3 (parity)

## Phase 1: Setup

**Purpose**: repository plumbing shared by all stories

- [x] T001 Add projected-artifact ignore entries (`.specify/gates/attestations.jsonl`, `.specify/gates/canary.sh`, `.specify/gates/lib/attest.sh` is covered by the existing `lib/` rule) to `.gitignore`

---

## Phase 2: Foundational (policy substrate)

**Purpose**: the optional `attestation` policy section — config consumed by
US2 (enabled, max_records) and US3 (parity severity).

**Note**: US1 does NOT depend on this phase (canaries read no attestation
config in v1); it is ordered first only because it is small and unblocks
two stories.

- [x] T002 Add `attestation` section (enabled boolean, max_records integer ≥ 1, parity enum error|warning|off; additionalProperties false) to `extension/runtime/policy.schema.json`
- [x] T003 Extend `gates_validate_policy` in `extension/runtime/lib/policy.sh` to validate the `attestation` section (types, enums, unknown-field rejection — same pattern as the `git` section)
- [x] T004 Seed explicit defaults (`"attestation": { "enabled": true, "max_records": 200, "parity": "error" }`) into `extension/runtime/policy-template.json` (depends on T002, T003)
- [x] T005 [P] Add `attestation`-section validation cases (valid, absent-section-ok, bad types, bad enum, unknown field) to `tests/test-policy.sh`

**Checkpoint**: policy substrate validated; user stories can start (US1
could even have started already).

---

## Phase 3: User Story 1 — The gate proves it still blocks (Priority: P1) 🎯 MVP

**Goal**: a sandboxed canary suite that fails loudly, naming the gate, when
any gate or hook stops blocking known violations.

**Independent Test**: quickstart Scenarios 1–2 — healthy checkout → suite
exits 0, all five canaries `blocked`, `git status` untouched; stub
`formatter-dispatch.sh` to a no-op → suite exits 1 naming the format gate;
restore → 0 again.

### Implementation for User Story 1

- [x] T006 [US1] Create `extension/runtime/canary.sh`: sandbox lifecycle (mktemp -d, trap cleanup on all exits, exit 2 on setup failure per contract), CLI parsing (`--json`, `--only <ids>`), result collection and summary (status blocked/accepted/skipped per canary, exit 0/1)
- [x] T007 [US1] Implement gate canaries `format` and `shell` in `extension/runtime/canary.sh`: project runtime into sandbox (copy verify.sh + lib/, minimal policy, symlink host `node_modules` when present — pattern from `tests/test-gate.sh`), plant a prettier-dirty file / an SC2086-class script, require `verify.sh` exit 2 with the gate failing
- [x] T008 [US1] Implement hook canaries `bash` and `protect` in `extension/runtime/canary.sh`: pipe crafted tool-call JSON (`rm -rf /`; `.env` edit) to `validate-bash.sh` / `protect-files.sh` from the projected hooks, require exit 2
- [x] T009 [US1] Implement `secret` canary in `extension/runtime/canary.sh`: sandbox `git init` fixture with the pre-commit hook installed, stage an AWS-key-shaped string, require the commit to be blocked
- [x] T010 [P] [US1] Add `--canary` delegation (exec canary.sh, propagate exit and output) to `extension/runtime/doctor.sh` (parallel with T007–T009 once T006 exists)
- [x] T011 [US1] Wire projection + CI: project `canary.sh` and add a named canary step in `.github/workflows/ci.yml`; add the same step to `extension/ci/github/gates.yml`
- [x] T012 [P] [US1] Add the canary step equivalents to `extension/ci/gitlab/gates.gitlab-ci.yml` and `extension/ci/jenkins/Jenkinsfile.gates`
- [x] T013 [US1] Create `tests/test-canary.sh` (healthy suite → 0 with all blocked; broken dispatch stub → 1 naming format gate, restore → 0 [SC-001]; sandbox isolation: no file created/modified outside sandbox [FR-006]; `--only` subset; skipped semantics for absent non-enabled tools) and add it to `tests/run.sh`

**Checkpoint**: MVP — quickstart Scenarios 1–2 pass; enforcement is
demonstrably alive even with zero attestation code written.

---

## Phase 4: User Story 2 — Every gate run leaves evidence (Priority: P2)

**Goal**: every `verify.sh` run appends a schema-conformant attestation
record to a capped JSONL log and embeds it in `--json`; doctor fails on the
no-op signature.

**Independent Test**: quickstart Scenarios 3–4 — run the gate, validate the
record fields against `contracts/attestation-record.schema.json`; two
identical runs differ only in ts/duration; cap loop never exceeds
max_records; forged no-op record makes doctor exit 1 naming the gate.

### Implementation for User Story 2

- [x] T014 [US2] Create `extension/runtime/lib/attest.sh`: `gates_sha256` (sha256sum→shasum chain, fail loudly — R3), `gates_tool_version` (package.json read for node tools, version-command parse for PATH tools, per-run cache — R1), `gates_pin_version` (package-lock v2+ `.packages` lookup, null when absent — R2), `gates_attest_append` (single-line jq -c append; cap via tail + atomic mv when exceeded — R4)
- [x] T015 [P] [US2] Surface per-tool `candidates` and `checked` counts from check-mode in `extension/runtime/lib/formatter-dispatch.sh` (machine-readable line on a dedicated fd or stderr marker consumed by verify.sh; counts already computed by `_gates_collect_files`)
- [x] T016 [US2] Extend `extension/runtime/verify.sh`: capture per-gate start/end seconds and results into GateEntry fields, assemble the AttestationRecord (v, ts, boundary, policy_sha256, runtime_version from `.runtime-version` when present, exit, gates[]), honor `attestation.enabled`/`max_records`, append via attest.sh, embed as top-level `"attestation"` in `--json`; a log-write failure is a stderr warning that never changes the gate outcome (depends on T014, T015)
- [x] T017 [US2] Add the no-op heuristic to `extension/runtime/doctor.sh`: read the latest record from `.specify/gates/attestations.jsonl` when present; any entry with result=pass, candidates>0, checked=0 → FAIL (exit 1) naming the gate (FR-004)
- [x] T018 [US2] Create `tests/test-attest.sh` (record present in log + `--json` after any run; required fields match `specs/001-provable-enforcement-gate/contracts/attestation-record.schema.json` shape via jq assertions; two identical runs identical modulo ts/duration; cap loop max_records+10 → wc -l ≤ cap [SC-004]; missing tool → skipped never pass; forged no-op record → doctor exits 1 naming gate; `attestation.enabled=false` → no log write, no attestation key) and add it to `tests/run.sh`

**Checkpoint**: quickstart Scenarios 3–4 pass; US1 still green (canaries
unaffected by records).

---

## Phase 5: User Story 3 — Parity is verified, not assumed (Priority: P3)

**Goal**: a synthetic `parity` gate inside `verify.sh` fails (or warns) any
boundary whose resolved tool versions drift from the lockfile pins.

**Independent Test**: quickstart Scenario 5 — stub a drifted tool version
(or a scratch lockfile pin): gate exits 2 with
`parity -- <tool>: resolved X, pinned Y (run npm ci)`; severity `warning`
→ exit 0 with warning; `off` → no parity entry; unpinned tool exempt.

### Implementation for User Story 3

- [ ] T019 [US3] Add pin-comparison helper to `extension/runtime/lib/attest.sh`: given the assembled gate entries, produce the mismatch list (entries with pinned non-null and version ≠ pinned)
- [ ] T020 [US3] Add the synthetic `parity` gate to `extension/runtime/verify.sh`: evaluated after tool gates from already-detected versions (R7), severity from `attestation.parity` (default error; warning reports without failing; off omits the entry), reason format `<tool>: resolved <version>, pinned <pinned> (run npm ci)`; entry included in report, `--json`, and the attestation record (depends on T019)
- [ ] T021 [US3] Add parity cases to `tests/test-attest.sh`: versions match pins → parity pass; stubbed drift → exit 2 naming tool + both versions [SC-002]; severity warning → exit 0 + warn entry; off → no entry; tool with pinned=null exempt

**Checkpoint**: all three stories independently green; drift on any
boundary blocks by default.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T022 [P] Document attestations, canaries, and parity in `README.md` (three-boundary section + design rules) and `docs/how-it-works.md` (evidence/canary model, pins-based parity rationale)
- [ ] T023 [P] Reconcile `specs/001-provable-enforcement-gate/contracts/cli-contracts.md` against the implemented surfaces; correct the contract or the code where they drifted (contract is the arbiter)
- [ ] T024 Execute all six quickstart scenarios end-to-end on macOS (bash 3.2) including measured SC-003 (attestation overhead ≤ 1s) and SC-005 (canaries ≤ 30s); note results in the PR description
- [ ] T025 Full self-dogfood green with everything enabled: `bash tests/run.sh` (7 suites), repo self-gate with parity on, `bash .specify/gates/canary.sh`, CI green on the PR (SC-006)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: none.
- **Phase 2 (Foundational)**: after Phase 1. Blocks US2 and US3 only —
  **US1 may start immediately after Phase 1** (documented exception; the
  canary suite reads no attestation config in v1).
- **Phase 3 (US1)**: after Phase 1. Independent of everything else.
- **Phase 4 (US2)**: after Phase 2. Independent of US1.
- **Phase 5 (US3)**: after Phase 4 (T019/T020 consume the version/pin
  fields and record assembly built in T014/T016).
- **Phase 6 (Polish)**: after all desired stories.

### Within-story ordering

- US1: T006 → (T007 → T008 → T009 same-file sequence; T010 [P]; T012 [P])
  → T011 → T013
- US2: T014, T015 [P] → T016 → T017 → T018
- US3: T019 → T020 → T021

### Parallel opportunities

- T005 alongside T004 review; T010/T012 alongside T007–T009; T014 ∥ T015;
  T022 ∥ T023.
- Team split: after Phase 2, one person on US1 (fully independent) while
  another builds US2 → US3.

## Parallel Example: User Story 2 kickoff

```text
Task: "Create extension/runtime/lib/attest.sh (hash, versions, pins, append+cap)"   # T014
Task: "Surface candidates/checked counts in extension/runtime/lib/formatter-dispatch.sh"  # T015
```

## Implementation Strategy

**MVP first (US1 only)**: T001 → T006–T013 → validate quickstart
Scenarios 1–2 → PR-able increment: "the gate demonstrably blocks, and CI
proves it every run" stands alone.

**Incremental delivery**: each story ends at a checkpoint mapped to
quickstart scenarios; stop-and-ship is possible after any checkpoint. US3
is the only story with a hard dependency on another (US2's machinery), by
design (spec: "It depends on Story 2's attestation fields").

## Notes

- Every new script is bash 3.2 + jq only (FR-010); shellcheck-clean is
  enforced by the repo's own gate at commit time.
- Commit after each task or logical group; the commit-msg gate enforces
  conventional format.
- The canary suite is itself the regression guard for this feature's
  machinery — T013's broken-dispatch case re-creates the historical no-op
  bug on purpose.
