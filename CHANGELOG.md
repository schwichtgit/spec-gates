<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

User-visible changes to the spec-gates extension. Each release lists new
behavior, changed defaults, and anything an upgrade requires. Upgrading
never touches `.specify/gates/policy.json`. New policy keys take the
defaults stated here until you set them. Releases before 0.3.3 are
described in their [GitHub release notes](https://github.com/schwichtgit/spec-gates/releases).

## [Unreleased]

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
  `--take-upstream` on a held file replaces it and releases the hold; a
  deleted projected file can be held as deleted; paths with spaces or a
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
