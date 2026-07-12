---
id: quality/pre-pr-verification
statement: "The full local gate runs and passes before a PR is opened; CI is a backstop, not the place bugs are first found."
rationale: "Deferring verification to CI turns the shared pipeline into a slow, noisy debugger and normalizes red."
surface: git-hook
ref: pre-commit
tags: [quality, all-projects]
provenance: "Kahi corpus (2026): pre-PR local verification, do not defer to CI"
---

The same checks CI runs are run locally and pass before a pull request is
opened. Test plans reflect tests actually executed, not intended. CI exists
to catch environment drift and the occasional escape, never as the first
place a failure is discovered.
