from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import models
from .database import DATABASE_PATH, ensure_assignment_schema
from .routers import assignments, organization
from .services.attachment_store import reconcile_attachment_files


STATIC_DIR = Path(__file__).resolve().parent / "static"

ensure_assignment_schema()
reconcile_attachment_files(DATABASE_PATH)

app = FastAPI(title="Assignment Organizer API")

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
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/health")
def read_health() -> dict[str, str]:
    return {"message": "Assignment Organizer API is running"}


@app.get("/")
def read_index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")
