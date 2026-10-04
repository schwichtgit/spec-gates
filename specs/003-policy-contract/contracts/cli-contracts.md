# Contract: CLI Surfaces — contract.sh, verify.sh, doctor.sh, attestation

Behavioral contracts for the new entry script, the gate wiring, and the
evidence surfaces. Artifact formats are in
[artifact-layout.md](artifact-layout.md).

## `contract.sh` (projected next to `verify.sh`)

```text
contract.sh sync                     # fetch the DECLARED version; write pin+snapshot+effective
contract.sh sync --update [VERSION]  # move the pin: to VERSION, or to the highest tag when omitted
contract.sh propose [--rationale T]  # package overlay deviations as an upstream change request
```

Exit codes: `0` success (including "nothing to propose"), `1` usage or
environment error, `2` contract failure (fetch failed, digest mismatch,
schema-invalid baseline, chained baseline, branch-name version).

### `sync` (no flags)

- Reads `extends` from `policy.json`; absent → message + exit 0 (no-op).
- `policy.json` is a partial policy: it may be only `{ "extends": … }`, a
  hook entry may set only the fields it changes (no `severity`), and
  `null` removes a baseline hook. Its values are checked before the
  fetch; the merged effective policy is validated strictly.
- Fetches `source@version` (R2: shallow-by-tag first, full-clone
  fallback), refuses branch names and chained baselines.
- Validates the fetched baseline against the policy schema; validates the
  resulting effective policy too — both fail closed leaving prior
  artifacts untouched.
- Writes the three artifacts canonicalized; prints the deviation
  inventory; never touches `policy.json`; never creates commits.

### `sync --update [VERSION]`

- With `VERSION`: exactly that version. Without: highest tag from
  `git ls-remote --tags` by the awk segment-comparator (R7).
- Target equals current pin → "already up to date", exit 0, no artifacts
  touched.
- Otherwise, in a git work tree: creates branch `gates/baseline-<version>`
  from the current HEAD, writes the three artifacts and sets
  `extends.version` in `policy.json` to the new version (only that value's
  text changes where possible), so the branch passes its own contract
  gate. Commits with a body containing old→new version, digests, the
  classified enforcement delta (weakened, strengthened and changed rules,
  plus `added`/`removed` hooks), and a `Protected-Change` trailer for each
  protected file it changes with `Approved-By: <git committer name>`: the
  person running the update declares the change, the review of the branch
  approves it. The commit runs the repository's git hooks; when one
  refuses it, the worktree and the branch are both removed so a retry
  starts clean. Opens a PR via `gh` when available and a GitHub remote
  exists, else prints the branch name and next steps. Never commits to
  the current branch. Outside a git work tree: writes nothing, prints the
  delta and instructions (patch mode).

### `propose [--rationale TEXT]`

- Computes the deviation inventory (live, R5). Empty → "nothing to
  propose", exit 0.
- Clones the baseline source at the pinned version, applies the deviating
  paths onto the baseline document (keeping its key order and
  indentation, so the diff shows only the deviating values; a removed
  hook is deleted), commits on branch
  `propose/<consumer-name>-<YYYYMMDD>` with origin repo, pinned version,
  per-deviation classification, and the rationale (`--rationale` or
  interactive prompt; refuses to proceed without one).
- Opens the upstream PR via `gh` when possible; otherwise writes
  `.specify/gates/proposals/<branch>.patch` plus instructions.

## `verify.sh` — the synthetic `contract` gate

- Evaluated immediately after policy validation, before all tool gates:
  policy integrity precedes policy enforcement.
- Dormant (no `extends`): no gate entry, no attestation object — byte-for-
  byte today's behavior.
- Otherwise proves the four invariants (artifact-layout.md) offline; any
  violation → gate `fail`, run exit 2, message naming the artifact and the
  repair command. Severity is fixed at error (a broken contract is never a
  warning); deviations print informationally and never affect exit codes.
- Policy resolution: with `extends` declared and `policy.effective.json`
  present, every `gates_policy_*` accessor reads the effective file.
  `GATES_POLICY_FILE` keeps absolute precedence. With `extends` declared
  and the effective file missing, the gate fails closed (accessors keep
  reading `policy.json` so the failure itself can be policy-configured
  output — but the run is already red).
- `--dry-run` lists the contract gate as `planned` when `extends` is
  declared.

## `doctor.sh` — contract section

- Reports: declaration (source, version, file), pin presence, snapshot
  digest match, effective recompute match, deviation inventory (counts +
  lines), all from local information only.
- Fails (exit 1) on exactly the four gate invariants.
- `[rec]` nudge when `extends` is declared but never synced, naming the
  sync command.

## Attestation extension

- `gates[]` gains a `contract` GateEntry (synthetic; tool fields null;
  `reason` names the violated invariant on fail).
- Top-level optional `contract` object (absent when dormant):
  `{ source, version, digest, effective_sha256, deviations: { weakened,
changed } }`.
- Record stays `v: 1`; the 001 attestation-record schema gains the
  optional property additively (consumers ignore unknown fields).

## Canary

- New `contract` probe: project a sandbox with a local fixture baseline
  (plain-path remote), sync it, tamper `policy.effective.json`, and
  require the sandboxed `verify.sh` to exit 2 naming the contract gate.
  Accepted probe → suite exit 1 naming the gate. Wired into `--only`.
- The probe never touches the user's project files and performs no network
  access (fixture baseline lives inside the sandbox).

## Extension commands

- `/speckit.gates.sync` → runs `contract.sh sync` (passes `--update
[version]` through when the user asks for an update).
- `/speckit.gates.propose` → runs `contract.sh propose` (prompts for the
  rationale, passes `--rationale`).
- `extension.yml` lists both (7 commands total); `speckit_version`
  requirement unchanged.
