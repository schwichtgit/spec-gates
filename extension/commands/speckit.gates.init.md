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
another agent is the harness), `--no-git-hooks` (both are passed through
to `project.sh`), and `--policy-only` (run step 2 only: infer and approve
the policy, then stop without projecting anything).

## Prerequisites

- A Spec Kit project (`.specify/` exists). If not, tell the user to run
  `specify init` first and STOP.
- `jq` available. If missing, tell the user to install it and STOP.

## Steps

### 1. Locate the extension runtime

The extension ships its runtime under the extension install directory.
Resolve `RUNTIME_SRC` as the `runtime/` directory under this command's
extension root (e.g. `.specify/extensions/gates/runtime/`). All projection
below copies FROM `RUNTIME_SRC` INTO the project. Never symlink — projected
files must survive the extension being removed.

### 2. Infer the policy (or load the existing one)

- If `.specify/gates/policy.json` already exists: show it to the user,
  ask whether to keep it (default) or re-infer. NEVER silently overwrite —
  policy.json is user-owned.
- Otherwise run (positional args `<project_dir> <output_path>`):
  `bash "$RUNTIME_SRC/lib/policy-infer.sh" . .specify/gates/policy.json.seed`
  It introspects the repo (existing prettier / markdownlint / shellcheck
  configs, Taskfile presence) and WRITES a seeded, schema-validated policy
  to the output path. It exits nonzero on a usage error, a missing default
  template, or schema-validation failure — surface that and stop.
- Present the seed (`.specify/gates/policy.json.seed`) to the user section
  by section (one hook entry at a time: include globs, exclude globs,
  orchestrator, severity). Apply requested edits. This is a conversation,
  not a dump — the user must understand what will be enforced.
- Offer the settings the seed leaves at their defaults, one question each:
  `git.block_bulk_staging` (refuse `git add`/`git stage` with `-A`,
  `--all`, `--no-ignore-removal`, `--pathspec-from-file`, `.`, `:/` and
  other pathspec magic, globs, `"$PWD"`, `~` and directory arguments at
  the agent boundary, asking on an argument it cannot resolve; off by
  default) and the branding
  `git.ai_branding.allow_phrases` (phrases a repository that integrates an
  AI provider legitimately uses, such as an SDK name).
- On approval, move the seed to `.specify/gates/policy.json`. Re-validate
  with `bash "$RUNTIME_SRC/lib/policy.sh" validate .specify/gates/policy.json`.
  On failure, show the error, fix interactively, re-validate.
- With `--policy-only`, stop here and report the policy path.

### 3. Seed the pinned linter toolchain

If the approved policy enables node-resolved linters (prettier and/or
markdownlint) and the repo does not already pin them (`package.json`
devDependencies + a lockfile):

- Offer to add the missing devDependencies (`prettier`,
  `markdownlint-cli2`) — creating a minimal `package.json` if the repo
  has none — and run `npm install` to produce the lockfile. The lockfile
  pin is what the parity gate verifies and what makes local == CI.
- If the user declines, say plainly that those gates will SKIP until the
  tools are installed and that `doctor` will report the enforcement gap.
  Never leave this state silent.

Also seed a sensible markdownlint config when the policy enables
markdownlint and the repo has none (`.markdownlint-cli2.jsonc`,
`.markdownlint.*`): without one, markdownlint's MD013 line-length rule
fights prettier (which deliberately does not wrap prose), producing
permanent noise. Seed this and show it to the user:

```jsonc
{
  // One tool owns each concern: prettier owns wrapping (proseWrap:
  // preserve) and formats tables/code in ways MD013 cannot satisfy, so
  // line-length is ceded to prettier and the rest of the ruleset stays on.
  "config": {
    "default": true,
    "MD013": false,
  },
  "globs": ["**/*.md"],
  "ignores": ["**/node_modules", "**/.venv", ".specify", ".claude"],
}
```

