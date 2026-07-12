---
id: governance/fail-closed
statement: "Anything the enforcement layer cannot read, parse, or run produces a red result — never a silent skip."
rationale: "A gate that quietly stops gating is worse than no gate: it leaves the belief of coverage behind."
surface: prose
tags: [governance, all-projects, posture/security-hardened]
provenance: "spec-gates constitution v1.0.0 (2026): fail closed"
---

When the enforcement layer meets something it cannot read, parse, or
demonstrably execute, it fails the run and names the cause at `file:line`. A
malformed rule, an unreadable criterion, or a missing tool the policy enables
is an enforcement gap that blocks — it is never reported as a pass.
