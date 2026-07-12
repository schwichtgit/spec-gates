---
id: workflow/conventional-commits
statement: "Commits follow Conventional Commits: an enumerated type, a subject of 72 characters or fewer, no emoji, no AI-attribution trailers."
rationale: "A machine-readable history is what makes changelogs, release automation, and blame legible; drift here is silent debt."
surface: git-hook
ref: commit-msg
tags: [workflow, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026): types enumerated, no-emoji/no-AI-isms/no Co-Authored-By"
---

Commit subjects follow Conventional Commits with a type from the project's
enumerated set and a subject line of 72 characters or fewer. Emoji,
marketing language, and AI-attribution trailers are refused at the commit-msg
boundary.
