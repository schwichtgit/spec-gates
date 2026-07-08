# Research: Policy as Versioned Contract

Decisions for every open technical question in plan.md's Technical Context.
Each entry: Decision / Rationale / Alternatives considered. Constraints
throughout: bash 3.2 floor, BSD + GNU toolchains, jq + git only, offline at
verify time, fail closed.

## R1 — `extends` declaration shape

**Decision**: an object, not a packed string:

```json
"extends": { "source": "<git URL or local path>", "version": "<tag or commit>", "file": "policy.json" }
```

`source` and `version` required when the section is present; `file`
optional (default `policy.json`) selecting the baseline document inside the
source repository. `additionalProperties: false`.

**Rationale**: the `URL@version` string form from the feature description
is ambiguous for real git URLs (`git@github.com:org/repo` already contains
`@`); an object needs no parsing rules, validates field-by-field in the
existing schema machinery, and leaves room for future fields without a
format break. The commands' docs may still show the `@` mnemonic in prose.

**Alternatives considered**: packed `source@version` string (rejected:
`git@` ambiguity, unschematizable parts); separate top-level fields
(rejected: pollutes the policy root; the section groups naturally).

## R2 — Baseline fetch mechanism (sync time only)

**Decision**: clone into `mktemp -d`, resolve the version, read one file:

```sh
git clone -q --no-checkout <source> <tmp>
git -C <tmp> checkout -q <version> -- <file>     # after: git -C <tmp> fetch -q origin <version> if needed
```

Concretely: try `git clone -q --depth 1 --branch <version>` first (works
for tags/branches on every host); on failure fall back to a full
`git clone` + `git checkout <version>` (covers commit SHAs on hosts that
refuse SHA-in-want). Local paths work identically — git treats a directory
as a remote. The temp clone is removed on every exit path.

**Rationale**: git is the only fetch tool the runtime may assume; the
two-step fallback covers tags, branches, and SHAs across GitHub/GitLab/
plain-file remotes without host-specific code. Tests use `file://` and
plain-path remotes — no network.

**Alternatives considered**: `git archive --remote` (rejected: disabled on
GitHub); raw HTTPS download of a file URL (rejected: host-specific URL
schemes, no commit resolution, second fetch path to maintain).

## R3 — Contract artifact layout (committed, beside policy.json)

**Decision**: three derived artifacts in `.specify/gates/`:

| File                    | Content                                                                     |
| ----------------------- | --------------------------------------------------------------------------- |
| `baseline.json`         | snapshot: the fetched baseline document, canonicalized (`jq -S .`)          |
| `baseline.lock.json`    | pin: `{ "source", "version", "file", "digest": "sha256:<hex>" }` — no times |
| `policy.effective.json` | materialized merge (R4), canonicalized (`jq -S .`)                          |

All three are committed (they are the contract's local truth and must
survive clone-and-run offline); none are gitignored. `policy.json` remains
the only user-edited file; sync never writes it.

**Rationale**: committed artifacts are what makes FR-005/FR-007 provable
offline; no timestamps keeps diffs semantic and recomputation
byte-deterministic; `jq -S` canonicalization makes "byte-identical" a
stable property across jq versions and key orders.

**Alternatives considered**: pin embedded inside `policy.json` (rejected:
sync would write the user-owned file); a single combined lock+snapshot file
(rejected: snapshot must validate as a policy on its own and diffs read
better separately); gitignoring the effective policy and recomputing at
every run (rejected: hooks and CI read the policy dozens of times per run —
and a missing artifact could not be distinguished from never-synced).

## R4 — Merge semantics (baseline ⊕ overlay)

**Decision**: jq's recursive object-merge with overlay winning:

```text
effective = (baseline * (overlay | del(.extends))) | sort keys (jq -S)
```

Semantics, documented in the artifact contract: objects merge recursively;
scalars and **arrays replace wholesale** (no element-level union); the
`extends` section itself is excluded from the merge input and re-attached
verbatim in the effective output (traceability without recursion).

**Rationale**: `*` is deterministic, bash-3.2-free, already shipped with
the only hard dependency, and its array-replacement rule is the honest one
for policy lists (a merged include-list union would hide what the overlay
actually enforces). 001 established "the lockfile is the truth" with the
same wholesale-replacement doctrine.

**Alternatives considered**: element-wise array union (rejected: silently
strengthens/widens in ways neither side wrote); JSON Merge Patch RFC 7386
(rejected: null-means-delete surprises policy authors and jq `*` covers
the actual need); custom merge in awk (rejected: reimplementing jq).

## R5 — Deviation classification (defined-order fields only)

**Decision**: deviations are computed live (never stored) by comparing
baseline vs effective per hook/section with jq. Classification:

- `weakened`: `enabled` true→false; severity along `error > warning > off`
  moving right; `include` narrowed (element removed) or `exclude` widened
  (element added).
- `changed`: any other differing value (commands, orchestrators, unordered
  fields), plus scope-list changes that both add and remove.
- Additions of new hooks/sections and strengthenings are not deviations.

Output: one line per deviation `contract: deviation (<class>): <path>:
baseline <a> -> overlay <b>`, echoed informationally by the gate, counted
in attestations, and enumerated by `propose`.

**Rationale**: matches the clarification decision exactly (defined
comparable fields; everything else neutral); computing live from
snapshot + overlay means the inventory can never drift from reality.

**Alternatives considered**: storing a deviations file at sync time
(rejected: a fourth artifact that can go stale — recomputation is cheap);
classifying custom_command changes semantically (rejected in
clarification).

