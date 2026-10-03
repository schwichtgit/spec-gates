# Research: Upgrade-Safe Projection

Facts below were checked on 2026-10-02 against Spec Kit 1.0.13, git 2.54,
husky 9, and lefthook (npm), in scratch sandboxes, not recalled.

## R1. How the projection step runs (#72, FR-001..FR-003)

**Decision**: ship `runtime/project.sh`, a non-interactive bash 3.2 script
that does the whole projection. It is also projected into
`.specify/gates/project.sh`. Canonical invocation:
`bash .specify/extensions/gates/runtime/project.sh` (source = its own
directory). Decisions the agent used to ask about become flags, so the
agent shows a `--dry-run`, asks the maintainer, and re-runs with flags:
one approval per decision, not per file.

Half-done remove+add (FR-003): after `extension remove`, the vendored
directory and the gates skills are gone, so only the projected copy can
speak. Run from `.specify/gates/` (no vendored source next to it), the
script reports "extension removed but not re-added" plus the
`specify extension add gates --from <url>` command, and exits 2 without
writing. Run from the vendored copy, it refuses when `.registry` lists no
`gates` entry or a version different from the vendored `extension.yml`.
Doctor reports the same states.

**Rationale**: a downstream classifier refused the agent's many-file
projection ("Untrusted Code Integration"); one reviewable script is one
approval. Spec Kit 1.0.13 `extension add` has `--from/--dev/--force/
--priority` and no `--yes` or checksum check; `remove` has
`--keep-config/--force`. The pair is therefore not atomic.

**Alternatives**: keep projection in the command prose (status quo,
refused downstream); a Spec Kit `after_install` hook (none exists in
1.0.13).

## R2. Canned self-test probes (#72, FR-004, FR-005)

**Decision**: no new probe script. `canary.sh` already builds every
payload internally and runs the projected hooks. The live validate-bash
hook only sees `bash .specify/gates/canary.sh`. Init self-test steps 2–3
become `canary.sh --only bash,protect`; init and `project.sh` run the full
suite and fail on any accepted canary.

**Rationale**: the step 6.3 probe failed because its command line carried
`rm -rf /` text, which the live hook refuses. Canary payloads never appear
on the command line.

## R3. Exec bits on vendored files (FR-005a)

**Finding**: Spec Kit's zip extraction keeps the execute bit only on
`*.sh` files. The release zip has `+x` on `hooks/git/commit-msg` and
`pre-commit`, but extraction leaves them 644 (reproduced). Repos that
commit `.specify/extensions/` then show a 100755→100644 mode change.

**Decision**: `project.sh` re-applies `chmod +x` to the vendored scripts
and git hooks, and doctor reports a vendored script without the bit.

**Alternatives**: rename the sources to `pre-commit.sh`/`commit-msg.sh`
and project them under the hook names. Rejected: it fixes only this
extraction quirk, and touches the stub contract, canaries, tests and
every doc path for a cosmetic mode diff. The projected copies, which are
what git runs, are already chmod'ed.

## R4. Manifest and first upgrade from 0.3.x (#70, FR-007, FR-008, FR-011)

**Decision**: `.specify/gates/.projected.sha256` in `sha256sum` format,
with a header line `# spec-gates-manifest v1 version=<X.Y.Z>`. It is
written after every successful projection. Hashing uses `sha256sum`, else
`shasum -a 256`, else fail closed.

For projects with no manifest (every 0.3.x consumer), ship
`runtime/lib/known-releases.sha256` (`<version>\t<sha256>\t<projected
path>`), generated from the release tags v0.3.0..v0.3.6 by
`scripts/known-releases.sh`. A file whose content any of those releases
shipped at that path is pristine (safe to replace); matching any version,
not only `.runtime-version`, answers the real question (was it edited?)
and also covers a missing or stale marker. Only a real deviation is a
conflict. The table covers v0.3.x only: 0.4.0 and later always write a
manifest, so releases never need adding. A test rebuilds the table from
the tags and fails if the committed copy differs.

Per-file classification: `absent` → write; `pristine` (matches manifest
or known hash) → replace; `upstream` (already equal) → no-op; `edited` →
conflict; `held` → skip and report; `local` (under `hooks.local.d/`) →
never visited. A conflict exits 3 and lists the files with
`--take-upstream <path>` / `--keep-local <path>`. `--keep-local` appends
the path to `.upgrade-holds`. A deleted projected file counts as `edited`.
A corrupt manifest or one with a future version exits 2 and is never
overwritten blindly.

**Rationale**: without the table, every file differs between 0.3.6 and
0.4.0, so the first upgrade would make every file a conflict.

