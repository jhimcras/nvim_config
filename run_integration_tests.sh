#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash run_integration_tests.sh [feature | feature.Class.test_method]'
    echo 'Features: startup, launcher, grep, session, markdown, windows'
    echo 'Requires: nvim >= 0.11, tmux, Python 3, rg. Failures retain /tmp artifacts.'
    echo 'Runs real init.lua with plugin installation and external LSP launches disabled.'
    exit 0
fi
for dependency in nvim tmux python3 rg; do
    command -v "$dependency" >/dev/null || { echo "Missing: $dependency" >&2; exit 1; }
done
export PYTHONDONTWRITEBYTECODE=1
cd tests/integration
if (( $# == 0 )); then
    exec python3 -m unittest discover -v -p 'test_*.py'
fi
if (( $# > 1 )); then
    echo 'Expected at most one feature or test selector.' >&2
    exit 2
fi
exec python3 -m unittest -v "test_$1"
