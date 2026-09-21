"""HTTP contract tests for v4 reminders against temporary SQLite databases."""
from __future__ import annotations

import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

_IMPORT_ROOT = tempfile.TemporaryDirectory(prefix='assignment-reminder-import-')
os.environ['ASSIGNMENT_DB_PATH'] = str(Path(_IMPORT_ROOT.name) / 'unused.db')

from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine, event  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from backend.app.database import get_db, migrate_database  # noqa: E402
from backend.app.routers import assignments, organization  # noqa: E402


class ReminderV4ApiTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix='assignment-reminder-api-')
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / 'case.db'
        migrate_database(self.path)
        engine = create_engine(f'sqlite:///{self.path}', connect_args={'check_same_thread': False})
        self.addCleanup(engine.dispose)
        @event.listens_for(engine, 'connect')
        def configure(connection, _record):
            connection.execute('PRAGMA foreign_keys=ON')
        sessions = sessionmaker(bind=engine, autoflush=False)
        def isolated_db():
            with sessions() as session:
                yield session
        app = FastAPI()
        app.include_router(assignments.router)
        app.include_router(organization.router)
        app.dependency_overrides[get_db] = isolated_db
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.task = self.create_task()

    def create_task(self, **values):
        body = {
            'course_name': '物理 Physics', 'title': '复习 Review',
            'due_date': '2026-09-08 10:00:00', 'timezone_id': 'Asia/Shanghai',
            'description': 'Preserve hidden details', 'priority': 'high',
            'link': 'https://example.test/book',
        }
        body.update(values)
        response = self.client.post('/assignments', json=body)
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def reminder_path(self, reminder=None, task=None):
        path = f"/assignments/{(task or self.task)['id']}/reminders"
        return path if reminder is None else f"{path}/{reminder['id']}"

    def create_reminder(self, **values):
        response = self.client.post(self.reminder_path(), json=values)
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def patch_task(self, **values):
        response = self.client.patch(f"/assignments/{self.task['id']}", json=values)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def stored(self, reminder):
        response = self.client.get(self.reminder_path())
        self.assertEqual(response.status_code, 200, response.text)
        return next(row for row in response.json() if row['id'] == reminder['id'])

    def pending_ids(self):
        response = self.client.get('/reminders/pending')
        self.assertEqual(response.status_code, 200, response.text)
        return {row['id'] for row in response.json()}

    def test_existing_fixed_payload_keeps_authoritative_trigger(self):
        reminder = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z', lead_minutes=75)
        self.assertEqual(reminder['schedule_kind'], 'fixed')
        self.patch_task(due_date='2026-09-09 19:00:00', timezone_id='America/New_York')
        stored = self.stored(reminder)
        self.assertEqual(stored['trigger_at_utc'], '2026-09-08T00:00:00Z')
        self.assertEqual(stored['lead_minutes'], 75)
        self.assertIsNone(stored['disabled_reason'])

    def test_relative_creation_uses_due_and_lead_not_client_trigger(self):
        reminder = self.create_reminder(
            schedule_kind='due_relative', lead_minutes=90,
            trigger_at_utc='2000-01-01T00:00:00Z',
        )
        self.assertEqual(reminder['trigger_at_utc'], '2026-09-08T00:30:00.000Z')
        self.assertEqual(reminder['schedule_kind'], 'due_relative')
        self.assertIn(reminder['id'], self.pending_ids())

    def test_due_and_timezone_changes_move_relative_and_preserve_fixed(self):
        relative = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        fixed = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z')
        self.client.patch(self.reminder_path(relative), json={'last_scheduled_at': '2026-09-01T00:00:00Z'})
        self.patch_task(due_date='2026-09-09 11:00:00')
        self.assertEqual(self.stored(relative)['trigger_at_utc'], '2026-09-09T02:30:00.000Z')
        self.patch_task(timezone_id='America/New_York')
        stored = self.stored(relative)
        self.assertEqual(stored['trigger_at_utc'], '2026-09-09T14:30:00.000Z')
        self.assertIsNone(stored['last_scheduled_at'])
        self.assertEqual(self.stored(fixed)['trigger_at_utc'], fixed['trigger_at_utc'])

    def test_missing_deadline_rejects_create_with_reason_and_no_insert(self):
        self.patch_task(due_date=None)
        for enabled in (True, False):
            response = self.client.post(self.reminder_path(), json={
                'schedule_kind': 'due_relative', 'lead_minutes': 10, 'is_enabled': enabled,
            })
            self.assertEqual(response.status_code, 422)
            self.assertIn('require a due date', response.json()['detail'])
        self.assertEqual(self.client.get(self.reminder_path()).json(), [])

    def test_removing_deadline_disables_relative_and_explicit_enable_is_rejected(self):
        relative = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        fixed = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z')
        self.patch_task(due_date=None)
        stored = self.stored(relative)
        self.assertFalse(stored['is_enabled'])
        self.assertEqual(stored['disabled_reason'], 'missing_due_date')
        self.assertEqual(stored['trigger_at_utc'], relative['trigger_at_utc'])
        response = self.client.patch(self.reminder_path(relative), json={'is_enabled': True})
        self.assertEqual(response.status_code, 422)
        self.assertIn('require a due date', response.json()['detail'])
        self.assertFalse(self.stored(relative)['is_enabled'])
        self.assertEqual(self.pending_ids(), {fixed['id']})
        response = self.client.patch(self.reminder_path(relative), json={'is_enabled': False})
        self.assertEqual(response.status_code, 200, response.text)

    def test_restoring_deadline_refreshes_cache_without_enabling_user_preference(self):
        relative = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        self.patch_task(due_date=None)
        self.patch_task(due_date='2026-09-10 11:00:00')
        stored = self.stored(relative)
        self.assertFalse(stored['is_enabled'])
        self.assertEqual(stored['disabled_reason'], 'disabled_by_user')
        self.assertEqual(stored['trigger_at_utc'], '2026-09-10T02:30:00.000Z')
        response = self.client.patch(self.reminder_path(relative), json={'is_enabled': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn(relative['id'], self.pending_ids())

    def test_completed_task_cancels_pending_without_deleting_record(self):
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=15)
        response = self.client.patch(f"/assignments/{self.task['id']}/status", json={'status': 'completed'})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['status'], 'done')
        self.assertNotIn(reminder['id'], self.pending_ids())
        self.assertEqual(self.stored(reminder)['disabled_reason'], 'task_completed')
        self.patch_task(status='todo')
        self.assertIn(reminder['id'], self.pending_ids())

    def test_subtask_completion_also_cancels_pending(self):
        reminder = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z')
        response = self.client.post(f"/assignments/{self.task['id']}/subtasks", json={'title': '完成准备'})
        self.assertEqual(response.status_code, 201, response.text)
        child = response.json()
        response = self.client.patch(f"/assignments/{self.task['id']}/subtasks/{child['id']}", json={'status': 'done'})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertNotIn(reminder['id'], self.pending_ids())
        self.assertEqual(self.stored(reminder)['disabled_reason'], 'task_completed')

    def test_deleting_and_restoring_task_keeps_reminder_disabled_and_identity(self):
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=15)
        response = self.client.delete(f"/assignments/{self.task['id']}")
        self.assertEqual(response.status_code, 204)
        self.assertNotIn(reminder['id'], self.pending_ids())
        response = self.client.post(f"/assignments/{self.task['id']}/restore")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['uuid'], self.task['uuid'])
        stored = self.stored(reminder)
        self.assertEqual(stored['uuid'], reminder['uuid'])
        self.assertFalse(stored['is_enabled'])
        self.assertNotIn(reminder['id'], self.pending_ids())

    def test_lead_edit_and_schedule_kind_switch_are_authoritative(self):
        reminder = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z')
        response = self.client.patch(self.reminder_path(reminder), json={'schedule_kind': 'due_relative', 'lead_minutes': 60})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['trigger_at_utc'], '2026-09-08T01:00:00.000Z')
        response = self.client.patch(self.reminder_path(reminder), json={'lead_minutes': 120})
        self.assertEqual(response.json()['trigger_at_utc'], '2026-09-08T00:00:00.000Z')
        response = self.client.patch(self.reminder_path(reminder), json={
            'schedule_kind': 'fixed', 'trigger_at_utc': '2026-09-07T22:00:00Z',
        })
        self.assertEqual(response.status_code, 200, response.text)
        self.patch_task(due_date=None)
        stored = self.stored(reminder)
        self.assertEqual(stored['trigger_at_utc'], '2026-09-07T22:00:00Z')
        self.assertTrue(stored['is_enabled'])

    def test_invalid_payloads_report_422_and_do_not_mutate(self):
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=10)
        before = self.stored(reminder)
        for body in (
            {'schedule_kind': None}, {'schedule_kind': 'relative'}, {'lead_minutes': -1},
            {'lead_minutes': None}, {'is_enabled': None}, {'trigger_at_utc': None},
            {'trigger_at_utc': '2026-01-01T00:00:00+08:00'}, {'lead_minutes': 10**30},
        ):
            with self.subTest(body=body):
                response = self.client.patch(self.reminder_path(reminder), json=body)
                self.assertEqual(response.status_code, 422, response.text)
                self.assertIn('detail', response.json())
                self.assertEqual(self.stored(reminder), before)
        response = self.client.post(self.reminder_path(), json={'schedule_kind': 'fixed'})
        self.assertEqual(response.status_code, 422)

    def test_dst_fold_uses_first_occurrence_and_gap_is_disabled_with_reason(self):
        self.patch_task(due_date='2026-11-01 01:30:00', timezone_id='America/New_York')
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=60)
        self.assertEqual(reminder['trigger_at_utc'], '2026-11-01T04:30:00.000Z')
        self.patch_task(due_date='2026-03-08 02:30:00')
        stored = self.stored(reminder)
        self.assertFalse(stored['is_enabled'])
        self.assertEqual(stored['disabled_reason'], 'nonexistent_due_time')
        response = self.client.post(self.reminder_path(), json={'schedule_kind': 'due_relative'})
        self.assertEqual(response.status_code, 422)
        self.assertIn('daylight-saving', response.json()['detail'])

    def test_pending_refreshes_external_deadline_change_without_moving_fixed(self):
        relative = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        fixed = self.create_reminder(trigger_at_utc='2026-09-08T00:00:00Z')
        with closing(sqlite3.connect(self.path)) as connection:
            connection.execute("UPDATE assignments SET due_date='2026-09-11 12:00:00' WHERE id=?", (self.task['id'],))
            connection.commit()
        self.assertEqual(self.pending_ids(), {relative['id'], fixed['id']})
        self.assertEqual(self.stored(relative)['trigger_at_utc'], '2026-09-11T03:30:00.000Z')
        self.assertEqual(self.stored(fixed)['trigger_at_utc'], fixed['trigger_at_utc'])

    def test_out_of_range_resolved_dates_return_422_and_roll_back(self):
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        for due_date, zone in (
            ('0001-01-01 00:00:00', 'Asia/Shanghai'),
            ('9999-12-31 23:59:00', 'America/New_York'),
        ):
            with self.subTest(due_date=due_date):
                response = self.client.patch(f"/assignments/{self.task['id']}", json={
                    'due_date': due_date, 'timezone_id': zone,
                })
                self.assertEqual(response.status_code, 422, response.text)
                self.assertIn('supported dates', response.json()['detail'])
                self.assertEqual(self.stored(reminder)['trigger_at_utc'], reminder['trigger_at_utc'])
                stored_task = self.client.get(f"/assignments/{self.task['id']}").json()
                self.assertEqual(stored_task['due_date'], self.task['due_date'])
                self.assertEqual(stored_task['timezone_id'], self.task['timezone_id'])

    def test_assignment_read_exposes_resolved_instant_without_changing_wall_time(self):
        self.assertEqual(self.task['due_at_utc'], '2026-09-08T02:00:00.000Z')
        self.assertEqual(self.task['due_date'], '2026-09-08 10:00')
        updated = self.patch_task(timezone_id='America/New_York')
        self.assertEqual(updated['due_at_utc'], '2026-09-08T14:00:00.000Z')
        self.assertEqual(updated['due_date'], self.task['due_date'])
        missing = self.patch_task(due_date=None)
        self.assertIsNone(missing['due_at_utc'])
        gap = self.patch_task(due_date='2026-03-08 02:30:00')
        self.assertIsNone(gap['due_at_utc'])
        self.assertEqual(gap['due_date'], '2026-03-08 02:30')
        with closing(sqlite3.connect(self.path)) as connection:
            columns = {row[1] for row in connection.execute('PRAGMA table_info(assignments)')}
        self.assertNotIn('due_at_utc', columns)

    def test_simple_task_patch_preserves_professional_fields(self):
        reminder = self.create_reminder(schedule_kind='due_relative', lead_minutes=30)
        updated = self.patch_task(title='只改标题', due_date=None)
        for field in ('description', 'priority', 'link', 'timezone_id'):
            self.assertEqual(updated[field], self.task[field])
        self.assertEqual(self.stored(reminder)['disabled_reason'], 'missing_due_date')


if __name__ == '__main__':
    unittest.main()
