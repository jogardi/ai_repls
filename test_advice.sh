#!/bin/bash

# Test file for advice.sh
# This script tests the ask_advice function with various input scenarios

# Source the advice.sh file to load the ask_advice function
source "$(dirname "$0")/advice.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
test_count=0
pass_count=0

# Helper function to print test results
print_test_result() {
    local test_name="$1"
    local result="$2"
    
    test_count=$((test_count + 1))
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ Test $test_count: $test_name - PASS${NC}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}✗ Test $test_count: $test_name - FAIL${NC}"
        echo -e "${RED}  $result${NC}"
    fi
}

# Helper function to run a test with timeout
run_test_with_timeout() {
    local timeout_duration="$1"
    local test_command="$2"
    local test_name="$3"
    
    echo -e "${YELLOW}Running: $test_name${NC}"
    
    # Run the command with timeout and capture output
    local output
    if output=$(timeout "$timeout_duration" bash -c "source $(dirname $0)/advice.sh && $test_command" 2>&1); then
        # Check if output contains expected patterns
        if echo "$output" | grep -q "GEMINI RESPONSE" && echo "$output" | grep -q "O3 RESPONSE"; then
            print_test_result "$test_name" "PASS"
        else
            print_test_result "$test_name" "FAIL - Missing expected output sections"
        fi
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            print_test_result "$test_name" "FAIL - Timeout after $timeout_duration seconds"
        else
            print_test_result "$test_name" "FAIL - Exit code: $exit_code"
        fi
    fi
}

# Helper function for quick tests that don't need full execution
test_function_behavior() {
    local test_name="$1"
    local test_command="$2"
    local expected_pattern="$3"
    
    echo -e "${YELLOW}Testing: $test_name${NC}"
    
    local output
    if output=$(timeout 5 bash -c "$test_command" 2>&1); then
        if echo "$output" | grep -q "$expected_pattern"; then
            print_test_result "$test_name" "PASS"
        else
            print_test_result "$test_name" "FAIL - Expected pattern '$expected_pattern' not found"
        fi
    else
        print_test_result "$test_name" "FAIL - Command failed or timed out"
    fi
}

echo "=== Testing advice.sh ==="
echo

# Test 1: Function exists and is callable
echo -e "${YELLOW}Test 1: Function definition check${NC}"
if declare -f ask_advice > /dev/null; then
    print_test_result "ask_advice function exists" "PASS"
else
    print_test_result "ask_advice function exists" "FAIL - Function not found"
fi

# Test 2: Check if gemini_reason_search alias exists
echo -e "${YELLOW}Test 2: gemini_reason_search alias check${NC}"
if alias gemini_reason_search > /dev/null 2>&1; then
    print_test_result "gemini_reason_search alias exists" "PASS"
else
    print_test_result "gemini_reason_search alias exists" "FAIL - Alias not found"
fi

# Test 3: Empty input (should fail gracefully)
echo -e "${YELLOW}Test 3: Empty input handling${NC}"
if ask_advice 2>&1 | grep -q "Error: No input or query provided"; then
    print_test_result "Empty input handling" "PASS"
else
    print_test_result "Empty input handling" "FAIL - Should show error message"
fi

# Test 4: Check temp file creation capability
echo -e "${YELLOW}Test 4: Temp file creation check${NC}"
if temp_file=$(mktemp) && [ -f "$temp_file" ]; then
    rm -f "$temp_file"
    print_test_result "Temp file creation and cleanup" "PASS"
else
    print_test_result "Temp file creation and cleanup" "FAIL - mktemp not working"
fi

# Test 5: Check if llm command is available
echo -e "${YELLOW}Test 5: llm command availability${NC}"
if command -v llm > /dev/null 2>&1; then
    print_test_result "llm command available" "PASS"
else
    print_test_result "llm command available" "FAIL - llm command not found"
fi

# Test 6: Quick functional test with simple query
echo -e "${YELLOW}Test 6: Simple query test${NC}"
run_test_with_timeout 60 'ask_advice "What is 2+2?"' "Simple query test"

# Test 7: Piped input test
echo -e "${YELLOW}Test 7: Piped input test${NC}"
run_test_with_timeout 60 'echo "print(\"hello\")" | ask_advice "What does this do?"' "Piped input test"

# Test 8: Test with file input
echo -e "${YELLOW}Test 8: File input test${NC}"
echo "def test(): return 42" > /tmp/test_code.py
run_test_with_timeout 60 'cat /tmp/test_code.py | ask_advice "Explain this code"' "File input test"
rm -f /tmp/test_code.py

# Test 9: Test process handling (check if background process works)
echo -e "${YELLOW}Test 9: Process handling test${NC}"
# This test checks if the function can handle background processes properly
# We'll run a quick test and check if both outputs appear
test_output=$(timeout 60 bash -c "source $(dirname $0)/advice.sh && ask_advice 'What is 1+1?' 2>&1" || echo "TIMEOUT")
if echo "$test_output" | grep -q "GEMINI RESPONSE" && echo "$test_output" | grep -q "O3 RESPONSE"; then
    print_test_result "Process handling" "PASS"
elif echo "$test_output" | grep -q "TIMEOUT"; then
    print_test_result "Process handling" "FAIL - Test timed out"
else
    print_test_result "Process handling" "FAIL - Missing expected output sections"
fi

# Test 10: Test with special characters
echo -e "${YELLOW}Test 10: Special characters test${NC}"
test_output=$(timeout 30 bash -c "source $(dirname $0)/advice.sh && ask_advice 'What is \$HOME?' 2>&1" || echo "TIMEOUT")
if echo "$test_output" | grep -q "GEMINI RESPONSE"; then
    print_test_result "Special characters handling" "PASS"
elif echo "$test_output" | grep -q "TIMEOUT"; then
    print_test_result "Special characters handling" "FAIL - Test timed out"
else
    print_test_result "Special characters handling" "FAIL - Missing GEMINI RESPONSE"
fi

echo
echo "=== Test Summary ==="
echo -e "Total tests: $test_count"
echo -e "${GREEN}Passed: $pass_count${NC}"
echo -e "${RED}Failed: $((test_count - pass_count))${NC}"

if [ $pass_count -eq $test_count ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi 