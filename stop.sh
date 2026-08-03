#!/usr/bin/env bash

# Stop a backend started by start.sh.

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$PROJECT_ROOT/.assignment_app_backend.pid"

if [ -f "$PID_FILE" ]; then
  BACKEND_PID="$(cat "$PID_FILE" 2>/dev/null || true)"

  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    echo "Stopping backend process $BACKEND_PID..."
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    sleep 1

    if kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
      echo "Backend did not stop cleanly; forcing it to stop..."
      kill -9 "$BACKEND_PID" >/dev/null 2>&1 || true
    fi

    rm -f "$PID_FILE"
    echo "Backend stopped."
    exit 0
  fi

  rm -f "$PID_FILE"
  echo "No running backend was found for the saved PID."
  exit 0
fi

echo "No backend PID file was found. The app may already be stopped."
exit 0

