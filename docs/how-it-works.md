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
  `.specify/gates/hooks.local.d/`, `.specify/gates/policy.json` (always,
  whatever the policy says), and every `protected_files.extra` entry. A
  Write or Edit to `.specify/memory/constitution.md` asks instead, under
  any policy (an `extra` entry naming it included): the constitution
  commands write it as one of their steps, so you approve that write once.
  It resolves `.`, `..` and `//` in the path first and matches ignoring
  case, since macOS filesystems are case-insensitive by default. Every
  rule, built-in or `extra`, also judges the fully resolved real path,
  with every symlink in the file and its parents followed, so a link
  inside the project (`gdir -> .specify/gates`, `pol.json -> policy.json`)
  or another spelling of the project root (`/tmp` and `/private/tmp`, a
  symlinked checkout) reaches the same verdict. A hard link to
  `policy.json`, the constitution, a contract artifact or a project rule is
  recognized as that file. A path whose links it cannot resolve (a loop)
  asks.
- `PreToolUse(Bash)` → `validate-bash.sh`: refuses destructive commands
  (`rm` of root, home or a path outside the temp directories, force push
  with `-f`, `--force`, `--force-with-lease`, `--mirror` or a `+ref`
  refspec, hard reset, `chmod 777`, piping a download into a shell,
  discarding the whole working tree with `git checkout`, `git restore` or
  `git rm` of `.`, `:/` or other pathspec magic in any option order,
  `git checkout -f`, `git switch -f` or `--discard-changes`,
  `git stash clear`, `git clean` with `-f` or `--force` anywhere, …). With
  `git.block_bulk_staging` it also refuses bulk staging: `git add` or
  `git stage` with `-A` (also in a cluster such as `-vA`), `--all`,
  `--no-ignore-removal`, `--pathspec-from-file`, `.`, `:/` and other
  pathspec magic, globs (quoted or not), `"$PWD"`, `~` and directory
  arguments (relative to an earlier `cd` in the same command), including
  behind `env`, `command`, `sudo`, variable assignments and git's global
  options (`-C`, `--no-pager`, …). An argument it cannot resolve (`"$f"`,
  a backtick substitution, arguments from `xargs`, a path after a `cd` it
  cannot follow) asks. `validate-pr.sh`: checks the title and body of
  `gh pr create|new|edit`, `glab mr create|new|update` (also with `-R` or
  `--repo` before the subcommand) and `gh api` calls on a
  `repos/<owner>/<repo>/pulls` endpoint with the commit-message rules. It
  reads each value as the shell would pass it and refuses one it cannot
  read literally: a variable, a command substitution (except the
  `"$(cat <<'EOF' … EOF)"` heredoc), a glob, a flag given twice, a
  clustered short flag such as `-tfeat`, `gh api --input`, or a PR
  command inside `sh -c` or `eval`.
- `PostToolUse(Write|Edit)` → `post-edit.sh`: formats the touched file per
  policy.
- `Stop` → `format-changed.sh` + `verify-quality.sh`: a stop while
  `verify.sh` is red is refused. The agent gets the failure list and keeps
  working. This turns "the tasks say run the tests" from a suggestion into
  an invariant, the property that matters for long, semi-attended
  `/speckit.implement` runs. The refusal holds once per stop: when the
  agent stops again right after it, Claude Code marks the retry with
  `stop_hook_active` and both hooks let it through, so a gate the agent
  cannot turn green never locks the session. A red tree still cannot be
  committed (`pre-commit`) or merged (CI).

Every refusal says why and what to do instead, so the agent is redirected
rather than stopped cold.

