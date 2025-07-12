#!/bin/bash

# Test using script command to simulate terminal
test_parallel5() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 5: Using script command to simulate terminal"
    # Use script to run llm in a pseudo-terminal
    (script -q -c "llm -m grok-4-latest '$query'" "$output" > /dev/null 2>&1) &
    local pid=$!
    wait $pid
    echo "Output size: $(wc -c < "$output") bytes"
    # Clean up script output (remove control characters)
    cat "$output" | sed 's/\r//g' | sed 's/\x1b\[[0-9;]*m//g'
    rm -f "$output"
}

# Test all three models with script
test_all_parallel() {
    local query="$*"
    local gemini_output=$(mktemp)
    local grok_output=$(mktemp)
    local o3_output=$(mktemp)
    
    echo "Running all three models in parallel with script..."
    
    # Start all three with script
    (script -q -c "llm -m gemini-2.5-pro -o thinking_budget -1 -o google_search 1 '$query'" "$gemini_output" > /dev/null 2>&1) &
    local gemini_pid=$!
    
    (script -q -c "llm -m grok-4-latest '$query'" "$grok_output" > /dev/null 2>&1) &
    local grok_pid=$!
    
    (script -q -c "llm -m o3 '$query'" "$o3_output" > /dev/null 2>&1) &
    local o3_pid=$!
    
    # Wait and display results
    wait $gemini_pid
    echo "=== GEMINI RESPONSE ==="
    cat "$gemini_output" | sed 's/\r//g' | sed 's/\x1b\[[0-9;]*m//g'
    
    wait $grok_pid
    echo ""
    echo "=== GROK RESPONSE ==="
    cat "$grok_output" | sed 's/\r//g' | sed 's/\x1b\[[0-9;]*m//g'
    
    wait $o3_pid
    echo ""
    echo "=== O3 RESPONSE ==="
    cat "$o3_output" | sed 's/\r//g' | sed 's/\x1b\[[0-9;]*m//g'
    
    rm -f "$gemini_output" "$grok_output" "$o3_output"
} 