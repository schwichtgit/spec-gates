#!/bin/sh
# spec-gates hook stub -- installed into .git/hooks as pre-commit and
# commit-msg by /speckit.gates.init (issue #59).
#
# .git/hooks is shared by every branch; the projected runtime is not. This
# stub runs the CHECKED-OUT branch's projected hook
# (.specify/gates/hooks/<name>), so the hook version always matches the
# branch's runtime and an upgrade takes effect without reinstalling hooks.
# Invoked through bash, so a projected hook that lost its execute bit (zip
# installs drop modes) still runs.

name="$(basename "$0")"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "gates: $name: cannot resolve the work tree -- hook not run" >&2
    exit 1
}
hook="$root/.specify/gates/hooks/$name"
if [ ! -f "$hook" ]; then
    # A branch from before gates was adopted has nothing to enforce.
    echo "gates: $name skipped -- this branch has no projected gates hook ($hook)" >&2
    exit 0
fi
exec bash "$hook" "$@"
