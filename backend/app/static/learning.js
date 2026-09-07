"use strict";
const learning = {
  view: "tasks", generation: 0, month: new Date(new Date().getFullYear(), new Date().getMonth(), 1),
  timetableMode: "week", week: LearningCore.dateKey(new Date()), course: "", weekday: "", showDeleted: false,
  examStatus: "", examCourse: "", showDeletedExams: false,
};
const weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const learningRoot = document.querySelector("#view-learning");
const browserZone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function translated(tag, text, className) { return element(tag, tr(text), className); }
function actionButton(text, action, className = "secondary-button") {
  const button = translated("button", text, className); button.type = "button";
  button.addEventListener("click", () => runAction(button, action)); return button;
}
async function runAction(button, action) {
  if (button.disabled) return;
  button.disabled = true;
  try { await action(); } catch (error) { announce(error.message, true); }
  finally { button.disabled = false; }
}
function announce(message, error = false) {
  const notice = document.querySelector("#workspace-notice");
  notice.textContent = message; notice.hidden = false; notice.classList.toggle("has-error", error); notice.setAttribute("role", error ? "alert" : "status");
}
function empty(parent, message = "Nothing here yet.") { parent.append(translated("p", message, "empty-message")); }
function jsonOptions(method, payload) { return { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) }; }
function dateLabel(instant, options = {}) {
  return instant ? new Intl.DateTimeFormat(localeName(), { dateStyle: "medium", timeStyle: "short", ...options }).format(new Date(instant)) : tr("No due date");
}
function warningList(parent, warnings = []) {
  if (!warnings.length) return;
  const list = element("ul", null, "warning-list"); list.setAttribute("aria-label", tr("Warnings"));
  warnings.forEach(warning => {
    const message = typeof warning === "string" ? warning : warning.message;
    const localized = preferences.language === "zh-CN" && /overlap/i.test(warning.code || message) ? "课程时间重叠；记录已保留，请自行调整。" : message;
    list.append(element("li", localized));
  }); parent.append(list);
}
function labeledField(name, label, type = "text", value = "", required = false) {
  const wrapper = translated("label", label);
  const input = element(type === "textarea" ? "textarea" : "input");
  if (type !== "textarea") input.type = type;
  input.name = name; input.value = value ?? ""; input.required = required;
  if (type === "textarea") input.rows = 3;
  wrapper.append(input); return { wrapper, input };
}
function selectField(name, label, options, value = "") {
  const wrapper = translated("label", label), input = element("select"); input.name = name;
  options.forEach(([key, text]) => input.append(createOption(String(key), ["course_id","exam-course","meeting-course"].includes(name) && key !== "" ? text : tr(text))));
  input.value = value; wrapper.append(input); return { wrapper, input };
}
function checkboxField(name, label, checked) {
  const field = labeledField(name, label, "checkbox"); field.wrapper.className = "check-field"; field.input.checked = checked; return field;
}
function filterSelect(toolbar, name, label, options, value, update) {
  const field = selectField(name, label, options, value); field.input.addEventListener("change", () => { update(field.input.value); renderLearning(); }); toolbar.append(field.wrapper); return field;
}
function pageHeading(title, subtitle) {
  const header = element("header", null, "learning-heading"), texts = element("div");
  texts.append(translated("h2", title)); if (subtitle) texts.append(translated("p", subtitle, "muted"));
  header.append(texts); return header;
}
function selectTask(id) {
  clearFilters(); state.selectedId = id; applyFilters(); changeView("tasks");
  state.detailExpanded = true; renderDetail(); dom.selectedDetail.scrollIntoView({ block: "nearest", behavior: "instant" });
  dom.coverFlow.focus();
}
function taskRow(task) {
  const item = element("li", null, "learning-row"), copy = element("div", null, "row-copy");
  copy.append(element("strong", task.title), element("span", `${task.course_name || tr("No course")} · ${dateLabel(LearningCore.dueInstant(task))}`, "muted"));
  item.append(copy, actionButton("Open task", () => selectTask(task.id))); return item;
}
function taskSection(title, tasks) {
  const section = element("section", null, "overview-section"); section.append(translated("h3", title));
  const list = element("ul", null, "learning-list"); tasks.forEach(task => list.append(taskRow(task))); section.append(list);
  if (!tasks.length) empty(section); return section;
}
function changeView(view, focus = true) {
  if (!["tasks", "today", "calendar", "timetable", "exams", "settings"].includes(view)) view = "tasks";
  learning.view = view; history.replaceState(null, "", `#${view}`);
  document.querySelectorAll("[data-view]").forEach(button => {
    if (button.dataset.view === view) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
  });
  document.querySelector("#view-tasks").hidden = view !== "tasks"; learningRoot.hidden = view === "tasks";
  if (view !== "tasks") renderLearning();
  if (focus) (view === "tasks" ? document.querySelector("#view-tasks") : learningRoot).focus({ preventScroll: true });
}
async function renderLearning() {
  if (learning.view === "tasks") return;
  const generation = ++learning.generation, view = learning.view;
  learningRoot.replaceChildren(translated("p", "Loading…", "empty-message")); learningRoot.setAttribute("aria-busy", "true");
  const content = element("div", null, "learning-content");
  try {
    const renderers = { today: renderToday, calendar: renderCalendar, timetable: renderTimetable, exams: renderExams, settings: renderSettings };
    await renderers[view](content);
    if (generation === learning.generation) learningRoot.replaceChildren(content);
  } catch (error) {
    if (generation !== learning.generation) return;
    content.replaceChildren(pageHeading(view.charAt(0).toUpperCase() + view.slice(1)), element("p", error.message, "view-error"), actionButton("Retry", renderLearning));
    content.querySelector(".view-error").setAttribute("role", "alert"); learningRoot.replaceChildren(content);
  } finally { if (generation === learning.generation) learningRoot.setAttribute("aria-busy", "false"); }
}
async function renderToday(parent) {
  const overview = await apiRequest(`/overview/today?timezone_id=${encodeURIComponent(browserZone)}`);
  const heading = pageHeading("Today", "Your day, at a glance."); heading.append(actionButton("Quick add", openDialog, "primary-button")); parent.append(heading);
  parent.append(element("p", `${overview.date} · ${overview.timezone_id}`, "muted")); warningList(parent, overview.warnings);
  const grid = element("div", null, "overview-grid"), meetings = element("section", null, "overview-section"); meetings.append(translated("h3", "Today's classes"));
  const list = element("ul", null, "learning-list"); overview.meetings.forEach(meeting => list.append(meetingRow(meeting, false))); meetings.append(list);
  if (!overview.meetings.length) empty(meetings, "No classes scheduled.");
  const exams = element("section", null, "overview-section"); exams.append(translated("h3", "Upcoming exams"));
  const examList = element("ul", null, "learning-list"); overview.upcoming_exams.forEach(exam => examList.append(examRow(exam, false))); exams.append(examList);
  if (!overview.upcoming_exams.length) empty(exams, "No exams scheduled.");
  grid.append(meetings, exams, taskSection("Due today tasks", overview.due_today), taskSection("Overdue tasks", overview.overdue)); parent.append(grid);
}
async function renderCalendar(parent) {
  const [tasks, exams] = await Promise.all([apiRequest("/assignments"), apiRequest("/exams")]);
  const heading = pageHeading("Calendar", "Task deadlines and exams"), controls = element("div", null, "view-actions");
  controls.append(actionButton("Previous month", () => { learning.month.setMonth(learning.month.getMonth() - 1); renderLearning(); }), actionButton("Current month", () => { learning.month = new Date(new Date().getFullYear(), new Date().getMonth(), 1); renderLearning(); }), actionButton("Next month", () => { learning.month.setMonth(learning.month.getMonth() + 1); renderLearning(); })); heading.append(controls); parent.append(heading);
  parent.append(element("h3", learning.month.toLocaleDateString(localeName(), { year: "numeric", month: "long" })));
  const events = tasks.filter(task => LearningCore.dueInstant(task)).map(task => ({ title: task.title, day: LearningCore.dateKey(LearningCore.dueInstant(task)), kind: "Task", time: LearningCore.dueInstant(task), open: () => selectTask(task.id) }));
  exams.filter(exam => exam.starts_at_utc).forEach(exam => events.push({ title: exam.name, day: LearningCore.dateKey(new Date(exam.starts_at_utc)), kind: "Exam", time: new Date(exam.starts_at_utc), open: () => openLearningEditor("exam", exam) }));
  const grid = element("div", null, "calendar-grid"); grid.setAttribute("aria-label", tr("Calendar"));
  weekdays.forEach(day => grid.append(translated("div", day, "calendar-weekday")));
  const year = learning.month.getFullYear(), month = learning.month.getMonth(), offset = (new Date(year, month, 1).getDay() + 6) % 7, count = new Date(year, month + 1, 0).getDate();
  for (let i = 0; i < offset; i++) { const gap = element("div", null, "calendar-gap"); gap.setAttribute("aria-hidden", "true"); grid.append(gap); }
  const monthEvents = [];
  for (let day = 1; day <= count; day++) {
    const key = `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`, cell = element("div", null, "calendar-day");
    if (key === LearningCore.dateKey(new Date())) cell.classList.add("is-today");
    const number = element("time", String(day)); number.dateTime = key; cell.append(number);
    const items = events.filter(event => event.day === key).sort((a, b) => a.time - b.time); monthEvents.push(...items);
    items.forEach(event => { const button = actionButton(`${tr(event.kind)} · ${event.title}`, event.open, `calendar-event ${event.kind.toLowerCase()}`); button.setAttribute("aria-label", `${key} ${tr(event.kind)} ${event.title}`); cell.append(button); });
    if (items.length) cell.append(element("span", String(items.length), "calendar-count"));
    grid.append(cell);
  }
  parent.append(grid);
  const agenda = element("section", null, "calendar-agenda"); agenda.append(translated("h3", "Task deadlines and exams"));
  const agendaList = element("ul", null, "learning-list"); monthEvents.forEach(event => { const row = element("li", null, "learning-row"), copy = element("div", null, "row-copy"); copy.append(element("strong", event.title), element("span", `${tr(event.kind)} · ${dateLabel(event.time)}`, "muted")); row.append(copy, actionButton("Open", event.open)); agendaList.append(row); }); agenda.append(agendaList); parent.append(agenda);
  if (!monthEvents.length) empty(parent, "No events this month.");
}
function courseName(item) { return item.course_name || state.courses.find(course => course.id === item.course_id)?.name || tr("No course"); }
function meetingRow(meeting, editable = true) {
  const item = element("li", null, "learning-row"), copy = element("div", null, "row-copy");
  copy.append(element("strong", courseName(meeting)), element("span", `${meeting.start_time_local.slice(0,5)}–${meeting.end_time_local.slice(0,5)} · ${meeting.timezone_id}`, "muted"));
  if (meeting.location || meeting.teacher_override) copy.append(element("span", [meeting.location, meeting.teacher_override].filter(Boolean).join(" · "), "muted"));
  if (meeting.deleted_at) copy.append(translated("span", "Deleted", "deleted-label")); warningList(copy, meeting.warnings); item.append(copy);
  if (editable) item.append(recordActions("meeting", meeting)); return item;
}
function recordActions(kind, item) {
  const actions = element("div", null, "row-actions"), path = kind === "meeting" ? "/course-meetings" : "/exams";
  if (item.deleted_at) actions.append(actionButton("Restore", async () => { await apiRequest(`${path}/${item.id}/restore`, { method: "POST" }); announce(tr("Restored.")); await renderLearning(); }));
  else actions.append(actionButton("Edit", () => openLearningEditor(kind, item)), actionButton("Delete", async () => {
    if (!confirm(tr(kind === "exam" ? "Delete exam? Its review task will be kept." : "Delete this item? You can restore it from Show deleted."))) return;
    await apiRequest(`${path}/${item.id}`, { method: "DELETE" }); announce(tr("Deleted.")); await renderLearning();
  }, "delete-button")); return actions;
}
async function renderTimetable(parent) {
  const query = new URLSearchParams({ include_deleted: String(learning.showDeleted), timezone_id: browserZone });
  query.set(learning.timetableMode === "today" ? "on_date" : "week_start", learning.timetableMode === "today" ? LearningCore.dateKey(new Date()) : learning.week);
  if (learning.course) query.set("course_id", learning.course); if (learning.weekday) query.set("weekday", learning.weekday);
  const [meetings, courses] = await Promise.all([apiRequest(`/course-meetings?${query}`), apiRequest("/courses")]); state.courses = courses;
  const heading = pageHeading("Timetable"); heading.append(actionButton("Add meeting", () => openLearningEditor("meeting"), "primary-button")); parent.append(heading);
  const toolbar = element("div", null, "view-filters");
  filterSelect(toolbar, "timetable-mode", "Timetable", [["week", "Week view"], ["today", "Today view"]], learning.timetableMode, value => learning.timetableMode = value);
  const week = labeledField("week", "Week of", "date", learning.week, true); week.input.disabled = learning.timetableMode === "today"; week.input.addEventListener("change", () => { if (week.input.value) { learning.week = week.input.value; renderLearning(); } }); toolbar.append(week.wrapper);
  filterSelect(toolbar, "meeting-course", "Course", [["", "all courses"], ...courses.map(course => [course.id, course.name])], learning.course, value => learning.course = value);
  filterSelect(toolbar, "meeting-weekday", "Weekday", [["", "All"], ...weekdays.map((day, index) => [index + 1, day])], learning.weekday, value => learning.weekday = value);
  const deleted = checkboxField("deleted-meetings", "Show deleted", learning.showDeleted); deleted.input.addEventListener("change", () => { learning.showDeleted = deleted.input.checked; renderLearning(); }); toolbar.append(deleted.wrapper); parent.append(toolbar);
  if (!courses.length) { empty(parent, "Create a course first, then add a meeting."); parent.append(actionButton("Manage courses", openOrgDialog)); }
  if (!meetings.length) { empty(parent, "No classes scheduled."); return; }
  const weekView = element("div", null, "timetable-week");
  weekdays.forEach((day, index) => {
    const items = meetings.filter(meeting => meeting.weekday === index + 1); if (!items.length && learning.timetableMode === "today") return;
    const section = element("section", null, "timetable-day"); section.append(translated("h3", day));
    const list = element("ul", null, "learning-list"); items.forEach(meeting => list.append(meetingRow(meeting))); section.append(list);
    if (!items.length) empty(section, "No classes scheduled."); weekView.append(section);
  }); parent.append(weekView);
}
function examRow(exam, editable = true) {
  const row = element("li", null, "learning-row"), copy = element("div", null, "row-copy");
  copy.append(element("strong", exam.name), element("span", `${courseName(exam)} · ${exam.starts_at_local} · ${exam.timezone_id}`, "muted"));
  if (exam.location) copy.append(element("span", exam.location, "muted"));
  copy.append(element("span", tr(exam.deleted_at ? "Deleted" : exam.status), "status-label")); warningList(copy, exam.warnings); row.append(copy);
  if (editable) {
    const actions = recordActions("exam", exam);
    if (!exam.deleted_at) actions.prepend(actionButton(exam.linked_assignment_id ? "Open review task" : "Create review task", async () => {
      const result = await apiRequest(`/exams/${exam.id}/review-task`, { method: "POST" }); await loadAssignments(); announce(tr("Review task ready.")); selectTask(result.assignment.id);
    })); row.append(actions);
  } return row;
}
async function renderExams(parent) {
  const query = new URLSearchParams({ include_deleted: String(learning.showDeletedExams) }); if (learning.examCourse) query.set("course_id", learning.examCourse); if (learning.examStatus) query.set("status", learning.examStatus);
  const [exams, courses] = await Promise.all([apiRequest(`/exams?${query}`), apiRequest("/courses")]); state.courses = courses;
  const heading = pageHeading("Exams"); heading.append(actionButton("Add exam", () => openLearningEditor("exam"), "primary-button")); parent.append(heading);
  const toolbar = element("div", null, "view-filters"); filterSelect(toolbar, "exam-course", "Course", [["", "all courses"], ...courses.map(course => [course.id, course.name])], learning.examCourse, value => learning.examCourse = value);
  filterSelect(toolbar, "exam-status", "Status", [["", "All"], ...["upcoming", "completed", "cancelled"].map(status => [status,status])], learning.examStatus, value => learning.examStatus = value);
  const deleted = checkboxField("deleted-exams", "Show deleted", learning.showDeletedExams); deleted.input.addEventListener("change", () => { learning.showDeletedExams = deleted.input.checked; renderLearning(); }); toolbar.append(deleted.wrapper); parent.append(toolbar);
  const list = element("ul", null, "learning-list"); exams.forEach(exam => list.append(examRow(exam))); parent.append(list); if (!exams.length) empty(parent, "No exams scheduled.");
  if (!courses.length) parent.append(actionButton("Manage courses", openOrgDialog));
}
async function openLearningEditor(kind, record = null) {
  const courses = await apiRequest("/courses");
  if (!courses.length) { announce(tr("Create a course first, then add a meeting.")); openOrgDialog(); return; }
  const dialog = element("dialog", null, "learning-dialog"), heading = element("div", null, "dialog-header"), title = translated("h2", `${record ? "Edit" : "Add"} ${kind === "exam" ? "exam" : "meeting"}`); title.id = "learning-editor-title"; dialog.setAttribute("aria-labelledby", title.id);
  heading.append(title, actionButton("Close", () => dialog.close())); dialog.append(heading);
  const form = element("form", null, "learning-form"), fields = {};
  function add(name, label, type, value, required = false) { const field = labeledField(name, label, type, value, required); fields[name] = field.input; form.append(field.wrapper); return field.input; }
  const course = selectField("course_id", "Course", courses.map(item => [item.id,item.name]), record?.course_id || courses[0].id); fields.course_id = course.input; form.append(course.wrapper);
  if (kind === "meeting") {
    const weekday = selectField("weekday", "Weekday", weekdays.map((day,index) => [index + 1,day]), record?.weekday || ((new Date().getDay() + 6) % 7) + 1); fields.weekday = weekday.input; form.append(weekday.wrapper);
    add("start_time_local", "Start time", "time", record?.start_time_local || "09:00", true);
    add("end_time_local", "End time", "time", record?.end_time_local || "10:00", true);
    add("effective_start_date", "Effective from", "date", record?.effective_start_date || LearningCore.dateKey(new Date()), true);
    add("effective_end_date", "Effective until", "date", record?.effective_end_date || "");
    add("teacher_override", "Teacher override", "text", record?.teacher_override || "");
  } else {
    add("name", "Title", "text", record?.name || "", true);
    add("starts_at_local", "Starts at", "datetime-local", record?.starts_at_local?.replace(" ","T").slice(0,16) || "", true);
    const status = selectField("status", "Status", ["upcoming","completed","cancelled"].map(value => [value,value]), record?.status || "upcoming"); fields.status = status.input; form.append(status.wrapper);
    add("scope", "Scope", "textarea", record?.scope || ""); add("notes", "Notes", "textarea", record?.notes || "");
  }
  add("timezone_id", "Time zone", "text", record?.timezone_id || browserZone, true); add("location", "Location", "text", record?.location || "");
  const error = element("p", null, "form-error"); error.setAttribute("role", "alert"); error.hidden = true; form.append(error);
  const buttons = element("div", null, "view-actions full-width"), save = translated("button", "Save", "primary-button"); save.type = "submit"; buttons.append(save, actionButton("Cancel", () => dialog.close())); form.append(buttons);
  form.addEventListener("submit", async event => {
    event.preventDefault(); if (save.disabled) return; save.disabled = true; error.hidden = true;
    try {
      const payload = Object.fromEntries(Object.entries(fields).map(([name,input]) => [name, input.value.trim() || null])); payload.course_id = Number(payload.course_id);
      if (kind === "meeting") { payload.weekday = Number(payload.weekday); ["start_time_local", "end_time_local"].forEach(name => { if (payload[name].length === 5) payload[name] += ":00"; }); }
      else { payload.starts_at_local = payload.starts_at_local.replace("T", " "); if (payload.starts_at_local.length === 16) payload.starts_at_local += ":00"; }
      const path = kind === "meeting" ? "/course-meetings" : "/exams";
      const result = await apiRequest(`${path}${record ? `/${record.id}` : ""}`, jsonOptions(record ? "PATCH" : "POST", payload));
      dialog.close(); announce(tr(result.warnings?.length ? "Saved. Schedule warnings are shown below." : "Saved.")); await renderLearning();
    } catch (failure) { error.textContent = failure.message; error.hidden = false; error.tabIndex = -1; error.focus(); }
    finally { save.disabled = false; }
  });
  dialog.append(form); dialog.addEventListener("close", () => dialog.remove(), { once: true }); document.body.append(dialog); dialog.showModal(); (fields.name || fields.course_id).focus();
}
async function renderSettings(parent) {
  const [backups, info] = await Promise.all([apiRequest("/backups"), apiRequest("/app-info")]);
  parent.append(pageHeading("Settings"));
  const preferenceSection = element("section", null, "settings-section"); preferenceSection.append(translated("h3", "Preferences"));
  const controls = element("div", null, "settings-controls");
  const choices = {
    language: ["Language", [["en","English"],["zh-CN","简体中文"]]],
    theme: ["Theme", [["system","System"],["light","Light"],["dark","Dark"]]],
    mode: ["Mode", [["simple","Simple"],["professional","Professional"]]],
  };
  Object.entries(choices).forEach(([key,[label,options]]) => {
    const field = selectField(`preference-${key}`, label, options, preferences[key]);
    field.input.addEventListener("change", () => {
      preferences[key] = field.input.value;
      try { localStorage.setItem("assignment.preferences", JSON.stringify(preferences)); }
      catch (error) { announce(error.message, true); return; }
      applyPreferences(); if (key === "language") location.reload();
    }); controls.append(field.wrapper);
  }); preferenceSection.append(controls, translated("p", "Simple mode hides advanced fields and preserves their values.", "muted"), translated("p", "Application-open reminders only. Keep this page open; browser background throttling can delay delivery.", "muted")); parent.append(preferenceSection);
  const backupSection = element("section", null, "settings-section"); backupSection.append(translated("h3", "Backup center"), translated("p", "SQLite snapshots include attachments; imports are validated before confirmation.", "muted"));
  backupSection.append(actionButton("Create backup", async () => { await apiRequest("/backups", { method: "POST" }); announce(tr("Backup ready.")); await renderLearning(); }, "primary-button"));
  const list = element("ul", null, "learning-list backup-list");
  backups.forEach(backup => {
    const row = element("li", null, "learning-row"), copy = element("div", null, "row-copy");
    copy.append(element("strong", backup.filename || backup.id), element("span", `${dateLabel(backup.created_at)} · ${formatBytes(backup.size)}`, "muted"));
    const link = translated("a", "Download", "download-link"); link.href = `/backups/${encodeURIComponent(backup.id)}/download`; link.download = backup.filename || "backup.zip"; row.append(copy, link); list.append(row);
  }); backupSection.append(list); if (!backups.length) empty(backupSection, "No backups yet.");
  const importForm = element("form", null, "backup-import"), fileField = labeledField("backup-file", "Import backup", "file"); fileField.input.accept = ".zip,application/zip"; fileField.input.required = true;
  const check = translated("button", "Check backup", "secondary-button"); check.type = "submit";
  const preview = element("div", null, "backup-preview"); preview.setAttribute("aria-live", "polite");
  fileField.input.addEventListener("change", () => preview.replaceChildren());
  importForm.append(fileField.wrapper, check); backupSection.append(importForm, preview);
  importForm.addEventListener("submit", async event => {
    event.preventDefault(); if (check.disabled) return;
    const file = fileField.input.files[0]; if (!file) { announce(tr("Choose a ZIP backup first."), true); return; }
    check.disabled = true; preview.replaceChildren(translated("p", "Loading…"));
    try {
      const result = await apiRequest("/backups/preflight", { method: "POST", headers: { "Content-Type": "application/zip" }, body: file });
      preview.replaceChildren(translated("p", "Backup checked. Review the contents before restoring."));
      const summary = element("dl", null, "backup-summary");
      function summaryItem(label,value) { summary.append(translated("dt",label),element("dd",String(value))); }
      summaryItem("Schema version", result.summary.schema_version); summaryItem("Attachment count", result.summary.attachment_count);
      Object.entries(result.summary.counts || {}).forEach(([key,value]) => summaryItem(({ assignments:"Tasks", courses:"Courses", course_meetings:"Timetable", exams:"Exams", projects:"Projects", tags:"Tags", subtasks:"Subtasks", reminders:"Reminders" })[key] || key, value));
      preview.append(summary); warningList(preview,result.warnings); preview.append(translated("p", "Restore replaces current data and attachments. Confirm only after reviewing this backup."));
      const confirmation = checkboxField("restore-confirmation", "I confirm replacing current data and attachments.", false);
      const restore = actionButton("Restore backup", async () => {
        if (!confirmation.input.checked) return;
        await apiRequest("/backups/restore", jsonOptions("POST", { token: result.token, confirm: true }));
        announce(tr("Restore completed.")); state.lastOrgAssignmentId = null; await loadAssignments(); await renderLearning();
      }, "delete-button"); restore.disabled = true;
      confirmation.input.addEventListener("change", () => restore.disabled = !confirmation.input.checked); preview.append(confirmation.wrapper,restore);
    } catch (error) { preview.replaceChildren(element("p", error.message, "view-error")); preview.firstChild.setAttribute("role", "alert"); }
    finally { check.disabled = false; }
  }); parent.append(backupSection);
  const about = element("section", null, "settings-section"); about.append(translated("h3", "About"), element("p", `Assignment App · ${tr("Version")} ${info.version}`), translated("p", "This workspace uses Schema v4.", "muted"));
  const details = element("details"), summary = translated("summary", "Changelog"), entries = element("ul", null, "changelog");
  (info.changelog || []).forEach(entry => entries.append(element("li", typeof entry === "string" ? entry : entry.title || entry.text || JSON.stringify(entry)))); details.append(summary,entries); about.append(details); parent.append(about);
}
async function renderV4Reminders(view, assignment) {
  const { list, form } = view.orgReminders;
  list.replaceChildren(translated("li", "Loading…", "empty-message"));
  try {
    const reminders = await apiRequest(`/assignments/${assignment.id}/reminders`);
    list.replaceChildren(); if (!reminders.length) list.append(translated("li", "No reminders yet.", "empty-message"));
    reminders.forEach(reminder => {
      const row = element("li", null, "learning-row"), copy = element("div", null, "row-copy");
      copy.append(translated("strong", reminder.schedule_kind === "due_relative" ? "Relative to deadline" : "Fixed time"), element("span", dateLabel(reminder.trigger_at_utc), "muted"));
      if (reminder.schedule_kind === "due_relative") copy.append(element("span", `${tr("Minutes before deadline")}: ${reminder.lead_minutes}`, "muted"));
      copy.append(translated("span", reminder.is_enabled ? "Enabled" : "Disabled", "muted"));
      if (reminder.disabled_reason) copy.append(element("span", reminder.disabled_reason === "missing_due_date" ? tr("Relative reminder disabled: task has no due date.") : tr(reminder.disabled_reason), "form-error"));
      const actions = element("div", null, "row-actions");
      actions.append(actionButton(reminder.is_enabled ? "Disable" : "Enable", async () => { await apiRequest(`/assignments/${assignment.id}/reminders/${reminder.id}`, jsonOptions("PATCH", { is_enabled: !reminder.is_enabled })); await renderV4Reminders(view,assignment); }), actionButton("Delete", async () => { if (!confirm(tr("Delete this item?"))) return; await apiRequest(`/assignments/${assignment.id}/reminders/${reminder.id}`, { method:"DELETE" }); await renderV4Reminders(view,assignment); }, "delete-button")); row.append(copy,actions); list.append(row);
    });
  } catch (error) { const message = element("li", error.message, "view-error"); message.setAttribute("role","alert"); list.replaceChildren(message, actionButton("Retry", () => renderV4Reminders(view,assignment))); }
  form.replaceChildren(); form.classList.add("reminder-form");
  const kind = selectField("schedule_kind", "Reminder type", [["fixed","Fixed time"],["due_relative","Relative to deadline"]], "fixed"), trigger = labeledField("trigger_at_utc", "Trigger time", "datetime-local", "", true), lead = labeledField("lead_minutes", "Minutes before deadline", "number", "15"); lead.input.min = "0"; lead.input.step = "1"; lead.wrapper.hidden = true;
  const hint = translated("p", "Application-open reminders only. Keep this page open; browser background throttling can delay delivery.", "muted full-width"), error = element("p", null, "form-error full-width"); error.setAttribute("role", "alert");
  const add = translated("button", "Add", "primary-button"); add.type = "submit";
  kind.input.addEventListener("change", () => {
    const relative = kind.input.value === "due_relative"; lead.wrapper.hidden = !relative; lead.input.required = relative; trigger.wrapper.hidden = relative; trigger.input.required = !relative;
    const unavailable = relative && !assignment.due_date; add.disabled = unavailable; error.textContent = unavailable ? tr("A due date is required for relative reminders.") : "";
  });
  form.append(kind.wrapper,trigger.wrapper,lead.wrapper,add,hint,error);
  form.onsubmit = async event => {
    event.preventDefault(); if (add.disabled) return; add.disabled = true; error.textContent = "";
    try {
      const payload = { schedule_kind: kind.input.value, lead_minutes: kind.input.value === "due_relative" ? Number(lead.input.value) : 0, is_enabled: true };
      if (kind.input.value === "fixed") payload.trigger_at_utc = toUtcIso(trigger.input.value);
      await apiRequest(`/assignments/${assignment.id}/reminders`, jsonOptions("POST",payload)); await renderV4Reminders(view,assignment);
    } catch (failure) { error.textContent = failure.message; } finally { add.disabled = false; }
  };
}
let lastReminderScan = Date.now(), reminderScanRunning = false;
const shownReminders = new Set();
async function checkOpenReminders() {
  if (reminderScanRunning || document.hidden) return;
  reminderScanRunning = true;
  const now = Date.now(), from = lastReminderScan;
  try {
    const active = state.all.filter(task => normalizeStatus(task.status) !== "done" && !task.deleted_at);
    const result = await Promise.all(active.map(async task => ({ task, reminders: await apiRequest(`/assignments/${task.id}/reminders`) })));
    const due = [], delivered = [];
    result.forEach(({task,reminders}) => reminders.forEach(reminder => {
      const key = `${reminder.id}:${reminder.trigger_at_utc}`, instant = new Date(reminder.trigger_at_utc).getTime();
      if (reminder.is_enabled && instant > from && instant <= now && (!reminder.last_scheduled_at || new Date(reminder.last_scheduled_at).getTime() < instant) && !shownReminders.has(key)) { due.push(task.title); shownReminders.add(key); delivered.push({task,reminder}); }
    }));
    if (due.length) announce(`${tr("Reminder")}: ${due.join(" · ")}`);
    await Promise.all(delivered.map(({task,reminder}) => apiRequest(`/assignments/${task.id}/reminders/${reminder.id}`, jsonOptions("PATCH", {last_scheduled_at: new Date(now).toISOString()}))));
    lastReminderScan = now;
  } catch (error) { announce(error.message,true); } finally { reminderScanRunning = false; }
}
document.querySelectorAll("[data-view]").forEach(button => button.addEventListener("click", () => changeView(button.dataset.view)));
document.querySelectorAll("[data-scope]").forEach(button => button.addEventListener("click", () => { state.scope = button.dataset.scope; document.querySelectorAll("[data-scope]").forEach(item => item.setAttribute("aria-pressed", String(item === button))); applyFilters(); }));
window.addEventListener("assignments-loaded", () => { if (learning.view !== "tasks") renderLearning(); });
window.addEventListener("hashchange", () => changeView(location.hash.slice(1),false));
document.addEventListener("visibilitychange", () => { if (!document.hidden) checkOpenReminders(); });
window.setInterval(checkOpenReminders, 15000);
changeView(location.hash.slice(1) || "tasks", false);
