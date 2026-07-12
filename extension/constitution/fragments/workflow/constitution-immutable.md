---
id: workflow/constitution-immutable
statement: "The constitution changes only by explicit human approval, never as a side effect of automated work."
rationale: "A governance document an agent can quietly edit is not governance; the ratchet must require a person."
surface: agent-hook
ref: protect-files.sh
tags: [workflow, governance, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026): constitution immutable without human approval"
---

The constitution is amended only through a reviewed change with explicit
human approval. Automated tooling and agents may propose amendments but may
not apply them; the protected-files boundary refuses edits to the
constitution outside that flow.
