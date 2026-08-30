#!/usr/bin/env bash
# Run the vibe.nvim test suite with plenary.nvim in a headless Neovim.
#
# Usage:
#   scripts/test.sh                  # run all specs in tests/spec
#   scripts/test.sh tests/spec/foo   # run a single spec path
#
# Requires `nvim` on PATH. plenary.nvim is cloned under tests/.deps on first run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/tests/.deps"
PLENARY="$DEPS/plenary.nvim"

if ! command -v nvim >/dev/null 2>&1; then
  echo "error: nvim not found on PATH" >&2
  exit 1
fi

if [ ! -d "$PLENARY" ]; then
  echo ">> cloning plenary.nvim into $DEPS"
  mkdir -p "$DEPS"
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$PLENARY" >/dev/null
fi

target="${1:-tests/spec}"
echo ">> running specs: $target"
exec nvim --headless -u "$ROOT/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $target { minimal_init = 'tests/minimal_init.lua' }"
