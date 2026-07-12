---
id: security/least-privilege
statement: "Grants are least-privilege by default: no basic roles, no public principals, no long-lived keys where federation is possible."
rationale: "Recurred across every infra repo; broad grants are the reversible mistake that is never actually reversed."
surface: scanner
ref: checkov:CKV_GCP_117
tags: [security, project-type/infra, posture/regulated]
provenance: "accelno gitops corpus (2026): Checkov CKV_GCP_117, WIF-only, no SA keys"
---

Access is granted at the narrowest scope that works. Primitive or basic
roles, `allUsers` / `allAuthenticatedUsers` bindings, and long-lived service
account keys are prohibited; workload identity federation is used wherever
the platform supports it.
