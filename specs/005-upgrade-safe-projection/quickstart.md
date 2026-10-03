# Quickstart: Validating Upgrade-Safe Projection

Runnable end-to-end checks, one per story. The suites in `tests/`
automate each; this is the manual walk-through and the RC checklist base.
Contracts: [project-sh.md](contracts/project-sh.md),
[hooks.md](contracts/hooks.md). File formats:
[data-model.md](data-model.md).

## Prerequisites

- `specify` 1.0.13, jq, git ≥ 2.30, bash (stock macOS 3.2 included).
- A release-shaped zip built from this branch (same `cp` steps as
  `.github/workflows/release.yml`), served with
  `python3 -m http.server 8734 --bind 127.0.0.1`.
- A fixture: `git init`, then
  `specify init --here --integration claude --script sh --non-interactive`.

## US7 (#83) — agent hooks never silently allow

Build a PATH without jq (recent macOS ships `/usr/bin/jq`, so a plain
`/usr/bin:/bin` PATH is not enough): a shim directory with symlinks to
bash, grep, sed, cat, basename, git only. Then, with `NOJQ` set to it:

```sh
p() { printf '%s' "$1" | env PATH="$NOJQ" "$2"; echo " rc=$?"; }
p '{"tool_input":{"command":"rm -rf /"}}'  .claude/hooks/gates/validate-bash.sh  # rc=2 (blocked)
p '{"tool_input":{"command":"ls"}}'        .claude/hooks/gates/validate-bash.sh  # rc=0 + doctor warning
p '{"tool_input":{"file_path":".env"}}'    .claude/hooks/gates/protect-files.sh  # rc=2 (blocked)
p '{"tool_input":{"file_path":"a.txt"}}'   .claude/hooks/gates/protect-files.sh  # ask if protected_files.extra is set, else rc=0
bash .specify/gates/canary.sh --only bash,protect                               # includes no-jq variants
```

## US1 (#72) — one-command projection

```sh
specify extension add gates --from http://127.0.0.1:8734/gates.zip
bash .specify/extensions/gates/runtime/project.sh --dry-run
bash .specify/extensions/gates/runtime/project.sh           # exit 0, canaries all blocked
bash .specify/extensions/gates/runtime/project.sh           # "no changes"
specify extension remove gates --keep-config --force
bash .specify/gates/project.sh --check                       # exit 2, names the add command
```

## US2 (#70) — upgrade safety

```sh
echo '# local' >> .specify/gates/verify.sh                   # local edit
echo .specify/gates/canary.sh >> .specify/gates/.upgrade-holds
# install a fixture "newer" version, then:
bash .specify/extensions/gates/runtime/project.sh            # exit 3, lists verify.sh
bash .specify/extensions/gates/runtime/project.sh --keep-local .specify/gates/verify.sh
bash .specify/gates/doctor.sh                                # lists both holds
```

From a 0.3.6 projection (no manifest): upgrade reports no conflicts for
untouched files.

## US3 (#71) — local rules, bulk staging, ask

```sh
mkdir -p .specify/gates/hooks.local.d/validate-bash
printf 'grep -q "touch /tmp/forbidden" && exit 1; exit 0\n' \
  > .specify/gates/hooks.local.d/validate-bash/10-demo.sh
# after an upgrade the rule still refuses; with git.block_bulk_staging:
#   git add -A / git add . / git add src/  -> refused; git add a.txt -> allowed
echo '{"tool_input":{"file_path":"tests/test_no_secret_leak.py"}}' \
  | .claude/hooks/gates/protect-files.sh                     # stdout permissionDecision "ask"
```

## US4 (#82) — constitution scope

A fixture with one `###` under Core Principles and one under Additional
Constraints: `constitution.sh check` reports one principle. Adding a
marker under the second heading makes the check fail as MALFORMED.

## US5 (#73) — install hygiene

```sh
specify extension add --dev <path-to-extension>              # in a scratch fixture
bash .specify/gates/doctor.sh                                # fails: symlinked skills; warns dev
npx prettier --check .specify/extensions/gates               # clean
```

## US6 (#74) — coexistence and dormant installs

```sh
npx husky init && bash .specify/extensions/gates/runtime/project.sh --dry-run   # shows .husky entries
bash .specify/extensions/gates/runtime/project.sh --wire-manager
GATES_PROBE=1 "$(git rev-parse --git-path hooks)/commit-msg" /dev/null   # prints gates-probe:commit-msg:
bash .specify/extensions/gates/runtime/doctor.sh --installed-only        # dormant: exit 0
```

Also repeat with lefthook, the pre-commit framework, and an unknown
`core.hooksPath` (expect exit 1 and a printed call-through).

## Release gate

`bash tests/run.sh`, `bash .specify/gates/verify.sh --boundary ci`,
`bash .specify/gates/canary.sh` green locally, on stock macOS bash 3.2,
and in the container matrix. Both local consumer projects follow the
documented upgrade path to a doctor-clean state (SC-006).
