---
description: "Upgrade the extension and re-project the enforcement runtime through one reviewable step (never touches policy.json)"
---

# Upgrade Gates Runtime

Move a project to a new spec-gates release: verify the release, swap the
installed extension, and re-project `.specify/gates/`,
`.claude/hooks/gates/` and the git hook stubs with
`.specify/extensions/gates/runtime/project.sh`.

## When to run this

ALWAYS when the project should move to a newer release, and whenever
doctor reports that the projected runtime and the installed extension
disagree. Nothing re-projects the runtime automatically: until
`project.sh` runs, the installed extension and `.specify/gates/` silently
diverge. Re-running `/speckit.gates.init` is NOT needed when a policy
already exists.

## Steps

There is exactly one upgrade path (README "Upgrade"). Walk the user
through it in order and STOP at the first failure.

1. **Back up** `.specify/gates/` (a copy outside the repo is enough).
2. **Download and verify** the versioned release asset, never
   `releases/latest`: `gates-X.Y.Z.zip`, its `.sha256`, and its
   `.sigstore.json`. Run `sha256sum -c gates-X.Y.Z.zip.sha256` (behind a
   proxy that rewrites `.sha256` URLs, `sha256sum -c --ignore-missing
SHA256SUMS`) and `cosign verify-blob` with the identity and issuer
   from the README. Either check failing ends the upgrade. If cosign is
   not installed, stop and have the user install it: the upgrade never
   continues with a release whose signature was not checked.
3. **Swap the extension**:
   `specify extension remove gates --keep-config --force`, then
   `specify extension add gates --from <the same versioned URL>`. These
   are two commands, not a transaction. If `add` fails, the projected
   runtime keeps working and `bash .specify/gates/project.sh --check`
   prints the finishing command.
4. **Confirm the install is the verified zip**: unzip it to a temp
   directory and `diff -r <tmp>/gates .specify/extensions/gates`. A
   difference ends the upgrade.
5. **Plan the projection**:
   `bash .specify/extensions/gates/runtime/project.sh --dry-run`. Show the
   user the complete output.
6. **Resolve local edits** (exit 3 lists them). For each listed file, ask
   the user: keep the local version (`--keep-local <path>`, recorded in
   `.specify/gates/.upgrade-holds` so later upgrades leave it alone too),
   or take the new release's version (`--take-upstream <path>`; show
   `diff <path> .specify/extensions/gates/runtime/<source>` first).
7. **Project once**:
   `bash .specify/extensions/gates/runtime/project.sh [the resolution flags]`.
   One command does every write: runtime files, execute bits (including
   the installed extension's git hooks, which zip extraction leaves
   non-executable), `.runtime-version`, the attestation ignore entry, the
   agent hook settings merge, the git hook stubs (an older copied gates
   hook is migrated to the stub), and `.specify/gates/.projected.sha256`.
   It ends by running the canary suite.
8. **Report** what `project.sh` printed: files written, holds, any git
   hook another tool owns (print the call-through line it gives you and
   tell the user to add it there), and the canary result.

## Rules

- NEVER write `.specify/gates/policy.json`. If the release adds policy
  fields, list them and point at `/speckit.gates.propose`.
- NEVER copy runtime files by hand or `chmod` them yourself: that is
  `project.sh`'s job, and doing it file by file is what the single
  reviewable step replaces.
- NEVER pass `--take-upstream` or `--keep-local` without the user's
  decision for that file.
- A non-zero exit from `project.sh` is a failure to report, not to work
  around: 1 = a canary was accepted or a git hook needs the user,
  2 = refused before writing (read its message), 3 = local edits need a
  decision.
- Re-check the lint-scope ignores (step 3c of `/speckit.gates.init`): an
  upgrade can add projected paths.
- Tell the user that `.git/hooks` is shared by every branch while the
  projected runtime is per branch. With the stub installed, each branch
  runs its own projected hooks, so an upgrade on one branch does not
  change what another branch enforces.
