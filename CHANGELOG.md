<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

User-visible changes to the spec-gates extension. Each release lists new
behavior, changed defaults, and anything an upgrade requires. Upgrading
never touches `.specify/gates/policy.json`. New policy keys take the
defaults stated here until you set them. Releases before 0.3.3 are
described in their [GitHub release notes](https://github.com/schwichtgit/spec-gates/releases).

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
- `.specify/gates/attestations.jsonl` is gitignored, as documented: the
  runtime writes `.specify/gates/.gitignore` (#69).

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
