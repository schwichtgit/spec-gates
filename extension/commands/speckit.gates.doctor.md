---
description: "Check enforcement health: tools, hooks wired and proven, runtime current, upgrade safety, install hygiene, and the spec, contract and constitution gates"
---

# Gates Doctor

Diagnose the enforcement setup without changing anything. `doctor.sh` does
the checking; this command runs it, shows the output, and explains it.

## Modes

- `bash .specify/gates/doctor.sh`: the full check (the sections below).
- `bash .specify/extensions/gates/runtime/doctor.sh --installed-only`: only
  the installed extension (registry, version, skills, install mode). Use it
  before the runtime is projected, or for an install without an agent
  integration. The full check on such an install fails and says the
  runtime is not projected.
- `--probe-git`: also run git hooks another tool owns (husky, lefthook, the
  pre-commit framework) to prove a gates refusal reaches git (the gates
  hook refuses in probe mode; the hook git runs must exit non-zero). Their own steps
  run too (husky's default `pre-commit` is `npm test`; under lefthook only
  the gates job runs), so ask the user first.
- `--ci`: for a CI job. A CI checkout has no git hook stubs (they live in
  `.git/hooks` of a developer clone), so the full check would report the
  projection as not current. `--ci` leaves out the git hook wiring and
  the git boundary section and runs every other check.
- `--canary`: run the canary suite instead (`canary.sh`; same exit code).
  Every other argument goes to `canary.sh` (`--json`, `--only <ids>`);
  doctor's own options cannot be combined with it.

Options go in any order. An unknown option is a usage error (exit 2) and
nothing is checked.

## Steps

1. **Run doctor** and show its output verbatim:
   `bash .specify/gates/doctor.sh`. Each line is `[ok]`, `[MISSING]` (a
   failure: doctor exits 1), `[rec]` (a recommendation) or `[--]`
   (skipped). The sections, in order:
   - **Required tools**: `jq`, `git`, `cmp`, `sha256sum` or `shasum`,
     `python3` with the `json` module (the PR hook refuses every PR
     command without it), and python3 or perl (the emoji rule). Each
     missing one is named with an install hint. Without jq the agent
     hooks run in raw mode.
   - **Policy**: the policy `verify.sh` enforces must validate; an invalid
     one **fails** with the validator's errors (every boundary refuses to
     run the gates until it is fixed), and the linters are not listed.
   - **Policy-enabled linters**: each linter the policy turns on must
     resolve (`node_modules/.bin`, then PATH). A missing one is an
     enforcement gap, so it fails. A deprecated field that no gate reads
     (`on_missing_runner`, `on_missing_tests`) gets a `[rec]` line to remove
     it; it does not fail.
   - **Runtime projection**: the projected runtime's `.runtime-version` must
     match the installed extension; a mismatch **fails** (run
     `/speckit.gates.upgrade`). Also the install itself: registered gates
     commands must be regular skill or command files (a `--dev` install's
     symlinks fail), a `--dev` install is flagged, and installed scripts
     without the execute bit are flagged.
   - **Install state**: a projected runtime whose extension was removed and
     not added back (a half-done upgrade), or a registry that disagrees
     with the installed copy, fails. Without jq the registry cannot be
     read, and the state is reported as not checked.
   - **Upgrade safety**: whether `project.sh --check` finds the projection
     current, and when it reports pending work, which item it is (files
     to project, hook-manager wiring for `--wire-manager`, the manager's
     install command, a stale or missing hold, missing git, a repository
     git refuses), each with its command; local edits that are not held fail; held files are listed,
     and a hold whose file now equals the installed copy is stale and
     fails; a held file that is missing fails (a deletion cannot be held;
     `--take-upstream <path>` restores it), and held edits get a `[rec]`
     to prove them with `doctor.sh --canary`; CI pipelines must contain the template's `gates`, `canary` and
     `pr` steps unless `ci:<step>` in `.specify/gates/.upgrade-holds`
     records a deliberate omission. Only live steps count: commented-out
     steps, steps or jobs under `if: false`, a command an `echo` only
     prints, one whose failure `|| true`, `continue-on-error: true` or
     `allow_failure: true` ignores, `--dry-run`, anything after an
     unconditional `exit 0`, manual, hidden or never-run GitLab jobs,
     workflows triggered only by `workflow_dispatch` or `schedule`, and
     Jenkins stages under `when { expression { false } }` do not. The
     gates step must be proven: `bash .specify/gates/verify.sh --boundary ci`
     as the whole command (or the last line of its script, with no heredoc,
     `trap` or `exit 0` before it), on a push or pull request trigger (GitLab:
     a branch or merge request pipeline), with no `GATES_SPEC_EXEC` or
     `GATES_POLICY_FILE` in the file, and not inside Jenkins `catchError`,
     `warnError` or `try`. A pipeline that calls `verify.sh` without such a
     step fails, and the line says what to change. Wrapper scripts and
     computed conditions are read as live: the CI run's own log is the
     proof that the gates ran. A
     `ci:<step>` hold for a step the pipeline runs is stale and fails, and
     an unknown id gets a `[rec]`. A hold for a step the pipeline lacks is
     a `[rec]` naming the check CI gives up (exit code unchanged); for
     `pr`, `project.sh --check` prints the step on its own.
   - **Agent hooks**: each projected hook must be executable (Claude Code
     runs them by path).
   - **Attestations**: `.specify/gates/` and its `attestations.jsonl`
     must be writable (unless `attestation.enabled` is false): `verify.sh`
     still runs without them but records no evidence, so doctor fails.
     The latest record must not show a gate that passed while checking
     none of its candidate files (the no-op signature).
   - **Spec conformance**: features, accept blocks and Complete count; a
     parse error fails; all tasks checked without the Complete flip gets a
     nudge.
   - **Git boundary**: the hooks git actually runs. A gates stub is run with
     `GATES_PROBE=1` and must answer from the gates hook. A hook another
     tool owns is read, not run: the gates call-through must be in the file
     the tool that runs the hook reads (`.husky/<hook>`, the lefthook
     config, `.pre-commit-config.yaml`), where it runs for that hook (the
     hook's own lefthook key, not skipped; a pre-commit item staged for
     it), as a whole command whose failure refuses the commit (not behind
     `|| true`, `&`, `echo` or a comment). A hook that is installed but not executable fails, and so does
     one a manager's config calls but git does not run yet (the line names
     the install command); one never wired gets a recommendation.
   - **Policy contract** (only with `extends`): pin, snapshot and effective
     policy must agree; the deviations are listed.
   - **Constitution**: per principle, `enforced`, `gap` (fails) or
     `prose-only`; a malformed marker, or one outside `## Core Principles`,
     fails naming the line; a constitution without that section is
     reported as declaring no principles.
   - **Recommended**: `node`, `shfmt`, `task`. Never fail the check.

2. **Validate the policy** if doctor did not already flag it:
   `bash .specify/gates/lib/policy.sh validate .specify/gates/policy.json`.

3. **Check the agent wiring** doctor does not read: `.claude/settings.json`
   carries the gates hook entries for the scripts in `.claude/hooks/gates/`.

## Output

A table of check, status (OK / WARN / FAIL) and remediation, plus doctor's
raw output. State whether enforcement is fully active at each boundary
(agent, git, CI). Doctor changes nothing.

## Exit codes

`0` = healthy, `1` = at least one `[MISSING]` item, `2` = usage error
(an unknown option). When doctor's output is
piped through an early-closing consumer (`head`, `grep -q`), the shell may
report exit `141` (SIGPIPE): standard pipe behavior, not a doctor verdict;
run it unpiped for the meaningful exit code.
