#!/usr/bin/env bash

# Start the Assignment Schedule App on macOS or Linux.
# This script creates the virtual environment if needed, starts the backend,
# launches the desktop GUI, and stops the backend when the GUI closes.

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$PROJECT_ROOT/.venv"
PID_FILE="$PROJECT_ROOT/.assignment_app_backend.pid"
BACKEND_URL="http://127.0.0.1:8000"
BACKEND_PID=""

cd "$PROJECT_ROOT" || {
  echo "Could not open the project folder: $PROJECT_ROOT"
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 was not found. Please install Python 3 first."
  exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
  echo "Creating virtual environment..."
  python3 -m venv "$VENV_DIR" || {
    echo "Could not create the virtual environment."
    exit 1
  }
fi

# Activate the app's Python environment.
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate" || {
  echo "Could not activate the virtual environment."
  exit 1
}

echo "Installing dependencies..."
python -m pip install -r "$PROJECT_ROOT/requirements.txt" || {
  echo "Could not install dependencies from requirements.txt."
  exit 1
}

cleanup() {
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    echo "Stopping backend..."
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    wait "$BACKEND_PID" >/dev/null 2>&1 || true
  fi

  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$BACKEND_PID" ]; then
    rm -f "$PID_FILE"
  fi
}

handle_shutdown() {
  cleanup
  exit 130
}

trap cleanup EXIT
trap handle_shutdown INT TERM

echo "Starting backend..."
python -m uvicorn backend.app.main:app --host 127.0.0.1 --port 8000 &
BACKEND_PID=$!
echo "$BACKEND_PID" > "$PID_FILE"

echo "Waiting for backend to be ready..."
if ! python "$PROJECT_ROOT/scripts/wait_for_backend.py" \
  "$BACKEND_URL" \
  --timeout 90 \
  --pid "$BACKEND_PID"
then
  echo "The backend did not become ready at $BACKEND_URL."
  echo "Check the backend error above, then try again."
  exit 1
fi

echo "Starting desktop GUI..."
python desktop_gui/main_window.py
GUI_EXIT_CODE=$?

if [ "$GUI_EXIT_CODE" -ne 0 ]; then
  echo "The desktop GUI closed with an error code: $GUI_EXIT_CODE"
fi

exit "$GUI_EXIT_CODE"
