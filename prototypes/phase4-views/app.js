import * as THREE from './vendor/three.module.js';
import { courses, statuses, priorities, views, makeTasks, queryTasks, setStatus, TODAY } from './model.js';
import { coverCanvas, coverURL } from './covers.js';

const $ = selector => document.querySelector(selector);
const escape = value => String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const icons = () => globalThis.lucide?.createIcons({ attrs: { 'aria-hidden': 'true' } });
const scopeNames = { all: '全部任务', today: '今天', week: '本周', overdue: '已逾期', completed: '已完成' };
const state = { view: 'list', scope: 'all', course: 'all', query: '', status: 'all', priority: 'all', sort: 'due', selectedId: 1, inspector: false, display: 'professional', size: 24, manualReduce: false };
let tasks = makeTasks();
let undoSnapshot = null;
let coverRuntime = null;
let toastTimer = 0;

function courseFor(task) { return courses.find(c => c.id === task.course_id); }
function due(task, short = false) {
  if (!task.due_date) return '未安排';
  const date = task.due_date.slice(5, 10).replace('-', ' 月 ') + ' 日';
  return task.all_day || short ? date : `${date} ${task.due_date.slice(11, 16)}`;
}
function overdue(task) { return !!task.due_date && task.status !== 'done' && task.due_date < `${TODAY} 10:00:00`; }
function selected() { return tasks.find(t => t.id === state.selectedId) || null; }
function visible() { return queryTasks(tasks, state); }
function announce(text) { $('#live').textContent = text; }
function showToast(text) { clearTimeout(toastTimer); const node = $('#toast'); node.textContent = text; node.hidden = false; toastTimer = setTimeout(() => { node.hidden = true; }, 1600); }
function pushUndo() { undoSnapshot = structuredClone(tasks); $('#undo').disabled = false; }
function mutate(action, message) { pushUndo(); action(); render(); announce(message); showToast(message); }
function setSelected(id, open = false) { state.selectedId = Number(id); if (open) state.inspector = true; render(); }

function renderShell() {
  const scopes = [['all', 'inbox'], ['today', 'sun'], ['week', 'calendar-range'], ['overdue', 'circle-alert'], ['completed', 'circle-check']];
  $('#scope-nav').innerHTML = scopes.map(([key, icon]) => `<button class="nav-item" data-scope="${key}" aria-current="${state.scope === key}"><i data-lucide="${icon}"></i><span>${scopeNames[key]}</span><span class="count">${tasks.filter(t => queryTasks([t], { ...state, scope: key, query: '', status: 'all', priority: 'all', course: 'all' }).length).length}</span></button>`).join('');
  $('#course-nav').innerHTML = courses.map(c => `<button class="nav-item" data-course="${c.id}" aria-current="${String(state.course) === String(c.id)}"><span class="course-dot" style="background:${c.color}"></span><span>${escape(c.name)}</span><span class="count">${tasks.filter(t => t.course_id === c.id).length}</span></button>`).join('');
  $('#view-tabs').innerHTML = views.map(([key, label, icon]) => `<button class="view-tab" id="tab-${key}" role="tab" aria-selected="${state.view === key}" aria-controls="view-panel" tabindex="${state.view === key ? 0 : -1}" data-view="${key}" title="${label}"><i data-lucide="${icon}"></i><span>${label}</span></button>`).join('');
  $('#scope-title').textContent = state.course === 'all' ? scopeNames[state.scope] : courseFor({ course_id: Number(state.course) }).name;
  $('#total-count').textContent = `${tasks.length.toLocaleString('zh-CN')} 个任务`;
  $('#detail-toggle').setAttribute('aria-pressed', String(state.inspector));
  $('#detail-toggle').disabled = !selected();
  $('#search').value = state.query; $('#status-filter').value = state.status; $('#priority-filter').value = state.priority; $('#sort').value = state.sort;
  $('#display-mode').value = state.display; $('#dataset-size').value = String(state.size); $('#reduce-motion').checked = state.manualReduce;
  const systemReduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  $('#motion-status').textContent = systemReduced ? '系统已启用 Reduce Motion；3D 视图将即时切换。' : '跟随系统，也可在原型中强制启用。';
}

