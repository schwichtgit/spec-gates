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

- **Installing no longer warns about `policy.json`** (#118). The manifest
  declared `policy.json` as a config template, which Spec Kit 1.x refuses
  to scaffold (it keeps only `<id>-config.yml` files), so every install
  printed "Config templates not scaffolded". The policy lives at
  `.specify/gates/policy.json` and `/speckit.gates.init` seeds it; the
  manifest no longer declares a config file.
- **Checks no longer miss matches on large input** (#117). Under
  `pipefail`, `echo "$x" | grep -q` read a match as a miss once the input
  outgrew the pipe buffer, so the pre-commit secret scan let a key through
  in any staged file over 64 KB (since v0.1.0), and a large commit touching
  a protected path could not be committed at all. Every such check now
  reads from a here-string, and a package test refuses the pipe form.
  Under the stock macOS bash 3.2 the commit-message checks also no longer
  hang on long messages, and the agent hooks without jq ask on a command
  too long to decode instead of stalling.
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
