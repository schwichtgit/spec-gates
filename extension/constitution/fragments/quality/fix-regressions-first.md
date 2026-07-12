---
id: quality/fix-regressions-first
statement: "A regression is fixed before new work proceeds, and it lands with a test that fails on the pre-fix code."
rationale: "Deferred regressions accumulate into a permanently red baseline that trains everyone to ignore failures."
surface: prose
tags: [quality, all-projects]
provenance: "Kahi corpus (2026): fix regressions before new work"
---

When a change breaks existing behavior, the regression is fixed before new
work continues. Each fix ships with a regression test that fails against the
pre-fix code, so the same break cannot recur unnoticed.
