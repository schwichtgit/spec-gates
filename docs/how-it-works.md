# How spec-gates works

spec-gates turns a project's quality rules into checks that fail closed
wherever code can change: while an agent works, when work is committed, and
in CI. One policy file (`.specify/gates/policy.json`) drives all three, one
entrypoint (`verify.sh`) runs the quality gate at each, and the runtime is
copied into the repository so it works for every clone and offline in CI.

```text
 agent edits ──► agent hooks ─┐
 git commit  ──► git hooks   ─┼──► verify.sh --boundary <b>  ◄── policy.json
 pull request ─► CI pipeline ─┘        │
                                       └──► attestation record (evidence)
```

The sections below follow that path: the three boundaries, the shared
entrypoint, the evidence that proves enforcement still works, the spec,
policy and constitution contracts, and how the runtime gets into a project
and stays current.

## The three-boundary model

Quality rules only matter if they are enforced wherever code can change.
An agentic workflow has exactly three such places.

### 1. The agent boundary

While the agent is working. Claude Code exposes lifecycle hooks, and
spec-gates uses four of them:

- `PreToolUse(Write|Edit)` → `protect-files.sh`: refuses edits to `.env`
  files, private keys and certificates, exact credential file names
  (`credentials.json`, `.netrc`, cloud service-account files), sensitive
  directories, lock files, the project's own rules in
  `.specify/gates/hooks.local.d/`, and every `protected_files.extra` entry
  (by default the constitution and `policy.json`). It resolves `.`, `..`
  and `//` in the path first and matches ignoring case, since macOS
  filesystems are case-insensitive by default.
- `PreToolUse(Bash)` → `validate-bash.sh`: refuses destructive commands
  (`rm` of root, home or a path outside the temp directories, force push,
  hard reset, `chmod 777`, piping a download into a shell, …). With
  `git.block_bulk_staging` it also refuses `git add -A`, `.`, `:/` and
  directory arguments. `validate-pr.sh`: checks the title and body of
  `gh pr create|edit` and `glab mr create|update` with the commit-message
  rules.
- `PostToolUse(Write|Edit)` → `post-edit.sh`: formats the touched file per
  policy.
- `Stop` → `format-changed.sh` + `verify-quality.sh`: the session may not
  end while `verify.sh` is red. The agent gets the failure list and keeps
  working. This turns "the tasks say run the tests" from a suggestion into
  an invariant, the property that matters for long, semi-attended
  `/speckit.implement` runs.

Every refusal says why and what to do instead, so the agent is redirected
rather than stopped cold.

**Block, ask, allow.** The file and command hooks block on a rule match,
ask the human when they cannot judge, and allow everything else. "Ask" is
the PreToolUse `permissionDecision: ask` answer, which prompts in every
permission mode. The hooks ask when a file name merely contains a word
such as `secret` or `token` (a test like `test_no_secret_leak.py` is not a
credential), when a Bash command appears to modify a protected path
(`rm`, `mv`, `sed -i`, a redirect, `tee`, `find -delete`, `git rm` naming
one, its parent directory, or a path relative to a `cd` into one; telling
a modification from a read by the command text is a heuristic, so it asks
rather than blocks), when a Bash command names a secret file the file hook
refuses (`cat .env`), when it bypasses the git hooks (`--no-verify`,
`git commit -n`, a `core.hooksPath` setting), and in any state they
cannot evaluate. A project rule in `hooks.local.d` runs before any of
these questions, so its refusal wins. They never
silently allow. Without jq, or for input that is not valid JSON, they read
the field in a raw mode that keeps every built-in block rule and still
checks `policy.json`, the constitution and the project's rules; an
internal error, an undecodable or missing value, or a
`protected_files.extra` it cannot read asks. Doctor keeps failing until jq
is installed.

