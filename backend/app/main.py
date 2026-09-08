from pathlib import Path
import logging

from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException

from . import models
from .database import DATABASE_PATH, ensure_assignment_schema, _migration_lock
from .routers import assignments, organization, backups, learning
from .services.attachment_store import reconcile_attachment_files
from .services.backup_store import BackupError, BackupStore
from .services.maintenance import MaintenanceGate


STATIC_DIR = Path(__file__).resolve().parent / "static"

ensure_assignment_schema()
with _migration_lock(DATABASE_PATH):
    BackupStore(DATABASE_PATH).recover_interrupted_restore()
    reconcile_attachment_files(DATABASE_PATH)

app = FastAPI(title="Assignment Organizer API")
app.add_middleware(MaintenanceGate, database_path=DATABASE_PATH)


def error_response(status: int, code: str, detail: object) -> JSONResponse:
    message = detail if isinstance(detail, str) else "Request validation failed"
    return JSONResponse(status_code=status, content=jsonable_encoder({
        "detail": detail, "error": {"code": code, "message": message},
    }))


@app.exception_handler(HTTPException)
async def http_error(_request: Request, exc: HTTPException) -> JSONResponse:
    return error_response(exc.status_code, f"http_{exc.status_code}", exc.detail)


@app.exception_handler(RequestValidationError)
async def validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
    details = [{key: value for key, value in item.items() if key not in ("ctx", "input")}
               for item in exc.errors()]
    return error_response(422, "validation_error", details)


@app.exception_handler(BackupError)
async def backup_error(_request: Request, exc: BackupError) -> JSONResponse:
    return error_response(422, "backup_validation_failed", str(exc))


@app.exception_handler(Exception)
async def unexpected_error(_request: Request, exc: Exception) -> JSONResponse:
    logging.getLogger(__name__).error("Request failed", exc_info=exc)
    return error_response(500, "internal_error", "The operation failed; please retry")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(assignments.router)
app.include_router(organization.router)
app.include_router(backups.router)
app.include_router(learning.router)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/health")
def read_health() -> dict[str, str]:
    return {"message": "Assignment Organizer API is running"}


@app.get("/")
def read_index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/app-info")
def read_app_info() -> dict:
    root = Path(__file__).resolve().parents[2]
    return {"version": (root / "VERSION").read_text(encoding="utf-8").strip(),
            "schema_version": 4,
            "changelog": ["Phase 3A: timetable, exams, calendar, Today and relative reminders.",
                          "Language, themes, simple/professional mode and verified backups."],
            "changelog_url": "/changelog",
            "reminder_delivery": "while_app_open"}


@app.get("/changelog", response_class=FileResponse)
def read_changelog() -> FileResponse:
    return FileResponse(Path(__file__).resolve().parents[2] / "CHANGELOG.md",
                        media_type="text/plain; charset=utf-8")
