#!/usr/bin/env python3
"""Fail when Assignment App release-facing version metadata drifts."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"version-sync: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> None:
    version = read("VERSION").strip()
    if re.fullmatch(r"\d+\.\d+\.\d+", version) is None:
        fail(f"VERSION must be semantic x.y.z, got {version!r}")

    readme = read("README.md")
    if f"Current source version: **{version}**" not in readme:
        fail("README current source version does not match VERSION")

    changelog = read("CHANGELOG.md")
    if re.search(rf"^## \[{re.escape(version)}\]", changelog, re.MULTILINE) is None:
        fail("CHANGELOG has no section for VERSION")

    project = read("native/apple/AssignmentApp2.xcodeproj/project.pbxproj")
    apple_versions = set(
        re.findall(r"MARKETING_VERSION = ([^;]+);", project)
    )
    if apple_versions != {version}:
        fail(
            "Apple MARKETING_VERSION values do not match VERSION: "
            + ", ".join(sorted(apple_versions))
        )

    windows_project = ET.parse(
        ROOT / "native/windows/AssignmentNative.Windows.csproj"
    ).getroot()
    windows_version = windows_project.findtext(".//Version")
    if windows_version != version:
        fail(
            f"Windows project Version is {windows_version!r}, expected {version!r}"
        )

    expected_windows_binary_version = f"{version}.0"
    for element_name in ("AssemblyVersion", "FileVersion"):
        value = windows_project.findtext(f".//{element_name}")
        if value != expected_windows_binary_version:
            fail(
                f"Windows {element_name} is {value!r}, expected "
                f"{expected_windows_binary_version!r}"
            )

    manifest = ET.parse(ROOT / "native/windows/app.manifest").getroot()
    namespace = {"asm": "urn:schemas-microsoft-com:asm.v1"}
    identity = manifest.find("asm:assemblyIdentity", namespace)
    manifest_version = None if identity is None else identity.get("version")
    expected_manifest = expected_windows_binary_version
    if manifest_version != expected_manifest:
        fail(
            "Windows manifest version is "
            f"{manifest_version!r}, expected {expected_manifest!r}"
        )

    print(
        "version-sync: OK "
        f"(root, README, CHANGELOG, Apple, Windows = {version})"
    )


if __name__ == "__main__":
    main()
