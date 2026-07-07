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
   latest attestation, **Then** it reports a suspected no-op gate.

---

### User Story 3 - Parity is verified, not assumed (Priority: P3)

CI verifies that the gate it just ran is the same gate the developer's
boundaries ran: same policy hash, same tool versions. If the agent boundary
attested prettier 3.9.4 but CI resolves 3.5.3 — or the policy file changed
between the local run and the push — the discrepancy is reported at the
severity the policy specifies (error blocks, warning reports).

**Why this priority**: this converts the README's parity claim into a
checked property. It depends on Story 2's records existing at two
boundaries, so it lands last.

**Acceptance Scenarios**:

1. **Given** an agent-boundary attestation committed alongside a change,
   **When** CI runs the gate and compares attestations, **Then** matching
   policy hash + tool versions passes and any mismatch is reported with
   both values named.
2. **Given** the policy's parity severity is `error`, **When** tool versions
   differ between boundaries, **Then** the CI gate run fails.

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
  (`candidates > 0, files_checked = 0`), and `doctor` MUST flag this
  combination as a suspected no-op gate.
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
- **FR-008**: A parity verification mode MUST compare two attestations
  (e.g., latest agent-boundary vs current CI run) on policy hash and
  per-tool version, reporting any mismatch with both values; its severity
  (error/warning) MUST be policy-configurable.
- **FR-009**: The policy schema MUST gain an optional `attestation` section
  (enabled flag, max record count, parity severity) validated by both the
  JSON schema and the shell validator; absence of the section means
  attestations enabled with defaults.
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
- **SC-002**: A tool-version difference between two boundaries (e.g., two
  prettier versions) is surfaced by parity verification in the first CI run
  after it appears, with both versions named in the report.
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
  source), with parity verification reading the agent attestation from the
  log when present.
