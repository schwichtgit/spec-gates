# spec-gates

![spec-gates — a caliper holding a growing project to its spec](docs/assets/spec-gates.png)

[![CI](https://github.com/schwichtgit/spec-gates/actions/workflows/ci.yml/badge.svg)](https://github.com/schwichtgit/spec-gates/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Deterministic quality enforcement for [Spec Kit](https://github.com/github/spec-kit) projects.**

> **Status:** early and evolving. Verified against Spec Kit **v0.12.4**; the
> upstream extension API is still marked experimental, so pin
> `requires.speckit_version` and expect some churn.

Spec Kit is a guidance layer: templates, prompts, and checklists _ask_ the
agent to comply. spec-gates is the enforcement layer underneath it: hooks
and pipelines that _force_ compliance — the bash call is rejected, the
protected file is refused, a stop with failing checks is sent back to the agent.

Extracted from
[claude-project-foundation](https://github.com/schwichtgit/claude-project-foundation)
(now EOL), whose spec-authoring half was superseded by Spec Kit and whose
enforcement half lives on here.

## One policy, three boundaries

```text
                    .specify/gates/policy.json
                               |
        +----------------------+----------------------+
        |                      |                      |
  AGENT BOUNDARY         GIT BOUNDARY            CI BOUNDARY
  Claude Code hooks      pre-commit /            GitHub Actions /
  PreToolUse: block      commit-msg:             GitLab CI /
    protected files,     block main commits,     Jenkins:
    dangerous bash       conventional commits,
  PostToolUse:           no AI-isms
    auto-format
  Stop: refuse to end            \                    /
    with failing checks           \                  /
        \                          \                /
         +------------->  .specify/gates/verify.sh  <-----------+
                          (identical at every boundary)
```

**The parity property:** if the agent boundary passed, the git boundary
passes; if the git boundary passed, CI passes. Every boundary runs the
same `verify.sh` with the same policy — `tests/test-parity.sh` asserts it:
identical results at every boundary, and no boundary re-implements the gate.
A fourth, server-side boundary (branch protection requiring the CI check) is
available via `/speckit.gates.ci github --protect`.

## Provable enforcement

Enforcement that can silently stop enforcing is worse than none — you
still believe you are covered. Three mechanisms make the gate
self-evidencing:

- **Attestations** — every `verify.sh` run appends one record to
  `.specify/gates/attestations.jsonl` (capped, gitignored) and embeds it
  in `--json`: the policy's SHA-256, and per gate the resolved binary,
  detected version, lockfile pin, candidate vs checked file counts,
  result, and duration. Evidence, never file contents.
- **Canaries** — `canary.sh` plants 15 known violations in disposable
  sandboxes (dirty and lint-failing files, dangerous tool calls with and
  without jq, staged secrets, undeclared protected changes, branding, a
  failing accept block, a tampered effective policy, and more) and requires
  the real gate or hook to reject each one. An accepted probe fails the
  suite naming the broken gate; CI runs it on every build. On demand:
  `bash .specify/gates/canary.sh` (or `doctor.sh --canary`). The full list
  is in [How it works](docs/how-it-works.md#evidence-canaries-and-verified-parity).
- **Verified parity** — a synthetic `parity` gate compares each tool's
  resolved version against its lockfile pin on every run, at every
  boundary. Drift fails the boundary with
  `parity -- prettier: resolved 3.5.3, pinned 3.9.4 (run npm ci)`;
  tune it with `attestation.parity` (`error | warning | off`). `doctor`
  additionally fails on the no-op signature: a gate that passed while
  checking zero of its candidate files.

The optional policy section, with its defaults:

```json
"attestation": { "enabled": true, "max_records": 200, "parity": "error" }
```

## Spec conformance

A spec's acceptance criteria are usually prose — checked by hand, if at
all. The `spec` gate makes them executable: fence a shell snippet as
` ```accept ` under any task in `specs/<feature>/tasks.md` and it becomes
a criterion the gate can run (exit 0 = the criterion holds):

````markdown
- [x] T042 Ship the exporter

  ```accept
  # verifies: SC-003
  bash tests/test-exporter.sh
  ```
````

The full grammar lives in
[`specs/002-spec-conformance-gate/contracts/accept-block.md`](specs/002-spec-conformance-gate/contracts/accept-block.md).
Malformed blocks (unterminated fence, no commands, no preceding task) fail
the gate naming `tasks.md:<line>` — an unreadable criterion is never
silently skipped.

Enforcement follows the feature's own completion claim, read from
`spec.md`:

- **In progress** (any `**Status**:` other than `Complete`) — blocks are
  parsed and reported on every run, executed only on demand:
  `verify.sh --accept <feature|all>` runs them informationally, never
  changing the exit code.
- **`**Status**: Complete`** — the claim is enforced. Any unchecked
  `- [ ]` task or failing accept block fails the run, naming the feature,
  the task or criterion, and the cause (exit code, `timeout after <N>s`,
  or a mutation — blocks are read-only by contract and never
  auto-reverted). The read-only check covers the working tree, git config,
  the git hooks, `.git/info/`, skip-worktree and assume-unchanged flags,
  linked worktrees, `HEAD` and refs, and gitignored files. A block that
  leaves a process running fails too, including one that left the
  block's process group or session; a process that both closed the
  inherited descriptor and dropped the block's environment marker is not
  seen, nor on macOS an Apple-signed binary that closed the descriptor,
  since `ps` cannot read its environment (see [how it works](docs/how-it-works.md)). Outside a git work tree
  blocks fail closed, since there is nothing to check mutations against.

Results land in the attestation record (a `spec` gate entry plus per-run
counts and per-feature outcomes), a `spec` canary proves the gate still
blocks, and `doctor` reports discovery — including a nudge when every
task is checked but the Status flip is missing. The optional policy
section, with its defaults:

```json
"spec": { "enabled": true, "severity": "error", "include": ["*"], "exclude": [], "timeout_s": 30, "snapshot_exclude": [] }
```

`snapshot_exclude` takes path globs of untracked or gitignored files the
read-only check skips, for a cache another process writes while blocks
run; `cache/` covers the directory and everything under it, and a pattern
that would match every path (`*`, `**`) is refused.

## Policy as a versioned contract

An organization runs one baseline policy across a fleet of repos by
declaring, in each repo's `policy.json`:

```json
"extends": { "source": "https://github.com/acme/policy-baseline", "version": "v2.3.0" }
```

`/speckit.gates.sync` fetches that version once, pins it (version +
SHA-256 digest), commits a snapshot, and materializes the **effective
policy** — baseline with the local file applied as an overlay — which is
what every boundary then enforces. Gate runs never touch the network: a
synthetic `contract` gate proves offline, on every run, that the snapshot
matches the pin and the effective policy matches recomputation. Editing
any artifact by hand blocks the next run naming what drifted.

Drift is reviewable in both directions:

- **Overlays may deviate — transparently.** The local `policy.json` is
  a partial policy: it may hold only `extends`, set just the fields a
  hook changes, or remove a baseline hook with `null`. A repo can weaken a
  baseline rule (disable, lower a severity, narrow its scope, turn off a
  `git` protection, remove a hook), but every weakening
  is a named, attested deviation: `contract: deviation (weakened):
hooks.shellcheck.severity: baseline "error" -> overlay "warning"`.
  Deviations never change the exit code; they change what the org can see.
- **Updates arrive as changes, not surprises.** `sync --update` moves the
  pin to a newer baseline version on its own `gates/baseline-<v>` branch
  with the classified enforcement delta in the commit body (weakened,
  strengthened and changed rules, added and removed hooks); enforcement
  follows only when it merges. The delta names paths and never quotes
  policy values: a list change reads `git.ai_branding.terms: 2 added,
1 removed`, a text value `value changed`, so a new branding term or a
  word the message rules forbid cannot make the repo refuse its own
  update. Should the message still trip those rules (a hook named after
  a branding term), it falls back to counts only. That branch moves
  `extends.version` in `policy.json` with the pin, so it passes its own
  gates, and its commit carries the `Protected-Change` trailers with
  you, the person running the update, as `Approved-By`: your git
  committer name, or the local part of your committer email when the
  message rules refuse the name, else a fixed
  `the committer of this commit`. If a hook refuses the commit, the
  branch is removed so a retry starts clean.
- **Deviations can go home.** `/speckit.gates.propose` packages the
  deviation inventory as a change request against the baseline source —
  origin, pinned version, classification, and your rationale included.

The three artifacts (`baseline.json`, `baseline.lock.json`,
`policy.effective.json`) are committed contract state (formats:
[`specs/003-policy-contract/contracts/artifact-layout.md`](specs/003-policy-contract/contracts/artifact-layout.md));
`policy.json` stays the only file you edit. The artifacts are built-in
protected files: only `sync` writes them, and the commit that adds a
sync needs a `Protected-Change: <path>` trailer for each artifact it
changes plus `Approved-By: <name>`. Repos without an `extends`
declaration are completely unaffected.

With `git.protected_change_trailer` set to `false`, `pre-commit`
refuses protected files outright. The commit that sets it to `false` is
still judged by `HEAD`'s policy, so it passes with its trailers; the
refusal starts with the next commit. One exception remains: the commit
`sync --update` makes. `pre-commit` lets it through only when, read
from the index, the branch is `gates/baseline-<v>` and the lock pins
`<v>`, nothing is staged but `policy.json` and the three artifacts,
`policy.json` differs from `HEAD` in `extends.version` alone, and the
staged files pass the contract checks (snapshot digest equals the pin,
declaration equals the lock, effective policy equals recomputation).
Anything else stays refused. The exception follows the shape of the
change, not who runs it: a hand-made commit of that exact shape passes
too, and no hook can prove offline that the snapshot is what the source
publishes. That proof is the review of the update branch, where
`pr-check.sh` still requires the `Protected-Change` trailers the update
commit carries.

## Constitution as an enforceable contract

A constitution states the principles a project holds itself to — but a
principle that says "we never commit to main" and a git boundary that lets
you are a lie the document tells. `/speckit.gates.constitution` runs a guided
session that closes that gap:

1. **Interview → profile.** A short interview (project type, postures) filters
   a bundled corpus of ~30 provenance-carrying principles so a docs project is
   never shown infra rules.
2. **Pick and annotate.** You accept, adapt, or decline candidates and add
   your own. Every principle you keep carries an explicit **surface** — the
   boundary that enforces it (`policy`, `agent-hook`, `git-hook`, `ci`,
   `accept`, `scanner`, or `prose` for the ones no gate can check). The
   session writes a byte-deterministic draft with one invisible
   `<!-- gates:enforce … -->` marker per principle, then hands off to the core
   `/speckit-constitution` command for versioning.
3. **Align.** `constitution.sh align` computes, per annotated principle,
   whether its surface is actually wired here (`active` / `missing` /
   `pending-boundary`) and proposes a concrete change for each gap — policy
   changes targeting the overlay so a live 003 contract picks them up. A
   `policy` ref is a dotted path (`hooks.markdownlint.severity`, or the
   short `markdownlint.severity`); a `ci` principle counts only when a
   pipeline runs `verify.sh --boundary ci` in a step doctor can prove runs
   and fails the pipeline, and runs the step its ref names. You apply them one at a time, with approval; declining leaves the repo
   byte-identical.
4. **Prove, permanently.** `doctor` and `constitution.sh check` report every
   principle's status on every run. An annotated-but-unwired principle, or a
   malformed marker, is a **gap** that fails at fixed severity — the same
   fail-closed doctrine the rest of the gate uses. This repo dogfoods it: all
   five of its own principles report enforced.

The corpus uses the [spec-kit-charter](https://github.com/Fyloss/spec-kit-charter)
registry layout, so charter reads each fragment's body while spec-gates reads
its enforcement frontmatter — one registry, two consumers.

## Requirements

- **jq** and **git**: the hooks, `verify.sh` and `pr-check.sh` require
  them; `verify.sh` and `pr-check.sh` refuse to run without either, so
  `pre-commit` refuses commits and the CI job fails. Without jq, the file
  and command hooks fall back to a raw mode that keeps every built-in
  block rule, still checks `policy.json`, the constitution and the
  project's rules, and asks you about anything it can't check; the PR
  hook refuses PR commands. The Stop hook is the one exception, on
  purpose: when `verify.sh` cannot run it lets the session end and says
  why, so a missing tool never locks the agent in. Until jq is installed,
  the quality gate holds at the git and CI boundaries only.
- **python3** with the `json` module: the PR hook parses commands with it
  and refuses every PR command without it. The message rules' emoji check
  needs python3 or perl. `doctor` fails when either is missing.
- **Standard POSIX tools** (`awk`, `sed`, `grep`, `cmp`, `sha256sum` or
  `shasum`): `project.sh` refuses to run without `cmp` and a SHA-256
  tool, the contract gate cannot verify its pin without a SHA-256 tool,
  and `doctor` fails when either is missing.
- **Node** with the linters your policy uses (default: **prettier**,
  **markdownlint-cli2**). Pin them in `package.json` so local and CI agree.
  A linter the policy enables but the host lacks does not block anything
  by itself: every boundary passes with that gate reported `[skipped]`.
  `doctor` and the canary suite fail on it, and the CI templates run the
  canary suite, so a CI job without the linter fails.
- **shellcheck** if you lint shell. Its findings change between releases
  (0.9.0 reports SC2015 where 0.11.0 does not), so declare the version in
  `.tool-versions` (`shellcheck 0.11.0`) and install that one everywhere —
  the parity gate reads it and fails any boundary that drifts. The CI
  templates install exactly that version, checksum-verified, with
  `bash .specify/gates/install-shellcheck.sh` (Linux and macOS, x86_64
  and aarch64); for a version spec-gates ships no checksums for, run it
  with `--update` and commit `.specify/gates/shellcheck.local.sha256`.
- **Claude Code** for the agent boundary. The git and CI boundaries are
  agent-agnostic.

## Install

```bash
specify extension add gates --from https://github.com/schwichtgit/spec-gates/releases/latest/download/gates.zip
```

That URL always resolves to the newest release. To pin a specific
version instead (recommended for fleets), use the versioned asset from
the [releases page](https://github.com/schwichtgit/spec-gates/releases),
e.g. `releases/download/vX.Y.Z/gates-X.Y.Z.zip`. Either way the URL must
point at a release **asset** (the zip holds a `gates/` directory with
`extension.yml` inside it). The repository's source archive does not
install, because the manifest lives in `extension/` inside this repo.
Don't install with `specify extension add --dev`: it is for developing
spec-gates itself. It renders the `/speckit.gates.*` skills as symlinks
into `.specify/extensions/gates/.specify-dev/`, which exists only on that
machine, so in any other clone or CI checkout the commands do not load.
`/speckit.gates.doctor` fails on such symlinks.
Spec Kit's community catalog is discovery-only (`install_allowed: false`),
so `--from <url>` is the install path even after `gates` is listed there;
catalog listing buys discoverability, not a bare `specify extension add gates`.

`specify extension add` registers the `/speckit.gates.*` commands at
install time, for the agent integration chosen at `specify init` (for
Claude Code, as skills in `.claude/skills/speckit-gates-*/`). Nothing is
enforced until the runtime is projected; until then the install is
dormant, and `bash .specify/extensions/gates/runtime/doctor.sh
--installed-only` checks it.

Then, in Claude Code:

```text
/speckit.gates.init        # infer policy, project runtime, wire hooks, self-test
/speckit.gates.ci github   # project the CI boundary (github | gitlab | jenkins)
```

Commit the adoption on a branch. Its first commit stages
`.specify/gates/policy.json`, a protected file, so end the message with
`Protected-Change: .specify/gates/policy.json` and `Approved-By: <name>`
(see [Commit and PR message rules](#commit-and-pr-message-rules)).

From that point the normal Spec Kit loop is unchanged —
`/speckit.specify → clarify → plan → tasks → implement` — but during
`implement` every edit is auto-formatted, protected files and dangerous
bash are refused with actionable messages, and a stop with red checks is
sent back to the agent with the failure list. After `implement`, the extension's `after_implement`
hook offers a gate run before you move to commit/PR.

## Upgrade

There is one upgrade path. It verifies the release before anything is
installed and ends with a single reviewable projection step.

```bash
V=X.Y.Z   # the release to install
U=https://github.com/schwichtgit/spec-gates/releases/download/v$V
D="$(mktemp -d)"   # downloads stay out of the project tree
cp -R .specify/gates "$D/gates-backup"   # 1. back up

# 2. Download and verify the release; stop if a check fails (no cosign on
#    this machine? see "No cosign" below).
(cd "$D" && curl -fsSLO "$U/gates-$V.zip" -O "$U/gates-$V.zip.sha256" -O "$U/gates-$V.zip.sigstore.json" -O "$U/SHA256SUMS" \
  && sha256sum -c "gates-$V.zip.sha256")   # behind Artifactory: sha256sum -c --ignore-missing SHA256SUMS
cosign verify-blob --bundle "$D/gates-$V.zip.sigstore.json" \
  --certificate-identity-regexp '^https://github.com/schwichtgit/spec-gates/.github/workflows/release.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com "$D/gates-$V.zip"

# 3. Swap the installed extension (policy.json stays).
specify extension remove gates --keep-config --force
specify extension add gates --from "$U/gates-$V.zip"

# 4. Confirm the installed files are the verified zip.
unzip -q "$D/gates-$V.zip" -d "$D/verified" && diff -r "$D/verified/gates" .specify/extensions/gates

# 5. Project: review the plan, then run it once.
bash .specify/extensions/gates/runtime/project.sh --dry-run
bash .specify/extensions/gates/runtime/project.sh
```

`specify extension add --from` checks neither the checksum nor the
signature, and it downloads the zip itself, so steps 2 and 4 are what tie
the installed files to a verified release. Step 3 is two commands, not
one transaction: if the `add` fails, the projected runtime keeps working,
and `bash .specify/gates/project.sh --check` prints the command that
finishes the upgrade.

**No cosign on this machine** (a locked-down workstation, say): the
checksum check is still required, and the signature can be checked
elsewhere. Run the `cosign verify-blob` command on any machine that has
cosign (a CI job or another workstation), note the zip's
`sha256sum` there, and on this machine confirm that
`sha256sum "$D/gates-$V.zip"` prints the same value. That gives the same
assurance as running cosign locally. Skipping the signature entirely is
a deliberate choice for the maintainer to make, never a default: the
`.sha256` file and `SHA256SUMS` come from the same release page as the
zip, so they prove the download arrived intact, not who published it.

`project.sh` never writes `.specify/gates/policy.json`. It records a hash
of every file it projects in `.specify/gates/.projected.sha256`, so a file
you changed locally is reported (exit 3) instead of overwritten: re-run
with `--keep-local <path>` (it is added to `.specify/gates/.upgrade-holds`
and left alone from then on) or `--take-upstream <path>`, which also
releases a hold. A deletion cannot be held: every projected file is run
by a hook, a gate, the canary suite or CI, and a missing agent hook exits
127, which Claude Code does not treat as a block. `--keep-local` on a
deleted file is refused, and a held file that is missing fails both
`project.sh` and doctor until `--take-upstream <path>` restores it. A project
projected by 0.3.x has no such record yet; there `project.sh` compares
against the hashes of what the 0.3.x releases shipped, so only real
edits stop it. It ends by running the canary suite and fails if any gate
no longer blocks. `/speckit.gates.doctor` reports the same state between
upgrades: local edits that are not held, stale holds, and CI pipelines
missing a template step (a `ci:<step>` line in `.upgrade-holds` records a
deliberate omission; one for a step the pipeline runs is stale and fails).
Only live steps count: commented-out steps, steps under `if: false`, a
step whose failure is ignored (`|| true`, `continue-on-error: true`), and
a job that never runs on a push or pull request do not. The gates step
must be proven: `bash .specify/gates/verify.sh --boundary ci` as the whole
command (or the last line of its script), on a push or pull request
trigger, without `GATES_SPEC_EXEC` or `GATES_POLICY_FILE`, outside Jenkins
`catchError`/`try`; a pipeline that calls `verify.sh` without such a step
fails and is told what to change (the full rules and the limits of a text
check are in [how-it-works](docs/how-it-works.md)).
`/speckit.gates.upgrade` walks through the same steps in Claude Code.

## Project rules that survive upgrades

Upgrades replace every projected file, so project-specific hardening goes
in `.specify/gates/hooks.local.d/<hook>/*.sh`, which projection, upgrades
and the manifest never touch. `<hook>` is `protect-files`,
`validate-bash`, `validate-pr`, `pre-commit` (which also runs for merge
commits), or `commit-msg`. Each rule
runs after the shipped checks, so it can add a refusal but never remove
one. It reads the tool call JSON on stdin (agent hooks) or gets the hook's
arguments (`commit-msg` gets the message file as `$1`). Exit 0 allows;
any other exit refuses, with the rule's stderr as the message. A rule that
cannot be read (including a dangling symlink) refuses, and so does one still
running after 10 seconds (`GATES_LOCAL_TIMEOUT`, a whole number above 0;
any other value refuses): it is stopped with every process in its process
group. A rule that exits but leaves a process running refuses too, and the
process is stopped; a child that leaves the group (`setsid`) is out of
reach.

The rules are the project's, not the agent's: the agent cannot write or
delete them (Write/Edit is refused, and a Bash command that appears to
modify them asks you first), and a commit that adds, changes or removes
one needs `Protected-Change: <path>` and `Approved-By: <name>` trailers,
checked again in CI by `pr-check.sh`. The same Bash check covers
`policy.json`, the constitution, the policy-contract artifacts and every
`protected_files.extra` entry. The Bash checks are best-effort heuristics: they
recognise common spellings, block on certainty and ask on uncertainty,
but cannot parse every shell form, so the git hooks and CI remain the
enforcement backstop.

```bash
# .specify/gates/hooks.local.d/validate-bash/10-no-vendor-edits.sh
if grep -q 'vendor/'; then echo "vendor/ is generated; run make vendor" >&2; exit 1; fi
```

Two settings in `.specify/gates/policy.json` cover the most common cases:

- `git.block_bulk_staging: true` refuses `git add -A` (also inside an
  option cluster such as `-vA`), `--all`, `--no-ignore-removal`,
  `--pathspec-from-file`, `.`, `:/` and other pathspec magic, globs
  (quoted or not), `"$PWD"`, `~` and directory arguments (also under
  `git -C <dir>`) at the agent boundary, so an untracked directory
  cannot be swept into a commit. `git stage`, `env git add`,
  `GIT_DIR=… git add` and `git --no-pager add` count too; an argument the
  check cannot resolve (`"$f"`) asks. Explicit files, `-p`, and the forms
  that stage only tracked changes (`git add -u`, `--renormalize`,
  `git commit -a`) stay allowed: they cannot sweep in an untracked file. The git boundary cannot tell how
  files were staged, so this is an agent-boundary rule.
- The file hook blocks only on strong evidence: `.env` files, keys and
  certificates (`*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`, …),
  exact credential file names (`credentials.json`, `.netrc`, `.pypirc`,
  cloud service-account files), sensitive directories, lock files, and
  `protected_files.extra`. A file whose name merely contains a word like
  `secret` or `token` (`test_no_secret_leak.py`) gets an "ask" instead,
  so you confirm the edit. So does the constitution: `/speckit-constitution`
  and `/speckit.gates.constitution` write it as one of their steps, and
  you approve that write once.

## Coexisting with other hook managers

When husky, lefthook or the pre-commit framework owns the git hooks,
gates adds its entry to that tool's own configuration, never to the files
the tool generates (the next install would silently drop it).
`project.sh` prints the entry; `--wire-manager` appends it where the result
is certainly still valid. Any other owner gets the call-through line to
add. Where each entry goes:
[How it works, "Other hook managers"](docs/how-it-works.md#the-three-boundary-model).

Doctor checks such hooks statically: it looks for the gates call-through in
the file the tool that runs the hook reads, and does not run the hook,
since that would run the tool's own steps too (husky's default is
`npm test`). The call-through counts only where that tool runs it for that
hook: under the hook's own key in lefthook, not skipped, and running while
nothing is staged; in a pre-commit framework item whose `stages:` include
the hook. A commented-out line, or one after a top-level `exit` or
`exec <command>`, does not count. A manager config that calls gates while
git runs no hook for it (its install command never ran) fails.
`doctor --probe-git` runs the full chain when you want proof; under
lefthook it runs only the gates job. A hook gates
installs itself (the stub) is always run with a probe signal, because only
gates code executes there.

## Commit and PR message rules

`commit-msg` and the PR checks (the agent's PR hook and `pr-check.sh` in
CI) apply the same rules, from `lib/message.sh`:

- A Conventional Commits subject, at most 72 characters
  (`git.conventional_commits`).
- No AI-isms and no self-referential phrasing (`git.forbid_ai_isms`), no
  emoji anywhere in the message, subject or body (comment lines and the
  `git commit -v` diff below the scissors line are not part of it).
- No AI branding: the terms in `git.ai_branding.terms` (default
  `Anthropic`, `GPT`, `OpenAI`, `Copilot`), and a standalone `Claude`.
  `Claude Code`, `CLAUDE.md`, `.claude/` paths and `claude-*`
  identifiers are allowed.
- No `Co-Authored-By` trailer, whatever the policy says, and in PR text
  no "Generated with Claude Code" attribution line.

`git cherry-pick`, `git rebase`, `git am` and `git revert` (also with
`--continue` or `--skip`) create commits without running any commit hook,
so `pre-commit` and `commit-msg` never see them and only CI checks the
result. The agent's Bash hook asks before each of them, as it does for
`--no-verify`.

**Agent attribution.** Claude Code adds a `Co-Authored-By: Claude …`
trailer to commits and a "Generated with Claude Code" line to PRs by
default, and gates refuses both. Turn them off for the project in
`.claude/settings.json`:

```json
{ "attribution": { "commit": "", "pr": "" } }
```

(`"includeCoAuthoredBy": false` is the older, deprecated form.)

**A repo that integrates a provider** (an SDK client, a model name in a
changelog) adds the phrases to `git.ai_branding.allow_phrases`. They are
removed before both branding checks, matched literally but ignoring case
like the terms, and the refusal message points there:

```json
{
  "git": {
    "ai_branding": {
      "allow_phrases": ["OpenAI API", "Anthropic SDK", "GPT-4o"]
    }
  }
}
```

`policy.json` is protected, so that change goes through a reviewed commit
with a `Protected-Change` trailer.

## Commands

| Command                       | Purpose                                                                                                                                                                                                                                                           |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/speckit.gates.init`         | Infer the policy, then project the runtime and wire the agent and git hooks in one `project.sh` run, and self-test                                                                                                                                                |
| `/speckit.gates.verify`       | Run the full suite on demand (also runs after `implement`)                                                                                                                                                                                                        |
| `/speckit.gates.doctor`       | Health check: tools, hooks wired and proven, versions in sync, upgrade safety (local edits, holds, CI drift), install hygiene, attestations, spec, contract and constitution state; `--installed-only` for an install with nothing projected, `--ci` for a CI job |
| `/speckit.gates.ci`           | Project CI enforcement (`github` \| `gitlab` \| `jenkins`); `--protect` requires the check + a PR on the default branch                                                                                                                                           |
| `/speckit.gates.upgrade`      | Verify a release, swap the installed extension, and re-project through `project.sh`; never touches policy.json                                                                                                                                                    |
| `/speckit.gates.sync`         | Pin + materialize the `extends` baseline; `--update` moves the pin as a reviewable branch                                                                                                                                                                         |
| `/speckit.gates.propose`      | Package this repo's policy deviations as an upstream change request against the baseline                                                                                                                                                                          |
| `/speckit.gates.constitution` | Guided session: interview to a profile, pick corpus principles, produce an enforcement-annotated constitution, and align each principle to its boundary                                                                                                           |

## Workflow-engine integration

Insert a hard gate into any Spec Kit workflow:

```yaml
- id: quality-gate
  type: shell
  run: .specify/gates/verify.sh --boundary ci --json
- id: human-review
  type: gate
  prompt: "Gates green. Approve merge preparation?"
```

A red gate pauses the run; fix and `specify workflow resume <run_id>`.

## Agent support

Git and CI boundaries work with **any** coding agent — they are plain git
hooks and CI jobs. Agent-boundary enforcement currently supports
**Claude Code** (hook system). Adapters for other harnesses are welcome
as they grow hook APIs.

## Design rules

- `policy.json` is user-owned: `init` seeds it, `upgrade` never overwrites it.
- Runtime is **projected** (copied) into the repo — enforcement survives
  extension removal and works for every collaborator who clones.
- Fail closed: a gate that cannot demonstrably block is reported broken.
- Evidence over trust: every run leaves an attestation record, canaries
  re-prove that every gate still blocks, and parity is verified per run
  rather than assumed.

## Development

```bash
npm ci              # pinned prettier + markdownlint-cli2
bash tests/run.sh   # 15 suites: parity, gate, hooks, policy, doctor, canary, attest, spec-gate, contract, constitution, package, pr-check, manifest, project, policy-infer
```

The gate runs the projected copy in `.specify/gates/`, so re-project after
editing `extension/runtime/` (steps in [CONTRIBUTING](CONTRIBUTING.md)).

The repo gates itself: `.github/workflows/ci.yml` projects the runtime and
runs `verify.sh --boundary ci` (attestations and the parity gate included)
plus the canary suite on every PR, alongside the tests. Every PR gets a
**unit test results** check (per-test table) and one sticky comment with
the per-suite counts and the coverage headline. A separate `coverage` job
runs the suite under bashcov and puts the runtime's line coverage per file
in its job summary and artifact; it reports and never blocks. Locally,
as root in a Linux container with bashcov installed:
`bash scripts/coverage.sh`. See the pull
request template for the contribution checklist.

## License

[MIT](LICENSE) © Frank Schwichtenberg
