---
id: quality/tracking-file-immutability
statement: "Machine-owned tracking files change only through their tool; humans do not hand-edit status to make a gate pass."
rationale: "A tracking file edited by hand records belief, not fact, and the gate reading it then enforces the belief."
surface: agent-hook
ref: protect-files.sh
tags: [quality, workflow, all-projects]
provenance: "Kahi corpus (2026): tracking-file immutability, only status fields change via the tool"
---

Files that record generated state — task status, coverage ledgers, readiness
scores — are updated only by the tooling that owns them. Hand-editing a
tracking file to flip a status is prohibited; the underlying work is done so
the tool records the change itself.
