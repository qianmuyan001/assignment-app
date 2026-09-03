#!/usr/bin/env python3
"""Check the Apple localization catalogs against the sources that use them.

Three things are verified:

1. Both catalogs (`en.lproj`, `zh-Hans.lproj`) hold exactly the same keys.
2. Every key the sources use is present in both catalogs.
3. Non-English catalogs do not silently fall back to the English key.

The second check is the one that earns its keep. Keys reach the catalogs by
two different routes:

* `L10n.tr("Key")` — resolved explicitly, through the `.lproj` bundle that
  matches the language chosen inside the app.
* `Text("Key")`, `Button("Key")`, `.navigationTitle("Key")`, … — a SwiftUI
  string *literal*, resolved by SwiftUI itself.

A literal that is missing from the catalog does not fail: it quietly renders
in English. That is invisible in a code review and easy to miss by eye, so it
is found here instead.

A warning is printed (not a failure) for values that equal their key outside
English: brand names and technical terms are legitimately identical, but the
list is worth re-reading when it grows.

Usage:
    python3 scripts/check_apple_localization.py
    python3 scripts/check_apple_localization.py <sources-dir> <catalog...>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCES = REPOSITORY_ROOT / "native/apple/AssignmentApp2"
DEFAULT_CATALOGS = [
    DEFAULT_SOURCES / "Resources/en.lproj/Localizable.strings",
    DEFAULT_SOURCES / "Resources/zh-Hans.lproj/Localizable.strings",
]

# `L10n.tr("…")` — the key is the first argument and is always a literal here.
L10N_CALL = re.compile(r'L10n\.tr\(\s*"((?:[^"\\]|\\.)*)"')

# SwiftUI entry points that take a LocalizedStringKey literal. `\s*` spans
# newlines so a literal sitting on the next line is still caught.
LITERAL_CALL = re.compile(
    r"(?:\b(?:Text|Button|Toggle|Label|Picker|Section|TextField|SecureField|"
    r"Menu|NavigationLink|DisclosureGroup|Alert)\(\s*"
    r"|\.(?:navigationTitle|help|accessibilityLabel|accessibilityHint|"
    r"accessibilityValue)\(\s*)"
    r'"((?:[^"\\]|\\.)*)"'
)

ESCAPES = {"n": "\n", "t": "\t", '"': '"', "'": "'", "\\": "\\"}


def unescape(raw: str) -> str:
    out, i = [], 0
    while i < len(raw):
        ch = raw[i]
        if ch == "\\" and i + 1 < len(raw):
            nxt = raw[i + 1]
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def strip_interpolations(raw: str) -> str:
    """Replace `\\(…)` with `%@`, the placeholder SwiftUI uses for the key.

    `Text("Export \\(name)")` is looked up as `Export %@`, so the catalog has
    to carry that form. Runs on the *raw* capture: unescaping first would turn
    the interpolation marker into a plain paren and hide it.
    """
    out, i = [], 0
    while i < len(raw):
        if raw[i] == "\\" and i + 1 < len(raw) and raw[i + 1] == "(":
            depth, j = 1, i + 2
            while j < len(raw) and depth:
                if raw[j] == "(":
                    depth += 1
                elif raw[j] == ")":
                    depth -= 1
                j += 1
            out.append("%@")
            i = j
        else:
            out.append(raw[i])
            i += 1
    return "".join(out)


def keys_from_sources(root: Path) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {"l10n": set(), "literal": set()}
    for path in sorted(root.rglob("*.swift")):
        if "Tests" in path.parts or "UITests" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        for pattern, bucket in ((L10N_CALL, "l10n"), (LITERAL_CALL, "literal")):
            for match in pattern.finditer(text):
                raw = match.group(1)
                if bucket == "literal":
                    # Glue text such as `Text("\\(label): \\(value)")` carries
                    # no words of its own, so there is nothing to translate.
                    raw = strip_interpolations(raw)
                    if not re.search(r"[A-Za-z]{2,}", raw):
                        continue
                key = unescape(raw)
                if key and not key.startswith("%"):
                    found[bucket].add(key)
    return found


def parse_catalog(path: Path) -> dict[str, str]:
    entry = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    catalog = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("/*") or stripped.startswith("//"):
            continue
        match = entry.match(line)
        if match:
            catalog[unescape(match.group(1))] = unescape(match.group(2))
    return catalog


def main(argv: list[str]) -> int:
    sources = Path(argv[1]) if len(argv) > 1 else DEFAULT_SOURCES
    catalogs_paths = [Path(p) for p in argv[2:]] or DEFAULT_CATALOGS

    missing_paths = [p for p in catalogs_paths if not p.is_file()]
    if missing_paths:
        for path in missing_paths:
            print(f"catalog not found: {path}", file=sys.stderr)
        return 2

    used = keys_from_sources(sources)
    catalogs = {p.parent.name: parse_catalog(p) for p in catalogs_paths}
    names = sorted(catalogs)
    failures = 0

    print(f"sources: {sources}")
    print(f"  L10n.tr keys        : {len(used['l10n'])}")
    print(f"  SwiftUI literal keys: {len(used['literal'])}")
    for name in names:
        print(f"  catalog {name:<12}: {len(catalogs[name])} entries")

    # 1. catalog parity
    if len(names) >= 2:
        for left, right in zip(names, names[1:]):
            only_left = sorted(set(catalogs[left]) - set(catalogs[right]))
            only_right = sorted(set(catalogs[right]) - set(catalogs[left]))
            if only_left or only_right:
                failures += 1
                print(f"\n[FAIL] {left} and {right} do not hold the same keys")
                for key in only_left:
                    print(f"  only in {left}: {key!r}")
                for key in only_right:
                    print(f"  only in {right}: {key!r}")
            else:
                print(f"\n[OK] {left} and {right} hold the same key set")

    # 2. every used key exists in every catalog
    for bucket in ("l10n", "literal"):
        for name in names:
            missing = sorted(k for k in used[bucket] if k not in catalogs[name])
            if missing:
                failures += 1
                print(f"\n[FAIL] {len(missing)} {bucket} key(s) missing from {name}")
                for key in missing:
                    print(f"  {key!r}")
            else:
                print(f"[OK] all {len(used[bucket])} {bucket} keys present in {name}")

    # 3. values that equal their key outside English
    for name in names:
        if name.startswith("en"):
            continue
        untranslated = sorted(k for k, v in catalogs[name].items() if v == k)
        if untranslated:
            print(f"\n[WARN] {len(untranslated)} key(s) in {name} equal their key")
            for key in untranslated:
                print(f"  {key!r}")

    print("\nRESULT:", "FAIL" if failures else "OK")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
