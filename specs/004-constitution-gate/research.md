# Research: Constitution as Enforceable Contract

Decisions for the open technical questions in plan.md. Constraints
throughout: bash 3.2 floor, BSD + GNU toolchains, jq only, offline with
the bundled corpus, never auto-fill constitution values, user-owned files
only change on approval.

## R1 — Enforcement-annotation format

**Decision**: one inline HTML comment marker on the line following each
principle's heading (or first line for list-style principles):

```text
<!-- gates:enforce surface=policy ref=spec.severity expect=error -->
<!-- gates:enforce surface=git-hook ref=commit-msg -->
<!-- gates:enforce surface=prose -->
```

Grammar: `gates:enforce` tag, `surface=<type>` from the fixed set
(`policy | agent-hook | git-hook | ci | accept | scanner | prose`),
`ref=` surface-specific identifier (required except for prose),
`expect=` optional expected value (policy surfaces). One marker per
principle; a principle without a marker is simply unannotated (FR-013's
informational note, never an error); a malformed marker is a doctor
failure naming the line (fail closed — an unreadable claim is worse than
no claim).

**Rationale**: HTML comments are invisible in rendered markdown, survive
prettier (verified: prettier preserves comments; this repo's constitution
already carries the Sync Impact comment), survive the core command's
fill-and-version flow (it rewrites placeholders, not arbitrary comments),
and bind tightly to the principle they annotate — a separate map section
would drift on renames, which is exactly the disease this feature cures.

**Alternatives considered**: trailing "Enforcement Map" table (rejected:
binds by principle name, drifts on rename, two places to edit); YAML
frontmatter on the constitution (rejected: the core template has none and
the core command could clobber it); a sidecar file (rejected: separable
from the document it makes claims about).

## R2 — Corpus format and charter interoperability

**Decision**: adopt the charter extension's registry layout verbatim —
`manifest.yml` (name + `mandatory_fragments` / `recommended_fragments` /
`optional_fragments` lists) over `fragments/<category>/<name>.md` —
and put this feature's extra metadata in fragment YAML frontmatter:

```text
---
id: workflow/branch-first
statement: "All changes reach main via pull request; never commit to main."
rationale: "Every CPF-era repo converged on this; direct-to-main commits were the top pre-CPF incident source."
surface: git-hook
ref: pre-commit
tags: [workflow, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026)"
---
<fragment body: the principle text as it should appear in a constitution>
```

Charter reads the body (frontmatter is standard markdown metadata it
tolerates); our tooling reads the frontmatter. One registry can serve
both consumers (FR-011). Verified against Fyloss/spec-kit-charter README
at research time: layout is `manifest.yml` + `fragments/<cat>/<name>.md`,
tiers mandatory/recommended/optional, registries are local dirs or git
repos.

**Rationale**: zero-cost interop beats a private format plus a converter;
frontmatter-over-markdown is the established pattern for exactly this
(and parses with a 15-line awk splitter on the BSD floor).

**Alternatives considered**: JSON fragment files (rejected: charter can't
read them, and principle prose belongs in markdown); our own layout plus
an export command (rejected: two formats to keep honest).

## R3 — Session pipeline: conversation vs deterministic core

**Decision**: the command markdown owns the conversation; every
deterministic step is a `constitution.sh` subcommand the session calls:

- `constitution.sh fragments --corpus <dir> --profile <answers.json>` —
  list candidate fragments filtered/ranked by the interview profile
  (project type, postures), TSV out.
- `constitution.sh draft --corpus <dir> --selections <selections.json>
--out <file> [--augment <existing.md>]` — assemble the filled,
  annotated constitution draft; augment mode preserves existing content
  and appends/annotates only.
- `constitution.sh align [--policy <file>]` — read annotations, compare
  against the live enforcement layer, emit the alignment proposal
  (TSV: principle, surface, ref, state=active|missing|pending, proposed
  change) — computation only, never applies anything.
- `constitution.sh check` — the doctor primitive: verify every
  annotation's surface activity, exit 0/1, one line per principle.

The answers/selections files are plain JSON. The interview NEVER writes
the constitution directly — the agent gathers decisions, materializes
them into selections.json, and calls `draft`; the user sees the draft
before it lands. Non-interactive callers (tests, scripted runs) provide
the same files, which is how FR-006's "answers file" requirement and the
SC regression tests are satisfied with one code path.

**Rationale**: identical to the init/policy-infer split that already
works; makes SC-001/002/003 hermetically testable without simulating
conversation.

**Alternatives considered**: pure command-markdown flow with ad-hoc shell
(rejected: untestable, drifts); a single monolithic `run` subcommand
(rejected: doctor needs `check` alone; init needs `fragments` alone).

## R4 — Surface-activity semantics (local-only, per type)

**Decision** (what "active" means in v1, all checked from local files):