**The Stop hook does not fail closed.** When `verify.sh` cannot run (no
jq, no git, no policy), `verify-quality.sh` lets the session end and says
why. That is deliberate: a missing tool must never lock the agent in a
session it cannot finish. The gate still holds where it can: `pre-commit`
refuses every commit while `verify.sh` cannot run, `pr-check.sh` and
`verify.sh` in CI exit with an error, and the Write/Edit and Bash hooks
keep working in raw mode. Only a red gate, never a missing tool, keeps the
session open.

**Project rules.** A project adds its own refusals as scripts in
`.specify/gates/hooks.local.d/<hook>/` for `protect-files`,
`validate-bash`, `validate-pr`, `pre-commit` and `commit-msg`. They run
after the shipped checks, so they can add a refusal but never remove one,
and upgrades never touch them. The agent cannot change them: Write/Edit
there is refused, a Bash change asks, and a commit that changes a rule
needs `Protected-Change` and `Approved-By` trailers like any protected
file.

### 2. The git boundary

When work becomes history. `pre-commit` blocks commits to `main`, scans
staged content for secrets and forbidden files, and runs the same verify
entrypoint. `commit-msg` enforces Conventional Commits and refuses
AI-isms, emoji, AI branding and `Co-Authored-By` trailers. The branding
list is policy (`git.ai_branding.terms`); a legitimate phrase that contains
a term, such as a product name a repository integrates, is allowed via
`git.ai_branding.allow_phrases` (matched literally, ignoring case, like the
terms).

Subjects git writes itself are exempt from the Conventional Commits rule
only: a merge commit (recognized by `MERGE_HEAD`, not by its subject) and
the `fixup!`, `squash!` and `amend!` subjects of `git commit --fixup` and
`--squash`. Every other message rule still applies to them. `git revert`
runs no commit hooks at all (git's own behavior), so a revert is checked
only at the CI boundary.

`.git/hooks` holds two copies of a small stub, not the hooks themselves.
`.git/hooks` is shared by every branch while the projected runtime is per
branch, so the stub runs the checked-out branch's
`.specify/gates/hooks/<name>`. The hook version always matches the
branch's runtime, and an upgrade needs no hook reinstall. A branch from
before gates was adopted has no runtime and is skipped: git tracks nothing
under `.specify/gates` there, in `HEAD` or in the index, and gitignored
leftovers such as `attestations.jsonl` do not count. A branch that tracks a
runtime but deleted its hooks is refused, so removing the hooks cannot
quietly turn enforcement off.

**Other hook managers.** When husky, lefthook or the pre-commit framework
owns the hooks, gates adds its entry to the file that tool reads, never to
the files it generates, which its next install would rewrite.
`project.sh --wire-manager` appends the entry only where the result is
certainly still valid; otherwise it prints it.

| Owner                                                     | Where the gates entry goes                        | Notes                                                                                                                                                                                                     |
| --------------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| husky (`core.hooksPath` under `.husky/`)                  | a line in `.husky/<hook>`                         | The script is created if missing; your existing lines stay first. A script with a top-level `exit` is left alone and the line printed, to go before the `exit`.                                           |
| lefthook                                                  | a `<hook>:` block in `lefthook.yml`               | Appended only when that hook has no block yet; otherwise printed for you to merge. Run `lefthook install` if git does not run lefthook for that hook yet.                                                 |
| pre-commit framework                                      | a `repo: local` item in `.pre-commit-config.yaml` | Appended only when `repos:` is the last top-level key and a block list (not `repos: []`); otherwise printed. Needs pre-commit 3.2+; run `pre-commit install --hook-type commit-msg` for the message hook. |
| anything else (another `core.hooksPath`, a custom script) | nothing is written                                | `project.sh` prints the call-through line to add, before any `exit`.                                                                                                                                      |

**Proving the hooks run.** A hook that exists is not a hook git runs. The
projected hooks answer `GATES_PROBE=1` with a marker before reading any
policy, so a probe works with every rule off and can only refuse. Doctor
and `project.sh` run the stub that way and fail when the marker does not
come back. A hook another tool owns is read, not run, because running it
would also run that tool's steps (husky's default `pre-commit` is
`npm test`, under `sh -e`); the check looks for the gates call-through in
the tool's file, on a line that can run (not commented out, not after a
top-level `exit`), and `--probe-git` runs the full chain on request. The
probe calls each hook as git does: only `commit-msg` gets a message file.
lefthook skips every `pre-commit` job while nothing is staged, so its
hook is called with `--force`, which it passes on to `lefthook run`.

