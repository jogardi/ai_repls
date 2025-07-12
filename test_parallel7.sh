#!/bin/bash

# Test with detailed error checking
test_parallel_debug() {
    local query="$*"
    local gemini_output=$(mktemp)
    local grok_output=$(mktemp) 
    local o3_output=$(mktemp)
    local gemini_err=$(mktemp)
    local grok_err=$(mktemp)
    local o3_err=$(mktemp)
    
    echo "Running all models with detailed debugging..."
    
    # Run each model and capture both stdout and stderr
    (llm -m gemini-2.5-pro -o thinking_budget -1 -o google_search 1 "$query" > "$gemini_output" 2>"$gemini_err" </dev/null) &
    local gemini_pid=$!
    
    (llm -m grok-4-latest "$query" > "$grok_output" 2>"$grok_err" </dev/null) &
    local grok_pid=$!
    
    (llm -m o3 "$query" > "$o3_output" 2>"$o3_err" </dev/null) &
    local o3_pid=$!
    
    # Wait and check exit codes
    wait $gemini_pid
    local gemini_exit=$?
    wait $grok_pid
    local grok_exit=$?
    wait $o3_pid
    local o3_exit=$?
    
    echo "=== GEMINI (exit code: $gemini_exit) ==="
    echo "STDOUT ($(wc -c < "$gemini_output") bytes):"
    cat "$gemini_output"
    echo "STDERR:"
    cat "$gemini_err"
    
    echo ""
    echo "=== GROK (exit code: $grok_exit) ==="
    echo "STDOUT ($(wc -c < "$grok_output") bytes):"
    cat "$grok_output"
    echo "STDERR:"
    cat "$grok_err"
    
    echo ""
    echo "=== O3 (exit code: $o3_exit) ==="
    echo "STDOUT ($(wc -c < "$o3_output") bytes):"
    cat "$o3_output"
    echo "STDERR:"
    cat "$o3_err"
    
    rm -f "$gemini_output" "$grok_output" "$o3_output" "$gemini_err" "$grok_err" "$o3_err"
} 