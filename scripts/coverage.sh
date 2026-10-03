#!/bin/bash
# shellcheck shell=bash
set -uo pipefail

# Measure line coverage of the shipped runtime (#98): run the whole suite
# under bashcov, then merge the per-copy results onto extension/runtime/
# with scripts/coverage-merge.py. Linux, as root (CI runs it in the
# node:26-slim container: `apt-get install ruby`, `gem install bashcov`).
#
# Usage: scripts/coverage.sh [out-dir]     (default: coverage/, gitignored)
# Exit: 0 when a report was produced, 2 when it could not be. This is a
# report: neither the coverage number nor the suite's result under tracing
# fails it (the gates job runs the suite untraced and is the authority).
#
# Why bashcov: it turns on xtrace through an exported SHELLOPTS, so every
# bash child inherits tracing -- the hooks git runs, the scripts a test
# runs from its sandbox. kcov dropped many of those runs in CI.
#
# Why --root /: the tests run sandbox copies of the runtime from mktemp
# directories outside the repository, and bashcov reports only files under
# its root. SimpleCov then writes its report to /coverage, hence root.
#
# Why GATES_KEEP_TMP: bashcov reports a file only if it still exists when
# the run ends ("was executed but has been deleted since then"), so the
# test suites keep their sandboxes for the run.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/coverage}"
for t in bashcov python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "coverage: $t not found" >&2; exit 2; }
done
if [[ ! -w / ]]; then
    echo "coverage: bashcov --root / writes its report to /coverage; run as root (CI uses a container)" >&2
    exit 2
fi
rm -rf "$OUT" /coverage
mkdir -p "$OUT"

export GATES_KEEP_TMP=1
rc=0
(cd "$REPO" && bashcov --root / --skip-uncovered -- tests/run.sh) >"$OUT/run.log" 2>&1 || rc=$?
grep -E '^(>> test-|All suites|[0-9]+ suite)' "$OUT/run.log" | tail -n 20
echo "coverage: the suite exited $rc under tracing (the gates job's untraced run is authoritative)"

RESULTS=/coverage/.resultset.json
if [[ ! -f "$RESULTS" ]]; then
    echo "coverage: bashcov produced no $RESULTS (see $OUT/run.log)" >&2
    exit 2
fi
cp -R /coverage "$OUT/bashcov"
python3 "$REPO/scripts/coverage-merge.py" "$OUT/bashcov/.resultset.json" "$REPO" | tee "$OUT/summary.txt"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    python3 "$REPO/scripts/coverage-merge.py" "$OUT/bashcov/.resultset.json" "$REPO" --markdown >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