## R6 — Drift proving at verify time (the `contract` gate)

**Decision**: a synthetic `contract` gate evaluated immediately after
policy validation, before tool gates. Checks, in order, each failing
closed with the artifact named:

1. `extends` absent → gate not emitted at all (dormant, FR-001).
2. Lock/snapshot/effective missing → fail: `contract: not synced (<file>
missing) — run /speckit.gates.sync`.
3. `sha256(baseline.json)` ≠ lock digest → fail: snapshot tampered.
4. `jq -S` recompute of merge(snapshot, overlay) ≠ `policy.effective.json`
   bytes → fail: effective policy drifted (names which side to regenerate).
5. Overlay's `extends` ≠ lock's source/version/file → fail: pin out of
   date with the declaration (re-sync).
6. All green → gate `pass`; deviations (R5) printed informationally.

The runtime reads `policy.effective.json` (via `gates_policy_file`
resolution) whenever `policy.json` declares `extends` and the effective
file exists; otherwise `policy.json` as today. `GATES_POLICY_FILE`
override keeps absolute precedence (tests depend on it).

**Rationale**: integrity before enforcement — a tampered policy must fail
before any gate consults it; the ordering mirrors how parity guards tool
identity. Reading the effective file (rather than merging per run) keeps
the dozens of per-run policy reads cheap and keeps hooks unchanged.

**Alternatives considered**: merging on every read (rejected: R3);
placing the gate after tools like `spec`/`parity` (rejected: gates would
have already run under a possibly-tampered policy).

## R7 — Update detection and version ordering

**Decision**: `contract.sh sync --update [version]`. With an explicit
version, fetch and pin exactly that. Without one, list candidate versions
via `git ls-remote --tags <source>`, filter to `v?[0-9]*` tags, strip
peeled `^{}` entries, and pick the highest by a small awk numeric
segment-comparator (split on dots, compare fields numerically, longer
wins on prefix-equality). Plain `sync` (no flag) never moves the pin — it
re-fetches the pinned version only (repair/first-sync).

**Rationale**: explicit-first keeps SC-003 conservative; `sort -V` is not
on the BSD floor, and a 15-line awk comparator is testable and sufficient
for tag ordering; `ls-remote` is the one permitted network call and it
happens only in the interactive sync command.

**Alternatives considered**: `sort -V` (BSD absence); pinning to a branch
head (rejected: a moving pin is the anti-pattern this feature exists to
kill); auto-update on every sync (rejected: silent enforcement change).

## R8 — Reviewable update delivery (consumer side)

**Decision**: `sync --update` writes the three artifacts, then: if the
tree is a git repo, create branch `gates/baseline-<version>`, commit the
artifact changes with a generated summary (old→new version, digest, and
the R5-classified enforcement delta), and — when `gh` is available and the
repo has a GitHub remote — open the PR with that summary as body. Without
`gh`/remote: leave the committed branch plus printed next-step
instructions. Never commits to the current branch; never pushes without a
remote.

**Rationale**: matches FR-008's "reviewable change" with graceful
degradation, using only tools already in the environment contract (git
required for this flow; gh optional exactly as the repo's own workflow
treats it).

**Alternatives considered**: patch-file-only output (kept as the final
fallback when not even a git repo); direct commit to current branch
(rejected: silent enforcement change, SC-003).

## R9 — Propose delivery (upstream change request)

**Decision**: `contract.sh propose` computes the R5 deviation inventory;
if empty, reports "nothing to propose" and exits 0. Otherwise it clones
the baseline source (R2), applies the deviations onto the baseline
document (jq merge of just the deviating paths), writes the result to the
baseline file on branch `propose/<consumer-repo-name>-<date>`, commits
with a body carrying origin repo, pinned version, per-deviation
classification, and the maintainer's rationale (prompted, or `--rationale`
flag for non-interactive use), and opens a PR against the source when `gh`
can; otherwise prints the branch path in the temp clone plus a patch file
under `.specify/gates/proposals/` and instructions.

**Rationale**: FR-009's artifact must be reviewable without asking the
proposer for context — origin, version, classification, and rationale are
exactly the review inputs; the patch fallback keeps the flow alive for
hosts without `gh`.

**Alternatives considered**: issue-only proposal (rejected: a concrete
diff reviews better than prose); editing the baseline repo in place via a
long-lived local clone (rejected: temp clones keep no state to go stale).

## R10 — Attestation, canary, and doctor surfaces

**Decision**:

- Attestation: a `contract` GateEntry in `gates[]` (result pass/fail,
  reason names the drifted artifact) plus an optional top-level `contract`
  object `{ source, version, digest, effective_sha256, deviations:
{ weakened: N, changed: N } }` — absent when `extends` is absent.
  Record stays `v: 1` (additive, consumers ignore unknown fields).
- Canary: `contract` probe — sandbox with a synced fixture contract whose
  `policy.effective.json` is then tampered; the sandboxed `verify.sh` must
  exit 2 naming the contract gate; wired into `--only`.
- Doctor: contract section reporting declaration, pin presence,
  snapshot-digest match, effective-recompute match, and the deviation
  inventory; fails (exit 1) on exactly the drift conditions the gate
  blocks on; `[rec]` nudge when `extends` is declared but never synced.

**Rationale**: identical evidence pattern as 001 (parity) and 002 (spec):
every new gate class ships attested, canaried, and doctor-visible —
constitution principle II is not optional.

**Alternatives considered**: none — this surface is constitutionally
required; only the field shapes were open, and they mirror the `spec`
object precedent.
