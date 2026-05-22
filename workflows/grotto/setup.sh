#!/usr/bin/env sh
set -eu

if [ -n "${GROTTO_BACKEND_ENV_PATH:-}" ]; then
  ln -s "$GROTTO_BACKEND_ENV_PATH" backend/.env
fi
