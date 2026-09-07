"""Backup failures must preserve both database state and attachment bytes."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
import unittest
import zipfile
from pathlib import Path
from uuid import uuid4

from shared.schema_v3 import create_v3_schema
from shared.schema_v4 import migrate_v3_to_v4
from backend.app.services.backup_store import BackupError, BackupStore, _fingerprint


class BackupStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="assignment-backup-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "store.sqlite3"
        self.attachment_uuid = str(uuid4())
        self.content = "学习笔记\nattachment bytes\x00".encode()
        self.store = BackupStore(self.path)
        self.store.prepare()
        with sqlite3.connect(self.path) as connection:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            create_v3_schema(connection)
            migrate_v3_to_v4(connection)
            connection.execute(
                "INSERT INTO assignments(uuid,course_name,title,description,created_at,updated_at) "
                "VALUES(?,?,?,?,'2026-09-07T00:00:00.000Z','2026-09-07T00:00:00.000Z')",
                (str(uuid4()), "数学", "Review derivatives", "保留隐藏字段"),
            )
            connection.execute(
                "INSERT INTO attachments(uuid,assignment_id,file_name,relative_path,byte_size,sha256) "
                "VALUES(?,1,?,?,?,?)",
                (self.attachment_uuid, "notes.txt", f"attachments/{self.attachment_uuid}",
                 len(self.content), hashlib.sha256(self.content).hexdigest()),
            )
            connection.execute("ALTER TABLE assignments ADD COLUMN school_extension TEXT")
            connection.execute("UPDATE assignments SET school_extension='扩展字段 ✅'")
            connection.execute("CREATE TABLE school_data (key TEXT PRIMARY KEY, value BLOB)")
            connection.execute("INSERT INTO school_data VALUES ('bytes', ?)", (b"\x00\xffdata",))
            connection.execute("CREATE INDEX school_index ON school_data(value)")
            connection.execute("CREATE TRIGGER school_trigger AFTER INSERT ON school_data "
                               "BEGIN UPDATE school_data SET value=new.value WHERE key=new.key; END")
        self.payload = self.store.payloads.payload_path(self.attachment_uuid)
        self.payload.write_bytes(self.content)

    def fingerprint(self):
        with sqlite3.connect(self.path) as connection:
            return _fingerprint(connection)

    def archive(self):
        info = self.store.create()
        return self.store.download_path(info["id"])

    def rewrite_archive(self, original, transform):
        target = self.root / f"modified-{uuid4()}.zip"
        with zipfile.ZipFile(original) as archive:
            data = {name: archive.read(name) for name in archive.namelist()}
        transform(data)
        with zipfile.ZipFile(target, "w") as archive:
            for name, content in data.items():
                archive.writestr(name, content)
        return target

    def test_snapshot_includes_committed_wal_and_all_payloads(self):
        with sqlite3.connect(self.path) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("UPDATE assignments SET title='WAL committed title'")
            writer.commit()
            archive = self.archive()
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.read(f"attachments/{self.attachment_uuid}"), self.content)
                snapshot = self.root / "snapshot.sqlite3"
                snapshot.write_bytes(package.read("database.sqlite3"))
            with sqlite3.connect(snapshot) as restored:
                self.assertEqual(restored.execute("SELECT title FROM assignments").fetchone()[0],
                                 "WAL committed title")
                self.assertEqual(restored.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
            self.assertFalse(snapshot.with_name(snapshot.name + "-wal").exists())

    def test_restore_round_trip_preserves_uuid_extensions_and_attachments(self):
        expected = self.fingerprint()
        archive = self.archive()
        before_preflight = self.fingerprint()
        preview = self.store.preflight(archive)
        self.assertEqual(self.fingerprint(), before_preflight)
        self.assertEqual(preview["summary"]["attachment_count"], 1)
        with sqlite3.connect(self.path) as connection:
            connection.execute("UPDATE assignments SET title='After backup'")
        self.payload.write_bytes(b"changed after backup")
        result = self.store.restore(preview["token"])
        self.assertTrue(result["restored"])
        self.assertEqual(self.fingerprint(), expected)
        self.assertEqual(self.payload.read_bytes(), self.content)
        with self.assertRaises(BackupError):
            self.store.restore(preview["token"])

    def test_failure_after_attachment_swap_rolls_back_both_stores(self):
        preview = self.store.preflight(self.archive())
        with sqlite3.connect(self.path) as connection:
            connection.execute("UPDATE assignments SET title='Must survive restore failure'")
        self.payload.write_bytes(b"live payload must survive")
        expected = self.fingerprint()

        def fail():
            raise RuntimeError("injected failure after attachment swap")

        with self.assertRaisesRegex(BackupError, "rolled back"):
            self.store.restore(preview["token"], failure_hook=fail)
        self.assertEqual(self.fingerprint(), expected)
        self.assertEqual(self.payload.read_bytes(), b"live payload must survive")
        self.assertFalse(self.store.journal.exists())

    def test_corrupt_zip_rejected_without_database_changes(self):
        before = self.fingerprint()
        corrupted = self.root / "broken.zip"
        corrupted.write_bytes(b"not a zip archive")
        with self.assertRaises(BackupError):
            self.store.preflight(corrupted)
        self.assertEqual(self.fingerprint(), before)

    def test_modified_attachment_rejected_even_when_zip_crc_is_valid(self):
        archive = self.rewrite_archive(self.archive(), lambda entries: entries.__setitem__(
            f"attachments/{self.attachment_uuid}", b"X" * len(self.content)))
        with self.assertRaisesRegex(BackupError, "checksum"):
            self.store.preflight(archive)

    def test_modified_snapshot_rejected(self):
        archive = self.rewrite_archive(self.archive(), lambda entries: entries.__setitem__(
            "database.sqlite3", bytes(len(entries["database.sqlite3"]))))
        with self.assertRaisesRegex(BackupError, "checksum"):
            self.store.preflight(archive)

    def test_missing_attachment_and_path_traversal_rejected(self):
        base = self.archive()
        for transform in (
            lambda data: data.pop(f"attachments/{self.attachment_uuid}"),
            lambda data: data.__setitem__("../escape", b"bad"),
        ):
            with self.subTest(transform=transform), self.assertRaises(BackupError):
                self.store.preflight(self.rewrite_archive(base, transform))
        self.assertFalse((self.root.parent / "escape").exists())

    def test_attachment_metadata_mismatch_rejected(self):
        def tamper(entries):
            manifest = json.loads(entries["manifest.json"])
            manifest["attachments"][0]["sha256"] = "0" * 64
            entries["manifest.json"] = json.dumps(manifest).encode()
        with self.assertRaises(BackupError):
            self.store.preflight(self.rewrite_archive(self.archive(), tamper))

    def test_missing_live_attachment_prevents_incomplete_backup(self):
        self.payload.unlink()
        with self.assertRaisesRegex(BackupError, "missing"):
            self.store.create()
        self.assertEqual(self.store.list_backups(), [])

    def test_bad_live_attachment_prevents_inconsistent_backup(self):
        self.payload.write_bytes(b"corrupt")
        with self.assertRaisesRegex(BackupError, "checksum"):
            self.store.create()

    def test_staged_attachment_is_reverified_at_confirmation(self):
        preview = self.store.preflight(self.archive())
        staged = self.store.root / f"preflight-{preview['token']}" / "attachments" / self.attachment_uuid
        staged.write_bytes(b"changed")
        before = self.fingerprint()
        with self.assertRaisesRegex(BackupError, "changed"):
            self.store.restore(preview["token"])
        self.assertEqual(self.fingerprint(), before)
        self.assertEqual(self.payload.read_bytes(), self.content)

    def test_token_expiration_and_invalid_identifiers(self):
        preview = self.store.preflight(self.archive())
        metadata = self.store.root / f"preflight-{preview['token']}" / "preflight.json"
        metadata.write_text(json.dumps({"created": 0}))
        with self.assertRaisesRegex(BackupError, "expired"):
            self.store.restore(preview["token"])
        for value in ("../escape", "bad", "00000000-0000-0000-0000-000000000000"):
            with self.subTest(value=value), self.assertRaises(BackupError):
                self.store.download_path(value)

    def test_future_schema_rejected_at_export(self):
        with sqlite3.connect(self.path) as connection:
            connection.execute("PRAGMA user_version=5")
        before = self.fingerprint()
        with self.assertRaisesRegex(BackupError, "Unsupported"):
            self.store.create()
        self.assertEqual(self.fingerprint(), before)

    def test_crash_journal_restores_original_attachment_tree_after_sqlite_rollback(self):
        identifier = str(uuid4())
        old = self.store.root / f"rollback-{identifier}"
        before = self.fingerprint()
        os.replace(self.store.payloads.attachments_root, old)
        self.store.payloads.attachments_root.mkdir()
        self.payload.write_bytes(b"interrupted new content")
        self.store.journal.write_text(json.dumps({"id": identifier,
            "old_fingerprint": before, "new_fingerprint": "different-commit"}))
        self.store.recover_interrupted_restore()
        self.assertEqual(self.payload.read_bytes(), self.content)
        self.assertEqual(self.fingerprint(), before)
        self.assertFalse(self.store.journal.exists())


if __name__ == "__main__":
    unittest.main()