function renderResults() {
  const list = visible();
  $('#result-count').textContent = `${list.length.toLocaleString('zh-CN')} 个结果`;
  const bits = [];
  if (state.query) bits.push(`搜索“${state.query}”`);
  if (state.status !== 'all') bits.push(statuses[state.status]);
  if (state.priority !== 'all') bits.push(`${priorities[state.priority]}优先级`);
  $('#query-summary').textContent = bits.length ? `· ${bits.join(' · ')}` : '· 当前查询适用于全部视图';
  const hiddenSelection = selected() && !list.some(t => t.id === state.selectedId);
  $('#reveal-selection').hidden = !hiddenSelection;
  $('#view-panel').setAttribute('aria-labelledby', `tab-${state.view}`);
  $('#render-status').textContent = list.length > 300 ? `窗口化预览 · ${Math.min(list.length, 160)} / ${list.length.toLocaleString('zh-CN')}` : `${views.find(v => v[0] === state.view)[1]}视图`;
  if (!list.length) {
    disposeCover();
    $('#view-panel').innerHTML = `<div class="empty-state"><div><i data-lucide="search-x"></i><h2>没有符合条件的任务</h2><p>清除筛选，或换一个搜索词。</p></div></div>`;
    return;
  }
  const renderers = { list: renderList, calendar: renderCalendar, board: renderBoard, table: renderTable, gallery: renderGallery, cover: renderCover };
  renderers[state.view](list);
}

