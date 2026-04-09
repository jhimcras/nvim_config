#!/usr/bin/env bash

# Run tests and capture output
output=$(nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    +qa 2>&1)

echo "$output"

# Count failures and errors by summing up the numbers at the end of the line
failures=$(echo "$output" | grep "Failed :" | awk '{print $3}' | awk '{s+=$1} END {print s}')
errors=$(echo "$output" | grep "Errors :" | awk '{print $3}' | awk '{s+=$1} END {print s}')

# Default to 0 if no match
failures=${failures:-0}
errors=${errors:-0}

echo "----------------------------------------"
if [ "$failures" -eq 0 ] && [ "$errors" -eq 0 ]; then
    echo "SUMMARY: All tests passed successfully."
    exit 0
else
    echo "SUMMARY: Tests failed ($failures failures, $errors errors)."
    exit 1
fi
