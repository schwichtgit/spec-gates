---
id: workflow/worktree-safety
statement: "Git operations target an explicit absolute path (git -C) after a pre-write check; never assume the current worktree or branch."
rationale: "Hand-copied into three repos after real branch-swap accidents wrote changes to the wrong tree."
surface: prose
tags: [workflow, all-projects]
provenance: "accelno multi-repo corpus (2026): git -C worktree safety, pre-write checklist"
---

Scripted git operations name their target explicitly with `git -C <abs-path>`
and verify branch and worktree state before writing. No step assumes it is
running in the intended checkout; a wrong assumption here corrupts the wrong
repository silently.
