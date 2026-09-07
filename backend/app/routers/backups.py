"""Local backup center: download, inspect, explicitly confirm, restore."""

from pathlib import Path
import tempfile

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from ..database import DATABASE_PATH, engine
from ..services.backup_store import BackupError, BackupStore, MAX_ARCHIVE_BYTES


router = APIRouter(prefix="/backups", tags=["backups"])
store = BackupStore(DATABASE_PATH)


class RestoreRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    token: str = Field(pattern=r"^[0-9a-f-]{36}$")
    confirm: bool


@router.get("")
def list_backups() -> list[dict]:
    return store.list_backups()


@router.post("", status_code=201)
def create_backup() -> dict:
    return store.create()


@router.get("/{backup_id}/download")
def download_backup(backup_id: str) -> FileResponse:
    path = store.download_path(backup_id)
    return FileResponse(path, media_type="application/zip",
                        filename=f"assignment-backup-{backup_id}.zip")


@router.post("/preflight")
async def preflight_backup(request: Request) -> dict:
    if request.headers.get("content-type", "").split(";", 1)[0] not in (
            "application/zip", "application/octet-stream"):
        raise HTTPException(415, "Upload a ZIP backup using application/zip")
    store.prepare()
    with tempfile.NamedTemporaryFile(prefix="upload-", suffix=".zip", dir=store.root) as handle:
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_ARCHIVE_BYTES:
                raise HTTPException(413, "Backup exceeds the 512 MiB limit")
            handle.write(chunk)
        handle.flush()
        return await run_in_threadpool(store.preflight, Path(handle.name))


@router.post("/restore")
def restore_backup(body: RestoreRequest) -> dict:
    if body.confirm is not True:
        raise HTTPException(409, "Explicit restore confirmation is required")
    # The maintenance middleware waits for all prior responses and closes
    # their sessions before this endpoint runs, including attachment streams.
    engine.dispose()
    try:
        return store.restore(body.token)
    finally:
        engine.dispose()