## R5. Holds (#70, FR-009)

**Decision**: `.specify/gates/.upgrade-holds`, one project-relative path
per line, `#` comments allowed. Doctor lists each hold; a hold whose file
equals the vendored upstream copy is stale and fails. A `ci:<step-id>` line
acknowledges a deliberately omitted CI step (R6). A hold inside
`hooks.local.d/` is reported as redundant.

## R6. CI-template drift (#70, FR-010)

**Decision**: detect by command signature, not by YAML structure.
`gates_ci_steps` in `lib/manifest.sh` lists `<step-id>\t<regex>`:
`gates` → `verify\.sh --boundary ci`, `canary` → `canary\.sh`, `pr` →
`pr-check\.sh`. It lives in the projected library, not a `ci/` data file,
so the projected doctor can judge drift without the installed extension.
The pipeline is every file among `.github/workflows/*.y*ml`,
`.gitlab-ci.yml`, `*.gitlab-ci.yml` and `Jenkinsfile*` that runs the
`gates` step; each other signature missing from their union is reported. Doctor **fails** on a missing step unless `.upgrade-holds`
has `ci:<step-id>`. No pipeline at all is informational.

**Rationale**: a missing PR-check step is an enforcement gap (principle
I). Signatures also work on 0.3.x pipelines adapted by hand and across all
three platforms, with no YAML parser.

## R7. Local extension point (#71, FR-012, FR-013)

**Decision**: `.specify/gates/hooks.local.d/<hook>/*.sh`, where `<hook>`
is one of `protect-files`, `validate-bash`, `validate-pr`, `pre-commit`,
`commit-msg`. They run in lexical order through `bash` (exec bits don't
matter), only after the shipped checks allow. They get the same stdin
(agent hooks) or arguments (git hooks). Any non-zero exit refuses, with
the script's stderr. A local rule can only add refusals: it never runs
when the shipped check refused, and it can't turn a refusal into an allow.
A local script that can't be read fails closed. Projection, upgrade, the
manifest and doctor's edit check never visit the directory.

## R8. Bulk-staging knob (#71, FR-014)

**Decision**: `git.block_bulk_staging` (boolean, default `false`) in the
schema. With it on, validate-bash refuses `git add` with `-A`, `--all`,
`.`, `:/`, `*`, or any argument ending in `/` or naming an existing
directory (resolved against the payload `cwd`). `-u`, `-p` and explicit
files stay allowed. The rule applies at the **agent boundary only**:
pre-commit sees the index, not how it was filled, so the git boundary
cannot detect bulk staging. The contract says so plainly.

## R9. protect-files split (#71, FR-015)

**Decision**: hard block stays for `.env`/`.env.*`, SSH key names, `*.pem
*.key *.crt *.p12 *.pfx *.jks *.keystore`, exact credential names
(`credentials`, `credentials.json`, `aws-credentials`, `.netrc`,
`.pypirc`, `service-account*.json`, `gcloud-*.json`), sensitive
directories, lock files, and `protected_files.extra`. A basename that
merely contains `credentials|secret|password|token|keystore` gets a
PreToolUse `ask` decision (shape verified in R14). The git boundary is
unchanged (exact names).

## R10. Agent hooks never silently allow (#83, FR-028)

**Decision** (revised with Frank, 2026-10-02): block what is known to be
risky, ask when uncertain, allow what is benign. Never lock the agent out.

- **jq present, payload parses**: unchanged full check.
- **No jq, or the payload does not parse (raw mode)**:
  - validate-bash runs its block patterns over the raw stdin, with `\"`
    and `\\` unescaped first. The raw text contains the command, so this
    can only over-match (for example a pattern inside a description
    field), never miss. A match blocks (exit 2). No match allows, with a
    stderr warning that names doctor.
  - protect-files extracts `file_path` with a POSIX sed expression and
    applies the built-in name rules (block on a match).
    `protected_files.extra` globs cannot be evaluated without jq: when
    `policy.json` declares a non-empty `extra` (grep), the hook returns
    `ask`; with none it allows, with the warning.
- **Uncertain states return `ask`** (static JSON via printf, no jq
  needed): an internal error (the `ERR` trap), a `file_path` that can't
  be extracted, a policy library that exists but fails to load. Exit 2 is
  reserved for a positive block match.
- Doctor and canary keep failing while jq is missing (jq stays a required
  tool), so degraded mode is never silent.

**Rationale**: the first draft refused every call without jq. Every Bash
call blocked meant the agent couldn't even install jq. Raw mode keeps
every built-in block rule in force, and `ask` puts a human on exactly the
calls the hook can't judge. "ask" escalates in every permission mode
(R14), so this is not a bypass.

