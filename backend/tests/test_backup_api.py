"""Exercise the backup HTTP workflow against a disposable database."""

from contextlib import closing
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from shared.schema_v3 import create_v3_schema
from shared.schema_v4 import migrate_v3_to_v4
from backend.app.routers import backups
from backend.app.services.backup_store import BackupError, BackupStore


class BackupApiTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="assignment-backup-api-tests-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "store.sqlite3"
        with closing(sqlite3.connect(self.path)) as connection:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            create_v3_schema(connection)
            migrate_v3_to_v4(connection)
            connection.execute("INSERT INTO assignments(uuid,course_name,title,created_at,updated_at) "
                               "VALUES(?,'课程','Keep this task','2026-09-07T00:00:00.000Z','2026-09-07T00:00:00.000Z')",
                               (str(uuid4()),))
            connection.commit()
        self.store = BackupStore(self.path)
        replacement = patch.object(backups, "store", self.store)
        replacement.start()
        self.addCleanup(replacement.stop)
        app = FastAPI()
        app.include_router(backups.router)

        @app.exception_handler(BackupError)
        async def backup_error(_request: Request, exc: BackupError):
            return JSONResponse({"detail": str(exc)}, status_code=422)

        self.client = TestClient(app)
        self.addCleanup(self.client.close)

    def preflight(self):
        created = self.client.post("/backups")
        self.assertEqual(created.status_code, 201, created.text)
        item = created.json()
        self.assertEqual(self.client.get("/backups").json()[0]["id"], item["id"])
        download = self.client.get(f"/backups/{item['id']}/download")
        self.assertIn("application/zip", download.headers["content-type"])
        self.assertIn(item["id"], download.headers["content-disposition"])
        inspected = self.client.post("/backups/preflight", content=download.content,
                                     headers={"Content-Type": "application/zip"})
        self.assertEqual(inspected.status_code, 200, inspected.text)
        self.assertEqual(inspected.json()["summary"]["counts"]["assignments"], 1)
        return inspected.json()

    def test_http_backup_preflight_confirm_and_restore_roundtrip(self):
        preview = self.preflight()
        with closing(sqlite3.connect(self.path)) as connection:
            connection.execute("UPDATE assignments SET title='After backup'")
            connection.commit()
        response = self.client.post("/backups/restore", json={"token": preview["token"], "confirm": True})
        self.assertEqual(response.json(), {"restored": True, "schema_version": 4})
        with closing(sqlite3.connect(self.path)) as connection:
            self.assertEqual(connection.execute("SELECT title FROM assignments").fetchone()[0], "Keep this task")

    def test_restore_requires_explicit_boolean_confirmation(self):
        preview = self.preflight()
        for body, expected in (({"token": preview["token"], "confirm": False}, 409),
                               ({"token": preview["token"]}, 422),
                               ({"token": preview["token"], "confirm": "true"}, 422)):
            with self.subTest(body=body):
                response = self.client.post("/backups/restore", json=body)
                self.assertEqual(response.status_code, expected)
                self.assertIn("detail", response.json())
        self.assertTrue((self.store.root / f"preflight-{preview['token']}").exists())

    def test_corrupt_upload_rejected_and_store_preserved(self):
        response = self.client.post("/backups/preflight", content=b"broken archive",
                                    headers={"Content-Type": "application/zip"})
        self.assertEqual(response.status_code, 422)
        self.assertIn("validation", response.json()["detail"].lower())
        with closing(sqlite3.connect(self.path)) as connection:
            self.assertEqual(connection.execute("SELECT title FROM assignments").fetchone()[0], "Keep this task")

    def test_unsupported_upload_type_and_unknown_backup_rejected(self):
        response = self.client.post("/backups/preflight", json={"fake": "backup"})
        self.assertEqual(response.status_code, 415)
        response = self.client.get(f"/backups/{uuid4()}/download")
        self.assertEqual(response.status_code, 422)
        self.assertIn("not found", response.json()["detail"])


if __name__ == "__main__":
    unittest.main()
