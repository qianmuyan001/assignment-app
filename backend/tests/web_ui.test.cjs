'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { wallInstant, dueInstant, dateKey, matchesScope, reminderIsDue, normalizePreferences } = require('../app/static/learning-core.js');
const now = new Date('2026-09-09T12:00:00Z');
const task = (date, status = 'todo', timezone_id = 'UTC') => ({ due_date: date, status, timezone_id });

test('all scope retains tasks without deadlines and completed tasks', () => {
  assert.equal(matchesScope(task(null), 'all', now, 'UTC'), true);
  assert.equal(matchesScope(task(null, 'done'), 'all', now, 'UTC'), true);
});
test('today uses requested display timezone and includes completed tasks', () => {
  const item = task('2026-09-10 00:30:00', 'todo', 'Asia/Shanghai');
  assert.equal(matchesScope(item, 'today', now, 'UTC'), true);
  assert.equal(matchesScope(item, 'today', now, 'Asia/Shanghai'), false);
  assert.equal(matchesScope(task('2026-09-09 18:00:00', 'done'), 'today', now, 'UTC'), true);
});
test('week is ISO Monday through Sunday, not the next seven days', () => {
  assert.equal(matchesScope(task('2026-09-07 01:00:00'), 'week', now, 'UTC'), true);
  assert.equal(matchesScope(task('2026-09-13 23:59:00'), 'week', now, 'UTC'), true);
  assert.equal(matchesScope(task('2026-09-14 00:00:00'), 'week', now, 'UTC'), false);
  assert.equal(matchesScope(task('2026-09-06 23:59:00'), 'week', now, 'UTC'), false);
});
test('overdue includes earlier today but excludes completed and undated tasks', () => {
  assert.equal(matchesScope(task('2026-09-09 11:59:00'), 'overdue', now), true);
  assert.equal(matchesScope(task('2026-09-09 12:00:00'), 'overdue', now), false);
  assert.equal(matchesScope(task('2026-09-08 12:00:00','completed'), 'overdue', now), false);
  assert.equal(matchesScope(task(null), 'overdue', now), false);
});
test('completed accepts the existing done and shared completed mappings', () => {
  assert.equal(matchesScope(task(null,'done'), 'completed', now), true);
  assert.equal(matchesScope(task(null,'completed'), 'completed', now), true);
  assert.equal(matchesScope(task(null,'in_progress'), 'completed', now), false);
});
test('deadline conversion respects the declared IANA timezone', () => {
  assert.equal(dueInstant(task('2026-09-09 18:30:00','todo','Asia/Shanghai')).toISOString(), '2026-09-09T10:30:00.000Z');
});
test('DST repeated time resolves to the first occurrence', () => {
  assert.equal(wallInstant('2026-11-01 01:30:00','America/New_York').toISOString(), '2026-11-01T05:30:00.000Z');
});
test('DST missing wall time has no instant', () => {
  assert.equal(wallInstant('2026-03-08 02:30:00','America/New_York'), null);
});
test('non-hour offsets resolve correctly', () => {
  assert.equal(wallInstant('2026-09-09 12:00:00','Asia/Kathmandu').toISOString(), '2026-09-09T06:15:00.000Z');
});
test('invalid or absent wall values have no deadline', () => {
  assert.equal(wallInstant(null,'UTC'), null);
  assert.equal(wallInstant('2026-02-30 12:00:00','UTC'), null);
  assert.equal(wallInstant('2026-09-09 12:00:00','Invalid/Zone'), null);
});
test('day keys use the supplied zone at midnight boundaries', () => {
  assert.equal(dateKey(new Date('2026-09-09T23:30:00Z'), 'Asia/Shanghai'), '2026-09-10');
});
test('both languages, all themes and both modes survive preference normalization', () => {
  for (const language of ['en','zh-CN']) for (const theme of ['system','light','dark']) for (const mode of ['simple','professional']) {
    assert.deepEqual(normalizePreferences({ language, theme, mode }), { language, theme, mode });
  }
});
test('invalid stored preferences fall back to supported values', () => {
  assert.deepEqual(normalizePreferences({ language: 'xx', theme: 'neon', mode: 'deleted' }), { language: 'en', theme: 'system', mode: 'professional' });
});

test('completed tasks remain in shared Today and Week views', () => {
  const item = task('2026-09-09 18:00:00', 'completed');
  assert.equal(matchesScope(item, 'today', now, 'UTC'), true);
  assert.equal(matchesScope(item, 'week', now, 'UTC'), true);
});
test('reminders fire once per trigger and only when enabled and actionable', () => {
  const reminder = { is_enabled: true, trigger_at_utc: '2026-09-09T11:59:30Z', last_scheduled_at: null };
  const from = new Date('2026-09-09T11:59:00Z').getTime();
  assert.equal(reminderIsDue(reminder, from, now.getTime()), true);
  assert.equal(reminderIsDue({...reminder, last_scheduled_at: now.toISOString()}, from, now.getTime()), false);
  assert.equal(reminderIsDue({...reminder, is_enabled: false}, from, now.getTime()), false);
});
test('server cancellation suppresses reminders even with a stale local task list', () => {
  const reminder = { is_enabled: true, trigger_at_utc: '2026-09-09T11:59:30Z', disabled_reason: 'task_completed' };
  const from = new Date('2026-09-09T11:59:00Z').getTime();
  for (const reason of ['task_completed','task_deleted','missing_due_date','nonexistent_due_time']) {
    assert.equal(reminderIsDue({...reminder, disabled_reason: reason}, from, now.getTime()), false);
  }
});
