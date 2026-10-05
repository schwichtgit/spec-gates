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
(`boundary` is `unspecified` when the arguments were refused). A run that
evaluated gates prints the result object with `gates[]` instead, which has
no `result` key.
