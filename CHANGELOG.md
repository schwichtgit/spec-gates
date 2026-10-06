<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

User-visible changes to the spec-gates extension. Each release lists new
behavior, changed defaults, and anything an upgrade requires. Upgrading
never touches `.specify/gates/policy.json`. New policy keys take the
defaults stated here until you set them. Releases before 0.3.3 are
described in their [GitHub release notes](https://github.com/schwichtgit/spec-gates/releases).

## [Unreleased]

### Fixed

- **Doctor names the pending upgrade item** (#214). Whenever
  `project.sh --check` exited 1, doctor advised running `project.sh`,
  which reports "no changes" for pending hook-manager wiring, a pending
  `lefthook install`, stale or missing holds, missing git or a repository
  git refuses. Doctor now names each item and its command
  (`--wire-manager`, the manager's install command, the holds file,
  `safe.directory`) and still fails until it is done.
- **Upgrade notes are exact** (#215). `project.sh` no longer prints a
  stray space before the closing parenthesis of "the CI pipeline (...)
  lacks these template steps".
  The README Upgrade section says how the new `pre-merge-commit` stub
  behaves on a branch still on 0.3.x (it runs that branch's `pre-commit`
  hook) and that rolling back means removing that stub.
- **A parent directory in `.prettierignore` counts** (#217). `project.sh`
  reported `.specify/gates/`, `.specify/extensions/` and
  `.claude/hooks/gates/` as not excluded when `.prettierignore` already
  had `.specify/` and `.claude/`, and `--add-lint-ignores` appended
  redundant lines. An entry for the path or a parent directory (with `/`,
  `/*` or `/**`) now covers it. The README Upgrade step 3 says to run
  `specify extension remove` and `add` as two commands and to check the
  remove output first.

## 0.4.0 — 2026-10-06

### Upgrading

- Upgrade with the README "Upgrade" steps; they end with one
  `project.sh` run. Commit `.specify/gates/.projected.sha256` and
  `.specify/gates/project.sh` with the upgrade, as `project.sh` lists.
- A 0.3.x projection has no manifest yet: the first `project.sh` run
  compares each file against what the 0.3.x releases shipped, so only
  real local edits stop it (exit 3). Resolve each with
  `--keep-local <path>` or `--take-upstream <path>`.
- A 0.3.x projection has no `.specify/gates/project.sh`; if
  `specify extension add` failed half-way, re-run it, then `project.sh`.
- With husky, lefthook or the pre-commit framework, run
  `project.sh --wire-manager` (gates writes only to that manager's own
  config) and check `doctor.sh --probe-git`.
- `verify.sh` without `--boundary` still runs, with a deprecation
  warning; `project.sh` and doctor name the scripts that call it so.
- The release is signed with sigstore (cosign); without cosign on the
  machine, verify the signature elsewhere and compare the sha256 here.

### Added

- **One-command projection: `project.sh`** (#72). `bash
.specify/extensions/gates/runtime/project.sh` does what init and upgrade
  used to do file by file: copy the runtime, set execute bits (including
  the installed extension's git hooks, which zip extraction leaves
  non-executable), merge the agent hook settings, install the git hook
  stubs, and run the canary suite. `--dry-run` shows the plan first, and a
  second run changes nothing. It never writes `policy.json`.
- **Local edits survive upgrades** (#72, #70). `project.sh` records a hash
  of every projected file in `.specify/gates/.projected.sha256`. A file
  changed since then stops the run (exit 3) until you pass
  `--keep-local <path>`, which holds it in `.specify/gates/.upgrade-holds`,
  or `--take-upstream <path>`.
- **Upgrading a 0.3.x projection reports only real edits** (#70). Those
  projections have no manifest yet, so `project.sh` compares each file
  against what the 0.3.x releases shipped
  (`runtime/lib/known-releases.sha256`); a file one of them shipped
  unchanged is updated without asking.
- **Doctor checks upgrade safety** (#70): whether the projection is
  current, local edits that are not held, holds that went stale (the held
  file now equals the installed copy), and CI pipelines missing a template
  step (`verify.sh --boundary ci`, `canary.sh`, `pr-check.sh`). Record a
  deliberate omission as `ci:<step>` in `.specify/gates/.upgrade-holds`.
  `project.sh` reports the same holds and CI drift.
- **Project rules that survive upgrades** (#71):
  `.specify/gates/hooks.local.d/<hook>/*.sh` for `protect-files`,
  `validate-bash`, `validate-pr`, `pre-commit` and `commit-msg`. They run
  after the shipped checks and can only add refusals.
- **Project rules and protected files are out of the agent's reach**
  (#95). Write/Edit under `hooks.local.d/` is refused, a Bash command that
  appears to modify a protected path (`rm`, `mv`, `sed -i`, a redirect,
  `tee`, `git rm`; `hooks.local.d`, `policy.json`, the constitution, any
  `protected_files.extra` entry) asks first, and committing a rule change
  needs `Protected-Change` and `Approved-By` trailers, also checked by
  `pr-check.sh` in CI.
- **`git.block_bulk_staging`** (default `false`, #71): refuses bulk `git
add` forms at the agent boundary. `project.sh` lists new settings like
  this one on the first upgrade that ships them and never writes
  `policy.json`.
- **Install hygiene** (#73). Doctor fails when a registered gates command's
  skill is a symlink (a `--dev` install), dangles, or is missing, and flags
  a `--dev` install and installed extension scripts without the execute
  bit. `project.sh` reports vendored paths missing from `.prettierignore`
  in repos that use prettier, and `--add-lint-ignores` appends them.
- **The git boundary is proven, not assumed** (#74). The projected git hooks
  answer `GATES_PROBE=1` with a marker before reading any policy. Doctor and
  `project.sh` run a gates-owned hook (the stub) with it and fail when the
  marker does not come back. A hook another tool owns is checked statically
  (the gates call-through in `.husky/<hook>`, `lefthook.yml` or
  `.pre-commit-config.yaml`) instead of being run, because running it would
  also run that tool's steps; `--probe-git` runs the full chain on request.
- **Hook-manager adapters** (#74). With husky, lefthook or the pre-commit
  framework, `project.sh` adds the gates entry to that tool's own
  configuration (`.husky/<hook>`, a `lefthook.yml` block, a `repo: local`
  item in `.pre-commit-config.yaml`) with `--wire-manager`, and only where
  the append is certainly valid; otherwise it prints the entry. It never
  edits the files those tools generate. Before 0.4.0, init appended a
  call-through to whatever file sat in the hooks directory, which the next
  `husky`, `lefthook install` or `pre-commit install` overwrote.
- **`doctor --installed-only`** (#74) checks the installed extension alone,
  for an install with nothing projected yet. Doctor also fails on a
  half-done upgrade (extension removed, runtime still projected) and on a
  registry that disagrees with the installed copy.
- **A half-done upgrade is detected.** If `specify extension remove` ran
  but `add` did not, `bash .specify/gates/project.sh --check` says so and
  prints the command that finishes it.

### Changed

- **The standalone "Claude" refusal names `git.ai_branding.allow_phrases`**,
  and the README documents the message rules, the agent attribution
  setting, and the `allow_phrases` entry for a repo that integrates a
  provider (#74).
- **The file hook asks instead of blocking on a name alone** (#71). A
  sensitive word in a file name (`secret`, `token`, `password`,
  `credentials`, `keystore`) now asks for confirmation; exact credential
  names, keys, certificates (now including `*.jks` and `*.keystore`) and
  `.env` files still block.

- **One documented upgrade path** (README "Upgrade", `/speckit.gates.upgrade`):
  verify the versioned zip (checksum and cosign), remove and add the
  extension, diff the install against the verified zip, then run
  `project.sh`. `specify extension add --from` verifies neither. Without
  cosign on the machine, the signature can be checked on another machine
  and tied to the local zip by its sha256; skipping it is only ever the
  maintainer's explicit choice.
- **The init self-test uses the canaries** for the agent hooks, so the
  live command hook no longer refuses the self-test's own probe.
- **Git hooks owned by another tool are left alone.** When
  `core.hooksPath` is set or a non-gates hook exists, `project.sh` prints
  the call-through line to add instead of editing that tool's files.
- **`extension.yml` declares every tool the runtime needs**: git is now
  required, and python3 and cmp are listed (doctor already checked them).
  The internal `MIGRATION-NOTES.md` (the extraction log from the
  predecessor project) is removed.

### Fixed

- **Without python3 the PR hook refuses only possible PR commands**
  (T050 container matrix). It refused every command whose text named a PR
  command, so `git commit -m "fix: handle gh pr create"` and any `gh api`
  call were blocked. It now lets through a command where `gh`/`glab` is
  not at a command start, and a `gh api` call that names no pulls
  endpoint; every PR command form is still refused.
- **A pattern after a leading `**/` matches top-level paths** (#220).
  The shared glob matcher compared the rest of a `**/` pattern as a
  literal, so `**/*.md` missed `README.md` and `**/.claude/mind.*` missed
  `.claude/mind.mv2`. `spec.snapshot_exclude`, `spec.exclude` and
  `protected_files.extra` in protect-files (an entry such as
  `**/secrets/*.json` did not protect a file at the repository root from
  the agent) now match as documented.
- **The rm guard ignores Markdown in a quoted heredoc** (#218).
  `cat > notes.md <<'EOF'` with an rm example in its body was refused,
  and a slash before the closing backtick of inline code was read as the
  root path.
  A quoted heredoc body, a literal `git commit -m` message and a literal
  `gh` `--body`, `--title` or `--notes` value are now data, and a backtick
  ends an rm segment. A heredoc fed to a shell or interpreter still counts.
- **`grep -n rm <path> > /dev/null` is no longer refused** (#205). A
  redirect target is not an rm argument, so `/dev/null` after `>` or `2>`
  no longer reads as an absolute rm target.
- **CI scans the pull request's commits for secrets and forbidden files**
  (#212). Commits made by `cherry-pick`, `rebase`, `am` or `revert` run no
  commit hook, and no boundary scanned them. `pr-check.sh` now runs the
  `pre-commit` scan, with the same rules (now `lib/secrets.sh`, shared by
  both), over the files each commit in the range adds or changes, renames
  included. A secret added and removed within the range still fails: it is
  in the pushed history.
- **`verify.sh` without `--boundary` warns instead of refusing** (#216).
  A 0.3.6 caller such as `"gates": "bash .specify/gates/verify.sh"` broke
  on upgrade. It now runs as in 0.3.6 (every gate, boundary
  `unspecified`) with a stderr deprecation warning naming
  `--boundary agent|git|ci`; `GATES_POLICY_FILE` is ignored for such a
  run. `project.sh` and doctor name callers in `package.json`, Taskfiles
  and Makefiles that omit `--boundary`.
- **A project rule's timeout covers what the rule started** (#189). A
  rule that exited after starting a background child (`(sleep 25) &`,
  `nohup … &`) made the hook wait for the child, past the timeout or
  forever, since the child held the captured stderr pipe. The rule's
  stderr now goes to a file, its process group is stopped when it exits
  or times out, and a rule that leaves a process running refuses, as an
  accept block does. A non-numeric `GATES_LOCAL_TIMEOUT` disabled the
  timeout; any value that is not a whole number above 0 now refuses.
- **`GATES_POLICY_FILE` no longer drops gates at the git and CI
  boundaries** (#196). Set on a commit it replaced the whole policy, so the
  lint gates vanished without a `skipped` line and the canaries passed
  unblocked. The git hooks, `verify.sh --boundary git|ci` and
  `pr-check.sh` now ignore it and say so; at the agent boundary it still
  applies and is reported in the text, `--json` and the attestation
  (`policy_override`). validate-bash asks before a command sets
  `GATES_POLICY_FILE`, `GATES_SKIP`, `GATES_ALLOW_MAIN_COMMIT`,
  `GATES_RUNTIME_DIR` or `GATES_TEST`, and `GATES_SKIP=1` now prints that
  the quality gate did not run.
- **Renamed and typechanged files are scanned for secrets** (#186).
  `pre-commit` (and `pre-merge-commit`) listed staged files without
  renames or typechanges, so `git mv settings.txt .env`, a rename with a
  small edit adding a key, or a symlink replaced by a file holding one
  was committed unscanned. Renames now count as their new name, and
  typechanges are scanned.
- **An unstaged policy edit no longer lifts the trailer-off refusal**
  (#188). The hooks turned `git.protected_change_trailer` on when the
  working-tree policy had it on, so re-enabling it without staging that
  edit let a refused protected commit through. The switch is now read
  from the staged policy and `HEAD`'s (the working tree only when neither
  carries a policy).
- **The PR hook checks `gh pr new`, `glab mr new` and a leading `-R`**
  (#192). `validate-pr.sh` matched only `gh pr create|edit` and
  `glab mr create|update` spelled exactly, so the `new` alias and a
  `-R`/`--repo` flag before the subcommand (`gh -R o/r pr create`) let an
  unchecked title and body through. Both are now recognized.
- **Agent hooks: a missing prettier is a skip, and fewer false asks**
  (#195). With `post-edit.severity: error` and prettier not installed,
  every `.md` edit failed as a tool failure (bare `npx` fails without
  prettier) while `verify.sh` reported `[skipped]`; the formatter now
  resolves prettier as `verify.sh` does and skips with a note.
  `grep -n rm <protected path>` and a commit message naming a protected
  path no longer ask. The docs now say that the Stop hook lets the stop
  right after a refusal through (`stop_hook_active`).
- **Symlinks inside the project no longer bypass the file hook** (#193).
  `protect-files` compared only the path as written, so a link such as
  `gdir -> .specify/gates` or `pol.json -> policy.json` made a protected
  file editable. Every rule now also judges the fully resolved real path
  (file and parents, with and without jq), hard links to protected files
  are recognized, and `validate-bash` asks for an `ln` that links to or
  through a protected path.
- **A Write or Edit to the constitution asks instead of being refused**
  (#200). `/speckit-constitution` and `/speckit.gates.constitution` write
  `.specify/memory/constitution.md` as one of their steps, and the file
  hook refused that write with no way through. It now asks, under any
  policy; `policy.json`, `hooks.local.d` and the contract artifacts stay
  refused.
- **validate-bash catches more command variants** (#194). A `>|`
  redirect, `sed --in-place`, split quotes (`pol""icy.json`), a variable
  in front of the file name, `--out` to a protected path and a glob
  `extra` entry with no literal prefix (`**/*.lock.md`) now ask. Force
  pushes with a `+ref` refspec, `--force-with-lease` or `--mirror`,
  `git checkout -f`, `git switch -f`/`--discard-changes`, `git rm` of the
  whole tree and `git stash clear` are refused; a remote branch deletion
  and a hook manager's skip variable (`HUSKY=0`, `LEFTHOOK=0`, `SKIP=`)
  ask. The docs now call the Bash checks heuristics, with the git hooks
  and CI as the backstop.
- **validate-bash resolves relative protected paths against `cwd`**
  (#191). Claude Code keeps the Bash working directory between calls, so
  after `cd .specify/gates` a later `rm policy.json` changed the policy
  without an ask (jq and raw mode alike). The hook now reads protected
  paths relative to the input `cwd` too, also under another spelling of
  the project root, and asks for any change made from inside a protected
  directory.
- **Emoji are checked in the whole commit message** (#190). commit-msg
  checked emoji in the subject only; it now checks the body too, after
  dropping comment lines and the scissors section. The docs now say
  which forms `git.block_bulk_staging` refuses; `git add -u`,
  `--renormalize` and `git commit -a` stay allowed, since they stage
  only tracked changes.
- **Commits made without commit hooks ask first** (#187). Like
  `git revert`, the only one documented, `git cherry-pick`, `git rebase`
  and `git am` create commits without running `pre-commit` or
  `commit-msg`; validate-bash allowed all four. It now asks before each
  (also `--continue` and `--skip`), naming the CI boundary as the only
  check, and the docs list all four.
- **Small gates findings from RC3** (#199). `verify.sh --accept ""` is a
  usage error (exit 1) instead of a full run. `--dry-run` lists the `parity` gate. prettier checks a
  tracked file even when `.gitignore` lists it. In `spec.snapshot_exclude`,
  `cache/` now covers the directory like `cache/**`, and a pattern of only
  `*`, `?` and `/` makes the policy invalid. `constitution.sh align` no
  longer proposes values below the schema minimum, `align` and `check`
  refuse an invalid policy instead of reporting principles active against
  it, and a heading or marker inside a fenced code block is not a
  principle.
- **An accept block can no longer leave a detached process behind**
  (#197). A child that left the block's process group (`set -m`,
  `setsid`, a double fork) kept running after a passing block and could
  switch `core.hooksPath` off seconds later. Blocks now inherit a lease
  descriptor and a `GATES_SPEC_BLOCK` marker; a process still holding
  either after the block exits is stopped and fails it. The read-only
  check also covers skip-worktree and assume-unchanged flags (with a
  content hash of flagged files), `.git/info/` and linked worktrees.
- **Work in another worktree no longer fails an accept block** (#206). The
  read-only check compared every ref and every linked worktree, so a
  commit, a branch switch, or a worktree added or removed in a sibling
  worktree while a block ran failed it. Refs of branches other worktrees
  have checked out, and other worktrees' entries, are now left out; `HEAD`,
  this worktree's branch, tags and branches checked out nowhere still
  count.
- **The CI gates step must be proven, not merely found** (#198). Doctor
  and the constitution `ci` surface still accepted steps that cannot fail
  the pipeline: `verify.sh --boundary ci; exit 0`, `&`, `true || ...`,
  `if ...; then`, a second `--boundary`, `GATES_SPEC_EXEC` in the step
  env, a `workflow_call`-only trigger, GitLab `only: [tags]`,
  `except: [branches]` or workflow `rules: - when: never`, and Jenkins
  `catchError` or `try`. A step now counts only as the bare command (or
  the last line of its script), on a push or pull request trigger,
  without those variables and outside those wrappers; anything else fails
  with what to change. `verify.sh` refuses a repeated `--boundary`.
- **A hook-manager call-through counts only where it can refuse** (#202).
  husky `|| true`, `&`, `echo`, `:` or `true ||`, a lefthook `run:` with
  the call in a shell comment or excluded by `exclude_tags:`, and a
  pre-commit `entry: echo ...` all passed the static check. It now counts
  only the gates hook as a whole command whose status reaches git, and
  `--probe-git` also requires the hook git runs to exit non-zero, so it
  proves a refusal reaches git, not only that the hook was reached.
- **`pre-commit install` after projection no longer blocks every commit**
  (#201). The pre-commit framework moves the gates stub to
  `.git/hooks/<hook>.legacy` and runs it first; the stub looked for
  `.specify/gates/hooks/<hook>.legacy` and refused, while doctor and
  `--probe-git` stayed green. The stub now runs the gates `<hook>` under
  that name, `project.sh` refreshes an older moved stub, and doctor
  reports the layout: an older moved stub fails, and a double run (the
  config calls gates too) is named.
- **An unknown `--accept` feature is refused before any gate runs**
  (#179). `verify.sh --accept <name>` with a name that is not a feature
  ran the lint and quality gates first and refused only at the spec gate,
  and under `--dry-run` it was not refused at all. It is now an argument
  error, refused up front (exit 1, and the refusal object under `--json`).
- **Gate sandboxes no longer touch the caller's repository** (#173). Git
  runs hooks with `GIT_DIR` and `GIT_INDEX_FILE` set (absolute in a linked
  worktree); the canary sandboxes and accept blocks that build their own
  git repository then staged, committed, tagged and even set `core.bare`
  in the caller's repository, so no commit could be made from a linked
  worktree. The canary suite clears those variables, and accept blocks run
  without them.
- **A deletion can no longer be held** (#168). `--keep-local` on a
  deleted projected file recorded a hold, which left the hook, library or
  gate that needed it off (a missing agent hook exits 127, which Claude
  Code does not treat as a block) while doctor reported it as kept on
  purpose. Every projected file is needed by a hook, a gate, the canary
  suite or CI, so `project.sh` now refuses the hold, and a held file that
  is missing (from an older holds file) fails `project.sh`, its `--check`
  and doctor (also `--ci`), naming `--take-upstream <path>` to restore
  it. Doctor recommends `doctor.sh --canary` while files are held.
- **The lint gates no longer slow down with every file in the tree**
  (#169). Collecting the files to check started a jq process per file
  per tool, gitignored and unmatched files included, so a few thousand
  build or note files added minutes to every commit and Stop hook. Each
  tool's globs are now read once, git lists the files (tracked files
  plus untracked ones it does not ignore), and matching stays in bash.
  The same files are checked as before.
- **CI wiring checks no longer accept steps that enforce nothing** (#171).
  Doctor's CI drift check and the constitution `ci` surface took
  `echo bash .specify/gates/verify.sh ...`, `|| true`,
  `continue-on-error: true`, `--dry-run`, an earlier `exit 0`, a
  `workflow_dispatch`-only workflow, hidden, manual or `when: never`
  GitLab jobs and Jenkins `when { expression { false } }` stages as live,
  and reported a job under `if: false` or `verify.sh --boundary git` as a
  `[rec]` only. These are now not live, and a pipeline that calls
  `verify.sh` without a live `--boundary ci` step fails. What a text check
  cannot see (heredocs, wrapper scripts, computed conditions) is listed in
  how-it-works; the CI run's log is the proof.
- **Constitution `policy` markers on lists and objects work** (#171). A
  list or object value always reported `missing`, and `align` proposed
  `set ... = non-false`, which never converged. A non-empty list or object
  is now present, `expect` on a list means it contains that entry (on an
  object, that key), and proposals follow `policy.schema.json`; a marker
  no valid policy can satisfy is reported as an annotation to fix.
- **`policy.json` and the constitution are built-in agent protection**
  (#165). With jq, both hooks protected them only through
  `protected_files.extra`, so a policy with an empty or missing `extra`
  let the agent delete or rewrite them. protect-files now refuses edits to
  both and validate-bash asks before changing them, with and without jq,
  whatever `extra` says. A malformed or invalid policy makes validate-bash
  ask before any change, as protect-files does. `extra` entries are now
  matched under any spelling of the project root (`/tmp` and
  `/private/tmp`, a symlinked checkout, `../proj/...`).
- **The agent hooks catch common command variants** (#170). validate-pr
  refuses a title or body it cannot read literally (a variable, a command
  substitution other than the `cat <<'EOF'` heredoc, `-tfeat`, a repeated
  `--body`) and reads `--body=x` and unquoted words; it now also checks
  `gh api` calls on a pulls endpoint. validate-bash refuses
  `git checkout -- .`, `git restore :/`, `git clean --force` and similar
  spellings, asks for `/bin/rm`, `\rm`, brace and backslash spellings,
  `sh -c`, `eval`, `xargs rm` and interpreter one-liners on a protected
  path, and treats backticks, `xargs git add` and `cd dir; git add sub`
  as bulk staging. commit-msg exempts `fixup!`/`squash!`/`amend!` only
  before the subject of an existing commit, and the PR rules refuse
  "Made with", "Generated by" and re-spaced variants of the Claude Code
  footer.
- **Accept blocks no longer act on the repository being committed**
  (#164). The git boundary ran them with git's hook environment
  (`GIT_DIR`, `GIT_INDEX_FILE`), absolute in a linked worktree, so a
  block's `git init` in a temp directory reinitialized the main repository
  as bare and its `git add` overwrote the commit's index. Blocks now run
  without those variables.
- **`pr-check.sh` no longer passes on a broken base policy, and CI runs
  the base's copy** (#166). An invalid base policy read as an empty rule
  set, so an undeclared constitution change passed; it now fails the step
  (exit 2) and names the problem. A base with no policy (the adoption PR)
  is checked against the PR's own policy with `policy.json`, the
  constitution, `hooks.local.d` and the contract artifacts protected
  regardless. The CI templates extract `pr-check.sh` and `lib/` from the
  base revision and run them against the PR checkout through the new
  `GATES_RUNTIME_DIR`, so a PR that replaces `pr-check.sh` is still
  judged by the base's copy. Re-project the CI template to pick this up.
- **Accept blocks can no longer switch off the git boundary** (#164). The
  read-only check saw only the working tree, so a block could set
  `core.hooksPath`, rewrite a hook, commit, tag or write gitignored files
  and still pass. It now also covers git config, the hooks directory,
  `HEAD` and refs, and ignored files, naming what changed. The block's
  process group is stopped after every block, and a block that leaves a
  process running fails. `GATES_SPEC_EXEC` no longer drops the spec gate
  silently: it is reported as `skipped` with the reason, and validate-bash
  asks before a command that sets it. New `spec.snapshot_exclude` exempts
  untracked or ignored paths another process writes during the run.
- **Hook-manager wiring is checked per hook** (#167). The static check
  counted a gates call-through anywhere in any manager's config: under
  lefthook's `pre-push:` or a skipped job, in a pre-commit item staged for
  another hook, or in a stale config of a manager that does not own the
  hooks. It now reads only the owning manager's config, where it runs for
  that hook. lefthook's `pre-commit` entry now runs with nothing staged,
  so empty commits and amends on `main` are refused (an entry written
  before this is reported until it gets `files:` and `{files}`); `--wire-manager` no
  longer creates `lefthook.yml` next to a `lefthook.toml`/`.json`/`.jsonc`;
  doctor fails when a manager config calls gates but git runs no hook for
  it; `--probe-git` runs only lefthook's gates job, without `--force`; and
  a husky line after `exec <command>` or `if ...; then exit` no longer
  counts.
- **The git hooks refuse a branch whose runtime was never projected**
  (#159). In a clone that tracks `policy.json` but gitignores the runtime,
  commit-msg took the missing `.runtime-version` for a pre-0.3.4 runtime
  and let a non-conventional message through with a warning, and
  pre-commit skipped the protected-file check. Both hooks now refuse when
  `.specify/gates` is tracked and their libraries are missing, and name
  `bash .specify/extensions/gates/runtime/project.sh`. A runtime whose
  `.runtime-version` is older than 0.3.4 still commits with the warning;
  a branch from before adoption is still skipped.
- **`sync --update` no longer fails on the committer's name** (#159). A
  name the message rules refuse (a branding term, or a standalone
  "Claude") went into the `Approved-By` trailer, so commit-msg refused the
  update. The approver is now the first value the rules accept: the
  committer name, the local part of the committer email, or
  `the committer of this commit`.
- **Degraded hosts get messages that name the cause** (#122). Without jq,
  doctor reported an interrupted install because it could not read the
  registry; it now says the install state was not checked. Without
  python3, the PR-hook canary names python3 instead of calling the hook
  broken. Without git, `project.sh` says git is not installed instead of
  asking for `git init`, and doctor and `pr-check.sh` give an install
  hint. Without `sha256sum` or `shasum`, the contract canary names the
  tool instead of reporting a sandbox setup failure. Doctor now checks
  `cmp` and a SHA-256 tool, which `project.sh` needs. With a read-only
  `.specify/gates/`, `verify.sh` prints one warning that the run left no
  evidence instead of a shell `Permission denied` line, and doctor fails
  because attestations cannot be written. README "Requirements" says
  what a missing policy-enabled linter does: every boundary passes with
  that gate `[skipped]`, while doctor and the canary suite (and so a CI
  job from the templates) fail.
- **Doctor can run as a CI step** (#148). A CI checkout has no git hook
  stubs, so doctor reported the projection as not current. `doctor.sh
--ci` leaves out the git hook wiring and the git boundary section and
  runs every other check.
- **CI and test follow-ups from the 0.4.0 fixes** (#148). The GitLab
  template ran `node:22-slim`; it now runs `node:26-slim`, the major the
  GitHub template and this repository's CI use, and a parity test keeps
  them aligned. This repository's CI ran its own copy of the shellcheck
  installer with its own checksum file; it now runs the shipped
  `extension/runtime/install-shellcheck.sh` and `shellcheck.sha256`, and
  the copy is gone. `tests/test-doctor.sh` no longer fails two
  constitution cases on a host without `node_modules` (doctor now always
  runs; only the exit-code case skips), and `tests/test-hooks.sh` projects
  the runtime its PR-hook and commit-msg cases need into a fixture, so a
  fresh clone passes without projecting first. The bulk-staging docs in
  `docs/how-it-works.md` and `/speckit.gates.init` list every form the
  hook refuses.
- **The test suite passes on a host without python3** (#120). The GitLab
  "no curl" case assumed python3's `urllib` as the fallback fetcher; it
  now skips visibly without it, and a new case checks that with neither
  curl nor python3 a truncated description fails closed.
- **A fresh init no longer fails before the user does anything wrong**
  (#119). `/speckit.gates.init` installs the pinned linters before it
  projects, so the canaries no longer report a missing prettier as a
  broken gate, and the report gives the `Protected-Change` and
  `Approved-By` trailers the adoption commit needs (README "Install" says
  so too). The README upgrade steps download into a temp directory instead
  of the project root, and `policy-infer.sh` prefixes its summary with its
  own name.
- **Installing no longer warns about `policy.json`** (#118). The manifest
  declared `policy.json` as a config template, which Spec Kit 1.x refuses
  to scaffold (it keeps only `<id>-config.yml` files), so every install
  printed "Config templates not scaffolded". The policy lives at
  `.specify/gates/policy.json` and `/speckit.gates.init` seeds it; the
  manifest no longer declares a config file.
- **The CI templates install the pinned shellcheck, and Jenkins installs
  its linters** (#138). The GitHub and GitLab templates installed the
  distro shellcheck (0.9.0), which the parity gate rejects against a
  `.tool-versions` pin. They now run `.specify/gates/install-shellcheck.sh`,
  projected with the runtime, which installs the pinned version for the
  runner's OS and architecture and refuses a download that does not match
  `shellcheck.sha256` (`--update` pins another version in
  `shellcheck.local.sha256`); without a pin they fall back to the distro
  package. The Jenkins fragment ran no `npm ci` and installed nothing, so
  on a bare agent it passed having linted nothing; it now installs both.
  A new `markdown` canary proves the markdownlint gate blocks and, like
  the format and shell canaries, fails the run when the policy enables
  markdownlint but it is not installed, so every template's canary step
  is red when a policy-enabled linter is missing.
- **Accept blocks can no longer write to dirty files unnoticed or outlive
  their timeout** (#136). The read-only check compared `git status` lines,
  which do not change when a block writes to a file that is already
  modified or untracked, the usual state at the agent boundary. It now
  also hashes the content of every such file, so any write fails the block
  naming the path. Outside a git work tree a block now fails closed
  (`cannot check for mutations: not a git work tree`) instead of running
  unchecked. A timed-out block runs in its own process group, and the
  watchdog stops the whole group (TERM, then KILL), so a child process can
  no longer keep running and writing after verify has returned.
- **A PR can no longer relax the rules its own text is judged by**
  (#147). `pr-check.sh` read the message rules (AI-isms, branding,
  conventional title) from the PR head, so a commit in the PR could turn
  them off for its own title and description. With a range, they now come
  from the base's policy, like the protected-change check.
- **`pr-check.sh` can no longer be switched off by the PR it checks**
  (#123). The protected-change check read the policy from the PR head, so
  a `--no-verify` commit setting `git.protected_change_trailer` to `false`
  passed its own undeclared `policy.json` change, and it skipped merge
  commits entirely. The rules now come from the policy at the base;
  `policy.json` and `hooks.local.d/**` are always checked; and a merge
  commit is checked for the paths it changes against every parent.
- **The PR message rules refuse the agent attribution line** (#140). The
  README promised that Claude Code's default PR line is refused, but only
  its emoji was: "Generated with Claude Code", plain or as a markdown
  link, passed. PR text (the agent's PR hook and `pr-check.sh`) now
  refuses it, matching the commit-side `Co-Authored-By` rule.
- **Holds and project rules behave as documented** (#132).
  `--take-upstream` on a held file replaces it and releases the hold;
  paths with spaces or a
  leading `./` work, and naming one path for both flags is refused. The
  plan names each lost execute bit and what a wrong `.runtime-version`
  said. Doctor flags a held file whose upstream copy changed since the
  hold. A `hooks.local.d` rule that is a dangling symlink refuses, a rule
  still running after 10 seconds (`GATES_LOCAL_TIMEOUT`) is killed with
  everything it started and refuses, and a rule that ignores a large tool
  call on stdin no longer turns it into a refusal. On Linux, a tool call
  over 128 KB no longer makes every local rule refuse: it was exported into
  the rules' environment, which the kernel rejects.
- **An invalid policy no longer makes every boundary pass** (#124).
  `verify.sh` validates the policy it enforces (`policy.json`, or
  `policy.effective.json` in a contract repo) before any gate runs and
  refuses a malformed or schema-invalid one with exit 1 and the
  validator's errors, as it does a missing policy. Before, `{}`, a
  severity of `Error`, a `spec.timeout_s` of `"abc"` or an
  `attestation.max_records` of `0` silently dropped or weakened gates and
  commits landed. The Stop hook still lets the session stop and names the
  errors; protect-files asks, the format hooks format nothing, doctor
  reports `[MISSING] policy is invalid` instead of linters "not enabled",
  and `project.sh` refuses to project (exit 2). The validator now runs in
  one jq pass and also rejects what the schema already did: a hook that is
  not an object, non-array `include`/`exclude`, unknown top-level fields,
  an empty file, and more than one JSON document. `verify.sh --boundary`
  accepts only `agent`, `git` or `ci`, and `--boundary` or `--accept`
  without a value is a usage error instead of a raw bash error.
- **`sync --update` builds a branch that passes its own gates** (#135).
  The update branch moved the pin but left `extends.version` in
  `policy.json` at the old version, so the branch's pre-commit refused the
  commit ("extends declaration changed since the last sync"), the command
  exited 2 and left an empty `gates/baseline-<v>` branch that blocked
  every retry. The branch now sets `extends.version` (that value only)
  together with the three artifacts, the commit carries its own
  `Protected-Change` trailers (`Approved-By` is the git committer running
  the update), and a refused commit removes both the worktree and the
  branch. The commit body's delta now classifies every change: added
  include globs and raised severities as strengthened, added exclude globs
  and lowered severities as weakened, hooks added or removed as one line
  each. Turning off `git.block_main_commits`, `protected_change_trailer`,
  `conventional_commits`, `forbid_ai_isms` or `block_bulk_staging` is a
  weakened deviation, and `hooks.<name>: null` is one "removed" deviation
  instead of one per field. An overlay that is only `extends`, or a hook
  overlay that sets only the fields it changes, is accepted: the overlay
  is checked for shape and values, the merged effective policy strictly.
  A non-object hook entry is now named instead of silently skipping the
  validation of every hook. `propose` keeps the upstream file's key order
  and indentation, so the proposal diff shows only the deviating values.
- **The policy-contract artifacts are protected files** (#137).
  `baseline.json`, `baseline.lock.json` and `policy.effective.json` decide
  what is enforced, like `policy.json`, but nothing protected them: a
  consistent hand edit (lock digest and effective policy recomputed) passed
  pre-commit, the contract gate, `pr-check` and doctor. All three are now
  built-in protected paths: the agent cannot write them, a Bash command
  that appears to modify one asks, and a commit that changes one needs
  `Protected-Change` and `Approved-By` trailers, checked again by
  `pr-check`. Commit a sync with one `Protected-Change` line per artifact.
- **`sync --update` commits when the delta touches branding terms, and in
  repos with the trailer rule off** (#154). The commit body quoted the
  changed values, so a baseline adding "Copilot" to
  `git.ai_branding.terms` (or any value holding an AI-ism or a
  `Co-Authored-By:` line) made the branch's commit-msg refuse the update.
  Delta lines now name the path with a summary instead of values (`2
added, 1 removed` for lists, `from -> to` for booleans, numbers and
  severities, `value changed` for text); a message that still trips the
  rules falls back to counts only. With `git.protected_change_trailer:
false`, pre-commit refused the protected artifacts outright; it now
  lets through exactly the update commit (on `gates/baseline-<v>`,
  `policy.json` changing `extends.version` alone plus the three
  artifacts, consistent with the pin), and the update always carries
  the `Protected-Change` trailers that `pr-check` requires.
- **Checks no longer miss matches on large input** (#117). Under
  `pipefail`, `echo "$x" | grep -q` read a match as a miss once the input
  outgrew the pipe buffer, so the pre-commit secret scan let a key through
  in any staged file over 64 KB (since v0.1.0), and a large commit touching
  a protected path could not be committed at all. Every such check now
  reads from a here-string, and a package test refuses the pipe form.
  Under the stock macOS bash 3.2 the commit-message checks also no longer
  hang on long messages, and the agent hooks without jq ask on a command
  too long to decode instead of stalling.
- **Commented-out CI steps no longer count as wiring** (#139). Doctor's
  CI drift check and the constitution `ci` surface read a pipeline without
  its comments (`#` in YAML, `//` and `/* */` in a Jenkinsfile) and
  without GitHub steps or jobs under `if: false`, so `# - bash
.specify/gates/canary.sh` or `run: "true"  # bash ...` is a missing
  step. A `ci` principle is enforced only by a pipeline with a live
  `verify.sh --boundary ci` step, plus the named step for `ref=gates`,
  `canary` or `pr` (any other ref must appear in that pipeline), not by
  the word anywhere in a workflow. A `ci:<step>` hold for a step the
  pipeline runs is now a stale hold that fails, and an unknown id gets a
  recommendation to remove it. Policy refs resolve as full dotted paths
  (`hooks.markdownlint.severity`; `markdownlint.severity` still means the
  hook key), and `align` proposes the full path.
- **The format hooks no longer format without a policy** (#111). When
  `policy.json` is missing or the policy loader cannot load, post-edit and
  format-changed print one line saying so and format nothing, instead of
  formatting with no exclude lists under a "legacy mode" notice that
  promised removal at v0.2.0.
- **`on_missing_runner` and `on_missing_tests` are marked deprecated**
  (#112). No gate has read them since the per-language walk was removed.
  They still validate, so existing policies keep working; the schema marks
  them deprecated and doctor recommends removing them.
- **Only `###` headings under `## Core Principles` are principles** (#82).
  Sub-headings under Additional Constraints, Governance and other sections
  are no longer reported as unannotated principles. A `gates:enforce`
  marker outside Core Principles is now malformed (doctor and
  `constitution.sh check` fail and name the line), and a constitution
  without the section is reported as declaring no principles.
- **Branches from before adoption can commit again** (#125). The git hook
  stub treated the `.specify/gates` directory as proof of adoption, but the
  gitignored `attestations.jsonl` survives a branch switch, so every commit
  on an older branch was refused for a missing hook. The stub now asks git
  whether anything under `.specify/gates` is tracked, in `HEAD` or in the
  index.
- **Commit hooks handle empty commits, merges and fixups** (#129). An
  empty or delete-only commit on `main` skipped `git.block_main_commits`,
  because pre-commit exited on "nothing staged" before the branch check; the
  check now comes first. A merge commit (recognized by `MERGE_HEAD`) and
  `fixup!`, `squash!` and `amend!` subjects skip the Conventional Commits
  rule, so `git merge --no-edit` and `git commit --fixup` work; every other
  message rule still applies. A merge needs a `Protected-Change` trailer only
  for a protected path that differs from every merged parent. An amend that
  drops a commit's trailers is caught by `pr-check.sh`, and `git revert`
  runs no commit hooks; both are now documented as covered in CI.
- **The git hooks are fast on large commits** (#133). Protected-path
  matching forked a `basename` per staged path and pattern, and the secret
  scan ran one `git show` plus six `grep` processes per file, so a
  1500-file commit took tens of seconds per hook. Matching now runs in one
  pass without subprocesses, and the scan reads the staged content with one
  `git grep --cached` per rule. Same rules, same one-line-per-file report.
  File names with spaces are now scanned as one file (they were split into
  words and skipped), and a scan that cannot read the index refuses the
  commit instead of passing it.

- **The file and command hooks never silently allow** (#83). Without jq,
  or for input that isn't valid JSON, `protect-files.sh` and
  `validate-bash.sh` read the path or command in raw mode, and every
  built-in block rule still applies. When a hook can't decide, it returns
  a PreToolUse "ask", so you confirm the call. That covers
  `protected_files.extra` without jq, an unparseable `policy.json`, a
  policy library that won't load, an encoded command, a missing
  grep/sed/tr, and an internal error. They used to allow everything in
  those states. A benign command is still allowed without jq, so the
  agent can install it. Doctor keeps failing until jq is installed, and
  the `bash` and `protect` canaries now also run without jq.
- **The Bash hook catches more ways around its checks** (#130). A project
  rule in `hooks.local.d/validate-bash` now runs before a shipped "ask",
  so its refusal wins. A protected path changed through a parent
  directory (`rm -rf .specify/gates`, `find … -delete`), after a `cd` or
  `git -C` into one, or spelled with `./`, `//`, `/./`, `"$PWD"`, the
  absolute project path or other letter case now asks. Under
  `git.block_bulk_staging`, `git stage`, `env`/`command`/`GIT_DIR=…`
  prefixes, `git --no-pager add`, quoted or escaped directory names,
  `"$PWD"`, quoted globs and pathspec magic (`':(top)'`) are refused, and
  an argument the check cannot resolve asks. A command that names a
  secret file the file hook refuses (`cat .env`) asks, and so do hook
  bypasses (`--no-verify`, `git commit -n`, a `core.hooksPath` setting).
  `git.ai_branding.allow_phrases` now ignore case, as the terms always
  did.
- **A missing jq or git no longer lets a violation through** (#121).
  `pr-check.sh` without jq read an empty protected list and passed an
  undeclared protected change; it now exits 2 and names the missing tool.
  `verify.sh` without git skipped the spec gate's check that an accept
  block left the tree unchanged; it now refuses (exit 1, as without jq).
  Without jq, the Bash hook now checks `policy.json` and the constitution
  as well as the project's rules, reads a plain `protected_files.extra`
  list, and asks on any change when it cannot read that list. It also
  asks, instead of guessing, when the input holds more than one `command`
  field or none. The README now says plainly that the Stop hook lets the
  session end when `verify.sh` cannot run, and what still enforces.
- **The file hook sees through path spellings** (#131). `protect-files.sh`
  matched the raw path, so `.specify/gates/./policy.json`,
  `.specify//gates/policy.json`, `.specify/gates/lib/../policy.json` and,
  on case-insensitive APFS, `.specify/gates/POLICY.json`, `.ENV` or
  `Package-Lock.json` were written. It now resolves `.`, `..` and `//`
  before matching, makes a path under the project relative to it, and
  compares ignoring case.
- **Generated hook files no longer fail the lint gates** (#126). With
  husky v9 every commit failed: the shellcheck gate linted husky's
  generated, gitignored `.husky/_/husky.sh`, which CI never sees. The
  `none` orchestrator now skips untracked files git ignores, so the local
  gates check what CI checks; a tracked file is still checked when an
  ignore pattern matches it. New policies also seed `.husky/_/**` in
  `shellcheck.exclude`.
- **`doctor --probe-git` works with the pre-commit framework and
  lefthook** (#127). The probe passed the message file to both hooks, and
  the pre-commit framework's `pre-commit` hook refuses any argument; now
  only `commit-msg` gets it. lefthook skips its jobs while nothing is
  staged, so the probe calls its hook with `--force`. A skip that still
  happens is reported as such instead of "no probe answer".
- **Hook-manager wiring no longer breaks configs or reports a dead
  call-through as wired** (#128). `--wire-manager` treats a quoted
  lefthook key (`"pre-commit":`) as an existing block instead of adding a
  duplicate, prints the pre-commit item instead of appending it when
  `repos:` is a flow list (`repos: []`), and no longer appends to a husky
  script with a top-level `exit`. The static check (doctor and
  `project.sh`) ignores commented lines and lines after a top-level
  `exit`, and the printed call-through says to put it before any `exit`.
  The summary lists only entries actually appended, and the by-hand text
  says to merge into an existing block. Doctor's hook check reports a
  hook as delegating only when it calls `.specify/gates/hooks/<name>`, not
  when it mentions "gates". The full `doctor.sh` on a dormant install now
  fails and says the runtime is not projected, instead of reporting the
  policy's linters as not enabled.
- **A local `git merge` runs the pre-commit checks** (#148). git runs
  `pre-merge-commit` and `commit-msg` for a merge commit, never
  `pre-commit`, so a merge into `main` skipped the protected-branch block
  and the secret scan. The stub is now installed as `pre-merge-commit`
  too, and the projected `pre-merge-commit` hook runs the pre-commit
  checks. A branch whose runtime predates it falls back to its
  `pre-commit` hook. `--wire-manager` adds the entry for husky, lefthook
  and the pre-commit framework, and doctor says when git is older than
  2.24, which never calls the hook.
- **protect-files asks when raw mode cannot tell which file is edited**
  (#148). Without jq, an input with two `file_path` keys was judged by the
  last one and an input with none was allowed. Both now ask, as
  validate-bash does for its command.
- **`--wire-manager` reports a hook awaiting its install command as
  pending** (#148). After adding a lefthook or pre-commit framework entry,
  `project.sh` probed `.git/hooks/<hook>`, which only that tool's install
  command creates, and printed `FAILED: git probe: ... does not exist`. It
  now says the hook is pending until `lefthook install` or
  `pre-commit install --hook-type <hook>` runs (exit 1: wiring needs the
  maintainer), and doctor names that command until the hook exists.
- **husky 8 hooks created by `--wire-manager` run, and the shellcheck pins
  stay in the project** (#159). Under husky 8 (`core.hooksPath=.husky`)
  git runs `.husky/<hook>` itself, and `--wire-manager` created that
  script without the execute bit, so git skipped it while `project.sh`'s
  static check passed. A created script is now executable; an existing
  one without the bit keeps its mode, and the git check fails naming the
  `chmod +x` fix. `install-shellcheck.sh --update` wrote
  `shellcheck.local.sha256` next to itself, which in the spec-gates
  source tree is the packaging source `extension/runtime/`; it now always
  writes the project's `.specify/gates/shellcheck.local.sha256`, with the
  project root taken from the script's own work tree, not the working
  directory. CONTRIBUTING.md describes how a maintainer bumps the shipped
  pin. The coverage CI job installs the pinned, checksum-verified
  shellcheck instead of the distro package.
- **Small RC2 findings** (#172). `verify.sh --json` prints one
  `{"result":"refused",...}` object when it refuses to run (bad
  arguments, no jq or git, a missing or invalid policy) instead of
  nothing. `policy-infer` reports the synthesized policy only after
  writing it and exits 5 when the write fails. `install-shellcheck.sh`
  takes an unknown flag as a usage error, not an install directory. The
  contract gate names a missing SHA-256 tool instead of claiming
  tampering; doctor without jq no longer lists every linter as "not
  enabled" and says that no gate runs; canary without git names git;
  `project.sh --check` exits 1 when git is missing. The commit that turns
  `git.protected_change_trailer` off passes with its trailers. In
  `sync --update`, the update commit's gate sees the project's
  `node_modules`, added `ai_branding.terms` count as strengthened,
  `_`-prefixed keys are not an enforcement delta, and no `Source:` line
  exceeds 100 characters. The release workflow probes the git hooks and
  the shellcheck installer.
- **Small install findings** (#203). doctor refuses an unknown option
  (exit 2) instead of running a plain check, and takes its options in any
  order; `--canary` passes the rest to `canary.sh` and refuses doctor's
  own options. `project.sh --check` now fails, as the full run does, on a
  hook manager whose hooks were never installed, and both fail on a stale
  hold. A held file emptied to 0 bytes is treated like a held deletion. A
  repository git refuses for dubious ownership is named as such, with the
  `safe.directory` fix, and fails. Under lefthook adopted after the gates
  stubs, `project.sh` names the hooks whose stub still runs apart from
  those that run no gates. For a 0.3.x projection, which has no
  `.specify/gates/project.sh`, the half-done-upgrade advice names the add
  command. `install-shellcheck.sh --update` cannot pin releases before
  v0.11.0 (they carry no GitHub digests); this limit is documented, and
  the refusal names the by-hand pin file.

## 0.3.6 — 2026-10-02

### Fixed

- **The PR hook fails closed** once a command is recognized as a PR
  command (`gh pr create|edit`, `glab mr create|update`). A missing jq,
  missing python3 (with `json`), a missing runtime, invalid input, or an
  internal error now blocks the command instead of letting it through
  unchecked (#66).
- **A `--body-file` the PR hook can't read is refused.** That covers stdin
  (`-`) and a file created later in the same command. A leading `~`, `$VAR`
  or `${VAR}` is resolved from the hook's environment first (#65).
- **The emoji rule falls back to perl** when python3 is missing. It refuses
  the message only when neither is usable; it used to skip silently (#66).
- **GitLab: `pr-check.sh` checks the full MR description.** When GitLab
  truncates it, or doesn't expose it (before 16.7), pr-check fetches the
  full text from the API with `GATES_GITLAB_TOKEN` or `CI_JOB_TOKEN`. A
  truncated description it can't fetch fails the job (#67).
- **GitLab: the description fetch works without curl.** It falls back to
  python3's `urllib`, and the GitLab template installs curl. Slim CI images
  have no curl, so a truncated description could never be fetched there.
- **The `rm` guard is narrowed to real root, home and system-path deletes.**
  `echo brainstorm /` and `rm -rf /tmp/<dir>` are no longer blocked. Root
  as a later argument (`rm -rf ./build /`) now is (#68).
- `.specify/gates/attestations.jsonl` is gitignored, as documented: init
  and upgrade write `.specify/gates/.gitignore` while projecting, so the
  entry lands in the upgrade commit, and the runtime adds it on any later
  run that finds it missing (#69).

### Added

- doctor lists python3 (`json`, `re`) as required, and python3 or perl for
  the emoji rule (#66).
- Releases publish `SHA256SUMS`, which works behind proxies such as
  Artifactory that treat a `.sha256` suffix as a checksum query. The ZIP
  ships this `CHANGELOG.md` (#69).

## 0.3.5 — 2026-10-02

### Fixed

- **macOS:** `validate-pr.sh` parses under the stock `/bin/bash` 3.2 again.
  In 0.3.4, every agent `gh pr create` or `gh pr edit` on a Mac was blocked
  with `syntax error near unexpected token` (#63).

### Added

- Tests and canaries run hooks by path, through their shebang, as Claude
  Code and git do.
- A new `prhook` canary requires a clean PR to be allowed and a bad one
  refused (12 canaries).
- A bash 3.2 parse check, and a macOS CI job.

## 0.3.4 — 2026-10-01 (withdrawn)

Withdrawn because of the macOS defect fixed in 0.3.5; its assets have been
removed. Everything below ships in 0.3.5.

### Added

- **Protected files commit through the git boundary with trailers**: one
  `Protected-Change: <path>` per staged protected path, plus
  `Approved-By: <name>` (#47). The trailer is a self-attested declaration;
  real approval needs CODEOWNERS plus branch protection. New key:
  `git.protected_change_trailer`, **default `true`**. Set `false` to keep
  refusing protected files outright.
- **Configurable AI-branding rule** (#52). New keys:
  `git.ai_branding.terms` (default: Anthropic, GPT, OpenAI, Copilot) and
  `git.ai_branding.allow_phrases`. Note that the default refuses Claude
  Code's `Co-Authored-By: … <noreply@anthropic.com>` attribution.
- **PR/MR text** goes through the commit-message rules at every boundary,
  via the shared `lib/message.sh`. `validate-pr.sh` covers `--body-file`,
  `gh pr edit` and `glab mr` (#56).
- **`pr-check.sh`**, a new CI step: it checks the PR/MR title and
  description, and re-checks Protected-Change declarations across the PR's
  commits, including declarations in the description (#53). Re-run
  `/speckit.gates.ci` to add it.
- **Git hooks are installed as stubs** that run the checked-out branch's
  `.specify/gates/hooks/<name>` (#59). Upgrade replaces copied hooks.
- New canaries: `credential`, `protected`, `branding` and `pr`.
- **Runtime dependency:** python3 (with `json`) for the PR hook.

### Changed

- **Hardened CI templates:** read-only token, no persisted credentials,
  concurrency, timeouts, and `npm ci` from the lockfile.
  `/speckit.gates.ci` merges into an existing pipeline (#62).
- Linked worktrees resolve the shared hooks directory everywhere.

### Fixed

- The secret scan no longer flags the runtime itself (#50).
- commit-msg ignores editor comments and the scissors section.
- Branches on an older runtime stay committable under newer hooks (#60).

## 0.3.3 — 2026-07-26

### Fixed

- Projected and vendored files stay out of a consumer's own lint scope
  (#44).
