---
id: quality/changed-files-scoped
statement: "Enforcement is scoped to changed files with legacy debt grandfathered; whole-repo debt never blocks a focused change."
rationale: "A gate that fails on pre-existing debt gets disabled; scoping to the diff keeps enforcement credible and adoptable."
surface: ci
ref: gates
tags: [quality, all-projects]
provenance: "accelno cortex/halo/excel corpus (2026): 85% diff coverage, whole-repo debt grandfathered"
---

Quality gates evaluate the files a change actually touches. Pre-existing
violations in untouched code are grandfathered and tracked separately, so a
small change is never blocked by debt it did not introduce and the gate stays
worth keeping on.
