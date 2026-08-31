from __future__ import annotations

import hashlib
import os
import sqlite3
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4


MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024


class AttachmentStoreError(RuntimeError):
    """Raised when a payload cannot be handled without crossing its data root."""


@dataclass(frozen=True)
class StoredPayload:
    byte_size: int
    sha256: str
    path: Path


class AttachmentStore:
    def __init__(self, database_path: str | Path) -> None:
        self.data_root = Path(database_path).expanduser().resolve().parent
        self.attachments_root = self.data_root / "attachments"
        self.staging_root = self.data_root / ".attachment-staging"

    def prepare(self) -> None:
        self.attachments_root.mkdir(parents=True, exist_ok=True)
        self.staging_root.mkdir(parents=True, exist_ok=True)
        for root in (self.attachments_root, self.staging_root):
            if root.is_symlink() or not root.is_dir():
                raise AttachmentStoreError("attachment storage root is unsafe")

    async def store_stream(
        self,
        attachment_uuid: str,
        chunks: AsyncIterator[bytes],
    ) -> StoredPayload:
        self.prepare()
        destination = self.payload_path(attachment_uuid)
        if destination.exists():
            raise AttachmentStoreError("attachment payload already exists")
        staged = self.staging_root / f"{uuid4()}.partial"
        digest = hashlib.sha256()
        byte_size = 0
        try:
            with staged.open("xb") as handle:
                async for chunk in chunks:
                    if not chunk:
                        continue
                    byte_size += len(chunk)
                    if byte_size > MAX_ATTACHMENT_BYTES:
                        raise AttachmentStoreError(
                            f"attachment exceeds {MAX_ATTACHMENT_BYTES} bytes"
                        )
                    digest.update(chunk)
                    handle.write(chunk)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(staged, destination)
            return StoredPayload(byte_size, digest.hexdigest(), destination)
        except Exception:
            staged.unlink(missing_ok=True)
            raise

    def payload_path(self, attachment_uuid: str) -> Path:
        try:
            parsed = UUID(attachment_uuid)
        except (ValueError, AttributeError) as exc:
            raise AttachmentStoreError("attachment UUID is invalid") from exc
        canonical = str(parsed)
        if canonical != attachment_uuid or parsed.version not in {4, 5}:
            raise AttachmentStoreError("attachment UUID is not canonical")
        candidate = self.attachments_root / canonical
        if candidate.parent != self.attachments_root:
            raise AttachmentStoreError("attachment path escapes its storage root")
        return candidate

    def available_path(self, attachment_uuid: str) -> Path | None:
        path = self.payload_path(attachment_uuid)
        if not path.exists():
            return None
        if path.is_symlink() or not path.is_file():
            raise AttachmentStoreError("attachment payload is not a regular file")
        return path

    def stage_delete(self, attachment_uuid: str) -> tuple[Path, Path] | None:
        self.prepare()
        source = self.payload_path(attachment_uuid)
        if not source.exists():
            return None
        if source.is_symlink() or not source.is_file():
            raise AttachmentStoreError("attachment payload is not a regular file")
        staged = self.staging_root / f"{attachment_uuid}.deleted"
        staged.unlink(missing_ok=True)
        os.replace(source, staged)
        return source, staged

    @staticmethod
    def finish_delete(staged: tuple[Path, Path] | None) -> None:
        if staged is not None:
            try:
                staged[1].unlink(missing_ok=True)
            except OSError:
                # Metadata is already committed. Reconciliation removes this
                # tombstone on the next startup instead of reporting a false
                # delete failure after the database change succeeded.
                pass

    @staticmethod
    def rollback_delete(staged: tuple[Path, Path] | None) -> None:
        if staged is not None and staged[1].exists():
            os.replace(staged[1], staged[0])

    def remove_payload(self, attachment_uuid: str) -> None:
        self.payload_path(attachment_uuid).unlink(missing_ok=True)

    def reconcile(self, active_uuids: set[str]) -> tuple[int, list[str]]:
        self.prepare()
        self._reconcile_staging(active_uuids)
        missing = sorted(
            value for value in active_uuids if self.available_path(value) is None
        )
        removed = 0
        for candidate in self.attachments_root.iterdir():
            try:
                parsed = UUID(candidate.name)
            except ValueError:
                continue
            if str(parsed) in active_uuids:
                continue
            if candidate.is_file() and not candidate.is_symlink():
                candidate.unlink()
                removed += 1
        return removed, missing

    def _reconcile_staging(self, active_uuids: set[str]) -> None:
        for candidate in self.staging_root.iterdir():
            if candidate.name.endswith(".partial"):
                if candidate.is_symlink() or candidate.is_file():
                    candidate.unlink(missing_ok=True)
                continue
            if not candidate.name.endswith(".deleted"):
                continue
            attachment_uuid = candidate.name.removesuffix(".deleted")
            try:
                parsed = UUID(attachment_uuid)
            except ValueError:
                continue
            if str(parsed) != attachment_uuid:
                continue
            if candidate.is_symlink() or not candidate.is_file():
                candidate.unlink(missing_ok=True)
                continue
            destination = self.payload_path(attachment_uuid)
            if attachment_uuid in active_uuids and not destination.exists():
                os.replace(candidate, destination)
            else:
                candidate.unlink(missing_ok=True)


def reconcile_attachment_files(database_path: str | Path) -> tuple[int, list[str]]:
    path = Path(database_path).expanduser().resolve()
    with sqlite3.connect(path) as connection:
        active = {
            str(row[0])
            for row in connection.execute(
                "SELECT uuid FROM attachments WHERE deleted_at IS NULL"
            )
        }
    return AttachmentStore(path).reconcile(active)
