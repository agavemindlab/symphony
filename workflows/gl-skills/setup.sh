#!/usr/bin/env sh
set -eu

upstream_repo="agavemindlab/gl-skills"
repo_name="${upstream_repo##*/}"
fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
fork_repo="$fork_owner/$repo_name"
base_branch="${SYMPHONY_BASE_BRANCH:-main}"

gh repo clone "$fork_repo" .

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "https://github.com/$upstream_repo.git"
fi

git fetch upstream "$base_branch" --prune
