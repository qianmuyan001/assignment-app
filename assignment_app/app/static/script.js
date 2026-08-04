const API_BASE = "";
const STATUS_OPTIONS = ["todo", "in_progress", "done", "ignored"];

const assignmentForm = document.querySelector("#assignment-form");
const assignmentList = document.querySelector("#assignment-list");
const errorMessage = document.querySelector("#error-message");
const refreshButton = document.querySelector("#refresh-button");
const statusFilter = document.querySelector("#status-filter");
const courseFilter = document.querySelector("#course-filter");
const searchBox = document.querySelector("#search-box");
const clearFiltersButton = document.querySelector("#clear-filters-button");
const totalCount = document.querySelector("#total-count");
const openCount = document.querySelector("#open-count");
const todayCount = document.querySelector("#today-count");
const weekCount = document.querySelector("#week-count");

let allAssignments = [];

document.addEventListener("DOMContentLoaded", () => {
  bindButtonFeedback();
  loadAssignments();
});
assignmentForm.addEventListener("submit", handleCreateAssignment);
refreshButton.addEventListener("click", loadAssignments);
statusFilter.addEventListener("change", renderFilteredAssignments);
courseFilter.addEventListener("change", renderFilteredAssignments);
searchBox.addEventListener("input", renderFilteredAssignments);
clearFiltersButton.addEventListener("click", clearFilters);

async function loadAssignments() {
  hideError();

  try {
    const assignments = await apiRequest("/assignments");
    allAssignments = assignments;
    updateCourseFilter(allAssignments);
    updateSummaryCounts(allAssignments);
    renderFilteredAssignments();
  } catch (error) {
    showError(error.message);
  }
}

async function handleCreateAssignment(event) {
  event.preventDefault();
  hideError();

  const formData = new FormData(assignmentForm);
  const assignmentData = {
    course_name: formData.get("course_name"),
    title: formData.get("title"),
    due_date: formData.get("due_date"),
    description: emptyToNull(formData.get("description")),
    source_url: emptyToNull(formData.get("source_url")),
    source_name: emptyToNull(formData.get("source_name")),
  };

  try {
    await apiRequest("/assignments", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(assignmentData),
    });

    assignmentForm.reset();
    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

async function handleStatusChange(assignmentId, newStatus) {
  hideError();

  try {
    await apiRequest(`/assignments/${assignmentId}/status`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: newStatus }),
    });

    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

