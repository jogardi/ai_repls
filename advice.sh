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
    
    # Create a temp file for o3 output
    local o3_output=$(mktemp)
    
    # Start o3 in the background using nohup to prevent tty issues
    if [ -n "$full_context" ]; then
        nohup bash -c "echo \"$full_context\" | llm -m o3 \"$full_query\" > \"$o3_output\" 2>&1" &
    else
        nohup bash -c "llm -m o3 \"$full_query\" > \"$o3_output\" 2>&1" &
    fi
    local o3_pid=$!
    
    # Run Gemini (foreground)
    echo "=== GEMINI RESPONSE ==="
    if [ -n "$full_context" ]; then
        echo "$full_context" | gemini_reason_search "$full_query"
    else
        gemini_reason_search "$full_query"
    fi
    
    # Wait for o3 to complete and show its output
    echo ""
    echo "=== O3 RESPONSE ==="
    wait $o3_pid
    cat "$o3_output"
    
    # Clean up temp file and nohup.out
    rm -f "$o3_output"
    rm -f nohup.out
}
