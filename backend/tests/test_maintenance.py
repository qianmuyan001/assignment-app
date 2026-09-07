"""Verify that streamed responses retain the cross-worker maintenance gate."""
from __future__ import annotations

import asyncio
import multiprocessing
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

# Importing the middleware imports database configuration. Never let a test
# process, including multiprocessing spawn workers, point at a user database.
_IMPORT_ROOT = tempfile.TemporaryDirectory(prefix="assignment-maintenance-import-")
os.environ["ASSIGNMENT_DB_PATH"] = str(Path(_IMPORT_ROOT.name) / "unused.db")

from starlette.responses import Response, StreamingResponse  # noqa: E402
from backend.app.database import _migration_lock  # noqa: E402
from backend.app.services.maintenance import MaintenanceGate  # noqa: E402


def _hold_process_lock(path: str, acquired, release) -> None:
    """Represent another backend worker/startup holding the same file lock."""
    with _migration_lock(Path(path)):
        acquired.set()
        if not release.wait(timeout=10):
            raise TimeoutError("test parent did not release the temporary lock")


def _scope(path: str) -> dict:
    return {
        "type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"},
        "http_version": "1.1", "method": "GET" if path == "/attachment" else "POST",
        "scheme": "http", "path": path, "raw_path": path.encode(),
        "query_string": b"", "headers": [], "root_path": "",
        "server": ("testserver", 80), "client": ("127.0.0.1", 1),
    }


async def _receive() -> dict:
    return {"type": "http.request", "body": b"", "more_body": False}


async def _discard(_message: dict) -> None:
    return None


class MaintenanceGateTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="assignment-maintenance-case-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.database = self.root / "disposable.sqlite3"
        self.attachment = self.root / "attachment.bin"
        self.original_payload = b"original attachment content\x00\xff"
        self.attachment.write_bytes(self.original_payload)
        with closing(sqlite3.connect(self.database)) as connection:
            connection.execute("CREATE TABLE mutations(id INTEGER PRIMARY KEY, value TEXT)")

    def mutation_count(self) -> int:
        with closing(sqlite3.connect(self.database)) as connection:
            return connection.execute("SELECT COUNT(*) FROM mutations").fetchone()[0]

    async def assert_not_entered(self, event: asyncio.Event) -> None:
        # The competing task signals its attempt before entering middleware.
        # A bounded wait proves that it cannot reach its actual side effects.
        with self.assertRaises(TimeoutError):
            await asyncio.wait_for(event.wait(), timeout=0.1)
        self.assertEqual(self.mutation_count(), 0)
        self.assertEqual(self.attachment.read_bytes(), self.original_payload)

    async def _prove_stream_exclusion(self, *, separate_worker: bool) -> None:
        first_body = asyncio.Event()
        continue_stream = asyncio.Event()
        final_send_started = asyncio.Event()
        accept_final_send = asyncio.Event()
        mutation_attempted = asyncio.Event()
        mutation_entered = asyncio.Event()
        delivered = []

        async def stream():
            with self.attachment.open("rb") as handle:
                yield handle.read(3)
                await continue_stream.wait()
                yield handle.read()

        async def app(scope, receive, send):
            if scope["path"] == "/attachment":
                await StreamingResponse(stream(), media_type="application/octet-stream")(
                    scope, receive, send
                )
                return
            mutation_entered.set()
            with closing(sqlite3.connect(self.database)) as connection:
                connection.execute("INSERT INTO mutations(value) VALUES('new task state')")
                connection.commit()
            self.attachment.write_bytes(b"replacement payload")
            await Response(status_code=204)(scope, receive, send)

        async def slow_send(message):
            if message["type"] == "http.response.body":
                delivered.append(message.get("body", b""))
                if message.get("body"):
                    first_body.set()
                if not message.get("more_body", False):
                    final_send_started.set()
                    # Simulate a socket whose final response bytes have not
                    # drained. Releasing a route's lock at response creation
                    # or after its first chunk would be observably unsafe.
                    await accept_final_send.wait()

        first_gate = MaintenanceGate(app, self.database)
        second_gate = MaintenanceGate(app, self.database) if separate_worker else first_gate
        first_request = asyncio.create_task(first_gate(_scope("/attachment"), _receive, slow_send))

        async def mutate():
            mutation_attempted.set()
            await second_gate(_scope("/assignments/1"), _receive, _discard)

        second_request = None
        try:
            await asyncio.wait_for(first_body.wait(), timeout=5)
            second_request = asyncio.create_task(mutate())
            await asyncio.wait_for(mutation_attempted.wait(), timeout=5)
            await self.assert_not_entered(mutation_entered)
            continue_stream.set()
            await asyncio.wait_for(final_send_started.wait(), timeout=5)
            await self.assert_not_entered(mutation_entered)
            accept_final_send.set()
            await asyncio.wait_for(asyncio.gather(first_request, second_request), timeout=5)
            self.assertTrue(mutation_entered.is_set())
            self.assertEqual(self.mutation_count(), 1)
            self.assertEqual(b"".join(delivered), self.original_payload)
            self.assertEqual(self.attachment.read_bytes(), b"replacement payload")
        finally:
            continue_stream.set()
            accept_final_send.set()
            await asyncio.wait_for(asyncio.gather(
                first_request, *([second_request] if second_request is not None else []),
                return_exceptions=True,
            ), timeout=5)

    async def test_mutation_waits_for_same_worker_attachment_final_bytes(self) -> None:
        await self._prove_stream_exclusion(separate_worker=False)

    async def test_separate_worker_gates_share_lock_through_final_bytes(self) -> None:
        # These middleware instances have independent asyncio.Lock objects;
        # passing requires the shared advisory file lock, not local queuing.
        await self._prove_stream_exclusion(separate_worker=True)

    async def test_another_process_holding_store_lock_blocks_mutation(self) -> None:
        context = multiprocessing.get_context("spawn")
        acquired = context.Event()
        release = context.Event()
        process = context.Process(target=_hold_process_lock,
                                  args=(str(self.database), acquired, release))
        attempted = asyncio.Event()
        entered = asyncio.Event()

        async def mutate_app(scope, receive, send):
            entered.set()
            with closing(sqlite3.connect(self.database)) as connection:
                connection.execute("INSERT INTO mutations(value) VALUES('after other worker')")
                connection.commit()
            await Response(status_code=204)(scope, receive, send)

        gate = MaintenanceGate(mutate_app, self.database)

        async def request():
            attempted.set()
            await gate(_scope("/assignments/1"), _receive, _discard)

        pending = None
        process.start()
        try:
            self.assertTrue(await asyncio.to_thread(acquired.wait, 5))
            pending = asyncio.create_task(request())
            await asyncio.wait_for(attempted.wait(), timeout=5)
            await self.assert_not_entered(entered)
            release.set()
            await asyncio.wait_for(pending, timeout=5)
            self.assertEqual(self.mutation_count(), 1)
        finally:
            release.set()
            if pending is not None:
                await asyncio.wait_for(asyncio.gather(pending, return_exceptions=True), timeout=5)
            await asyncio.to_thread(process.join, 5)
            if process.is_alive():
                process.terminate()
                await asyncio.to_thread(process.join, 5)
            exitcode = process.exitcode
            process.close()
        self.assertEqual(exitcode, 0)

    async def test_response_error_releases_gate_for_next_request(self) -> None:
        async def app(scope, receive, send):
            if scope["path"] == "/broken":
                raise RuntimeError("injected response failure")
            with closing(sqlite3.connect(self.database)) as connection:
                connection.execute("INSERT INTO mutations(value) VALUES('after failure')")
                connection.commit()
            await Response(status_code=204)(scope, receive, send)

        gate = MaintenanceGate(app, self.database)
        with self.assertRaisesRegex(RuntimeError, "injected response failure"):
            await gate(_scope("/broken"), _receive, _discard)
        await asyncio.wait_for(gate(_scope("/assignments/1"), _receive, _discard), timeout=5)
        self.assertEqual(self.mutation_count(), 1)


if __name__ == "__main__":
    unittest.main()
