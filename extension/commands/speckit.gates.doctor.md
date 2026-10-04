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
  integration.
- `--probe-git`: also run git hooks another tool owns (husky, lefthook, the
  pre-commit framework) to prove the chain reaches gates. Their own steps
  run too (husky's default `pre-commit` is `npm test`), so ask the user
  first.
- `--canary`: run the canary suite instead (`canary.sh`; same exit code).

## Steps

1. **Run doctor** and show its output verbatim:
   `bash .specify/gates/doctor.sh`. Each line is `[ok]`, `[MISSING]` (a
   failure: doctor exits 1), `[rec]` (a recommendation) or `[--]`
   (skipped). The sections, in order:
   - **Required tools**: `jq`, `git`, `python3` with the `json` module (the
     PR hook refuses every PR command without it), and python3 or perl
     (the emoji rule). Without jq the agent hooks run in raw mode.
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
     with the installed copy, fails.
   - **Upgrade safety**: whether `project.sh --check` finds the projection
     current; local edits that are not held fail; held files are listed,
     and a hold whose file now equals the installed copy is stale and
     fails; CI pipelines must contain the template's `gates`, `canary` and
     `pr` steps unless `ci:<step>` in `.specify/gates/.upgrade-holds`
     records a deliberate omission.
   - **Agent hooks**: each projected hook must be executable (Claude Code
     runs them by path).
   - **Attestations**: the latest record must not show a gate that passed
     while checking none of its candidate files (the no-op signature).
   - **Spec conformance**: features, accept blocks and Complete count; a
     parse error fails; all tasks checked without the Complete flip gets a
     nudge.
   - **Git boundary**: the hooks git actually runs. A gates stub is run with
     `GATES_PROBE=1` and must answer from the gates hook. A hook another
     tool owns is read, not run: the gates call-through must be in the file
     that tool reads (`.husky/<hook>`, `lefthook.yml`,
     `.pre-commit-config.yaml`). A hook that is installed but not
     executable fails; one never installed gets a recommendation.
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

`0` = healthy, `1` = at least one `[MISSING]` item. When doctor's output is
piped through an early-closing consumer (`head`, `grep -q`), the shell may
report exit `141` (SIGPIPE): standard pipe behavior, not a doctor verdict;
run it unpiped for the meaningful exit code.
