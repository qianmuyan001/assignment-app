#!/usr/bin/env python3
"""Read-only file fingerprints. Never connect SQLite to a user's database."""
import argparse
import hashlib
import json
from pathlib import Path
import stat


def fingerprint(path):
    try:
        before = path.lstat()
    except FileNotFoundError:
        return {"exists": False}
    result = {"exists": True, "size": before.st_size, "mtime_ns": before.st_mtime_ns}
    if stat.S_ISLNK(before.st_mode):
        raise RuntimeError(f"Refusing an incomplete fingerprint of protected symlink: {path}")
    elif stat.S_ISDIR(before.st_mode):
        result.update(kind="directory", entries={
            child.name: fingerprint(child) for child in sorted(path.iterdir())
        })
    elif stat.S_ISREG(before.st_mode):
        with path.open("rb") as source:
            digest = hashlib.sha256()
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
            result.update(kind="file", sha256=digest.hexdigest())
    else:
        raise RuntimeError(f"Unexpected protected file type: {path}")
    after = path.lstat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise RuntimeError(f"Protected data changed during fingerprint: {path}")
    return result


def snapshot():
    home = Path.home()
    roots = [
        home / "Library/Containers/com.qianmuyan.assignmentapp/Data/Library/Application Support/AssignmentApp2",
        home / "Library/Application Support/AssignmentApp2",
    ]
    names = ["assignments.db", "assignments.db-wal", "assignments.db-shm",
             "attachments", ".attachment-staging", ".attachment-presentations"]
    paths = [root / name for root in roots for name in names]
    # Include backup/recovery directories, future files and persistent preferences.
    paths += roots
    paths += [home / "Library/Containers/com.qianmuyan.assignmentapp/Data/Library/Preferences/com.qianmuyan.assignmentapp.plist",
              home / "Library/Preferences/com.qianmuyan.assignmentapp.plist"]
    return {str(path): fingerprint(path) for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    result = snapshot()
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if args.compare:
        expected = json.loads(args.compare.read_text())
        changed = [path for path in expected.keys() | result.keys() if expected.get(path) != result.get(path)]
        if changed:
            raise SystemExit("FAIL: protected paths changed: " + ", ".join(changed))
        print("protected_data_unchanged=true (existence, size, mtime_ns, SHA-256, attachment tree)")
    else:
        print(f"protected_data_snapshot={args.output}")


if __name__ == "__main__":
    main()
