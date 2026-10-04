---
description: "Sync the policy baseline contract: pin, snapshot, and materialize the effective policy (--update moves the pin as a reviewable change)"
---

# Sync Policy Baseline

Fetch the baseline policy that `policy.json` extends, pin it (version +
content digest), snapshot it, and materialize the merged effective policy
that every boundary enforces. This is the ONLY moment the contract
machinery touches the network; gate runs prove drift offline.

## User Input

```text
$ARGUMENTS
```

Optional: `--update [VERSION]` — move the pin to VERSION (or the highest
version tag at the source when omitted) as a reviewable change on its own
branch. Plain sync never moves a pin; it (re-)materializes the declared
version.

## Steps

1. Confirm `.specify/gates/contract.sh` exists; if not, direct the user to
   `/speckit.gates.init` (or `/speckit.gates.upgrade`) and STOP.
2. If `policy.json` has no `extends` section, explain that the repo
   inherits no baseline and show the declaration shape
   (`"extends": { "source": "<git url or path>", "version": "<tag or commit>" }`),
   then STOP.
3. Run `bash .specify/gates/contract.sh sync` (append `--update` and the
   version argument if requested). Stream output to the user.
4. On success, show the deviation inventory the command printed and remind
   the user to COMMIT the three artifacts (`baseline.json`,
   `baseline.lock.json`, `policy.effective.json`) — they are contract
   state, not build output. They are protected files: the commit needs a
   `Protected-Change: <path>` trailer for each artifact it changes (and
   for `policy.json` when that changed too) plus `Approved-By: <name>`
   naming the human who approves the change. You cannot edit the
   artifacts yourself; only `contract.sh sync` writes them. For
   `--update`, nothing is committed on the current branch: the command
   commits the artifacts and the new `extends.version` in `policy.json`
   on its own branch, with the trailers already in place
   (`Approved-By` names the git committer running it: the committer
   name, or the local part of the committer email when the message
   rules refuse the name, else `the committer of this commit`). Point at
   the created
   `gates/baseline-<version>` branch or opened PR instead; enforcement
   follows only when it merges. The commit body names changed paths with
   counts or `from -> to` for booleans, numbers and severities, never
   quoted policy text, so a baseline that adds a branding term cannot
   make commit-msg refuse it. In a repo with
   `git.protected_change_trailer: false`, pre-commit still lets this one
   commit through: it verifies that the staged change is exactly
   `policy.json` (its `extends.version` only) plus the three artifacts,
   consistent with the pin, on the matching `gates/baseline-<version>`
   branch. Any other change to those files stays refused there.
5. On failure, relay the named cause (branch-name version, chained
   baseline, schema-invalid baseline, unreachable source, or a git hook
   that refused the `--update` commit; the branch is then removed, so
   fix the cause and re-run). Never edit the
   artifacts by hand to make a failure disappear — the contract gate
   proves them against recomputation on every run.
