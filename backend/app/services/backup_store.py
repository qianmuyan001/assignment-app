"""Verified SQLite snapshots with attachment payloads and transactional restore.

The HTTP maintenance gate holds the database advisory lock for the complete
request, including streaming uploads/downloads. Direct callers must provide
the same exclusion when sharing a store with an application process.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
import time
import zipfile
from collections.abc import Callable
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from shared.schema_v3 import validate_v3_schema
from shared.schema_v4 import validate_v4_schema

from .attachment_store import AttachmentStore


MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
PREFLIGHT_TTL_SECONDS = 30 * 60
TABLES = (
    "assignments", "courses", "projects", "tags", "task_tags", "subtasks",
    "attachments", "reminders", "course_meetings", "exams",
)


class BackupError(RuntimeError):
    """An archive or restore failed validation without silently losing data."""


class PayloadEntry(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str
    byte_size: int = Field(ge=0, le=MAX_ARCHIVE_BYTES)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class Manifest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    format_version: int = Field(ge=1, le=1)
    schema_version: int = Field(ge=3, le=4)
    created_at: str
    database: PayloadEntry
    attachments: list[PayloadEntry] = Field(max_length=10000)


def _hash(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def _fingerprint(connection: sqlite3.Connection) -> str:
    digest = hashlib.sha256()
    for statement in connection.iterdump():
        digest.update(statement.encode("utf-8") + b"\n")
    digest.update(str(connection.execute("PRAGMA user_version").fetchone()[0]).encode())
    return digest.hexdigest()


def _connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path, timeout=10)
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA busy_timeout=10000")
    return connection


def _validate(connection: sqlite3.Connection) -> int:
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version not in (3, 4):
        raise BackupError(f"Unsupported backup schema version: {version}")
    if version == 3:
        validate_v3_schema(connection)
    else:
        validate_v4_schema(connection)
        # The shared v4 validator covers additive objects. Also validate every
        # inherited v3 invariant without permanently changing the version.
        connection.execute("SAVEPOINT validate_inherited")
        try:
            connection.execute("PRAGMA user_version=3")
            validate_v3_schema(connection)
        finally:
            connection.execute("ROLLBACK TO validate_inherited")
            connection.execute("RELEASE validate_inherited")
    return version


def _uuid(value: str) -> str:
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError) as exc:
        raise BackupError("Invalid backup identifier") from exc
    if str(parsed) != value or parsed.version not in (4, 5):
        raise BackupError("Invalid backup identifier")
    return value


def _atomic_json(path: Path, data: dict) -> None:
    temporary = path.with_suffix(".partial")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


class BackupStore:
    def __init__(self, database_path: str | Path):
        self.database_path = Path(database_path).resolve()
        self.root = self.database_path.parent / "web-backups"
        self.payloads = AttachmentStore(self.database_path)
        self.journal = self.root / "restore-journal.json"

    def prepare(self) -> None:
        if self.root.is_symlink():
            raise BackupError("Backup directory must not be a symbolic link")
        self.root.mkdir(parents=True, exist_ok=True)
        self.payloads.prepare()

    def _snapshot(self, destination: Path) -> None:
        # A separate writer connection freezes metadata while Online Backup
        # reads committed pages, including WAL pages, into a standalone file.
        guard = _connect(self.database_path)
        source = sqlite3.connect(f"{self.database_path.as_uri()}?mode=ro", uri=True)
        target = _connect(destination)
        try:
            guard.execute("BEGIN IMMEDIATE")
            source.backup(target)
            target.execute("PRAGMA journal_mode=DELETE")
            _validate(target)
            if _fingerprint(source) != _fingerprint(target):
                raise BackupError("Online snapshot payload mismatch")
        finally:
            guard.rollback()
            guard.close()
            source.close()
            target.close()

    def create(self) -> dict:
        self.prepare()
        backup_id = str(uuid4())
        destination = self.root / f"{backup_id}.zip"
        partial = self.root / f"{backup_id}.partial"
        try:
            with tempfile.TemporaryDirectory(prefix="snapshot-", dir=self.root) as directory:
                snapshot = Path(directory) / "database.sqlite3"
                self._snapshot(snapshot)
                with closing(_connect(snapshot)) as connection:
                    version = _validate(connection)
                    rows = connection.execute(
                        "SELECT uuid,byte_size,sha256,deleted_at FROM attachments ORDER BY uuid"
                    ).fetchall()
                entries = []
                files = []
                for identifier, byte_size, digest, deleted_at in rows:
                    payload = self.payloads.available_path(identifier)
                    if payload is None:
                        if deleted_at is None:
                            raise BackupError(f"Attachment payload is missing: {identifier}")
                        continue
                    if payload.stat().st_size != byte_size or _hash(payload) != digest:
                        raise BackupError(f"Attachment checksum mismatch: {identifier}")
                    entries.append(PayloadEntry(path=f"attachments/{identifier}",
                                                byte_size=byte_size, sha256=digest))
                    files.append(payload)
                manifest = Manifest(
                    format_version=1, schema_version=version,
                    created_at=datetime.now(timezone.utc).isoformat(),
                    database=PayloadEntry(path="database.sqlite3", byte_size=snapshot.stat().st_size,
                                          sha256=_hash(snapshot)), attachments=entries,
                )
                if manifest.database.byte_size + sum(item.byte_size for item in entries) > MAX_ARCHIVE_BYTES:
                    raise BackupError("Backup exceeds the 512 MiB limit")
                with zipfile.ZipFile(partial, "x", compression=zipfile.ZIP_DEFLATED) as archive:
                    archive.writestr("manifest.json", manifest.model_dump_json())
                    archive.write(snapshot, "database.sqlite3")
                    for payload, entry in zip(files, entries):
                        archive.write(payload, entry.path)
                # Validate the actual exported bytes before publishing a backup.
                self._extract_verified(partial, Path(directory) / "verify")
                os.replace(partial, destination)
            return self.describe(backup_id)
        except (OSError, sqlite3.Error, ValueError, RuntimeError) as exc:
            partial.unlink(missing_ok=True)
            if isinstance(exc, BackupError):
                raise
            raise BackupError(f"Backup creation failed: {exc}") from exc

    def describe(self, backup_id: str) -> dict:
        path = self.download_path(backup_id)
        with zipfile.ZipFile(path) as archive:
            manifest = Manifest.model_validate_json(archive.read("manifest.json"))
        return {"id": backup_id, "filename": f"assignment-backup-{backup_id}.zip",
                "created_at": manifest.created_at, "size": path.stat().st_size}

    def list_backups(self) -> list[dict]:
        self.prepare()
        return [self.describe(path.stem) for path in
                sorted(self.root.glob("*.zip"), key=lambda item: item.stat().st_mtime, reverse=True)]

    def download_path(self, backup_id: str) -> Path:
        path = self.root / f"{_uuid(backup_id)}.zip"
        if path.is_symlink() or not path.is_file():
            raise BackupError("Backup was not found")
        return path

    def _extract_verified(self, path: Path, destination: Path) -> dict:
        destination.mkdir(parents=True)
        try:
            with zipfile.ZipFile(path) as archive:
                infos = archive.infolist()
                names = [item.filename for item in infos]
                if len(infos) > 10002 or len(names) != len(set(names)):
                    raise BackupError("Archive contains too many or duplicate entries")
                if sum(item.file_size for item in infos) > MAX_ARCHIVE_BYTES:
                    raise BackupError("Expanded backup exceeds the 512 MiB limit")
                if "manifest.json" not in names or archive.getinfo("manifest.json").file_size > 2 * 1024 * 1024:
                    raise BackupError("Missing or oversized backup manifest")
                manifest = Manifest.model_validate_json(archive.read("manifest.json"))
                if manifest.database.path != "database.sqlite3":
                    raise BackupError("Invalid database snapshot path")
                entries = [manifest.database, *manifest.attachments]
                allowed = {"manifest.json", *(entry.path for entry in entries)}
                if set(names) != allowed or len(allowed) != len(entries) + 1:
                    raise BackupError("Archive entries do not match the manifest")
                for entry in manifest.attachments:
                    if entry.path != f"attachments/{_uuid(entry.path.removeprefix('attachments/'))}":
                        raise BackupError("Unsafe attachment archive path")
                for entry in entries:
                    info = archive.getinfo(entry.path)
                    if info.file_size != entry.byte_size or ((info.external_attr >> 16) & 0o170000) == 0o120000:
                        raise BackupError("Invalid archive entry size or symbolic link")
                    target = destination / entry.path
                    target.parent.mkdir(exist_ok=True)
                    with archive.open(info) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
                    if _hash(target) != entry.sha256:
                        raise BackupError(f"Backup checksum mismatch: {entry.path}")
            database = destination / "database.sqlite3"
            with closing(_connect(database)) as connection:
                version = _validate(connection)
                if version != manifest.schema_version:
                    raise BackupError("Manifest and database schema versions disagree")
                rows = connection.execute("SELECT uuid,byte_size,sha256,deleted_at FROM attachments").fetchall()
                declared = {entry.path: entry for entry in manifest.attachments}
                expected = set()
                for identifier, byte_size, digest, deleted_at in rows:
                    key = f"attachments/{identifier}"
                    if deleted_at is None or key in declared:
                        expected.add(key)
                        entry = declared.get(key)
                        if entry is None or entry.byte_size != byte_size or entry.sha256 != digest:
                            raise BackupError(f"Attachment metadata mismatch: {identifier}")
                if expected != set(declared):
                    raise BackupError("Backup contains unreferenced attachments")
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                counts = {name: connection.execute(f'SELECT COUNT(*) FROM "{name}"').fetchone()[0]
                          for name in TABLES if name in tables}
            (destination / "attachments").mkdir(exist_ok=True)
            return {"schema_version": version, "counts": counts,
                    "attachment_count": len(manifest.attachments)}
        except (OSError, sqlite3.Error, zipfile.BadZipFile, KeyError, ValueError, RuntimeError, ValidationError) as exc:
            if isinstance(exc, BackupError):
                raise
            raise BackupError(f"Backup validation failed: {exc}") from exc

    def preflight(self, archive_path: Path) -> dict:
        self.prepare()
        if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise BackupError("Backup exceeds the 512 MiB limit")
        token = str(uuid4())
        destination = self.root / f"preflight-{token}"
        try:
            summary = self._extract_verified(archive_path, destination)
            # Upgrade only the isolated imported snapshot. The live store is
            # untouched until a separate, explicit restore confirmation.
            from ..database import migrate_database  # avoid startup import cycles
            migrate_database(destination / "database.sqlite3")
            _atomic_json(destination / "preflight.json", {"created": time.time(), "summary": summary})
            return {"token": token, "summary": summary,
                    "warnings": ["Restoring replaces current tasks, learning records and attachments."]}
        except Exception as exc:
            shutil.rmtree(destination)
            if isinstance(exc, BackupError):
                raise
            raise BackupError(f"Import preflight failed: {exc}") from exc

    def recover_interrupted_restore(self) -> None:
        self.prepare()
        if not self.journal.exists():
            return
        journal = json.loads(self.journal.read_text(encoding="utf-8"))
        old = self.root / f"rollback-{_uuid(journal['id'])}"
        with closing(_connect(self.database_path)) as connection:
            actual = _fingerprint(connection)
        if actual not in (journal["old_fingerprint"], journal["new_fingerprint"]):
            raise BackupError("Interrupted restore has unexpected database contents; recovery evidence retained")
        if actual == journal["old_fingerprint"] and old.exists():
            current = self.payloads.attachments_root
            if current.exists():
                shutil.rmtree(current)
            os.replace(old, current)
        elif old.exists():
            shutil.rmtree(old)
        self.journal.unlink()

    def restore(self, token: str, *, failure_hook: Callable[[], None] | None = None) -> dict:
        self.prepare()
        self.recover_interrupted_restore()
        candidate = self.root / f"preflight-{_uuid(token)}"
        metadata = candidate / "preflight.json"
        if not metadata.is_file() or metadata.is_symlink():
            raise BackupError("Preflight token was not found or was already used")
        created = json.loads(metadata.read_text(encoding="utf-8"))["created"]
        if time.time() - created > PREFLIGHT_TTL_SECONDS:
            raise BackupError("Preflight expired; inspect the backup again")
        source = _connect(candidate / "database.sqlite3")
        connection = _connect(self.database_path)
        rollback_id = str(uuid4())
        old_payloads = self.root / f"rollback-{rollback_id}"
        current = self.payloads.attachments_root
        swapped = False
        committed = False
        try:
            _validate(source)
            expected = _fingerprint(source)
            # Reject changes to any staged payload since preflight.
            for identifier, size, digest, deleted in source.execute(
                    "SELECT uuid,byte_size,sha256,deleted_at FROM attachments"):
                payload = candidate / "attachments" / _uuid(identifier)
                if deleted is None or payload.exists():
                    if payload.is_symlink() or not payload.is_file() or payload.stat().st_size != size or _hash(payload) != digest:
                        raise BackupError("Preflight attachment changed; inspect the backup again")
            connection.execute("PRAGMA foreign_keys=OFF")
            connection.execute("BEGIN IMMEDIATE")
            original = _fingerprint(connection)
            objects = connection.execute(
                "SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
                "AND type IN ('trigger','view','table') ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 ELSE 2 END"
            ).fetchall()
            for kind, name in objects:
                quoted = '"' + name.replace('"', '""') + '"'
                connection.execute(f"DROP {kind.upper()} {quoted}")
            for statement in source.iterdump():
                if statement not in ("BEGIN TRANSACTION;", "COMMIT;"):
                    connection.execute(statement)
            connection.execute("PRAGMA user_version=4")
            if connection.execute("PRAGMA foreign_key_check").fetchall():
                raise BackupError("Restored database has invalid references")
            if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise BackupError("Restored database failed integrity validation")
            if _fingerprint(connection) != expected:
                raise BackupError("Restored database did not preserve the complete payload")
            _atomic_json(self.journal, {"id": rollback_id, "old_fingerprint": original,
                                        "new_fingerprint": expected})
            os.replace(current, old_payloads)
            swapped = True
            os.replace(candidate / "attachments", current)
            if failure_hook:
                failure_hook()
            connection.commit()
            committed = True
        except Exception as exc:
            connection.rollback()
            if swapped:
                if current.exists():
                    os.replace(current, candidate / "attachments")
                os.replace(old_payloads, current)
            self.journal.unlink(missing_ok=True)
            if isinstance(exc, BackupError):
                raise
            raise BackupError(f"Restore failed and was rolled back: {exc}") from exc
        finally:
            source.close()
            connection.close()
        if committed:
            # Cleanup after commit is recoverable on next startup. Never tell
            # the user a committed restore rolled back if cleanup itself fails.
            self.recover_interrupted_restore()
            shutil.rmtree(candidate)
        return {"restored": True, "schema_version": 4}
