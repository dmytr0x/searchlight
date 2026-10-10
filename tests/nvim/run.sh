#!/bin/sh
set -eu
test_repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_state=$(mktemp -d "${TMPDIR:-/tmp}/searchlight-tests.XXXXXX")
trap 'rm -rf -- "$test_state"' EXIT HUP INT TERM
test_file=tests/nvim/run.lua
if [ "${1:-}" = "--benchmark" ]; then
  test_file=tests/nvim/benchmark.lua
fi
cd "$test_repo"
NVIM_LOG_FILE="$test_state/nvim.log" \
XDG_CONFIG_HOME="$test_state/config" \
XDG_DATA_HOME="$test_state/data" \
XDG_STATE_HOME="$test_state/state" \
XDG_CACHE_HOME="$test_state/cache" \
  nvim --headless -u tests/nvim/minimal_init.lua -l "$test_file"
