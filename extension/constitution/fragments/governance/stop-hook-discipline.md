---
id: governance/stop-hook-discipline
statement: "A working session cannot end while quality checks are red; the stop boundary blocks handoff on failure."
rationale: "Ending on red normalizes red; the stop hook makes a clean tree the precondition for finishing, not a hope."
surface: agent-hook
ref: verify-quality.sh
tags: [governance, quality]
provenance: "Kahi corpus (2026): stop-hook blocks session end until lint/tests pass"
---

The session-stop boundary refuses to conclude while lint or tests are
failing. Finishing requires a green local run, so a session hands off a clean
tree rather than deferring known failures to the next person or the next
pipeline run.
