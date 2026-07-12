---
id: quality/fail-loudly
statement: "Errors surface loudly and are diagnosed at the root; no silent recovery, no fabricated or placeholder data shown as real."
rationale: "Silent recovery and stand-in data hide the failure until it compounds; a loud stop is cheaper than a quiet lie."
surface: prose
tags: [quality, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026): fail loudly / never fabricate"
---

Failures are made visible and traced to their root cause before work
continues. The system does not silently swallow an error, retry into a
degraded state, or present fabricated or placeholder values as if they were
real results.
