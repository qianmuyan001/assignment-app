/* Real Chromium acceptance. Run with PLAYWRIGHT_MODULE and PYTHON_EXECUTABLE
 * pointing to installed runtimes. Starts its own loopback server and temp DB;
 * never attaches to an existing server or opens a repository/user database. */
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const playwrightPath = process.env.PLAYWRIGHT_MODULE || 'playwright';
const { chromium } = require(playwrightPath);
const { expect } = require(`${playwrightPath}/test`);
const root = path.resolve(__dirname, '../..');
const output = path.resolve(process.env.BROWSER_EVIDENCE_DIR || path.join(root, 'docs/phase-reports/web-phase3a-v4-evidence'));
fs.mkdirSync(output, { recursive: true });
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'assignment-web-phase3a-browser-'));
const database = path.join(temporary, 'assignments.db');
const report = { source_sha: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), browser: '', screens: [], temporary_database: database, real_user_database_accessed: false, checks: [], failed: 0 };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let server, browser, page, base, currentCheck;
const errors = [];
async function check(name, operation) {
  currentCheck = name;
  await operation();
  report.checks.push({ name, passed: true });
  console.log(`PASS ${name}`);
}
async function request(method, route, data) {
  const response = await fetch(base + route, { method, headers: data === undefined ? {} : { 'Content-Type': 'application/json' }, body: data === undefined ? undefined : JSON.stringify(data) });
  const body = response.status === 204 ? null : await response.json();
  assert.ok(response.ok, `${method} ${route}: ${response.status} ${JSON.stringify(body)}`);
  return body;
}
async function view(name) {
  await page.locator(`[data-view="${name}"]`).click();
  await expect(page.locator(`[data-view="${name}"]`)).toHaveAttribute('aria-current', 'page');
  if (name !== 'tasks') await expect(page.locator('#view-learning h2')).toBeVisible();
}
async function screenshot(name) {
  await page.screenshot({ path: path.join(output, name + '.png'), fullPage: true });
  report.screens.push({ file: name + '.png', viewport: page.viewportSize(), language: await page.locator('html').getAttribute('lang'), theme: await page.locator('html').getAttribute('data-resolved-theme') });
}
async function noOverflow() {
  const geometry = await page.evaluate(() => ({ viewport: innerWidth, body: document.body.scrollWidth, document: document.documentElement.scrollWidth }));
  assert.ok(geometry.body <= geometry.viewport + 1 && geometry.document <= geometry.viewport + 1, JSON.stringify(geometry));
}
function localDate(offset = 0) {
  const day = new Date(Date.now() + offset * 86400000);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(day);
}
async function taskByTitle(title) { return (await request('GET', '/assignments')).find(task => task.title === title); }
async function searchTask(title) {
  await view('tasks');
  await page.locator('#clear-filters-button').click();
  await page.locator('#search-box').fill(title);
  await expect(page.locator('#flow-position')).toHaveText('1 / 1');
}
async function editor(kind, fields) {
  await page.getByRole('button', { name: `Add ${kind}`, exact: true }).click();
  const form = page.locator('.learning-dialog form');
  await expect(form).toBeVisible();
  for (const [name, value] of Object.entries(fields)) {
    const input = form.locator(`[name="${name}"]`);
    if (await input.evaluate(element => element.tagName === 'SELECT')) await input.selectOption(String(value));
    else await input.fill(String(value));
  }
  await form.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.locator('.learning-dialog')).toHaveCount(0);
}

