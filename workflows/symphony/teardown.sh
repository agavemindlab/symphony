#!/usr/bin/env sh
set -eu

if command -v mise >/dev/null 2>&1 && [ -d elixir ]; then
  cd elixir
  mise exec -- mix workspace.before_remove
fi
