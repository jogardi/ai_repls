#!/bin/bash

# Test parallel execution with different approaches

# Approach 1: Force non-interactive mode
test_parallel1() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 1: Using < /dev/null to force non-interactive"
    (llm -m grok-4-latest "$query" < /dev/null > "$output" 2>&1) &
    local pid=$!
    wait $pid
    echo "Output size: $(wc -c < "$output") bytes"
    cat "$output"
    rm -f "$output"
}

# Approach 2: Use nohup
test_parallel2() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 2: Using nohup"
    nohup llm -m grok-4-latest "$query" > "$output" 2>&1 &
    local pid=$!
    wait $pid
    echo "Output size: $(wc -c < "$output") bytes"
    cat "$output"
    rm -f "$output"
}

# Approach 3: Use setsid to detach from terminal
test_parallel3() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 3: Using setsid"
    setsid llm -m grok-4-latest "$query" > "$output" 2>&1 &
    local pid=$!
    wait $pid
    echo "Output size: $(wc -c < "$output") bytes"
    cat "$output"
    rm -f "$output"
}

# Approach 4: Export TERM=dumb
test_parallel4() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 4: Using TERM=dumb"
    (TERM=dumb llm -m grok-4-latest "$query" > "$output" 2>&1) &
    local pid=$!
    wait $pid
    echo "Output size: $(wc -c < "$output") bytes"
    cat "$output"
    rm -f "$output"
} 