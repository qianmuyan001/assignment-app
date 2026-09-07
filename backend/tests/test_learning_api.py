"""HTTP and transactional learning-scene checks; every database is temporary."""
from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timezone
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session

from backend.app import models
from backend.app.database import get_db
from backend.app.routers import learning
from shared.schema_v3 import create_v3_schema
from shared.schema_v4 import migrate_v3_to_v4, validate_v4_schema


def _cases(parameter, values):
    """Expand validation cases as separately isolated unittest test methods."""
    def decorate(check):
        check.case_values = [{parameter: value} for value in values]
        return check
    return decorate


def _open_scene_api(test_case):
    directory = tempfile.TemporaryDirectory(prefix="assignment-learning-api-")
    test_case.addCleanup(directory.cleanup)
    path = Path(directory.name) / "learning-v4.db"
    with closing(sqlite3.connect(path)) as connection:
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("BEGIN IMMEDIATE")
        create_v3_schema(connection)
        migrate_v3_to_v4(connection)
        connection.commit()
        validate_v4_schema(connection)
    engine = create_engine(f"sqlite:///{path}", connect_args={"check_same_thread": False})

    @event.listens_for(engine, "connect")
    def configure(connection, _record):
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=10000")

    with Session(engine) as session:
        courses = [models.Course(name=name, normalized_name=name.lower()) for name in ("Mathematics", "Physics")]
        session.add_all(courses)
        session.commit()
        course_ids = [course.id for course in courses]
    app = FastAPI()
    app.include_router(learning.router)

    def isolated_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = isolated_db
    test_case.enterContext(patch.object(learning, "_now", return_value=datetime(2026, 9, 7, 4, tzinfo=timezone.utc)))
    test_case.addCleanup(engine.dispose)
    client = test_case.enterContext(TestClient(app))
    return client, engine, course_ids


def meeting_payload(course_id, /, **changes):
    return {
        "course_id": course_id, "weekday": 1,
        "start_time_local": "09:00:00", "end_time_local": "10:30:00",
        "timezone_id": "Asia/Shanghai", "effective_start_date": "2026-09-01",
        "effective_end_date": "2026-12-31", "location": "A101",
        "teacher_override": "王老师", **changes,
    }


def exam_payload(course_id, /, **changes):
    return {
        "course_id": course_id, "name": "期中考 Midterm",
        "starts_at_local": "2026-09-10 09:00:00", "timezone_id": "Asia/Shanghai",
        "location": "B201", "scope": "Chapters 1–4", "notes": "Bring a calculator", **changes,
    }


