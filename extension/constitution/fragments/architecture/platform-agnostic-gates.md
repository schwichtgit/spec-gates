---
id: architecture/platform-agnostic-gates
statement: "Gate principles are defined abstractly and separately from their per-platform implementations."
rationale: "Coupling a principle to one CI vendor strands it when the platform changes; the abstract rule outlives the tool."
surface: prose
tags: [architecture, project-type/infra, posture/team]
provenance: "Kahi corpus (2026): abstract gate principles separate from github/gitlab/jenkins implementations"
---

Enforcement principles are written independently of any single CI platform,
with the platform-specific wiring kept in separate, swappable implementations.
Moving from one pipeline vendor to another re-implements the wiring without
touching the principle it satisfies.
