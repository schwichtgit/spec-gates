# Feature Specification: Constitution as Enforceable Contract — Guided Elicitation With Enforcement Wiring

**Feature Branch**: `004-constitution-gate`

**Created**: 2026-07-11

**Status**: Complete

**Input**: User description: "constitution as enforceable contract: a guided
constitution-elicitation command (wired as a before_constitution hook so it
runs ahead of the core /speckit.constitution flow) replaces the
blank-placeholder experience for new and existing projects. It runs a
structured interview (project type, quality posture, security posture,
workflow discipline) and offers a principle menu drawn from a versioned
baseline of battle-tested rules (fragment registry, interoperable with the
charter extension's format; a bundled starter corpus ships with the
extension). The differentiator: every accepted principle must name its
enforcement surface — a policy.json knob, an agent/git hook, a CI check, an
accept block, or a scanner rule — or be explicitly marked prose-only; the
command then seeds/updates policy.json and the gate wiring to match, so the
constitution, the policy, and the enforcement layer cannot silently
disagree. doctor gains a constitution section reporting principles whose
enforcement surface is missing or inactive (the governance analogue of the
no-op gate check). Output artifacts: a filled constitution with
per-principle enforcement annotations, an aligned policy.json, and a
sync-impact summary. The elicit -> version -> enforce -> prove loop closes:
spec-gates graduates from proving the gates enforce to proving the
governance enforces."

## Clarifications

### Session 2026-07-11

- Q: Does an annotated-but-inactive enforcement surface fail the health
  check or only warn? → A: Fail (exit 1), naming principle and surface. An
  annotation is a claim of enforcement; a false claim is the silent-no-op
  class. Severity is fixed, not a policy knob; prose-only remains the
  honest escape hatch and never fails.