| surface      | ref format               | active when                                                                                                                                                  |
| ------------ | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `policy`     | `<section>.<key>`        | key present in the enforced policy (effective policy when 003 contract is live) and, if `expect=` given, equal to it; enabled-style keys must not be `false` |
| `agent-hook` | `<script.sh>`            | file exists under `.claude/hooks/gates/`, is executable, and is wired in `.claude/settings.json`                                                             |
| `git-hook`   | `pre-commit\|commit-msg` | installed hook exists, is executable, and delegates to the gates runtime (same logic doctor's git-boundary section already uses)                             |
| `ci`         | `<check/job name>`       | a workflow/pipeline file under `.github/workflows/` (or `.gitlab-ci.yml`, `Jenkinsfile`) contains the named job/check                                        |
| `accept`     | `<feature>/<SC-id>`      | the named feature's tasks.md contains an accept block whose `# verifies:` matches, and it parses (spec-gate lib)                                             |
| `scanner`    | `<tool>:<rule>`          | the tool's config file exists and mentions the rule (e.g. checkov `CKV_GCP_117`)                                                                             |
| `prose`      | —                        | always "prose-only"; listed, never checked, never failed                                                                                                     |

**Rationale**: local-only keeps doctor offline and fast (SC-004);
"actually runs remotely" is already covered by the parity gate and the
CI boundary itself — this feature checks the _claim wiring_, not remote
execution (same division 001 drew).

**Alternatives considered**: invoking surfaces to prove them live
(rejected: doctor must stay side-effect-free and ≤ 1s); remote CI API
checks (rejected: offline doctrine).

## R5 — Alignment computation and application

**Decision**: `align` derives, per annotated principle, either
`state=active` (no change), `state=missing` + a proposed change, or
`state=pending-boundary` (surface type not applicable yet — e.g. `ci`
with no CI boundary projected). Proposed changes by surface: policy →
a jq assignment sketch shown as a unified diff of the policy file
(applied to the OVERLAY when a 003 contract is live — the change then
shows up in the deviation/propose machinery exactly like any overlay
edit); git/agent hooks → the existing init wiring steps; ci → pointer to
`/speckit.gates.ci`; accept → a stub block proposal for the named
feature; scanner → config snippet. Application is performed by the agent
session after explicit approval, change by change; `align` itself never
writes. Decline = byte-identical repo (SC-003 is tested by hashing the
tree before/after a declined run).

**Rationale**: keeps the deterministic layer pure-compute and puts the
only mutating steps behind the same conversational approval init uses;
the 003 interplay (align edits the overlay, never the effective policy)
falls out for free.

## R6 — Core-command handoff (FR-012)

**Decision**: the session writes the approved draft to
`.specify/memory/constitution.md` itself (showing the full diff first) —
this IS the "filled draft" — and then instructs the user/agent to run
the core `/speckit-constitution` command, which now finds concrete
content instead of placeholders and performs its normal
versioning/ratification/Sync-Impact pass unchanged. Registered as the
extension's `before_constitution` hook (optional: true) so projects that
invoke the core command first get offered the session at exactly the
right moment. The annotation markers survive the core pass (R1).

**Rationale**: the core command's contract is "fill placeholders or
update concrete text, version it, propagate" — handing it concrete text
is its native happy path; owning versioning ourselves would fork core
behavior (rejected in Clarifications).

## R7 — Starter corpus content and provenance

**Decision**: harvest ~30 fragments from three mined sources, each
fragment carrying `provenance`: (1) the CPF-8 cross-project baseline
(branch-first, atomic commit-standards rule, no-secrets-with-rotation,
fail-loudly/never-fabricate, changed-files-scoped enforcement with
grandfathering, single-chokepoint architecture, policy-change approval,
worktree/`git -C` safety, least-privilege, out-of-scope section); (2)
Kahi's generalizable set (readiness gates, pre-PR local verification,
tracking-file immutability, CODEOWNERS-on-governance, stop-hook
discipline); (3) this repository's constitution v1.0.0 (fail closed,
provable enforcement, one-policy-three-boundaries, projection,
spec-as-boundary). Tag taxonomy: `project-type/*` (service, cli, spa,
library, infra, docs), `posture/*` (regulated, security-hardened,
solo, team), plus surface tags. Tiers: the no-secrets and branch-first
class → `mandatory` in the starter manifest; most others `recommended`.

**Rationale**: every fragment is a rule that survived real projects and
real failures — provenance is the fragment's credibility, so it is a
required field, not a nicety.

## R8 — Placeholder detection (FR-014, init hookup)

**Decision**: a constitution is "placeholder-only" when it matches the
core template's signature: contains `[PRINCIPLE_1_NAME]`-style
bracket-tokens (`[A-Z_]{3,}` inside brackets) or is byte-equal to the
shipped template; "absent" when the file does not exist. init runs this
detection (via `lib/constitution.sh`) and offers — never forces — the
session; declining records nothing and changes nothing.

**Rationale**: the bracket-token signature is the same one the core
constitution command scans for, so the two tools agree on what
"unfilled" means.