async function handleDeleteAssignment(assignmentId) {
  hideError();

  try {
    await apiRequest(`/assignments/${assignmentId}`, {
      method: "DELETE",
    });

    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

async function apiRequest(path, options = {}) {
  const response = await fetch(`${API_BASE}${path}`, options);

  if (!response.ok) {
    let message = "Something went wrong. Please try again.";

    try {
      const errorData = await response.json();
      message = errorData.detail || message;
    } catch {
      // Some responses do not include JSON, so keep the simple fallback message.
    }

    throw new Error(message);
  }

  if (response.status === 204) {
    return null;
  }

  return response.json();
}

function renderAssignments(assignments, emptyText = "No assignments yet.") {
  assignmentList.innerHTML = "";

  if (assignments.length === 0) {
    const emptyMessage = document.createElement("p");
    emptyMessage.className = "empty-message";
    emptyMessage.textContent = emptyText;
    assignmentList.appendChild(emptyMessage);
    return;
  }

  assignments.forEach((assignment, index) => {
    const card = createAssignmentCard(assignment);
    card.style.setProperty("--index", index);
    assignmentList.appendChild(card);
  });
}

function renderFilteredAssignments() {
  const visibleAssignments = sortAssignmentsByDueDate(
    filterAssignments(allAssignments),
  );
  const emptyText = allAssignments.length === 0
    ? "No assignments yet."
    : "No assignments match the current filters.";

  renderAssignments(visibleAssignments, emptyText);
}

function filterAssignments(assignments) {
  const selectedStatus = statusFilter.value;
  const selectedCourse = courseFilter.value;
  const searchText = searchBox.value.trim().toLowerCase();

  return assignments.filter((assignment) => {
    const statusMatches = selectedStatus === "all" || assignment.status === selectedStatus;
    const courseMatches = selectedCourse === "all" || assignment.course_name === selectedCourse;
    const searchMatches = searchText === "" || assignmentMatchesSearch(assignment, searchText);

    return statusMatches && courseMatches && searchMatches;
  });
}

function sortAssignmentsByDueDate(assignments) {
  return [...assignments].sort((first, second) => {
    const firstTime = getDueDateTime(first.due_date);
    const secondTime = getDueDateTime(second.due_date);

    if (firstTime === null && secondTime === null) {
      return 0;
    }

    if (firstTime === null) {
      return 1;
    }

    if (secondTime === null) {
      return -1;
    }

    return firstTime - secondTime;
  });
}

function updateCourseFilter(assignments) {
  const selectedCourse = courseFilter.value;
  const courseNames = [...new Set(assignments.map((assignment) => assignment.course_name))]
    .filter(Boolean)
    .sort((first, second) => first.localeCompare(second));

  courseFilter.innerHTML = "";
  courseFilter.appendChild(createFilterOption("all", "all courses"));

  courseNames.forEach((courseName) => {
    courseFilter.appendChild(createFilterOption(courseName, courseName));
  });

  if (courseNames.includes(selectedCourse)) {
    courseFilter.value = selectedCourse;
  } else {
    courseFilter.value = "all";
  }
}

function createFilterOption(value, label) {
  const option = document.createElement("option");
  option.value = value;
  option.textContent = label;
  return option;
}

function clearFilters() {
  statusFilter.value = "all";
  courseFilter.value = "all";
  searchBox.value = "";
  renderFilteredAssignments();
}

function assignmentMatchesSearch(assignment, searchText) {
  const searchableText = [
    assignment.course_name,
    assignment.title,
    assignment.description,
    assignment.source_name,
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  return searchableText.includes(searchText);
}

function createAssignmentCard(assignment) {
  const card = document.createElement("article");
  card.className = getAssignmentCardClassName(assignment);
  card.dataset.assignmentId = assignment.id;

  const title = document.createElement("h3");
  title.textContent = assignment.title;

  const course = document.createElement("p");
  course.className = "assignment-meta";
  course.textContent = assignment.course_name;

  const dueHelper = createDueDateHelper(assignment);

  const details = document.createElement("div");
  details.className = "assignment-details";
  details.appendChild(createDetailRow("Due Date", formatDate(assignment.due_date) || "None"));
  details.appendChild(createDetailRow("Description", assignment.description || "None"));
  details.appendChild(createSourceUrlRow(assignment.source_url));
  details.appendChild(createDetailRow("Source Name", assignment.source_name || "None"));
  details.appendChild(createDetailRow("Status", assignment.status));

  const actions = document.createElement("div");
  actions.className = "assignment-actions";
  actions.appendChild(createStatusSelect(assignment));

  const buttons = document.createElement("div");
  buttons.className = "card-buttons";
  buttons.appendChild(createEditButton(card, assignment));
  buttons.appendChild(createDeleteButton(assignment.id));
  actions.appendChild(buttons);

  card.appendChild(title);
  card.appendChild(course);
  if (dueHelper !== null) {
    card.appendChild(dueHelper);
  }
  card.appendChild(details);
  card.appendChild(actions);

  return card;
}

function createAssignmentEditCard(assignment) {
  const card = document.createElement("article");
  card.className = `${getAssignmentCardClassName(assignment)} edit-mode`;
  card.dataset.assignmentId = assignment.id;

  const heading = document.createElement("h3");
  heading.textContent = "Edit Assignment";

  const form = document.createElement("form");
  form.className = "edit-form";
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    handleEditAssignment(assignment, form);
  });

  form.appendChild(createEditField("Course Name", "course_name", "text", assignment.course_name, true));
  form.appendChild(createEditField("Title", "title", "text", assignment.title, true));
  form.appendChild(createEditField("Due Date", "due_date", "datetime-local", toDateTimeLocalValue(assignment.due_date), true));
  form.appendChild(createEditTextArea("Description", "description", assignment.description || ""));
  form.appendChild(createEditField("Source URL", "source_url", "url", assignment.source_url || "", false));
  form.appendChild(createEditField("Source Name", "source_name", "text", assignment.source_name || "", false));

  const actions = document.createElement("div");
  actions.className = "assignment-actions";
  actions.appendChild(createStatusSelect(assignment));

  const buttons = document.createElement("div");
  buttons.className = "card-buttons";
  buttons.appendChild(createSaveButton(form, assignment));
  buttons.appendChild(createCancelButton(card, assignment));
  actions.appendChild(buttons);

  card.appendChild(heading);
  card.appendChild(form);
  card.appendChild(actions);

  return card;
}

function createDetailRow(label, value) {
  const row = document.createElement("p");
  const labelElement = document.createElement("strong");

  labelElement.textContent = `${label}: `;
  row.appendChild(labelElement);
  row.append(value);

  return row;
}

function createSourceUrlRow(sourceUrl) {
  const row = document.createElement("p");
  const labelElement = document.createElement("strong");

  labelElement.textContent = "Source URL: ";
  row.appendChild(labelElement);

  if (!sourceUrl) {
    row.append("None");
    return row;
  }

  const link = document.createElement("a");
  link.href = sourceUrl;
  link.textContent = sourceUrl;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  row.appendChild(link);

  return row;
}

function createStatusSelect(assignment) {
  const label = document.createElement("label");
  label.className = "status-control";
  label.textContent = "Change Status";

  const select = document.createElement("select");

  STATUS_OPTIONS.forEach((status) => {
    const option = document.createElement("option");
    option.value = status;
    option.textContent = status;
    select.appendChild(option);
  });

  select.value = assignment.status;

  select.addEventListener("change", () => {
    handleStatusChange(assignment.id, select.value);
  });

  label.appendChild(select);
  return label;
}

function createEditButton(card, assignment) {
  const button = document.createElement("button");
  button.className = "secondary-button";
  button.type = "button";
  button.textContent = "Edit";

  button.addEventListener("click", () => {
    card.replaceWith(createAssignmentEditCard(assignment));
  });

  return button;
}

function createSaveButton(form, assignment) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Save";

  button.addEventListener("click", () => {
    handleEditAssignment(assignment, form);
  });

  return button;
}

