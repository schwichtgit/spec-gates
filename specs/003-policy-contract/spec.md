# Feature Specification: Policy as Versioned Contract — Baseline Inheritance With Reviewable Drift

**Feature Branch**: `003-policy-contract`

**Created**: 2026-07-08

**Status**: Complete

**Input**: User description: "policy as versioned contract: policy.json gains
an optional extends field referencing a baseline policy at a versioned source
(URL@version or path@version); the baseline is fetched and pinned at sync time
(never at verify time — the runtime stays offline), materialized as a merged
effective policy with the local file as overlay; gates sync updates the pinned
baseline and propagates the change downstream as a reviewable PR; gates
propose packages a local policy deviation as an upstream change request
against the baseline repo; the governance loop that lets an org run one
baseline policy across a fleet of repos with reviewable drift in both
directions"

## Clarifications

### Session 2026-07-08

- Q: May a repository's overlay weaken the baseline (disable a gate the
  baseline enables, lower a severity)? → A: Yes — transparent deviation.
  Overlays may override anything, but every weakening is a named deviation:
  surfaced in gate output, recorded in attestations, and enumerable by
  propose. Drift is permitted, never silent.
- Q: What does "propagate downstream as PRs" cover in v1? → A: Consumer-side
  only. Sync runs inside each consuming repo (manually or on a schedule) and
  produces that repo's own reviewable update. Baseline-side fleet fan-out
  (registry + cross-repo access) is explicitly out of scope for v1.
- Q: What effect does a deviation have on the gate run itself? → A:
  Informational only — a named line in gate output plus the attestation
  record; the exit code never changes because of a deviation. Governance
  reviews drift via attestations and propose, not red builds.
- Q: How precisely is an override classified as a weakening? → A: Only
  fields with a defined order are classified: enabled booleans
  (true → false), severity enums (error → warning → off), and rule-scope
  lists (narrowed include / widened exclude) are "weakened"; every other
  override is a neutral "changed" deviation — still named and attested.
- Q: How are sync and propose exposed? → A: As extension commands joining
  the existing five, with their underlying scripts directly runnable (for
  CI and scheduled runs), consistent with how verify and doctor work.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Inherit a versioned baseline, provably (Priority: P1)

An organization maintains one baseline quality policy. A repo maintainer
declares that their repository extends that baseline at a specific version.
A single sync step fetches the baseline, pins it (version plus content
digest), stores a local snapshot, and materializes the effective policy —
baseline with the repository's own policy applied as an overlay. From then on
every gate run, at every boundary, enforces the effective policy and proves —
without any network access — that it still equals the pinned baseline plus
the overlay. Any tampering with the snapshot, the pin, or the materialized
policy blocks the run naming what drifted.

**Why this priority**: this is the contract itself — inheritance with
provable integrity. Without it there is nothing to update (US2) or push back
on (US3). It is independently valuable: even a never-updated baseline gives an
org one enforced policy across repos instead of N hand-copied ones.

**Independent Test**: point a fixture repository's policy at a fixture
baseline source, run sync, and verify: the effective policy governs gate
results at all three boundaries; editing the materialized policy, the
snapshot, or the pin by hand is blocked by the very next run with the drift
named; a repo without an extends declaration behaves exactly as today.

**Acceptance Scenarios**:

1. **Given** a repo whose policy declares a baseline at version X, **When**
   sync runs, **Then** the baseline is validated, pinned (version + digest),
   snapshotted locally, and the materialized effective policy reflects
   baseline-plus-overlay deterministically.
2. **Given** a synced repo, **When** any boundary's gate runs with no network
   access, **Then** enforcement uses the effective policy and passes only if
   it matches the pin; a hand-edited effective policy fails the run naming
   the drift.
3. **Given** a repo with no extends declaration, **When** the gate runs,
   **Then** behavior is byte-for-byte identical to today (the feature is
   dormant).

---

### User Story 2 - Adopt baseline updates as reviewable changes (Priority: P2)

The org ships a new baseline version. In a consuming repository, sync detects
the newer version, updates the pin and the materialized policy on a branch,
and packages the change as a reviewable pull request — showing exactly which
enforcement rules tightened, loosened, or appeared. Nothing about the repo's
enforcement changes until a human merges that PR.

**Why this priority**: updates are why the contract is _versioned_. Silent
baseline drift would repeat the silent-no-op failure class this project
exists to kill; reviewable updates are the safe default.