**Protected files** get different treatment at the two local boundaries.
The agent may never edit them. At the git boundary a human is the
committer, so an approved amendment has a path through: every staged
protected path (added, modified, deleted, or renamed) must be declared in
the message's trailer block, with an approver:

```text
docs(constitution): ratify principle VI

Protected-Change: .specify/memory/constitution.md
Approved-By: Jane Reviewer
```

A staged protected path without a declaration, a declaration for a path
the commit does not change, or a missing `Approved-By` is refused. The
protected list is the union of the worktree policy and the committed one
at `HEAD`, plus the built-in `hooks.local.d/**` and the three
policy-contract artifacts (`baseline.json`, `baseline.lock.json`,
`policy.effective.json`), so a staged `policy.json`
cannot drop its own protection on the way in. A merge commit needs a
declaration only for a protected path that differs from every merged
parent, such as an edit made while resolving it; the merged commits carry
their own. `git commit --amend` cannot be told apart from a new commit
inside `commit-msg`, so an amend that drops a commit's trailers passes the
git boundary; `pr-check.sh` re-checks every commit in the range and
refuses it there unless the PR description declares the path. The trailer is an auditable
declaration, not a credential: real approval is enforced server-side by
CODEOWNERS plus branch protection. Setting `git.protected_change_trailer`
to `false` restores the unconditional refusal.

### 3. The CI boundary

When work leaves the machine. The projected pipeline job runs
`verify.sh --boundary ci` and the canary suite. Because it is the same
script and the same policy, CI is a backstop, never a surprise. The same
tool versions too: the job installs the lockfile's linters with `npm ci`
and the shellcheck pinned in `.tool-versions` with
`.specify/gates/install-shellcheck.sh`, which picks the release asset for
the runner's architecture and refuses one whose SHA-256 does not match
`.specify/gates/shellcheck.sha256`.

A third step, `pr-check.sh`, needs context only a pull or merge request
has, so it is deliberately not a `verify.sh` gate. It checks the PR/MR
title and description with the same message rules as `commit-msg`
(`lib/message.sh`, shared by all three boundaries); on a squash-merge
repository that text becomes the commit on the default branch, and no
local hook ever sees it. It also re-checks the protected-change rule for
every commit in the range, catching commits that never passed a local
hook. The rules for both checks, the text and the protected changes,
come from the policy at the base of the range, not the PR head, so a PR
cannot relax the rules it is judged by; `policy.json` and
`hooks.local.d/**` are checked even where the base sets
`git.protected_change_trailer` to `false`. A merge commit is checked for
the paths it changes against every parent, so merging the base into a PR
branch does not re-check the base's own changes. A declaration in the description covers every commit, since a
squash merge keeps the description and drops the commit trailers. GitHub
re-runs it when a PR is `edited`; GitLab starts no pipeline on an MR edit,
so a fresh pipeline is needed after one.

## One entrypoint

`verify.sh --boundary agent|git|ci [--json] [--dry-run]`

Dispatch follows the policy's `verify-quality.orchestrator`:

- `none`: per-tool walk (prettier, markdownlint, shellcheck) driven by the
  policy's include and exclude globs via `lib/formatter-dispatch.sh`. In a
  git work tree it skips untracked files git ignores (husky's generated
  `.husky/_/`, build output), since CI never sees them; a tracked file is
  checked even when an ignore pattern matches it.
