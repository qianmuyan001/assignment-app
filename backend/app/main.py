from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import models
from .database import ensure_assignment_schema
from .routers import assignments


ensure_assignment_schema()

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


@app.get("/")
def read_root() -> dict[str, str]:
    return {"message": "Assignment Organizer API is running"}
