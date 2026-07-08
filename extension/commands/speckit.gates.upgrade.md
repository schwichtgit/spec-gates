---
description: "Re-project the enforcement runtime after an extension update (never touches policy.json)"
---

# Upgrade Gates Runtime

Re-project `verify.sh`, `doctor.sh`, `canary.sh`, `contract.sh`, `lib/`,
hook scripts, and the schema from the currently installed extension
version into the project.

## Rules

- NEVER overwrite `.specify/gates/policy.json`. If the new schema adds
  fields, list them and offer to add defaults interactively.
- Diff each projected file against the in-repo copy; show a summary of
  what changes before writing.
- If the user has locally modified a projected runtime file, flag the
  conflict and let them choose (keep local / take upstream / show diff).
  Record kept-local files in `.specify/gates/.upgrade-holds` so doctor
  can report them.
- Update `.specify/gates/.runtime-version` and re-run the init self-test
  (step 6 of /speckit.gates.init) to prove enforcement still works.
