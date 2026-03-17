#!/usr/bin/env bash
nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    +qa