- `task`: `task lint` (error class) and `task test` (warning class), the
  fixed Taskfile convention. `policy-infer` seeds it when a Taskfile
  declares top-level `lint` and `test` targets.
- `custom`: a policy-supplied command, its exit code mapped through the
  hook's severity.

Exit codes: `0` green, `1` internal error, `2` gate failure. `--json`
emits a single machine-readable object for workflow steps and CI.

**An invalid policy runs no gate.** Before any gate, `verify.sh` validates
the policy it enforces (`policy.json`, or `policy.effective.json` in a
contract repo) with the same check as `policy.sh validate`: malformed
JSON, a missing `hooks` object, an unknown field or a wrong value (a
severity of `Error`, a `spec.timeout_s` of `"abc"`, an
`attestation.max_records` of `0`) is refused with exit `1` and the
validator's errors, exactly like a missing policy. The policy reader treats
an unreadable field as its default, so without this check a typo would
silently drop gates while every boundary passed. The git and CI
boundaries fail on exit `1`. The Stop hook treats it as a setup error: it
prints the errors and lets the session stop, because an agent must never be
locked in by a broken configuration. The other agent hooks match:
`protect-files` asks before every edit (it cannot tell what the policy
protects), `post-edit` and `format-changed` format nothing, and doctor
reports the policy as `[MISSING]`; `project.sh` refuses to project under
it. A bad `--boundary` value, or `--boundary` or `--accept` without a
value, is a usage error (exit `1`).

## Evidence, canaries, and verified parity

Three separate silent-no-op enforcement bugs in this project's own history
taught one lesson: an enforcement layer must prove it is still enforcing.

**Attestation records.** Every `verify.sh` run appends one compact JSON
line to `.specify/gates/attestations.jsonl` and embeds the same object in
`--json`: schema version, timestamp, boundary, the SHA-256 of the policy
file, and one entry per gate (resolved binary, detected version, lockfile
pin, candidate and checked file counts, result, duration). The log is
capped (`attestation.max_records`, default 200) by append plus atomic
rewrite, is gitignored by default, and never contains file contents.
Evidence loss cannot change a gate outcome: a write failure is a stderr
warning, never a result. `doctor` reads the latest record and fails on the
no-op signature, `result=pass` with `candidates > 0` and `checked = 0`,
because no legitimate run looks like that.

**Canaries.** `canary.sh` (projected next to `verify.sh`) plants known
violations in `mktemp` sandboxes and requires the real entrypoints to
reject them, 15 probes in all:

- the format, markdown and shell probes run through `verify.sh` itself;
  when the tool is missing but the policy enables it, the probe fails as
  an enforcement gap, so a CI job that installed no linters is red;
- the hook probes pipe crafted tool calls through the projected hooks, the
  command and file probes once with jq and once without it;
- `bulk` and `local` prove the bulk-staging setting and that a project rule
  in `hooks.local.d` refuses its command while a plain command passes;
- the PR-hook probe needs a clean PR allowed as well as bad ones refused,
  because a hook that fails to parse also exits 2 and would otherwise
  count as blocking;
- the git probes commit in sandbox repositories with the projected hooks
  installed: a key-shaped string and a token assignment (secret scan), a
  protected file without its trailer, and a message naming a branding term;
- `pr` runs `pr-check.sh` over a sandbox range with an undeclared protected
  change and over a description containing an AI-ism;
- `spec` and `contract` are described with their gates below.

Hooks run by path, as Claude Code runs them, so their shebang picks the
interpreter (bash 3.2 on macOS). The suite copies the runtime from the
projected directory, so a broken _projected_ gate, not just a broken source
tree, is what gets caught. Probes never read or write user project files.
An accepted probe fails the suite naming the gate; `project.sh` runs the
suite after every projection, and CI runs it on every build.

