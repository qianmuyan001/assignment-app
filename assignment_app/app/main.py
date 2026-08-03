from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .routes import router as assignment_router


BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

app = FastAPI(title="Assignment App Backend")

app.include_router(assignment_router)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def read_root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")
