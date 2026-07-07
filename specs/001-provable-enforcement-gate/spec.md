# Feature Specification: Provable Enforcement — Gate Run Attestations and Canary Self-Tests

**Feature Branch**: `001-provable-enforcement-gate`

**Created**: 2026-07-07

**Status**: Draft

**Input**: User description: "provable enforcement: gate run attestations and canary self-tests"

## Context

The most dangerous defects found while building spec-gates were not gates
that blocked wrongly, but gates that **silently passed everything**: a
check-mode CLI that never existed (every file "passed" for weeks), auto-format
hooks whose library path resolved nowhere (no-op for their entire life), and a
dangerous-command pattern that matched on BSD grep but not GNU grep. Each
produced false confidence — worse than no gate, because users stop checking.
Separately, the parity property ("local green == CI green") was broken once by
tool **versions** alone (two prettier releases formatting tables differently),
proving parity is policy × implementation × tool versions, and the third leg
is currently pinned only by convention.

This feature makes enforcement self-evidencing: every gate run leaves a
verifiable record of what actually ran (attestation), and the system
periodically proves it still blocks known violations (canaries). The design
rule in the README — "a gate that cannot demonstrably block is reported
broken" — becomes a standing, automated invariant instead of a principle.

## Clarifications

### Session 2026-07-07

- Q: How does CI obtain a reference attestation for parity verification,
  given the attestation log defaults to gitignored? → A: No transport —
  each boundary verifies its own attestation against committed
  expectations (resolved tool versions vs `package-lock.json` pins, policy
  hash vs the committed `policy.json`); boundaries are proven equal
  transitively.
- Q: When doctor detects a suspected no-op gate (candidates > 0, zero files
  checked, result pass), is that a warning or a failure? → A: A failure —
  doctor exits nonzero naming the gate, same class as a required-tool gap;
  the combination has no legitimate false positive.
- Q: What is the parity severity default when the policy has no
  `attestation` section? → A: `error` — drift fails that boundary's gate
  run with tool, both versions, and remedy named; projects opt into
  `warning` explicitly.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - The gate proves it still blocks (Priority: P1)

A maintainer (or CI) runs the canary suite. The suite creates a sandbox
containing known violations — an unformatted file, a shell script with a
shellcheck finding, a dangerous bash payload, a protected-file edit, a
secret-shaped string — and requires the corresponding gate or hook to
**reject** each one. Any canary that is not rejected means enforcement has
silently rotted; the suite fails loudly and names the broken gate.

**Why this priority**: this is the direct countermeasure to the bug class
that occurred three times during initial development. It is the smallest
independently valuable slice: even with no attestations at all, a green
canary run means "the gate demonstrably blocks today."

**Independent Test**: run the canary suite on a healthy checkout (expect
pass), then deliberately break one gate (e.g., stub the formatter dispatch
to a no-op) and run it again (expect a loud, named failure).

**Acceptance Scenarios**:

1. **Given** a healthy projected runtime, **When** the canary suite runs,
   **Then** every canary reports "blocked as expected" and the suite exits 0.
2. **Given** a gate whose check-mode has been replaced with a no-op,
   **When** the canary suite runs, **Then** the suite exits nonzero and the
   failure message names the gate that failed to block.
3. **Given** a user project with real files, **When** the canary suite runs,
   **Then** no user file is created, modified, or deleted (sandbox only).

---

### User Story 2 - Every gate run leaves evidence (Priority: P2)

A team lead reviewing a semi-attended agent session (or auditing a merge)
inspects the attestation log. For each gate run they can see when it ran, at
which boundary, against which policy (by content hash), with which resolved
tool binaries and versions, how many files each tool actually checked, and
what the results were. "The gate was green" becomes "here is what the gate
actually did."

**Why this priority**: attestations turn trust into evidence and are the
foundation both for parity verification (Story 3) and for future
enhancements (spec-conformance gating, policy baselines). They are P2 only
because canaries deliver protection even without records.

**Independent Test**: run the gate twice with an unchanged policy and
toolchain; the two attestations are identical except timestamp, boundary,
and duration. Change the policy; the policy hash changes.

