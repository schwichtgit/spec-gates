---
description: "Re-project the enforcement runtime after an extension update (never touches policy.json)"
---

# Upgrade Gates Runtime

Re-project `verify.sh`, `doctor.sh`, `canary.sh`, `contract.sh`,
`constitution.sh`, `pr-check.sh`, `lib/`, hook scripts, and the schema from
the currently installed extension version into the project.

## When to run this

ALWAYS after the installed extension changes version — whether via
`specify extension update` or via `extension remove` + `extension add`
(note: `extension update` may not move a `source: local` install; the
remove+add pair is the reliable path there). Nothing re-projects the
runtime automatically: until this command runs, the installed extension
and `.specify/gates/` silently diverge, and `doctor` reports the
version mismatch as a failure. Re-running `/speckit.gates.init` is NOT
needed when a policy already exists — this command is the whole bump.

## Rules

- NEVER overwrite `.specify/gates/policy.json`. If the new schema adds
  fields, list them and offer to add defaults interactively.
- Diff each projected file against the in-repo copy; show a summary of
  what changes before writing.
- If the user has locally modified a projected runtime file, flag the
  conflict and let them choose (keep local / take upstream / show diff).
  Record kept-local files in `.specify/gates/.upgrade-holds` so doctor
  can report them.
- After projecting, EXPLICITLY `chmod +x` every projected script and git
  hook (same rule as init: zip-based installs drop execute bits, and git
  silently skips a non-executable hook).
- Ensure `.specify/gates/.gitignore` lists `attestations.jsonl` (same
  one-liner as init step 3), so the entry lands in the upgrade commit
  instead of appearing as an untracked file after it. The runtime writes
  the entry on its first gate run otherwise, which is during that commit's
  pre-commit hook.
- Update `.specify/gates/.runtime-version` and re-run the init self-test
  (step 6 of /speckit.gates.init, including the git-boundary probe) to
  prove enforcement still works.
- Re-check the lint-scope ignores (step 3c of /speckit.gates.init): an
  upgrade can add projected paths, and any local reformatting of
  projected files is overwritten here by design. If the repo lints
  `.specify/gates/`, `.specify/extensions/`, or `.claude/hooks/gates/`,
  offer the ignore entries again.
- Migrate copied git hooks to the stub. For each of `pre-commit` and
  `commit-msg` in the hooks directory (`git rev-parse --git-path hooks`,
  which also resolves linked worktrees and `core.hooksPath`): if the file
  is a copy of a gates hook (its header reads `# Git pre-commit hook --` or
  `# Git commit-msg hook.`), replace it with `.specify/gates/hooks/stub.sh`
  and `chmod +x` it. Leave stubs and foreign hooks (husky, lefthook,
  call-through lines) alone. Report what was replaced. doctor flags any
  copied hook that remains.
- Tell the user that `.git/hooks` is shared by every branch while the
  projected runtime is per branch. After an upgrade, a branch still on an
  older runtime (cut before the upgrade landed, or an old branch checked
  out) commits with the newer hooks: commit-msg warns that the message
  rules are skipped there, and pre-commit keeps that runtime's protected-
  file refusal. Rebasing the branch onto the upgraded one ends the skew.
  With the stub installed (above), each branch runs its own hooks and
  the skew does not arise.