function taskRow(t) {
  const course = courseFor(t);
  return `<article class="task-row ${t.id === state.selectedId ? 'selected' : ''}" data-task="${t.id}" tabindex="0" aria-label="${escape(t.title)}，${statuses[t.status]}，${due(t)}">
    <span class="course-marker" style="background:${course.color}"></span><div class="task-primary"><div class="task-title">${escape(t.title)}</div>${state.display === 'professional' ? `<div class="task-description">${escape(t.description)}</div>` : ''}</div><span class="task-course">${escape(t.course_name)}</span><span class="due ${overdue(t) ? 'overdue' : ''}">${due(t)}</span><span class="priority-pill ${t.priority}">${priorities[t.priority]}优先级</span><button class="icon-button row-more" data-open="${t.id}" aria-label="打开 ${escape(t.title)} 详情" title="任务详情"><i data-lucide="chevron-right"></i></button></article>`;
}
function renderList(list) {
  disposeCover(); const now = list.filter(t => t.due_date && t.due_date.slice(0, 10) <= '2026-09-02').slice(0, 80); const later = list.filter(t => !now.includes(t)).slice(0, 80);
  $('#view-panel').innerHTML = `<div class="task-list"><div class="section-label"><span>近期</span><span>${now.length}</span></div>${now.map(taskRow).join('')}${later.length ? `<div class="section-label"><span>稍后与未安排</span><span>${later.length}</span></div>${later.map(taskRow).join('')}` : ''}</div>`;
}
function renderBoard(list) {
  disposeCover(); const groups = ['todo', 'in_progress', 'done'];
  $('#view-panel').innerHTML = `<div class="board">${groups.map(status => { const group = list.filter(t => t.status === status); const shown = group.slice(0, 45); return `<section class="board-column" aria-labelledby="board-${status}"><div class="board-title" id="board-${status}"><span class="status-dot ${status}"></span>${statuses[status]} <span class="count">${group.length}</span></div><div class="board-cards">${shown.map(t => `<article class="board-card ${t.id === state.selectedId ? 'selected' : ''}" data-task="${t.id}" tabindex="0"><span class="task-course">${escape(t.course_name)}</span><div class="task-title">${escape(t.title)}</div>${state.display === 'professional' ? `<div class="task-description">${escape(t.description)}</div>` : ''}<div class="card-meta"><span class="priority-pill ${t.priority}">${priorities[t.priority]}优先级</span><span class="due ${overdue(t) ? 'overdue' : ''}">${due(t, true)}</span></div></article>`).join('')}${group.length > shown.length ? `<button class="board-more">还有 ${group.length - shown.length} 项</button>` : ''}</div></section>`; }).join('')}</div>`;
}
function renderTable(list) {
  disposeCover(); const shown = list.slice(0, 160);
  $('#view-panel').innerHTML = `<div class="data-table-wrap"><table class="data-table"><thead><tr><th><span class="sr-only">完成</span></th><th>任务</th><th>课程</th><th>截止时间</th><th>状态</th><th>优先级</th></tr></thead><tbody>${shown.map(t => `<tr class="${t.id === state.selectedId ? 'selected' : ''}" data-task="${t.id}" tabindex="0"><td><input class="table-check" data-complete="${t.id}" type="checkbox" ${t.status === 'done' ? 'checked' : ''} aria-label="将 ${escape(t.title)} 标记为${t.status === 'done' ? '未完成' : '完成'}"></td><td title="${escape(t.title)}">${escape(t.title)}</td><td>${escape(t.course_name)}</td><td class="due ${overdue(t) ? 'overdue' : ''}">${due(t)}</td><td><span class="status-pill"><span class="status-dot ${t.status}"></span>${statuses[t.status]}</span></td><td><span class="priority-pill ${t.priority}">${priorities[t.priority]}</span></td></tr>`).join('')}</tbody></table></div>`;
}
function renderGallery(list) {
  disposeCover(); const shown = list.slice(0, 100);
  $('#view-panel').innerHTML = `<div class="gallery">${shown.map(t => `<article class="gallery-card ${t.id === state.selectedId ? 'selected' : ''}" data-task="${t.id}" tabindex="0"><div class="gallery-thumb"><img src="${coverURL(t)}" alt="${escape(t.title)} 的模拟提交预览"></div><div class="gallery-content"><span class="task-course">${escape(t.course_name)}</span><div class="task-title">${escape(t.title)}</div><div class="card-meta"><span class="status-pill"><span class="status-dot ${t.status}"></span>${statuses[t.status]}</span><span class="due ${overdue(t) ? 'overdue' : ''}">${due(t, true)}</span></div></div></article>`).join('')}</div>`;
}
function calendarDays() {
  const days = [];
  for (let day = 24; day <= 31; day++) days.push({ iso: `2026-08-${day}`, n: day, other: day < 31 });
  for (let day = 1; day <= 27; day++) days.push({ iso: `2026-09-${String(day).padStart(2, '0')}`, n: day, other: false });
  return days;
}
function renderCalendar(list) {
  disposeCover(); const arranged = list.filter(t => t.due_date); const unscheduled = list.filter(t => !t.due_date).slice(0, 12); const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  $('#view-panel').innerHTML = `<div class="calendar"><div><div class="monthbar"><h2>2026 年 9 月</h2><div class="calendar-controls"><button class="icon-button" aria-label="上个月" title="上个月"><i data-lucide="chevron-left"></i></button><button class="secondary-button">今天</button><button class="icon-button" aria-label="下个月" title="下个月"><i data-lucide="chevron-right"></i></button></div></div><div class="calendar-grid">${weekdays.map(d => `<div class="weekday">周${d}</div>`).join('')}${calendarDays().map(d => `<div class="calendar-day ${d.other ? 'other' : ''} ${d.iso === TODAY ? 'today' : ''}"><div class="date-number">${d.n}</div>${arranged.filter(t => t.due_date.slice(0, 10) === d.iso).slice(0, 3).map(t => `<button class="calendar-task ${t.id === state.selectedId ? 'selected' : ''}" style="--course:${courseFor(t).color}" data-task="${t.id}" title="${escape(t.title)}">${escape(t.title)}</button>`).join('')}</div>`).join('')}</div></div>${unscheduled.length ? `<section class="unscheduled"><h3>未安排 · ${unscheduled.length}</h3><div class="unscheduled-list">${unscheduled.map(t => `<button class="calendar-task ${t.id === state.selectedId ? 'selected' : ''}" style="--course:${courseFor(t).color}" data-task="${t.id}">${escape(t.title)}</button>`).join('')}</div></section>` : ''}</div>`;
}

function renderCover(list) {
  disposeCover(); const shown = list.slice(0, 31); const index = Math.max(0, shown.findIndex(t => t.id === state.selectedId)); const active = shown[index] || shown[0]; if (active.id !== state.selectedId) state.selectedId = active.id;
  $('#view-panel').innerHTML = `<div class="cover-shell" role="region" aria-roledescription="轮播" aria-label="3D 任务封面"><div class="cover-stage" id="cover-stage" tabindex="0" aria-label="${escape(active.title)}。使用左右方向键切换，按 Enter 打开详情"></div><div class="cover-info"><button class="cover-nav" id="cover-prev" aria-label="上一个任务"><i data-lucide="chevron-left"></i></button><div class="cover-caption"><div class="task-title" id="cover-title">${escape(active.title)}</div><div class="task-course" id="cover-course">${escape(active.course_name)} · ${due(active)}</div><div class="cover-count" id="cover-count">${index + 1} / ${shown.length}</div></div><button class="cover-nav" id="cover-next" aria-label="下一个任务"><i data-lucide="chevron-right"></i></button></div></div>`;
  initCover(shown, index);
}

