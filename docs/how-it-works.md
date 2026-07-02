# How spec-gates works

## The three-boundary model

Quality rules only matter if they are enforced wherever code can change.
There are exactly three such places in an agentic workflow:

1. **The agent boundary** — while the agent is working. Claude Code
   exposes lifecycle hooks; spec-gates uses four of them:
   - `PreToolUse(Write|Edit)` → `protect-files.sh`: refuse edits to
     secrets, keys, CI configs, the constitution, and policy.json itself.
     The refusal message tells the agent _why_ and what to do instead,
     redirecting it productively rather than derailing the session.
   - `PreToolUse(Bash)` → `validate-bash.sh` + `validate-pr.sh`: refuse
     dangerous commands; refuse commits to main or to merged branches.
   - `PostToolUse(Write|Edit)` → `post-edit.sh`: auto-format the touched
     file per policy.
   - `Stop` → `format-changed.sh` + `verify-quality.sh`: the session may
     not end while `verify.sh` is red. The agent gets the failure list
     and keeps working. This turns "the tasks say run the tests" from a
     suggestion into an invariant — the property that matters for long,
     semi-attended `/speckit.implement` runs.

2. **The git boundary** — when work becomes history. `pre-commit` blocks
   main commits and runs the same verify entrypoint; `commit-msg`
   enforces conventional commits and strips AI-isms.

3. **The CI boundary** — when work leaves the machine. The projected
   pipeline job runs `verify.sh --boundary ci`. Because it is the same
   script and the same policy, CI is a backstop, never a surprise.

## One entrypoint

`verify.sh --boundary agent|git|ci [--json] [--dry-run]`

Dispatch follows the policy's `verify-quality.orchestrator`:

- `none` — per-tool walk (prettier / markdownlint / shellcheck) driven by
  the policy's include/exclude globs via `lib/formatter-dispatch.sh`.
- `task` — `task lint` (error class) and `task test` (warning class),
  the fixed Taskfile convention.
- `custom` — a policy-supplied command; exit code mapped through the
  hook's severity.

Exit codes: `0` green, `1` internal error, `2` gate failure. `--json`
emits a single machine-readable object for workflow steps and CI.

## Why projection, not symlinks or plugin-resident hooks

The runtime is copied into `.specify/gates/` and `.claude/hooks/gates/`.
Three reasons: enforcement must survive the extension being removed;
collaborators who clone the repo get enforcement without installing
anything; and CI can run the entrypoint from the checkout with no
network access. The cost — projected copies can drift from the extension
version — is exactly what `/speckit.gates.doctor` and
`/speckit.gates.upgrade` exist to manage, via `.runtime-version`.

## Threat model honesty

The agent boundary raises the cost of noncompliance; it does not make
noncompliance impossible (an agent with unrestricted bash can, in
principle, edit hook wiring — which is why settings.json and the hooks
themselves are on the protected-files list, and why the git and CI
boundaries exist). Defense in depth is the point of the three-boundary
design: the boundaries an agent cannot rewrite (CI, server-side branch
protection) backstop the ones it theoretically could.

## Spec Kit compatibility

The extension mechanics spec-gates relies on — the `extension.yml`
manifest (schema 1.0), `specify extension add --from <url>`, the
`after_implement` lifecycle hook, and the workflow-engine `gate`/`shell`
steps — were verified against Spec Kit **v0.12.4**. That API still ships
alongside an `RFC-EXTENSION-SYSTEM.md` and an "experimental" label
upstream, so treat it as an evolving contract: pin `requires.speckit_version`
(currently `>=0.12.0`), and expect `/speckit.gates.doctor` to grow a
Spec-Kit-version compatibility check as the schema settles.

Two upstream facts shape how spec-gates positions itself. First, Spec
Kit's own `gate` steps and lifecycle hooks are **advisory and
human-gated** — a gate blocks only inside `specify workflow run` and
merely _pauses_ (does not fail) in CI or any non-interactive context.
Second, its lifecycle hooks are not git hooks, and nothing upstream
projects git or CI enforcement into your repository. spec-gates exists to
bind those advisory checkpoints to boundaries that actually fail closed —
a rejected tool call, a blocked commit, a red build.
