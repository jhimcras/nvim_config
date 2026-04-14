#!/bin/bash

# Configuration
SESSION="launcher_test_$(date +%s)"
TEST_DIR="/tmp/launcher_test_project"
SCREEN_OUTPUT="screen_output.txt"

# Cleanup from previous runs
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Create dummy project
cat > .prjroot <<EOF
return {
    launchers = {
        gen = {
            cmd = "echo",
            args = {"hello general"},
            mode = "general"
        },
        term = {
            cmd = "echo",
            args = {"hello terminal"},
            mode = "terminal"
        },
        ext = {
            cmd = "sleep",
            args = {"30"},
            mode = "external"
        }
    }
}
EOF

# Start tmux session
WORKSPACE=$(pwd -P)

tmux new-session -d -s "$SESSION" "nvim -u tests/minimal_init.lua $TEST_DIR/.prjroot"

echo "Waiting for Neovim to start..."
sleep 5

# Function to verify output
verify_output() {
    local pattern="$1"
    local description="$2"
    tmux capture-pane -pt "$SESSION" > "$SCREEN_OUTPUT"
    # Remove pane separators | and [s | ignal things by removing the |
    # Also remove all spaces and newlines to handle wrapping
    if tr -d '│ \n' < "$SCREEN_OUTPUT" | grep -q "$pattern"; then
        echo "[PASS] $description"
    else
        echo "[FAIL] $description (Pattern '$pattern' not found)"
        echo "Full output (processed):"
        tr -d '│ \n' < "$SCREEN_OUTPUT"
    fi
}

# Test General Mode
echo "Testing General Mode..."
tmux send-keys -t "$SESSION" ":lua require'launcher'.LaunchObject('gen')" Enter
sleep 2
verify_output "hellogeneral" "General mode output captured"

# Test Terminal Mode
echo "Testing Terminal Mode..."
tmux send-keys -t "$SESSION" C-w l
tmux send-keys -t "$SESSION" ":lua require'launcher'.LaunchObject('term')" Enter
sleep 2
verify_output "helloterminal" "Terminal mode output captured"

# Test External Mode
echo "Testing External Mode..."
tmux send-keys -t "$SESSION" C-w l
tmux send-keys -t "$SESSION" ":lua require'launcher'.LaunchObject('ext')" Enter
sleep 1
# Verify PID tracking via Lua and extract PID for 'ps' check
tmux send-keys -t "$SESSION" ":lua for _, p in ipairs(require'launcher'.GetRunningProcesses()) do if p.obj == 'ext' then print('EXT_PID:' .. p.pid) end end" Enter
sleep 1
tmux capture-pane -pt "$SESSION" > "$SCREEN_OUTPUT"
EXT_PID=$(grep -oP 'EXT_PID:\K[0-9]+' "$SCREEN_OUTPUT")

if [ -n "$EXT_PID" ] && ps -p "$EXT_PID" > /dev/null; then
    echo "[PASS] External process tracked and verified via ps (PID: $EXT_PID)"
else
    echo "[FAIL] External process not found in system process list (PID: $EXT_PID)"
    ps aux | grep sleep | grep -v grep
fi

# Test Termination
echo "Testing Termination..."
tmux send-keys -t "$SESSION" ":lua require'launcher'.Launch( 'sleep', {'100'}, '.', nil, nil, {orientation='vertical'}, 'use', nil, nil, 'sleeper')" Enter
sleep 1
tmux send-keys -t "$SESSION" C-c
sleep 1
verify_output "15]" "Process terminated via <C-c>"

# Cleanup
tmux kill-session -t "$SESSION"
rm -rf "$TEST_DIR"
[ -f "$SCREEN_OUTPUT" ] && rm "$SCREEN_OUTPUT"

echo "Testing completed."