function initCover(list, initial) {
  const stage = $('#cover-stage');
  try {
    const scene = new THREE.Scene(); const camera = new THREE.PerspectiveCamera(42, 1, .1, 100); camera.position.set(0, .1, 8.2);
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: new URLSearchParams(location.search).has('qa'), powerPreference: 'high-performance' }); renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75)); renderer.outputColorSpace = THREE.SRGBColorSpace; stage.append(renderer.domElement);
    const group = new THREE.Group(); scene.add(group); const geometry = new THREE.PlaneGeometry(3, 3.75); const cards = list.map((task, i) => { const texture = new THREE.CanvasTexture(coverCanvas(task)); texture.colorSpace = THREE.SRGBColorSpace; const material = new THREE.MeshBasicMaterial({ map: texture, side: THREE.DoubleSide }); const mesh = new THREE.Mesh(geometry, material); mesh.userData = { task, texture }; group.add(mesh); return mesh; });
    let current = initial; let frame = 0; let startX = null;
    const reduced = () => state.manualReduce || matchMedia('(prefers-reduced-motion: reduce)').matches;
    const layout = snap => { cards.forEach((card, i) => { const delta = i - current; const visible = Math.abs(delta) <= 4; card.visible = visible; if (!visible) return; const x = Math.sign(delta) * (2.25 + Math.max(0, Math.abs(delta) - 1) * 1.08); const z = -Math.abs(delta) * .82; const ry = -Math.sign(delta) * .72; if (snap) { card.position.set(x, 0, z); card.rotation.y = ry; } else { card.position.x += (x - card.position.x) * .16; card.position.z += (z - card.position.z) * .16; card.rotation.y += (ry - card.rotation.y) * .16; } card.renderOrder = 20 - Math.abs(delta); }); };
    const draw = () => { frame = 0; resize(); layout(reduced()); renderer.render(scene, camera); if (!reduced() && cards.some((c, i) => Math.abs(c.position.x - (i === current ? 0 : Math.sign(i-current)*(2.25+Math.max(0,Math.abs(i-current)-1)*1.08))) > .01)) frame = requestAnimationFrame(draw); };
    const resize = () => { const w = Math.max(stage.clientWidth, 1), h = Math.max(stage.clientHeight, 1); if (renderer.domElement.width !== Math.round(w * renderer.getPixelRatio()) || renderer.domElement.height !== Math.round(h * renderer.getPixelRatio())) { renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix(); } };
    const sync = () => { const t = list[current]; state.selectedId = t.id; $('#cover-title').textContent = t.title; $('#cover-course').textContent = `${t.course_name} · ${due(t)}`; $('#cover-count').textContent = `${current + 1} / ${list.length}`; stage.setAttribute('aria-label', `${t.title}。使用左右方向键切换，按 Enter 打开详情`); $('#selection-status').textContent = `已选择：${t.title}`; cancelAnimationFrame(frame); layout(reduced()); frame = requestAnimationFrame(draw); announce(`${t.title}，${current + 1} / ${list.length}`); };
    const move = delta => { current = Math.max(0, Math.min(list.length - 1, current + delta)); sync(); };
    $('#cover-prev').onclick = () => move(-1); $('#cover-next').onclick = () => move(1);
    stage.onkeydown = event => { if (event.key === 'ArrowLeft') { event.preventDefault(); move(-1); } if (event.key === 'ArrowRight') { event.preventDefault(); move(1); } if (event.key === 'Home') { current = 0; sync(); } if (event.key === 'End') { current = list.length - 1; sync(); } if (event.key === 'Enter') { state.inspector = true; render(); } };
    stage.onpointerdown = event => { startX = event.clientX; stage.classList.add('dragging'); stage.setPointerCapture(event.pointerId); };
    stage.onpointerup = event => { if (startX !== null && Math.abs(event.clientX - startX) > 36) move(event.clientX < startX ? 1 : -1); startX = null; stage.classList.remove('dragging'); };
    const observer = new ResizeObserver(() => { resize(); draw(); }); observer.observe(stage); layout(true); draw();
    coverRuntime = { renderer, geometry, cards, observer, frame };
  } catch (error) {
    stage.innerHTML = `<div class="cover-fallback"><img src="${coverURL(list[initial])}" alt="${escape(list[initial].title)} 的模拟提交预览"></div>`;
    $('#render-status').textContent = '2D 安全回退'; console.error(error);
  }
}
function disposeCover() {
  if (!coverRuntime) return; cancelAnimationFrame(coverRuntime.frame); coverRuntime.observer.disconnect(); coverRuntime.cards.forEach(c => { c.userData.texture.dispose(); c.material.dispose(); }); coverRuntime.geometry.dispose(); coverRuntime.renderer.dispose(); coverRuntime.renderer.domElement.remove(); coverRuntime = null;
}

