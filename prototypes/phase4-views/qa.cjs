const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const base = 'http://127.0.0.1:4174/?qa=1';
const shotDir = path.join(__dirname, 'screenshots');
fs.mkdirSync(shotDir, { recursive: true });
let browser;

(async () => {
  const errors = [];
  browser = await chromium.launch({ channel: 'msedge', headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 1 });
  page.on('console', message => { if (message.type() === 'error') errors.push(`console: ${message.text()}`); });
  page.on('pageerror', error => errors.push(`page: ${error.message}`));
  await page.goto(base, { waitUntil: 'networkidle' });
  assert.equal(await page.locator('[role=tab]').count(), 6, 'six view tabs');
  assert.equal(await page.locator('[role=tabpanel]').count(), 1, 'one shared tab panel');
  assert.match(await page.locator('#result-count').textContent(), /24 个结果/);
  await page.screenshot({ path: path.join(shotDir, '01-list-desktop.png'), fullPage: true });

  const selectedTitle = (await page.locator('.task-row').first().locator('.task-title').textContent()).trim();
  await page.locator('.task-row').first().click();
  await page.locator('.task-row').first().press('Enter');
  await page.locator('#inspector').waitFor({ state: 'visible' });
  await page.locator('#advance-status').click();
  assert.equal(await page.locator('#undo').isDisabled(), false, 'status change is undoable');
  await page.locator('#undo').click();
  await page.locator('#inspector-close').click();
  await page.locator('#search').fill('实验');
  await page.getByRole('tab', { name: '日历' }).click();
  assert.equal(await page.locator('#search').inputValue(), '实验', 'query persists across views');
  assert.match(await page.locator('#selection-status').textContent(), new RegExp(selectedTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), 'selection persists');
  await page.locator('#clear').click();
  await page.screenshot({ path: path.join(shotDir, '02-calendar-desktop.png'), fullPage: true });

  for (const [name, file] of [['看板', '03-board-desktop.png'], ['表格', '04-table-desktop.png'], ['图库', '05-gallery-desktop.png']]) {
    await page.getByRole('tab', { name }).click();
    await page.screenshot({ path: path.join(shotDir, file), fullPage: true });
  }

  await page.getByRole('tab', { name: 'Cover Flow' }).click();
  await page.locator('#cover-stage canvas').waitFor();
  await page.waitForTimeout(450);
  const canvasSignal = await page.locator('#cover-stage canvas').evaluate(canvas => {
    const context = canvas.getContext('webgl2') || canvas.getContext('webgl');
    if (!context) return 0;
    const pixels = new Uint8Array(4 * 32 * 32);
    context.readPixels(Math.max(0, canvas.width / 2 - 16), Math.max(0, canvas.height / 2 - 16), 32, 32, context.RGBA, context.UNSIGNED_BYTE, pixels);
    return pixels.reduce((sum, value) => sum + value, 0);
  });
  assert(canvasSignal > 1000, '3D canvas contains rendered pixels');
  const before = await page.locator('#cover-title').textContent();
  await page.locator('#cover-stage').press('ArrowRight');
  assert.notEqual(await page.locator('#cover-title').textContent(), before, 'keyboard changes cover');
  await page.locator('.workspace-header').click({ position: { x: 600, y: 40 } });
  await page.screenshot({ path: path.join(shotDir, '06-cover-flow-desktop.png'), fullPage: true });

  await page.locator('#settings-open').click();
  await page.locator('#reduce-motion').check();
  assert.equal(await page.locator('html').getAttribute('class'), 'reduce-motion');
  await page.screenshot({ path: path.join(shotDir, '08-cover-reduced-motion.png'), fullPage: true });
  await page.locator('#settings-close').click();

  await page.locator('#settings-open').click();
  await page.locator('#dataset-size').selectOption('10000');
  await page.locator('#settings-close').click();
  await page.getByRole('tab', { name: '列表' }).click();
  assert.match(await page.locator('#total-count').textContent(), /10,000/);
  assert((await page.locator('.task-row').count()) <= 160, 'large result is windowed');
  assert.match(await page.locator('#render-status').textContent(), /窗口化/);

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  mobile.on('console', message => { if (message.type() === 'error') errors.push(`mobile console: ${message.text()}`); });
  mobile.on('pageerror', error => errors.push(`mobile page: ${error.message}`));
  await mobile.goto(base, { waitUntil: 'networkidle' });
  const layout = await mobile.evaluate(() => ({ body: document.body.scrollWidth, viewport: innerWidth, bottom: getComputedStyle(document.querySelector('.sidebar')).position }));
  assert(layout.body <= layout.viewport, `mobile page does not overflow: ${JSON.stringify(layout)}`);
  assert.equal(layout.bottom, 'fixed');
  await mobile.screenshot({ path: path.join(shotDir, '07-list-mobile.png'), fullPage: true });
  await mobile.getByRole('tab', { name: 'Cover Flow' }).click();
  await mobile.locator('#cover-stage canvas').waitFor();
  const stageBox = await mobile.locator('#cover-stage').boundingBox();
  await mobile.mouse.move(stageBox.x + stageBox.width * .75, stageBox.y + stageBox.height / 2);
  await mobile.mouse.down(); await mobile.mouse.move(stageBox.x + stageBox.width * .25, stageBox.y + stageBox.height / 2); await mobile.mouse.up();
  assert.equal(errors.length, 0, errors.join('\n'));
  await browser.close();
  console.log(JSON.stringify({ screenshots: fs.readdirSync(shotDir).sort(), canvasSignal, mobile: layout, errors }, null, 2));
})().catch(async error => { console.error(error); await browser?.close?.(); process.exitCode = 1; });
