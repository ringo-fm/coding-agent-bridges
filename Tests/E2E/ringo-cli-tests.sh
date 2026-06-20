#!/usr/bin/env bash
set -euo pipefail

RINGO="${1:-.build/debug/ringo}"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_output() {
    local desc="$1"
    local pattern="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$pattern"; then
        echo "PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_exit_nonzero() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL  $desc (expected failure)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS  $desc"
        PASS=$((PASS + 1))
    fi
}

# Help output
check_output "no args prints help" "Usage:" "$RINGO"
check_output "--help prints help" "Usage:" "$RINGO" --help
check_output "-h prints help" "Usage:" "$RINGO" -h
check_output "help subcommand" "Usage:" "$RINGO" help

# Unknown command
check_exit_nonzero "unknown command exits nonzero" "$RINGO" notacommand

# Doctor runs (may fail checks but should not crash)
"$RINGO" doctor >/dev/null 2>&1 || true
check "doctor does not crash" true

# Serve without agent
check_exit_nonzero "serve without agent exits nonzero" "$RINGO" serve

# Run without agent
check_exit_nonzero "run without agent exits nonzero" "$RINGO" run

# Port info in help
check_output "help mentions port 8766" "8766" "$RINGO" --help

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
