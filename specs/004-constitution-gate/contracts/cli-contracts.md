# Contract: CLI Surfaces — constitution.sh, doctor, init hookup, command

Behavioral contracts for the deterministic runtime and the session's
integration points. Formats are in
[annotation-format.md](annotation-format.md).

## `constitution.sh` (projected next to `verify.sh`)

```text
constitution.sh fragments --corpus DIR --profile ANSWERS.json   # candidate menu, TSV
constitution.sh draft --corpus DIR --selections SEL.json --out FILE [--augment EXISTING.md]
constitution.sh align [--constitution FILE] [--policy FILE]     # proposal, TSV; never writes
constitution.sh check [--constitution FILE]                     # health verdict; exit 0/1
constitution.sh detect [--constitution FILE]                    # placeholder|absent|filled (exit 0, word on stdout)
```

Exit codes: `0` success, `1` usage/environment error, `2` contract
failure (malformed corpus, malformed selections, malformed annotations).

### `fragments`

- TSV per candidate: `tier \t id \t statement \t surface \t ref \t rationale`.
- Filtered/ranked by profile tags (a `docs` project never sees
  `project-type/infra`-tagged candidates); mandatory tier first.
- No profile → usage error (the menu is never unfiltered by accident).

### `draft`

- Deterministic: identical inputs → byte-identical output (tested).
- Every accepted/custom selection MUST carry a surface decision; a
  selection without one is a contract failure (FR-004) — the session
  cannot even materialize an unannotated acceptance.
- `--augment`: existing content preserved verbatim; annotations inserted
  after their principles; additions appended per template section order;
  output still one valid constitution document.
- Output is a DRAFT file (caller-supplied path); this subcommand never
  touches `.specify/memory/`.

### `align`

- TSV per annotated principle:
  `principle \t surface \t ref \t state \t proposed-change`
  with `state ∈ active | missing | pending-boundary`.
- Policy surfaces are evaluated against the enforced policy (the 003
  effective policy when a contract is live); proposed policy changes
  always target the OVERLAY.
- Pure computation: no file writes, no network, ≤ 1s on a normal repo.

### `check`

- One line per principle: `enforced | gap | prose-only` (+ one summary
  line counting unannotated principles when > 0).
- Exit 1 iff at least one `gap` or malformed marker; prose-only and
  unannotated never fail (FR-009, FR-013, Clarifications).
- Reads only local files; usable standalone and by doctor.

### `detect`

- Prints `absent`, `placeholder` (bracket-token signature or byte-equal
  to the shipped template), or `filled`. Used by init (FR-014) and the
  session's mode selection (fresh vs augment).

## `doctor.sh` — constitution section

- Runs when a constitution exists AND contains at least one
  `gates:enforce` marker; otherwise at most one informational line
  ("constitution has no enforcement annotations — /speckit.gates.constitution
  can add them") and no failure (FR-013).
- Reports per principle enforced/gap/prose-only via `constitution.sh
check` semantics; any gap or malformed marker → doctor exit 1 naming
  principle + surface (+ line for malformed).
- Local information only; ≤ 1s (SC-004).

## `speckit.gates.constitution` command (the session)

- Interview → profile; menu via `fragments`; per-candidate decisions
  (accept / adapt / decline; surface confirm or override; prose-only is
  an explicit choice) → selections; `draft`; full diff shown; approval
  writes `.specify/memory/constitution.md`; then the alignment flow
  (`align` → per-change approvals → apply via the existing wiring steps);
  final report = sync-impact summary (principle → surface → change).
- Refuses non-interactive invocation without `--answers`+`--selections`
  files (FR-006).
- Ends by pointing at the core `/speckit-constitution` command for
  versioning/ratification (FR-012); registered as the extension's
  `before_constitution` hook with `optional: true`.

## `speckit.gates.init` hookup (FR-014)

- After policy inference, init runs `constitution.sh detect`; on
  `absent`/`placeholder` it OFFERS the session (one question, default
  skip) and continues init regardless of the answer. The final init
  report includes the constitution state either way.

## `extension.yml`

- `speckit.gates.constitution` registered (8 commands total).
- `hooks.before_constitution` → `speckit.gates.constitution`,
  `optional: true`, prompt naming what it does.
