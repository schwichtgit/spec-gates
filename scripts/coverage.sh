#!/bin/bash
# shellcheck shell=bash
set -uo pipefail

# Measure line coverage of the shipped runtime (#98): run the whole suite
# under kcov, then merge the per-copy results onto extension/runtime/ with
# scripts/coverage-merge.py. Linux only (kcov); CI runs it in the
# node:26-slim image (`apt-get install kcov`).
#
# Usage: scripts/coverage.sh [out-dir]     (default: coverage/, gitignored)
# Exit: the suite's exit code; 2 when kcov or python3 is missing. The
# coverage number never fails the run: this is a report.
#
# kcov is pointed at the script, not `bash tests/run.sh`: given the bash
# binary it tries to ptrace it, which containers refuse; given a bash
# script it traces through BASH_ENV/xtrace and follows child bash scripts.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/coverage}"
for t in kcov python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "coverage: $t not found" >&2; exit 2; }
done
rm -rf "$OUT/kcov"
mkdir -p "$OUT"

rc=0
(cd "$REPO" && kcov --exclude-pattern=/usr/,/node_modules/ "$OUT/kcov" tests/run.sh) >"$OUT/run.log" 2>&1 || rc=$?
tail -n 3 "$OUT/run.log"

XML="$(find "$OUT/kcov" -path '*run.sh.*' -name cobertura.xml | head -n 1)"
if [[ -z "$XML" ]]; then
    echo "coverage: kcov produced no cobertura report (see $OUT/run.log)" >&2
    exit 2
fi
python3 "$REPO/scripts/coverage-merge.py" "$XML" "$REPO" | tee "$OUT/summary.txt"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    python3 "$REPO/scripts/coverage-merge.py" "$XML" "$REPO" --markdown >>"$GITHUB_STEP_SUMMARY"
fi
exit "$rc"