**Independent Test**: publish version X+1 of a fixture baseline, run sync in
a consuming fixture, and verify a branch/change-set is produced whose diff
shows the pin and effective-policy changes; verify enforcement still follows
version X until the change is accepted.

**Acceptance Scenarios**:

1. **Given** a repo pinned to baseline X while the source offers X+1,
   **When** sync runs in update mode, **Then** a reviewable change is
   produced updating pin, snapshot, and effective policy — and current
   enforcement stays at X until it is accepted.
2. **Given** an update whose baseline fails schema validation, **When** sync
   runs, **Then** no change is produced and the failure names the source,
   version, and validation error (fail closed).

---

### User Story 3 - Propose a local deviation upstream (Priority: P3)

A repository needs a rule the baseline does not have (or needs one relaxed).
Instead of silently overlaying forever, the maintainer runs propose: the tool
packages the local deviation — what differs from the baseline and why — as a
change request against the baseline source, so the org can adopt it for
everyone or reject it with reasons. The governance loop closes in both
directions.

**Why this priority**: valuable but dependent on US1's contract and rarer
than consuming updates; a fleet can operate with overlays alone.

**Independent Test**: in a synced fixture with a local overlay deviation, run
propose and verify the produced change request contains the deviation as a
baseline edit, the originating repo, and the maintainer's rationale.

**Acceptance Scenarios**:

1. **Given** a synced repo whose overlay deviates from the baseline, **When**
   propose runs, **Then** a change request against the baseline source is
   produced containing the deviation, its origin, and a rationale prompt.
2. **Given** a repo with no deviation from its baseline, **When** propose
   runs, **Then** it reports there is nothing to propose and produces
   nothing.

---

### Edge Cases

- Baseline source unreachable during sync → sync fails with a named cause;
  existing enforcement (last synced state) is unaffected.
- Baseline content at the pinned version changes upstream (tag moved,
  history rewritten) → the digest no longer matches; sync refuses the
  mismatch and names it (a moved tag is indistinguishable from tampering).
- Baseline fails policy schema validation → sync refuses it, fail closed;
  the repo keeps enforcing its last good state.
- Repo declares extends but has never synced → gate runs fail closed naming
  the missing materialization (an unenforced contract must not look green).
- The baseline itself declares extends → out of scope for v1 (single-level
  inheritance); sync refuses a chained baseline naming the limitation.
- Overlay and baseline both configure the same rule → deterministic merge
  semantics decide (see FR-006); the effective policy must be reproducible
  from pin + overlay alone.
- Verify runs on a machine that has never had network access → all
  enforcement and drift-proving works from the committed snapshot, pin, and
  effective policy.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The policy file MAY declare that it extends one baseline policy
  at a versioned source (remote URL or local path, each with an explicit
  version). Absence of the declaration MUST leave all existing behavior
  unchanged.
- **FR-002**: Sync MUST fetch the declared baseline version, validate it
  against the policy schema, and record a pin consisting of the version
  identifier and a content digest of the fetched baseline. Validation or
  fetch failure MUST abort the sync with a named cause and leave prior state
  intact.
- **FR-003**: Sync MUST store a local snapshot of the pinned baseline inside
  the repository, so that every later operation — including drift proving —
  works with zero network access.
- **FR-004**: Sync MUST materialize an effective policy — the baseline with
  the local policy applied as an overlay — via a deterministic, documented
  merge; given the same snapshot and overlay, the result MUST be
  byte-identical. All boundaries MUST enforce from the effective policy.
- **FR-005**: Gate runs MUST NOT perform network access. A repo that declares
  a baseline but lacks a pin, snapshot, or effective policy MUST fail closed
  naming what is missing.
- **FR-006**: The merge MUST resolve overlay-versus-baseline conflicts as
  overlay-wins with transparent deviation: an overlay may override any
  baseline rule, and every override MUST be recorded as a named deviation —
  in gate output, in attestations, and in the enumerable inventory propose
  draws from. Deviations are informational: they MUST NOT change a run's
  exit code. Classification is defined-order only: disabling an enabled
  rule, lowering a severity (error → warning → off), or narrowing a rule's
  scope (narrowed include, widened exclude) is reported as "weakened";
  any other override is reported as "changed". Strengthening and pure
  additions are ordinary overlay behavior, not deviations.
- **FR-007**: Every gate run in an extending repo MUST prove the effective
  policy equals pinned-baseline-plus-overlay (recomputed from the local
  snapshot) and that the snapshot matches the pinned digest; any mismatch
  MUST block the run at error severity, naming the drifted artifact.