**Block, ask, allow.** The file and command hooks block on a rule match,
ask the human when they cannot judge, and allow everything else. "Ask" is
the PreToolUse `permissionDecision: ask` answer, which prompts in every
permission mode. The hooks ask when a file name merely contains a word
such as `secret` or `token` (a test like `test_no_secret_leak.py` is not a
credential), when a Bash command appears to modify a protected path
(`rm`, `mv`, `sed -i` or `--in-place`, a redirect (also `>|`), an
`--out`/`--output` option, `tee`, `find -delete`, `git rm`, also as
`/bin/rm`, `\rm`, `xargs rm`, inside `sh -c` or `eval`, or an
interpreter one-liner such as `python3 -c`, or an `ln` whose target or
link resolves to, contains or lies under one, naming one, its parent
directory, a brace, backslash or split-quote spelling of it, a variable
the same command assigns, a variable or substitution it cannot resolve
in front of the file name, a glob `extra` entry such as `**/*.lock.md`,
or a path relative to a
`cd` into one or to the session's working directory (the hook input
`cwd`, which Claude Code keeps between calls); telling
a modification from a read by the command text is a heuristic, so it asks
rather than blocks; a read-only command such as `grep -n rm <path>` and
the literal message of a `git commit -m` do not count as a change), when a Bash command names a secret file the file hook
refuses (`cat .env`), when it bypasses the git hooks (`--no-verify`,
`git commit -n`, a `core.hooksPath` setting, or a hook manager's skip
variable such as `HUSKY=0`, `LEFTHOOK=0` or `SKIP=`), when it creates
commits that git runs no commit hook for (`git cherry-pick`, `git rebase`,
`git am`, `git revert`, see the git boundary), when it deletes a remote
branch (`git push origin :main`, `--delete`), and in any state they
cannot evaluate. A project rule in `hooks.local.d` runs before any of
these questions, so its refusal wins. They never
silently allow. Without jq, or for input that is not valid JSON, they read
the field in a raw mode that keeps every built-in block rule and still
checks `policy.json`, the constitution and the project's rules; an
internal error, an undecodable, missing or repeated field, or a
`protected_files.extra` it cannot read asks. A malformed or invalid
`policy.json` cannot say what it protects either, so with jq the Write/Edit
hook asks before every edit and the Bash hook before every command that
appears to change a file. Doctor keeps failing until jq is installed.

**The Bash checks are heuristics.** `validate-bash.sh` reads the command
text, not what the shell will run. It recognises the common spellings
listed above, blocks where a match is certain and asks where it is not,
but it cannot parse every shell form. The git hooks and the CI boundary
(`pre-commit`, `commit-msg`, `pr-check.sh`) are the enforcement backstop.

**The Stop hook does not fail closed.** When `verify.sh` cannot run (no
jq, no git, no policy), `verify-quality.sh` lets the session end and says
why. That is deliberate: a missing tool must never lock the agent in a
session it cannot finish. The gate still holds where it can: `pre-commit`
refuses every commit while `verify.sh` cannot run, `pr-check.sh` and
`verify.sh` in CI exit with an error, and the Write/Edit and Bash hooks
keep working in raw mode. Only a red gate, never a missing tool, refuses
a stop, and only the first one: the agent's next stop is let through
(see `Stop` above).

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
staged content for secrets and forbidden files (renamed and typechanged
files included), and runs the same verify
entrypoint. `commit-msg` enforces Conventional Commits and refuses
AI-isms, emoji (anywhere in the message, not only the subject; comment
lines and the scissors section are dropped first), AI branding and
`Co-Authored-By` trailers. The branding
list is policy (`git.ai_branding.terms`); a legitimate phrase that contains
a term, such as a product name a repository integrates, is allowed via
`git.ai_branding.allow_phrases` (matched literally, ignoring case, like the
terms).

Subjects git writes itself are exempt from the Conventional Commits rule
only: a merge commit (recognized by `MERGE_HEAD`, not by its subject) and
the `fixup!`, `squash!` and `amend!` subjects of `git commit --fixup` and
`--squash`. A prefix counts only when the rest of the subject is the
subject of an existing commit, as git writes it; `fixup! anything` typed by
hand is judged like any other subject. Every other message rule still
applies to them.

