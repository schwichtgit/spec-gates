---
id: quality/lockfile-committed
statement: "Dependencies are pinned by a committed lockfile, and resolved tool versions are verified against it on every run."
rationale: "An unpinned toolchain makes local and CI silently disagree; the lockfile is the shared source of parity truth."
surface: policy
ref: attestation.parity
expect: error
tags: [quality, project-type/service, project-type/spa]
provenance: "accelno multi-repo corpus (2026): lockfile committed on every dep install"
---

Every dependency install commits the resulting lockfile in the same change.
Linters and build tools resolve from the pinned set, and a parity check
compares resolved versions against the lockfile on every gate run so local
and CI cannot drift apart unnoticed.
