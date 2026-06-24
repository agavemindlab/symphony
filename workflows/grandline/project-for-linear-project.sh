case "${SYMPHONY_LINEAR_PROJECT_SLUG:-}" in
  "bb8f9b7a6364")
    SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../grotto"
    ;;
  "02773795419d")
    SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../gl-infra"
    ;;
  "1ecc8649e9da")
    SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../gl-skills"
    ;;
  "977d7a7b6c0e")
    SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../symphony"
    ;;
  "25c113bb4717")
    SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../voxvault"
    ;;
  *)
    printf 'Unknown Linear project slug for grandline: %s\n' "${SYMPHONY_LINEAR_PROJECT_SLUG:-}" >&2
    exit 66
    ;;
esac

SYMPHONY_PROJECT_DIR="$(cd "$SYMPHONY_PROJECT_DIR" && pwd)"

set -a
. "$SYMPHONY_PROJECT_DIR/project.env"
[ ! -f "$SYMPHONY_PROJECT_DIR/project.env.local" ] || . "$SYMPHONY_PROJECT_DIR/project.env.local"
set +a

export SYMPHONY_PROJECT_DIR
