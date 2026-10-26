---
id: architecture/one-policy-many-boundaries
statement: "One policy drives every enforcement boundary, and cross-boundary parity is verified rather than asserted."
rationale: "Boundaries an agent can rewrite are only trustworthy if a boundary it cannot rewrite provably runs every check the policy demands."
surface: policy
ref: attestation.parity
expect: error
tags: [architecture, all-projects, posture/security-hardened]
provenance: "spec-gates constitution v1.1.0 (2026): one policy, three boundaries; CI runs the full policy; parity verified"
---

A single policy file is the source of enforcement truth, and the same entry
point runs it at every boundary — local, commit, and CI. CI runs the whole
policy; an earlier boundary skips only what the policy declares, and names
each skip. Parity is checked on each run, so the boundaries an actor could
rewrite are backstopped by the ones it cannot.
