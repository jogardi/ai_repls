#!/bin/bash
set -euo pipefail

source /Users/joseph/ai_repls/tmux_run_func.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

total_tests=0
failed_tests=0

pass() {
    echo -e "${GREEN}PASS${NC} - $1"
}

fail() {
    echo -e "${RED}FAIL${NC} - $1"
    failed_tests=$((failed_tests + 1))
}

test_finds_first_new_matching_fork_rollout() {
    total_tests=$((total_tests + 1))
    echo -e "${BLUE}Test:${NC} finds first new matching fork rollout"

    local tmpdir
    tmpdir="$(mktemp -d)"
    local marker
    marker="$(mktemp)"
    mkdir -p "$tmpdir/2026/03/07"

    local old_rollout="$tmpdir/2026/03/07/rollout-old.jsonl"
    local malformed_rollout="$tmpdir/2026/03/07/rollout-malformed.jsonl"
    local other_rollout="$tmpdir/2026/03/07/rollout-other.jsonl"
    local first_match="$tmpdir/2026/03/07/rollout-first-match.jsonl"
    local second_match="$tmpdir/2026/03/07/rollout-second-match.jsonl"

    printf '%s\n' '{"timestamp":"2026-03-07T09:00:00Z","type":"session_meta","payload":{"id":"old-child","forked_from_id":"parent-1","timestamp":"2026-03-07T09:00:00Z"}}' > "$old_rollout"
    printf '%s\n' '{"timestamp":"2026-03-07T09:02:00Z","type":"session_meta","payload":{"id":"other-child","forked_from_id":"parent-2","timestamp":"2026-03-07T09:02:00Z"}}' > "$other_rollout"
    printf '%s\n' '{"timestamp":"2026-03-07T09:03:00Z","type":"session_meta","payload":{"id":"child-1","forked_from_id":"parent-1","timestamp":"2026-03-07T09:03:00Z"}}' > "$first_match"
    printf '%s\n' '{"timestamp":"2026-03-07T09:04:00Z","type":"session_meta","payload":{"id":"child-2","forked_from_id":"parent-1","timestamp":"2026-03-07T09:04:00Z"}}' > "$second_match"
    printf '%s\n' '{"timestamp":' > "$malformed_rollout"

    touch -t 202603070100 "$old_rollout"
    touch -t 202603070101 "$marker"
    touch -t 202603070102 "$malformed_rollout"
    touch -t 202603070103 "$other_rollout"
    touch -t 202603070104 "$first_match"
    touch -t 202603070105 "$second_match"

    local found
    found="$(_codex_exec_fork_find_new_session_id "$tmpdir" "parent-1" "$marker")"

    if [[ "$found" == "child-1" ]]; then
        pass "returned the earliest new rollout forked from the requested parent"
    else
        fail "expected child-1, got ${found:-<empty>}"
    fi

    rm -rf "$tmpdir" "$marker"
}

test_returns_1_when_no_new_matching_rollout_exists() {
    total_tests=$((total_tests + 1))
    echo -e "${BLUE}Test:${NC} returns 1 when no new matching rollout exists"

    local tmpdir
    tmpdir="$(mktemp -d)"
    local marker
    marker="$(mktemp)"
    mkdir -p "$tmpdir/2026/03/07"

    local other_rollout="$tmpdir/2026/03/07/rollout-other.jsonl"
    printf '%s\n' '{"timestamp":"2026-03-07T09:02:00Z","type":"session_meta","payload":{"id":"other-child","forked_from_id":"parent-2","timestamp":"2026-03-07T09:02:00Z"}}' > "$other_rollout"

    touch -t 202603070101 "$marker"
    touch -t 202603070102 "$other_rollout"

    local status=0
    if _codex_exec_fork_find_new_session_id "$tmpdir" "parent-1" "$marker" >/dev/null; then
        fail "expected _codex_exec_fork_find_new_session_id to return non-zero"
    else
        status=$?
        if [[ "$status" -eq 1 ]]; then
            pass "returned 1 when no matching rollout was present"
        else
            fail "expected exit code 1, got $status"
        fi
    fi

    rm -rf "$tmpdir" "$marker"
}

test_finds_first_new_matching_fork_rollout
test_returns_1_when_no_new_matching_rollout_exists

echo
echo "Tests run: $total_tests"
echo "Failures: $failed_tests"

if [[ "$failed_tests" -ne 0 ]]; then
    exit 1
fi