**Pins-based parity.** The parity property used to be an argument ("same
script, same policy"); now it is checked. A synthetic `parity` gate inside
`verify.sh` compares every tool's resolved version against the project's
lockfile pin, and the record's policy hash captures policy identity, so
agent, git and CI runs are proven equivalent transitively. The lockfile is
the shared source of truth; no attestation has to travel between
boundaries. Drift fails the run by default (`attestation.parity: error`);
tools with no pin source are attested but exempt.

## Spec conformance: acceptance criteria as executable gates

The tool gates hold code to linters; the `spec` gate holds a feature to
its own specification. It runs inside `verify.sh` on every run, after the
tool gates and before `parity`:

1. **Discover**: direct children of `specs/` containing a `spec.md`, in
   lexicographic order, minus `spec.exclude` globs. No `specs/` directory
   means zero features and a trivial pass.
2. **Parse**: an awk fence state machine reads each feature's `tasks.md`.
   ` ```accept ` fences become criteria (commands, optional `# verifies:`
   label, owning task), and checkbox counts are taken fence-aware so a
   `- [ ]` inside a code sample never counts. Malformed shapes (an
   unterminated fence, a command-less block, a block with no preceding
   task) fail the gate at `spec.severity` naming `tasks.md:<line>`. Parsing
   is fail-closed by design: a criterion the gate cannot read is a red run,
   not a skipped check.
3. **Execute**: for features whose `spec.md` says `**Status**: Complete`
   (and any feature named via `--accept`), blocks run serially from the
   repository root with output captured (shown only on failure), a
   per-block watchdog (`spec.timeout_s`, default 30s) that stops the
   block's whole process group, and working-tree snapshots around each
   block (`git status` plus a content hash of every dirty or untracked
   file). A block that mutates the working tree, including a write to a
   file that was already modified, fails its criterion, and nothing is
   ever auto-reverted. Outside a git work tree there is nothing to check
   against, so blocks fail closed.
4. **Enforce**: a Complete feature fails the `spec` gate on any unchecked
   task or failing block, naming the feature, the task or criterion, and
   the cause. Incomplete features are informational
   (`spec: <feature> -- N criteria parsed, not enforced`); a Complete
   feature with zero blocks is flagged as having nothing executable to hold
   it to, but does not block.

