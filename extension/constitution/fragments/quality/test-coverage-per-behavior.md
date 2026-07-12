---
id: quality/test-coverage-per-behavior
statement: "Every behavior lands with test coverage, and every bug fix lands with a regression case."
rationale: "Coverage argued rather than written drifts exactly like an unverified gate; the test is the record."
surface: prose
tags: [quality, all-projects]
provenance: "spec-gates constitution v1.0.0 (2026): every behavior lands with suite coverage"
---

New behavior is not considered done until it carries automated test coverage,
and each bug fix carries a regression case. Test suites are registered in the
project's canonical runner so coverage is executed, not merely claimed.
