---
id: security/secret-rotation
statement: "Exposure is rotation: any credential that appears in a diff, log, or ticket is revoked and reissued, not merely deleted."
rationale: "Deleting a leaked value from HEAD leaves it live in history and in every clone; only rotation actually closes the exposure."
surface: prose
tags: [security, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026)"
---

A credential that appears anywhere it should not — a diff, a log line, a
paste in an issue — is considered compromised. The response is to revoke and
reissue it, then purge the copy. Deletion without rotation is theater.
