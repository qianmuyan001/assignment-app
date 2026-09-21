"""Check real package boundaries and reject unrelated/dirty native builds."""
import importlib.util
import json
import plistlib
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("distribution", Path(__file__).parents[1] / "package_distribution.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DistributionTests(unittest.TestCase):
    def test_mac_bundle_uses_native_version_and_records_web_version(self):
        # Synthetic payload tests archive metadata only, never an Apple build.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            native = root / "Assignment App.app"
            executable = native / "Contents/MacOS/Assignment App"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"synthetic fixture; not an application")
            apple_version = (MODULE.ROOT / "native/apple/VERSION").read_text().strip()
            apple_build = (MODULE.ROOT / "native/apple/BUILD_NUMBER").read_text().strip()
            web_version = (MODULE.ROOT / "VERSION").read_text().strip()
            plist = native / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": apple_version, "CFBundleVersion": apple_build,
            }))
            revision = MODULE.git("rev-parse", "HEAD")
            info = root / "build-info.txt"
            info.write_text(
                f"source_revision={revision}\nsource_tree_dirty=false\n"
                f"version={apple_version}\nbuild_number={apple_build}\n", encoding="utf-8",
            )
            tracked_files = MODULE.git("ls-files")

            def git(*args):
                return {"status": "", "rev-parse": revision, "ls-files": tracked_files}[args[0]]

            def fixture_archive(command, **_kwargs):
                # ditto is exercised on macOS CI; this test checks its input tree.
                bundle, archive = Path(command[-2]), Path(command[-1])
                shutil.make_archive(str(archive.with_suffix("")), "zip", bundle.parent, bundle.name)

            with patch.object(MODULE, "git", side_effect=git), \
                 patch.object(MODULE.sys, "platform", "darwin"), \
                 patch.object(MODULE.subprocess, "run", side_effect=fixture_archive):
                archive = MODULE.package("macos", native, info, root / "output")
                self.assertIn(f"Assignment-App-{apple_version}-Mac", archive.name)
                with zipfile.ZipFile(archive) as contents:
                    prefix = archive.stem + "/"
                    manifest = json.loads(contents.read(prefix + "manifest.json"))
                    self.assertEqual(manifest["version"], apple_version)
                    self.assertEqual(manifest["web_version"], web_version)
                    self.assertEqual(contents.read(prefix + "Web/VERSION").decode().strip(), web_version)
                    self.assertIn(f"Web version: {web_version}", contents.read(prefix + "README.txt").decode())
                plist.write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": web_version, "CFBundleVersion": apple_build,
                }))
                with self.assertRaisesRegex(ValueError, "Apple.*version"):
                    MODULE.package("macos", native, info, root / "wrong-version")
                plist.write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": apple_version, "CFBundleVersion": "999",
                }))
                with self.assertRaisesRegex(ValueError, "Apple.*build"):
                    MODULE.package("macos", native, info, root / "wrong-build")
                plist.write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": apple_version, "CFBundleVersion": apple_build,
                }))
                info.write_text(f"source_revision={revision}\nsource_tree_dirty=false\n", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Apple.*evidence"):
                    MODULE.package("macos", native, info, root / "missing-evidence")

    def test_both_platforms_include_runnable_web_without_user_data(self):
        for platform, launcher in (("windows", "start.bat"), ("macos", "start.command")):
            files = MODULE.web_files(platform)
            for required in (launcher, "requirements.txt", "scripts/wait_for_backend.py", "backend/app/main.py", "backend/app/static/index.html", "backend/app/static/learning.js", "shared/schema_v4.py"):
                self.assertIn(required, files)
            self.assertFalse(any(".db" in name or name.endswith(".bak") or "attachments/" in name for name in files))
            self.assertTrue(all((MODULE.ROOT / name).is_file() for name in files))

    def test_windows_archive_contains_web_native_manifest_and_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            native = root / "publish"
            native.mkdir()
            (native / "AssignmentNative.exe").write_bytes(b"test fixture, not a native acceptance build")
            info = root / "build-info.txt"
            revision = MODULE.git("rev-parse", "HEAD")
            info.write_text(f"source_revision={revision}\nsource_tree_dirty=false\n", encoding="utf-8")
            original_git = MODULE.git
            def git(*args):
                return "" if args[0] == "status" else original_git(*args)
            with patch.object(MODULE, "git", side_effect=git):
                archive = MODULE.package("windows", native, info, root / "output")
                with zipfile.ZipFile(archive) as package:
                    prefix = archive.stem + "/"
                    self.assertIn(prefix + "Native/AssignmentNative.exe", package.namelist())
                    self.assertIn(prefix + "Web/start.bat", package.namelist())
                    manifest = json.loads(package.read(prefix + "manifest.json"))
                    self.assertEqual(manifest["source_revision"], revision)
                    self.assertTrue(manifest["web_included"])
                    self.assertFalse(manifest["python_bundled"])
                    self.assertIn("Web/shared/schema_v4.py", manifest["sha256"])
                self.assertTrue(archive.with_suffix(".zip.sha256").is_file())
                with self.assertRaises(FileExistsError):
                    MODULE.package("windows", native, info, root / "output")
                info.write_text("source_revision=unrelated\nsource_tree_dirty=false\n", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "must match"):
                    MODULE.package("windows", native, info, root / "output")
            with patch.object(MODULE, "git", side_effect=lambda *args: " M README.md" if args[0] == "status" else revision):
                with self.assertRaisesRegex(ValueError, "Commit source"):
                    MODULE.package("windows", native, info, root / "output")


if __name__ == "__main__":
    unittest.main()
