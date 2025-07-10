# I want to combine gemini and o3. 
# With the llm command you can do `cat context.txt | llm -m o3 "what does this mean?"`
# I want the same to work with ask_advice but returning response from gemini and then o3
# use gemini_reason_search to get the gemini with reasoning and search 
# Define the alias after the function
alias gemini_reason_search="llm -m gemini-2.5-pro  -o thinking_budget -1 -o google_search 1"

ask_advice() {
    local input=""
    local query=""
    
    # Check if we have arguments
    if [ $# -gt 0 ]; then
        query="$*"
    fi
    
    # Check if we have piped input
    if [ ! -t 0 ]; then
        input=$(cat)
    fi
    
    # If we have both input and query, combine them
    if [ -n "$input" ] && [ -n "$query" ]; then
        full_context="$input"
        full_query="$query"
    elif [ -n "$input" ]; then
        # Only piped input, no query
        full_context="$input"
        full_query="What does this mean?"
    elif [ -n "$query" ]; then
        # Only query, no piped input
        full_context=""
        full_query="$query"
    else
        echo "Error: No input or query provided"
        return 1
    fi
    
    # Create temporary files for outputs
    local gemini_output=$(mktemp)
    local o3_output=$(mktemp)
    
    # Start both calls in parallel
    if [ -n "$full_context" ]; then
        # Run Gemini in background
        (echo "$full_context" | gemini_reason_search "$full_query" > "$gemini_output" 2>&1) &
        local gemini_pid=$!
        
        # Run O3 in background
        (echo "$full_context" | llm -m o3 "$full_query" > "$o3_output" 2>&1) &
        local o3_pid=$!
    else
        # Run Gemini in background
        (gemini_reason_search "$full_query" > "$gemini_output" 2>&1) &
        local gemini_pid=$!
        
        # Run O3 in background
        (llm -m o3 "$full_query" > "$o3_output" 2>&1) &
        local o3_pid=$!
    fi
    
    # Wait for Gemini to complete and display its response first
    wait $gemini_pid
    echo "=== GEMINI RESPONSE ==="
    cat "$gemini_output"
    
    # Wait for O3 to complete and display its response
    wait $o3_pid
    echo ""
    echo "=== O3 RESPONSE ==="
    cat "$o3_output"
    
    # Clean up temporary files
    rm -f "$gemini_output" "$o3_output"
}
