export const courses = [
  { id: 1, name: '交互设计', code: 'DES 204', color: '#21685b' },
  { id: 2, name: '高等数学', code: 'MAT 201', color: '#3563a5' },
  { id: 3, name: '大学物理', code: 'PHY 102', color: '#9b4a66' },
  { id: 4, name: '数据科学', code: 'DSC 301', color: '#94601d' },
];
export const statuses = { todo: '未开始', in_progress: '进行中', done: '已完成' };
export const priorities = { high: '高', medium: '中', low: '低' };
export const TODAY = '2026-08-31';
export const NOW = '2026-08-31 10:00:00';
export const views = [
  ['list', '列表', 'list'], ['calendar', '日历', 'calendar-days'],
  ['board', '看板', 'columns-3'], ['table', '表格', 'table-2'],
  ['gallery', '图库', 'layout-grid'], ['cover', 'Cover Flow', 'gallery-horizontal-end'],
];
const seeds = [
  ['校园导览 · 交互原型', 1, '2026-08-31 18:00:00', 'in_progress', 'high', 66],
  ['极限与连续 · 习题 03', 2, '2026-08-31 23:59:00', 'todo', 'high', 0],
  ['单摆实验 · 数据分析', 3, '2026-09-01 16:00:00', 'in_progress', 'medium', 33],
  ['城市出行 · 可视化报告', 4, '2026-09-02 12:00:00', 'in_progress', 'high', 66],
  ['界面系统 · 组件规范', 1, '2026-09-03 18:00:00', 'todo', 'medium', 0],
  ['线性代数 · 向量空间', 2, '2026-09-04 23:59:00', 'todo', 'medium', 0],
  ['电路实验 · 预习报告', 3, '2026-09-04 09:00:00', 'todo', 'high', 0],
  ['概率分布 · Notebook', 4, '2026-09-05 20:00:00', 'todo', 'low', 0],
  ['阅读笔记 · 设计心理学', 1, null, 'in_progress', 'low', 33],
  ['积分应用 · 小组作业', 2, '2026-09-07 15:00:00', 'todo', 'medium', 0],
  ['光学实验 · 误差讨论', 3, '2026-08-28 17:00:00', 'done', 'medium', 100],
  ['数据清洗 · 练习 02', 4, '2026-08-29 20:00:00', 'done', 'low', 100],
  ['可用性测试 · 访谈提纲', 1, '2026-09-01 00:00:00', 'todo', 'high', 0],
  ['微分方程 · 课堂测验', 2, '2026-09-08 10:00:00', 'todo', 'high', 0],
  ['热力学 · 章节总结', 3, null, 'todo', 'low', 0],
  ['回归模型 · 结果解释', 4, '2026-09-09 18:00:00', 'in_progress', 'medium', 66],
  ['信息架构 · 卡片分类', 1, '2026-08-30 18:00:00', 'todo', 'high', 0],
  ['数列 · 收敛性证明', 2, '2026-09-02 10:00:00', 'done', 'medium', 100],
  ['振动与波 · 习题 04', 3, '2026-09-11 16:00:00', 'todo', 'medium', 0],
  ['开放数据集 · 选题', 4, null, 'todo', 'low', 0],
  ['学期作品集 · 第一版', 1, '2026-09-15 18:00:00', 'in_progress', 'high', 33],
  ['函数图像 · 预习', 2, '2026-08-27 17:00:00', 'done', 'low', 100],
  ['期末实验 · 方案设计', 3, '2026-10-01 18:00:00', 'todo', 'medium', 0],
  ['研究笔记_very_long_unbroken_filename_2026_final_revision', 4, '2026-09-06 20:00:00', 'todo', 'low', 0],
];
export function makeTasks(count = 24) {
  return Array.from({ length: count }, (_, i) => {
    const [title, course_id, due_date, status, priority, progress_percent] = seeds[i % seeds.length];
    const suffix = String(i + 1).padStart(12, '0');
    return {
      id: i + 1, uuid: `00000000-0000-4000-8000-${suffix}`, course_id, project_id: course_id,
      course_name: courses[course_id - 1].name, title: title + (i >= 24 ? ` #${i + 1}` : ''),
      due_date, status, priority, progress_percent, completed_at: status === 'done' ? '2026-08-28T08:00:00Z' : null,
      all_day: i % 24 === 12, timezone_id: i % 24 === 23 ? 'America/Los_Angeles' : null,
      description: ['整理研究发现，完成主要流程与交互细节。提交可点击原型与关键页面说明。', '写出完整推导过程，标注关键条件。完成后检查计算结果。', '记录原始实验数据，分析误差来源，给出实验结论。', '整理数据来源，生成图表，并说明结果与局限。'][course_id - 1],
      link: null, created_at: '2026-08-25T08:00:00Z', updated_at: '2026-08-28T08:00:00Z', deleted_at: null,
      tags: ['作业', ['设计', '推导', '实验', '报告'][course_id - 1]],
      project: ['校园导览', '基础习题', '实验记录', '城市研究'][course_id - 1],
      attachments: i % 5 === 4 ? [] : [{ name: ['交互稿.png', '解题草稿.pdf', '实验记录.png', '分析图表.png'][course_id - 1], type: course_id === 2 ? 'pdf' : 'image' }],
      subtasks: ['准备材料', '完成初稿', '复核与提交'].map((name, n) => ({ name, done: status === 'done' || n < Math.round(progress_percent / 33) })),
    };
  });
}
export function matchesScope(t, scope) {
  const day = t.due_date?.slice(0, 10);
  if (scope === 'today') return day === TODAY;
  if (scope === 'week') return day >= TODAY && day < '2026-09-07';
  if (scope === 'overdue') return !!t.due_date && t.status !== 'done' && t.due_date < (t.all_day ? `${TODAY} 00:00:00` : NOW);
  if (scope === 'completed') return t.status === 'done';
  return true;
}
export function compareTasks(a, b, sort = 'due') {
  if (sort === 'priority') {
    const rank = { high: 0, medium: 1, low: 2 };
    const p = rank[a.priority] - rank[b.priority];
    if (p) return p;
  }
  const d = (a.due_date || '9999').localeCompare(b.due_date || '9999');
  return d || a.uuid.localeCompare(b.uuid);
}
export function queryTasks(tasks, state) {
  const q = state.query.trim().toLocaleLowerCase();
  return tasks.filter(t => !t.deleted_at && matchesScope(t, state.scope)
    && (state.course === 'all' || t.course_id === Number(state.course))
    && (state.status === 'all' || t.status === state.status)
    && (state.priority === 'all' || t.priority === state.priority)
    && (!q || [t.title, t.course_name, t.description].some(s => s?.toLocaleLowerCase().includes(q))))
    .sort((a, b) => compareTasks(a, b, state.sort));
}
export function setStatus(task, status) {
  task.status = status;
  task.completed_at = status === 'done' ? '2026-08-31T02:00:00Z' : null;
  if (status === 'done') task.subtasks.forEach(s => { s.done = true; });
  task.progress_percent = status === 'done' ? 100 : Math.min(99, Math.floor(task.subtasks.filter(s => s.done).length / task.subtasks.length * 100));
  task.updated_at = '2026-08-31T02:00:00Z';
}
