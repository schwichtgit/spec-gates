# Phase 0 Research: Spec Conformance Gate

All Technical Context entries were resolvable; no NEEDS CLARIFICATION
remained after `/speckit-clarify`. Decisions below follow 001's practice:
each platform-sensitive choice was verified empirically on the target floor
(macOS `/bin/bash` 3.2.57, BSD userland) before being adopted.

## R1 — Accept-block parsing

**Decision**: a single awk state machine over `tasks.md`: a line matching
`^[[:space:]]*` + ` ```accept ` opens a block; the next
`^[[:space:]]*` + ` ``` ` closes it; interior lines are dedented and
collected as the command sequence. The block is associated with the nearest
preceding task line (`- [ ]`/`- [x]`, tolerant of leading whitespace and
either checkbox case); a leading `# verifies: <ID>` comment line is
extracted as the explicit criterion reference. Parse output is one JSON
object per block (built with jq), consumed by the runner.

**Rationale**: verified the fence state machine on BSD awk against the
clarified format (adjacent fenced block, indented under a task bullet). awk
is already in the runtime's toolbox; the grammar needs no markdown library.
Emitting JSON at the parse boundary keeps the runner and the attestation
builder on jq, the established data plane.

**Malformed** (FR-005, fail closed): a fence opened but never closed; an
`accept` block with no command lines (only comments/blank); an `accept`
block with no preceding task line in the same file. Each is a parse error
naming file and line — never a skip.

**Alternatives considered**: grep/sed line pairing (cannot detect an
unterminated fence — exactly the silent-skip failure mode FR-005 forbids);
requiring a `# verifies:` in every block (redundant with adjacency for the
common case; kept optional).

## R2 — Completion detection

**Decision**: a feature is complete when its `spec.md` contains a line
whose stripped form is `**Status**: Complete` (case-sensitive value,
surrounding whitespace tolerated), extracted with
`sed -n 's/^\*\*Status\*\*:[[:space:]]*//p' | head -n 1`. Any other value,
or a missing field/file, means not complete.

**Rationale**: the field already exists in every feature spec produced by
the template (Clarifications, 2026-07-07); first-match extraction is
deterministic even if body text mentions "Status" elsewhere. Case-sensitive
`Complete` avoids accidental enforcement from prose like "status: complete
rewrite planned".

**Alternatives considered**: YAML frontmatter (feature specs don't have
frontmatter; adding it churns the template and every existing spec);
parsing the whole header section (more states, no added safety).

## R3 — Task checkbox accounting

**Decision**: count `- [ ]` (unchecked) and `- [x]`/`- [X]` (checked) task
lines in `tasks.md`, tolerant of leading whitespace, ignoring everything
inside fenced code blocks (the same fence tracking as R1 — an example
checkbox inside a code sample must not count). For a complete feature,
`unchecked > 0` is drift and blocks; the first unchecked task's text is
named in the failure.

**Rationale**: matches how spec-kit tasks.md is actually written (001's
25 tasks all use this shape); fence-awareness costs nothing since the
parser already tracks fences.

**Alternatives considered**: counting only `- [ ]` under `## Phase`
headings (couples the gate to template heading conventions that vary);
treating any unchecked box anywhere as drift including checklists/ (out of
scope — the gate reads `tasks.md` only, per spec FR-001).

## R4 — Per-block timeout without `timeout(1)`

**Decision**: a pure-shell watchdog, one code path on every platform: run
the block in a background subshell, start a killer subshell
(`sleep N; kill $pid`), `wait` on the block, then kill the watcher. Timeout
surfaces as exit 143 (SIGTERM) and is reported as
`timeout after <N>s`; otherwise the block's real exit code propagates
exactly.

**Verified**: on `/bin/bash` 3.2.57 — timeout returns 143, a fast command
returns 0, a failing command's exit code (7) propagates unchanged.

**Rationale**: macOS base has no `timeout(1)` (the one on this dev machine
is user-installed in `/usr/local/bin`); a "use timeout(1) when present"
fallback would create two code paths — cross-platform divergence is this
project's recurring bug source, so the portable path is the only path.

**Alternatives considered**: `timeout(1)` with watchdog fallback (two code
paths, divergent kill semantics); `perl -e 'alarm...'` (new dependency,
rejected in 001 R6 for the same reason).

## R5 — Mutation detection

**Decision**: snapshot `git status --porcelain` immediately before and
after each block's execution; any difference fails that block with
`working tree modified by accept block` plus the changed paths (from the
diff of the two snapshots). The tree may already be dirty when the gate
runs — only the delta matters. No auto-revert (FR-006).

**Rationale**: `git status --porcelain` is stable, fast (this repo: well
under 100ms), and catches creations, modifications, and deletions of both
tracked and untracked files. Per-block snapshots give exact attribution of
which criterion mutated the tree.

**Alternatives considered**: hashing the tree (`git stash create` /
`git write-tree`) — misses untracked files without extra plumbing;
before/after only per gate run (cannot attribute the mutation to a block);
filesystem watchers (platform-divergent, heavy).

## R6 — Where the `spec` gate runs and the on-demand interface

**Decision**: the `spec` gate is a synthetic gate entry in `verify.sh`,
evaluated after the tool gates and before `parity`, exactly like 001's
parity gate — every boundary gets it automatically because every boundary
already calls `verify.sh`. On-demand execution for incomplete features is
`verify.sh --accept <feature-dir-name|all>`: it additionally executes the
named feature's blocks and prints per-criterion results as informational
output (never affects the exit code for incomplete features). Doctor
reports discovery (features, blocks, complete count) in its normal run and
fails on parse errors.

**Rationale**: the single-implementation rule (001 R7) — a separate
entrypoint would be a second surface for boundaries to forget. Putting
on-demand execution behind a `verify.sh` flag keeps one runner, one output
format, one attestation path.

**Alternatives considered**: `doctor --accept` delegating like `--canary`
(doctor is diagnostic; execution results belong to the runner that owns
severity and attestation); a standalone `spec-gate.sh` executable (second
surface, violates the rule above).

## R7 — Feature discovery

**Decision**: features are the direct children of `specs/` that contain a
`spec.md`, discovered with a glob + `-f` test, processed in lexicographic
order (deterministic, FR-001). No recursion; no dependence on the
`NNN-`/timestamp prefix convention. A missing `specs/` directory yields
zero features and a trivial pass (FR-011).

**Rationale**: works for both sequential and timestamp numbering modes and
for repos that never ran spec-kit; lexicographic order makes runs and
attestations comparable across boundaries.

**Alternatives considered**: honoring `.specify/feature.json` only (that
file names the _active_ feature, but enforcement must cover _all_ complete
features); configurable specs roots (out of scope per spec Assumptions).

## R8 — Spec-gate canary

**Decision**: extend `canary.sh` with a sixth canary: inside the existing
projected-runtime sandbox, create `specs/900-canary-fixture/` containing a
`spec.md` with `**Status**: Complete` and a `tasks.md` with one checked
task and one accept block whose command is `false`; run the sandboxed
`verify.sh` and require the `spec` gate to fail naming the fixture. Not
rejected → the suite fails naming the spec gate (FR-009).

**Rationale**: reuses 001's sandbox lifecycle and the "prove the real code
path blocks" doctrine; the fixture exercises discovery, completion
detection, execution, and severity in one probe.

**Alternatives considered**: stub-level unit assertion inside
`test-spec-gate.sh` only (tests are dev-side; the canary is what ships to
user projects and CI, and FR-009 requires the shipped probe).