def create(client, path, payload):
    response = client.post(path, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def add_task(engine, course_id, title, due, **values):
    with Session(engine) as session:
        task = models.Assignment(course_id=course_id, course_name="Mathematics", title=title,
                                 due_date=datetime.fromisoformat(due) if due else None, **values)
        session.add(task)
        session.commit()
        return task.id


def _check_meeting_crud_restore_and_uuid(scene_api):
    client, engine, courses = scene_api
    meeting = create(client, "/course-meetings", meeting_payload(courses[0]))
    assert UUID(meeting["uuid"]).version == 4
    assert meeting["course_name"] == "Mathematics"
    assert meeting["warnings"] == []
    assert meeting["teacher_override"] == "王老师"
    path = f"/course-meetings/{meeting['id']}"
    assert client.get(path).json()["uuid"] == meeting["uuid"]
    changed = client.patch(path, json={"course_id": courses[1], "location": None, "end_time_local": "11:00:00"}).json()
    assert changed["course_name"] == "Physics"
    assert changed["location"] is None
    assert changed["teacher_override"] == "王老师"
    assert changed["uuid"] == meeting["uuid"]
    assert client.delete(path).status_code == 204
    assert client.get(path).status_code == 404
    assert client.get("/course-meetings").json() == []
    assert client.get("/course-meetings?include_deleted=true").json()[0]["deleted_at"]
    restored = client.post(path + "/restore").json()
    assert restored["deleted_at"] is None
    assert restored["id"] == meeting["id"]
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM course_meetings")).scalar() == 1


def _check_meeting_filters_dates_and_current_week(scene_api):
    client, _, courses = scene_api
    active = create(client, "/course-meetings", meeting_payload(courses[0]))
    create(client, "/course-meetings", meeting_payload(courses[1], effective_start_date="2027-01-01", effective_end_date=None))
    create(client, "/course-meetings", meeting_payload(courses[1], weekday=2))
    for query in ("current_week=true&weekday=1", "week_start=2026-09-09&weekday=1", "on_date=2026-09-07", f"course_id={courses[0]}"):
        response = client.get("/course-meetings?" + query)
        assert [row["id"] for row in response.json()] == [active["id"]]
    occurrence = client.get("/course-meetings?on_date=2026-09-07").json()[0]["occurrences"][0]
    assert occurrence == {"date": "2026-09-07", "starts_at_utc": "2026-09-07T01:00:00Z", "ends_at_utc": "2026-09-07T02:30:00Z"}
    assert client.get("/course-meetings?on_date=2026-08-31").json() == []


def _check_overlap_is_warning_not_rejection_and_checks_other_courses(scene_api):
    client, engine, courses = scene_api
    first = create(client, "/course-meetings", meeting_payload(courses[0]))
    second = create(client, "/course-meetings", meeting_payload(courses[1], start_time_local="10:00:00", end_time_local="11:00:00"))
    assert second["warnings"][0]["code"] == "overlap"
    assert second["warnings"][0]["related_id"] == first["id"]
    filtered = client.get(f"/course-meetings?course_id={courses[0]}").json()
    assert filtered[0]["warnings"][0]["related_id"] == second["id"]
    assert client.patch(f"/course-meetings/{second['id']}", json={"start_time_local": "10:30:00"}).json()["warnings"] == []
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM course_meetings WHERE deleted_at IS NULL")).scalar() == 2


def _check_overlap_resolves_timezones_and_effective_windows(scene_api):
    client, _, courses = scene_api
    create(client, "/course-meetings", meeting_payload(courses[0]))
    different_zone = create(client, "/course-meetings", meeting_payload(courses[1], timezone_id="UTC"))
    assert different_zone["warnings"] == []
    expired = create(client, "/course-meetings", meeting_payload(courses[1], effective_start_date="2026-01-01", effective_end_date="2026-01-31"))
    assert expired["warnings"] == []


@_cases("changes", [
    {"weekday": 0}, {"weekday": 8}, {"weekday": True}, {"course_id": -1},
    {"start_time_local": "9:00"}, {"start_time_local": "24:00:00"},
    {"end_time_local": "09:00:00"}, {"end_time_local": "08:00:00"},
    {"timezone_id": "Mars/Olympus"}, {"timezone_id": "GMT+08:00"},
    {"effective_start_date": "2026-02-30"}, {"effective_end_date": "2026-01-01"},
    {"sort_order": -1}, {"uuid": "replacement"},
])
def _check_meeting_invalid_create_is_atomic(scene_api, changes):
    client, engine, courses = scene_api
    response = client.post("/course-meetings", json=meeting_payload(courses[0], **changes))
    assert response.status_code == 422
    assert response.json()["detail"]
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM course_meetings")).scalar() == 0


@_cases("changes", [
    {"start_time_local": "11:00:00"}, {"effective_start_date": None},
    {"course_id": None}, {"weekday": None}, {"timezone_id": None},
    {"uuid": "other"},
])
def _check_meeting_partial_invalid_edit_preserves_record(scene_api, changes):
    client, _, courses = scene_api
    meeting = create(client, "/course-meetings", meeting_payload(courses[0]))
    path = f"/course-meetings/{meeting['id']}"
    assert client.patch(path, json=changes).status_code == 422
    assert client.get(path).json() == meeting


def _check_meeting_dst_gap_warning_and_first_fold(scene_api):
    client, _, courses = scene_api
    spring = create(client, "/course-meetings", meeting_payload(courses[0], weekday=7, start_time_local="02:10:00", end_time_local="02:50:00", timezone_id="America/New_York", effective_start_date="2026-03-01", effective_end_date="2026-03-31"))
    result = client.get("/course-meetings?on_date=2026-03-08").json()[0]
    assert result["id"] == spring["id"]
    assert result["occurrences"][0]["starts_at_utc"] is None
    assert any(w["code"] == "nonexistent_local_time" for w in result["warnings"])
    autumn = create(client, "/course-meetings", meeting_payload(courses[0], weekday=7, start_time_local="01:10:00", end_time_local="02:10:00", timezone_id="America/New_York", effective_start_date="2026-11-01"))
    result = client.get("/course-meetings?on_date=2026-11-01").json()[0]
    assert result["id"] == autumn["id"]
    assert result["occurrences"][0]["starts_at_utc"] == "2026-11-01T05:10:00Z"
    assert result["occurrences"][0]["ends_at_utc"] == "2026-11-01T07:10:00Z"


def _check_exam_crud_status_order_and_restore(scene_api):
    client, _, courses = scene_api
    first = create(client, "/exams", exam_payload(courses[0]))
    assert UUID(first["uuid"]).version == 4
    second = create(client, "/exams", exam_payload(courses[1], starts_at_local="2026-09-10 02:00:00", timezone_id="UTC"))
    done = create(client, "/exams", exam_payload(courses[0], status="completed", starts_at_local="2026-09-01 00:00:00"))
    cancelled = create(client, "/exams", exam_payload(courses[0], status="cancelled"))
    assert [row["id"] for row in client.get("/exams").json()] == [first["id"], second["id"], done["id"], cancelled["id"]]
    assert [row["id"] for row in client.get(f"/exams?course_id={courses[1]}&status=upcoming").json()] == [second["id"]]
    path = f"/exams/{first['id']}"
    updated = client.patch(path, json={"status": "completed", "course_id": courses[1], "notes": None}).json()
    assert updated["course_name"] == "Physics"
    assert updated["status"] == "completed"
    assert updated["scope"] == first["scope"]
    assert updated["notes"] is None
    assert updated["uuid"] == first["uuid"]
    assert client.delete(path).status_code == 204
    assert client.get(path).status_code == 404
    assert client.get(path + "?include_deleted=true").json()["deleted_at"]
    assert client.post(path + "/restore").json()["deleted_at"] is None


@_cases("changes", [
    {"name": "   "}, {"course_id": 0}, {"starts_at_local": "2026-02-30 12:00:00"},
    {"starts_at_local": "2026-09-10T09:00:00"}, {"starts_at_local": "2026-09-10 09:00:00+08:00"},
    {"timezone_id": "invalid"}, {"status": "done"}, {"linked_assignment_id": 123},
])
def _check_exam_invalid_create_or_edit_preserves_data(scene_api, changes):
    client, _, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0]))
    path = f"/exams/{exam['id']}"
    assert client.post("/exams", json=exam_payload(courses[0], **changes)).status_code == 422
    assert client.patch(path, json=changes).status_code == 422
    assert client.get(path).json() == exam