**Alternatives**: refuse everything (lockout, rejected); a python3
fallback parser (a second dependency and a second escaping surface, for
no gain over raw matching plus ask); keep the silent allow (violates
principle I).

## R11. Constitution parser scope (#82, FR-016)

**Decision**: `gates_const_parse` tracks the current `##` section. `###`
opens a principle only inside `## Core Principles`. A `gates:enforce`
marker elsewhere is `MALFORMED` ("marker outside Core Principles"). A
constitution without that section yields zero principles plus a notice.
The writer side (`lib/constitution.sh` ~l.500) already scopes this way.

## R12. Install hygiene (#73, FR-017..FR-019)

**Findings**: a `--dev` install makes each
`.claude/skills/speckit-gates-*/SKILL.md` a symlink into
`.specify/extensions/gates/.specify-dev/agent-commands/claude/...`. A zip
install writes regular files. `.registry` records `source: local` for
both, so only `.specify-dev/` tells them apart. Vendored files already
pass default prettier (`prettier --check` clean); the reports came from
repos with non-default configs that no shipped style can satisfy.

**Decision**: doctor iterates `registered_commands.claude[]` and maps
`speckit.gates.x` to `.claude/skills/speckit-gates-x/SKILL.md`. It fails
on a symlink (`-L`) or a non-file (`! -f`). The `.specify-dev/` directory
triggers a warning in doctor and `project.sh`. A package test asserts
default-prettier cleanliness. `project.sh` reports missing
`.prettierignore`/markdownlint ignores and adds them only with
`--add-lint-ignores`, never through a policy change.

## R13. Hook managers and the behavioral probe (#74, FR-022, FR-022a)

**Findings** (sandboxed): husky 9 sets `core.hooksPath=.husky/_`, a
generated, gitignored shim directory. The user-owned hooks are
`.husky/<name>`. lefthook writes generated scripts into the hooks
directory, which `lefthook install` rewrites; the user-owned file is
`lefthook.yml`. The pre-commit framework generates `.git/hooks/pre-commit`
("File generated by pre-commit"); the user-owned file is
`.pre-commit-config.yaml`, where a `repo: local` hook goes. Today's init
appends call-throughs into the generated files, which are lost on the
next install.

**Decision**: detection order is `core.hooksPath` + `.husky/`, then
`lefthook.yml`, then the pre-commit marker, then any other non-stub hook
(unknown). `project.sh --dry-run` prints the entry for the manager's
user-owned file; `--wire-manager` applies it. Edits are append-only: a
line in `.husky/<name>`; for YAML, a new top-level block only when the
hook key is absent, otherwise the snippet is printed and the script exits

1. An unknown manager always gets the printed call-through and exit 1.

Probe: the projected `pre-commit` and `commit-msg` honor `GATES_PROBE=1`
by printing `gates-probe:<name>:<runtime-version>` and exiting 1. This
happens before any policy read, so the probe works with every rule turned
off. It can only cause a refusal, so it opens no bypass. Doctor and
`project.sh` run the hook git resolves (`git rev-parse --git-path
hooks`/`<name>`, executed directly) with `GATES_PROBE=1`. They fail
unless the marker appears, which proves the call chain reaches gates
through any manager.

## R14. PreToolUse "ask" output

**Verified** (code.claude.com/docs/en/hooks.md, 2026-10-02): the hook prints
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"..."}}`
on stdout and exits 0. Exit 2 still blocks. "ask" escalates to the user in
every permission mode. Valid decisions are `allow|deny|ask|defer`.

## R15. Policy defaults reach consumers (#74, FR-020, FR-021)

**Decision**: the branding default is unchanged (clarified). Its refusal
message names `git.ai_branding.allow_phrases`, and the README documents
the agent attribution case. `project.sh` compares `policy.json` against
the schema's defaulted properties and prints a notice for each absent one
(e.g. `git.block_bulk_staging`), pointing at the propose flow. It never
writes `policy.json`.

## R16. doctor --installed-only (#74, FR-023)

**Decision**: runs only the install sections: registry entry, vendored
version, skills (R12), vendored exec bits (R3), dev-install warning. It
skips every section that needs `.specify/gates/`. Since doctor lives in
`.specify/gates/` once projected, the canonical dormant invocation is
`bash .specify/extensions/gates/runtime/doctor.sh --installed-only`.

## Not done

- The plan template's "update agent context" step: this repo has no
  agent-context script under `.specify/scripts/bash/`, so it is skipped.
- Spec Kit CLI gaps (no `--yes`, non-atomic remove+add, mode loss,
  `--from` local paths) are mitigated on the gates side (R1, R3) only.
