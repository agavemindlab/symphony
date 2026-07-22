#!/bin/sh
set -eu

die() {
  printf 'snapshot-shared-skills: %s\n' "$*" >&2
  exit 1
}

replace_link() {
  mv -fT "$1" "$2" 2>/dev/null || mv -fh "$1" "$2" 2>/dev/null || {
    rm -f "$2"
    mv "$1" "$2"
  }
}

ensure_workspace_dir() {
  [ ! -L "$1" ] || die "workspace state directory is a symlink: $1"
  if [ -e "$1" ]; then
    [ -d "$1" ] || die "workspace state path is not a directory: $1"
  else
    mkdir "$1"
  fi
  actual="$(cd "$1" && pwd -P)"
  case "$actual" in "$workspace"/*) ;; *) die "workspace state directory escapes the workspace: $1" ;; esac
}

validate_link_target() {
  [ "$(readlink "$1" | wc -l | tr -d ' ')" -eq 1 ] ||
    die "managed skill link target contains a newline: $1"
  ! readlink "$1" | grep "$(printf '\t')" >/dev/null ||
    die "managed skill link target contains a tab: $1"
}

normalize_repo_path() {
  normalized=
  saved_ifs=$IFS
  IFS=/
  for component in $1; do
    case "$component" in
      ""|.) ;;
      ..)
        [ -n "$normalized" ] || die "skill source escapes its Git repository: $1"
        case "$normalized" in */*) normalized="${normalized%/*}" ;; *) normalized= ;; esac
        ;;
      *) normalized="${normalized}${normalized:+/}$component" ;;
    esac
  done
  IFS=$saved_ifs
  printf '%s\n' "$normalized"
}

[ "$#" -gt 0 ] || die "at least one skill source is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "workspace is not a Git worktree"

workspace="$(pwd -P)"
[ ! -L "$workspace/.git" ] || die "workspace Git metadata is a symlink"
[ -d "$workspace/.git" ] || [ -f "$workspace/.git" ] || die "workspace Git metadata is missing"
workspace_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "workspace Git root is unavailable"
workspace_root="$(cd "$workspace_root" && pwd -P)"
[ "$workspace_root" = "$workspace" ] || die "snapshot must run from the workspace Git root"
exclude="$(git rev-parse --git-path info/exclude 2>/dev/null)" || die "workspace Git metadata is unavailable"
case "$exclude" in /*) ;; *) exclude="$workspace/$exclude" ;; esac
git_info="$(dirname "$exclude")"
[ ! -L "$git_info" ] && [ -d "$git_info" ] || die "workspace Git metadata is not writable"
git_info="$(cd "$git_info" && pwd -P)"
exclude="$git_info/$(basename "$exclude")"
[ ! -L "$exclude" ] || die "workspace Git exclude file is a symlink"
[ ! -e "$exclude" ] || [ -f "$exclude" ] || die "workspace Git exclude path is not a file"
state="$workspace/.symphony/shared-skills"
generations="$state/generations"
current="$state/current"
agents="$workspace/.agents/skills"
! git ls-files -- '.symphony/shared-skills' | grep -q . ||
  die "repository tracks Symphony shared skill state"
for directory in "$workspace/.symphony" "$state" "$generations" "$workspace/.agents" "$agents"; do
  ensure_workspace_dir "$directory"
done

repo=
object=
sources=
prefixes=
single_sources=
missing_prefixes=
empty_prefixes=
legacy_links=
for source_arg in "$@"; do
  [ -d "$(dirname "$source_arg")" ] || die "missing skill source parent: $source_arg"
  source_parent="$(cd "$(dirname "$source_arg")" && pwd -P)"
  source_path="$source_parent/$(basename "$source_arg")"
  source_repo="$(git -C "$source_parent" rev-parse --show-toplevel 2>/dev/null)" ||
    die "skill source is not in Git: $source_arg"
  source_repo="$(cd "$source_repo" && pwd -P)"
  source_object="$(git -C "$source_repo" rev-parse HEAD^{commit} 2>/dev/null)" ||
    die "skill source has no committed HEAD: $source_arg"

  case "$source_path" in
    "$source_repo"/*) prefix="${source_path#"$source_repo"/}" ;;
    *) die "skill source is outside its Git repository: $source_arg" ;;
  esac

  source_mode="$(git -C "$source_repo" ls-tree "$source_object" -- "$prefix" | awk 'NR == 1 { print $1 }')"
  if [ "$source_mode" = 120000 ]; then
    committed_target="$(git -C "$source_repo" cat-file -p "$source_object:$prefix")"
    case "$committed_target" in /*) die "absolute committed skill source symlink is not supported: $source_arg" ;; esac
    prefix="$(normalize_repo_path "$(dirname "$prefix")/$committed_target")"
    target_type="$(git -C "$source_repo" cat-file -t "$source_object:$prefix" 2>/dev/null || true)"
    [ -z "$target_type" ] || [ "$target_type" = tree ] ||
      die "committed skill source symlink does not target a directory: $source_arg"
    [ -n "$target_type" ] || empty_prefixes="${empty_prefixes}${empty_prefixes:+
}$prefix"
  elif [ -n "$source_mode" ] && [ "$source_mode" != 040000 ]; then
    die "committed skill source is not a directory: $source_arg"
  fi
  source="$source_repo/$prefix"

  if [ -z "$repo" ]; then
    repo="$source_repo"
    object="$source_object"
  else
    [ "$repo" = "$source_repo" ] || die "skill sources span multiple Git repositories"
    [ "$object" = "$source_object" ] || die "skill sources span multiple commits"
  fi

  sources="${sources}${sources:+
}$source"
  prefixes="${prefixes}${prefixes:+
}$prefix"
  if git -C "$repo" cat-file -e "$object:$prefix/SKILL.md" 2>/dev/null; then
    single_sources="${single_sources}${single_sources:+
}$source"
  elif ! git -C "$repo" cat-file -e "$object:$prefix" 2>/dev/null; then
    missing_prefixes="${missing_prefixes}${missing_prefixes:+
}$prefix"
  else
    while IFS="$(printf '\t')" read -r entry name; do
      [ "${entry%% *}" = 120000 ] || continue
      case "$name" in ""|.|..|.*|*[!A-Za-z0-9._-]*) die "invalid shared skill name: $name" ;; esac
      committed_target="$(git -C "$repo" cat-file -p "$object:$prefix/$name")"
      case "$committed_target" in /*) continue ;; esac
      target_prefix="$(normalize_repo_path "$prefix/$committed_target")"
      legacy_links="${legacy_links}${legacy_links:+
}$name$(printf '\t')$repo/$target_prefix"
    done <<EOF
$(git -C "$repo" ls-tree "$object:$prefix")
EOF
  fi
done

is_resolved_legacy_link() {
  printf '%s\n' "$legacy_links" | grep -Fxq -e "$1$(printf '\t')$2"
}

is_legacy_source_link() {
  is_resolved_legacy_link "$1" "$2" && return 0
  for legacy_source in $sources; do [ "$2" = "$legacy_source/$1" ] && return 0; done
  for legacy_source in $single_sources; do
    [ "$1" = "${legacy_source##*/}" ] && [ "$2" = "$legacy_source" ] && return 0
  done
  return 1
}

