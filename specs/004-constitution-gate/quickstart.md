# Quickstart Validation: Constitution as Enforceable Contract

Runnable scenarios proving the feature end-to-end, mapped to the success
criteria. Same doctrine as 001–003: nothing counts as verified until it
has blocked (or passed) for real. Scenarios drive the deterministic
pipeline with fixture answers/selections files — no conversation
simulation needed; the session layer adds only approval prompts on top
of exactly these calls.

**Prerequisites**: repo checkout with the runtime projected, `jq`.
Everything below is offline (bundled corpus only).

## Scenario 1 — Menu, draft, annotations (US1, SC-001, SC-005)

In a fixture project with no constitution:

```sh
bash .specify/gates/constitution.sh detect                 # -> absent
bash .specify/gates/constitution.sh fragments --corpus extension/constitution --profile answers.json
bash .specify/gates/constitution.sh draft --corpus extension/constitution --selections sel.json --out draft.md
```

**Expected**: candidates arrive as tier/statement/surface/rationale rows
filtered by the profile (a `docs` profile sees no infra fragments); the
draft contains exactly the selected principles, each followed by its
`gates:enforce` marker (or `surface=prose`), zero bracket placeholders;
identical inputs reproduce a byte-identical draft; a selection missing
its surface decision is refused (exit 2).

## Scenario 2 — Augment mode preserves a hand-written constitution (FR-010)

Run `draft --augment` against a fixture with an existing, hand-authored
constitution and a selections file adding two principles and annotating
one existing principle.

**Expected**: every existing line survives verbatim; the existing
principle gains its marker in place; additions are appended in section
order; the result still parses as one constitution (`check` runs on it).

## Scenario 3 — Alignment proposal, approval, and the decline guarantee (US2, SC-002, SC-003)

In a synced fixture with an annotated constitution whose policy surface
is not yet configured:

```sh
bash .specify/gates/constitution.sh align
```

**Expected**: the proposal lists the policy principle as `missing` with a
concrete overlay change, already-wired principles as `active`, and a
`ci`-surface principle in a repo with no CI boundary as
`pending-boundary`. Applying the change (as the session would, after
approval) then re-running `align` shows all `active`. Hash the fixture
tree, run `align` again and decline everything — the tree hash is
unchanged (SC-003: byte-identical on decline).

## Scenario 4 — The gap is caught, permanently (US3, SC-002)

With all surfaces active:

```sh
bash .specify/gates/constitution.sh check && bash .specify/gates/doctor.sh
```

**Expected**: check exit 0, every principle `enforced` (prose-only listed
as such); doctor's constitution section green. Now disable one surface
(set the policy key to `false` / chmod -x the named hook / delete the CI
job line) → both `check` and `doctor` **exit 1 naming the principle and
the surface**. A malformed marker (unknown surface) also fails, naming
`constitution.md:<line>`.

## Scenario 5 — Opt-out repos are untouched (FR-013, SC-006)

Run `doctor` in a fixture whose constitution has no markers, and in one
with no constitution at all.

**Expected**: at most one informational line, exit unaffected; `verify.sh`
output byte-identical to a pre-004 runtime on the same fixture; existing
suites pass unmodified.

## Scenario 6 — Init offers the session (FR-014)

In a fixture with a placeholder constitution, follow
`speckit.gates.init.md`'s flow.

**Expected**: init's constitution step surfaces the offer (via `detect` →
`placeholder`), proceeds normally on decline, and the final report names
the constitution state.

## Scenario 7 — Dogfood closure (SC-007)

Run the session in augment mode on THIS repository's constitution:
annotate the five principles (candidate surfaces: I → policy severities +
fail-closed defaults; II → ci `gates` check + canary suite presence;
III → parity gate policy key; IV → projection files; V → spec gate policy
key), apply the alignment, and run doctor.

**Expected**: every annotated principle reports `enforced`; the repo's
gate stays green; the annotations survive a subsequent
`/speckit-constitution` versioning pass (markers intact in the diff).

## Scenario 8 — Budgets and suites (SC-004, SC-006)

```sh
time bash .specify/gates/constitution.sh check    # ≤ 1s
bash tests/run.sh                                 # all suites incl. test-constitution
```

**Expected**: check within budget; all suites green on macOS/BSD and
Linux/GNU.
