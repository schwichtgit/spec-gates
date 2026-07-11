# Contract: Enforcement Annotations, Fragments, and the Corpus Registry

Normative formats for the three durable artifacts this feature reads and
writes. The conversational session is NOT part of this contract; anything
here must be producible and consumable by the deterministic runtime alone.

## Enforcement annotation marker

An HTML comment on its own line, immediately following the principle's
heading (or the first line of a list-style principle):

```text
<!-- gates:enforce surface=policy ref=spec.severity expect=error -->
<!-- gates:enforce surface=agent-hook ref=validate-bash.sh -->
<!-- gates:enforce surface=git-hook ref=commit-msg -->
<!-- gates:enforce surface=ci ref=gates -->
<!-- gates:enforce surface=accept ref=004-constitution-gate/SC-002 -->
<!-- gates:enforce surface=scanner ref=checkov:CKV_GCP_117 -->
<!-- gates:enforce surface=prose -->
```

Grammar rules:

1. Tag is exactly `gates:enforce`; unknown tags in comments are ignored.
2. `surface=` is required, from the fixed v1 set
   `policy | agent-hook | git-hook | ci | accept | scanner | prose`.
3. `ref=` is required for every surface except `prose`. Values must not
   contain whitespace; the surface-specific formats are the R4 table's.
4. `expect=` is optional and only meaningful for `surface=policy`.
5. At most one marker per principle. A second marker before the next
   principle heading is malformed.
6. Malformed markers (unknown surface, missing ref, unparseable pairs)
   are FAIL-CLOSED: doctor and `constitution.sh check` fail naming
   `constitution.md:<line>`.
7. Principles without a marker are unannotated: legal, reported once
   informationally, never a failure (FR-013).

Durability requirements: markers must survive prettier formatting, the
core constitution command's fill/version/sync-impact pass, and hand
edits to surrounding prose (the marker binds by position — directly
after its principle's heading — so moving a principle means moving its
marker line with it).

## Fragment file (`fragments/<category>/<name>.md`)

YAML frontmatter + markdown body:

```text
---
id: workflow/branch-first
statement: "All changes reach main via pull request; never commit to main."
rationale: "Every CPF-era repo converged on this; direct-to-main commits were the top pre-CPF incident source."
surface: git-hook
ref: pre-commit
tags: [workflow, all-projects]
provenance: "CPF-8 baseline (accelno corpus, 2026)"
---

All changes reach `main` via pull request. Direct commits to `main` are
refused at the git boundary; a release-only escape hatch requires an
explicit per-commit override variable.
```

Rules: `id`, `statement`, `rationale`, `surface`, `provenance` required;
`ref` required unless `surface: prose`; `tags` drive profile filtering;
the body is what lands in a constitution (possibly user-adapted). The
frontmatter is this feature's contract; the body alone must remain a
valid charter fragment (FR-011 interop).

## Corpus registry

```text
<registry-root>/
├── manifest.yml
└── fragments/
    └── <category>/<name>.md
```

`manifest.yml` (charter-compatible):

```yaml
name: "spec-gates starter corpus"
mandatory_fragments:
  - "security/no-secrets"
  - "workflow/branch-first"
recommended_fragments:
  - "quality/changed-files-clean"
optional_fragments:
  - "infra/least-privilege"
```

Tiers shape the session's presentation (mandatory candidates are
presented first and declining one requires typing a reason into the
session log), never auto-acceptance — FR-006 holds even for mandatory
fragments. The bundled corpus lives at `extension/constitution/`;
remote registries are git sources fetched at session time via the 003
fetch machinery (tag/commit pinned, never at doctor/verify time).
