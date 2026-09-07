#!/usr/bin/env python3
"""Fail on SQLite lifecycle diagnostics in explicitly supplied, unchanged logs."""

import argparse
import hashlib
import json
from pathlib import Path
import re


# Match concrete failure messages. A bare SQLITE_BUSY symbol, an ordinary open
# operation, or an unrelated OS "busy" message is not a database warning.
PATTERNS = {
    "integrity_api_violation": r"database\s+integrity\s+compromised\s+by\s+API\s+violation",
    "unlinked_open_vnode": r"vnode\s+unlinked\s+while\s+in\s+use",
    "database_locked_or_busy": r"\bdatabase(?:\s+(?:table|schema))?\s+is\s+(?:locked|busy)\b",
    "unfinalized_close": r"unable\s+to\s+close\s+due\s+to\s+unfinalized\s+statements",
    "sqlite_close_failure": r"\bsqlite3?_close(?:_v2)?\b[^\n]*(?:failed|error|SQLITE_BUSY|unfinalized)",
    "sqlite_error_code": r"\b(?:warning|error|failed|failure)\b[^\n]*\bSQLITE_(?:BUSY(?:_[A-Z_]+)?|LOCKED(?:_[A-Z_]+)?|MISUSE)\b",
    "sqlite_open_connection": r"\b(?:database|sqlite3?)\b[^\n]*\b(?:connection|handle)s?\s+(?:(?:is|are|was|were)\s+)?(?:still\s+open|not\s+closed|still\s+in\s+use)\b",
}
COMPILED = [(name, re.compile(pattern, re.IGNORECASE)) for name, pattern in PATTERNS.items()]


def check(paths):
    report = {"files": [], "findings": [], "input_errors": []}
    for path in paths:
        try:
            raw = path.read_bytes()
        except OSError as error:
            report["input_errors"].append({"path": str(path), "error": str(error)})
            continue
        report["files"].append({
            "path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
        })
        for line_number, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), start=1):
            matches = [name for name, pattern in COMPILED if pattern.search(line)]
            if matches:
                report["findings"].append({
                    "path": str(path), "line": line_number, "diagnostics": matches, "text": line,
                })
    report["passed"] = not report["findings"] and not report["input_errors"]
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path, help="Exact raw log paths; missing files fail the gate")
    report = check(parser.parse_args().logs)
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
