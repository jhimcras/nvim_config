#!/bin/bash
SESSION_NAME="nvim_fugitive_test"

# Kill any existing session with the same name
tmux kill-session -t $SESSION_NAME 2>/dev/null

# Start a new detached tmux session running nvim
tmux new-session -d -s $SESSION_NAME "nvim -u tests/minimal_init.lua --cmd 'set rtp+=~/.local/share/nvim/site/pack/pckr/opt/vim-fugitive' --cmd 'packadd vim-fugitive' init.lua"

# Wait for nvim to start
sleep 2

# Open fugitive summary
tmux send-keys -t $SESSION_NAME ":G" Enter
sleep 2

# Capture summary pane
echo "--- Fugitive Summary Pane ---"
tmux capture-pane -pt $SESSION_NAME

# Open a diff for current file (init.lua)
tmux send-keys -t $SESSION_NAME C-w
tmux send-keys -t $SESSION_NAME l
sleep 1
tmux send-keys -t $SESSION_NAME ":GdiffSplit" Enter
sleep 2

# Capture diff pane
echo "--- Fugitive Diff Pane ---"
tmux capture-pane -pt $SESSION_NAME

# Clean up
tmux kill-session -t $SESSION_NAME
