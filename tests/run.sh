#!/bin/bash
# shellcheck shell=bash
set -euo pipefail

# Run every gate test suite. Exit nonzero if any suite fails. Used locally and
# by the self-enforcement CI job (.github/workflows/gates.yml).

HERE="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
for suite in test-parity test-gate test-hooks test-policy test-doctor test-canary test-attest test-spec-gate test-contract; do
    echo "======================================================================"
    echo "  $suite"
    echo "======================================================================"
    if bash "$HERE/$suite.sh"; then
        echo ">> $suite OK"
    else
        echo ">> $suite FAILED"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

if [[ "$FAILED" -gt 0 ]]; then
    echo "$FAILED suite(s) failed."
    exit 1
fi
echo "All suites passed."
exit 0