managed_target() {
  printf '../../.symphony/shared-skills/current/skills/%s\n' "$1"
}

old_generation=
old_target=
old_managed=
old_sources=
old_ifs=$IFS
IFS='
'
if [ -L "$current" ]; then
  old_target="$(readlink "$current")"
  case "$old_target" in
    generations/*) old_generation="$state/$old_target" ;;
    *) die "current snapshot target is invalid: $old_target" ;;
  esac
  [ ! -L "$old_generation" ] || die "current snapshot generation is a symlink"
  actual_old_generation="$(cd "$old_generation" && pwd -P 2>/dev/null)" ||
    die "current snapshot generation is missing"
  case "$actual_old_generation" in "$generations"/*) ;; *) die "current snapshot generation escapes the workspace" ;; esac
  [ -d "$old_generation/skills" ] && [ -f "$old_generation/manifest" ] ||
    die "current snapshot manifest is missing or corrupt"
  old_managed="$(sed -n 's/^managed=//p' "$old_generation/manifest")"
  old_sources="$(sed -n 's/^source=//p' "$old_generation/manifest")"
elif [ -e "$current" ]; then
  die "current snapshot is not a symlink"
fi

for name in $old_managed; do
  case "$name" in ""|.|..|.*|*[!A-Za-z0-9._-]*) die "invalid managed skill name in prior snapshot: $name" ;; esac
done
for prefix in $missing_prefixes; do
  printf '%s\n' "$empty_prefixes" | grep -Fxq -e "$prefix" && continue
  printf '%s\n' "$old_sources" | grep -Fxq -e "$prefix" || die "committed skill source is missing: $prefix"
done

for target in "$agents"/*; do
  [ -L "$target" ] || continue
  name="${target##*/}"
  actual="$(readlink "$target")"
  relative="$(managed_target "$name")"
  if [ "$actual" = "$relative" ] && ! printf '%s\n' "$old_managed" | grep -Fxq -e "$name"; then
    old_managed="${old_managed}${old_managed:+
}$name"
  fi
  if is_legacy_source_link "$name" "$actual" &&
    ! printf '%s\n' "$old_managed" | grep -Fxq -e "$name"; then
    old_managed="${old_managed}${old_managed:+
}$name"
  fi
