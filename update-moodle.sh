#!/usr/bin/env bash
set -euo pipefail

# --- Parse Command Line Arguments ---
SOURCE=""
DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument '$1'"
      echo "Usage: $0 --source /path/to/moodle.tgz --dest /path/to/local/git"
      exit 1
      ;;
  esac
done

# --- Validation Checks ---
for cmd in tar rsync; do
  if ! command -v "$cmd" &> /dev/null; then
     echo "Error: Required command '$cmd' is not installed or not in PATH." >&2
     exit 1
  fi
done

if [[ -z "$SOURCE" || -z "$DEST" ]]; then
  echo "Error: Both --source and --dest parameters are required."
  echo "Usage: $0 --source /path/to/moodle.tgz --dest /path/to/local/git"
  exit 1
fi

if [[ ! -f "$SOURCE" ]]; then
  echo "Error: Source archive '$SOURCE' does not exist."
  exit 1
fi

if [[ ! -d "$DEST" ]]; then
  echo "Error: Destination directory '$DEST' does not exist."
  exit 1
fi

if [[ ! -d "$DEST/.git" ]]; then
  echo "Error: Destination '$DEST' is not a valid Git repository."
  exit 1
fi

# Ensure git working directory in destination is clean before starting
if [[ -n "$(git -C "$DEST" status --porcelain)" ]]; then
  echo "Warning: Git repository at '$DEST' has uncommitted changes."
  read -p "Do you want to proceed anyway? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting update."
    exit 1
  fi
fi

# --- Exclusion List ---
# Add any extra custom plugins, themes, or local files here
EXCLUDES=(
  ".git/"
  ".github/"
  ".gitignore"
  ".ebextensions"
  ".platform"
  "config.php"
  "mod/customcert"
  # "theme/my_custom_theme/"   # Example: Uncomment if you have untracked custom plugins in core folders
  # "mod/my_custom_plugin/"
)

# Build rsync exclude arguments array
RSYNC_EXCLUDE_ARGS=()
for item in "${EXCLUDES[@]}"; do
  RSYNC_EXCLUDE_ARGS+=("--exclude=$item")
done

# --- Temporary Extraction & Sync ---
TEMP_DIR=$(mktemp -d -t moodle-update-XXXXXX)

# Guarantee cleanup of temp directory on exit or failure
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Extracting Moodle release archive..."
# Strip the top-level 'moodle/' directory from official Moodle tarballs
tar -xzf "$SOURCE" -C "$TEMP_DIR" --strip-components=1

echo "Syncing new Moodle version to repository..."
rsync -av --delete "${RSYNC_EXCLUDE_ARGS[@]}" "$TEMP_DIR/" "$DEST/"

echo ""
echo "======================================================="
echo " Moodle update sync complete!"
echo "======================================================="
echo "Review changes using Git:"
echo "  cd $DEST"
echo "  git status"
echo "  git diff"
