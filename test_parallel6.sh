#!/bin/bash

# Test using expect to handle terminal interaction
test_parallel_expect() {
    local query="$*"
    local output=$(mktemp)
    
    echo "Test 6: Using expect"
    # Create expect script
    cat > /tmp/llm_expect.exp << EOF
#!/usr/bin/expect -f
set timeout 30
log_file -noappend "$output"
spawn llm -m grok-4-latest "$query"
expect eof
EOF
    chmod +x /tmp/llm_expect.exp
    
    # Run expect in background
    (/tmp/llm_expect.exp > /dev/null 2>&1) &
    local pid=$!
    wait $pid
    
    echo "Output size: $(wc -c < "$output") bytes"
    cat "$output"
    rm -f "$output" /tmp/llm_expect.exp
}

# Alternative: Use a different approach with timeout
test_parallel_timeout() {
    local query="$*"
    local gemini_output=$(mktemp)
    local grok_output=$(mktemp) 
    local o3_output=$(mktemp)
    
    echo "Running all models with timeout approach..."
    
    # Use timeout command to ensure processes don't hang
    (timeout 30 bash -c "llm -m gemini-2.5-pro -o thinking_budget -1 -o google_search 1 '$query'" > "$gemini_output" 2>&1 </dev/null) &
    local gemini_pid=$!
    
    (timeout 30 bash -c "llm -m grok-4-latest '$query'" > "$grok_output" 2>&1 </dev/null) &
    local grok_pid=$!
    
    (timeout 30 bash -c "llm -m o3 '$query'" > "$o3_output" 2>&1 </dev/null) &
    local o3_pid=$!
    
    # Wait for all
    wait $gemini_pid
    wait $grok_pid
    wait $o3_pid
    
    echo "=== GEMINI RESPONSE ==="
    cat "$gemini_output"
    
    echo ""
    echo "=== GROK RESPONSE ==="
    cat "$grok_output"
    
    echo ""
    echo "=== O3 RESPONSE ==="
    cat "$o3_output"
    
    rm -f "$gemini_output" "$grok_output" "$o3_output"
} 