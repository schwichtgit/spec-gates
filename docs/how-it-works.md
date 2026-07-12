# How spec-gates works

## The three-boundary model

Quality rules only matter if they are enforced wherever code can change.
There are exactly three such places in an agentic workflow:

1. **The agent boundary** — while the agent is working. Claude Code
   exposes lifecycle hooks; spec-gates uses four of them:
   - `PreToolUse(Write|Edit)` → `protect-files.sh`: refuse edits to
     secrets, keys, CI configs, the constitution, and policy.json itself.
     The refusal message tells the agent _why_ and what to do instead,
     redirecting it productively rather than derailing the session.
   - `PreToolUse(Bash)` → `validate-bash.sh` + `validate-pr.sh`: refuse
     dangerous commands; refuse commits to main or to merged branches.
   - `PostToolUse(Write|Edit)` → `post-edit.sh`: auto-format the touched
     file per policy.
   - `Stop` → `format-changed.sh` + `verify-quality.sh`: the session may
     not end while `verify.sh` is red. The agent gets the failure list
     and keeps working. This turns "the tasks say run the tests" from a
     suggestion into an invariant — the property that matters for long,
     semi-attended `/speckit.implement` runs.

2. **The git boundary** — when work becomes history. `pre-commit` blocks
   main commits and runs the same verify entrypoint; `commit-msg`
   enforces conventional commits and strips AI-isms.

3. **The CI boundary** — when work leaves the machine. The projected
   pipeline job runs `verify.sh --boundary ci`. Because it is the same
   script and the same policy, CI is a backstop, never a surprise.

## One entrypoint

`verify.sh --boundary agent|git|ci [--json] [--dry-run]`

Dispatch follows the policy's `verify-quality.orchestrator`:

- `none` — per-tool walk (prettier / markdownlint / shellcheck) driven by
  the policy's include/exclude globs via `lib/formatter-dispatch.sh`.
- `task` — `task lint` (error class) and `task test` (warning class),
  the fixed Taskfile convention.
- `custom` — a policy-supplied command; exit code mapped through the
  hook's severity.

Exit codes: `0` green, `1` internal error, `2` gate failure. `--json`
emits a single machine-readable object for workflow steps and CI.

## Evidence, canaries, and verified parity

Three separate silent-no-op enforcement bugs in this project's own history
taught one lesson: an enforcement layer must prove it is still enforcing.

**Attestation records.** Every `verify.sh` run appends one compact JSON
line to `.specify/gates/attestations.jsonl` and embeds the same object in
`--json`: schema version, timestamp, boundary, the SHA-256 of the policy
file, and one entry per gate — resolved binary, detected version, lockfile
pin, candidate vs checked file counts, result, duration. The log is capped
(`attestation.max_records`, default 200) via append plus atomic rewrite,
is gitignored by default, and never contains file contents. Evidence loss
cannot change a gate outcome: a write failure is a stderr warning, never a
result. `doctor` reads the latest record and fails on the no-op signature —
`result=pass` with `candidates > 0` and `checked = 0` — because no
legitimate run looks like that.

**Canaries.** `canary.sh` (projected next to `verify.sh`) plants known
violations in `mktemp` sandboxes and requires the real entrypoints to
reject them: the format and shell probes run through `verify.sh` itself,
the hook probes pipe crafted tool-call JSON through the projected hooks,
and the secret probe stages an AWS-key-shaped string in a sandbox git repo
with the pre-commit hook installed. The suite copies the runtime from the
projected directory, so a broken _projected_ gate — not just a broken
source tree — is what gets caught. Probes never read or write user project
files. An accepted probe fails the suite naming the gate; CI runs the
suite on every build.

