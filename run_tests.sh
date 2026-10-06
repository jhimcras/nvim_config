#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash run_tests.sh [tests/spec/path_spec.lua | tests/spec/directory]'
    echo 'Runs file-based unit specs. For tmux features: bash run_integration_tests.sh'
    exit 0
fi
if (( $# > 1 )); then
    echo 'Expected at most one spec file or directory.' >&2
    exit 2
fi
export NVIM_TEST_TARGET=${1:-tests/spec}
test_runtime_dir=$(mktemp -d)
trap 'rm -rf -- "$test_runtime_dir"' EXIT
# Plenary is read from the installed data directory; config, state and caches
# are test-owned so the suite cannot load another checkout or write user logs.
export XDG_CONFIG_HOME="$test_runtime_dir/config"
export XDG_STATE_HOME="$test_runtime_dir/state"
export XDG_CACHE_HOME="$test_runtime_dir/cache"
export NVIM_LOG_FILE="$test_runtime_dir/nvim.log"

# Preserve Neovim/Plenary's exit status, including startup errors and timeouts.
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run_unit.lua
