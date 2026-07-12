---
id: security/no-secrets
statement: "No secret ever enters the repository, its history, or its logs; a leaked credential is rotated before anything else."
rationale: "Every CPF-era repo converged on this after a real incident; git history is forever and a committed key is a live key."
surface: scanner
ref: gitleaks:default
tags: [security, all-projects, posture/security-hardened]
provenance: "CPF-8 baseline (accelno corpus, 2026); excel constitution names leaked-key commit 2cf8bcc"
---

Secrets never enter the repository, its history, or its logs. Credentials
live in the environment or a secret manager, never in tracked files. A key
that reaches the history is treated as compromised and rotated immediately —
removal from `HEAD` is not remediation.