(async () => {
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'browser-server.log'), 'w');
  server = spawn(process.env.PYTHON_EXECUTABLE || 'python3', ['-m', 'uvicorn', 'backend.app.main:app', '--host', '127.0.0.1', '--port', String(port), '--log-level', 'warning'], { cwd: root, env: { ...process.env, ASSIGNMENT_DB_PATH: database }, stdio: ['ignore', log, log] });
  for (let attempt = 0; attempt < 150; attempt++) {
    if (server.exitCode !== null) throw new Error('Disposable server exited: ' + fs.readFileSync(path.join(output, 'browser-server.log'), 'utf8'));
    try { if ((await fetch(base + '/health')).ok) break; } catch (error) { if (attempt === 149) throw error; }
    await sleep(100);
  }
  browser = await chromium.launch({ headless: true });
  report.browser = `Chromium ${browser.version()}`;
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, timezoneId: 'Asia/Shanghai', locale: 'en-US', colorScheme: 'light', acceptDownloads: true });
  page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(base);
  await check('Fresh empty views render without script errors', async () => {
    await expect(page.locator('#flow-empty')).toBeVisible();
    for (const name of ['today', 'calendar', 'timetable', 'exams', 'settings']) {
      await view(name); await noOverflow();
    }
    await screenshot('empty-settings');
  });
  let course, primary, exam, meeting;
  await check('Course and professional task created through visible forms', async () => {
    await page.locator('#open-org-button').click();
    await page.locator('#org-course-name').fill('Calculus / 微积分');
    await page.locator('#org-course-teacher').fill('Lin');
    await page.locator('#org-course-form button[type=submit]').click();
    await expect(page.locator('#org-course-list')).toContainText('Calculus / 微积分');
    course = (await request('GET', '/courses'))[0];
    await page.locator('#close-org-button').click();
    await page.locator('#open-add-button').click();
    await page.locator('#course-picker').selectOption(String(course.id));
    await page.locator('#title').fill('Derivative practice');
    await page.locator('#due-date').fill(localDate() + 'T23:15');
    await page.locator('#task-timezone').fill('Asia/Shanghai');
    await page.locator('#priority').selectOption('high');
    await page.locator('#description').fill('Complete exercises 1–8. Preserve this description.');
    await page.locator('#source-name').fill('Week 1 seminar');
    await page.locator('#source-url').fill('https://example.com/course-material');
    await page.locator('#assignment-form button[type=submit]').click();
    await expect(page.locator('#assignment-dialog')).not.toBeVisible();
    primary = await taskByTitle('Derivative practice');
    assert.equal(primary.course_id, course.id); assert.equal(primary.priority, 'high');
    assert.equal(primary.source_name, 'Week 1 seminar');
    await view('tasks');
    await expect(page.locator('#selected-detail')).toContainText('Derivative practice');
  });
  await check('Task form validation keeps an actionable error inside its dialog', async () => {
    await page.locator('#open-add-button').click();
    await page.locator('#course-name').fill(course.name);
    await page.locator('#title').fill('Invalid timezone must not create');
    await page.locator('#task-timezone').fill('Not/AZone');
    await page.locator('#assignment-form button[type=submit]').click();
    await expect(page.locator('#assignment-dialog [role=alert]')).toBeVisible();
    assert.equal(await taskByTitle('Invalid timezone must not create'), undefined);
    await page.keyboard.press('Escape');
    await expect(page.locator('#assignment-dialog')).not.toBeVisible();
  });
  await check('Attachment upload and download preserve exact payload bytes', async () => {
    await searchTask(primary.title);
    const files = page.locator('#selected-detail input[type=file]');
    await expect(files).toBeVisible();
    await files.setInputFiles({ name: 'study-notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Browser attachment evidence\n学习笔记\n') });
    await files.locator('xpath=ancestor::form').locator('button[type=submit]').click();
    await expect(page.locator('#selected-detail')).toContainText('study-notes.txt');
    const metadata = await request('GET', `/assignments/${primary.id}/attachments`);
    assert.equal(metadata[0].payload_available, true);
    const payload = await fetch(base + `/assignments/${primary.id}/attachments/${metadata[0].id}/file?download=true`);
    assert.ok(payload.ok);
    assert.equal(await payload.text(), 'Browser attachment evidence\n学习笔记\n');
  });
  await check('Task deletion asks for confirmation and cancellation preserves its data', async () => {
    const disposable = await request('POST', '/assignments', { course_name: course.name, title: 'Deletion confirmation sample' });
    await page.locator('#refresh-button').click(); await searchTask(disposable.title);
    page.once('dialog', dialog => dialog.dismiss());
    await page.locator('#selected-detail').getByRole('button', { name: 'Delete', exact: true }).click();
    assert.equal((await request('GET', `/assignments/${disposable.id}`)).title, disposable.title);
    page.once('dialog', dialog => dialog.accept());
    await page.locator('#selected-detail').getByRole('button', { name: 'Delete', exact: true }).click();
    await expect(page.locator('#flow-position')).toHaveText('0 / 0');
    assert.equal((await request('GET', '/assignments')).some(item => item.id === disposable.id), false);
    await page.locator('#clear-filters-button').click();
  });
  await check('All Today Week Overdue Completed filters select real task records', async () => {
    await request('POST', '/assignments', { course_id: course.id, course_name: course.name, title: 'Overdue reading', due_date: localDate(-1) + ' 09:00', timezone_id: 'Asia/Shanghai' });
    await request('POST', '/assignments', { course_id: course.id, course_name: course.name, title: 'Completed exercise', due_date: localDate() + ' 10:00', timezone_id: 'Asia/Shanghai', status: 'done', progress_percent: 100 });
    await request('POST', '/assignments', { course_id: course.id, course_name: course.name, title: 'Unscheduled essay' });
    await page.locator('#search-box').fill(''); await page.locator('#refresh-button').click();
    for (const scope of ['all', 'today', 'week', 'overdue', 'completed']) {
      await page.locator(`[data-scope="${scope}"]`).click();
      const ids = await page.evaluate(() => state.visible.map(task => task.title));
      if (scope === 'all') assert.equal(ids.length, 4);
      if (scope === 'today') assert.deepEqual(new Set(ids), new Set(['Derivative practice', 'Completed exercise']));
      if (scope === 'week') assert.ok(ids.includes('Derivative practice') && !ids.includes('Unscheduled essay'));
      if (scope === 'overdue') assert.ok(ids.includes('Overdue reading') && !ids.includes('Completed exercise'));
      if (scope === 'completed') assert.deepEqual(ids, ['Completed exercise']);
    }
    await page.locator('#clear-filters-button').click();
    const progress = await page.evaluate(() => state.visible.map(task => ({ stored: task.progress_percent, displayed: getProgress(task) })));
    progress.forEach(item => assert.equal(item.displayed, item.stored));
    await page.locator('#cover-flow').focus();
    const selected = await page.evaluate(() => state.selectedId);
    await page.keyboard.press('ArrowRight');
    assert.notEqual(await page.evaluate(() => state.selectedId), selected);
  });
  await check('Timetable form saves overlap warnings and supports edit delete restore', async () => {
    await view('timetable');
    await editor('meeting', { start_time_local: '09:00', end_time_local: '10:00', location: 'Room 204', timezone_id: 'Asia/Shanghai' });
    meeting = (await request('GET', '/course-meetings'))[0];
    await editor('meeting', { start_time_local: '09:30', end_time_local: '10:30', location: 'Library', timezone_id: 'Asia/Shanghai' });
    await expect(page.locator('#view-learning')).toContainText(/overlap/i);
    assert.equal((await request('GET', '/course-meetings')).length, 2);
    const row = page.locator('.learning-row').filter({ hasText: 'Room 204' });
    await row.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.locator('.learning-dialog [name=location]').fill('Room 205');
    await page.locator('.learning-dialog').getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.locator('.learning-dialog')).toHaveCount(0);
    assert.equal((await request('GET', `/course-meetings/${meeting.id}`)).location, 'Room 205');
    page.once('dialog', dialog => dialog.accept());
    await page.locator('.learning-row').filter({ hasText: 'Room 205' }).getByRole('button', { name: 'Delete', exact: true }).click();
    await expect(page.locator('.learning-row').filter({ hasText: 'Room 205' })).toHaveCount(0);
    await page.locator('[name=deleted-meetings]').check();
    await page.locator('.learning-row').filter({ hasText: 'Room 205' }).getByRole('button', { name: 'Restore', exact: true }).click();
    await expect(page.locator('.learning-row').filter({ hasText: 'Room 205' }).getByRole('button', { name: 'Edit', exact: true })).toBeVisible();
    assert.equal((await request('GET', `/course-meetings/${meeting.id}`)).uuid, meeting.uuid);
    await page.locator('[name=deleted-meetings]').uncheck();
    await page.locator('[name=timetable-mode]').selectOption('today');
    await expect(page.locator('#view-learning')).toContainText('Room 205');
    await page.locator('[name=timetable-mode]').selectOption('week');
  });
  await check('Exams edit status and idempotent review task survive exam deletion', async () => {
    await view('exams');
    await editor('exam', { name: 'Calculus quiz', starts_at_local: localDate(2) + 'T14:30', scope: 'Derivatives and limits', notes: 'Bring a calculator', location: 'Hall B' });
    exam = (await request('GET', '/exams'))[0];
    const row = page.locator('.learning-row').filter({ hasText: 'Calculus quiz' });
    await row.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.locator('.learning-dialog [name=status]').selectOption('completed');
    await page.locator('.learning-dialog').getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.locator('.learning-dialog')).toHaveCount(0);
    assert.equal((await request('GET', `/exams/${exam.id}`)).status, 'completed');
    await row.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.locator('.learning-dialog [name=status]').selectOption('upcoming');
    await page.locator('.learning-dialog').getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.locator('.learning-dialog')).toHaveCount(0);
    await row.getByRole('button', { name: 'Create review task', exact: true }).click();
    await expect(page.locator('#selected-detail')).toContainText('Review: Calculus quiz');
    const stored = await request('GET', `/exams/${exam.id}`);
    const repeated = await request('POST', `/exams/${exam.id}/review-task`);
    assert.equal(repeated.created, false); assert.equal(repeated.assignment.id, stored.linked_assignment_id);
    await view('exams'); page.once('dialog', dialog => dialog.accept());
    await row.getByRole('button', { name: 'Delete', exact: true }).click();
    await expect(page.getByText('No exams scheduled.', { exact: true })).toBeVisible();
    assert.equal((await request('GET', `/assignments/${stored.linked_assignment_id}`)).id, stored.linked_assignment_id);
    await page.locator('[name=deleted-exams]').check();
    await row.getByRole('button', { name: 'Restore', exact: true }).click();
    await expect(row.getByRole('button', { name: 'Edit', exact: true })).toBeVisible();
    await page.locator('[name=deleted-exams]').uncheck();
  });
  await check('Calendar and Today show real tasks exams courses and quick add', async () => {
    await view('calendar');
    await expect(page.locator('.calendar-grid')).toContainText('Derivative practice');
    await expect(page.locator('.calendar-grid')).toContainText('Calculus quiz');
    await view('today');
    for (const text of ['Room 205', 'Calculus quiz', 'Derivative practice', 'Overdue reading']) await expect(page.locator('#view-learning')).toContainText(text);
    await page.getByRole('button', { name: 'Quick add', exact: true }).click();
    await expect(page.locator('#assignment-dialog')).toBeVisible();
    await page.keyboard.press('Escape');
  });
  await check('Fixed and relative reminders save separately and react to deadline edits', async () => {
    await searchTask(primary.title);
    const form = page.locator('.reminder-form');
    await form.locator('[name=schedule_kind]').selectOption('due_relative');
    await form.locator('[name=lead_minutes]').fill('30');
    await form.getByRole('button', { name: 'Add', exact: true }).click();
    await expect(page.locator('#selected-detail')).toContainText('Relative to deadline');
    await form.locator('[name=trigger_at_utc]').fill(localDate(1) + 'T08:00');
    await form.getByRole('button', { name: 'Add', exact: true }).click();
    let reminders = await request('GET', `/assignments/${primary.id}/reminders`);
    assert.equal(reminders.length, 2);
    const fixed = reminders.find(item => item.schedule_kind === 'fixed');
    const relative = reminders.find(item => item.schedule_kind === 'due_relative');
    await page.locator('#selected-detail').getByRole('button', { name: 'Edit', exact: true }).click();
    await page.locator('.detail-edit-form [name=due_date]').fill(localDate(1) + 'T22:15');
    await page.locator('.detail-edit-form').getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.locator('.detail-edit-form')).toHaveCount(0);
    reminders = await request('GET', `/assignments/${primary.id}/reminders`);
    assert.equal(reminders.find(item => item.id === fixed.id).trigger_at_utc, fixed.trigger_at_utc);
    assert.notEqual(reminders.find(item => item.id === relative.id).trigger_at_utc, relative.trigger_at_utc);
    await searchTask('Unscheduled essay');
    await page.locator('.reminder-form [name=schedule_kind]').selectOption('due_relative');
    await expect(page.locator('.reminder-form')).toContainText('A due date is required');
    await expect(page.locator('.reminder-form button[type=submit]')).toBeDisabled();
    await request('PATCH', `/assignments/${primary.id}`, { due_date: localDate() + ' 23:15' });
  });
  await check('Simple mode editing preserves professional fields and language theme persist', async () => {
    await view('settings');
    await page.locator('[name=preference-mode]').selectOption('simple');
    await searchTask(primary.title);
    await page.locator('#selected-detail').getByRole('button', { name: 'Edit', exact: true }).click();
    await expect(page.locator('.detail-edit-form [name=priority]')).not.toBeVisible();
    await page.locator('.detail-edit-form [name=title]').fill('Derivative practice revised');
    await page.locator('.detail-edit-form').getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.locator('.detail-edit-form')).toHaveCount(0);
    primary = await request('GET', `/assignments/${primary.id}`);
    assert.equal(primary.priority, 'high'); assert.equal(primary.source_name, 'Week 1 seminar');
    assert.equal(primary.source_url, 'https://example.com/course-material'); assert.equal(primary.course_id, course.id);
    await view('settings'); await page.locator('[name=preference-mode]').selectOption('professional');
    await page.locator('[name=preference-theme]').selectOption('dark');
    await page.reload(); await expect(page.locator('html')).toHaveAttribute('data-resolved-theme', 'dark');
    await page.locator('[name=preference-theme]').selectOption('system');
    await page.emulateMedia({ colorScheme: 'dark' }); await expect(page.locator('html')).toHaveAttribute('data-resolved-theme', 'dark');
    await page.emulateMedia({ colorScheme: 'light' }); await expect(page.locator('html')).toHaveAttribute('data-resolved-theme', 'light');
  });
  await check('Open-page reminder actually delivers once and records delivery time', async () => {
    await view('tasks'); await page.locator('#refresh-button').click();
    const trigger = new Date(Date.now() + 1500).toISOString();
    const reminder = await request('POST', `/assignments/${primary.id}/reminders`, { schedule_kind: 'fixed', trigger_at_utc: trigger, is_enabled: true });
    await expect(page.locator('#workspace-notice')).toContainText('Reminder: ' + primary.title, { timeout: 22000 });
    await expect.poll(async () => (await request('GET', `/assignments/${primary.id}/reminders`)).find(item => item.id === reminder.id).last_scheduled_at).not.toBeNull();
    const delivered = (await request('GET', `/assignments/${primary.id}/reminders`)).find(item => item.id === reminder.id);
    assert.ok(new Date(delivered.last_scheduled_at) >= new Date(trigger));
    await request('DELETE', `/assignments/${primary.id}/reminders/${reminder.id}`);
  });
  await check('Backup center downloads inspects confirms and restores data with attachments', async () => {
    await view('settings'); await page.getByRole('button', { name: 'Create backup', exact: true }).click();
    const link = page.locator('.backup-list a').first(); await expect(link).toBeVisible();
    const downloadPromise = page.waitForEvent('download'); await link.click(); const download = await downloadPromise;
    const archive = path.join(temporary, 'browser-backup.zip'); await download.saveAs(archive);
    const disposable = await request('POST', '/assignments', { course_name: course.name, title: 'Must disappear after restore' });
    await page.locator('[name=backup-file]').setInputFiles(archive);
    await page.getByRole('button', { name: 'Check backup', exact: true }).click();
    await expect(page.locator('.backup-preview')).toContainText('Backup checked.');
    await expect(page.getByRole('button', { name: 'Restore backup', exact: true })).toBeDisabled();
    assert.ok(await request('GET', `/assignments/${disposable.id}`));
    await page.locator('[name=restore-confirmation]').check();
    await page.getByRole('button', { name: 'Restore backup', exact: true }).click();
    await expect(page.locator('#workspace-notice')).toContainText('Restore completed.');
    assert.equal((await request('GET', '/assignments')).some(item => item.id === disposable.id), false);
    const attachments = await request('GET', `/assignments/${primary.id}/attachments`);
    assert.equal(attachments[0].payload_available, true);
    await page.locator('[name=backup-file]').setInputFiles({ name: 'broken.zip', mimeType: 'application/zip', buffer: Buffer.from('corrupt backup') });
    await page.getByRole('button', { name: 'Check backup', exact: true }).click();
    await expect(page.locator('.backup-preview [role=alert]')).toBeVisible();
    assert.equal((await request('GET', `/assignments/${primary.id}`)).title, primary.title);
  });
  await check('Network error and loading states allow retry', async () => {
    await page.route('**/exams?*', route => route.abort());
    await view('today');
    await page.locator('[data-view=exams]').click();
    await expect(page.locator('#view-learning [role=alert]')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Retry', exact: true })).toBeVisible();
    await page.unroute('**/exams?*');
    await page.getByRole('button', { name: 'Retry', exact: true }).click();
    await expect(page.locator('#view-learning')).toContainText('Calculus quiz');
    await page.route('**/overview/today*', async route => { await sleep(350); await route.continue(); });
    await page.locator('[data-view=today]').click();
    await expect(page.locator('#view-learning')).toContainText('Loading');
    await expect(page.locator('#view-learning h2')).toBeVisible();
    await page.unroute('**/overview/today*');
  });
  await check('Desktop English screenshots cover all six views without overflow', async () => {
    await view('tasks'); await page.locator('#clear-filters-button').click();
    for (const name of ['tasks', 'today', 'calendar', 'timetable', 'exams', 'settings']) {
      await view(name); await noOverflow(); await screenshot(`desktop-en-${name}`);
    }
    await page.locator('[name=preference-theme]').selectOption('dark');
    await screenshot('desktop-en-settings-dark');
    await page.locator('[name=preference-theme]').selectOption('light');
  });
  await check('Chinese translation persists after reload on all six views', async () => {
    await page.locator('[name=preference-language]').selectOption('zh-CN');
    await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
    await expect(page.locator('[data-view=timetable]')).toHaveText('课程表');
    await expect(page.locator('[data-view=settings]')).toHaveText('设置');
    await page.reload(); await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
    for (const name of ['tasks', 'today', 'calendar', 'timetable', 'exams', 'settings']) {
      await view(name); await noOverflow(); await screenshot(`desktop-zh-${name}`);
    }
    await expect(page.locator('#view-learning')).toContainText('仅在应用打开期间提醒');
    await page.locator('#view-learning details summary').click();
    await expect(page.locator('#view-learning details')).toContainText('中英文、主题、简易/专业模式');
    await screenshot('desktop-zh-about');
  });
  await check('Narrow layouts and reduced motion retain visible usable controls', async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.emulateMedia({ reducedMotion: 'reduce' });
    for (const name of ['tasks', 'today', 'calendar', 'timetable', 'exams', 'settings']) {
      await view(name); await noOverflow(); await screenshot(`narrow-zh-${name}`);
    }
    await page.locator('[name=preference-theme]').selectOption('dark');
    await screenshot('narrow-zh-settings-dark');
    await page.locator('[name=preference-theme]').selectOption('light');
    await page.locator('[name=preference-mode]').selectOption('simple');
    await view('tasks'); await screenshot('narrow-zh-simple-tasks');
    await view('settings'); await page.locator('[name=preference-mode]').selectOption('professional');
    await page.setViewportSize({ width: 320, height: 740 });
    for (const name of ['tasks', 'today', 'calendar', 'timetable', 'exams', 'settings']) { await view(name); await noOverflow(); }
    await page.locator('#open-add-button').click();
    await noOverflow();
    const box = await page.locator('#assignment-dialog').boundingBox(); assert.ok(box.x >= 0 && box.x + box.width <= 321);
    await page.keyboard.press('Escape');
    assert.ok(await page.locator('#open-add-button').evaluate(element => element === document.activeElement));
  });
  await check('No uncaught browser script errors', async () => assert.deepEqual(errors, []));
  fs.rmSync(path.join(output, 'browser-failure.png'), { force: true });
  report.passed = report.checks.length;
})().catch(async error => {
  report.failed = 1; report.failure = { check: currentCheck, message: error.stack };
  console.error(error);
  if (page) await page.screenshot({ path: path.join(output, 'browser-failure.png'), fullPage: true }).catch(screenshotError => console.error(screenshotError));
  process.exitCode = 1;
}).finally(async () => {
  report.passed = report.checks.length;
  fs.writeFileSync(path.join(output, 'browser-acceptance.json'), JSON.stringify(report, null, 2));
  if (browser) await browser.close();
  if (server && server.exitCode === null) { server.kill('SIGTERM'); await new Promise(resolve => server.once('exit', resolve)); }
  console.log(`Browser checks: ${report.passed} passed; ${report.failed} failed. Temporary database: ${database}`);
});