Adjust `ignores` to the repo's layout (mirror the policy's exclude
globs). Do not seed a prettier **config** — prettier's defaults are the
convention and needing none is the point. Ignore files are a different
concern; see 4b.

### 4. Project the runtime and wire the boundaries (one step)

`RUNTIME_SRC/project.sh` does the whole projection in one invocation:
it copies the runtime into `.specify/gates/` and `.claude/hooks/gates/`,
sets every execute bit (including the installed extension's git hooks,
which zip extraction leaves non-executable), records
`.specify/gates/.runtime-version`, adds `attestations.jsonl` to
`.specify/gates/.gitignore`, merges the agent hooks into
`.claude/settings.json` (append-only: existing entries are never removed
or reordered, and a command path already wired is skipped), installs the
git hook stub as `pre-commit` and `commit-msg` in the hooks directory git
reads, writes `.specify/gates/.projected.sha256`, and runs the canary
suite. It never writes `policy.json` and refuses to run without one.

1. Plan it and show the user the complete output:
   `bash "$RUNTIME_SRC/project.sh" --dry-run` (pass `--no-agent-hooks` /
   `--no-git-hooks` through from the user's arguments).
2. On approval, run it once with the same flags:
   `bash "$RUNTIME_SRC/project.sh"`.

Never copy runtime files or `chmod` them by hand: one reviewed command
replaces the per-file writes that permission classifiers refuse.

Read the exit code:

- `0`: projected, and every canary blocked.
- `1`: a canary was skipped because a policy-enabled tool is not
  installed (the user declined step 3: name the tool and say that gate
  skips until it is installed), a canary was accepted (a broken gate:
  report it and point at `/speckit.gates.doctor`; when its line names a
  missing tool such as python3, name that tool instead), or another tool owns
  the git hooks:
  - **husky, lefthook or the pre-commit framework**: `project.sh` printed
    the gates entry for that tool's own file (`.husky/<hook>`,
    `lefthook.yml`, `.pre-commit-config.yaml`). Show it, ask the user, and
    on approval re-run with `--wire-manager` to append it. If it says the
    file cannot be appended to safely, give the user the entry and the
    instruction it printed (merge into an existing block, or put the line
    before any `exit`). If it says to run `lefthook install` or `pre-commit install
--hook-type commit-msg`, tell the user to run it (never run another
    tool's installer yourself).
  - **any other owner**: give the user the call-through line it printed,
    to go before any `exit` in their hook.
  - Never edit the generated files in `.husky/_/` or `.git/hooks`.
- `2`: refused before writing; its message says why (no policy, an
  interrupted install, a corrupt `.projected.sha256`).
- `3`: files projected earlier were changed locally. Treat it as
  `/speckit.gates.upgrade` step 6.

If the project is not a git work tree yet (greenfield), `project.sh` says
the git boundary is not wired: tell the user to run it again after
`git init`, because a later `git init` does not pick the hooks up.

### 4b. Keep projected artifacts out of the repo's OWN lint scope

Projection puts files the user did not write into their tree:
`.specify/gates/` (runtime + schema), `.specify/extensions/gates/`
(the installed extension), and `.claude/hooks/gates/`. The gate's own
policy already excludes them. The user's own tooling does not know
that — so a plain `npx prettier --check .` or
`markdownlint-cli2 "**/*.md"` lints our vendored files against THEIR
style, and reports failures they cannot fix (reformatting is undone by
the next `/speckit.gates.upgrade`).

There is no formatting that avoids this: any style we ship fails
somebody's config. Vendored content belongs out of scope, exactly like
`node_modules`. So:

- **prettier**: when the repository uses prettier, `project.sh` (step 4)
  already reported which of the three paths `.prettierignore` does not
  exclude. Offer to add them; on approval re-run
  `bash "$RUNTIME_SRC/project.sh" --add-lint-ignores`, which appends them
  (creating the file if needed) and never rewrites or reorders existing
  entries.
- **markdownlint**: if the repo already has its own markdownlint config
  (so the seed in step 3 does not apply), offer to add the same three paths to
  its `ignores`; `project.sh` does not edit markdownlint configs.

Show the diff, apply only on approval, and if the user declines say
plainly that their repo-wide lint runs will flag our vendored files and
that the gate itself is unaffected either way.

### 5. Self-test (mandatory — the user must SEE enforcement work)

`project.sh` already ran the full canary suite. Run these as well and
show the results, so the user sees each boundary refuse something:

1. `bash .specify/gates/verify.sh --boundary agent --dry-run`: the
   entrypoint resolves the policy and enumerates checks.
2. `bash .specify/gates/canary.sh --only bash,protect`: the projected
   agent hooks refuse `rm -rf /` and an `.env` edit, with and without jq.
   The canaries build those tool calls internally, so the live
   validate-bash hook in this session never sees a dangerous command
   line (writing the probe into the command line itself gets the probe
   refused by the very hook it tests).
3. Prove the git boundary is live (this catches lost execute bits and
   hook-manager overrides):

   ```sh
   HOOKS="$(git rev-parse --git-path hooks)"
   test -x "$HOOKS/pre-commit" && test -x "$HOOKS/commit-msg"
   printf 'bad subject with no conventional prefix\n' >/tmp/gates-msg-probe \
     && ! bash "$HOOKS/commit-msg" /tmp/gates-msg-probe
   ```

   The first line must succeed; the second must show the hook REFUSING
   the message. A hook that exists but is not executable, or that accepts
   that subject, is a broken boundary.

If any self-test does not behave as expected, report it as a failure and
point the user at `/speckit.gates.doctor`. Do not declare success.

### 5b. Constitution enforcement (FR-014, offer only)

Run `bash .specify/gates/constitution.sh detect`. It prints one word:

- `filled` — a real constitution already exists; say so and do nothing.
- `absent` or `placeholder` — the project has no real constitution yet. Ask
  ONE question, defaulting to skip: "Run the guided constitution session
  (`/speckit.gates.constitution`) to write one whose principles are bound to
  the boundaries that enforce them?" If the user declines, continue — record
  nothing, change nothing. The session is never forced.

Whatever the answer, init proceeds. This step reads only; it never writes the
constitution itself (that is the session's job, on explicit approval).

### 6. Report

Summarize: policy path, boundaries wired, self-test results, the constitution
state from step 5b (`filled` / `absent` / `placeholder`, and whether the
session was offered), and the two follow-ups — `/speckit.gates.ci <platform>`
to project CI enforcement, and the note that `/speckit.implement` will now
offer to run gates on completion (via the extension's `after_implement` hook).

Tell the user how to commit the adoption. The first commit stages
`.specify/gates/policy.json`, a protected file, so commit-msg refuses it
without a declaration and an approver. Give them the exact message tail:

```text
Protected-Change: .specify/gates/policy.json
Approved-By: <name>
```

Commit on a branch, not `main` (the git boundary refuses commits to
`main` unless `git.block_main_commits` is off).

## Project rules

Mention that project-specific refusals belong in
`.specify/gates/hooks.local.d/<hook>/*.sh` (for `protect-files`,
`validate-bash`, `validate-pr`, `pre-commit`, `commit-msg`): they run after
the shipped checks, survive upgrades, and are protected like `policy.json`
(the agent cannot edit them; a commit changing one needs a
`Protected-Change` trailer). Never write a rule yourself without the user
asking for that exact rule.

## Important Rules

- policy.json is USER-OWNED. init seeds it; upgrade never overwrites it.
- All projection is copy, not symlink, and all of it goes through
  `project.sh`: its `--dry-run` plan (including the `.claude/settings.json`
  merge) is shown and approved before the one real run.
- Fail closed on self-test: a gate that does not demonstrably block is
  reported as broken, not glossed over.