- **FR-008**: Sync in update mode MUST detect a newer available baseline
  version and produce a reviewable change (pin + snapshot + effective policy
  updated together, with a human-readable summary of the enforcement delta)
  rather than applying it directly. This is a consumer-side flow: sync runs
  inside the consuming repository (manually or on a schedule) and produces
  that repository's own reviewable update. Baseline-side fleet fan-out is
  out of scope for v1.
- **FR-009**: Propose MUST package the overlay's deviation from the pinned
  baseline as a change request against the baseline source, carrying the
  deviation itself, the originating repository, and a rationale supplied by
  the maintainer. With no deviation, propose MUST report nothing to propose.
- **FR-010**: Attestation records MUST carry the contract evidence: baseline
  source, pinned version, digest, and the effective policy's hash — so any
  run can be audited against the contract after the fact.
- **FR-011**: The environment health check MUST report contract state
  (declared source and version, pin present, snapshot digest match,
  effective policy current) using only local information, and MUST fail on
  the same drift conditions the gate blocks on.
- **FR-012**: The self-test suite MUST gain a probe proving the drift gate
  still blocks: a sandbox with a deliberately mismatched effective policy
  MUST be rejected, and a probe that is accepted MUST fail the suite naming
  the gate.
- **FR-013**: Sync and propose MUST be exposed as extension commands
  alongside the existing command set, and their underlying behavior MUST be
  directly runnable without an agent session (for CI and scheduled use) —
  the same dual surface the existing verify and health-check commands have.

### Key Entities

- **Baseline policy**: the org-owned policy document at a versioned source;
  the contract's upstream side.
- **Overlay**: the repository's own policy file — local additions or
  adjustments applied on top of the baseline.
- **Pin**: the recorded contract terms — baseline source, version
  identifier, content digest — the only thing enforcement trusts.
- **Baseline snapshot**: the in-repo copy of the pinned baseline content that
  makes offline recomputation and drift proving possible.
- **Effective policy**: the materialized merge of snapshot + overlay that
  every boundary actually enforces.
- **Baseline update**: a reviewable change produced by sync when the source
  offers a newer version (new pin + snapshot + effective policy).
- **Change request**: the artifact propose produces against the baseline
  source, carrying a deviation, its origin, and rationale.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A repository adopts an org baseline with one declaration and
  one sync command; from the next gate run, all three boundaries enforce the
  merged policy identically — proven by a regression test.
- **SC-002**: Hand-editing the effective policy, the snapshot, or the pin is
  blocked by the very next gate run at every boundary, naming the drifted
  artifact — proven by a regression test and a canary probe.
- **SC-003**: A baseline version bump reaches a consuming repo only through a
  reviewable change; no sequence of sync operations changes enforcement
  without a human-visible diff being accepted — proven by a regression test.
- **SC-004**: Gate runs in an extending repo complete with zero network
  access, and the contract checks add no more than 1 second to a run.
- **SC-005**: One propose command yields a complete change request (deviation,
  origin, rationale) that the baseline maintainer can review without asking
  the proposer for missing context.
- **SC-006**: A repo without an extends declaration shows zero behavioral or
  performance change (existing suites pass unmodified), and this repository's
  own gate stays green with the contract machinery active.

## Assumptions

- The pin records both a version identifier and a content digest, and the
  digest wins: a version whose content changed upstream is treated as
  tampering, not as an update (same doctrine as the lockfile-pin parity gate
  of feature 001).
- The baseline snapshot is committed to the consuming repository, making the
  repo self-sufficient: clone-and-run works offline, and drift proving needs
  no source access.
- Single-level inheritance in v1: a baseline that itself extends another
  source is refused at sync time. Chains are a possible future extension.
- One baseline per repository (a single extends declaration, not a list).
- Versioned sources are git-reachable (remote URL or local path) with tags or
  commit identifiers as versions; package registries are out of scope.
- Sync and propose produce branches/change requests using the hosting
  platform's tooling when available, and fall back to emitting the change as
  a patch plus instructions when it is not; core behavior is
  platform-agnostic.
- Fleet-wide orchestration (a registry of consuming repos, baseline-side
  fan-out of update PRs, org dashboards) is out of scope for v1; the
  consumer-side loop is designed so fan-out can be layered on later without
  changing the contract artifacts.
- The baseline's example/reference content (an org starter baseline) ships as
  a separate repository when this feature is released; this repository's test
  fixtures stand in for it during development.
