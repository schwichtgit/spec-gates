# Data Model: Constitution as Enforceable Contract

Entities and state rules. Normative formats live in
[contracts/annotation-format.md](contracts/annotation-format.md).

## Principle fragment (corpus entry)

| Field        | Type     | Rules                                                                                     |
| ------------ | -------- | ----------------------------------------------------------------------------------------- |
| `id`         | string   | `<category>/<name>`, unique in the registry.                                              |
| `statement`  | string   | One-sentence plain-language rule. Required.                                               |
| `rationale`  | string   | The failure this rule prevents. Required (credibility, FR-003).                           |
| `surface`    | enum     | Proposed surface: `policy \| agent-hook \| git-hook \| ci \| accept \| scanner \| prose`. |
| `ref`        | string   | Surface-specific identifier (absent for prose).                                           |
| `expect`     | string   | Optional expected value (policy surfaces).                                                |
| `tags`       | string[] | Applicability: `project-type/*`, `posture/*`, topic tags.                                 |
| `provenance` | string   | Where this rule earned its keep. Required.                                                |
| body         | markdown | The principle text as it should appear in a constitution.                                 |

## Corpus / registry

Charter-compatible: `manifest.yml` (name; `mandatory_fragments`,
`recommended_fragments`, `optional_fragments` id lists) +
`fragments/<category>/<name>.md`. One bundled (offline, versioned with
the extension); remote registries optional, fetched at session time only.

## Interview profile (`answers.json`)

| Field          | Type   | Rules                                                        |
| -------------- | ------ | ------------------------------------------------------------ |
| `project_type` | string | e.g. `service`, `cli`, `spa`, `library`, `infra`, `docs`.    |
| `quality`      | object | posture answers (tests required?, coverage discipline, ...). |
| `security`     | object | posture answers (secrets handling, supply chain, ...).       |
| `workflow`     | object | discipline answers (branch policy, review, commits, ...).    |

Produced by the interview (or supplied by tests/non-interactive runs).
The profile filters and ranks fragments; it never auto-accepts any.

## Selections (`selections.json`)

| Field        | Type     | Rules                                                                                                                                      |
| ------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `accepted[]` | object[] | `{ id, surface, ref, expect?, adapted_body? }` — surface decision may override the fragment's proposal; `adapted_body` carries user edits. |
| `custom[]`   | object[] | `{ title, body, surface, ref?, expect? }` — user-authored principles; same annotation obligation (FR-004).                                 |
| `declined[]` | string[] | Fragment ids declined — recorded for the session log only, never in the constitution.                                                      |

## Enforcement annotation (in the constitution)

One inline HTML comment marker per principle:
`<!-- gates:enforce surface=<type> ref=<id> [expect=<value>] -->` or
`<!-- gates:enforce surface=prose -->`. Malformed marker → doctor failure
naming the line. Unannotated principle → informational only (FR-013).

## Alignment proposal (computed, never stored)

One row per annotated principle:

| Field       | Type   | Rules                                                       |
| ----------- | ------ | ----------------------------------------------------------- |
| `principle` | string | Heading/first line of the annotated principle.              |
| `surface`   | enum   | From the annotation.                                        |
| `ref`       | string | From the annotation.                                        |
| `state`     | enum   | `active \| missing \| pending-boundary` (prose excluded).   |
| `change`    | string | Proposed concrete change when `missing`; empty when active. |

Applying changes is the session's job, change-by-change, after explicit
approval; a 003-contract repo receives policy changes in the OVERLAY.

## Constitution health report (doctor section)

Per principle: `enforced` (surface active) / `gap` (missing or inactive —
doctor exit 1, principle + surface named) / `prose-only` (listed, never
failed) / `unannotated` (counted in one informational line). Malformed
markers are failures (fail closed).

## State rules

- Draft assembly is deterministic: same corpus + selections (+ existing
  constitution in augment mode) → byte-identical draft.
- Augment mode: existing principles preserved verbatim; annotations added
  beside them; new principles appended in the template's section order;
  nothing removed or rewritten without the diff being shown and approved.
- Decline paths (draft not approved, alignment not approved) leave the
  repository byte-identical (SC-003).

## Relationships

```text
corpus fragments ──(profile filter/rank)──> candidate menu
candidate menu + human decisions ──> selections.json
selections ──(draft, deterministic)──> annotated constitution draft ──(approval)──> .specify/memory/constitution.md
annotations ──(align)──> alignment proposal ──(per-change approval)──> policy/hooks/CI/accept/scanner changes
annotations ──(check / doctor)──> health report (enforced | gap | prose-only)
core /speckit-constitution ──(versioning, sync-impact)──> ratified constitution (annotations survive)
```