**Pins-based parity.** The parity property used to be an argument ("same
script, same policy"); now it is checked. A synthetic `parity` gate inside
`verify.sh` compares every tool's resolved version against the project's
lockfile pin, and the record's policy hash captures policy identity — so
agent, git, and CI runs are proven equivalent transitively. The lockfile
is the shared source of truth; no attestation has to travel between
boundaries. Drift fails the run by default (`attestation.parity: error`);
tools with no pin source are attested but exempt.

## Spec conformance: acceptance criteria as executable gates

The tool gates hold code to linters; the `spec` gate holds a feature to
its own specification. The pipeline runs inside `verify.sh` on every run,
after the tool gates and before `parity`:

1. **Discover** — direct children of `specs/` containing a `spec.md`, in
   lexicographic order, minus `spec.exclude` globs. No `specs/` directory
   means zero features and a trivial pass.
2. **Parse** — an awk fence state machine reads each feature's `tasks.md`:
   ` ```accept ` fences become criteria (commands, optional
   `# verifies:` label, owning task), checkbox counts are taken
   fence-aware so a `- [ ]` inside a code sample never counts. Malformed
   shapes — unterminated fence, command-less block, block with no
   preceding task — fail the gate at `spec.severity` naming
   `tasks.md:<line>`. Parsing is fail-closed by design: a criterion the
   gate cannot read is a red run, not a skipped check.
3. **Execute** — for features whose `spec.md` says `**Status**: Complete`
   (and for any feature named via `--accept`), blocks run serially from
   the repo root with output captured (shown only on failure), a
   per-block watchdog (`spec.timeout_s`, default 30s), and
   `git status --porcelain` snapshots around each block — a block that
   mutates the working tree fails its criterion, and nothing is ever
   auto-reverted.
4. **Enforce** — a Complete feature fails the `spec` gate on any
   unchecked task or failing block, naming the feature, the task or
   criterion, and the cause. Incomplete features are informational
   (`spec: <feature> — N criteria parsed, not enforced`); a Complete
   feature with zero blocks is flagged as having nothing executable to
   hold it to, but does not block.

**Recursion guard.** An accept block that invokes `verify.sh` (this
repository's own blocks do) would re-enter the spec gate and recurse.
Blocks execute with `GATES_SPEC_EXEC=1` exported, and `verify.sh` skips
the spec gate entirely when it is set. Consumers that must probe the spec
gate from inside a block — the canary suite, the test suites — clear the
sentinel explicitly for their sandboxed runs.

**Evidence and self-test.** The attestation record gains a `spec` gate
entry (`candidates` = features, `checked` = blocks executed) and a
top-level `spec` object with per-run counts and per-feature outcomes
(`enforced-pass | enforced-fail | informational | no-criteria`). A `spec`
canary projects a sandbox feature marked Complete with a `false` accept
block and requires the sandboxed gate to reject it — stubbing the block
runner to a no-op fails the canary suite naming the spec gate. `doctor`
reports what the gate sees (features, blocks, complete count), fails on
parse errors, and nudges when every task is checked but the `Complete`
flip is missing.

## Policy as a versioned contract

The tool gates hold code to the policy; the `contract` gate holds the
policy itself to an organization's baseline. A repo opts in by declaring
`extends` (source + version) in `policy.json`, which turns that file into
an **overlay** on a versioned upstream document:

1. **Sync (the only network moment).** `contract.sh sync` fetches the
   declared version (shallow-by-tag, full-clone fallback for commit ids;
   branch names refused — a moving pin is not a pin), validates it against
   the policy schema, refuses chained baselines, and writes three
   committed artifacts: the canonicalized snapshot (`baseline.json`), the
   pin (`baseline.lock.json`: source, version, SHA-256 digest), and the
   materialized **effective policy** (`policy.effective.json`) — a
   deterministic recursive merge where the overlay wins and arrays replace
   wholesale.
2. **Enforce.** Every boundary reads the effective policy through the
   same resolver; `GATES_POLICY_FILE` keeps absolute precedence for
   tests. The attestation's `policy_sha256` hashes what was actually
   enforced.
3. **Prove (offline, every run).** The synthetic `contract` gate runs
   before the tool gates — policy integrity precedes policy enforcement —
   and proves four invariants from local files alone: artifacts present,
   snapshot matches the pinned digest, declaration matches the pin, and
   the effective policy matches byte-for-byte recomputation. Any
   violation fails closed naming the drifted artifact and the repair
   command.

**Transparent deviation.** Overlays may override anything, including
weakening baseline rules — but never silently. Overrides on fields with a
defined order (enabled `true→false`, severity along
`error > warning > off`, narrowed `include`, widened `exclude`) are
classified `weakened`; other overrides are `changed`; strengthenings and
additions are ordinary overlay behavior. The inventory is recomputed live
from snapshot + overlay (it cannot go stale), printed informationally —
never affecting the exit code — counted in the attestation `contract`
object, and reused verbatim by `propose`.

**Reviewable drift, both directions.** `sync --update [version]` moves
the pin to an explicit version or the highest tag (an awk numeric
comparator — no `sort -V` on the BSD floor), building the change on a
`gates/baseline-<v>` branch in a temporary worktree so the checkout keeps
enforcing the old pin until the branch merges. `propose` applies the
deviating paths onto the baseline document in a temp clone and delivers
it upstream as a branch/PR (or a patch under `.specify/gates/proposals/`
when `gh` cannot), carrying origin, pinned version, per-deviation
classification, and a required rationale.

**Evidence and self-test.** Attestations gain a `contract` GateEntry and
a top-level `contract` object (source, version, digests, deviation
counts). A `contract` canary syncs a sandbox against a fixture baseline
inside the sandbox, tampers the effective policy, and requires the
sandboxed gate to reject it. `doctor` reports the full contract state
from local information and fails on exactly the invariants the gate
blocks on. Repos without `extends` see none of this machinery.

## Constitution as an enforceable contract

A constitution is a set of claims about how a project behaves. Left as prose,
those claims drift from the enforcement that is supposed to back them — the
document says commits to `main` are refused while the git boundary quietly
allows them. Feature 004 binds each principle to the boundary that proves it.

**Elicit → annotate.** `/speckit.gates.constitution` interviews the project
into a profile (type + postures), then filters a bundled corpus of
provenance-carrying fragments into a candidate menu (`constitution.sh
fragments`, mandatory tier first, project-type-filtered). Each principle the
user keeps is materialized by `constitution.sh draft` into a byte-deterministic
document carrying one enforcement marker per principle:

```text
<!-- gates:enforce surface=git-hook ref=pre-commit -->
```

The marker is an HTML comment (invisible when rendered, surviving prettier and
the core command's fill/version pass) bound by position to the principle
directly above it. The grammar is fixed: a `surface` from
`policy | agent-hook | git-hook | ci | accept | scanner | prose`, a `ref`
required for all but `prose`, and an optional `expect` for policy surfaces. A
malformed marker is fail-closed — `check` and `doctor` fail naming
`constitution.md:<line>`, because an unreadable claim is worse than no claim.

**Align.** `constitution.sh align` evaluates, per annotated principle, whether
its surface is actually wired — all from local files, no network: a `policy`
key present in the effective policy (and equal to `expect`); an `agent-hook`
present, executable, and referenced in `settings.json`; a `git-hook` installed,
executable, and delegating to the runtime; a `ci` check named in a workflow;
an `accept` block that parses and verifies the named criterion; a `scanner`
rule in the tool's config. Each principle is `active`, `missing` (with a
concrete proposed change), or `pending-boundary` (the whole boundary is not
projected yet). Proposed policy changes target the **overlay**, so with a live
003 contract they flow through `sync` into the effective policy like any other
deviation. `align` never writes; applying is the session's job, change by
change, with approval.

**Prove.** `constitution.sh check` and the `doctor` constitution section report
one line per principle (`enforced | gap | prose-only`) on every run and exit
non-zero on any gap or malformed marker at fixed severity. A constitution with
no markers gets one informational nudge and never fails (FR-013); `prose`
principles are listed and never checked. The corpus adopts the
[spec-kit-charter](https://github.com/Fyloss/spec-kit-charter) registry layout
(`manifest.yml` + `fragments/<category>/<name>.md`), so charter consumes each
fragment's body while spec-gates consumes its frontmatter — one registry,
two consumers, no converter.

## Why projection, not symlinks or plugin-resident hooks

The runtime is copied into `.specify/gates/` and `.claude/hooks/gates/`.
Three reasons: enforcement must survive the extension being removed;
collaborators who clone the repo get enforcement without installing
anything; and CI can run the entrypoint from the checkout with no
network access. The cost — projected copies can drift from the extension
version — is exactly what `/speckit.gates.doctor` and
`/speckit.gates.upgrade` exist to manage, via `.runtime-version`.

## Threat model honesty

The agent boundary raises the cost of noncompliance; it does not make
noncompliance impossible (an agent with unrestricted bash can, in
principle, edit hook wiring — which is why settings.json and the hooks
themselves are on the protected-files list, and why the git and CI
boundaries exist). Defense in depth is the point of the three-boundary
design: the boundaries an agent cannot rewrite (CI, server-side branch
protection) backstop the ones it theoretically could.

## Spec Kit compatibility

The extension mechanics spec-gates relies on — the `extension.yml`
manifest (schema 1.0), `specify extension add --from <url>`, the
`after_implement` lifecycle hook, and the workflow-engine `gate`/`shell`
steps — were verified against Spec Kit **v0.12.4**. That API still ships
alongside an `RFC-EXTENSION-SYSTEM.md` and an "experimental" label
upstream, so treat it as an evolving contract: pin `requires.speckit_version`
(currently `>=0.12.0`), and expect `/speckit.gates.doctor` to grow a
Spec-Kit-version compatibility check as the schema settles.

Two upstream facts shape how spec-gates positions itself. First, Spec
Kit's own `gate` steps and lifecycle hooks are **advisory and
human-gated** — a gate blocks only inside `specify workflow run` and
merely _pauses_ (does not fail) in CI or any non-interactive context.
Second, its lifecycle hooks are not git hooks, and nothing upstream
projects git or CI enforcement into your repository. spec-gates exists to
bind those advisory checkpoints to boundaries that actually fail closed —
a rejected tool call, a blocked commit, a red build.
