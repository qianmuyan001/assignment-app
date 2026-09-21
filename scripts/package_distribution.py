#!/usr/bin/env python3
"""Bundle a verified platform build with the same revision's standalone Web app."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB_SUFFIXES = {".py", ".sql", ".json", ".js", ".css", ".html", ".svg", ".png", ".ico"}


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def web_files(platform: str) -> list[str]:
    """Only committed application resources; never databases, backups or secrets."""
    files = []
    for name in git("ls-files").splitlines():
        path = Path(name)
        if (name.startswith("backend/app/") or name.startswith("shared/")) and (
            "tests" not in path.parts and path.suffix in WEB_SUFFIXES
        ):
            files.append(name)
    files += ["requirements.txt", "VERSION", "scripts/wait_for_backend.py"]
    files += ["start.bat"] if platform == "windows" else ["start.sh", "start.command", "stop.sh"]
    return sorted(files)


def package(platform: str, native: Path, build_info: Path, output: Path) -> Path:
    native, build_info, output = native.resolve(), build_info.resolve(), output.resolve()
    revision = git("rev-parse", "HEAD")
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Commit source changes before packaging a distribution.")
    info = build_info.read_text(encoding="utf-8-sig")
    metadata = dict(line.split("=", 1) for line in info.splitlines() if "=" in line)
    if metadata.get("source_revision") != revision or metadata.get("source_tree_dirty") != "false":
        raise ValueError("Native build evidence must match this clean source revision.")
    if platform == "windows":
        if not (native / "AssignmentNative.exe").is_file():
            raise ValueError("Windows publish directory has no AssignmentNative.exe.")
    elif sys.platform != "darwin" or not (native / "Contents/MacOS/Assignment App").is_file():
        raise ValueError("Package the built Catalyst .app on macOS.")
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    target = "Windows-x64" if platform == "windows" else "Mac-Catalyst-arm64"
    name = f"Assignment-App-{version}-{target}-with-Web-{revision[:8]}"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{name}.zip"
    if archive.exists():
        raise FileExistsError(f"Refusing to overwrite {archive}")
    with tempfile.TemporaryDirectory(prefix="assignment-distribution-") as temporary:
        bundle = Path(temporary) / name
        web = bundle / "Web"
        web.mkdir(parents=True)
        for relative in web_files(platform):
            destination = web / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        destination = bundle / "Native"
        if platform == "macos":
            destination /= native.name
        shutil.copytree(native, destination, symlinks=True)
        shutil.copy2(build_info, bundle / "native-build-info.txt")
        launcher = "start.bat" if platform == "windows" else "start.command"
        native_entry = "Native/AssignmentNative.exe" if platform == "windows" else "Native/Assignment App.app"
        (bundle / "README.txt").write_text(
            f"Assignment App {version} — {target}\n\n"
            f"桌面版 / Desktop: {native_entry}\n"
            f"网页版 / Web: Web/{launcher}\n\n"
            "网页版需先安装 Python 3.12 或更新版本，首次启动需联网安装依赖。\n"
            "Web requires Python 3.12+; the first launch installs dependencies online.\n"
            "启动后浏览器打开 http://127.0.0.1:8000；保持启动窗口开启。\n"
            "Keep the launcher open while using the local Web app.\n\n"
            "桌面版与网页版默认使用各自数据库，不会自动同步。\n"
            "Native and Web use separate databases by default; synchronization is not implemented.\n"
            "Apple/Web use schema v4; Windows native uses v3. Do not point Windows at a v4 database.\n"
            "未包含任何用户数据库、附件或备份。\n"
            "No user database, attachments or backups are included.\n\n"
            "内部测试包；签名、构建与验收状态见 native-build-info.txt。\n"
            "Internal test build; see native-build-info.txt for signing and acceptance status.\n"
            f"Source revision: {revision}\n", encoding="utf-8",
        )
        hashes = {
            path.relative_to(bundle).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(bundle.rglob("*")) if path.is_file() and not path.is_symlink()
        }
        (bundle / "manifest.json").write_text(json.dumps({
            "source_revision": revision, "version": version, "platform": platform,
            "web_included": True, "python_bundled": False, "sha256": hashes,
        }, indent=2) + "\n", encoding="utf-8")
        # ditto preserves the Apple bundle's symlinks and executable metadata.
        if platform == "macos":
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(archive)], check=True)
        else:
            shutil.make_archive(str(archive.with_suffix("")), "zip", temporary, name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(archive)
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("windows", "macos"), required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--build-info", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/distributions")
    args = parser.parse_args()
    package(args.platform, args.native, args.build_info, args.output)


if __name__ == "__main__":
    main()
