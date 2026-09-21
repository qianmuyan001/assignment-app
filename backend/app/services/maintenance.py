"""Keep restore, attachment changes and database requests mutually consistent."""

import asyncio
from pathlib import Path

from starlette.concurrency import run_in_threadpool
from starlette.types import ASGIApp, Receive, Scope, Send

from ..database import _migration_lock


class MaintenanceGate:
    """Serialize local-store HTTP requests across workers, through final bytes.

    The async gate prevents waiting file locks from exhausting Starlette's
    worker pool. The advisory file lock is shared with startup migration.
    SQLite still enforces its own transaction locks against external writers.
    """

    def __init__(self, app: ASGIApp, database_path: Path):
        self.app = app
        self.database_path = database_path
        self.gate = asyncio.Lock()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        async with self.gate:
            lock = _migration_lock(self.database_path)
            await run_in_threadpool(lock.__enter__)
            try:
                await self.app(scope, receive, send)
            finally:
                await run_in_threadpool(lock.__exit__, None, None, None)
