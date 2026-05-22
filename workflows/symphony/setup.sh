#!/usr/bin/env sh
set -eu

repo_name="symphony"
fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
fork_repo="$fork_owner/$repo_name"
base_branch="${SYMPHONY_BASE_BRANCH:-main}"

gh repo clone "$fork_repo" .

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/agavemindlab/symphony.git
fi

git fetch upstream "$base_branch" --prune

if command -v mise >/dev/null 2>&1; then
  cd elixir
  mise trust
  mise exec -- mix deps.get
fi
