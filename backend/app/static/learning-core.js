"use strict";
/* Shared pure presentation rules. Server remains authoritative for scheduling. */
const LearningCore = (() => {
  function dateKey(value, zone = Intl.DateTimeFormat().resolvedOptions().timeZone) {
    return new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(value);
  }
  function wallInstant(value, zone = Intl.DateTimeFormat().resolvedOptions().timeZone) {
    if (!value) return null;
    if (/[zZ]$|[+-]\d\d:\d\d$/.test(value)) return new Date(value);
    const parts = String(value).replace("T", " ").match(/^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)(?::(\d\d))?/);
    if (!parts) return null;
    const [year, month, day, hour, minute, second] = parts.slice(1).map(Number);
    const naive = Date.UTC(year, month - 1, day, hour, minute, second || 0);
    const normalized = new Date(naive);
    if (normalized.getUTCFullYear() !== year || normalized.getUTCMonth() !== month - 1 || normalized.getUTCDate() !== day || hour > 23 || minute > 59 || (second || 0) > 59) return null;
    let formatter;
    try { formatter = new Intl.DateTimeFormat("en-GB", { timeZone: zone || "UTC", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }); }
    catch { return null; }
    function represented(time) {
      const p = Object.fromEntries(formatter.formatToParts(new Date(time)).map(part => [part.type, part.value]));
      return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
    }
    const offsets = new Set([-2, -1, 0, 1, 2].map(days => { const sample = naive + days * 86400000; return represented(sample) - sample; }));
    const candidates = [...offsets].map(offset => naive - offset).filter(time => represented(time) === naive);
    return candidates.length ? new Date(Math.min(...candidates)) : null;
  }
  function dueInstant(task) {
    if (Object.prototype.hasOwnProperty.call(task, "due_at_utc")) {
      if (!task.due_at_utc) return null;
      const resolved = new Date(task.due_at_utc);
      return Number.isNaN(resolved.getTime()) ? null : resolved;
    }
    return wallInstant(task.due_date, task.timezone_id || Intl.DateTimeFormat().resolvedOptions().timeZone);
  }
  function matchesScope(task, scope, now = new Date(), zone) {
    const done = ["done", "completed"].includes(task.status);
    if (scope === "all") return true;
    if (scope === "completed") return done;
    const due = dueInstant(task);
    if (!due) return false;
    const today = dateKey(now, zone), date = dateKey(due, zone);
    if (scope === "today") return date === today;
    if (scope === "overdue") return !done && due < now;
    const start = new Date(`${today}T12:00:00Z`);
    start.setUTCDate(start.getUTCDate() - ((start.getUTCDay() + 6) % 7));
    const end = new Date(start); end.setUTCDate(end.getUTCDate() + 7);
    return date >= start.toISOString().slice(0, 10) && date < end.toISOString().slice(0, 10);
  }
  function progressPercent(task) {
    const progress = Number(task.progress_percent);
    return Number.isFinite(progress) ? Math.min(100, Math.max(0, progress)) : 0;
  }
  function reminderIsDue(reminder, from, now) {
    const instant = new Date(reminder.trigger_at_utc).getTime();
    return reminder.is_enabled && !reminder.disabled_reason && instant > from && instant <= now &&
      (!reminder.last_scheduled_at || new Date(reminder.last_scheduled_at).getTime() < instant);
  }
  function normalizePreferences(value = {}) {
    if (!value || typeof value !== "object") value = {};
    return { language: ["en", "zh-CN"].includes(value.language) ? value.language : "en", theme: ["system", "light", "dark"].includes(value.theme) ? value.theme : "system", mode: ["simple", "professional"].includes(value.mode) ? value.mode : "professional" };
  }
  return { dateKey, wallInstant, dueInstant, matchesScope, progressPercent, reminderIsDue, normalizePreferences };
})();
if (typeof module !== "undefined") module.exports = LearningCore;
