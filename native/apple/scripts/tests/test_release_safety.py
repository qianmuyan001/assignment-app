import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fingerprints', SCRIPTS / 'protected-data-fingerprint.py')
fingerprints = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fingerprints)

class ReleaseSafetyTests(unittest.TestCase):
    def test_missing_file_fingerprint_never_creates_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'assignments.db'
            self.assertEqual(fingerprints.fingerprint(db), {'exists': False})
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_same_size_same_mtime_changes_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'assignments.db'; db.write_bytes(b'first')
            before = fingerprints.fingerprint(db); db.write_bytes(b'other')
            os.utime(db, ns=(before['mtime_ns'], before['mtime_ns']))
            after = fingerprints.fingerprint(db)
            self.assertEqual(before['size'], after['size'])
            self.assertEqual(before['mtime_ns'], after['mtime_ns'])
            self.assertNotEqual(before['sha256'], after['sha256'])

    def test_protected_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / 'assignments.db'; link.symlink_to('/missing')
            with self.assertRaises(RuntimeError): fingerprints.fingerprint(link)

    def test_synthetic_fixture_contains_committed_wal_and_cannot_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'fixture'
            command = [sys.executable, str(SCRIPTS / 'upgrade-rehearsal.py'), 'prepare', '--fixture', str(fixture)]
            subprocess.run(command, check=True, capture_output=True)
            receipt = json.loads((fixture / 'SYNTHETIC-ONLY.json').read_text())
            self.assertEqual(receipt['schema'], 2)
            self.assertGreater((fixture / 'assignments.db-wal').stat().st_size, 0)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_installation_and_uninstall_require_later_acceptance(self):
        for action in ['install', 'launch', 'seed', 'check', 'uninstall']:
            result = subprocess.run([sys.executable, str(SCRIPTS / 'upgrade-rehearsal.py'), action], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('wait for 开始验收', result.stderr)

    def test_notarization_upload_has_separate_authorization(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / 'developer-id-release.py'), 'submit'], capture_output=True, text=True,
                                env={**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode-beta.app/Contents/Developer'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Explicit upload authorization required', result.stderr)

if __name__ == '__main__': unittest.main()
