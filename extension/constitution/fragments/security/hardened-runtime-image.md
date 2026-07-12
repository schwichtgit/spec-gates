---
id: security/hardened-runtime-image
statement: "Production images are minimal and non-root: distroless or equivalent, no shell, static binaries where the language allows."
rationale: "Smaller attack surface and no ambient shell turns a code-execution bug into a dead end instead of a foothold."
surface: scanner
ref: hadolint:DL3002
tags: [security, project-type/service, posture/security-hardened]
provenance: "accelno service corpus (2026): distroless/nonroot, CGO_ENABLED=0 static binaries"
---

Runtime images ship the application and nothing else: a distroless or
scratch base, a non-root user, and no package manager or shell. Compiled
languages produce static binaries so the runtime layer carries no
interpreter to abuse.
