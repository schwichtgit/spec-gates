# Contract: Extends Declaration and Contract Artifacts

Normative formats for the `extends` policy section and the three derived
artifacts. What sync writes, what the gate proves, what users commit.

## `extends` section (in `policy.json`, the overlay)

```json
{
  "extends": {
    "source": "https://github.com/acme/policy-baseline",
    "version": "v2.3.0",
    "file": "policy.json"
  }
}
```

| Field     | Required | Rules                                                                       |
| --------- | -------- | --------------------------------------------------------------------------- |
| `source`  | yes      | Any value git accepts as a remote: https/ssh URL, `file://`, or local path. |
| `version` | yes      | Tag or commit identifier. Branch names are refused at sync time.            |
| `file`    | no       | Path of the baseline document inside the source. Default `policy.json`.     |

`additionalProperties: false`. The section is validated by
`gates_validate_policy` like every other section; a policy with a malformed
`extends` is invalid (fail closed, never ignored).

## Derived artifacts (written by sync, committed, never hand-edited)

All three live in `.specify/gates/` beside `policy.json` and are
canonicalized with `jq -S .` (sorted keys, one trailing newline) so that
byte-identity is a stable, recomputable property.

### `baseline.json` — snapshot

The baseline document exactly as fetched at the pinned version, after
canonicalization. Must itself validate against `policy.schema.json` (with
one exception: a baseline MUST NOT contain `extends` — single-level
inheritance; sync refuses a chained baseline).

### `baseline.lock.json` — pin

```json
{
  "digest": "sha256:0a1b…",
  "file": "policy.json",
  "source": "https://github.com/acme/policy-baseline",
  "version": "v2.3.0"
}
```

- `digest` is the SHA-256 of the canonicalized snapshot bytes.
- No timestamps, no resolved-commit field beyond `version` as given —
  audit metadata belongs to attestation records.

### `policy.effective.json` — materialized policy

```text
effective = canonicalize( (snapshot * (overlay - extends)) + overlay.extends )
```

- jq recursive object-merge (`*`): objects merge recursively, overlay wins;
  scalars and arrays replace wholesale (no unions).
- The overlay's `extends` is excluded from the merge and re-attached
  verbatim (traceability; the effective file records its own provenance).
- Every boundary reads this file when it exists and the overlay declares
  `extends`; `GATES_POLICY_FILE` env override retains absolute precedence.

## Invariants the `contract` gate proves per run (offline)

| #   | Invariant                                                     | On violation (fail closed, exit 2)               |
| --- | ------------------------------------------------------------- | ------------------------------------------------ |
| 1   | pin, snapshot, and effective all exist                        | `contract: not synced (<file> missing)`          |
| 2   | `sha256(baseline.json)` equals lock `digest`                  | `contract: baseline snapshot does not match pin` |
| 3   | overlay `extends` equals lock `source`/`version`/`file`       | `contract: declaration changed since last sync`  |
| 4   | recomputed merge equals `policy.effective.json` byte-for-byte | `contract: effective policy drifted`             |

Evaluation order is the table order: the declaration check precedes the
recompute so that an edited `extends` gets the precise message (an edited
declaration also perturbs the merge, which would otherwise mask it as
generic drift).

A repo whose overlay has no `extends` is exempt from all four (dormant).
Deviations (see data-model classification) are reported informationally and
never affect the exit code.

## Git expectations

- The three artifacts are committed; adding them to ignore files defeats
  the contract and is not supported.
- `policy.json` remains the only user-edited policy file; sync never
  writes it, and `upgrade` continues to never touch any of the four.