**Acceptance Scenarios**:

1. **Given** any `verify.sh` run at any boundary, **When** it completes
   (pass or fail), **Then** an attestation record is appended to the
   attestation log and embedded in `--json` output.
2. **Given** two runs with identical policy and tools, **When** their
   attestations are compared ignoring timestamp/boundary/duration fields,
   **Then** they are identical.
3. **Given** a gate that reports pass while checking zero files even though
   files matching its include globs exist, **When** doctor inspects the
   latest attestation, **Then** doctor fails (nonzero exit) naming the
   suspected no-op gate.

---

### User Story 3 - Parity is verified, not assumed (Priority: P3)

Every boundary verifies that the gate it just ran matches the project's
committed expectations: each resolved tool's version must match the pinned
version (e.g., in `package-lock.json`), and the policy in effect is
identified by content hash. If a developer's machine resolves prettier
3.5.3 while the project pins 3.9.4 — or CI does — that boundary's own gate
run reports the drift, with both versions named, at the severity the policy
specifies (error blocks, warning reports). Because every boundary passes
the same committed reference, agent, git, and CI runs are proven equivalent
transitively, with no attestation transport between machines.

**Why this priority**: this converts the README's parity claim into a
checked property. It depends on Story 2's attestation fields (resolved
binary + version per tool), so it lands last.

**Acceptance Scenarios**:

1. **Given** a project with pinned tool versions, **When** the gate runs at
   any boundary and every resolved tool version matches its pin, **Then**
   parity verification passes silently.
2. **Given** a resolved tool version that differs from its pin, **When**
   the gate runs, **Then** the drift is reported naming the tool, the
   resolved version, and the pinned version.
3. **Given** the policy's parity severity is `error`, **When** a tool
   version differs from its pin, **Then** that boundary's gate run fails.

---

### Edge Cases

- A brand-new project legitimately has zero files matching a tool's include
  globs: attestation records `files_checked: 0` with `candidates: 0`; the
  no-op heuristic (Story 2, scenario 3) only fires when candidates exist
  but the tool checked none.
- The attestation log grows unboundedly: the log is capped (oldest records
  dropped beyond a configurable maximum); the cap must not corrupt the file
  when two hooks append near-simultaneously.
- A tool is enabled in policy but not installed: the attestation records the
  tool as `skipped` (with reason), never as `pass`.
- `jq` missing entirely: `verify.sh` already fails with guidance; no
  attestation is written (a partial/corrupt record is worse than none).
- The policy file contains a `_comment` field or formatting-only changes:
  the policy hash is over raw bytes, so any byte change is a new hash —
  acceptable; the hash answers "same file?", not "same semantics?".
- Canary sandbox creation fails (no temp space, read-only FS): the canary
  suite fails closed with a diagnostic, never silently reports success.
- Attestations must not leak file contents: records contain counts, tool
  versions, hashes, and gate names — never file bodies; file _names_ are
  limited to the canary sandbox and failing-gate detail already shown by
  `verify.sh`.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: Every `verify.sh` run MUST produce an attestation record
  containing: schema version, timestamp (UTC ISO-8601), boundary, policy
  file content hash (SHA-256), runtime version marker, per-gate entries
  (gate name, resolved tool binary path, tool version string, candidate
  file count, checked file count, result: pass/fail/warn/skipped + reason,
  duration), and the overall exit status.
- **FR-002**: Attestation records MUST be appended to a project-local log
  (`.specify/gates/attestations.jsonl`), one JSON object per line, capped
  at a configurable maximum record count (default 200) by dropping oldest
  records.
- **FR-003**: `verify.sh --json` output MUST embed the same attestation
  object emitted to the log.
- **FR-004**: A gate whose include globs match at least one candidate file
  but which checked zero files MUST be distinguishable in the attestation
  (`candidates > 0, files_checked = 0`), and `doctor` MUST treat this
  combination on a passing gate as a failure: exit nonzero and name the
  suspected no-op gate (the combination has no legitimate false positive —
  candidates are counted after excludes, and a missing tool records
  `skipped`, never `pass`).
