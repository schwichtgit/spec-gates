# Data Model: Policy as Versioned Contract

Entities, fields, relationships, and state rules. File formats are
normative in [contracts/artifact-layout.md](contracts/artifact-layout.md);
this file is the conceptual model they implement.

## Extends declaration (in the overlay, `policy.json`)

| Field     | Type   | Rules                                                              |
| --------- | ------ | ------------------------------------------------------------------ |
| `source`  | string | Required. Git URL or local path; anything git accepts as a remote. |
| `version` | string | Required. Tag or commit identifier; never a branch name.           |
| `file`    | string | Optional, default `policy.json`. Path of the baseline document.    |

Absence of the whole section = the feature is dormant (FR-001). A branch
name as `version` is refused at sync (a moving pin is not a pin).

## Pin (`baseline.lock.json`)

| Field     | Type   | Rules                                               |
| --------- | ------ | --------------------------------------------------- |
| `source`  | string | Copied from the declaration at sync time.           |
| `version` | string | The version actually fetched.                       |
| `file`    | string | The baseline document path actually read.           |
| `digest`  | string | `sha256:<hex>` of the canonicalized snapshot bytes. |

No timestamps (clean diffs; audit time lives in attestation records). The
pin is the only thing enforcement trusts: declaration ≠ pin → drift.

## Baseline snapshot (`baseline.json`)

The fetched baseline document, canonicalized (`jq -S .`), committed. Must
itself validate against the policy schema (a baseline is a policy). A
snapshot whose digest mismatches the pin is tampering — fail closed.

## Effective policy (`policy.effective.json`)

Canonicalized result of `merge(snapshot, overlay minus extends)` with the
overlay's `extends` re-attached verbatim. This is what every boundary
enforces. Byte-equality with live recomputation is proven per run.

### Merge rules (R4)

- Objects merge recursively; overlay wins on conflicts.
- Scalars and arrays replace wholesale (no unions).
- `extends` never participates in the merge; it is copied through.
- Output is canonicalized (`jq -S`) so byte-identity is stable.

## Deviation (computed, never stored)

One per baseline-vs-effective difference attributable to the overlay.

| Field   | Type   | Rules                                                              |
| ------- | ------ | ------------------------------------------------------------------ |
| `path`  | string | JSON path of the differing value (e.g. `hooks.prettier.severity`). |
| `class` | enum   | `weakened` \| `changed` (classification rules below).              |
| `from`  | string | Baseline value (stringified).                                      |
| `to`    | string | Effective value (stringified).                                     |

### Classification (R5, Clarifications)

| Condition                                                        | Class           |
| ---------------------------------------------------------------- | --------------- |
| `enabled` true → false                                           | `weakened`      |
| severity moves right along `error > warning > off`               | `weakened`      |
| `include` loses an element / `exclude` gains one (and only that) | `weakened`      |
| any other difference (commands, orchestrators, mixed list edits) | `changed`       |
| new hooks/sections added, severities raised, scopes widened      | not a deviation |

Effect on runs: none (informational lines + attestation counts only).

## Contract state machine

| State    | Condition                                                 | Gate behavior                             |
| -------- | --------------------------------------------------------- | ----------------------------------------- |
| dormant  | no `extends` in overlay                                   | no `contract` gate entry at all           |
| unsynced | `extends` present, any artifact missing                   | fail closed naming the missing artifact   |
| synced   | pin+snapshot+effective present, digests and bytes match   | pass; deviations reported informationally |
| drifted  | digest mismatch, recompute mismatch, or declaration ≠ pin | fail closed naming the drifted artifact   |

Transitions: `sync` moves unsynced/drifted → synced (same pinned version);
`sync --update` produces a reviewable change that, once merged, lands the
repo in synced at the new version; hand-edits move synced → drifted.

## Attestation extension (R10)

- GateEntry `contract` in `gates[]`: result pass/fail, `reason` names the
  drifted artifact; tool fields null (synthetic, like `parity`/`spec`).
- Optional top-level `contract` object (absent when dormant):

| Field              | Type   | Rules                                     |
| ------------------ | ------ | ----------------------------------------- |
| `source`           | string | From the pin.                             |
| `version`          | string | From the pin.                             |
| `digest`           | string | Pin digest (`sha256:<hex>`).              |
| `effective_sha256` | string | Digest of the enforced effective policy.  |
| `deviations`       | object | `{ "weakened": N, "changed": N }` counts. |

Record stays `v: 1` — additive field, consumers ignore unknown fields.

## Relationships

```text
declaration (overlay.extends) --sync--> pin + snapshot
snapshot ⊕ overlay --merge (R4)--> effective policy
snapshot vs effective --classify (R5)--> deviations[] --> gate output, attestation, propose
pin/snapshot/effective --prove (R6)--> contract gate pass|fail
pin vs source tags --sync --update (R7/R8)--> reviewable update
deviations[] --propose (R9)--> upstream change request
```
