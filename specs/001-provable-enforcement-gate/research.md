# Phase 0 Research: Provable Enforcement

All Technical Context entries were resolvable; no NEEDS CLARIFICATION
remained after `/speckit-clarify`. This document records the technical
decisions, each verified empirically on the target platforms (macOS bash
3.2 / BSD userland and Linux CI / GNU userland) before being adopted.

## R1 — Tool version detection

**Decision**: For node-resolved tools (`node_modules/.bin/<tool>`), read the
version from `node_modules/<pkg>/package.json` with jq. For PATH-resolved
tools, run the tool's version command once and parse the first meaningful
line (`prettier --version` → `3.9.4`; `shellcheck --version` → line 2
`version: 0.11.0`). Cache per run — one detection per tool per gate run.

**Rationale**: package.json reads are fast (no interpreter startup), exact,
and cannot hang; verified `jq -r .version node_modules/prettier/package.json`
returns `3.9.4` matching `--version` output. PATH tools have no package.json,
so the version command is the only source.

**Alternatives considered**: always invoking `<tool> --version` (spawns node
per tool — measurable against the ≤1s overhead budget, SC-003);
`markdownlint-cli2` banner parsing (its version appears on every run's
banner, but that couples parsing to output format across versions —
package.json is stable).

## R2 — Pin source extraction

**Decision**: Read pins from `package-lock.json` (lockfileVersion ≥ 2) via
`jq -r '.packages["node_modules/<pkg>"].version'`. If the lockfile or the
entry is absent, the tool is attested but **exempt from pin comparison**
(recorded as `pinned: null`), per the spec's Assumptions.

**Rationale**: verified against this repo's lockfile (v3): prettier `3.9.4`,
markdownlint-cli2 `0.23.0` extract cleanly. Lockfile v2 also carries
`.packages`; v1 (npm ≤ 6, EOL) does not — treating v1 as "no pin source" is
acceptable and self-documenting in the attestation.

**Alternatives considered**: `package.json` devDependencies (ranges, not
pins — defeats the purpose); `npm ls --json` (spawns npm, slow, requires
install state); a gates-specific pin file (new artifact to drift — the
lockfile is already the project's pin source of truth).

## R3 — Portable SHA-256

**Decision**: resolution chain `sha256sum` → `shasum -a 256` → fail loudly
(policy hash is load-bearing; no silent skip). Implemented once in the new
`lib/attest.sh` as `gates_sha256 <file>`.

**Rationale**: Linux/GNU ships `sha256sum`; macOS ships `shasum` (verified
both resolve on the dev machine; CI has `sha256sum`). Two-step chain covers
every target; failing loudly honors fail-closed when neither exists.

**Alternatives considered**: `openssl dgst -sha256` as a third fallback
(adds an implicit dependency the spec doesn't grant; the two-step chain
already covers all supported platforms); md5 (not collision-credible for an
identity claim).

## R4 — JSONL append and cap without corruption

**Decision**: build each record as a single compact JSON line (`jq -c`),
append with one `printf '%s\n' >> log` write; enforce the cap only when
exceeded, by `tail -n <max>` to a temp file in the same directory followed
by `mv` (atomic rename on the same filesystem). Concurrent capping is
last-writer-wins.

**Rationale**: single-line writes below PIPE_BUF (records are well under
1 KB; FR-011 keeps contents out) do not interleave in practice; the atomic
rename means readers never observe a truncated file. The spec's assumption
is that same-boundary runs are serialized and cross-boundary collisions are
rare — losing a cap race costs at most a few excess old records, never a
corrupt line.

**Alternatives considered**: `flock` (not on macOS base system); lockfile
directories (`mkdir` spinlock — adds failure modes like stale locks for a
non-problem); SQLite (dependency the spec forbids).

## R5 — Canary sandbox design

**Decision**: `canary.sh` creates `mktemp -d` sandboxes: one projected-
runtime fixture (copy `verify.sh` + `lib/` + a minimal policy, symlink the
host project's `node_modules` when present so pinned linters resolve — the
pattern already proven in `tests/test-gate.sh`), plus a `git init` fixture
for the secret-scan canary. Hook canaries (validate-bash, protect-files)
pipe crafted JSON payloads to the hook scripts directly. `trap ... EXIT`
removes sandboxes on every path; `CLAUDE_PROJECT_DIR` pins all runtime path
resolution inside the sandbox, guaranteeing FR-006 (no user-file writes).

**Rationale**: reuses the exact fixture pattern the test suites already
validate on both platforms; hooks and gates are exercised through their
real entrypoints (the canary proves the same code path a real violation
would take, which is the point).

**Alternatives considered**: running canaries against the live project tree
with synthetic files (violates FR-006 isolation; a crash could leave debris
in the user's repo); container isolation (heavy dependency, offline
constraint).

## R6 — Timestamps and durations on bash 3.2

**Decision**: timestamps as `date -u +%Y-%m-%dT%H:%M:%SZ` (UTC ISO-8601,
verified identical on BSD and GNU date); durations as whole seconds from
`date +%s` deltas.

**Rationale**: bash 3.2 lacks `EPOCHREALTIME`; sub-second timing would need
GNU `date +%N` (absent on macOS) or another interpreter. Whole seconds
satisfy every consumer in the spec (SC-003's ≤1s budget is measured by the
test harness, not by the attestation's own duration field).

**Alternatives considered**: `perl -MTime::HiRes` (new dependency);
recording no durations (loses cheap, useful evidence).

## R7 — Where parity verification executes

**Decision**: parity runs inside `verify.sh` as a synthetic gate entry named
`parity`, evaluated after the tool gates using the versions already detected
for the attestation, at the policy's `attestation.parity` severity (default
`error`). It appears in the report and the attestation like any other gate.

**Rationale**: keeps the single-implementation rule — every boundary gets
parity automatically because every boundary already calls `verify.sh`; no
hook or CI template change is needed for Story 3, and the result is
self-documenting in the same record.

**Alternatives considered**: a separate `parity.sh` entrypoint (second
surface for boundaries to forget to call — exactly the divergence this
project exists to prevent); doctor-only parity (doctor is diagnostic, not a
boundary; drift must block at the boundary per Clarifications).
