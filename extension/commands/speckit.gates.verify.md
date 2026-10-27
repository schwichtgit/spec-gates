---
description: "Run the full gate suite on demand (same checks as the Stop hook, pre-commit, and CI)"
---

# Verify Quality Gates

Run the complete gate suite against the working tree and report results.
This is the SAME entrypoint invoked by the Claude Code Stop hook, the git
pre-commit hook, and projected CI — so a green run here means green
everywhere.

## User Input

```text
$ARGUMENTS
```

Optional:

- `--json`: one machine-readable result object, for workflow steps.
- `--dry-run`: resolve the policy and list the checks without running
  them.
- `--accept <feature|all>`: also run the named incomplete feature's (or
  every feature's) accept blocks, as information only. Features whose
  `spec.md` says `**Status**: Complete` are enforced on every run anyway.
  A name that is not a feature is refused (exit 1) before any gate runs.
- `--walk`: run only the built-in walk (prettier, markdownlint,
  shellcheck as the policy enables them), with no attestation. This is
  the stable way for a custom command to run the built-in checks; never
  call `lib/formatter-dispatch.sh` directly.

The report lists the project's own gates (`hooks.verify-quality.gates`)
after the built-in ones. A gate the policy keeps out of this boundary
shows as `[skipped] <name> -- skipped by declaration at agent`; that is
a policy decision, not a failure, and CI still runs it. Every gate
command can read the running boundary from `GATES_BOUNDARY`.

An accept block the policy's covering script (`spec.cover`) vouched for
shows as `spec: <feature>: "<label>" -- covered: <reason>`, and the spec
gate's summary names every covered block. Covering never happens at CI;
report covered blocks as covered, not as passed.

`GATES_TIMELINE=<file>` and `GATES_PROGRESS=<file>` make the run write a
line per gate and accept block as it ends (timeline) or starts and ends
(progress); set them only when the user asks for a timeline.

## Steps

1. Confirm `.specify/gates/verify.sh` exists; if not, direct the user to
   `/speckit.gates.init` and STOP.
2. Run `bash .specify/gates/verify.sh --boundary agent` (add `--json` if
   requested). Stream output to the user.
3. On failure: list each failed check, then FIX the failures (format,
   lint, test issues) and re-run until green or the user stops you. Never
   edit `.specify/gates/policy.json` to make a failure disappear — that
   file is protected and policy changes are a human decision.
4. Report the final state. If invoked by the after_implement hook, keep
   the report to a short summary plus any remaining failures.

## Exit codes

`0` = every gate green, `1` = internal error (a bad argument, a missing or
invalid policy: no gate ran, and the validator's errors are printed),
`2` = at least one gate failed. On an invalid policy, report the errors and
stop; do not edit the policy to fix it, that is the user's change.

With `--json`, an exit-`1` refusal still prints one object on stdout, next
to the message on stderr:
`{"result":"refused","boundary":"ci","reason":"<the stderr message>"}`
(`boundary` is `unspecified` when no valid `--boundary` was given). A run that
evaluated gates prints the result object with `gates[]` instead, which has
no `result` key.

One gate run holds the working tree at a time. When another run holds it,
this command (agent boundary) skips: exit `0`, the message
`gates: skipped: the gate run of pid N (<boundary>) is in progress`, and
with `--json` the object `{"result":"skipped","boundary":"agent","reason":...}`.
Report the skip and re-run once the other run (usually a commit's
pre-commit hook) has finished; do not delete `.specify/gates/.lock`. At the
git and CI boundaries a run waits for the lock instead, up to
`GATES_LOCK_WAIT_S` seconds (default 600), and then refuses with exit `1`.
