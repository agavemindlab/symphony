#!/usr/bin/env sh
set -eu

symphony_compose_project="${SYMPHONY_COMPOSE_PROJECT:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g; s/^[-_]*//; s/[-_]*$//')}"

if [ -n "$symphony_compose_project" ] && [ -f compose.symphony.yaml ]; then
  docker compose -p "$symphony_compose_project" -f compose.dev.yaml -f compose.symphony.yaml down --remove-orphans 2>/dev/null || true
  docker compose -p "$symphony_compose_project" -f compose.test.yaml down --remove-orphans 2>/dev/null || true
else
  docker compose -f compose.dev.yaml down --remove-orphans 2>/dev/null || true
  docker compose -f compose.test.yaml down --remove-orphans 2>/dev/null || true
fi