function createCancelButton(card, assignment) {
  const button = document.createElement("button");
  button.className = "secondary-button";
  button.type = "button";
  button.textContent = "Cancel";

  button.addEventListener("click", () => {
    card.replaceWith(createAssignmentCard(assignment));
  });

  return button;
}

function createDeleteButton(assignmentId) {
  const button = document.createElement("button");
  button.className = "delete-button";
  button.type = "button";
  button.textContent = "Delete";

  button.addEventListener("click", () => {
    handleDeleteAssignment(assignmentId);
  });

  return button;
}

function getAssignmentCardClassName(assignment) {
  const status = String(assignment.status || "todo");
  const classes = ["assignment-card", `status-${status}`];
  const dueDate = new Date(assignment.due_date);

  if (
    !Number.isNaN(dueDate.getTime()) &&
    startOfDay(dueDate) < startOfDay(new Date()) &&
    !["done", "completed"].includes(status)
  ) {
    classes.push("is-past-due");
  }

  return classes.join(" ");
}

function createEditField(labelText, name, type, value, required) {
  const label = document.createElement("label");
  label.textContent = labelText;

  const input = document.createElement("input");
  input.name = name;
  input.type = type;
  input.value = value;
  input.required = required;

  label.appendChild(input);
  return label;
}

function createEditTextArea(labelText, name, value) {
  const label = document.createElement("label");
  label.className = "full-width";
  label.textContent = labelText;

  const textarea = document.createElement("textarea");
  textarea.name = name;
  textarea.rows = 3;
  textarea.value = value;

  label.appendChild(textarea);
  return label;
}