def _check_review_task_idempotent_and_survives_exam_delete(scene_api):
    client, engine, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0]))
    path = f"/exams/{exam['id']}/review-task"
    first = client.post(path).json()
    second = client.post(path).json()
    assert first["created"] is True and second["created"] is False
    assert first["assignment"]["id"] == second["assignment"]["id"]
    task = first["assignment"]
    assert task["title"] == "Review: 期中考 Midterm"
    assert task["status"] == "todo" and task["priority"] == "high"
    assert task["course_id"] == courses[0] and task["timezone_id"] == "Asia/Shanghai"
    assert task["due_date"] == "2026-09-09 09:00"
    assert first["exam"]["linked_assignment_id"] == task["id"]
    assert client.delete(f"/exams/{exam['id']}").status_code == 204
    with Session(engine) as session:
        assert session.get(models.Assignment, task["id"]).deleted_at is None
    assert client.post(f"/exams/{exam['id']}/restore").json()["linked_assignment_id"] == task["id"]


def _check_review_task_repeat_returns_soft_deleted_task(scene_api):
    client, engine, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0]))
    path = f"/exams/{exam['id']}/review-task"
    first = client.post(path).json()["assignment"]
    with engine.begin() as connection:
        connection.execute(text("UPDATE assignments SET deleted_at='2026-09-07T00:00:00.000Z' WHERE id=:id"), {"id": first["id"]})
    repeated = client.post(path).json()
    assert repeated["created"] is False
    assert repeated["assignment"]["id"] == first["id"]
    assert repeated["assignment"]["deleted_at"]


