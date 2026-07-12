---
id: governance/provable-enforcement
statement: "Every gate class re-proves itself: it leaves an attestation and a canary that plants a violation and requires rejection."
rationale: "Coverage argued is coverage lost; a red canary catches a broken gate before an incident does."
surface: ci
ref: gates
tags: [governance, posture/security-hardened, posture/regulated]
provenance: "spec-gates constitution v1.0.0 (2026): provable enforcement, attest + canary per gate class"
---

Each enforcement class emits evidence of what it checked and ships a canary
that plants a known violation and requires the real entry point to reject it.
A new gate is not done until its canary and attestation surface exist, so a
gate that silently stops gating is caught by a red proof step.
