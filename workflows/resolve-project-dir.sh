# Shared aggregate-project resolver. Sourced by
# workflows/<aggregate>/project-for-linear-project.sh with:
#
#   SYMPHONY_WORKFLOW_DIR        the aggregate workflow dir (set by the engine)
#   SYMPHONY_LINEAR_PROJECT_SLUG the Linear project slug of the current issue
#   SYMPHONY_PROJECT_DIR_SUFFIX  optional workflow-dir suffix (e.g. "-lite")
#
# Reads $SYMPHONY_WORKFLOW_DIR/projects.tsv (tab-separated, # comments):
#   <linear project slug>\t<workflows/ dir name>
registry="$SYMPHONY_WORKFLOW_DIR/projects.tsv"
slug="${SYMPHONY_LINEAR_PROJECT_SLUG:-}"

project_dir_name="$(awk -F '\t' -v slug="$slug" \
  '$0 !~ /^#/ && $1 == slug { print $2; exit }' "$registry")"

if [ -z "$project_dir_name" ]; then
  printf 'Unknown Linear project slug for %s: %s\n' \
    "$(basename "$SYMPHONY_WORKFLOW_DIR")" "$slug" >&2
  exit 66
fi

SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../${project_dir_name}${SYMPHONY_PROJECT_DIR_SUFFIX:-}"
SYMPHONY_PROJECT_DIR="$(cd "$SYMPHONY_PROJECT_DIR" && pwd)"

set -a
. "$SYMPHONY_PROJECT_DIR/project.env"
[ ! -f "$SYMPHONY_PROJECT_DIR/project.env.local" ] || . "$SYMPHONY_PROJECT_DIR/project.env.local"
set +a

export SYMPHONY_PROJECT_DIR