done

for candidate in "$generations"/.tmp-*; do
  [ -d "$candidate" ] || continue
  [ "$candidate" = "$old_generation" ] || rm -rf "$candidate"
done

tmp="$(mktemp -d "$generations/.tmp-${object}-XXXXXXXX")" || die "failed to create snapshot generation"
generation="${tmp##*/.tmp-}"
final="$generations/$generation"
mkdir -p "$tmp/archive" "$tmp/skills"
cleanup() {
  rm -rf "$tmp"
  rm -f "$state/.current-$$" "$state/.current-rollback-$$" "$agents"/.snapshot-*"-$$"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for prefix in $prefixes; do
  git -C "$repo" cat-file -e "$object:$prefix" 2>/dev/null || continue
  git -C "$repo" ls-tree -r "$object" -- "$prefix" |
    awk '$1 == "160000" { found = 1 } END { exit found ? 0 : 1 }' &&
    die "Git submodules are not supported: $prefix"
  git -C "$repo" archive "$object" -- "$prefix" | tar -x -C "$tmp/archive" ||
    die "failed to archive committed skills: $prefix"

  archived="$tmp/archive/$prefix"
  [ -d "$archived" ] || die "committed skill source is not a directory: $prefix"
  if [ -f "$archived/SKILL.md" ]; then
    name="${archived##*/}"
    case "$name" in ""|.|..|.*|*[!A-Za-z0-9._-]*) die "invalid shared skill name: $name" ;; esac
    [ ! -e "$tmp/skills/$name" ] || die "duplicate shared skill name: $name"
    mv "$archived" "$tmp/skills/$name"
    continue
  fi
  for skill in "$archived"/.[!.]* "$archived"/..?*; do
    [ -e "$skill" ] || [ -L "$skill" ] || continue
    die "invalid shared skill name: ${skill##*/}"
  done
  for skill in "$archived"/*; do
    [ -e "$skill" ] || [ -L "$skill" ] || continue
    name="${skill##*/}"
    case "$name" in ""|.|..|.*|*[!A-Za-z0-9._-]*) die "invalid shared skill name: $name" ;; esac
    [ ! -e "$tmp/skills/$name" ] || die "duplicate shared skill name: $name"
    if [ -L "$skill" ]; then
      committed_target="$(readlink "$skill")"
      case "$committed_target" in /*) die "absolute committed skill symlink is not supported: $name" ;; esac
      target_prefix="$(normalize_repo_path "$prefix/$committed_target")"
      [ "$(git -C "$repo" cat-file -t "$object:$target_prefix" 2>/dev/null || true)" = tree ] ||
        die "committed skill symlink does not target a directory: $name"
      resolved="$tmp/resolved-$name"
      mkdir "$resolved"
      git -C "$repo" archive "$object" -- "$target_prefix" | tar -x -C "$resolved" ||
        die "failed to archive committed skill symlink target: $name"
      [ -f "$resolved/$target_prefix/SKILL.md" ] || die "committed skill symlink target is not a skill: $name"
      mv "$resolved/$target_prefix" "$tmp/skills/$name"
      rm -rf "$resolved"
      continue
    fi
    [ -d "$skill" ] || die "skill source contains a non-directory entry: $name"
    mv "$skill" "$tmp/skills/$name"
  done
done

if find "$tmp/skills" -type f -exec grep -Il '^version https://git-lfs.github.com/spec/v1$' {} + |
  grep -q .; then
  die "Git LFS pointers are not supported in shared skills"
fi

find "$tmp/skills" -type l -print | while IFS= read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    /*) die "absolute symlink is not supported: $link" ;;
  esac
  resolved="$(cd "$(dirname "$link")" && realpath "$target" 2>/dev/null)" ||
    die "dangling symlink is not supported: $link"
  case "$resolved" in
    "$tmp/skills"/*) ;;
    *) die "symlink escapes the snapshot: $link" ;;
  esac
done

desired=
for skill in "$tmp/skills"/*; do
  [ -d "$skill" ] || continue
  name="${skill##*/}"
  target="$agents/$name"
  relative="$(managed_target "$name")"

  if git ls-files --error-unmatch -- ".agents/skills/$name" >/dev/null 2>&1; then
    continue
  fi

  managed_before=false
  printf '%s\n' "$old_managed" | grep -Fxq -e "$name" && managed_before=true
  legacy=false
  if [ -L "$target" ]; then
    actual="$(readlink "$target")"
    [ "$actual" = "$relative" ] && managed_before=true
    is_legacy_source_link "$name" "$actual" && legacy=true
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$managed_before" != true ] && [ "$legacy" != true ]; then
      continue
    fi
    [ -L "$target" ] || die "managed skill was replaced by an unknown path: $target"
  fi

  desired="${desired}${desired:+
}$name"
done

