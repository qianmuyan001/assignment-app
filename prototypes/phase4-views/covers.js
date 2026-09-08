// Original bitmap facsimiles of sample submissions, not real attachments.
const cache = new Map();
export function coverCanvas(task) {
  const key = `${task.course_id}:${task.attachments.length > 0}`;
  if (cache.has(key)) return cache.get(key);
  const canvas = document.createElement('canvas');
  canvas.width = 480; canvas.height = 600;
  const ctx = canvas.getContext('2d');
  const accent = ['#21685b', '#3563a5', '#9b4a66', '#94601d'][task.course_id - 1];
  ctx.fillStyle = '#fcfdfc'; ctx.fillRect(0, 0, 480, 600);
  ctx.fillStyle = accent; ctx.fillRect(0, 0, 480, 12);
  ctx.font = '16px Segoe UI'; ctx.fillText(['DESIGN STUDIO', 'MATHEMATICS', 'PHYSICS LAB', 'DATA SCIENCE'][task.course_id - 1], 36, 55);
  ctx.font = 'bold 32px Segoe UI'; ctx.fillStyle = '#202822';
  ctx.fillText(['Campus wayfinding', 'Limits & continuity', 'Motion in practice', 'A city in motion'][task.course_id - 1], 36, 114);
  ctx.font = '16px Segoe UI'; ctx.fillStyle = '#666f68';
  ctx.fillText('AUTUMN 2026  /  ASSIGNMENT NOTES', 36, 146);
  if (!task.attachments.length) {
    ctx.strokeStyle = '#c8d0ca'; ctx.lineWidth = 2;
    ctx.strokeRect(150, 232, 180, 206);
    for (let i = 0; i < 5; i++) { ctx.beginPath(); ctx.moveTo(175, 275 + i * 27); ctx.lineTo(305, 275 + i * 27); ctx.stroke(); }
    ctx.font = '18px Segoe UI'; ctx.fillStyle = '#56625a'; ctx.fillText('No attachment', 178, 480);
  } else if (task.course_id === 1) {
    for (let j = 0; j < 3; j++) {
      const x = 36 + j * 143;
      ctx.fillStyle = ['#e2eee8', '#eef1e8', '#e6edf2'][j]; ctx.fillRect(x, 205, 125, 232);
      ctx.fillStyle = '#ffffff'; ctx.fillRect(x + 10, 225, 105, 177);
      ctx.fillStyle = accent; ctx.fillRect(x + 19, 242, 60, 9);
      ctx.strokeStyle = '#b8cac1'; ctx.lineWidth = 7;
      ctx.beginPath(); ctx.moveTo(x + 25, 280); ctx.lineTo(x + 85, 280); ctx.lineTo(x + 85, 343); ctx.lineTo(x + 40, 343); ctx.stroke();
      ctx.fillStyle = '#d59a44'; ctx.fillRect(x + 75, 333, 19, 19);
      ctx.fillStyle = accent; ctx.fillRect(x + 20, 374, 85, 12);
    }
  } else {
    ctx.fillStyle = '#f0f3f5'; ctx.fillRect(36, 204, 408, 252);
    ctx.strokeStyle = '#dce2e4'; ctx.lineWidth = 1;
    for (let y = 220; y < 440; y += 40) { ctx.beginPath(); ctx.moveTo(54, y); ctx.lineTo(426, y); ctx.stroke(); }
    for (let x = 54; x < 430; x += 40) { ctx.beginPath(); ctx.moveTo(x, 220); ctx.lineTo(x, 437); ctx.stroke(); }
    ctx.strokeStyle = accent; ctx.lineWidth = 4; ctx.beginPath();
    for (let x = 0; x < 360; x++) {
      const y = task.course_id === 2 ? 325 - Math.atan((x - 180) / 50) * 66 : task.course_id === 3 ? 328 - Math.sin(x / 40) * 65 : 407 - x * .4 - Math.sin(x / 33) * 24;
      if (!x) ctx.moveTo(x + 58, y); else ctx.lineTo(x + 58, y);
    }
    ctx.stroke();
    ctx.fillStyle = accent;
    for (let i = 0; i < 8; i++) ctx.fillRect(62 + i * 47, 490 - i % 3 * 10, 28, 28 + i % 3 * 10);
  }
  ctx.fillStyle = '#d3d9d5'; ctx.fillRect(36, 550, 408, 1);
  ctx.font = '14px Segoe UI'; ctx.fillStyle = '#69736c'; ctx.fillText('STUDY WORKSPACE', 36, 577); ctx.fillText('01', 419, 577);
  cache.set(key, canvas); return canvas;
}
export function coverURL(task) { return coverCanvas(task).toDataURL('image/png'); }