async function handleEditAssignment(assignment, form) {
  hideError();

  if (!form.reportValidity()) {
    return;
  }

  const updateData = getEditedFields(assignment, form);

  if (Object.keys(updateData).length === 0) {
    await loadAssignments();
    return;
  }

  try {
    await apiRequest(`/assignments/${assignment.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(updateData),
    });

    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

function getEditedFields(assignment, form) {
  const formData = new FormData(form);
  const editedAssignment = {
    course_name: String(formData.get("course_name") || "").trim(),
    title: String(formData.get("title") || "").trim(),
    due_date: String(formData.get("due_date") || ""),
    description: emptyToNull(formData.get("description")),
    source_url: emptyToNull(formData.get("source_url")),
    source_name: emptyToNull(formData.get("source_name")),
  };

  const originalAssignment = {
    course_name: assignment.course_name,
    title: assignment.title,
    due_date: toDateTimeLocalValue(assignment.due_date),
    description: assignment.description || null,
    source_url: assignment.source_url || null,
    source_name: assignment.source_name || null,
  };

  const updateData = {};

  Object.keys(editedAssignment).forEach((fieldName) => {
    if (editedAssignment[fieldName] !== originalAssignment[fieldName]) {
      updateData[fieldName] = editedAssignment[fieldName];
    }
  });

  return updateData;
}

function formatDate(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  return date.toLocaleString();
}

function createDueDateHelper(assignment) {
  const helperText = getDueDateHelperText(assignment);

  if (!helperText) {
    return null;
  }

  const helper = document.createElement("p");
  helper.className = "due-helper";
  helper.textContent = helperText;

  if (helperText === "Past due") {
    helper.classList.add("past-due");
  }

  return helper;
}

function getDueDateHelperText(assignment) {
  const dueDate = new Date(assignment.due_date);

  if (Number.isNaN(dueDate.getTime())) {
    return "";
  }

  const today = startOfDay(new Date());
  const dueDay = startOfDay(dueDate);
  const dayDifference = Math.round((dueDay - today) / 86400000);

  if (dayDifference === 0) {
    return "Due today";
  }

  if (dayDifference > 0) {
    return `Due in ${dayDifference} ${dayDifference === 1 ? "day" : "days"}`;
  }

  if (assignment.status !== "done") {
    return "Past due";
  }

  return "";
}

function updateSummaryCounts(assignments) {
  const today = startOfDay(new Date());
  const weekEnd = new Date(today);
  weekEnd.setDate(today.getDate() + 7);

  const summary = assignments.reduce(
    (counts, assignment) => {
      const status = String(assignment.status || "");
      const isComplete = ["done", "completed"].includes(status);
      const dueDate = startOfDay(new Date(assignment.due_date));

      counts.total += 1;
      if (!isComplete) {
        counts.open += 1;
      }

      if (!Number.isNaN(dueDate.getTime())) {
        if (dueDate.getTime() === today.getTime()) {
          counts.today += 1;
        }

        if (!isComplete && dueDate >= today && dueDate <= weekEnd) {
          counts.week += 1;
        }
      }

      return counts;
    },
    { total: 0, open: 0, today: 0, week: 0 },
  );

  totalCount.textContent = summary.total;
  openCount.textContent = summary.open;
  todayCount.textContent = summary.today;
  weekCount.textContent = summary.week;
}

function bindButtonFeedback() {
  document.addEventListener("pointerdown", (event) => {
    const button = event.target.closest("button");

    if (!button || button.disabled) {
      return;
    }

    const bounds = button.getBoundingClientRect();
    const x = ((event.clientX - bounds.left) / bounds.width) * 100;
    const y = ((event.clientY - bounds.top) / bounds.height) * 100;

    button.style.setProperty("--press-x", `${x}%`);
    button.style.setProperty("--press-y", `${y}%`);
    button.classList.add("is-pressing");
  });

  ["pointerup", "pointercancel", "pointerleave"].forEach((eventName) => {
    document.addEventListener(eventName, (event) => {
      const button = event.target.closest("button");

      if (button) {
        button.classList.remove("is-pressing");
      }
    });
  });
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function getDueDateTime(value) {
  if (!value) {
    return null;
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return null;
  }

  return date.getTime();
}

function toDateTimeLocalValue(value) {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  const year = date.getFullYear();
  const month = padDatePart(date.getMonth() + 1);
  const day = padDatePart(date.getDate());
  const hours = padDatePart(date.getHours());
  const minutes = padDatePart(date.getMinutes());

  return `${year}-${month}-${day}T${hours}:${minutes}`;
}

function padDatePart(value) {
  return String(value).padStart(2, "0");
}

function emptyToNull(value) {
  const cleaned = String(value || "").trim();
  return cleaned || null;
}

function showError(message) {
  errorMessage.textContent = message;
  errorMessage.classList.add("visible");
}

function hideError() {
  errorMessage.textContent = "";
  errorMessage.classList.remove("visible");
}