function renderInspector() {
  const inspector = $('#inspector'); const task = selected(); inspector.hidden = !state.inspector || !task; $('.work-area').classList.toggle('with-inspector', !inspector.hidden);
  if (inspector.hidden) { inspector.innerHTML = ''; $('#selection-status').textContent = task ? `已选择：${task.title}` : '未选择任务'; return; }
  const course = courseFor(task); inspector.innerHTML = `<div class="inspector-head"><span>任务详情</span><button class="icon-button" id="inspector-close" aria-label="关闭任务详情" title="关闭"><i data-lucide="x"></i></button></div><h2 class="inspector-title">${escape(task.title)}</h2><div class="inspector-course"><span class="course-dot" style="background:${course.color}"></span>${escape(task.course_name)} · ${escape(task.project)}</div><div class="inspector-block"><div class="field-grid"><dt>状态</dt><dd><span class="status-pill"><span class="status-dot ${task.status}"></span>${statuses[task.status]}</span></dd><dt>截止</dt><dd class="${overdue(task) ? 'due overdue' : ''}">${due(task)}${task.timezone_id ? `<br>${escape(task.timezone_id)}` : ''}</dd><dt>优先级</dt><dd>${priorities[task.priority]}</dd><dt>标签</dt><dd>${task.tags.map(escape).join(' · ')}</dd></div></div><div class="inspector-block"><h3>说明</h3><p>${escape(task.description)}</p></div><div class="inspector-block"><h3>进度 · ${task.progress_percent}%</h3><div class="progress-track"><i style="width:${task.progress_percent}%"></i></div>${task.subtasks.map((s, i) => `<label class="subtask"><input type="checkbox" data-subtask="${i}" ${s.done ? 'checked' : ''}>${escape(s.name)}</label>`).join('')}</div><div class="inspector-block"><h3>附件</h3><div class="field-grid"><dt>文件</dt><dd>${task.attachments.length ? escape(task.attachments[0].name) : '无附件'}</dd><dt>UUID</dt><dd>${task.uuid.slice(0, 18)}…</dd></div></div><div class="inspector-actions"><button class="secondary-button" id="advance-status"><i data-lucide="circle-dot-dashed"></i>推进状态</button><button class="primary-button" id="toggle-complete"><i data-lucide="check"></i>${task.status === 'done' ? '恢复任务' : '标记完成'}</button></div>`;
  $('#inspector-close').onclick = () => { state.inspector = false; render(); $('#detail-toggle').focus(); };
  $('#toggle-complete').onclick = () => mutate(() => setStatus(task, task.status === 'done' ? 'todo' : 'done'), `${task.title} 已${task.status === 'done' ? '恢复' : '完成'}`);
  $('#advance-status').onclick = () => mutate(() => setStatus(task, task.status === 'todo' ? 'in_progress' : task.status === 'in_progress' ? 'done' : 'todo'), `${task.title} 状态已更新`);
  inspector.querySelectorAll('[data-subtask]').forEach(input => input.onchange = () => mutate(() => { task.subtasks[Number(input.dataset.subtask)].done = input.checked; if (task.status === 'done' && !input.checked) task.status = 'in_progress'; setStatus(task, task.subtasks.every(s => s.done) ? 'done' : task.subtasks.some(s => s.done) ? 'in_progress' : 'todo'); }, `${task.title} 进度已更新`));
  $('#selection-status').textContent = `已选择：${task.title}`;
}

