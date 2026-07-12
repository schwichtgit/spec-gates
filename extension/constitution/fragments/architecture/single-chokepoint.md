---
id: architecture/single-chokepoint
statement: "Each cross-cutting concern flows through exactly one chokepoint; there is no supported bypass around it."
rationale: "Multiple entry points to the same concern guarantee one is eventually forgotten in a security or correctness path."
surface: prose
tags: [architecture, all-projects]
provenance: "accelno corpus (2026): Nexus data access, baseQueryWithReauth, sanitizeForExcel single chokepoints"
---

Every instance of a cross-cutting concern — data access, auth refresh, output
sanitization — passes through a single function or module. Callers use the
chokepoint or do not perform the operation; there is no second path that
skips the invariant it enforces.
