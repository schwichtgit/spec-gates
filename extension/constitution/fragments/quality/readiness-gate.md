---
id: quality/readiness-gate
statement: "Implementation does not begin until a spec, plan, and feature entry exist and a weighted readiness score clears the bar."
rationale: "Coding into an underspecified problem produces rework; the readiness gate front-loads the cheap decisions."
surface: prose
tags: [quality, posture/team, posture/regulated]
provenance: "Kahi corpus (2026): no coding until spec+plan+feature entry and readiness score >= 80"
---

Work on a feature starts only after its specification, plan, and feature
entry exist and a weighted readiness rubric clears the project's threshold.
The score is computed, not asserted, so an unready feature is caught before
code is written rather than during review.