{
  printf 'repo=%s\nobject=%s\n' "$repo" "$object"
  for prefix in $prefixes; do printf 'source=%s\n' "$prefix"; done
  for name in $desired; do printf 'managed=%s\n' "$name"; done
} > "$tmp/manifest"

links="$tmp/links"
: > "$links"
for name in $desired $old_managed; do
  cut -f1 "$links" | grep -Fxq -e "$name" && continue
  target="$agents/$name"
  if git ls-files --error-unmatch -- ".agents/skills/$name" >/dev/null 2>&1; then
    continue
  elif [ -L "$target" ]; then
    validate_link_target "$target"
    printf '%s\tlink\t%s\n' "$name" "$(readlink "$target")" >> "$links"
  elif [ -e "$target" ]; then
    die "managed skill was replaced by an unknown path: $target"
  else
    printf '%s\tmissing\n' "$name" >> "$links"
  fi
done
rollback_links="$(cat "$links")"

[ ! -e "$final" ] && [ ! -L "$final" ] || die "snapshot generation already exists: $final"
mv "$tmp" "$final"
published=false

rollback() {
  [ "${published:-false}" = true ] || return
  published=false
  if [ -n "$old_target" ]; then
    rollback_current="$state/.current-rollback-$$"
    ln -s "$old_target" "$rollback_current"
    replace_link "$rollback_current" "$current"
  else
    rm -f "$current"
  fi
  while IFS="$(printf '\t')" read -r name presence previous; do
    [ -n "$name" ] || continue
    case "$name" in .|..|.*|*[!A-Za-z0-9._-]*) die "invalid rollback skill name: $name" ;; esac
    target="$agents/$name"
    if [ "$presence" = missing ]; then
      [ ! -L "$target" ] || rm -f "$target"
    else
      [ "$presence" = link ] || die "invalid rollback journal entry: $name"
      rollback_link="$agents/.snapshot-rollback-$name-$$"
      case "$previous" in -*) previous="./$previous" ;; esac
      ln -s "$previous" "$rollback_link"
      replace_link "$rollback_link" "$target"
    fi
  done <<EOF
$rollback_links
EOF
  case "$final" in "$generations"/*) rm -rf "$final" ;; *) die "rollback generation escapes the workspace" ;; esac
}
trap 'rollback; cleanup' EXIT
trap 'exit 1' HUP INT TERM

new_target="generations/$generation"
current_tmp="$state/.current-$$"
ln -s "$new_target" "$current_tmp"
published=true
replace_link "$current_tmp" "$current"

for name in $desired; do
  target="$agents/$name"
  relative="$(managed_target "$name")"
  if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$relative" ]; then
    staged="$agents/.snapshot-$name-$$"
    ln -s "$relative" "$staged"
    replace_link "$staged" "$target"
  fi
done

for name in $old_managed; do
  printf '%s\n' "$desired" | grep -Fxq -e "$name" && continue
  target="$agents/$name"
  relative="$(managed_target "$name")"
  if git ls-files --error-unmatch -- ".agents/skills/$name" >/dev/null 2>&1; then
    continue
  elif [ -L "$target" ] && [ "$(readlink "$target")" = "$relative" ]; then
    rm "$target"
  elif [ -L "$target" ]; then
    legacy=false
    actual="$(readlink "$target")"
    is_legacy_source_link "$name" "$actual" && legacy=true
    [ "$legacy" = true ] && rm "$target" || die "removed managed skill has an unknown target: $target"
  elif [ -e "$target" ] || [ -L "$target" ]; then
    die "removed managed skill was replaced by an unknown path: $target"
  fi
done

grep -Fxq -e '.symphony/' "$exclude" 2>/dev/null || printf '%s\n' '.symphony/' >> "$exclude"
for name in $desired; do
  entry=".agents/skills/$name"
  grep -Fxq -e "$entry" "$exclude" 2>/dev/null || printf '%s\n' "$entry" >> "$exclude"
done

for candidate in "$generations"/*; do
  actual_generations="$(cd "$generations" && pwd -P)"
  [ "$actual_generations" = "$generations" ] || die "snapshot generations directory escapes the workspace"
  [ -d "$candidate" ] || continue
  [ "$candidate" = "$final" ] && continue
  [ -n "$old_generation" ] && [ "$candidate" = "$old_generation" ] && continue
  rm -rf "$candidate"
done

IFS=$old_ifs
published=false
trap - EXIT HUP INT TERM
