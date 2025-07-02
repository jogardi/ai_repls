#!/bin/bash

# Test suite for py_run Python functionality
# Compare behavior of python3 -c with py_run

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timeout for py_run commands (in seconds)
TMUX_RUN_TIMEOUT=5

# Source the functions
source ~/tmux_run_func.sh

# Create a test tmux session
tmux kill-session -t test_tmux_py 2>/dev/null
tmux new-session -d -s test_tmux_py
tmux send-keys -t test_tmux_py 'python3' Enter
sleep 0.5

# Function to normalize whitespace - removes trailing spaces, normalizes line endings, etc
normalize_output() {
    # Remove carriage returns, trailing spaces, and normalize multiple spaces
    # Also remove any trailing newlines
    echo "$1" | tr -d '\r' | sed 's/[[:space:]]*$//' | sed '/^$/d' | cat -v
}

# Function to run a command with timeout for bash functions
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local command=("$@")
    
    # Run command in background
    (
        "${command[@]}"
    ) &
    local pid=$!
    
    # Wait for command or timeout
    local count=0
    while kill -0 $pid 2>/dev/null; do
        if [ $count -ge $((timeout_seconds * 10)) ]; then
            # Timeout reached, kill the process
            kill -TERM $pid 2>/dev/null
            wait $pid 2>/dev/null
            return 124  # Same exit code as timeout command
        fi
        sleep 0.1
        ((count++))
    done
    
    # Get exit status
    wait $pid
    return $?
}

# Function to compare outputs
compare_outputs() {
    local test_name="$1"
    local code="$2"
    local is_error_test="${3:-false}"  # Optional flag for error tests
    
    # Increment total test counter
    ((total_tests++))
    
    echo -e "\n${BLUE}Test: $test_name${NC}"
    echo "Code:"
    echo "$code" | sed 's/^/  /'
    
    
    # Run with python3 -c
    local python_output=$(python3 -c "$code" 2>&1)
    local python_exit=$?
    
    # Run with py_run (with timeout to prevent hanging)
    local tmux_output=$(run_with_timeout $TMUX_RUN_TIMEOUT py_run test_tmux_py "$code" 2>&1)
    local tmux_exit=$?
    
    # Check if timeout occurred
    if [ $tmux_exit -eq 124 ]; then
        echo -e "${RED}✗ FAIL${NC} - py_run timed out after $TMUX_RUN_TIMEOUT seconds"
        ((failed_tests++))
        return 1
    fi
    
    # Normalize outputs for comparison
    local python_normalized=$(normalize_output "$python_output")
    local tmux_normalized=$(normalize_output "$tmux_output")
    
    # For error tests, check if both contain the key error message
    if [ "$is_error_test" = "true" ]; then
        # Extract just the error type and message from both outputs
        # Trim all whitespace including newlines from beginning and end
        local python_error=$(echo "$python_output" | grep -E "(SyntaxError|NameError|TypeError|ValueError|ZeroDivisionError):" | sed 's/^[[:space:]]*//' | head -1 | tr -d '\n\r')
        local tmux_error=$(echo "$tmux_output" | grep -E "(SyntaxError|NameError|TypeError|ValueError|ZeroDivisionError):" | sed 's/^[[:space:]]*//' | head -1 | tr -d '\n\r')
        
        if [ -n "$python_error" ] && [ -n "$tmux_error" ] && [ "$python_error" = "$tmux_error" ]; then
            echo -e "${GREEN}✓ PASS${NC} - Error messages match"
            return 0
        fi
    fi
    
    # Normal comparison for non-error tests
    if [ "$python_normalized" = "$tmux_normalized" ] && [ $python_exit -eq $tmux_exit ]; then
        echo -e "${GREEN}✓ PASS${NC} - Outputs match"
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} - Outputs differ"
        echo "python3 -c output (exit code: $python_exit):"
        echo "$python_output" | sed 's/^/  /'
        echo "py_run output (exit code: $tmux_exit):"
        echo "$tmux_output" | sed 's/^/  /'
        echo "Normalized python3 -c output:"
        echo "$python_normalized" | sed 's/^/  /'
        echo "Normalized py_run output:"
        echo "$tmux_normalized" | sed 's/^/  /'
        ((failed_tests++))
        return 1
    fi
}