def _check_review_task_concurrent_requests_create_one_row(scene_api):
    client, engine, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0]))
    with ThreadPoolExecutor(max_workers=6) as executor:
        responses = list(executor.map(lambda _: client.post(f"/exams/{exam['id']}/review-task"), range(6)))
    assert all(response.status_code == 200 for response in responses)
    bodies = [response.json() for response in responses]
    assert sum(body["created"] for body in bodies) == 1
    assert len({body["assignment"]["uuid"] for body in bodies}) == 1
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM assignments")).scalar() == 1


def _check_review_task_insert_and_link_roll_back_together(scene_api):
    client, engine, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0]))
    with engine.begin() as connection:
        connection.execute(text("CREATE TRIGGER reject_review_link BEFORE UPDATE OF linked_assignment_id ON exams BEGIN SELECT RAISE(ABORT, 'injected link failure'); END"))
    response = client.post(f"/exams/{exam['id']}/review-task")
    assert response.status_code == 409
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM assignments")).scalar() == 0
        assert connection.execute(text("SELECT linked_assignment_id FROM exams")).scalar() is None


def _check_review_deadline_subtracts_elapsed_day_across_dst(scene_api):
    client, _, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-03-08 10:00:00", timezone_id="America/New_York"))
    task = client.post(f"/exams/{exam['id']}/review-task").json()["assignment"]
    assert task["due_date"] == "2026-03-07 09:00"


def _check_nonexistent_exam_time_visible_and_review_rejected(scene_api):
    client, engine, courses = scene_api
    exam = create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-03-08 02:30:00", timezone_id="America/New_York"))
    assert exam["starts_at_utc"] is None
    assert exam["warnings"][0]["code"] == "nonexistent_local_time"
    assert client.post(f"/exams/{exam['id']}/review-task").status_code == 422
    with engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM assignments")).scalar() == 0


def _check_today_overview_uses_instants_and_active_data(scene_api):
    client, engine, courses = scene_api
    # Now is 2026-09-07 12:00 Shanghai. New York Sunday evening is Monday here.
    due = add_task(engine, courses[0], "Today", "2026-09-07 18:00:00", timezone_id="Asia/Shanghai")
    early = add_task(engine, courses[0], "Earlier today", "2026-09-07 09:00:00", timezone_id="Asia/Shanghai")
    overdue = add_task(engine, courses[0], "Past", "2026-09-06 18:00:00", timezone_id="Asia/Shanghai")
    cross_zone = add_task(engine, courses[0], "Cross-zone today", "2026-09-06 21:00:00", timezone_id="America/New_York")
    done = add_task(engine, courses[0], "Completed today", "2026-09-07 08:00:00", timezone_id="Asia/Shanghai", status="done", progress_percent=100, completed_at="2026-09-07T01:00:00.000Z")
    add_task(engine, courses[0], "No date", None)
    add_task(engine, courses[0], "Deleted", "2026-09-05 10:00:00", deleted_at="2026-09-07T00:00:00.000Z")
    meeting = create(client, "/course-meetings", meeting_payload(courses[0]))
    create(client, "/course-meetings", meeting_payload(courses[1], effective_start_date="2027-01-01", effective_end_date=None))
    exam = create(client, "/exams", exam_payload(courses[0]))
    create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-10-01 09:00:00"))
    create(client, "/exams", exam_payload(courses[0], status="cancelled"))
    overview = client.get("/overview/today?timezone_id=Asia/Shanghai").json()
    assert overview["date"] == "2026-09-07"
    assert {task["id"] for task in overview["due_today"]} == {due, early, cross_zone, done}
    assert {task["id"] for task in overview["overdue"]} == {early, overdue, cross_zone}
    assert [row["id"] for row in overview["meetings"]] == [meeting["id"]]
    assert [row["id"] for row in overview["upcoming_exams"]] == [exam["id"]]
    assert next(task for task in overview["due_today"] if task["id"] == cross_zone)["due_at_utc"] == "2026-09-07T01:00:00Z"


