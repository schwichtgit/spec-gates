---
id: workflow/rebase-before-pr
statement: "Branches rebase onto the latest main before a PR is opened or updated, and are verified not-yet-merged before more work lands."
rationale: "A stale branch hides conflicts until merge and invites duplicate work on an already-merged change."
surface: prose
tags: [workflow, all-projects]
provenance: "accelno multi-repo corpus (2026): rebase-before-PR, verify-PR-not-merged discipline"
---

Before opening or updating a pull request, the branch is rebased onto the
current `main`. Before resuming work on an existing branch, its merge status
is checked — continuing on an already-merged branch is a common source of
lost or duplicated changes.
