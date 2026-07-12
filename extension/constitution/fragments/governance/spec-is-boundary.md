---
id: governance/spec-is-boundary
statement: "Features run as numbered specs with executable acceptance criteria; a spec marked complete is enforced, not asserted."
rationale: "A spec whose completion is asserted rather than enforced drifts exactly like an unverified gate."
surface: ci
ref: gates
tags: [governance, all-projects]
provenance: "spec-gates constitution v1.0.0 (2026): the spec is a boundary"
---

Enhancements run as numbered specifications through the specify → plan →
tasks → implement flow, and their success criteria land as executable
acceptance checks. A feature marked complete is held to those checks on every
run: an unchecked task or a failing criterion blocks, so completion is proven
rather than declared.
