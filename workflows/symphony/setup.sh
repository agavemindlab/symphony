#!/usr/bin/env sh
set -eu

if command -v mise >/dev/null 2>&1; then
  cd elixir
  mise trust
  mise exec -- mix deps.get
fi
