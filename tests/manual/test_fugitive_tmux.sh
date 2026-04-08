#!/bin/bash
SESSION="fugitive_test_$(date +%s)"
tmux new-session -d -s "$SESSION" "nvim -u tests/minimal_init.lua --cmd 'set rtp+=~/.local/share/nvim/site/pack/pckr/opt/vim-fugitive' --cmd 'packadd vim-fugitive' init.lua"
sleep 5
# Open Fugitive summary
tmux send-keys -t "$SESSION" ":G" Enter
sleep 2
# Switch to init.lua and diff
tmux send-keys -t "$SESSION" C-w h ":Gdiffsplit" Enter
sleep 3
# Capture the screen to inspect the status line
tmux capture-pane -pt "$SESSION" > screen_output.txt
tmux kill-session -t "$SESSION"
grep "FUGITIVE" screen_output.txt || echo "FUGITIVE not found in screen output"
cat screen_output.txt | tail -n 5