`git cherry-pick`, `git rebase`, `git am` and `git revert` create commits
without running `pre-commit` or `commit-msg` (git's own behavior), so
neither the refusal of commits to `main` nor the secret scan nor the
message rules see them. The same holds for `--continue` and `--skip`,
which replay further commits (only a `cherry-pick` stopped on a conflict
runs the hooks for that one commit). Their result is checked only at the CI
boundary. The agent's Bash hook asks before each of them, as it does for
`--no-verify`; `--abort`, `--quit`, `--edit-todo` and
`--show-current-patch` create no commit and are allowed.

A merge commit never runs `pre-commit`: git runs `pre-merge-commit` and
`commit-msg` instead. The `pre-merge-commit` hook runs the `pre-commit`
checks unchanged, so a local merge into `main` is refused and the secret
scan sees what the merge brings in. git calls it from 2.24 on; doctor says
so on an older git. A fast-forward creates no commit and runs no hook.

`.git/hooks` holds three copies of a small stub, not the hooks themselves.
`.git/hooks` is shared by every branch while the projected runtime is per
branch, so the stub runs the checked-out branch's
`.specify/gates/hooks/<name>`. The hook version always matches the
branch's runtime, and an upgrade needs no hook reinstall. A branch from
before gates was adopted has no runtime and is skipped: git tracks nothing
under `.specify/gates` there, in `HEAD` or in the index, and gitignored
leftovers such as `attestations.jsonl` do not count. A branch that tracks a
runtime but deleted its hooks is refused, so removing the hooks cannot
quietly turn enforcement off. A branch whose runtime predates
`pre-merge-commit` runs its `pre-commit` hook for a merge.

A branch that tracks something under `.specify/gates` but has no
projected libraries is refused too: `pre-commit` without
`lib/policy.sh`, `commit-msg` without `lib/policy.sh` or
`lib/message.sh`. That is a clone of a repo that commits `policy.json`
and gitignores the runtime, before anyone ran
`bash .specify/extensions/gates/runtime/project.sh`; the refusal names
that command. Only a runtime whose `.runtime-version` names a release
before 0.3.4 commits without `lib/message.sh`, with a warning that the
message rules were skipped.

**Other hook managers.** When husky, lefthook or the pre-commit framework
owns the hooks, gates adds its entry to the file that tool reads, never to
the files it generates, which its next install would rewrite.
`project.sh --wire-manager` appends the entry only where the result is
certainly still valid; otherwise it prints it.

| Owner                                                     | Where the gates entry goes                        | Notes                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| husky (`core.hooksPath` under `.husky/`)                  | a line in `.husky/<hook>`                         | The script is created if missing, executable (husky 8, `core.hooksPath=.husky`, has git run it directly); your existing lines stay first. Under husky 8 an existing script without the execute bit fails the git check. A script with a top-level `exit` is left alone and the line printed, to go before the `exit`.     |
| lefthook                                                  | a `<hook>:` block in `lefthook.yml`               | Appended only when that hook has no block yet; otherwise printed for you to merge. A `lefthook.toml`, `.json` or `.jsonc` (also under `.config/`) is never edited: the entry is printed in its format. Run `lefthook install` if git does not run lefthook for that hook yet; until then the hook is reported as pending. |
| pre-commit framework                                      | a `repo: local` item in `.pre-commit-config.yaml` | Appended only when `repos:` is the last top-level key and a block list (not `repos: []`); otherwise printed. Needs pre-commit 3.2+; run `pre-commit install --hook-type <hook>` for `commit-msg` and `pre-merge-commit`.                                                                                                  |
| anything else (another `core.hooksPath`, a custom script) | nothing is written                                | `project.sh` prints the call-through line to add, before any `exit`.                                                                                                                                                                                                                                                      |

**Proving the hooks run.** A hook that exists is not a hook git runs. The
projected hooks answer `GATES_PROBE=1` with a marker before reading any
policy, so a probe works with every rule off and can only refuse. Doctor
and `project.sh` run the stub that way and fail when the marker does not
come back. A hook another tool owns is read, not run, because running it
would also run that tool's steps (husky's default `pre-commit` is
`npm test`, under `sh -e`); the check looks for the gates call-through in
the tool's file, on a line that can run (not commented out, not after a
top-level `exit`, `exec <command>` or one-line `if ...; then exit`), and
`--probe-git` runs the full chain on request. Only the configuration of
the manager that runs the hook is read, and only where it runs the
call-through for that hook: in lefthook, a job under the hook's own key
without `skip:`/`only:`; in the pre-commit framework, an item whose
`stages:` (or `default_stages:`) include the hook, an item without either
counting for `pre-commit` only. Other conditional exits in a script, and
lefthook's `lefthook-local` overrides or remote configs, are not read
statically; `--probe-git` covers them.