# Test cases
echo "=== Testing py_run Python functionality ==="

# Initialize test counters
total_tests=0
failed_tests=0

# Test 1: Simple print
compare_outputs "Simple print" \
"print('Hello, World!')"

# Test 2: Multi-line code
compare_outputs "Multi-line code" \
"print('Line 1')
print('Line 2')
print('Line 3')"

# Test 3: Variables and expressions
compare_outputs "Variables and expressions" \
"x = 10
y = 20
print(f'x + y = {x + y}')"

# Test 4: Single quotes in strings
compare_outputs "Single quotes in strings" \
$'print(\'It\\\'s a test\')\nprint("Don\'t worry")'

# Test 5: Double quotes in strings
compare_outputs "Double quotes in strings" \
$'print("She said, \\"Hello!\\"")\nprint(\'He replied, "Hi!"\')'

# Test 6: Mixed quotes
compare_outputs "Mixed quotes" \
"data = {'name': 'John', \"age\": 30}
print(data['name'])
print(data[\"age\"])"

# Test 7: Conditional statements
compare_outputs "Conditional statements" \
"x = 5
if x > 0:
    print('Positive')
else:
    print('Non-positive')"

# Test 8: Loops
compare_outputs "Loops" \
"for i in range(3):
    print(f'Count: {i}')"

# Test 9: Function definition
compare_outputs "Function definition" \
"def greet(name):
    return f'Hello, {name}!'
print(greet('Alice'))"

# Test 10: List comprehension
compare_outputs "List comprehension" \
"squares = [x**2 for x in range(5)]
print(squares)"

# Test 11: Exception handling
compare_outputs "Exception handling" \
"try:
    x = 1 / 0
except ZeroDivisionError:
    print('Division by zero!')"

# Test 12: Import statement
compare_outputs "Import statement" \
"import math
print(f'Pi = {math.pi:.4f}')"

# Test 13: Special characters
compare_outputs "Special characters" \
"print('Tab:\\tSpace: End')
print('New\\nLine')
print('Backslash: \\\\')"

# Test 14: Unicode
compare_outputs "Unicode" \
"print('Hello 世界 🌍')
print('π ≈ 3.14159')"

# Test 15: Empty lines and indentation
compare_outputs "Empty lines and indentation" \
"def example():

    print('After empty line')
    
    return True

result = example()
print(f'Result: {result}')"

# Test 16: Complex nested structures
compare_outputs "Complex nested structures" \
"data = {
    'users': [
        {'name': 'Alice', 'scores': [95, 87, 92]},
        {'name': 'Bob', 'scores': [88, 91, 85]}
    ]
}
for user in data['users']:
    avg = sum(user['scores']) / len(user['scores'])
    print(f\"{user['name']}: {avg:.1f}\")"

# Test 17: Triple quotes in code (edge case)
compare_outputs "Triple quotes in code" \
'text = """This is a
multi-line string"""
print(text)'

# Test 18: Raw strings
compare_outputs "Raw strings" \
"import re
pattern = r'\\d+'
print(f'Pattern: {pattern}')"


# Test 19: Global and local scope
compare_outputs "Global and local scope" \
"global_var = 100
def test_scope():
    local_var = 200
    print(f'Global: {global_var}')
    print(f'Local: {local_var}')
test_scope()"

# Test 20: Newline character in string (escaping issue)
compare_outputs "Newline character in string" \
"print('\\nhi')"

# Test 21: Error cases
compare_outputs "Syntax error" \
"print('Before error')
invalid syntax here
print('After error')" \
"true"

# Clean up
tmux kill-session -t test_tmux_py 2>/dev/null

echo -e "\n=== Test suite completed ==="

# Print test summary
echo -e "\n${BLUE}Test Summary:${NC}"
echo "Total tests: $total_tests"
echo "Failed tests: $failed_tests"
echo "Passed tests: $((total_tests - failed_tests))"

if [ $failed_tests -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$failed_tests tests failed${NC}"
    exit 1
fi