**Recursion guard.** An accept block that invokes `verify.sh` (this
repository's own blocks do) would re-enter the spec gate and recurse.
Blocks execute with `GATES_SPEC_EXEC=1` exported, and `verify.sh` skips the
spec gate entirely when it is set. Consumers that must probe the spec gate
from inside a block (the canary suite, the test suites) clear the sentinel
explicitly for their sandboxed runs.

**Evidence and self-test.** The attestation record gains a `spec` gate
entry (`candidates` = features, `checked` = blocks executed) and a
top-level `spec` object with per-run counts and per-feature outcomes
(`enforced-pass | enforced-fail | informational | no-criteria`). A `spec`
canary projects a sandbox feature marked Complete with a `false` accept
block and requires the sandboxed gate to reject it: stubbing the block
runner to a no-op fails the canary suite naming the spec gate. `doctor`
reports what the gate sees (features, blocks, complete count), fails on
parse errors, and nudges when every task is checked but the `Complete`
flip is missing.

## Policy as a versioned contract

The tool gates hold code to the policy; the `contract` gate holds the
policy itself to an organization's baseline. A repository opts in by
declaring `extends` (source and version) in `policy.json`, which turns that
file into an **overlay** on a versioned upstream document:

1. **Sync (the only network moment).** `contract.sh sync` fetches the
   declared version (shallow by tag, with a full-clone fallback for commit
   ids; branch names are refused, since a moving pin is not a pin),
   validates it against the policy schema, refuses chained baselines, and
   writes three committed artifacts: the canonicalized snapshot
   (`baseline.json`), the pin (`baseline.lock.json`: source, version,
   SHA-256 digest), and the materialized **effective policy**
   (`policy.effective.json`), a deterministic recursive merge where the
   overlay wins and arrays replace wholesale.
2. **Enforce.** Every boundary reads the effective policy through the same
   resolver; `GATES_POLICY_FILE` keeps absolute precedence for tests. The
   attestation's `policy_sha256` hashes what was actually enforced.
3. **Prove (offline, every run).** The synthetic `contract` gate runs
   before the tool gates (policy integrity precedes policy enforcement) and
   proves four invariants from local files alone: artifacts present,
   snapshot matching the pinned digest, declaration matching the pin, and
   the effective policy matching a byte-for-byte recomputation. Any
   violation fails closed, naming the drifted artifact and the repair
   command.

**Transparent deviation.** Overlays may override anything, including
weakening baseline rules, but never silently. Overrides on fields with a
defined order (enabled `true→false`, severity along `error > warning >
off`, narrowed `include`, widened `exclude`) are classified `weakened`;
other overrides are `changed`; strengthenings and additions are ordinary
overlay behavior. The inventory is recomputed live from snapshot and
overlay (it cannot go stale), printed informationally without affecting
the exit code, counted in the attestation `contract` object, and reused
verbatim by `propose`.

**Reviewable drift, both directions.** `sync --update [version]` moves the
pin to an explicit version or the highest tag (an awk numeric comparator,
since BSD has no `sort -V`), building the change on a
`gates/baseline-<v>` branch in a temporary worktree so the checkout keeps
enforcing the old pin until the branch merges. `propose` applies the
deviating paths onto the baseline document in a temporary clone and
delivers it upstream as a branch and PR (or a patch under
`.specify/gates/proposals/` when `gh` cannot), carrying the origin, the
pinned version, per-deviation classification, and a required rationale.

**Evidence and self-test.** Attestations gain a `contract` gate entry and a
top-level `contract` object (source, version, digests, deviation counts). A
`contract` canary syncs a sandbox against a fixture baseline inside the
sandbox, tampers the effective policy, and requires the sandboxed gate to
reject it. `doctor` reports the full contract state from local information
and fails on exactly the invariants the gate blocks on. Repositories
without `extends` see none of this machinery.

## Constitution as an enforceable contract

A constitution is a set of claims about how a project behaves. Left as
prose, those claims drift from the enforcement that is supposed to back
them: the document says commits to `main` are refused while the git
boundary quietly allows them. Feature 004 binds each principle to the
boundary that proves it.

**Elicit, then annotate.** `/speckit.gates.constitution` interviews the
project into a profile (type and postures), then filters a bundled corpus
of provenance-carrying fragments into a candidate menu (`constitution.sh
fragments`, mandatory tier first, filtered by project type). Each principle
the user keeps is materialized by `constitution.sh draft` into a
byte-deterministic document carrying one enforcement marker per principle:

```text
<!-- gates:enforce surface=git-hook ref=pre-commit -->
```

The marker is an HTML comment (invisible when rendered, surviving prettier
and the core command's fill and version pass) bound by position to the
principle heading above it. Principles are the `###` headings under
`## Core Principles`; sub-headings in other sections (Additional
Constraints, Governance) are prose. The grammar is fixed: a `surface` from
`policy | agent-hook | git-hook | ci | accept | scanner | prose`, a `ref`
required for all but `prose`, and an optional `expect` for policy surfaces.
A malformed marker, or one outside Core Principles, is fail-closed: `check`
and `doctor` fail naming `constitution.md:<line>`, because an unreadable or
unchecked claim is worse than no claim.

**Align.** `constitution.sh align` evaluates, per annotated principle,
whether its surface is actually wired, all from local files with no
network: a `policy` key present in the effective policy (and equal to
`expect`), the ref read as a full dotted path (`hooks.markdownlint.severity`;
a ref not starting with a top-level section such as `git` or `attestation`
is short for `hooks.<ref>`); an `agent-hook` present, executable and
referenced in `settings.json`; a `git-hook` installed, executable and
delegating to the runtime; a `ci` pipeline with a live `verify.sh
--boundary ci` step that also runs the named template step (`gates`,
`canary`, `pr`) or, for any other ref, names it, where comments and
GitHub steps under `if: false` do not count; an `accept` block that parses
and verifies the named criterion; a `scanner` rule in the tool's config.
Each principle is `active`, `missing` (with a concrete proposed change), or
`pending-boundary` (the whole boundary is not projected yet). Proposed
policy changes target the **overlay**, so with a live contract they flow
through `sync` into the effective policy like any other deviation. `align`
never writes; applying is the session's job, change by change, with
approval.

**Prove.** `constitution.sh check` and the `doctor` constitution section
report one line per principle (`enforced | gap | prose-only`) on every run
and exit non-zero on any gap or malformed marker, at fixed severity. A
constitution with no markers gets one informational nudge and never fails;
`prose` principles are listed and never checked. The corpus adopts the
[spec-kit-charter](https://github.com/Fyloss/spec-kit-charter) registry
layout (`manifest.yml` + `fragments/<category>/<name>.md`), so charter
consumes each fragment's body while spec-gates consumes its frontmatter:
one registry, two consumers, no converter.

## Projection and upgrades

### Why projection, not symlinks or plugin-resident hooks

The runtime is copied into `.specify/gates/` and `.claude/hooks/gates/`.
Three reasons: enforcement must survive the extension being removed;
collaborators who clone the repository get enforcement without installing
anything; and CI can run the entrypoint from the checkout with no network
access. The cost is that projected copies can drift from the extension
version or be edited locally, which is what the rest of this section
manages.

### One reviewable step

`.specify/extensions/gates/runtime/project.sh` does the whole projection in
one invocation: it copies the runtime, sets execute bits (including on the
installed extension's git hooks, which Spec Kit's zip extraction leaves
non-executable), merges the agent hooks into `.claude/settings.json`
append-only, installs or wires the git hooks, writes the manifest, and
proves the result with the canary suite and the git probe. `--dry-run`
shows the plan first, and a second run changes nothing. One command means
one approval, where a permission classifier would refuse dozens of
individual file writes. It never writes `policy.json`; when a release adds
a policy setting (marked `x-since` in the schema), `project.sh` lists it
once, on the first upgrade that ships it, for the maintainer to adopt in a
reviewed change.

### Local edits survive upgrades

`project.sh` records a hash of every projected file in
`.specify/gates/.projected.sha256`, with the version that wrote it. On the
next upgrade, a file that no longer matches its hash is a local edit: it is
reported (exit 3) and nothing is written until the maintainer keeps it,
which holds it in `.specify/gates/.upgrade-holds` from then on, or takes
the new version (`--take-upstream`, which also releases an existing hold).
Doctor flags a held file whose upstream copy changed since the hold, so a
hold never silently pins an old version of a hook. A project projected by 0.3.x has no manifest; there
`project.sh` compares each file against the hashes of what the 0.3.x
releases shipped (`lib/known-releases.sha256`), so only real edits stop
the upgrade. Doctor reports the same state between upgrades: local edits
that are not held, holds that went stale (the held file now equals the
installed copy), and CI pipelines missing a template step (the gates,
canary and PR-check steps, recognized by command on GitHub, GitLab and
Jenkins; `ci:<step>` in the holds file records a deliberate omission).
Comments (`#` in YAML, `//` and `/* */` in a Jenkinsfile) and GitHub steps
or jobs under `if: false` are not steps. A `ci:<step>` hold for a step the
pipeline runs is stale and fails; one naming no template step gets a
recommendation to remove it.

### Interrupted and unusual installs

Spec Kit's `extension remove` and `extension add` are two commands, not a
transaction. If the `add` fails, the projected copy of `project.sh`
(`.specify/gates/project.sh --check`) reports the half-done upgrade and the
command that finishes it, and doctor fails until it is done. A
`specify extension add --dev` install renders the gates skills as symlinks
that exist only on the author's machine; doctor fails on symlinked,
dangling or missing skills. `doctor --installed-only`, run from the
installed copy, checks an install with nothing projected yet.

### Toolchain parity

Parity has an analogous requirement on the toolchain itself: a linter's
findings depend on its version, so "the same policy at every boundary" is
only true if the same tool versions run at every boundary. Node linters
are pinned by `package-lock.json`. Tools npm cannot pin are declared in
`.tool-versions` (asdf format), currently shellcheck, where the gap is not
theoretical: Ubuntu's apt ships 0.9.0, which reports SC2015 findings that
0.11.0 does not, so an unpinned CI turns a green local run red for reasons
no diff explains. The parity gate reads both sources, so drift at any
boundary fails the run naming the tool, the resolved version and the pin,
instead of surfacing as mysteriously different lint output.

### Out of the project's lint scope

Projection has a second cost that is easy to miss: our files now live in
someone else's repository, so their repo-wide tooling reaches them. A plain
`prettier --check .` or `markdownlint-cli2 "**/*.md"` lints the projected
runtime and the installed extension against the consumer's style, and any
fix they apply is erased by the next upgrade. No shipped formatting solves
this, because every style choice fails somebody's config. Vendored content
belongs out of lint scope, the same way `node_modules` does. So the
extension ships a nested markdownlint config at its own root
(nearest-config resolution keeps our docs quiet under a default sweep),
and in a repository that uses prettier `project.sh` reports the missing
`.prettierignore` entries for `.specify/gates/`, `.specify/extensions/`
and `.claude/hooks/gates/`, appending them only with `--add-lint-ignores`,
since that file is the consumer's. A packaging test asserts the shipped
tree stays clean under default tooling.

## Threat model honesty

The agent boundary raises the cost of noncompliance; it does not make
noncompliance impossible. An agent with unrestricted Bash can, in
principle, rewrite its own hook wiring: `.claude/settings.json`, the
projected hooks in `.claude/hooks/gates/` and the runtime in
`.specify/gates/` are not protected by default. Add them to
`protected_files.extra` to have Write/Edit refused and Bash changes asked
about, as `policy.json`, the constitution and the project's own rules are.
The Bash check is itself a heuristic over command text, which is why it
asks rather than claims to block.

Defense in depth is the point of the three-boundary design. Whatever an
agent changes locally still has to pass the git hooks (whose own changes
need a reviewed trailer when protected) and then CI and server-side branch
protection, which run in an environment the agent cannot rewrite. The
boundaries an agent cannot touch backstop the ones it theoretically could.

## Spec Kit compatibility

spec-gates relies on the Spec Kit extension mechanics: the `extension.yml`
manifest (schema 1.0), `specify extension add --from <url>`, the
`after_implement` and `before_constitution` lifecycle hooks, and the
workflow-engine `gate` and `shell` steps. They were first verified against
Spec Kit v0.12.4; the install, upgrade and `--dev` behaviors this
release depends on were rechecked against 1.0.13. `requires.speckit_version`
stays at `>=0.12.0`. Two installer gaps shape the upgrade path: `add --from`
verifies neither checksum nor signature (the README's upgrade steps do both
explicitly, and diff the installed files against the verified zip), and
zip extraction keeps the execute bit only on `*.sh` files (`project.sh`
restores it).

Two upstream facts shape how spec-gates positions itself. First, Spec
Kit's own `gate` steps and lifecycle hooks are **advisory and
human-gated**: a gate blocks only inside `specify workflow run` and merely
_pauses_ (does not fail) in CI or any non-interactive context. Second, its
lifecycle hooks are not git hooks, and nothing upstream projects git or CI
enforcement into a repository. spec-gates exists to bind those advisory
checkpoints to boundaries that actually fail closed: a rejected tool call,
a blocked commit, a red build.
