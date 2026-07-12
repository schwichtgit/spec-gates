---
id: architecture/projection-not-dependency
statement: "Shared runtime is copied into the repository, not resolved from an installed tool; enforcement survives the installer's removal."
rationale: "A layer that disappears with its installer, or needs network to run, fails exactly when it is needed most."
surface: prose
tags: [architecture, posture/team]
provenance: "spec-gates constitution v1.0.0 (2026): projection, not dependency"
---

Enforcement and shared tooling are projected — copied — into the repository
rather than symlinked or resolved from an external install. The runtime works
on a fresh clone, offline, and after the tool that installed it is gone;
drift between source and copy is managed explicitly, not wished away.
