---
description: "Infer a quality policy from the repo, project the enforcement runtime, wire agent + git hooks, and run a self-test"
---

# Initialize Quality Gates

Set up deterministic quality enforcement for this Spec Kit project. After
this command completes, the same policy is enforced at three boundaries:

1. **Agent boundary** — Claude Code hooks block protected-file edits and
   dangerous bash calls, auto-format on edit, and refuse to end a session
   with failing quality checks.
2. **Git boundary** — pre-commit and commit-msg hooks block commits to
   `main`, enforce conventional commits, and run the same lint policy.
3. **CI boundary** — (projected separately via `/speckit.gates.ci`) the
   identical `verify.sh` runs in CI, so CI is a backstop, never a surprise.

## User Input

```text
$ARGUMENTS
```

Optional arguments: `--no-agent-hooks` (skip Claude Code wiring, e.g. when
another agent is the harness), `--no-git-hooks`, `--policy-only`.

## Prerequisites

- A Spec Kit project (`.specify/` exists). If not, tell the user to run
  `specify init` first and STOP.
- `jq` available. If missing, tell the user to install it and STOP.

## Steps

### 1. Locate the extension runtime

The extension ships its runtime under the extension install directory.
Resolve `RUNTIME_SRC` as the `runtime/` directory adjacent to this
command's extension root. All projection below copies FROM `RUNTIME_SRC`
INTO the project. Never symlink — projected files must survive the
extension being removed.

### 2. Infer the policy (or load the existing one)

- If `.specify/gates/policy.json` already exists: show it to the user,
  ask whether to keep it (default) or re-infer. NEVER silently overwrite —
  policy.json is user-owned.
- Otherwise run: `bash "$RUNTIME_SRC/lib/policy-infer.sh" --project-root .`
  This introspects the repo (languages present, existing prettier /
  markdownlint / shellcheck / ruff configs, Taskfile presence) and prints
  a seeded policy JSON.
- Present the inferred policy to the user section by section (one hook
  entry at a time: include globs, exclude globs, orchestrator, severity).
  Apply requested edits. This is a conversation, not a dump — the user
  must understand what will be enforced before it is enforced.
- Write the approved result to `.specify/gates/policy.json` and validate
  it against `"$RUNTIME_SRC/policy.schema.json"` using jq. On validation
  failure, show the error, fix interactively, re-validate.

### 3. Project the runtime

Copy from `RUNTIME_SRC` into the project:

| Source                 | Destination                                        |
| ---------------------- | -------------------------------------------------- |
| `verify.sh`            | `.specify/gates/verify.sh`                         |
| `lib/*.sh`             | `.specify/gates/lib/`                              |
| `policy.schema.json`   | `.specify/gates/policy.schema.json`                |
| `hooks/claude/*.sh`    | `.claude/hooks/gates/` (unless `--no-agent-hooks`) |
| `hooks/git/pre-commit` | `.specify/gates/hooks/pre-commit`                  |
| `hooks/git/commit-msg` | `.specify/gates/hooks/commit-msg`                  |

Preserve execute bits. Record the projected runtime version in
`.specify/gates/.runtime-version` (read it from the extension's
`extension.yml`).

### 4. Wire the agent boundary (Claude Code)

Unless `--no-agent-hooks`:

- Read `.claude/settings.json` (create `{}` if absent).
- Merge the hook entries from `"$RUNTIME_SRC/hooks/claude/settings.fragment.json"`
  into the `hooks` key. Merge semantics: append our entries; NEVER remove
  or reorder existing user entries; if an identical command path already
  exists, skip it (idempotent re-run).
- Show the user the resulting diff of settings.json before writing.

### 5. Wire the git boundary

Unless `--no-git-hooks` and if `.git/` exists:

- Install `.specify/gates/hooks/pre-commit` and `commit-msg` into
  `.git/hooks/`. If a hook already exists there, do NOT clobber it:
  append a call-through line invoking the gates hook, and tell the user
  what was done.

### 6. Self-test (mandatory — the user must SEE enforcement work)

Run these and show the results:

1. `bash .specify/gates/verify.sh --boundary agent --dry-run` — confirms
   the entrypoint resolves policy and enumerates checks.
2. Simulate a protected-file edit:
   `echo '{"tool_input":{"file_path":".env"}}' | bash .claude/hooks/gates/protect-files.sh`
   — expect a non-zero exit and a block message.
3. Simulate a blocked bash call through `validate-bash.sh` the same way.

If any self-test does not behave as expected, report it as a failure and
point the user at `/speckit.gates.doctor`. Do not declare success.

### 7. Report

Summarize: policy path, boundaries wired, self-test results, and the two
follow-ups — `/speckit.gates.ci <platform>` to project CI enforcement,
and the note that `/speckit.implement` will now offer to run gates on
completion (via the extension's `after_implement` hook).

## Important Rules

- policy.json is USER-OWNED. init seeds it; upgrade never overwrites it.
- All projection is copy, not symlink.
- Every write to `.claude/settings.json` is shown as a diff first.
- Fail closed on self-test: a gate that does not demonstrably block is
  reported as broken, not glossed over.
