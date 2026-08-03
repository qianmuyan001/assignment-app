#!/usr/bin/env bash

# macOS Finder launcher. Double-click this file to run start.sh.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$PROJECT_ROOT" || {
  echo "Could not open the project folder: $PROJECT_ROOT"
  read -r -p "Press Enter to close..."
  exit 1
}

"$PROJECT_ROOT/start.sh"
EXIT_CODE=$?

echo
read -r -p "App closed. Press Enter to close this window..."
exit "$EXIT_CODE"

