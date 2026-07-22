#!/usr/bin/env bash

# Run tests and capture output
output=$(nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    +qa 2>&1)

echo "$output"

# Count failures and errors (strip ANSI color codes first, or awk grabs the reset code instead of the number)
failures=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep "Failed :" | awk '{print $3}' | awk '{s+=$1} END {print s}')
errors=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep "Errors :" | awk '{print $3}' | awk '{s+=$1} END {print s}')

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
