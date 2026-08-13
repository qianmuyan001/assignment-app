from __future__ import annotations

import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from pathlib import Path
from typing import Any

from shared.schema_v3 import validate_v3_schema


_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_REAL_DATABASE = _REPOSITORY_ROOT / "backend" / "assignments.db"
_TEST_DIRECTORY = tempfile.TemporaryDirectory(prefix="assignment-api-tests-")
_TEST_ROOT = Path(_TEST_DIRECTORY.name)
_TEST_DATABASE = _TEST_ROOT / "assignments.db"
os.environ["ASSIGNMENT_DB_PATH"] = str(_TEST_DATABASE)


def _fingerprint(path: Path) -> tuple[int, str] | None:
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, hashlib.sha256(path.read_bytes()).hexdigest())


def _database_family_fingerprints(path: Path) -> dict[str, tuple[int, str]]:
    """Hash every repository database-family byte without SQLite opening it."""
    return {
        candidate.name: fingerprint
        for candidate in sorted(path.parent.glob(f"{path.name}*"))
        if candidate.is_file() and (fingerprint := _fingerprint(candidate)) is not None
    }


def _available_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


class BackendApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server: subprocess.Popen[bytes] | None = None
        cls.server_log = None
        cls.real_database_before = _database_family_fingerprints(_REAL_DATABASE)
        if Path(os.environ["ASSIGNMENT_DB_PATH"]).resolve() == _REAL_DATABASE.resolve():
            raise AssertionError("Backend API tests require a temporary database path")
        # Class cleanups run even when setUpClass fails. Register the database
        # assertion separately so a process-cleanup error cannot skip it.
        cls.addClassCleanup(cls.verify_real_database_unchanged)
        cls.addClassCleanup(cls.cleanup_server)
        cls.port = _available_loopback_port()
        cls.base_url = f"http://127.0.0.1:{cls.port}"
        cls.server_log = (_TEST_ROOT / "uvicorn.log").open("wb")
        environment = os.environ.copy()
        environment["ASSIGNMENT_DB_PATH"] = str(_TEST_DATABASE)
        cls.server = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "backend.app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(cls.port),
                "--log-level",
                "warning",
            ],
            cwd=_REPOSITORY_ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=cls.server_log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                cls.server_log.flush()
                log = (_TEST_ROOT / "uvicorn.log").read_text(
                    encoding="utf-8", errors="replace"
                )
                raise RuntimeError(f"Uvicorn exited during startup:\n{log}")
            try:
                status, payload = cls.request("GET", "/health")
                if status == 200 and "running" in payload["message"]:
                    break
            except (OSError, ValueError, KeyError):
                time.sleep(0.1)
        else:
            raise RuntimeError("Timed out waiting for isolated Uvicorn server")

    @classmethod
    def cleanup_server(cls) -> None:
        if cls.server is not None and cls.server.poll() is None:
            cls.server.terminate()
            try:
                cls.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server.kill()
                cls.server.wait(timeout=5)
        if cls.server_log is not None:
            cls.server_log.close()

    @classmethod
    def verify_real_database_unchanged(cls) -> None:
        real_database_after = _database_family_fingerprints(_REAL_DATABASE)
        if real_database_after != cls.real_database_before:
            raise AssertionError(
                "Backend API tests modified the real assignments.db family: "
                f"before={cls.real_database_before!r}, after={real_database_after!r}"
            )

    @classmethod
    def request(
        cls,
        method: str,
        path: str,
        *,
        json_body: dict[str, Any] | None = None,
        query: dict[str, str] | None = None,
    ) -> tuple[int, Any]:
        url = f"{cls.base_url}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        data = None
        headers: dict[str, str] = {}
        if json_body is not None:
            data = json.dumps(json_body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                body = response.read()
                content_type = response.headers.get("Content-Type", "")
                return response.status, cls.decode(body, content_type)
        except urllib.error.HTTPError as error:
            try:
                body = error.read()
                content_type = error.headers.get("Content-Type", "")
                return error.code, cls.decode(body, content_type)
            finally:
                error.close()

    @staticmethod
    def decode(body: bytes, content_type: str) -> Any:
        if not body:
            return None
        text = body.decode("utf-8")
        return json.loads(text) if "json" in content_type else text

    def setUp(self) -> None:
        status, assignments = self.request("GET", "/assignments")
        self.assertEqual(status, 200)
        for assignment in assignments:
            deleted, _ = self.request(
                "DELETE", f"/assignments/{assignment['id']}"
            )
            self.assertEqual(deleted, 204)

    def test_01_health_and_web_assets_are_served(self) -> None:
        health_status, health = self.request("GET", "/health")
        self.assertEqual(health_status, 200)
        self.assertIn("running", health["message"])

        index_status, index = self.request("GET", "/")
        self.assertEqual(index_status, 200)
        self.assertIn("/static/script.js", index)
        self.assertIn("/static/style.css", index)

        script_status, script = self.request("GET", "/static/script.js")
        style_status, stylesheet = self.request("GET", "/static/style.css")
        self.assertEqual(script_status, 200)
        self.assertIn("fetch(", script)
        self.assertEqual(style_status, 200)
        self.assertIn(":root", stylesheet)

    def test_02_crud_search_and_status_mapping(self) -> None:
        created_status, assignment = self.request(
            "POST",
            "/assignments",
            json_body={
                "course_name": "  物理 Physics  ",
                "title": "  波动实验 🧪  ",
                "due_date": None,
                "description": "保留 café 与 <特殊字符>",
                "status": "todo",
                "priority": "high",
            },
        )
        self.assertEqual(created_status, 201)
        assignment_id = assignment["id"]
        self.assertEqual(assignment["course_name"], "物理 Physics")
        self.assertEqual(assignment["title"], "波动实验 🧪")
        self.assertIsNone(assignment["due_date"])
        self.assertEqual(assignment["status"], "todo")

        updated_status, updated = self.request(
            "PATCH",
            f"/assignments/{assignment_id}",
            json_body={
                "title": "波动实验报告",
                "due_date": "2026-11-01 17:30",
                "priority": "medium",
            },
        )
        self.assertEqual(updated_status, 200)
        self.assertEqual(updated["due_date"], "2026-11-01 17:30")

        search_status, searched = self.request(
            "GET", "/assignments/search", query={"query": "café"}
        )
        self.assertEqual(search_status, 200)
        self.assertEqual([item["id"] for item in searched], [assignment_id])

        completed_status, completed = self.request(
            "PATCH",
            f"/assignments/{assignment_id}/status",
            json_body={"status": "done"},
        )
        self.assertEqual(completed_status, 200)
        self.assertEqual(completed["status"], "done")

        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            stored_status, completed_at, progress = connection.execute(
                "SELECT status, completed_at, progress_percent "
                "FROM assignments WHERE id = ?",
                (assignment_id,),
            ).fetchone()
        self.assertEqual(stored_status, "completed")
        self.assertIsNotNone(completed_at)
        self.assertEqual(progress, 100)

        deleted_status, _ = self.request(
            "DELETE", f"/assignments/{assignment_id}"
        )
        self.assertEqual(deleted_status, 204)
        missing_status, _ = self.request(
            "GET", f"/assignments/{assignment_id}"
        )
        self.assertEqual(missing_status, 404)
        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            deleted_at = connection.execute(
                "SELECT deleted_at FROM assignments WHERE id = ?", (assignment_id,)
            ).fetchone()[0]
        self.assertIsNotNone(deleted_at)

    def test_03_validation_rejects_offsets_and_invalid_enums(self) -> None:
        base = {"course_name": "Math", "title": "Review"}

        offset_status, _ = self.request(
            "POST",
            "/assignments",
            json_body={**base, "due_date": "2026-11-01T17:30:00+08:00"},
        )
        self.assertEqual(offset_status, 422)

        priority_status, _ = self.request(
            "POST",
            "/assignments",
            json_body={**base, "priority": "urgent"},
        )
        self.assertEqual(priority_status, 422)

        blank_status, _ = self.request(
            "POST",
            "/assignments",
            json_body={"course_name": "Math", "title": "   "},
        )
        self.assertEqual(blank_status, 422)

    def test_04_schema_is_v3_and_database_is_disposable(self) -> None:
        self.assertNotEqual(_TEST_DATABASE.resolve(), _REAL_DATABASE.resolve())

        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertEqual(connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
            columns = connection.execute(
                "SELECT name FROM pragma_table_info('assignments') ORDER BY cid"
            ).fetchall()
            identity = connection.execute(
                "SELECT instance_uuid FROM database_identity WHERE singleton = 1"
            ).fetchone()
            validate_v3_schema(connection)
        self.assertEqual(len(columns), 22)
        self.assertIsNotNone(identity)

    def test_05_task_organization_metadata_crud_and_progress(self) -> None:
        course_status, course = self.request(
            "POST",
            "/courses",
            json_body={
                "name": "  高等数学 🧮  ",
                "color_hex": "#3366AA",
                "teacher": "张老师",
                "semester": "2026 秋",
            },
        )
        self.assertEqual(course_status, 201)

        project_status, project = self.request(
            "POST",
            "/projects",
            json_body={
                "course_id": course["id"],
                "name": "期末复习",
                "description": "积分 & 极限",
            },
        )
        self.assertEqual(project_status, 201)

        task_status, task = self.request(
            "POST",
            "/assignments",
            json_body={
                "course_name": "ignored when course_id is present",
                "course_id": course["id"],
                "project_id": project["id"],
                "title": "复习 <特殊字符> 📚",
                "status": "todo",
            },
        )
        self.assertEqual(task_status, 201)
        self.assertEqual(task["course_name"], "高等数学 🧮")
        self.assertEqual(task["course_id"], course["id"])
        self.assertEqual(task["project_id"], project["id"])

        tag_status, tag = self.request(
            "POST", "/tags", json_body={"name": "重点", "color_hex": "#AA3300"}
        )
        self.assertEqual(tag_status, 201)
        link_status, task_tag = self.request(
            "POST", f"/assignments/{task['id']}/tags/{tag['id']}"
        )
        self.assertEqual(link_status, 201)
        self.assertEqual(task_tag["tag_id"], tag["id"])

        first_status, first = self.request(
            "POST",
            f"/assignments/{task['id']}/subtasks",
            json_body={"title": "第一章", "sort_order": 1},
        )
        second_status, _ = self.request(
            "POST",
            f"/assignments/{task['id']}/subtasks",
            json_body={"title": "第二章", "status": "done", "sort_order": 2},
        )
        self.assertEqual((first_status, second_status), (201, 201))
        current_status, current = self.request("GET", f"/assignments/{task['id']}")
        self.assertEqual(current_status, 200)
        self.assertEqual(current["progress_percent"], 50)
        self.assertEqual(current["status"], "in_progress")

        done_status, _ = self.request(
            "PATCH",
            f"/assignments/{task['id']}/subtasks/{first['id']}",
            json_body={"status": "done"},
        )
        self.assertEqual(done_status, 200)
        _, completed_task = self.request("GET", f"/assignments/{task['id']}")
        self.assertEqual(completed_task["progress_percent"], 100)
        self.assertEqual(completed_task["status"], "done")
        self.assertIsNotNone(completed_task["completed_at"])

        attachment_status, attachment = self.request(
            "POST",
            f"/assignments/{task['id']}/attachments",
            json_body={
                "file_name": "复习资料.pdf",
                "mime_type": "application/pdf",
                "byte_size": 42,
                "sha256": "ab" * 32,
            },
        )
        self.assertEqual(attachment_status, 201)
        self.assertEqual(
            attachment["relative_path"], f"attachments/{attachment['uuid']}"
        )

        reminder_status, reminder = self.request(
            "POST",
            f"/assignments/{task['id']}/reminders",
            json_body={
                "trigger_at_utc": "2026-11-01T09:30:00.000Z",
                "lead_minutes": 30,
                "is_enabled": True,
            },
        )
        self.assertEqual(reminder_status, 201)
        self.assertEqual(reminder["lead_minutes"], 30)

        deleted_attachment, _ = self.request(
            "DELETE",
            f"/assignments/{task['id']}/attachments/{attachment['id']}",
        )
        self.assertEqual(deleted_attachment, 204)
        list_status, attachments = self.request(
            "GET", f"/assignments/{task['id']}/attachments"
        )
        self.assertEqual(list_status, 200)
        self.assertEqual(attachments, [])

        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            stored = connection.execute(
                "SELECT relative_path, deleted_at FROM attachments WHERE id = ?",
                (attachment["id"],),
            ).fetchone()
            validate_v3_schema(connection)
        self.assertEqual(stored[0], f"attachments/{attachment['uuid']}")
        self.assertIsNotNone(stored[1])

    def test_06_parent_state_is_derived_from_active_subtasks(self) -> None:
        _, task = self.request(
            "POST",
            "/assignments",
            json_body={"course_name": "State", "title": "Derived state"},
        )
        _, first = self.request(
            "POST",
            f"/assignments/{task['id']}/subtasks",
            json_body={"title": "One", "sort_order": 1},
        )
        _, second = self.request(
            "POST",
            f"/assignments/{task['id']}/subtasks",
            json_body={"title": "Two", "sort_order": 2},
        )

        conflict_status, _ = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"progress_percent": 50},
        )
        pair_conflict_status, _ = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"status": "done", "progress_percent": 50},
        )
        self.assertEqual((conflict_status, pair_conflict_status), (422, 422))

        done_status, done_task = self.request(
            "PATCH",
            f"/assignments/{task['id']}/status",
            json_body={"status": "done"},
        )
        self.assertEqual(done_status, 200)
        self.assertEqual((done_task["status"], done_task["progress_percent"]), ("done", 100))

        progress_status, progress_task = self.request(
            "PATCH",
            f"/assignments/{task['id']}/status",
            json_body={"status": "in_progress"},
        )
        self.assertEqual(progress_status, 200)
        self.assertEqual(
            (progress_task["status"], progress_task["progress_percent"]),
            ("in_progress", 50),
        )

        todo_status, todo_task = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"status": "todo", "progress_percent": 0},
        )
        self.assertEqual(todo_status, 200)
        self.assertEqual((todo_task["status"], todo_task["progress_percent"]), ("todo", 0))

        _, in_progress_task = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"status": "in_progress", "progress_percent": 0},
        )
        self.assertEqual(in_progress_task["status"], "in_progress")
        self.assertEqual(in_progress_task["progress_percent"], 0)

        deleted_status, _ = self.request(
            "DELETE", f"/assignments/{task['id']}/subtasks/{second['id']}"
        )
        self.assertEqual(deleted_status, 204)
        restored_status, restored_subtask = self.request(
            "POST", f"/assignments/{task['id']}/subtasks/{second['id']}/restore"
        )
        self.assertEqual(restored_status, 200)
        self.assertEqual(restored_subtask["uuid"], second["uuid"])
        _, refreshed = self.request("GET", f"/assignments/{task['id']}")
        self.assertEqual((refreshed["status"], refreshed["progress_percent"]), ("in_progress", 0))

        list_status, subtasks = self.request(
            "GET", f"/assignments/{task['id']}/subtasks"
        )
        self.assertEqual(list_status, 200)
        self.assertEqual({item["id"] for item in subtasks}, {first["id"], second["id"]})

    def test_07_restore_endpoints_preserve_uuid_and_reminders_stay_disabled(self) -> None:
        _, course = self.request("POST", "/courses", json_body={"name": "Restore Course"})
        _, project = self.request(
            "POST", "/projects", json_body={"name": "Restore Project"}
        )
        _, tag = self.request("POST", "/tags", json_body={"name": "restore-tag"})
        _, task = self.request(
            "POST",
            "/assignments",
            json_body={
                "course_name": "Restore Course",
                "course_id": course["id"],
                "title": "Restore Task",
            },
        )
        _, reminder = self.request(
            "POST",
            f"/assignments/{task['id']}/reminders",
            json_body={"trigger_at_utc": "2026-12-01T09:00:00.000Z"},
        )

        pending_status, pending = self.request("GET", "/reminders/pending")
        self.assertEqual(pending_status, 200)
        self.assertIn(reminder["id"], {item["id"] for item in pending})

        for path in (
            f"/courses/{course['id']}",
            f"/projects/{project['id']}",
            f"/tags/{tag['id']}",
            f"/assignments/{task['id']}",
        ):
            deleted_status, _ = self.request("DELETE", path)
            self.assertEqual(deleted_status, 204)

        restored_entities = []
        for path in (
            f"/courses/{course['id']}/restore",
            f"/projects/{project['id']}/restore",
            f"/tags/{tag['id']}/restore",
            f"/assignments/{task['id']}/restore",
        ):
            restored_status, restored = self.request("POST", path)
            self.assertEqual(restored_status, 200)
            restored_entities.append(restored)
        self.assertEqual(
            [entity["uuid"] for entity in restored_entities],
            [course["uuid"], project["uuid"], tag["uuid"], task["uuid"]],
        )

        _, pending_after_restore = self.request("GET", "/reminders/pending")
        self.assertNotIn(reminder["id"], {item["id"] for item in pending_after_restore})
        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            enabled = connection.execute(
                "SELECT is_enabled FROM reminders WHERE id = ?", (reminder["id"],)
            ).fetchone()[0]
        self.assertEqual(enabled, 0)

    def test_08_relationship_nulls_project_moves_and_deleted_course_rename(self) -> None:
        _, first_course = self.request("POST", "/courses", json_body={"name": "Course A"})
        _, second_course = self.request("POST", "/courses", json_body={"name": "Course B"})
        _, project = self.request(
            "POST",
            "/projects",
            json_body={"name": "Linked", "course_id": first_course["id"]},
        )
        _, task = self.request(
            "POST",
            "/assignments",
            json_body={
                "course_name": "Course A",
                "course_id": first_course["id"],
                "project_id": project["id"],
                "title": "Linked task",
            },
        )

        null_conflict, _ = self.request(
            "PATCH", f"/assignments/{task['id']}", json_body={"course_id": None}
        )
        self.assertEqual(null_conflict, 422)
        unlink_status, unlinked = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"course_id": None, "project_id": None},
        )
        self.assertEqual(unlink_status, 200)
        self.assertIsNone(unlinked["course_id"])
        self.assertIsNone(unlinked["project_id"])

        _, linked_again = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"course_id": first_course["id"], "project_id": project["id"]},
        )
        self.assertEqual(linked_again["project_id"], project["id"])
        project_move_status, _ = self.request(
            "PATCH",
            f"/projects/{project['id']}",
            json_body={"course_id": second_course["id"]},
        )
        self.assertEqual(project_move_status, 409)

        self.request("DELETE", f"/assignments/{task['id']}")
        rename_status, renamed_course = self.request(
            "PATCH",
            f"/courses/{first_course['id']}",
            json_body={"name": "Course A Renamed"},
        )
        self.assertEqual(rename_status, 200)
        self.assertEqual(renamed_course["name"], "Course A Renamed")
        with closing(sqlite3.connect(_TEST_DATABASE)) as connection:
            stored_name = connection.execute(
                "SELECT course_name FROM assignments WHERE id = ?", (task["id"],)
            ).fetchone()[0]
        self.assertEqual(stored_name, "Course A Renamed")

    def test_09_patch_nulls_timezone_and_rrule_validation(self) -> None:
        _, course = self.request("POST", "/courses", json_body={"name": "Validation Course"})
        _, project = self.request("POST", "/projects", json_body={"name": "Validation Project"})
        _, tag = self.request("POST", "/tags", json_body={"name": "validation-tag"})
        _, task = self.request(
            "POST",
            "/assignments",
            json_body={
                "course_name": "Validation Course",
                "title": "Validation task",
                "timezone_id": "America/Los_Angeles",
            },
        )
        _, subtask = self.request(
            "POST",
            f"/assignments/{task['id']}/subtasks",
            json_body={"title": "Validation subtask"},
        )
        _, reminder = self.request(
            "POST",
            f"/assignments/{task['id']}/reminders",
            json_body={
                "trigger_at_utc": "2026-12-01T09:00:00.000Z",
                "repeat_rule": "freq=weekly;byday=mo,we;interval=2",
            },
        )
        self.assertEqual(reminder["repeat_rule"], "FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2")

        null_cases = (
            (f"/assignments/{task['id']}", {"title": None}),
            (f"/assignments/{task['id']}", {"course_name": None}),
            (f"/assignments/{task['id']}", {"status": None}),
            (f"/assignments/{task['id']}", {"priority": None}),
            (f"/assignments/{task['id']}", {"progress_percent": None}),
            (f"/assignments/{task['id']}", {"all_day": None}),
            (f"/courses/{course['id']}", {"name": None}),
            (f"/courses/{course['id']}", {"is_archived": None}),
            (f"/projects/{project['id']}", {"name": None}),
            (f"/projects/{project['id']}", {"status": None}),
            (f"/tags/{tag['id']}", {"name": None}),
            (f"/assignments/{task['id']}/subtasks/{subtask['id']}", {"title": None}),
            (f"/assignments/{task['id']}/subtasks/{subtask['id']}", {"status": None}),
            (f"/assignments/{task['id']}/subtasks/{subtask['id']}", {"sort_order": None}),
            (f"/assignments/{task['id']}/reminders/{reminder['id']}", {"trigger_at_utc": None}),
            (f"/assignments/{task['id']}/reminders/{reminder['id']}", {"lead_minutes": None}),
            (f"/assignments/{task['id']}/reminders/{reminder['id']}", {"is_enabled": None}),
        )
        for path, body in null_cases:
            patch_status, _ = self.request("PATCH", path, json_body=body)
            self.assertEqual(patch_status, 422, (path, body))

        invalid_timezone_status, _ = self.request(
            "PATCH",
            f"/assignments/{task['id']}",
            json_body={"timezone_id": "Mars/Olympus"},
        )
        self.assertEqual(invalid_timezone_status, 422)

        invalid_rules = (
            "FREQ=DAILY\nCOUNT=2",
            "DTSTART=20260101T000000Z;FREQ=DAILY",
            "FREQ=DAILY;UNKNOWN=1",
            "FREQ=DAILY;COUNT=2;UNTIL=20261201",
            "FREQ=MONTHLY;UNTIL=20261340",
            "FREQ=WEEKLY;BYDAY=MO,XX",
            "FREQ=DAILY;COUNT=٢",
            "FREQ=YEARLY;BYMONTH=１",
            "FREQ=MONTHLY;BYMONTHDAY=+1",
        )
        for rule in invalid_rules:
            rule_status, _ = self.request(
                "POST",
                f"/assignments/{task['id']}/reminders",
                json_body={
                    "trigger_at_utc": "2026-12-02T09:00:00.000Z",
                    "repeat_rule": rule,
                },
            )
            self.assertEqual(rule_status, 422, rule)


def tearDownModule() -> None:  # noqa: N802 - unittest lifecycle name
    _TEST_DIRECTORY.cleanup()


if __name__ == "__main__":
    unittest.main()