def _check_today_horizon_inclusive_and_day_end_exclusive(scene_api):
    client, engine, courses = scene_api
    at_start = create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-09-07 00:00:00"))
    at_horizon = create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-09-21 00:00:00"))
    create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-09-21 00:00:01"))
    create(client, "/exams", exam_payload(courses[0], starts_at_local="2026-09-06 23:59:59"))
    included = add_task(engine, courses[0], "Start", "2026-09-07 00:00:00", timezone_id="Asia/Shanghai")
    add_task(engine, courses[0], "End", "2026-09-08 00:00:00", timezone_id="Asia/Shanghai")
    result = client.get("/overview/today?timezone_id=Asia/Shanghai").json()
    assert [exam["id"] for exam in result["upcoming_exams"]] == [at_start["id"], at_horizon["id"]]
    assert [task["id"] for task in result["due_today"]] == [included]


def _check_today_meeting_resolves_viewer_date_across_timezones(scene_api):
    client, _, courses = scene_api
    meeting = create(client, "/course-meetings", meeting_payload(courses[0], weekday=7, start_time_local="21:00:00", end_time_local="22:00:00", timezone_id="America/New_York"))
    overview = client.get("/overview/today?timezone_id=Asia/Shanghai").json()
    assert [row["id"] for row in overview["meetings"]] == [meeting["id"]]
    assert overview["meetings"][0]["occurrences"][0]["date"] == "2026-09-06"


def _check_scene_update_preserves_extension_columns(scene_api):
    client, engine, courses = scene_api
    meeting = create(client, "/course-meetings", meeting_payload(courses[0]))
    exam = create(client, "/exams", exam_payload(courses[0]))
    with engine.begin() as connection:
        for table in ("course_meetings", "exams"):
            connection.execute(text(f"ALTER TABLE {table} ADD COLUMN future_extension TEXT DEFAULT '保留 Keep'"))
    assert client.patch(f"/course-meetings/{meeting['id']}", json={"location": "Changed"}).status_code == 200
    assert client.patch(f"/exams/{exam['id']}", json={"status": "completed"}).status_code == 200
    with engine.connect() as connection:
        for table in ("course_meetings", "exams"):
            assert connection.execute(text(f"SELECT future_extension FROM {table}")).scalar() == "保留 Keep"


@_cases("path", [
    "/course-meetings/999", "/exams/999", "/course-meetings?weekday=8",
    "/course-meetings?on_date=2026-02-30", "/course-meetings?timezone_id=invalid",
    "/course-meetings?on_date=2026-09-07&current_week=true", "/exams?status=bad",
    "/overview/today?timezone_id=invalid", "/overview/today?on_date=2026-02-30",
])
def _check_stable_missing_or_invalid_query_error(scene_api, path):
    client, _, _ = scene_api
    response = client.get(path)
    assert response.status_code in (404, 422)
    assert response.json()["detail"]


