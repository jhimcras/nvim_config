#!/bin/bash
# Test Process List UI using tmux

SESSION="nvim_process_list_test"
SCREEN_OUTPUT="/tmp/nvim_process_list_screen.txt"

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    rm -f "$SCREEN_OUTPUT"
}
trap cleanup EXIT

cleanup

# Start Neovim in a new tmux session
tmux new-session -d -s "$SESSION" "nvim -u tests/minimal_init.lua"
echo "Waiting for Neovim to start..."
sleep 2

# Helper to verify screen content
verify_output() {
    local pattern="$1"
    local description="$2"
    tmux capture-pane -pt "$SESSION" > "$SCREEN_OUTPUT"
    # Remove pipes and spaces, and collapse newlines for searching
    local clean_output=$(tr -d '|│ \n' < "$SCREEN_OUTPUT")
    local clean_pattern=$(echo "$pattern" | tr -d '|│ ')
    
    if echo "$clean_output" | grep -q "$clean_pattern"; then
        echo "[PASS] $description"
    else
        echo "[FAIL] $description (Pattern '$pattern' not found)"
        # Show a bit of the cleaned output for debugging
        echo "Cleaned output snippet: ${clean_output:0:200}..."
    fi
}

# 1. Start a launcher process (sleeper)
echo "Starting launcher process..."
tmux send-keys -t "$SESSION" ":lua require'launcher'.Launch('sleep', {'100'}, '.', nil, nil, {orientation='vertical'}, 'use', nil, nil, 'sleeper')" Enter
sleep 1

# 2. Start a grep process
echo "Starting grep process..."
tmux send-keys -t "$SESSION" ":Grep sleeper" Enter
sleep 1

# 2.5 Start a terminal process
echo "Starting terminal process..."
tmux send-keys -t "$SESSION" ":terminal bash" Enter
sleep 1
# Switch back to the previous window to keep the test flow
tmux send-keys -t "$SESSION" C-w p
sleep 1

# 3. Open Process List
echo "Opening Process List..."
tmux send-keys -t "$SESSION" ":ProcessList" Enter
sleep 1

# 4. Verify processes are listed
verify_output "TYPE" "Header check"
verify_output "general|sleeper" "Launcher listed"
verify_output "grep|Search:sleeper" "Grep listed"
verify_output "terminal|term" "Terminal listed"

# 5. Test Refresh (Wait for grep to finish if possible, or just check it's still there)
echo "Testing refresh (waiting 2 seconds)..."
sleep 2
tmux capture-pane -pt "$SESSION" > "$SCREEN_OUTPUT"
# grep might be done by now
if grep -q "grep" "$SCREEN_OUTPUT"; then
    echo "[INFO] Grep still in list or showing status"
fi

# 6. Test Termination from UI
echo "Testing termination from UI..."
# Move cursor to the second process (sleeper is likely first after header)
tmux send-keys -t "$SESSION" "gg" j j
tmux send-keys -t "$SESSION" C-c
sleep 1
verify_output "Terminating" "Termination notification shown"

# 7. Close with gq
echo "Closing with gq..."
tmux send-keys -t "$SESSION" "gq"
sleep 1
tmux capture-pane -pt "$SESSION" > "$SCREEN_OUTPUT"
if ! grep -q "TYPE" "$SCREEN_OUTPUT"; then
    echo "[PASS] Process List closed with gq"
else
    echo "[FAIL] Process List still visible"
fi

echo "Testing completed."
