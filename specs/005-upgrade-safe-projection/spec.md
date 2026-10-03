# Feature Specification: Upgrade-Safe Projection

**Feature Branch**: `005-upgrade-safe-projection`

**Created**: 2026-10-02

**Status**: Draft

## Clarifications

### Session 2026-10-02

- Q: Branding default for a provider name outside an attribution
  position? → A: Keep blocking everywhere; document the allow_phrases
  override and the agent attribution case, and name the override in the
  refusal message.
- Q: Another hook manager detected? → A: (revised the same day) Manager
  adapters plus a behavioral check. For husky, lefthook, and the
  pre-commit framework, show the exact entry for that manager's own
  user-owned configuration and apply it only on an approved diff; never
  edit a manager's generated hook files. For an unknown or custom
  framework, refuse and print the call-through. Doctor and the
  projection script prove the effective hook refuses a probe, regardless
  of which manager owns it. (Today's init appends the call-through into
  whatever file sits in the hooks directory, which for husky and lefthook
  is regenerated and silently loses the call-through.)
- Q: A `gates:enforce` marker outside Core Principles? → A: MALFORMED
  (fail), since an enforcement claim that is never checked is the
  silent-no-op class.

**Input**: User description: "Feature 005 upgrade-safe projection for
spec-gates 0.4.0: remediate every known open issue (#72, #70, #71, #82, #73,
and #74; #83 was added during planning) plus gates-side mitigations for
spec-kit CLI gaps. One user-story group per issue, in priority order,
each independently shippable as its own PR with its own accept block." (Full description in
the 0.4.0 milestone and issues #70–#74, #82.)

## User Scenarios & Testing _(mandatory)_

### User Story 1 - One reviewable step projects or upgrades the runtime (Priority: P1) — #72

A maintainer installs or upgrades spec-gates. Today the agent projects the
runtime as dozens of separate file writes, which downstream permission
classifiers refuse, so the maintainer ends up copying files by hand; the
self-test skips the canaries, so a broken PR hook first surfaces in CI;
and consumers improvise three different upgrade paths. After this story,
one shipped script does the whole projection (runtime copy, execute bits,
agent settings merge, git hook install, manifest write) and runs the
canaries, one canned probe proves each boundary from inside the agent, and
the README and upgrade command document exactly one upgrade path.

**Why this priority**: every other story builds on the projection step: the
manifest (US2), the preserved local directory (US3), and the install
checks (US5) are all written or honored by it. It also removes the
largest rollout cost reported for 0.3.5.

**Independent Test**: in a fixture project with the extension installed and
nothing projected, run the projection script once; verify the runtime,
hooks and settings are in place with execute bits, the canaries ran and
all blocked, and a second run changes nothing. Then run the documented
upgrade path against a release-shaped zip and verify it ends in the same
state.

**Acceptance Scenarios**:

1. **Given** an installed extension and no projected runtime, **When** the
   maintainer runs the projection script, **Then** the runtime, agent
   hooks, settings merge, and git hooks are in place, every projected
   script is executable, and the canary run reports all canaries blocked.
2. **Given** a completed projection, **When** the script runs again with
   the same extension version, **Then** it reports "no changes" and leaves
   every file byte-identical.
3. **Given** the extension was removed but the new version not yet added
   (an interrupted remove+add), **When** the projection script runs,
   **Then** it stops with a non-zero exit, names the half-done state, and
   prints the command to finish the upgrade, without touching the
   projected runtime.
4. **Given** a live agent session with the validate-bash hook active,
   **When** the maintainer runs the canned self-test probe, **Then** each
   boundary probe reports blocked or passed without the live hook refusing
   the probe invocation itself.
5. **Given** a canary fails during projection, **When** the script
   finishes, **Then** it exits non-zero and names the failing canary.
6. **Given** the README and upgrade command, **When** a maintainer follows
   the upgrade section, **Then** there is exactly one documented path:
   back up, remove keeping config, download the release zip, verify its
   checksum against the published checksum list and its signature, add
   from the release URL, run the projection script.

---

### User Story 2 - Upgrades never silently discard local edits (Priority: P2) — #70

A maintainer who adapted a projected file, or chose to keep a local copy
during a previous upgrade, upgrades again. Today nothing records what was
projected, so local edits cannot be detected reliably; holds are written
but nothing reads them; and a CI pipeline projected earlier silently misses
new template steps. After this story, projection records what it wrote
and from which version, upgrade refuses to overwrite a held or locally
edited file, doctor reports holds and fails on stale ones, and doctor and
upgrade list CI-template steps the pipeline lacks.

**Why this priority**: an upgrade that silently discards hardening is the
failure class this project exists to prevent, and it depends only on US1.

**Independent Test**: project, edit one projected file, add a hold for
another, then upgrade to a fixture "newer" version; verify both files
are untouched and reported, doctor lists the hold, and once the held file
matches upstream doctor fails on the stale hold.

**Acceptance Scenarios**:

1. **Given** a fresh projection, **When** it completes, **Then** a manifest
   records the source extension version and a content hash for every
   projected file.
2. **Given** a projected file edited locally, **When** an upgrade runs,
   **Then** the file is not overwritten, the upgrade names it as locally
   edited, and it exits non-zero unless the maintainer explicitly chooses
   to keep local or take upstream for that file.
3. **Given** a path listed in the holds file, **When** an upgrade runs,
   **Then** that path is never overwritten.
4. **Given** a hold whose file is now identical to the vendored upstream
   copy, **When** doctor runs, **Then** it fails and names the stale hold.
5. **Given** a held path that still differs from upstream, **When** doctor
   runs, **Then** it reports the hold as informational and does not fail.
6. **Given** a project pipeline that lacks a step present in the shipped CI
   template, **When** doctor or upgrade runs, **Then** the missing step is
   listed by name.
7. **Given** a project with no manifest (projected by 0.3.x), **When** the
   first 0.4.0 upgrade runs, **Then** it compares against the previous
   version's vendored copy if available, otherwise treats any file
   differing from the new upstream as possibly edited and asks, and then
   writes the manifest.

---

### User Story 3 - Local hardening survives upgrades; sensitive names ask instead of block (Priority: P3) — #71

A maintainer adds project-specific rules, such as refusing bulk staging
after an untracked directory was swept into main history. Today every
upgrade regenerates the hooks and discards those rules. Separately, the
agent cannot edit a file such as `test_no_secret_leak.py` because any
basename containing a sensitive word is hard-blocked with no override.
After this story, a local extension directory is consulted by every hook
and never touched by upgrade, bulk staging can be refused through a
policy knob, and a sensitive word alone in a file name makes the agent
ask the human instead of refusing outright.

**Why this priority**: the lost hardening is a real incident; the name rule
is a daily papercut for test-heavy repos.

**Independent Test**: add a local rule that blocks a marker command,
upgrade, and verify the rule still fires; enable the bulk-staging knob and
verify `git add -A`, `git add .`, and `git add somedir/` are refused while
`git add file.txt` is allowed; ask the agent hook to edit
`test_no_secret_leak.py` and verify it returns "ask", and to edit `.env`
and verify it blocks.

**Acceptance Scenarios**:

1. **Given** a local rule file in the local extension directory, **When**
   the matching hook runs, **Then** the local rule is applied in addition
   to the shipped rules (a local rule can add refusals, never remove a
   shipped one).
2. **Given** a local extension directory, **When** an upgrade runs,
   **Then** the directory and its contents are unchanged and are not
   reported as local edits.
3. **Given** the bulk-staging knob is enabled, **When** the agent or a
   commit attempts `git add -A`, `git add --all`, `git add .`, or
   `git add <dir>/`, **Then** it is refused with the knob named; explicit
   file paths are allowed.
4. **Given** the knob is absent, **When** bulk staging is attempted,
   **Then** behavior is unchanged from 0.3.6.
5. **Given** an agent edit to a file whose basename merely contains
   credentials, secret, password, token, or keystore, **When** the agent
   boundary evaluates it, **Then** the decision is "ask" with the reason
   stated, not a hard block.
6. **Given** an agent edit to `.env`/`.env.*`, a private key, a
   certificate, an exact known credential file name, or a
   `protected_files.extra` entry, **When** the agent boundary evaluates
   it, **Then** it is hard-blocked as today.

---

### User Story 4 - Only Core Principles are principles (Priority: P4) — #82

A maintainer whose constitution has sub-headings under Additional
Constraints or Governance runs the constitution check. Today every `###`
heading anywhere counts as a principle, so those sub-headings are
reported as unannotated principles and the maintainer rewrites them as
bold lead-ins to silence the report. After this story, only headings in
the Core Principles section are principles.

**Why this priority**: a small, contained correctness fix; independent of
the upgrade work.

**Independent Test**: check a fixture constitution with one principle
under Core Principles and one `###` under Additional Constraints; verify
exactly one principle is reported.

**Acceptance Scenarios**:

1. **Given** a constitution with `###` headings under Core Principles and
   under another `##` section, **When** the check runs, **Then** only the
   Core Principles headings are reported as principles.
2. **Given** a `gates:enforce` marker under a `###` heading outside Core
   Principles, **When** the check runs, **Then** it is reported MALFORMED (the check fails), naming the line
   and telling the author to move the principle into Core Principles.
3. **Given** a constitution with no Core Principles section, **When** the
   check runs, **Then** it reports zero principles and says the section
   is missing.

---

### User Story 5 - Installs that only work on the author's machine are caught (Priority: P5) — #73

A maintainer installed with the development flag. Spec Kit wrote the
rendered skills as symlinks into an untracked directory; they committed
the symlinks, and no gates command loads in a fresh clone or in CI.
Separately, repos whose formatters walk the vendored extension directory
need an exclude, which is a protected policy change. After this story,
doctor fails on a symlinked or unresolvable registered skill, init and
upgrade warn on a development install, the README says the flag is for
developing spec-gates only, and vendored files pass the formatter.

**Why this priority**: the failure is silent until a fresh clone; the
detection is cheap.

**Independent Test**: in a fixture, replace a registered gates skill with a
symlink, and separately with a dangling symlink; verify doctor fails and
names it. Run the formatter check over the vendored files and verify it
is clean.

**Acceptance Scenarios**:

1. **Given** a registered gates skill that is a symlink, **When** doctor
   runs, **Then** it fails, names the skill, and says how to reinstall
   from a release.
2. **Given** a registered gates skill that does not resolve, **When**
   doctor runs, **Then** it fails and names it.
3. **Given** a development-flag install, **When** init or upgrade runs,
   **Then** it warns that the install will not work in other clones.
4. **Given** the shipped release contents, **When** the repo's formatter
   check runs over the vendored files, **Then** it reports no changes.

---

### User Story 6 - Sensible defaults and coexistence with other tools (Priority: P6) — #74

A maintainer whose project integrates an AI provider, or already uses
another hook manager, or installed the extension without projecting it.
Today the branding rule refuses the provider's name anywhere in a commit
or PR text, forcing a protected policy change; init overwrites hooks that
another manager owns; and doctor, verify and upgrade assume the runtime
is projected. After this story, the branding default stays strict but
its refusal names the override, the provider attribution case is
documented, another hook
manager is detected before anything is overwritten, and doctor can check
a dormant install.

**Why this priority**: these are defaults and edge environments; each is
small and independent.

**Independent Test**: run init in fixtures with `core.hooksPath` set, a
husky directory, and a lefthook config; verify nothing is overwritten and
verify each manager's own configuration gets the gates entry only
after approval, the generated hook files are untouched, and the
behavioral probe passes afterwards; an unknown framework is refused. Run `doctor --installed-only` in
a fixture with the extension installed but no runtime projected and verify
it reports the install state and exits zero.

**Acceptance Scenarios**:

1. **Given** commit or PR text that names an AI provider outside an
   attribution position, **When** the message rules run with the default
   policy, **Then** it is still refused (the default is unchanged), and the
   refusal message names the allow_phrases override.
2. **Given** an existing project with a projected policy, **When** it
   upgrades to 0.4.0, **Then** the protected policy file is not
   rewritten; any new schema field is reported with the propose flow as
   the way to adopt it.
3. **Given** `core.hooksPath` is set, or husky, lefthook, the pre-commit
   framework, or a foreign
   hook already occupies the git hooks, **When** init or the projection
   script wires the git boundary, **Then** it never writes into the
   manager's generated hook files; for husky, lefthook, or the pre-commit
   framework it shows the entry for that manager's own configuration
   file and applies it only after the maintainer approves the diff; for
   an unknown framework it exits non-zero and prints the call-through.
4. **Given** any hook setup (plain, managed, or custom), **When** doctor
   or the projection script runs, **Then** it sends a known-bad commit
   message through the effective commit-msg hook and fails if the hook
   does not refuse it, naming the hook path that git actually runs.
5. **Given** the extension is installed but the runtime is not projected,
   **When** `doctor --installed-only` runs, **Then** it checks the
   installed extension (registration, skills, version) and exits zero if
   that is healthy, without failing on the missing runtime.
6. **Given** the README, **When** a maintainer reads the attribution
   section, **Then** it shows the agent attribution case and the
   allow_phrases entry that permits it.

---

### User Story 7 - Agent hooks never silently allow (Priority: P1, ships first) — #83

A maintainer relies on the agent boundary to refuse edits to secrets and
destructive commands. Today the file-protection and command-validation
hooks allow everything when jq is missing or when any unexpected error
occurs, and the file hook silently skips policy-declared protected paths
when the policy library cannot be loaded. After this story, the hooks
never silently allow in those states, and they never lock the agent out
either. Without jq, each hook falls back to a raw-text check that still
blocks every call a full check would block. Where it cannot decide (a
policy-declared protected path it cannot evaluate, an internal error),
it asks the human instead of allowing or refusing. Doctor keeps failing
until jq is installed.

**Why this priority**: a silent allow at the agent boundary violates
constitution principle I (Fail Closed). Refusing every call instead
would leave the agent unable to run any command, including the one that
installs jq. The fix is small and US3 changes the same hook, so it lands
first.

**Independent Test**: run each hook with jq absent from PATH and with a
malformed payload; verify that every destructive command and sensitive
file the full check blocks is still blocked, that a benign command or
file is allowed with a doctor warning, and that an edit the hook cannot
evaluate (protected_files.extra without jq, an internal error, a policy
library that fails to load) returns an "ask" decision.

**Acceptance Scenarios**:

1. **Given** jq is not on PATH, **When** the command hook receives a
   destructive command, **Then** it blocks it exactly as with jq.
2. **Given** jq is not on PATH, **When** the command hook receives a
   benign command (for example the jq install command), **Then** it
   allows it and warns that doctor reports a missing dependency.
3. **Given** jq is not on PATH, **When** the file hook receives an edit to
   `.env`, a key, or another built-in sensitive name, **Then** it blocks.
4. **Given** jq is not on PATH and the policy declares
   protected_files.extra entries, **When** the file hook receives any
   other edit, **Then** it returns "ask" naming the reason; with no extra
   entries it allows with a warning.
5. **Given** an unexpected internal error, an unextractable file path, or
   a policy library that exists but cannot be loaded, **When** a hook
   runs, **Then** it returns "ask", never a silent allow.
6. **Given** a payload with no file path or command, **When** the hook
   runs, **Then** it allows the call (nothing to check).
7. **Given** the canary suite, **When** it runs, **Then** it includes
   no-jq variants of the command and file canaries and fails if a
   destructive command or sensitive file gets through.

---

### Edge Cases

- Projection script run from a linked worktree, or where the git hooks
  directory is not `.git/hooks`: hooks are resolved through git, not by
  path guess.
- Manifest exists but is corrupt or from a future version: upgrade stops
  and says so; it does not fall back to blind overwrite.
- A held path also appears in the local extension directory: the local
  directory rule wins (never touched); the hold is reported as redundant.
- A projected file deleted locally: upgrade reports it as a local edit
  (deletion), not silently restores it.
- Bulk-staging knob with paths that contain spaces or a trailing slash on
  a file: only directory arguments and the all-files forms are refused.
- The stock-macOS shell: every new script runs under the bash 3.2 that
  `#!/bin/bash` resolves to on macOS.
- No network during the documented upgrade: the checksum and signature
  steps fail closed; the path never continues with an unverified zip.
- No cosign on the maintainer's machine (locked down): the checksum check
  stays required; the signature is checked on another machine and tied
  to the local zip by its sha256, or skipped only on the maintainer's
  explicit, informed choice (the checksum then proves integrity, not
  origin). The path never blocks outright and never skips the signature
  by default.
- A probe run outside Claude Code: the canned probe still runs the git and
  CI boundary probes and reports the agent probe as skipped, not passed.

## Requirements _(mandatory)_

### Functional Requirements

#### Projection and upgrade path (#72)

- **FR-001**: The extension MUST ship one projection script that performs
  the entire projection (runtime copy, execute bits, agent settings merge,
  git hook install, ignore entries, manifest write) in a single
  invocation.
- **FR-002**: The projection script MUST be idempotent: a second run with
  the same version changes no file.
- **FR-003**: The projection script MUST detect a half-done remove+add
  (no installed extension, or an installed version that does not match
  its own vendored copy) and exit non-zero with the command to finish,
  without modifying the projected runtime.
- **FR-004**: Init and upgrade MUST run the canaries and fail on any
  canary that does not block.
- **FR-005**: The extension MUST ship a canned self-test probe that
  exercises each boundary without its invocation being refused by the
  live agent hook, and reports a boundary it cannot reach as skipped.
- **FR-005a**: The projection script MUST restore execute bits on the
  vendored copies of the shipped scripts and git hooks inside the
  installed extension directory (a zip install drops them, which shows
  as a mode change in repos that commit that directory), and doctor MUST
  report a vendored script that is not executable.
- **FR-006**: The README and the upgrade command MUST document exactly
  one upgrade path including checksum and signature verification as
  explicit steps that stop on failure.

#### Upgrade safety (#70)

- **FR-007**: Projection MUST write a manifest recording the source
  extension version and a content hash per projected file.
- **FR-008**: Upgrade MUST NOT overwrite a path that is held, or whose
  content differs from its manifest hash, without an explicit per-file
  choice by the maintainer.
- **FR-009**: Doctor MUST report every hold, and MUST fail on a hold whose
  file is identical to the vendored upstream copy.
- **FR-010**: Doctor and upgrade MUST list each shipped CI-template step
  missing from the project's pipeline.
- **FR-011**: The first upgrade of a project with no manifest MUST NOT
  overwrite any differing file silently, and MUST write the manifest when
  done.

#### Local extension point and name rules (#71)

- **FR-012**: Every agent and git hook MUST consult a local extension
  directory that projection and upgrade never write, delete, or report as
  edited.
- **FR-013**: Local rules MUST only add refusals; they MUST NOT be able to
  disable a shipped check.
- **FR-013a** (#95): The agent MUST NOT be able to change the local rules
  unreviewed: Write/Edit under `hooks.local.d/` MUST be refused, a Bash
  command that appears to modify any protected path (the rules,
  `protected_files.extra`) MUST ask, and a commit changing a rule MUST
  carry `Protected-Change` and `Approved-By` trailers at the git boundary
  and in CI.
- **FR-014**: A policy knob MUST refuse bulk staging (all-files forms and
  directory arguments) at the agent boundary and at the git boundary
  where detectable; absent the knob, behavior is unchanged.
- **FR-015**: The agent boundary MUST hard-block edits only on strong
  evidence (`.env` and variants, private keys, certificates, exact known
  credential file names, `protected_files.extra`) and MUST return an
  "ask" decision when a sensitive word alone appears in the basename.

#### Constitution parser (#82)

- **FR-016**: Only `###` headings inside the Core Principles section MUST
  be treated as principles; a `gates:enforce` marker outside that
  section MUST be reported MALFORMED.

#### Install hygiene (#73)

- **FR-017**: Doctor MUST fail when a registered gates skill is a symlink
  or does not resolve.
- **FR-018**: Init and upgrade MUST warn on a development-flag install, and
  the README MUST state the flag is for developing spec-gates only.
- **FR-019**: Released vendored files MUST pass the repository's formatter
  check unchanged.

#### Defaults and coexistence (#74)

- **FR-020**: The default branding rule MUST stay unchanged (a provider
  name is refused anywhere); its refusal message MUST name the
  allow_phrases override, and the README MUST document the agent
  attribution case and the allow_phrases entry for a repo that
  integrates a provider.
- **FR-021**: Upgrade MUST NOT rewrite the protected policy file; any
  new policy field (such as the bulk-staging knob) MUST reach existing
  consumers as an upgrade notice pointing at the propose flow.
- **FR-022**: Init and the projection script MUST detect another hook
  manager (`core.hooksPath`, husky, lefthook, the pre-commit framework,
  or a foreign hook in the git hooks directory) and MUST NOT write into
  a manager's generated hook files. For a known manager they MUST offer
  the entry for that manager's own configuration and apply it only on an
  approved diff; for an unknown framework they MUST exit non-zero and
  print the call-through.
- **FR-022a**: Doctor and the projection script MUST prove the git
  boundary: a hook gates owns MUST be run with the probe signal and answer
  it; a hook another tool owns MUST be checked statically for the gates
  call-through (running it would run that tool's steps), with an opt-in to
  run the full chain; a failure names the hook git runs.
- **FR-023**: Doctor MUST support an installed-only mode that checks the
  installed extension without requiring a projected runtime.

#### Agent hooks fail closed (#83)

- **FR-028**: The file-protection and command-validation hooks MUST NOT
  silently allow when jq is missing, the payload cannot be parsed, an
  unexpected error occurs, or (file hook) the present policy library
  cannot be loaded. Without a parser they MUST still block every call
  that matches a built-in block rule, and MUST return "ask" for a call
  they cannot evaluate. They MUST NOT refuse a benign call only because
  jq is missing. A payload without the relevant field MUST be allowed.
- **FR-029**: The canary suite MUST cover the no-jq state of both hooks.

#### Cross-cutting

- **FR-024**: Every new or changed runtime script MUST run under bash 3.2.
- **FR-025**: Every new check MUST fail closed when a tool it needs is
  missing or an input is unreadable.
- **FR-026**: Every new check MUST ship with a test that has been shown to
  fail against the pre-change code.
- **FR-027**: Public text MUST NOT name downstream consumer projects.

### Key Entities

- **Projection manifest**: per-project record of the extension version
  that projected the runtime and a content hash per projected file;
  owned by projection, read by upgrade and doctor.
- **Upgrade hold**: a path the maintainer chose to keep local; read by
  upgrade (never overwrite) and doctor (report; fail when stale).
- **Local extension directory**: project-owned rules consulted by hooks;
  invisible to projection, upgrade, and the manifest.
- **Bulk-staging knob**: a policy setting; off by default.
- **Hook manager**: an existing owner of the git hooks (configured hooks
  path, husky, lefthook, the pre-commit framework, or a foreign hook
  file); it has generated files gates never edits and a user-owned
  configuration where the gates entry belongs.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A fresh install or upgrade needs exactly one maintainer
  approval for the projection step (one script invocation), down from one
  per file.
- **SC-002**: Across a test matrix of local edits, holds, and local rules,
  zero locally changed files are overwritten without an explicit choice.
- **SC-003**: Init and upgrade fail on 100% of canaries that do not block.
- **SC-004**: Every issue in the 0.4.0 milestone (#70–#74, #82, #83) is closed
  by a merged change with a test that has been mutation-checked.
- **SC-005**: The full suite passes on stock macOS bash 3.2 and in the slim
  container matrix (no python3, minimal python3, full python3).
- **SC-006**: The documented upgrade path, run against a release-shaped
  zip, reaches a doctor-clean state in both local consumer projects
  before the 0.4.0 tag.

## Assumptions

- Consumers are on Spec Kit 1.0.11–1.0.13, whose `extension add --from`
  verifies neither checksum nor signature and has no non-interactive
  confirm flag; remove+add is therefore non-atomic and the projection
  script, not Spec Kit, owns detecting a half-done state.
- Spec Kit itself is not changed; its CLI gaps are mitigated on the gates
  side only.
- The "ask" decision uses the agent's existing pre-tool-use permission
  protocol; on agents without it, the sensitive-word case falls back to
  the hard block (fail closed).
- The bulk-staging knob defaults off so 0.3.6 behavior is preserved.
- The shipped CI template is the reference for drift; steps the project
  added are not reported.
- Each user story ships as its own pull request under the 0.4.0
  milestone, in priority order, with acceptance blocks in tasks.md.