def _check_unknown_course_rejected_and_deleted_course_restore_blocked(scene_api):
    client, engine, courses = scene_api
    assert client.post("/course-meetings", json=meeting_payload(999)).status_code == 404
    assert client.post("/exams", json=exam_payload(999)).status_code == 404
    meeting = create(client, "/course-meetings", meeting_payload(courses[0]))
    exam = create(client, "/exams", exam_payload(courses[0]))
    client.delete(f"/course-meetings/{meeting['id']}")
    client.delete(f"/exams/{exam['id']}")
    with engine.begin() as connection:
        connection.execute(text("UPDATE courses SET deleted_at='2026-09-07T00:00:00.000Z' WHERE id=:id"), {"id": courses[0]})
    assert client.post(f"/course-meetings/{meeting['id']}/restore").status_code == 404
    assert client.post(f"/exams/{exam['id']}/restore").status_code == 404
    assert client.get(f"/course-meetings/{meeting['id']}?include_deleted=true").json()["deleted_at"]
    assert client.get(f"/exams/{exam['id']}?include_deleted=true").json()["deleted_at"]


def _check_timetable_today_matches_overview_across_weekday_boundary(scene_api):
    client, _, courses = scene_api
    sunday = create(client, "/course-meetings", meeting_payload(courses[0], weekday=7,
        start_time_local="21:00:00", end_time_local="22:00:00", timezone_id="America/New_York"))
    monday = create(client, "/course-meetings", meeting_payload(courses[0], weekday=1,
        start_time_local="21:00:00", end_time_local="22:00:00", timezone_id="America/New_York"))
    timetable = client.get("/course-meetings?on_date=2026-09-07&timezone_id=Asia/Shanghai").json()
    overview = client.get("/overview/today?timezone_id=Asia/Shanghai").json()
    assert [row["id"] for row in timetable] == [sunday["id"]]
    assert timetable == overview["meetings"]
    assert timetable[0]["occurrences"][0]["date"] == "2026-09-06"
    week = client.get("/course-meetings?week_start=2026-09-07&timezone_id=Asia/Shanghai").json()
    assert [row["id"] for row in week] == [monday["id"], sunday["id"]]
    assert next(row for row in week if row["id"] == sunday["id"])["occurrences"][0]["date"] == "2026-09-13"


def _check_null_task_timezone_instant_is_independent_of_viewer_zone(scene_api):
    client, engine, courses = scene_api
    task_id = add_task(engine, courses[0], "Legacy unzoned task", "2026-09-07 18:00:00")
    expected = datetime(2026, 9, 7, 18).astimezone(timezone.utc)
    results = []
    for viewer_zone in ("Asia/Shanghai", "Pacific/Honolulu"):
        viewer_day = expected.astimezone(ZoneInfo(viewer_zone)).date().isoformat()
        overview = client.get("/overview/today", params={"timezone_id": viewer_zone, "on_date": viewer_day}).json()
        task = next(item for item in overview["due_today"] if item["id"] == task_id)
        results.append(task["due_at_utc"])
    assert results[0] == results[1] == expected.isoformat(timespec="seconds").replace("+00:00", "Z")


class LearningApiTests(unittest.TestCase):
    def setUp(self):
        self.scene_api = _open_scene_api(self)


def _test_method(check, arguments):
    def run(self):
        check(self.scene_api, **arguments)
    run.__doc__ = f"{check.__name__}: {arguments}"
    return run


# unittest has no built-in parameterization; generated methods retain one fresh
# database per validation case and are discovered by the repository's CI runner.
for _name, _check in list(globals().items()):
    if _name.startswith("_check_") and callable(_check):
        _variants = getattr(_check, "case_values", [{}])
        for _index, _arguments in enumerate(_variants):
            _suffix = f"_{_index:02d}" if len(_variants) > 1 else ""
            setattr(LearningApiTests, _name.replace("_check_", "test_", 1) + _suffix, _test_method(_check, _arguments))


if __name__ == "__main__":
    unittest.main()