function bindRendered() {
  document.querySelectorAll('[data-task]').forEach(node => {
    node.addEventListener('click', event => { if (event.target.closest('[data-complete]')) return; setSelected(node.dataset.task); });
    node.addEventListener('dblclick', () => setSelected(node.dataset.task, true));
    node.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setSelected(node.dataset.task, event.key === 'Enter'); } });
  });
  document.querySelectorAll('[data-open]').forEach(button => button.onclick = event => { event.stopPropagation(); setSelected(button.dataset.open, true); });
  document.querySelectorAll('[data-complete]').forEach(check => check.onchange = () => { const task = tasks.find(t => t.id === Number(check.dataset.complete)); mutate(() => setStatus(task, check.checked ? 'done' : 'todo'), `${task.title} 已${check.checked ? '完成' : '恢复'}`); });
}
function render() { renderShell(); renderResults(); renderInspector(); bindRendered(); icons(); }

$('#scope-nav').addEventListener('click', event => { const button = event.target.closest('[data-scope]'); if (!button) return; state.scope = button.dataset.scope; state.course = 'all'; render(); announce(`已切换到${scopeNames[state.scope]}`); });
$('#course-nav').addEventListener('click', event => { const button = event.target.closest('[data-course]'); if (!button) return; state.course = button.dataset.course; state.scope = 'all'; render(); });
$('#view-tabs').addEventListener('click', event => { const tab = event.target.closest('[data-view]'); if (!tab) return; state.view = tab.dataset.view; render(); announce(`已切换到${tab.textContent.trim()}视图`); });
$('#view-tabs').addEventListener('keydown', event => { const tabs = views.map(v => v[0]); const index = tabs.indexOf(state.view); let next = null; if (event.key === 'ArrowRight') next = (index + 1) % tabs.length; if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length; if (event.key === 'Home') next = 0; if (event.key === 'End') next = tabs.length - 1; if (next !== null) { event.preventDefault(); state.view = tabs[next]; render(); $(`#tab-${state.view}`).focus(); } });
$('#query-form').addEventListener('submit', event => event.preventDefault());
$('#search').addEventListener('input', event => { state.query = event.target.value; renderResults(); renderInspector(); bindRendered(); icons(); });
$('#status-filter').onchange = event => { state.status = event.target.value; render(); };
$('#priority-filter').onchange = event => { state.priority = event.target.value; render(); };
$('#sort').onchange = event => { state.sort = event.target.value; render(); };
$('#clear').onclick = () => { Object.assign(state, { query: '', status: 'all', priority: 'all', course: 'all', scope: 'all', sort: 'due' }); render(); announce('已清除搜索和筛选'); };
$('#detail-toggle').onclick = () => { state.inspector = !state.inspector; render(); };
$('#reveal-selection').onclick = () => { Object.assign(state, { query: '', status: 'all', priority: 'all', course: 'all', scope: 'all' }); render(); requestAnimationFrame(() => document.querySelector(`[data-task="${state.selectedId}"]`)?.scrollIntoView({ block: 'center' })); };
$('#undo').onclick = () => { if (!undoSnapshot) return; tasks = undoSnapshot; undoSnapshot = null; $('#undo').disabled = true; render(); showToast('已撤销上一次修改'); };
$('#settings-open').onclick = () => $('#settings-dialog').showModal();
$('#settings-close').onclick = () => $('#settings-dialog').close();
$('#settings-dialog').addEventListener('click', event => { if (event.target === $('#settings-dialog')) $('#settings-dialog').close(); });
$('#reduce-motion').onchange = event => { state.manualReduce = event.target.checked; document.documentElement.classList.toggle('reduce-motion', state.manualReduce); render(); };
$('#display-mode').onchange = event => { state.display = event.target.value; render(); };
$('#dataset-size').onchange = event => { state.size = Number(event.target.value); tasks = makeTasks(state.size); state.selectedId = 1; render(); };
$('#reset-demo').onclick = () => { tasks = makeTasks(state.size); undoSnapshot = null; state.selectedId = 1; $('#settings-dialog').close(); render(); showToast('模拟数据已重置'); };
document.addEventListener('keydown', event => { const editable = ['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName); if (event.key === '/' && !editable) { event.preventDefault(); $('#search').focus(); } if (event.key === 'Escape' && state.inspector) { state.inspector = false; render(); } });
matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', () => { if (state.view === 'cover') render(); });
window.addEventListener('pagehide', disposeCover);
render();
