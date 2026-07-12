---
id: governance/no-coding-before-spec
statement: "No implementation code is written before the feature's spec and plan exist and are agreed."
rationale: "Code written ahead of its spec anchors the design to the first guess and makes the spec a post-hoc rationalization."
surface: prose
tags: [governance, workflow, posture/team]
provenance: "Kahi + CPF-8 corpus (2026): sequential specify-plan-tasks-implement workflow"
---

Implementation does not begin until the feature has an agreed specification
and plan. The workflow is sequential — specify, then plan, then tasks, then
implement — so the design decisions are made and reviewed before code commits
the project to them.