lefthook skips a `pre-commit` job while nothing is staged unless the job
has files to inspect, which would let `git commit --allow-empty` and
`--amend` on `main` through. The entry gates writes gives the job
`files: echo lefthook.yml` (the config file always exists) and puts
`{files}` in a shell comment of the quoted `run:` line, so the job runs on
every commit and the gates hook gets no arguments. The static check and the
probe fail a `pre-commit` job without that (or `{all_files}`), or with a
`glob`/`file_types`/`exclude` filter.

The probe calls each hook as git does: only `commit-msg` gets a message
file. lefthook's hook gets `--job <gates job>` (passed on to `lefthook
run`), so no other job runs and nothing is rewritten. A hook a manager's
config calls but whose install command has not run yet is reported by
`project.sh` as pending that command; doctor fails on it, naming the
command, since a commit runs no gates check until then.

**Protected files** get different treatment at the two local boundaries.
The agent may never edit them, except the constitution, whose Write/Edit
asks you first. At the git boundary a human is the
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
to `false` restores the unconditional refusal. The hooks read the switch
from the staged policy and `HEAD`'s, not the working tree, so an
unstaged edit does not lift the refusal, and the commit that turns
it off is still judged by the trailer rule: it passes with a
`Protected-Change` trailer for each protected path it stages plus
`Approved-By`, and the refusal applies from the next commit on. The one
exception to the refusal is the commit
`contract.sh sync --update` makes: on a `gates/baseline-<v>` branch,
`policy.json` changing `extends.version` alone plus the three contract
artifacts, consistent with the pin, passes (checked against the index).

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

A base policy that is not valid (broken JSON, wrong shape) stops the check
with exit 2 and names the problem, as `verify.sh` refuses it; it never
reads as "nothing is protected". A base with no policy at all is the PR
that adopts spec-gates: it is checked against the PR's own policy, and
`policy.json`, the constitution, `hooks.local.d/**` and the contract
artifacts are protected whatever that policy says. The log says so.

The code that runs the check comes from the base too. The projected
templates extract `.specify/gates/pr-check.sh` and `lib/` from the base
revision (`git archive`) into a temporary directory and run that copy
against the PR checkout, pointing it at its own libraries with
`GATES_RUNTIME_DIR`. A PR that replaces `pr-check.sh` with `exit 0` is
still judged by the base's copy. When the base has no `pr-check.sh` (the
adoption PR), the PR's own copy runs and the log says so. A base whose
`pr-check.sh` predates `GATES_RUNTIME_DIR` still loads the PR's
libraries, so this protection starts with the first base that carries a
release supporting it.

## One entrypoint

`verify.sh --boundary agent|git|ci [--json] [--dry-run]`

Dispatch follows the policy's `verify-quality.orchestrator`:

- `none`: per-tool walk (prettier, markdownlint, shellcheck) driven by the
  policy's include and exclude globs via `lib/formatter-dispatch.sh`. In a
  git work tree it skips untracked files git ignores (husky's generated
  `.husky/_/`, build output), since CI never sees them; a tracked file is
  checked even when an ignore pattern matches it (prettier runs with
  `--ignore-path .prettierignore`, so `.gitignore` never hides a tracked
  file from it, while `.prettierignore` still applies).
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
it. A missing `--boundary`, a bad `--boundary` value, `--boundary` or
`--accept` without a value (an empty value included), or an `--accept`
name that is not a feature, is a usage error (exit `1`)
refused before any gate runs.

**Environment overrides are visible.** `GATES_POLICY_FILE` replaces the
whole policy, so set on one command it would drop every gate the
repository declares. The git hooks, `verify.sh --boundary git|ci` and
`pr-check.sh` ignore it and enforce the policy the repository commits;
`verify.sh` at the agent boundary applies it.
Either way the run says so: a stderr line, an `[override] policy` line in
the text report, and a `policy_override` object (`file`, `applied`) in the
`--json` output and the attestation, whose `policy_sha256` hashes the
policy actually enforced. The canary suite therefore probes its sandboxes
with their own policies under an inherited override. Other variables
that change what is enforced are reported where they act: `GATES_SKIP=1`
(the pre-commit quality gate) prints that verify did not run, and
`GATES_SPEC_EXEC` records the spec gate as `skipped`. validate-bash asks
before a command sets `GATES_POLICY_FILE`, `GATES_SKIP`,
`GATES_ALLOW_MAIN_COMMIT`, `GATES_RUNTIME_DIR`, `GATES_TEST` or
`GATES_SPEC_EXEC`; unsetting them (`env -u`) is allowed.

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
   block's whole process group, and snapshots around each block:
   `git status` plus a content hash of every dirty or untracked file, git
   config in every scope, the hooks directory git uses, the files in
   `.git/info/` (attributes, exclude, sparse-checkout), every index entry
   flagged skip-worktree or assume-unchanged (the flag and a content hash,
   since `git status` no longer reports edits to such a file), this
   worktree's path and lock when it is a linked one, `HEAD` and every
   local ref, and gitignored files (checked by ctime). A block that
   changes any of them, including a write to a file that was already
   modified, a `git config core.hooksPath`, a commit, a tag or a new
   branch, fails its criterion, and nothing is ever auto-reverted.
   Repacking (`git gc`, `git pack-refs`) changes how git stores objects
   and refs, not what they say, and is not checked. Other worktrees are
   left out: their `HEAD`, their per-worktree refs, their entries, and
   the refs of the branches they have checked out (or are rebasing)
   before or after the block. A commit, a branch switch, or a worktree
   added or removed in a sibling worktree during the run does not fail a
   block. The flip side: a block that adds a worktree outside the
   project, or commits in another worktree, is not caught either (one
   inside the project shows up as an untracked directory).

   No process may outlive its block. The process group is stopped after
   every block, and a block that leaves a process running fails. A child
   that leaves the group or the session (`set -m`, `setsid`, a double
   fork) is found two ways: every process the block starts inherits the
   write end of a FIFO on descriptor 7, which the gate reads to EOF (no
   EOF half a second after the block exits means a holder is alive), and
   carries `GATES_SPEC_BLOCK=<id>` in its environment, which the gate
   looks for in `/proc/<pid>/environ` on Linux and in `ps -E` elsewhere.
   What is found is killed, and the block fails with
   `left a detached process running (stopped)`. Not found: a process that
   closed descriptor 7 and also started a program without the marker
   (`env -i`, `env -u GATES_SPEC_BLOCK`, or overwrote its environment in
   memory). On macOS `ps` shows no environment for Apple-signed binaries
   (`/bin/sh`, `/bin/sleep`, `/usr/bin/git`, `/usr/bin/perl`), so there
   only the descriptor finds them: a `/bin/sh` child started through
   Node's `child_process` or Python's `subprocess`, which pass no extra
   descriptors, is not seen on macOS. The process table is read after a
   short settle and before the after-snapshot, so a write such a process
   makes right away is still caught as a mutation; a later one is not.
   `spec.snapshot_exclude` exempts untracked or ignored paths another
   process writes during the run; `cache/` names the directory and
   everything under it, like `cache/**`, and a pattern of only `*`, `?`
   and `/` (which would exempt everything) makes the policy invalid.
   Outside a git work tree there is nothing to check against, so blocks
   fail closed.

4. **Enforce**: a Complete feature fails the `spec` gate on any unchecked
   task or failing block, naming the feature, the task or criterion, and
   the cause. Incomplete features are informational
   (`spec: <feature> -- N criteria parsed, not enforced`); a Complete
   feature with zero blocks is flagged as having nothing executable to hold
   it to, but does not block.

**Recursion guard.** An accept block that invokes `verify.sh` (this
repository's own blocks do) would re-enter the spec gate and recurse.
Blocks execute with `GATES_SPEC_EXEC=1` exported, and `verify.sh` runs no
accept blocks when it is set. Since any caller can set it, the spec gate
is then reported as `skipped` with the reason (text, `--json`, and the
attestation), and validate-bash asks before a command that sets it.
Consumers that must probe the spec gate from inside a block (the canary
suite, the test suites) clear the sentinel explicitly for their sandboxed
runs.

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
   resolver. `GATES_POLICY_FILE` takes precedence where it applies (the
   agent boundary and the library seams the test suites use); the git
   and CI boundaries ignore it (see One entrypoint). The
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
Constraints, Governance) are prose, and a heading or marker inside a
fenced code block is example content, never a principle. The grammar is fixed: a `surface` from
`policy | agent-hook | git-hook | ci | accept | scanner | prose`, a `ref`
required for all but `prose`, and an optional `expect` for policy surfaces.
A malformed marker, or one outside Core Principles, is fail-closed: `check`
and `doctor` fail naming `constitution.md:<line>`, because an unreadable or
unchecked claim is worse than no claim.

**Align.** `constitution.sh align` evaluates, per annotated principle,
whether its surface is actually wired, all from local files with no
network: a `policy` key present in the effective policy (and equal to
`expect`; a list or object must be non-empty, and `expect` names an entry
the list contains or a key the object has), the ref read as a full dotted
path (`hooks.markdownlint.severity`; a ref not starting with a top-level
section such as `git` or `attestation` is short for `hooks.<ref>`); an
`agent-hook` present, executable and referenced in `settings.json`; a
`git-hook` installed, executable and delegating to the runtime; a `ci`
pipeline with a live `verify.sh --boundary ci` step that also runs the
named template step (`gates`, `canary`, `pr`) or, for any other ref, names
it, where live means what doctor's CI drift check reads (below); an
`accept` block that parses
and verifies the named criterion; a `scanner` rule in the tool's config.
Each principle is `active`, `missing` (with a concrete proposed change), or
`pending-boundary` (the whole boundary is not projected yet). A policy
proposal follows `policy.schema.json`, so applying it makes the principle
active; a marker no valid policy can satisfy (a path the schema lacks, an
`expect` outside the allowed values or below the schema's minimum) is
proposed as an annotation fix instead. `align` and `check` refuse (exit
`1`) a policy `verify.sh` would refuse, whether named with `--policy` or
resolved, since nothing in it is enforced. Proposed policy changes target the **overlay**, so with a live contract they flow
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
A deletion is never held: every projected file is run by a hook, a gate,
the canary suite or CI, so `--keep-local` on a deleted file is refused,
and a held file that is missing fails `project.sh` and doctor until
`--take-upstream` restores it. Doctor recommends `doctor.sh --canary`
while any file is held, since only the canaries show that a held edit
still blocks.
Doctor flags a held file whose upstream copy changed since the hold, so a
hold never silently pins an old version of a hook. A project projected by 0.3.x has no manifest; there
`project.sh` compares each file against the hashes of what the 0.3.x
releases shipped (`lib/known-releases.sha256`), so only real edits stop
the upgrade. Doctor reports the same state between upgrades: local edits
that are not held, holds that went stale (the held file now equals the
installed copy), and CI pipelines missing a template step (the gates,
canary and PR-check steps, recognized by command on GitHub, GitLab and
Jenkins; `ci:<step>` in the holds file records a deliberate omission).
Only a live step counts: one that runs on a push or pull request and can
fail the pipeline. Doctor first removes, as text, what never runs or can
never fail: comments (`#` in YAML, `//` and `/* */` in a Jenkinsfile);
steps or jobs under `if: false`; a command only printed by `echo` or
`printf`; a command followed by `|| true`, `|| :`, `|| exit 0` or
`|| echo`; a command with `--dry-run`; anything after an unconditional
`exit 0` in the same run block; GitHub `continue-on-error: true` on the
step or job, and a workflow whose only triggers are `workflow_dispatch`
and `schedule`; GitLab `allow_failure: true`, `when: manual` or
`when: never` on the job, rules that never let a job run (every rule up to
the first unconditional one says `when: never` or `manual`; under
`workflow:` this stops the whole file), an `only:`/`except:` that keeps a
job out of branch and merge request pipelines (`only: [tags]`,
`except: [branches]`), and a hidden `.name:` job nothing extends; a
Jenkins stage under `when { expression { false } }` and an `sh` step with
`returnStatus: true`.

The gates step is then proven, not searched for: denying inert forms one
by one always leaves another. It counts only when all of these hold:

- the command, after one layer of quotes, is exactly
  `bash .specify/gates/verify.sh --boundary ci` (`bash`, `./` and the
  directory are optional; `--json` may come before or after
  `--boundary ci`), with nothing else on the line: no `;`, `&&`, `||`, `&`,
  `|`, `:`, `if`, `exit`, `true`, env prefix, second `--boundary` or
  `--dry-run`;
- it is the whole value of a GitHub `run:`, a GitLab `script:` or
  `before_script:` item (an `after_script:` failure does not fail the
  job), or the string of a Jenkins `sh` step (`sh '...'`,
  `sh(script: '...')`); or the last line of such a `|` block or `'''`
  string. Nothing before it in the same shell (earlier lines of the block,
  earlier GitLab script items) holds a heredoc, a `trap`, an `exit 0` or a
  `\` continuation into it;
- a GitHub workflow has `push` or `pull_request` among its `on:` events;
- the pipeline file never names `GATES_SPEC_EXEC` (skips the spec gate)
  or `GATES_POLICY_FILE` (replaces the policy), in any `env:`,
  `variables:` or `withEnv`;
- a Jenkins `sh` step is not inside `catchError`, `warnError` or `try`.

A pipeline that calls `verify.sh` but has no proven gates step fails, and
the line names what to change; a repository with no such pipeline at all
gets a recommendation. `verify.sh` itself refuses a repeated `--boundary`.
A `ci:<step>` hold for a step the pipeline runs is stale and fails; one
naming no template step gets a recommendation to remove it.

The check reads files, so it has limits. Read as live: a GitHub
`if:`, `continue-on-error:` or event filter (`branches:`, `paths:`)
computed by an expression or narrowing the trigger; conditional GitLab
rules (an `if:` that never matches, an earlier conditional `when: never`),
a job reached only through `extends:` or an alias, and an `exit 0` in
`before_script:` ahead of a `script:` step; a GitHub `shell:`
override; CI/CD variables set outside the file (GitLab project settings,
Jenkins job configuration) and Jenkins triggers, which live in the job,
not the Jenkinsfile; a Jenkins `when` other than a literal false; a
Jenkins step in a closure that is never called. Rejected although it may
be fine: the gates command followed by other commands in the same block
(move it to its own step, or make it the last line), and a path written
with a variable. The canary and PR-check steps are still recognized by
command after the removals above, not proven. The proof that the gates
ran is the CI run's own log: `verify.sh` prints a
`gates: boundary=ci failed=N warnings=N` summary line.

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
about, as `policy.json` and the project's own rules are (the constitution
asks for both).
The Bash check is itself a heuristic over command text, which is why it
asks rather than claims to block.

Defense in depth is the point of the three-boundary design. Whatever an
agent changes locally still has to pass the git hooks (whose own changes
need a reviewed trailer when protected) and then CI and server-side branch
protection. The boundaries an agent cannot touch backstop the ones it
theoretically could.

CI is only as independent as the code it runs, and a pull request brings
its own copy of most of it. The PR check runs the base revision's
`pr-check.sh` and libraries, so a PR cannot replace the check that judges
its protected changes. The rest still comes from the PR head:
`verify.sh`, `canary.sh` and, on GitHub and GitLab, the pipeline file
itself, so a PR (pushed with `--no-verify`) can rewrite the steps that
run on it. The human backstop is required, not optional: branch
protection (or a ruleset) that requires the gates check and a review, and
CODEOWNERS entries for `.specify/gates/**` and the pipeline file
(`.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`) with code-owner
review required, so a change to the enforcement itself needs an owner's
approval.

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