- Q: Integration and existing-constitution handling? → A: Confirmed as
  specified — before_constitution pre-hook handing the core command a
  filled draft (core keeps owning versioning/ratification), and augment
  mode for existing constitutions (preserve + annotate + propose; no
  evidence-derivation — the ecosystem's brownfield extension owns that).
- Q: Does init offer the elicitation? → A: Yes — /speckit.gates.init
  detects a placeholder-only or absent constitution and OFFERS the guided
  session as an optional step (never forced), making the onboarding flow
  end-to-end: policy inference + constitution elicitation + boundary
  wiring.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - A real constitution from a guided session (Priority: P1)

A maintainer starting a project (or adopting governance in an existing one)
runs the elicitation command instead of staring at a bracket-placeholder
template. It interviews them — project type, quality posture, security
posture, workflow discipline — and offers a menu of battle-tested candidate
principles drawn from a versioned corpus, each carrying a plain statement,
the reason it exists (including the failure it historically prevented), and
its proposed enforcement surface. The maintainer accepts, adapts, or
declines each; every accepted principle either names an enforcement surface
or is knowingly marked prose-only. The session produces a filled
constitution with per-principle enforcement annotations, ready for the core
constitution flow to version and ratify.

**Why this priority**: this is the gap itself — nothing in the ecosystem
elicits a constitution for a fresh project, and the upstream template is
empty scaffolding. Without US1 there is nothing to align (US2) or prove
(US3). Independently valuable even without enforcement wiring: a guided
session beats a blank page.

**Independent Test**: in a fixture project with no constitution, run the
elicitation; verify a structured interview happens (not a form dump), the
menu presents principles with statement/why/surface, declined principles
leave no trace, accepted ones land in a filled constitution whose every
principle carries either an enforcement annotation or an explicit
prose-only marker, and the result is valid input to the core constitution
command.

**Acceptance Scenarios**:

1. **Given** a project with a placeholder-only (or absent) constitution,
   **When** the maintainer completes the guided session accepting some
   principles and declining others, **Then** the produced constitution
   contains exactly the accepted principles, each annotated with its
   enforcement surface or an explicit prose-only marker, and no bracket
   placeholders remain.
2. **Given** the principle menu, **When** any candidate is presented,
   **Then** it shows a statement, a why (the failure it prevents), and a
   proposed enforcement surface — never a bare rule name.
3. **Given** a maintainer who wants a principle the corpus lacks, **When**
   they add a custom principle, **Then** the session requires the same
   annotation decision (surface or prose-only) before accepting it.

---

### User Story 2 - The constitution and the enforcement layer cannot silently disagree (Priority: P2)

For every accepted principle with an enforcement surface, the session
derives the concrete enforcement change — a policy setting, a hook to wire,
a CI check, an accept block, a scanner rule — and presents the complete set
as a reviewable alignment proposal (a sync-impact summary naming each
principle and the change that enforces it). Nothing user-owned is modified
without explicit approval; on approval, the enforcement layer matches the
constitution it just ratified.

**Why this priority**: annotation without alignment is documentation —
the accelno corpus showed constitutions overstating their own enforcement
in six of eight repos. Depends on US1's output.

**Independent Test**: complete a session in a fixture repo with an existing
policy; verify the alignment proposal names every surface-annotated
principle with its concrete change, the user-owned policy file is untouched
until approval, approval applies exactly the proposed changes, and decline
leaves everything unmodified with the mismatch stated.

**Acceptance Scenarios**:

1. **Given** accepted principles with enforcement surfaces, **When** the
   session ends, **Then** an alignment proposal lists one concrete
   enforcement change per principle (or states the surface is already
   active), and applying it requires explicit approval.
2. **Given** an existing user-owned policy that already satisfies some
   principles, **When** the proposal is generated, **Then** already-active
   surfaces are reported as such and produce no change.
3. **Given** a maintainer who declines the alignment, **When** the session
   ends, **Then** no enforcement artifact was touched and the summary
   plainly says which principles are annotated but not yet enforced.

---

### User Story 3 - Unenforced principles are visible, permanently (Priority: P3)

The health check gains a constitution section: for every principle with an
enforcement annotation it verifies, from local information, that the named
surface exists and is active (the policy knob is set, the hook is wired and
executable, the CI check is present, the accept block parses, the scanner
rule is configured). A principle whose surface is missing or inactive is
reported as an enforcement gap — the governance analogue of the no-op gate
signature. Prose-only principles are listed as such, so the honest
boundary between enforced and aspirational is always one command away.

**Why this priority**: the proof layer — cheap once US1 defines the
annotation format, and the piece that keeps alignment true over time rather
than only at ratification.

**Independent Test**: in a fixture with an annotated constitution, verify
the health check reports all-active when surfaces are live; disable one
surface (e.g. remove the policy knob) and verify the check fails naming the
principle and the missing surface; verify prose-only principles are listed
without failing.

**Acceptance Scenarios**:

1. **Given** an annotated constitution whose surfaces are all active,
   **When** the health check runs, **Then** the constitution section
   reports every principle enforced and exits clean.
2. **Given** a principle whose named surface has been removed or disabled,
   **When** the health check runs, **Then** it fails naming the principle
   and the inactive surface.
3. **Given** prose-only principles, **When** the health check runs,
   **Then** they are listed as prose-only (visible, never a failure).

---

### Edge Cases

- Project already has a hand-written constitution → the session must not
  clobber it: it operates in augment mode (annotate existing principles,
  propose additions) and every change is shown before writing.
- A principle's proposed surface conflicts with an existing policy value
  the user set deliberately → the alignment proposal shows the conflict
  and the user decides; no silent override of user-owned configuration.
- The corpus/registry source is unreachable → the bundled starter corpus
  is always available offline; remote registries are optional enrichment,
  never a dependency (same offline doctrine as every gate).
- The maintainer declines every candidate principle → valid outcome; the
  session produces a minimal constitution scaffold with zero unfounded
  content rather than inventing principles.
- An annotated surface type is not applicable to the repo (e.g. a CI check
  in a repo with no CI boundary projected) → the annotation is accepted
  but the alignment proposal flags it as pending that boundary, and the
  health check reports it as inactive until the boundary exists.
- Constitution later edited by hand, breaking an annotation → the health
  check (US3) surfaces the resulting gap on its next run; the session can
  be re-run in augment mode to reconcile.
- Non-interactive invocation (CI, scripted) → the elicitation refuses to
  guess: it requires an interactive session or a prepared answers file;
  it never auto-fills constitution values (the corpus rule CPF got right).

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The feature MUST provide a guided elicitation session that
  interviews the maintainer across at least: project type, quality
  posture, security posture, and workflow discipline — and adapts the
  candidate menu to the answers (a docs-only project is not offered
  container-hardening principles).
- **FR-002**: Candidate principles MUST come from a versioned corpus of
  reusable principle fragments; a starter corpus MUST ship bundled and
  work fully offline; additional registries MAY be configured and MUST be
  fetched only during the session (never at gate/verify time).
- **FR-003**: Every candidate MUST be presented with: a plain-language
  statement, a rationale naming the failure it prevents, and a proposed
  enforcement surface. Bare rule names are not presentable candidates.
- **FR-004**: Every accepted principle — from the menu or custom-written —
  MUST carry exactly one of: an enforcement-surface annotation from the
  defined surface set, or an explicit prose-only marker. The session MUST
  NOT accept a principle without this decision.
- **FR-005**: The defined enforcement-surface set for v1 is: policy
  setting, agent-boundary hook, git-boundary hook, CI check, accept
  block, scanner rule, prose-only. The annotation format MUST be readable
  by the health check (FR-009) and MUST survive the core constitution
  command's versioning flow.
- **FR-006**: The session MUST never auto-fill constitution values from
  inference alone: constitution content requires explicit human
  acceptance, per answer or per principle. Non-interactive runs without a
  prepared answers file MUST refuse rather than guess.
- **FR-007**: The session MUST produce an alignment proposal covering
  every surface-annotated principle: the concrete enforcement change (or
  "already active"), presented for explicit approval before anything is
  applied. User-owned files (the policy file above all) MUST NOT be
  modified without that approval; declining leaves the repository
  untouched and the gaps named.
- **FR-008**: On approval, applying the alignment MUST leave the
  enforcement layer consistent with the constitution: each approved
  surface change is applied, and the produced sync-impact summary names
  principle → surface → change for the record.
- **FR-009**: The health check MUST gain a constitution section verifying,
  from local information only, that every annotated surface exists and is
  active; a missing or inactive surface is an enforcement gap that fails
  the check (exit 1) naming the principle and the surface — severity is
  fixed, not policy-configurable (Clarifications). Prose-only principles
  are listed, never failed.
- **FR-010**: With an existing constitution present, the session MUST
  operate in augment mode: existing principles are preserved and offered
  for annotation, additions are proposed alongside, and no existing
  content is removed or rewritten without explicit approval.
- **FR-011**: The fragment format MUST be interoperable with the existing
  ecosystem fragment-composition approach (the charter extension's
  registry layout), so an org can maintain one registry serving both.
- **FR-012**: The elicitation MUST integrate ahead of the core
  constitution flow (its native pre-hook point) so the core command
  receives a filled draft rather than placeholders, and the core
  command's own versioning/sync-impact behavior keeps working unchanged.
- **FR-013**: A repository that never runs the elicitation MUST see zero
  behavior change anywhere (gates, health check, attestations) except
  that the health check MAY note when a constitution contains no
  enforcement annotations at all (a single informational line, never a
  failure).
- **FR-014**: The gates initialization flow MUST detect a placeholder-only
  or absent constitution and OFFER the guided elicitation as an optional
  step (never forced, consistent with init's conversational style), so
  that onboarding covers policy inference, constitution elicitation, and
  boundary wiring in one flow.

### Key Entities

- **Principle fragment**: a reusable candidate principle in the corpus —
  statement, rationale (failure it prevents), proposed surface,
  applicability tags (project type/posture), provenance.
- **Corpus / registry**: a versioned collection of fragments; one bundled
  (offline), others optional remote sources.
- **Interview profile**: the maintainer's answers (project type, postures,
  discipline) that filter and rank candidates.
- **Enforcement annotation**: the per-principle record binding it to one
  surface from the defined set (or prose-only), embedded in the
  constitution in a durable, checkable form.
- **Alignment proposal**: the reviewable set of concrete enforcement
  changes derived from annotations, with already-active surfaces noted.
- **Sync-impact summary**: the applied record — principle → surface →
  change — produced when an alignment is approved.
- **Constitution health report**: the health-check section listing each
  principle as enforced / gap (named surface missing or inactive) /
  prose-only.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: Starting from a placeholder or absent constitution, one
  guided session produces a ratifiable constitution in which 100% of
  principles carry an enforcement annotation or an explicit prose-only
  marker — proven by a regression test on fixture answers.
- **SC-002**: After an approved alignment, zero surface-annotated
  principles lack an active enforcement surface, and the health check
  proves it; deactivating any single surface is reported as a named gap
  by the very next health-check run — proven by a regression test.
- **SC-003**: The session never modifies user-owned configuration without
  explicit approval: declining the alignment proposal leaves every file
  byte-identical — proven by a regression test.
- **SC-004**: The bundled corpus session works with zero network access
  end-to-end; the health-check constitution section adds no more than one
  second to a run.
- **SC-005**: The guided session replaces the blank-template experience:
  a maintainer answering the interview honestly is never shown a bracket
  placeholder and never has to invent structure — the session supplies
  it (structure, ordering, and governance sections come from the corpus
  and the core template's required shape).
- **SC-006**: Repositories that never opt in show zero behavioral change
  (existing suites pass unmodified), and this repository's own gate stays
  green with the feature's machinery active.
- **SC-007**: This repository dogfoods the result: its own constitution
  gains enforcement annotations via the augment-mode session, and its
  health check reports every annotated principle as enforced.

## Assumptions

- The elicitation runs as an agent-session command (like init and the
  other gates commands): the interview is conversational, driven by
  command instructions, with deterministic helpers for parsing, merging,
  annotation, and checking — consistent with how this extension already
  splits command-markdown from runtime scripts.
- Enforcement annotations live inside the constitution document itself in
  a durable machine-readable form that survives hand-edits and the core
  command's rewrites; the exact format is a design decision (plan phase),
  but the requirement that the health check can read it is fixed (FR-005).
- The bundled starter corpus is harvested from the CPF-era projects'
  mined rules (the cross-project baseline and top-10 lists) plus this
  repository's constitution — provenance recorded per fragment.
- A companion org-baseline repository (already envisioned by feature 003
  for policy baselines) is the natural long-term home for a shared
  fragment registry; this feature ships self-sufficient with the bundled
  corpus and treats remote registries as optional sources (FR-002),
  reusing 003's fetch-and-pin doctrine for them.
- Alignment changes to the policy file follow the existing house rule:
  user-owned, proposed as a diff, applied only on explicit approval —
  the same doctrine init uses for policy seeding.
- Surface-activity checks (FR-009) are local-only in v1: policy knob
  present and enabled, hook file present/executable/delegating, CI
  workflow file contains the check, accept block parses, scanner config
  present. Verifying that remote CI actually runs the check is out of
  scope (the parity gate and CI boundary already cover execution).
- Multi-repo fleet reporting (which repos have unenforced principles) is
  out of scope for v1; it composes later from health-check output plus
  the 003 contract machinery.