- **FR-005**: A canary suite MUST verify, in an isolated sandbox, that each
  of the following is rejected: (a) a formatting violation via the format
  gate; (b) a shell lint violation via the shellcheck gate; (c) a
  dangerous-command payload via the bash-validation hook; (d) a
  protected-file edit via the file-protection hook; (e) a secret-patterned
  staged content via the pre-commit secret scan. Each canary that is NOT
  rejected MUST fail the suite with the gate named.
- **FR-006**: The canary suite MUST NOT create, modify, or delete any file
  outside its sandbox, and MUST remove the sandbox on exit (including
  failure paths).
- **FR-007**: `doctor` MUST offer canary execution, and the projected CI
  template MUST run the canary suite alongside the gate.
- **FR-008**: Parity verification MUST compare the current run's
  attestation against the project's committed expectations — each resolved
  tool version against its pinned version (from the project's lockfile
  pins) and the policy content hash against the committed policy file —
  reporting any mismatch with both values named; its severity
  (error/warning) MUST be policy-configurable. No cross-boundary transport
  of attestation records is required.
- **FR-009**: The policy schema MUST gain an optional `attestation` section
  (enabled flag, max record count, parity severity) validated by both the
  JSON schema and the shell validator; absence of the section means
  attestations enabled with defaults: `enabled: true`, `max_records: 200`,
  `parity: error`.
- **FR-010**: All new code MUST run on bash 3.2 (macOS `/bin/bash`) with
  `jq` as the only hard dependency, offline.
- **FR-011**: Attestation records MUST NOT contain file contents.

### Key Entities

- **Attestation record**: the per-run evidence object described in FR-001;
  one per `verify.sh` invocation; identified by timestamp + boundary.
- **Attestation log**: the capped, append-only JSONL file holding recent
  records for a project.
- **Canary**: a known-violation probe with an expected rejection; the suite
  is the ordered set of canaries plus sandbox lifecycle.
- **Policy `attestation` section**: user-owned configuration (enabled,
  max_records, parity severity) following the existing policy-ownership
  rules (init seeds, upgrade never overwrites).

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: Reintroducing the historical no-op regression (check-mode CLI
  removed/stubbed) is detected by the canary suite in a single run — proven
  by a regression test that breaks the dispatch and asserts the suite fails
  naming that gate.
- **SC-002**: A resolved tool version that differs from the project's pin
  (e.g., prettier 3.5.3 resolved where 3.9.4 is pinned) is surfaced by
  parity verification in that boundary's very next gate run, with both
  versions named in the report.
- **SC-003**: Attestation writing adds no more than 1 second to a gate run
  on this repository's own gate.
- **SC-004**: The attestation log never exceeds the configured cap across
  any number of runs (verified by a loop test exceeding the cap).
- **SC-005**: The canary suite completes in under 30 seconds in CI and
  produces zero false failures across 20 consecutive healthy runs.
- **SC-006**: All existing test suites remain green, and the repository's
  own gate (with attestations enabled) stays green in CI.

## Assumptions

- `jq` and `git` are present (doctor already enforces this); no other
  runtime dependency is acceptable.
- Gate runs within one boundary are effectively serialized (Claude Code Stop
  hook, git hooks, CI job); simultaneous cross-boundary appends are rare and
  the cap operation tolerates them without corrupting the log.
- Hash-based identity (SHA-256 of policy bytes) is sufficient for v1;
  cryptographic signing / tamper-proof attestation is explicitly out of
  scope (a future enhancement may add it).
- A remote/central attestation store is out of scope; the log is
  project-local.
- The spec-conformance gate (enhancement #1) and policy baseline
  propagation (enhancement #3) are out of scope here but are expected
  consumers of the attestation format and hash machinery.
- Whether the attestation log is committed or gitignored is a per-project
  choice; the default seeds it as gitignored (records are evidence, not
  source). Parity verification does not depend on the log being shared:
  each boundary checks its own run against committed pins (Clarifications,
  2026-07-07).
- Parity's pin source is the project's existing dependency pinning (e.g.,
  `package-lock.json` for node-resolved linters); tools without a pin
  source (e.g., system `shellcheck`) are attested but exempt from pin
  comparison in v1.
