#!/bin/bash

# Test suite for tmux_run Python functionality
# Compare behavior of python3 -c with tmux_run

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to compare outputs
compare_outputs() {
    local test_name="$1"
    local code="$2"
    
    echo -e "\n${BLUE}Test: $test_name${NC}"
    echo "Code:"
    echo "$code" | sed 's/^/  /'
    
    
    # Run with python3 -c
    local python_output=$(python3 -c "$code" 2>&1)
    local python_exit=$?
    
    # Run with tmux_run
    local tmux_output=$(tmux_run test_tmux_py "$code" 2>&1)
    local tmux_exit=$?
    
    # Normalize outputs for comparison
    local python_normalized=$(normalize_output "$python_output")
    local tmux_normalized=$(normalize_output "$tmux_output")
    
    # Compare normalized outputs
    if [ "$python_normalized" = "$tmux_normalized" ] && [ $python_exit -eq $tmux_exit ]; then
        echo -e "${GREEN}✓ PASS${NC} - Outputs match"
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} - Outputs differ"
        echo "python3 -c output (exit code: $python_exit):"
        echo "$python_output" | sed 's/^/  /'
        echo "tmux_run output (exit code: $tmux_exit):"
        echo "$tmux_output" | sed 's/^/  /'
        echo "Normalized python3 -c output:"
        echo "$python_normalized" | sed 's/^/  /'
        echo "Normalized tmux_run output:"
        echo "$tmux_normalized" | sed 's/^/  /'
        return 1
    fi
}

# Test cases
echo "=== Testing tmux_run Python functionality ==="

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
print('After error')"

# Clean up
tmux kill-session -t test_tmux_py 2>/dev/null

echo -e "\n=== Test suite completed ==="
