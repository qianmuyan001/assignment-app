from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.error
import urllib.request


def process_is_running(process_id: int | None) -> bool:
    """Check a child process on POSIX without sending a terminating signal."""
    if process_id is None or os.name == "nt":
        return True

    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_backend(url: str, timeout_seconds: float, process_id: int | None) -> int:
    deadline = time.monotonic() + timeout_seconds
    last_error = "No response received."

    while time.monotonic() < deadline:
        if not process_is_running(process_id):
            print("The backend process stopped before it became ready.")
            return 1

        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status < 500:
                    print(f"Backend is ready at {url}.")
                    return 0
                last_error = f"HTTP {response.status}"
        except (OSError, urllib.error.URLError) as error:
            last_error = str(error)

        time.sleep(0.5)

    print(
        f"The backend did not become ready within {timeout_seconds:g} seconds.\n"
        f"Last connection result: {last_error}"
    )
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wait for the local assignment API.")
    parser.add_argument("url", help="Backend URL to check.")
    parser.add_argument(
        "--timeout",
        type=float,
        default=90,
        help="Maximum number of seconds to wait.",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="Optional POSIX child process ID to monitor.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return wait_for_backend(args.url, args.timeout, args.pid)


if __name__ == "__main__":
    sys.exit(main())

