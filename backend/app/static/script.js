"use strict";

const API_BASE = "";
const STATUS_OPTIONS = ["todo", "in_progress", "done"];
const PRIORITY_OPTIONS = ["low", "medium", "high"];

/* Motion constants.

   The carousel is gesture-driven, so its position is integrated by a spring in
   JS rather than tweened by CSS: a spring carries velocity across an
   interruption, which a fixed-duration transition cannot. Everything that is
   *not* gesture-driven (selection styling, the dialog, the error notice) stays
   in CSS, where the browser can run it off the main thread.

   The spring is tuned to a damping ratio of ~0.8 — enough to settle without a
   visible bounce, which would be wrong for a list you page through all day. */
const SPRING_STIFFNESS = 170;
const SPRING_DAMPING = 21;
const SPRING_SUBSTEP_SECONDS = 1 / 240;
const SPRING_REST_POSITION = 0.0012;
const SPRING_REST_VELOCITY = 0.0035;

/* Release behaviour. 0.11 px/ms is the velocity above which a gesture reads as
   a deliberate flick rather than a slow drag, so a flick always commits to at
   least the next card even if the finger barely travelled. */
const FLICK_PX_PER_MS = 0.11;
const DRAG_PX_PER_CARD = 150;
const PROJECTION_SECONDS = 0.22;
const MAX_FLICK_CARDS = 3;
const VELOCITY_SAMPLE_MS = 90;
const WHEEL_PX_PER_CARD = 120;
const WHEEL_IDLE_RESET_MS = 180;

/* Rubber-banding past the ends, so the carousel resists instead of hitting a
   wall. RUBBER_RANGE is the asymptote in card units. */
const RUBBER_RANGE = 1.7;

/* Shelf geometry. */
const CARD_STEP_PX = 124;
const CARD_STEP_PX_COMPACT = 92;
const SELECTED_LIFT_PX = 130;
const DEPTH_STEP_PX = 44;
const ROTATE_PER_CARD_DEG = 15;
const MAX_ROTATE_DEG = 52;
const SCALE_FALLOFF = 0.058;
const MIN_SCALE = 0.7;
const OPACITY_FALLOFF = 0.22;
const MIN_OPACITY = 0.12;
const VISIBLE_RANGE = 5.4;
const MAX_OFFSET = 6;

/* Depth-of-field is quantised into four buckets and applied as a data
   attribute, not recomputed per frame. Blur is a paint-bound property: the
   previous code wrote a fresh sub-pixel blur radius to every card on every
   frame of every drag. Bucketing means a card changes its blur a handful of
   times per gesture, and CSS transitions between the steps. */
const DEPTH_BUCKETS = 3;

/* Entrance choreography. 40ms stagger sits inside the 30-80ms band; the run is
   capped so a long list never spends more than ~320ms introducing itself, and
   cards are interactive from the first frame. */
const ENTER_DURATION_MS = 240;
const ENTER_STAGGER_MS = 40;
const ENTER_STAGGER_CAP = 8;
const LEAVE_DURATION_MS = 200;
const SEARCH_DEBOUNCE_MS = 120;
const COUNT_SWAP_MS = 160;

const reducedMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
const coarsePointerQuery = window.matchMedia("(max-width: 720px)");

const dom = {
  form: document.querySelector("#assignment-form"),
  dialog: document.querySelector("#assignment-dialog"),
  openAdd: document.querySelector("#open-add-button"),
  closeAdd: document.querySelector("#close-add-button"),
  coverFlow: document.querySelector("#cover-flow"),
  flowEmpty: document.querySelector("#flow-empty"),
  selectedDetail: document.querySelector("#selected-detail"),
  errorMessage: document.querySelector("#error-message"),
  refresh: document.querySelector("#refresh-button"),
  statusFilter: document.querySelector("#status-filter"),
  courseFilter: document.querySelector("#course-filter"),
  searchBox: document.querySelector("#search-box"),
  clearFilters: document.querySelector("#clear-filters-button"),
  previousCard: document.querySelector("#previous-card-button"),
  nextCard: document.querySelector("#next-card-button"),
  flowPosition: document.querySelector("#flow-position"),
  openOrg: document.querySelector("#open-org-button"),
  closeOrg: document.querySelector("#close-org-button"),
  orgDialog: document.querySelector("#org-dialog"),
  coursePicker: document.querySelector("#course-picker"),
  projectPicker: document.querySelector("#project-picker"),
  tagCheckboxes: document.querySelector("#tag-checkboxes"),
  orgCourseForm: document.querySelector("#org-course-form"),
  orgProjectForm: document.querySelector("#org-project-form"),
  orgTagForm: document.querySelector("#org-tag-form"),
  orgCourseList: document.querySelector("#org-course-list"),
  orgProjectList: document.querySelector("#org-project-list"),
  orgTagList: document.querySelector("#org-tag-list"),
  orgProjectCourseSelect: document.querySelector("#org-project-course"),
  counts: {
    total: document.querySelector("#total-count"),
    open: document.querySelector("#open-count"),
    today: document.querySelector("#today-count"),
    week: document.querySelector("#week-count"),
  },
};

const state = {
  all: [],
  visible: [],
  selectedId: null,
  selectedIndex: 0,
  detailExpanded: false,
  loadGeneration: 0,
  inFlightLoads: 0,
  courses: [],
  projects: [],
  tags: [],
  orgGeneration: 0,
  draftCourseId: null,
  draftProjectId: null,
  lastOrgAssignmentId: null,
};

/* One entry per rendered card, keyed by assignment id, so filtering patches the
   shelf instead of tearing it down. The element reference lives here too: the
   old code ran a querySelector per card per frame. */
const cards = new Map();

let detailView = null;
let searchTimer = null;

// ---------------------------------------------------------------------------
// Spring
// ---------------------------------------------------------------------------

const carousel = {
  position: 0,
  velocity: 0,
  target: 0,
  dragging: false,
};

let frameHandle = null;
let lastFrameTime = 0;
let springAccumulator = 0;

function springAtRest() {
  return (
    Math.abs(carousel.target - carousel.position) < SPRING_REST_POSITION &&
    Math.abs(carousel.velocity) < SPRING_REST_VELOCITY
  );
}

/* Fixed-substep integration. The previous implementation advanced by a fixed
   fraction of the remaining distance per frame, which made the carousel settle
   twice as fast on a 120Hz display as on a 60Hz one. */
function stepSpring(deltaSeconds) {
  springAccumulator += Math.min(deltaSeconds, 0.05);

  while (springAccumulator >= SPRING_SUBSTEP_SECONDS) {
    const displacement = carousel.position - carousel.target;
    const acceleration =
      -SPRING_STIFFNESS * displacement - SPRING_DAMPING * carousel.velocity;

    carousel.velocity += acceleration * SPRING_SUBSTEP_SECONDS;
    carousel.position += carousel.velocity * SPRING_SUBSTEP_SECONDS;
    springAccumulator -= SPRING_SUBSTEP_SECONDS;
  }
}

function settleSpring() {
  carousel.position = carousel.target;
  carousel.velocity = 0;
  springAccumulator = 0;
}

function requestFrame() {
  if (frameHandle === null) {
    lastFrameTime = performance.now();
    frameHandle = requestAnimationFrame(runFrame);
  }
}

function runFrame(now) {
  const deltaSeconds = Math.max(0, (now - lastFrameTime) / 1000);
  lastFrameTime = now;

  if (!carousel.dragging) {
    if (reducedMotionQuery.matches) {
      settleSpring();
    } else {
      stepSpring(deltaSeconds);

      if (springAtRest()) {
        settleSpring();
      }
    }
  }

  const transitioning = layoutCards(now);

  if (carousel.dragging || transitioning || !springAtRest()) {
    frameHandle = requestAnimationFrame(runFrame);
    return;
  }

  frameHandle = null;
}

// ---------------------------------------------------------------------------
// Shelf layout
// ---------------------------------------------------------------------------

function cardStepPx() {
  return coarsePointerQuery.matches ? CARD_STEP_PX_COMPACT : CARD_STEP_PX;
}

function easeOutCubic(progress) {
  return 1 - Math.pow(1 - progress, 3);
}

/* Writes one transform string and one opacity per card per frame. The previous
   version set eleven custom properties per card and let CSS rebuild the
   transform from them, which meant a style recalculation for every card on
   every frame of every drag. Everything animated per frame here is transform or
   opacity; the per-frame blur and backdrop-filter are gone. */
function layoutCards(now) {
  const view = carousel.position;
  const step = cardStepPx();
  const reduced = reducedMotionQuery.matches;
  let transitioning = false;

  cards.forEach((entry) => {
    let enter = 1;
    let leave = 0;

    if (entry.enterAt !== null) {
      const elapsed = now - entry.enterAt;

      if (elapsed < 0) {
        enter = 0;
        transitioning = true;
      } else if (elapsed < ENTER_DURATION_MS) {
        enter = easeOutCubic(elapsed / ENTER_DURATION_MS);
        transitioning = true;
      } else {
        entry.enterAt = null;
      }
    }

    if (entry.leaveAt !== null) {
      const elapsed = now - entry.leaveAt;

      if (elapsed >= LEAVE_DURATION_MS) {
        entry.element.remove();
        cards.delete(entry.id);
        return;
      }

      leave = easeOutCubic(elapsed / LEAVE_DURATION_MS);
      transitioning = true;
    }

    const offset = entry.index - view;
    const absOffset = Math.abs(offset);
    const far = absOffset > VISIBLE_RANGE;

    if (far !== entry.isFar) {
      entry.isFar = far;
      entry.element.classList.toggle("is-far", far);
    }

    if (far && entry.leaveAt === null) {
      if (entry.hidden !== true) {
        entry.hidden = true;
        entry.element.style.opacity = "0";
        /* Cache the written value too, or the next in-range frame that happens
           to compute this same opacity would skip the write and leave the card
           invisible. */
        entry.lastOpacity = "0";
      }
      return;
    }

    entry.hidden = false;

    const clamped = clamp(offset, -MAX_OFFSET, MAX_OFFSET);
    const depth = Math.min(absOffset, MAX_OFFSET);
    const x = clamped * step;
    const z = absOffset < 0.08 ? SELECTED_LIFT_PX : -depth * DEPTH_STEP_PX;
    const rotate = clamp(-clamped * ROTATE_PER_CARD_DEG, -MAX_ROTATE_DEG, MAX_ROTATE_DEG);
    const depthScale = Math.max(MIN_SCALE, 1 - depth * SCALE_FALLOFF);

    /* Under reduced motion a card arrives and leaves by fading only. The
       depth scale stays, because it is spatial structure rather than motion. */
    const scale = reduced
      ? depthScale
      : depthScale * (0.94 + 0.06 * enter) * (1 - 0.08 * leave);
    const opacity =
      Math.max(MIN_OPACITY, 1 - depth * OPACITY_FALLOFF) * enter * (1 - leave);

    const transform = reduced
      ? `translate3d(${x}px, 0, ${z}px) scale(${scale})`
      : `translate3d(${x}px, 0, ${z}px) rotateY(${rotate}deg) scale(${scale})`;

    if (transform !== entry.lastTransform) {
      entry.lastTransform = transform;
      entry.element.style.transform = transform;
    }

    const opacityText = opacity.toFixed(3);

    if (opacityText !== entry.lastOpacity) {
      entry.lastOpacity = opacityText;
      entry.element.style.opacity = opacityText;
    }

    const zIndex = String(1000 - Math.round(absOffset * 10));

    if (zIndex !== entry.lastZIndex) {
      entry.lastZIndex = zIndex;
      entry.element.style.zIndex = zIndex;
    }

    const depthBucket = reduced
      ? "0"
      : String(Math.min(DEPTH_BUCKETS, Math.round(absOffset)));

    if (depthBucket !== entry.lastDepth) {
      entry.lastDepth = depthBucket;
      entry.element.dataset.depth = depthBucket;
    }
  });

  return transitioning;
}

// ---------------------------------------------------------------------------
// Card elements
// ---------------------------------------------------------------------------

function createCardElement(assignment) {
  const card = document.createElement("article");
  card.className = "flow-card";
  card.dataset.assignmentId = String(assignment.id);

  const disc = document.createElement("div");
  disc.className = "disc-core";
  disc.setAttribute("aria-hidden", "true");

  const course = document.createElement("p");
  course.className = "flow-course";

  const title = document.createElement("h3");

  const due = document.createElement("p");
  due.className = "flow-due";

  const meta = document.createElement("div");
  meta.className = "flow-meta";

  const statusChip = createChip("");
  const priorityChip = createChip("");
  const progressChip = createChip("");
  meta.append(statusChip, priorityChip, progressChip);

  const meter = document.createElement("div");
  meter.className = "progress-meter";
  const meterFill = document.createElement("span");
  meter.appendChild(meterFill);

  card.append(disc, course, title, due, meta, meter);

  return {
    element: card,
    refs: { course, title, due, statusChip, priorityChip, progressChip, meterFill },
  };
}

function updateCardContent(entry, assignment) {
  const { refs } = entry;
  const progress = getProgress(assignment);
  const status = normalizeStatus(assignment.status);
  const priority = normalizePriority(assignment.priority);

  setText(refs.course, assignment.course_name || "No course");
  setText(refs.title, assignment.title || "Untitled assignment");
  setText(refs.due, describeDueDate(assignment) || "No due date");
  setText(refs.statusChip, status);
  setText(refs.priorityChip, priority);
  setText(refs.progressChip, `${progress}%`);

  const fill = (progress / 100).toFixed(3);

  if (fill !== entry.lastFill) {
    entry.lastFill = fill;
    refs.meterFill.style.setProperty("--progress", fill);
  }

  const classes = ["flow-card", `status-${status}`, `priority-${priority}`];

  if (isPastDue(assignment)) {
    classes.push("is-past-due");
  }

  if (assignment.id === state.selectedId) {
    classes.push("is-selected");
  }

  if (entry.isFar) {
    classes.push("is-far");
  }

  const className = classes.join(" ");

  if (className !== entry.lastClassName) {
    entry.lastClassName = className;
    entry.element.className = className;
  }
}

function syncCards() {
  const nextIds = new Set(state.visible.map((assignment) => assignment.id));
  const now = performance.now();
  let appearing = 0;

  cards.forEach((entry) => {
    if (!nextIds.has(entry.id) && entry.leaveAt === null) {
      entry.leaveAt = now;
      entry.element.classList.add("is-leaving");
    }
  });

  state.visible.forEach((assignment, index) => {
    let entry = cards.get(assignment.id);

    if (!entry) {
      const created = createCardElement(assignment);
      const stagger = Math.min(appearing, ENTER_STAGGER_CAP) * ENTER_STAGGER_MS;

      entry = {
        id: assignment.id,
        element: created.element,
        refs: created.refs,
        index,
        enterAt: reducedMotionQuery.matches ? now : now + stagger,
        leaveAt: null,
        isFar: false,
        hidden: false,
        lastTransform: "",
        lastOpacity: "",
        lastZIndex: "",
        lastClassName: "",
        lastFill: "",
        lastDepth: "",
      };

      entry.element.style.opacity = "0";
      cards.set(assignment.id, entry);
      dom.coverFlow.appendChild(entry.element);
      appearing += 1;
    } else if (entry.leaveAt !== null) {
      entry.leaveAt = null;
      entry.element.classList.remove("is-leaving");
    }

    entry.index = index;
    entry.assignment = assignment;
    updateCardContent(entry, assignment);
  });

  dom.flowEmpty.hidden = state.visible.length > 0;

  if (state.visible.length === 0) {
    dom.flowEmpty.textContent =
      state.all.length === 0
        ? "No assignments yet."
        : "No assignments match the current filters.";
  }

  requestFrame();
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

function syncSelection() {
  if (state.visible.length === 0) {
    state.selectedId = null;
    state.selectedIndex = 0;
    carousel.target = 0;
    settleSpring();
    return;
  }

  const foundIndex = state.visible.findIndex(
    (assignment) => assignment.id === state.selectedId,
  );

  state.selectedIndex =
    foundIndex >= 0
      ? foundIndex
      : clamp(state.selectedIndex, 0, state.visible.length - 1);
  state.selectedId = state.visible[state.selectedIndex].id;
  carousel.target = state.selectedIndex;
}

function selectIndex(index, options = {}) {
  if (state.visible.length === 0) {
    return;
  }

  const nextIndex = clamp(index, 0, state.visible.length - 1);
  const changed = nextIndex !== state.selectedIndex;

  state.selectedIndex = nextIndex;
  state.selectedId = state.visible[nextIndex].id;
  carousel.target = nextIndex;

  if (changed && options.collapseDetail) {
    state.detailExpanded = false;
  }

  if (changed) {
    cards.forEach((entry) => updateCardContent(entry, entry.assignment));
  }

  updateFlowControls();
  renderDetail();
  requestFrame();
}

function moveSelection(delta) {
  if (state.visible.length <= 1) {
    return;
  }

  selectIndex(state.selectedIndex + delta, { collapseDetail: true });
}

function updateFlowControls() {
  const count = state.visible.length;
  dom.previousCard.disabled = count <= 1 || state.selectedIndex === 0;
  dom.nextCard.disabled = count <= 1 || state.selectedIndex === count - 1;
  dom.flowPosition.textContent =
    count === 0 ? "0 / 0" : `${state.selectedIndex + 1} / ${count}`;
}

// ---------------------------------------------------------------------------
// Gestures
// ---------------------------------------------------------------------------

const drag = {
  pointerId: null,
  startX: 0,
  startPosition: 0,
  moved: false,
  samples: [],
};

function rubberBand(value, min, max) {
  if (value >= min && value <= max) {
    return value;
  }

  const limit = value < min ? min : max;
  const overshoot = value - limit;
  const resisted =
    (1 - 1 / (Math.abs(overshoot) / RUBBER_RANGE + 1)) * RUBBER_RANGE;

  return limit + Math.sign(overshoot) * resisted;
}

function pointerVelocityPxPerMs(now) {
  const samples = drag.samples;

  if (samples.length < 2) {
    return 0;
  }

  let oldest = samples[0];

  for (let index = samples.length - 1; index >= 0; index -= 1) {
    if (now - samples[index].time > VELOCITY_SAMPLE_MS) {
      break;
    }

    oldest = samples[index];
  }

  const newest = samples[samples.length - 1];
  const elapsed = newest.time - oldest.time;

  if (elapsed <= 0) {
    return 0;
  }

  return (newest.x - oldest.x) / elapsed;
}

function beginDrag(event) {
  if (state.visible.length <= 1 || drag.pointerId !== null) {
    return;
  }

  drag.pointerId = event.pointerId;
  drag.startX = event.clientX;
  drag.startPosition = carousel.position;
  drag.moved = false;
  drag.samples = [{ x: event.clientX, time: event.timeStamp }];

  carousel.dragging = true;
  carousel.velocity = 0;
  dom.coverFlow.classList.add("is-dragging");
  dom.coverFlow.setPointerCapture(event.pointerId);
  requestFrame();
}

function updateDrag(event) {
  if (drag.pointerId !== event.pointerId) {
    return;
  }

  const totalDelta = event.clientX - drag.startX;

  if (Math.abs(totalDelta) > 6) {
    drag.moved = true;
  }

  drag.samples.push({ x: event.clientX, time: event.timeStamp });

  if (drag.samples.length > 12) {
    drag.samples.shift();
  }

  const raw = drag.startPosition - totalDelta / DRAG_PX_PER_CARD;
  carousel.position = rubberBand(raw, 0, state.visible.length - 1);

  const nearest = clamp(
    Math.round(carousel.position),
    0,
    state.visible.length - 1,
  );

  if (nearest !== state.selectedIndex) {
    state.selectedIndex = nearest;
    state.selectedId = state.visible[nearest].id;
    state.detailExpanded = false;
    cards.forEach((entry) => updateCardContent(entry, entry.assignment));
    updateFlowControls();
    scheduleDetailRender();
  }
}

/* The release seeds the spring with the gesture's own velocity, so letting go
   mid-flick continues the motion instead of restarting it from zero. */
function endDrag(event) {
  if (drag.pointerId !== event.pointerId) {
    return;
  }

  const pxPerMs = pointerVelocityPxPerMs(event.timeStamp);
  const cardsPerSecond = (-pxPerMs * 1000) / DRAG_PX_PER_CARD;

  drag.pointerId = null;
  carousel.dragging = false;
  dom.coverFlow.classList.remove("is-dragging");

  if (dom.coverFlow.hasPointerCapture?.(event.pointerId)) {
    dom.coverFlow.releasePointerCapture(event.pointerId);
  }

  if (state.visible.length === 0) {
    return;
  }

  carousel.velocity = cardsPerSecond;

  const startIndex = clamp(
    Math.round(drag.startPosition),
    0,
    state.visible.length - 1,
  );
  const projected = carousel.position + cardsPerSecond * PROJECTION_SECONDS;
  let target = clamp(Math.round(projected), 0, state.visible.length - 1);

  if (Math.abs(pxPerMs) > FLICK_PX_PER_MS && target === startIndex) {
    const magnitude = clamp(
      Math.round(Math.abs(cardsPerSecond) / 3),
      1,
      MAX_FLICK_CARDS,
    );
    target = clamp(
      startIndex + Math.sign(cardsPerSecond) * magnitude,
      0,
      state.visible.length - 1,
    );
  }

  selectIndex(target, { collapseDetail: true });
}

function cardFromEvent(event) {
  const direct = event.target.closest?.(".flow-card");

  if (direct) {
    return direct;
  }

  /* The cards are rotated in 3D, so a click can land on the stage while
     visually sitting on a card. Fall back to a front-to-back hit test. */
  const candidates = [...cards.values()]
    .filter((entry) => !entry.isFar && entry.leaveAt === null)
    .sort(
      (first, second) =>
        Number(second.lastZIndex || 0) - Number(first.lastZIndex || 0),
    );

  const hit = candidates.find((entry) => {
    const rect = entry.element.getBoundingClientRect();
    return (
      event.clientX >= rect.left &&
      event.clientX <= rect.right &&
      event.clientY >= rect.top &&
      event.clientY <= rect.bottom
    );
  });

  return hit ? hit.element : null;
}

function bindCarousel() {
  dom.coverFlow.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      moveSelection(-1);
      return;
    }

    if (event.key === "ArrowRight") {
      event.preventDefault();
      moveSelection(1);
      return;
    }

    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      toggleDetail();
    }
  });

  /* A trackpad emits a burst of wheel events per gesture. Deltas are
     accumulated and only spend a card once they cross a threshold, so one
     swipe advances one card instead of racing to the end of the list. */
  let wheelAccumulator = 0;
  let wheelResetTimer = null;

  dom.coverFlow.addEventListener(
    "wheel",
    (event) => {
      if (state.visible.length <= 1) {
        return;
      }

      event.preventDefault();

      const dominant =
        Math.abs(event.deltaX) > Math.abs(event.deltaY)
          ? event.deltaX
          : event.deltaY;

      wheelAccumulator += event.deltaMode === 1 ? dominant * 18 : dominant;

      window.clearTimeout(wheelResetTimer);
      wheelResetTimer = window.setTimeout(() => {
        wheelAccumulator = 0;
      }, WHEEL_IDLE_RESET_MS);

      if (Math.abs(wheelAccumulator) < WHEEL_PX_PER_CARD) {
        return;
      }

      const steps = Math.trunc(wheelAccumulator / WHEEL_PX_PER_CARD);
      wheelAccumulator -= steps * WHEEL_PX_PER_CARD;

      selectIndex(state.selectedIndex + steps, { collapseDetail: true });
    },
    { passive: false },
  );

  dom.coverFlow.addEventListener("click", (event) => {
    if (drag.moved) {
      drag.moved = false;
      return;
    }

    const card = cardFromEvent(event);

    if (!card) {
      return;
    }

    const index = state.visible.findIndex(
      (assignment) => assignment.id === Number(card.dataset.assignmentId),
    );

    if (index < 0) {
      return;
    }

    if (index === state.selectedIndex) {
      toggleDetail();
      return;
    }

    selectIndex(index, { collapseDetail: true });
  });

  dom.coverFlow.addEventListener("pointerdown", beginDrag);
  dom.coverFlow.addEventListener("pointermove", updateDrag);
  dom.coverFlow.addEventListener("pointerup", endDrag);
  dom.coverFlow.addEventListener("pointercancel", endDrag);
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

/* Built once and then patched. The previous version cleared innerHTML and
   rebuilt every node on each selection change, which fired while dragging. */
function buildDetailView() {
  const root = document.createDocumentFragment();

  const hero = document.createElement("div");
  hero.className = "selected-hero";

  const course = document.createElement("p");
  course.className = "flow-course";

  const title = document.createElement("h3");

  const due = document.createElement("p");
  due.className = "selected-due";

  const meta = document.createElement("div");
  meta.className = "flow-meta";
  const statusChip = createChip("");
  const priorityChip = createChip("");
  const progressChip = createChip("");
  meta.append(statusChip, priorityChip, progressChip);

  const meter = document.createElement("div");
  meter.className = "progress-meter";
  const meterFill = document.createElement("span");
  meter.appendChild(meterFill);

  hero.append(course, title, due, meta, meter);

  const actions = document.createElement("div");
  actions.className = "detail-actions";

  const statusLabel = document.createElement("label");
  statusLabel.className = "status-control";
  statusLabel.textContent = "Status";
  const statusSelect = document.createElement("select");

  STATUS_OPTIONS.forEach((status) => {
    const option = document.createElement("option");
    option.value = status;
    option.textContent = status;
    statusSelect.appendChild(option);
  });

  statusLabel.appendChild(statusSelect);

  const editButton = document.createElement("button");
  editButton.className = "secondary-button";
  editButton.type = "button";
  editButton.textContent = "Edit";

  const deleteButton = document.createElement("button");
  deleteButton.className = "delete-button";
  deleteButton.type = "button";
  deleteButton.textContent = "Delete";

  actions.append(statusLabel, editButton, deleteButton);

  const expandButton = document.createElement("button");
  expandButton.className = "secondary-button full-detail-button";
  expandButton.type = "button";

  const extraWrap = document.createElement("div");
  extraWrap.className = "detail-extra-wrap";
  const extraInner = document.createElement("div");
  extraInner.className = "detail-extra-inner";
  const extra = document.createElement("div");
  extra.className = "detail-extra";

  const rows = {
    due: createDetailRow("Due Date"),
    description: createDetailRow("Description"),
    source: createDetailRow("Source URL"),
    sourceName: createDetailRow("Source Name"),
    created: createDetailRow("Created"),
    updated: createDetailRow("Updated"),
  };

  Object.values(rows).forEach((row) => extra.appendChild(row.element));
  extraInner.appendChild(extra);
  extraWrap.appendChild(extraInner);

  const orgSections = buildOrgSections();

  root.append(hero, actions, expandButton, extraWrap, orgSections.fragment);

  statusSelect.addEventListener("change", () => {
    const assignment = state.visible[state.selectedIndex];

    if (assignment) {
      changeStatus(assignment, statusSelect.value);
    }
  });

  editButton.addEventListener("click", () => {
    const assignment = state.visible[state.selectedIndex];

    if (assignment) {
      renderEditForm(assignment);
    }
  });

  deleteButton.addEventListener("click", () => {
    const assignment = state.visible[state.selectedIndex];

    if (assignment) {
      deleteAssignment(assignment);
    }
  });

  expandButton.addEventListener("click", toggleDetail);

  return {
    fragment: root,
    ...orgSections.refs,
    course,
    title,
    due,
    statusChip,
    priorityChip,
    progressChip,
    meterFill,
    statusSelect,
    expandButton,
    extraWrap,
    rows,
    lastFill: "",
  };
}

function ensureDetailView() {
  if (detailView && dom.selectedDetail.contains(detailView.expandButton)) {
    return detailView;
  }

  dom.selectedDetail.replaceChildren();
  detailView = buildDetailView();
  dom.selectedDetail.appendChild(detailView.fragment);
  return detailView;
}

let detailRenderHandle = null;

function scheduleDetailRender() {
  if (detailRenderHandle !== null) {
    return;
  }

  detailRenderHandle = requestAnimationFrame(() => {
    detailRenderHandle = null;
    renderDetail();
  });
}

function renderDetail() {
  const assignment = state.visible[state.selectedIndex];

  if (!assignment) {
    detailView = null;
    dom.selectedDetail.replaceChildren(
      createEmptyMessage("Select an assignment to inspect it."),
    );
    return;
  }

  const view = ensureDetailView();
  const progress = getProgress(assignment);
  const status = normalizeStatus(assignment.status);

  setText(view.course, assignment.course_name || "No course");
  setText(view.title, assignment.title || "Untitled assignment");
  setText(view.due, formatDate(assignment.due_date) || "No due date");
  setText(view.statusChip, status);
  setText(view.priorityChip, normalizePriority(assignment.priority));
  setText(view.progressChip, `${progress}% progress`);

  const fill = (progress / 100).toFixed(3);

  if (fill !== view.lastFill) {
    view.lastFill = fill;
    view.meterFill.style.setProperty("--progress", fill);
  }

  if (view.statusSelect.value !== status) {
    view.statusSelect.value = status;
  }

  view.expandButton.textContent = state.detailExpanded
    ? "Hide Full Details"
    : "Show Full Details";
  view.extraWrap.classList.toggle("is-open", state.detailExpanded);

  setDetailRow(view.rows.due, formatDate(assignment.due_date) || "None");
  setDetailRow(view.rows.description, assignment.description || "None");
  setDetailRow(view.rows.sourceName, assignment.source_name || "None");
  setDetailRow(view.rows.created, formatDate(assignment.created_at) || "None");
  setDetailRow(view.rows.updated, formatDate(assignment.updated_at) || "None");
  setSourceRow(view.rows.source, assignment.source_url);

  if (assignment && assignment.id !== state.lastOrgAssignmentId) {
    state.lastOrgAssignmentId = assignment.id;
    renderOrgSections(view, assignment);
  } else if (!assignment) {
    state.lastOrgAssignmentId = null;
  }
}

function toggleDetail() {
  state.detailExpanded = !state.detailExpanded;
  renderDetail();
}

function createDetailRow(label) {
  const element = document.createElement("p");
  const strong = document.createElement("strong");
  strong.textContent = `${label}: `;
  const value = document.createElement("span");
  element.append(strong, value);
  return { element, value };
}

function setDetailRow(row, text) {
  setText(row.value, text);
}

/* Only http(s) links are rendered as links. A stored `javascript:` URL would
   otherwise execute on click. */
function setSourceRow(row, sourceUrl) {
  const safe = safeHttpUrl(sourceUrl);

  if (!safe) {
    row.value.replaceChildren(document.createTextNode(sourceUrl ? String(sourceUrl) : "None"));
    return;
  }

  const link = document.createElement("a");
  link.href = safe;
  link.textContent = safe;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  row.value.replaceChildren(link);
}

function renderEditForm(assignment) {
  detailView = null;
  dom.selectedDetail.replaceChildren();

  const heading = document.createElement("div");
  heading.className = "section-heading";
  const eyebrow = document.createElement("p");
  eyebrow.className = "eyebrow";
  eyebrow.textContent = "Modify";
  const title = document.createElement("h2");
  title.textContent = "Edit Assignment";
  heading.append(eyebrow, title);

  const form = document.createElement("form");
  form.className = "edit-form detail-edit-form";

  const fields = [
    createInputField("Course Name", "course_name", "text", assignment.course_name || "", true),
    createInputField("Title", "title", "text", assignment.title || "", true),
    createInputField("Due Date", "due_date", "datetime-local", toDateTimeLocal(assignment.due_date), true),
    createSelectField("Priority", "priority", PRIORITY_OPTIONS, normalizePriority(assignment.priority)),
    createTextAreaField("Description", "description", assignment.description || ""),
    createInputField("Source URL", "source_url", "url", assignment.source_url || "", false),
    createInputField("Source Name", "source_name", "text", assignment.source_name || "", false),
  ];

  fields.forEach((field) => form.appendChild(field));

  // Organization pickers (Phase 2).
  state.editCourseId = matchedCourseId(assignment);
  state.editProjectId = assignment.project_id || null;

  const coursePicker = createOrgSelectField(
    "Course",
    "course_id",
    state.courses.map((c) => ({ value: String(c.id), label: c.name })),
    state.editCourseId ? String(state.editCourseId) : "",
  );
  const projectPicker = createOrgSelectField(
    "Project",
    "project_id",
    editProjectOptions(),
    state.editProjectId ? String(state.editProjectId) : "",
  );
  form.appendChild(coursePicker.label);
  form.appendChild(projectPicker.label);

  coursePicker.select.addEventListener("change", (event) => {
    state.editCourseId = event.target.value ? Number(event.target.value) : null;
    const refreshed = createOrgSelectField(
      "Project",
      "project_id",
      editProjectOptions(),
      state.editProjectId ? String(state.editProjectId) : "",
    );
    projectPicker.label.replaceWith(refreshed.label);
    attachProjectChange(refreshed.select);
  });
  attachProjectChange(projectPicker.select);

  const tagWrap = document.createElement("fieldset");
  tagWrap.className = "tag-fieldset";
  const tagLegend = document.createElement("legend");
  tagLegend.textContent = "Tags";
  const tagBox = document.createElement("div");
  tagBox.className = "tag-options";
  tagBox.id = "edit-tag-checkboxes";
  tagWrap.append(tagLegend, tagBox);
  form.appendChild(tagWrap);
  populateTagCheckboxesInto(tagBox);
  apiRequest(`/assignments/${assignment.id}/tags`)
    .then((links) => {
      const ids = new Set(links.map((link) => link.tag_id));
      tagBox
        .querySelectorAll('input[name="tag_ids"]')
        .forEach((el) => {
          el.checked = ids.has(Number(el.value));
        });
    })
    .catch(() => {});

  const buttons = document.createElement("div");
  buttons.className = "card-buttons full-width";

  const save = document.createElement("button");
  save.type = "submit";
  save.textContent = "Save";

  const cancel = document.createElement("button");
  cancel.className = "secondary-button";
  cancel.type = "button";
  cancel.textContent = "Cancel";
  cancel.addEventListener("click", renderDetail);

  buttons.append(save, cancel);
  form.appendChild(buttons);

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    saveAssignment(assignment, form);
  });

  dom.selectedDetail.append(heading, form);
}

function createInputField(labelText, name, type, value, required) {
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

function createSelectField(labelText, name, options, value) {
  const label = document.createElement("label");
  label.textContent = labelText;

  const select = document.createElement("select");
  select.name = name;

  options.forEach((option) => {
    const element = document.createElement("option");
    element.value = option;
    element.textContent = option;
    select.appendChild(element);
  });

  select.value = value;
  label.appendChild(select);
  return label;
}

function createTextAreaField(labelText, name, value) {
  const label = document.createElement("label");
  label.className = "full-width";
  label.textContent = labelText;

  const textarea = document.createElement("textarea");
  textarea.name = name;
  textarea.rows = 4;
  textarea.value = value;

  label.appendChild(textarea);
  return label;
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

async function apiRequest(path, options = {}) {
  const response = await fetch(`${API_BASE}${path}`, options);

  if (!response.ok) {
    let message = "Something went wrong. Please try again.";

    try {
      const errorData = await response.json();

      if (typeof errorData.detail === "string") {
        message = errorData.detail;
      } else if (Array.isArray(errorData.detail)) {
        message = errorData.detail
          .map((item) => item.msg || "Invalid value")
          .join("\n");
      }
    } catch {
      // Not every error response carries JSON; the fallback message stands.
    }

    throw new Error(message);
  }

  if (response.status === 204) {
    return null;
  }

  return response.json();
}

/* Loads are sequenced. Without this, a slow list request could resolve after a
   newer one and overwrite fresh state with stale rows. */
async function loadAssignments() {
  const generation = (state.loadGeneration += 1);

  state.inFlightLoads += 1;
  dom.refresh.classList.add("is-refreshing");
  hideError();

  try {
    const assignments = await apiRequest("/assignments");

    if (generation !== state.loadGeneration) {
      return;
    }

    state.all = Array.isArray(assignments) ? assignments : [];
    updateCourseFilter();
    updateSummaryCounts();
    applyFilters();
    await loadOrganization();
  } catch (error) {
    if (generation === state.loadGeneration) {
      showError(error.message);
    }
  } finally {
    state.inFlightLoads -= 1;

    if (state.inFlightLoads === 0) {
      dom.refresh.classList.remove("is-refreshing");
    }
  }
}

function applyFilters() {
  const selectedStatus = dom.statusFilter.value;
  const selectedCourse = dom.courseFilter.value;
  const searchText = dom.searchBox.value.trim().toLowerCase();

  state.visible = state.all
    .filter((assignment) => {
      const statusMatches =
        selectedStatus === "all" ||
        normalizeStatus(assignment.status) === selectedStatus;
      const courseMatches =
        selectedCourse === "all" || assignment.course_name === selectedCourse;
      const searchMatches =
        searchText === "" || matchesSearch(assignment, searchText);

      return statusMatches && courseMatches && searchMatches;
    })
    .sort(compareByDueDate);

  syncSelection();
  syncCards();
  updateFlowControls();
  renderDetail();
}

function compareByDueDate(first, second) {
  const firstTime = getDueTime(first.due_date);
  const secondTime = getDueTime(second.due_date);

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
}

function matchesSearch(assignment, searchText) {
  return [
    assignment.course_name,
    assignment.title,
    assignment.description,
    assignment.source_name,
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .includes(searchText);
}

function updateCourseFilter() {
  const previous = dom.courseFilter.value;
  const courseNames = [
    ...new Set(state.all.map((assignment) => assignment.course_name)),
  ]
    .filter(Boolean)
    .sort((first, second) => first.localeCompare(second));

  dom.courseFilter.replaceChildren(createOption("all", "all courses"));
  courseNames.forEach((courseName) => {
    dom.courseFilter.appendChild(createOption(courseName, courseName));
  });

  dom.courseFilter.value = courseNames.includes(previous) ? previous : "all";
}

function createOption(value, label) {
  const option = document.createElement("option");
  option.value = value;
  option.textContent = label;
  return option;
}

async function createAssignment(event) {
  event.preventDefault();
  hideError();

  const formData = new FormData(dom.form);
  const payload = {
    course_name: String(formData.get("course_name") || "").trim(),
    title: String(formData.get("title") || "").trim(),
    due_date: String(formData.get("due_date") || ""),
    priority: String(formData.get("priority") || "medium"),
    description: emptyToNull(formData.get("description")),
    source_url: emptyToNull(formData.get("source_url")),
    source_name: emptyToNull(formData.get("source_name")),
  };

  const courseId = state.draftCourseId;
  const projectId = state.draftProjectId;
  if (courseId) payload.course_id = courseId;
  if (projectId) payload.project_id = projectId;

  const tagIds = selectedTagIds();

  try {
    const created = await apiRequest("/assignments", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    for (const tagId of tagIds) {
      try {
        await apiRequest(`/assignments/${created.id}/tags/${tagId}`, {
          method: "POST",
        });
      } catch (tagError) {
        showError(`Linked tag failed: ${tagError.message}`);
      }
    }

    state.selectedId = created.id;
    state.detailExpanded = true;
    dom.form.reset();
    resetOrgForm();
    closeDialog();
    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

/* Status and delete apply locally first. The list is small and the request is
   local, but an optimistic write keeps the card from freezing mid-interaction
   while a round trip completes; a failure reloads the truth. */
async function changeStatus(assignment, nextStatus) {
  const previousStatus = assignment.status;

  if (normalizeStatus(previousStatus) === nextStatus) {
    return;
  }

  hideError();
  assignment.status = nextStatus;
  state.selectedId = assignment.id;
  applyFilters();

  try {
    await apiRequest(`/assignments/${assignment.id}/status`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: nextStatus }),
    });
    await loadAssignments();
  } catch (error) {
    assignment.status = previousStatus;
    showError(error.message);
    await loadAssignments();
  }
}

async function deleteAssignment(assignment) {
  hideError();

  const removedIndex = state.visible.findIndex((item) => item.id === assignment.id);
  state.all = state.all.filter((item) => item.id !== assignment.id);

  if (state.selectedId === assignment.id) {
    state.detailExpanded = false;
    const fallback = state.visible[removedIndex + 1] || state.visible[removedIndex - 1];
    state.selectedId = fallback ? fallback.id : null;
  }

  updateCourseFilter();
  updateSummaryCounts();
  applyFilters();

  try {
    await apiRequest(`/assignments/${assignment.id}`, { method: "DELETE" });
  } catch (error) {
    showError(error.message);
  }

  await loadAssignments();
}

async function saveAssignment(assignment, form) {
  hideError();

  if (!form.reportValidity()) {
    return;
  }

  const formData = new FormData(form);
  const courseIdRaw = form.querySelector('select[name="course_id"]')?.value || "";
  const projectIdRaw = form.querySelector('select[name="project_id"]')?.value || "";
  const edited = {
    course_name: String(formData.get("course_name") || "").trim(),
    title: String(formData.get("title") || "").trim(),
    due_date: String(formData.get("due_date") || ""),
    priority: String(formData.get("priority") || "medium"),
    description: emptyToNull(formData.get("description")),
    source_url: emptyToNull(formData.get("source_url")),
    source_name: emptyToNull(formData.get("source_name")),
    course_id: courseIdRaw ? Number(courseIdRaw) : null,
    project_id: projectIdRaw ? Number(projectIdRaw) : null,
  };

  const original = {
    course_name: assignment.course_name,
    title: assignment.title,
    due_date: toDateTimeLocal(assignment.due_date),
    priority: normalizePriority(assignment.priority),
    description: assignment.description || null,
    source_url: assignment.source_url || null,
    source_name: assignment.source_name || null,
    course_id: assignment.course_id || null,
    project_id: assignment.project_id || null,
  };

  const changes = {};

  Object.keys(edited).forEach((field) => {
    if (edited[field] !== original[field]) {
      changes[field] = edited[field];
    }
  });

  const tagChanges = await computeTagChanges(assignment, form);
  if (
    Object.keys(changes).length === 0 &&
    tagChanges.add.length === 0 &&
    tagChanges.remove.length === 0
  ) {
    renderDetail();
    return;
  }

  try {
    state.selectedId = assignment.id;
    state.detailExpanded = true;
    if (Object.keys(changes).length > 0) {
      await apiRequest(`/assignments/${assignment.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(changes),
      });
    }
    for (const tagId of tagChanges.add) {
      await apiRequest(`/assignments/${assignment.id}/tags/${tagId}`, {
        method: "POST",
      });
    }
    for (const tagId of tagChanges.remove) {
      await apiRequest(`/assignments/${assignment.id}/tags/${tagId}`, {
        method: "DELETE",
      });
    }
    await loadAssignments();
  } catch (error) {
    showError(error.message);
  }
}

// ---------------------------------------------------------------------------
// Summary counts
// ---------------------------------------------------------------------------

function updateSummaryCounts() {
  const today = startOfDay(new Date());
  const weekEnd = new Date(today);
  weekEnd.setDate(today.getDate() + 7);

  const summary = { total: 0, open: 0, today: 0, week: 0 };

  state.all.forEach((assignment) => {
    const status = normalizeStatus(assignment.status);
    const isComplete = status === "done";
    const dueTime = getDueTime(assignment.due_date);

    summary.total += 1;

    if (!isComplete) {
      summary.open += 1;
    }

    if (dueTime === null) {
      return;
    }

    const dueDay = startOfDay(new Date(dueTime));

    if (dueDay.getTime() === today.getTime()) {
      summary.today += 1;
    }

    if (!isComplete && dueDay >= today && dueDay <= weekEnd) {
      summary.week += 1;
    }
  });

  setCount(dom.counts.total, summary.total);
  setCount(dom.counts.open, summary.open);
  setCount(dom.counts.today, summary.today);
  setCount(dom.counts.week, summary.week);
}

/* A digit that swaps instantly reads as a rendering glitch; a short dip in
   opacity marks it as a change without pulling attention to the header. */
function setCount(element, value) {
  const text = String(value);

  if (element.textContent === text) {
    return;
  }

  if (reducedMotionQuery.matches) {
    element.textContent = text;
    return;
  }

  element.classList.add("is-changing");

  window.setTimeout(() => {
    element.textContent = text;
    element.classList.remove("is-changing");
  }, COUNT_SWAP_MS);
}

// ---------------------------------------------------------------------------
// Assignment helpers
// ---------------------------------------------------------------------------

function normalizeStatus(value) {
  const status = String(value || "todo").trim().toLowerCase();

  if (status === "not_started") {
    return "todo";
  }

  if (status === "completed") {
    return "done";
  }

  return STATUS_OPTIONS.includes(status) ? status : "todo";
}

function normalizePriority(value) {
  const priority = String(value || "medium").trim().toLowerCase();
  return PRIORITY_OPTIONS.includes(priority) ? priority : "medium";
}

function getProgress(assignment) {
  const status = normalizeStatus(assignment.status);

  if (status === "done") {
    return 100;
  }

  if (status === "in_progress") {
    return 64;
  }

  const dueTime = getDueTime(assignment.due_date);

  if (dueTime === null) {
    return 24;
  }

  const hoursLeft = (dueTime - Date.now()) / 3600000;

  if (hoursLeft < 0) {
    return 82;
  }

  if (hoursLeft <= 24) {
    return 58;
  }

  if (hoursLeft <= 72) {
    return 42;
  }

  return 22;
}

function isPastDue(assignment) {
  const dueTime = getDueTime(assignment.due_date);

  if (dueTime === null) {
    return false;
  }

  return (
    startOfDay(new Date(dueTime)) < startOfDay(new Date()) &&
    normalizeStatus(assignment.status) !== "done"
  );
}

function describeDueDate(assignment) {
  const dueTime = getDueTime(assignment.due_date);

  if (dueTime === null) {
    return "";
  }

  const today = startOfDay(new Date());
  const dueDay = startOfDay(new Date(dueTime));
  const dayDifference = Math.round((dueDay - today) / 86400000);

  if (dayDifference === 0) {
    return "Due today";
  }

  if (dayDifference > 0) {
    return `Due in ${dayDifference} ${dayDifference === 1 ? "day" : "days"}`;
  }

  if (normalizeStatus(assignment.status) !== "done") {
    return "Past due";
  }

  return formatDate(assignment.due_date);
}

/* The API serialises naive local wall times as "YYYY-MM-DD HH:MM". Passing that
   string straight to `new Date` relies on non-standard parsing, so the parts
   are read explicitly and built as a local date. */
function parseDate(value) {
  if (!value) {
    return null;
  }

  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }

  const text = String(value).trim();
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(text);

  if (match) {
    return new Date(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4] || 0),
      Number(match[5] || 0),
      Number(match[6] || 0),
    );
  }

  const fallback = new Date(text);
  return Number.isNaN(fallback.getTime()) ? null : fallback;
}

function getDueTime(value) {
  const date = parseDate(value);
  return date ? date.getTime() : null;
}

function formatDate(value) {
  const date = parseDate(value);
  return date ? date.toLocaleString() : "";
}

function toDateTimeLocal(value) {
  const date = parseDate(value);

  if (!date) {
    return "";
  }

  const pad = (part) => String(part).padStart(2, "0");

  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function safeHttpUrl(value) {
  if (!value) {
    return null;
  }

  try {
    const url = new URL(String(value), window.location.origin);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function emptyToNull(value) {
  const cleaned = String(value || "").trim();
  return cleaned || null;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function setText(element, text) {
  if (element.textContent !== text) {
    element.textContent = text;
  }
}

function createChip(text) {
  const chip = document.createElement("span");
  chip.className = "chip";
  chip.textContent = text;
  return chip;
}

function createEmptyMessage(text) {
  const message = document.createElement("p");
  message.className = "empty-message";
  message.textContent = text;
  return message;
}

// ---------------------------------------------------------------------------
// Dialog and errors
// ---------------------------------------------------------------------------

function openDialog() {
  if (typeof dom.dialog.showModal === "function") {
    dom.dialog.showModal();
  } else {
    dom.dialog.setAttribute("open", "");
  }

  document.querySelector("#course-name")?.focus();
}

function closeDialog() {
  if (dom.dialog.open && typeof dom.dialog.close === "function") {
    dom.dialog.close();
    return;
  }

  dom.dialog.removeAttribute("open");
}

function showError(message) {
  dom.errorMessage.textContent = message;
  dom.errorMessage.classList.add("visible");
}

function hideError() {
  dom.errorMessage.classList.remove("visible");
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function clearFilters() {
  dom.statusFilter.value = "all";
  dom.courseFilter.value = "all";
  dom.searchBox.value = "";
  state.detailExpanded = false;
  applyFilters();
}

function bindControls() {
  dom.form.addEventListener("submit", createAssignment);
  dom.openAdd.addEventListener("click", openDialog);
  dom.closeAdd.addEventListener("click", closeDialog);
  dom.refresh.addEventListener("click", loadAssignments);
  dom.statusFilter.addEventListener("change", applyFilters);
  dom.courseFilter.addEventListener("change", applyFilters);
  dom.clearFilters.addEventListener("click", clearFilters);
  dom.previousCard.addEventListener("click", () => moveSelection(-1));
  dom.nextCard.addEventListener("click", () => moveSelection(1));

  /* Debounced: every keystroke used to rebuild the whole shelf. */
  dom.searchBox.addEventListener("input", () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(applyFilters, SEARCH_DEBOUNCE_MS);
  });

  dom.dialog.addEventListener("click", (event) => {
    if (event.target === dom.dialog) {
      closeDialog();
    }
  });

  reducedMotionQuery.addEventListener("change", () => {
    settleSpring();
    requestFrame();
  });

  window.addEventListener("resize", requestFrame);
}

bindControls();
bindCarousel();
renderDetail();
loadAssignments();
initOrg();

// ---------------------------------------------------------------------------
// Organization (Phase 2): courses, projects, tags, subtasks, attachments, reminders
// ---------------------------------------------------------------------------

function selectedTagIds() {
  if (!dom.tagCheckboxes) return [];
  return [...dom.tagCheckboxes.querySelectorAll('input[name="tag_ids"]:checked')].map(
    (el) => Number(el.value),
  );
}

function resetOrgForm() {
  state.draftCourseId = null;
  state.draftProjectId = null;
  if (dom.coursePicker) dom.coursePicker.value = "";
  if (dom.projectPicker) dom.projectPicker.value = "";
  if (dom.tagCheckboxes) {
    dom.tagCheckboxes
      .querySelectorAll('input[name="tag_ids"]')
      .forEach((el) => {
        el.checked = false;
      });
  }
}

function matchedCourseId(assignment) {
  if (!assignment || !assignment.course_name) return null;
  const match = state.courses.find((c) => c.name === assignment.course_name);
  return match ? match.id : null;
}

function editProjectOptions() {
  return state.projects
    .filter((p) => !state.editCourseId || p.course_id === state.editCourseId)
    .map((p) => ({ value: String(p.id), label: p.name }));
}

function populateTagCheckboxesInto(container) {
  if (!container) return;
  container.replaceChildren();
  state.tags.forEach((tag) => {
    const label = document.createElement("label");
    label.className = "tag-check";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.value = String(tag.id);
    input.name = "tag_ids";
    const swatch = document.createElement("span");
    swatch.className = "tag-swatch";
    if (tag.color_hex) swatch.style.background = tag.color_hex;
    const text = document.createElement("span");
    text.textContent = tag.name;
    label.append(input, swatch, text);
    container.appendChild(label);
  });
}

function createOrgSelectField(labelText, name, options, selectedValue) {
  const label = document.createElement("label");
  label.textContent = labelText;
  const select = document.createElement("select");
  select.name = name;
  options.forEach((opt) => {
    const option = document.createElement("option");
    option.value = opt.value;
    option.textContent = opt.label;
    select.appendChild(option);
  });
  select.value = selectedValue;
  label.appendChild(select);
  return { label, select };
}

function attachProjectChange(select) {
  select.addEventListener("change", (event) => {
    state.editProjectId = event.target.value ? Number(event.target.value) : null;
  });
}

async function loadOrganization() {
  const generation = (state.orgGeneration += 1);
  try {
    const [courses, projects, tags] = await Promise.all([
      apiRequest("/courses"),
      apiRequest("/projects"),
      apiRequest("/tags"),
    ]);
    if (generation !== state.orgGeneration) return;
    state.courses = Array.isArray(courses) ? courses : [];
    state.projects = Array.isArray(projects) ? projects : [];
    state.tags = Array.isArray(tags) ? tags : [];
    populateCoursePicker();
    populateProjectPicker();
    populateTagCheckboxes();
    if (dom.orgDialog && dom.orgDialog.open) renderOrgManager();
  } catch (error) {
    console.warn("Organization load failed:", error.message);
    showError(`Organization data could not be loaded: ${error.message}`);
  }
}

function populateCoursePicker() {
  if (!dom.coursePicker) return;
  const previous = dom.coursePicker.value;
  dom.coursePicker.replaceChildren(createOption("", "— type a new course —"));
  state.courses.forEach((course) => {
    dom.coursePicker.appendChild(createOption(String(course.id), course.name));
  });
  dom.coursePicker.value = [...dom.coursePicker.options].some(
    (o) => o.value === previous,
  )
    ? previous
    : "";
}

function populateProjectPicker() {
  if (!dom.projectPicker) return;
  const previous = dom.projectPicker.value;
  dom.projectPicker.replaceChildren(createOption("", "— no project —"));
  state.projects
    .filter((p) => !state.draftCourseId || p.course_id === state.draftCourseId)
    .forEach((project) => {
      dom.projectPicker.appendChild(createOption(String(project.id), project.name));
    });
  dom.projectPicker.value = [...dom.projectPicker.options].some(
    (o) => o.value === previous,
  )
    ? previous
    : "";
}

function populateTagCheckboxes() {
  populateTagCheckboxesInto(dom.tagCheckboxes);
}

// ---------------------------------------------------------------------------
// Detail panel: subtasks, attachments, reminders
// ---------------------------------------------------------------------------

function buildOrgSections() {
  const fragment = document.createElement("div");
  fragment.className = "org-sections";

  const refs = {};
  const kinds = {
    subtasks: "Subtasks",
    attachments: "Attachments",
    reminders: "Reminders",
  };

  Object.entries(kinds).forEach(([kind, label]) => {
    const block = document.createElement("div");
    block.className = `org-block org-block-${kind}`;
    const heading = document.createElement("h3");
    heading.className = "org-block-title";
    heading.textContent = label;
    const list = document.createElement("ul");
    list.className = "org-list";
    list.dataset.orgKind = kind;
    const form = document.createElement("form");
    form.className = "org-add-form";
    form.dataset.orgKind = kind;
    block.append(heading, list, form);
    fragment.appendChild(block);
    refs[kind] = { block, list, form };
  });

  return {
    fragment,
    refs: {
      orgSubtasks: refs.subtasks,
      orgAttachments: refs.attachments,
      orgReminders: refs.reminders,
    },
  };
}

async function renderOrgSections(view, assignment) {
  if (!assignment) return;
  await renderSubtasks(view, assignment);
  await renderAttachments(view, assignment);
  await renderReminders(view, assignment);
}

function formatBytes(n) {
  if (n == null) return "";
  const units = ["B", "KB", "MB", "GB"];
  let size = Number(n);
  let i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i += 1;
  }
  return `${size.toFixed(size >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

async function sha256Hex(buffer) {
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function toUtcIso(localDateTime) {
  const date = new Date(localDateTime);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString().replace(".000Z", "Z");
}

async function renderSubtasks(view, assignment) {
  const { list, form } = view.orgSubtasks;
  try {
    const subtasks = await apiRequest(`/assignments/${assignment.id}/subtasks`);
    list.replaceChildren();
    (subtasks || []).forEach((sub) => {
      list.appendChild(createSubtaskRow(sub, assignment, view));
    });
  } catch (error) {
    list.replaceChildren(createEmptyMessage(error.message));
  }

  form.replaceChildren();
  const input = document.createElement("input");
  input.type = "text";
  input.name = "title";
  input.placeholder = "Add subtask";
  input.required = true;
  const addButton = document.createElement("button");
  addButton.type = "submit";
  addButton.className = "primary-button";
  addButton.textContent = "Add";
  form.append(input, addButton);
  form.onsubmit = async (event) => {
    event.preventDefault();
    const title = input.value.trim();
    if (!title) return;
    try {
      await apiRequest(`/assignments/${assignment.id}/subtasks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title, status: "todo" }),
      });
      await renderSubtasks(view, assignment);
    } catch (error) {
      showError(error.message);
    }
  };
}

function createSubtaskRow(sub, assignment, view) {
  const li = document.createElement("li");
  li.className = "org-row";
  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  const done = normalizeStatus(sub.status) === "done";
  checkbox.checked = done;
  checkbox.addEventListener("change", async () => {
    try {
      await apiRequest(`/assignments/${assignment.id}/subtasks/${sub.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: checkbox.checked ? "done" : "todo" }),
      });
      await renderSubtasks(view, assignment);
    } catch (error) {
      showError(error.message);
    }
  });
  const span = document.createElement("span");
  span.className = "org-row-title";
  span.textContent = sub.title;
  if (done) span.style.textDecoration = "line-through";
  const deleteButton = document.createElement("button");
  deleteButton.type = "button";
  deleteButton.className = "delete-button org-row-btn";
  deleteButton.setAttribute("aria-label", "Delete subtask");
  deleteButton.textContent = "✕";
  deleteButton.addEventListener("click", async () => {
    try {
      await apiRequest(`/assignments/${assignment.id}/subtasks/${sub.id}`, {
        method: "DELETE",
      });
      await renderSubtasks(view, assignment);
    } catch (error) {
      showError(error.message);
    }
  });
  li.append(checkbox, span, deleteButton);
  return li;
}

async function renderAttachments(view, assignment) {
  const { list, form } = view.orgAttachments;
  try {
    const items = await apiRequest(`/assignments/${assignment.id}/attachments`);
    list.replaceChildren();
    (items || []).forEach((attachment) => {
      const li = document.createElement("li");
      li.className = "org-row";
      const span = document.createElement("span");
      span.className = "org-row-title";
      span.textContent = `${attachment.file_name} · ${formatBytes(attachment.byte_size)}`;
      const sha = document.createElement("span");
      sha.className = "org-row-sub";
      sha.textContent = attachment.payload_available
        ? `${attachment.sha256.slice(0, 12)}…`
        : "Local file missing";
      const actions = document.createElement("span");
      actions.className = "org-row-actions";
      if (attachment.payload_available) {
        const openLink = document.createElement("a");
        openLink.className = "secondary-button org-row-btn";
        openLink.href = `/assignments/${assignment.id}/attachments/${attachment.id}/file`;
        openLink.target = "_blank";
        openLink.rel = "noopener";
        openLink.textContent = "Open";
        openLink.setAttribute("aria-label", `Open ${attachment.file_name}`);
        const exportLink = document.createElement("a");
        exportLink.className = "secondary-button org-row-btn";
        exportLink.href = `/assignments/${assignment.id}/attachments/${attachment.id}/file?download=true`;
        exportLink.textContent = "Export";
        exportLink.setAttribute("aria-label", `Export ${attachment.file_name}`);
        actions.append(openLink, exportLink);
      }
      const deleteButton = document.createElement("button");
      deleteButton.type = "button";
      deleteButton.className = "delete-button org-row-btn";
      deleteButton.setAttribute("aria-label", "Delete attachment");
      deleteButton.textContent = "✕";
      deleteButton.addEventListener("click", async () => {
        try {
          await apiRequest(
            `/assignments/${assignment.id}/attachments/${attachment.id}`,
            { method: "DELETE" },
          );
          await renderAttachments(view, assignment);
        } catch (error) {
          showError(error.message);
        }
      });
      actions.append(deleteButton);
      li.append(span, sha, actions);
      list.appendChild(li);
    });
  } catch (error) {
    list.replaceChildren(createEmptyMessage(error.message));
  }

  form.replaceChildren();
  const fileInput = document.createElement("input");
  fileInput.type = "file";
  fileInput.name = "file";
  const addButton = document.createElement("button");
  addButton.type = "submit";
  addButton.className = "primary-button";
  addButton.textContent = "Attach";
  form.append(fileInput, addButton);
  form.onsubmit = async (event) => {
    event.preventDefault();
    const file = fileInput.files && fileInput.files[0];
    if (!file) return;
    try {
      await apiRequest(`/assignments/${assignment.id}/attachments/file`, {
        method: "POST",
        headers: {
          "Content-Type": "application/octet-stream",
          "X-Attachment-Name": encodeURIComponent(file.name),
          "X-Attachment-Mime": file.type || "application/octet-stream",
        },
        body: file,
      });
      await renderAttachments(view, assignment);
    } catch (error) {
      showError(error.message);
    }
  };
}

async function renderReminders(view, assignment) {
  const { list, form } = view.orgReminders;
  try {
    const items = await apiRequest(`/assignments/${assignment.id}/reminders`);
    list.replaceChildren();
    (items || []).forEach((reminder) => {
      const li = document.createElement("li");
      li.className = "org-row";
      const span = document.createElement("span");
      span.className = "org-row-title";
      span.textContent = formatDate(reminder.trigger_at_utc);
      const sub = document.createElement("span");
      sub.className = "org-row-sub";
      sub.textContent = [
        reminder.repeat_rule ? `repeat ${reminder.repeat_rule}` : null,
        reminder.is_enabled ? "on" : "off",
      ]
        .filter(Boolean)
        .join(" · ");
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "secondary-button org-row-btn";
      toggle.textContent = reminder.is_enabled ? "Disable" : "Enable";
      toggle.addEventListener("click", async () => {
        try {
          await apiRequest(
            `/assignments/${assignment.id}/reminders/${reminder.id}`,
            {
              method: "PATCH",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ is_enabled: !reminder.is_enabled }),
            },
          );
          await renderReminders(view, assignment);
        } catch (error) {
          showError(error.message);
        }
      });
      const deleteButton = document.createElement("button");
      deleteButton.type = "button";
      deleteButton.className = "delete-button org-row-btn";
      deleteButton.setAttribute("aria-label", "Delete reminder");
      deleteButton.textContent = "✕";
      deleteButton.addEventListener("click", async () => {
        try {
          await apiRequest(
            `/assignments/${assignment.id}/reminders/${reminder.id}`,
            { method: "DELETE" },
          );
          await renderReminders(view, assignment);
        } catch (error) {
          showError(error.message);
        }
      });
      li.append(span, sub, toggle, deleteButton);
      list.appendChild(li);
    });
  } catch (error) {
    list.replaceChildren(createEmptyMessage(error.message));
  }

  form.replaceChildren();
  const dateTime = document.createElement("input");
  dateTime.type = "datetime-local";
  dateTime.name = "trigger_at_utc";
  dateTime.required = true;
  const addButton = document.createElement("button");
  addButton.type = "submit";
  addButton.className = "primary-button";
  addButton.textContent = "Add";
  form.append(dateTime, addButton);
  form.onsubmit = async (event) => {
    event.preventDefault();
    const utc = toUtcIso(dateTime.value);
    if (!utc) return;
    try {
      await apiRequest(`/assignments/${assignment.id}/reminders`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ trigger_at_utc: utc, lead_minutes: 0, is_enabled: true }),
      });
      await renderReminders(view, assignment);
    } catch (error) {
      showError(error.message);
    }
  };
}

// ---------------------------------------------------------------------------
// Organization manager dialog (courses / projects / tags CRUD)
// ---------------------------------------------------------------------------

function createOrgRow({ title, subtitle, swatch, onRename, onDelete }) {
  const li = document.createElement("li");
  li.className = "org-row";
  const main = document.createElement("div");
  main.className = "org-row-main";
  if (swatch) {
    const sw = document.createElement("span");
    sw.className = "tag-swatch";
    sw.style.background = swatch;
    main.appendChild(sw);
  }
  const titleSpan = document.createElement("span");
  titleSpan.className = "org-row-title";
  titleSpan.textContent = title;
  main.appendChild(titleSpan);
  if (subtitle) {
    const sub = document.createElement("span");
    sub.className = "org-row-sub";
    sub.textContent = subtitle;
    main.appendChild(sub);
  }
  const actions = document.createElement("div");
  actions.className = "org-row-actions";
  const editButton = document.createElement("button");
  editButton.type = "button";
  editButton.className = "secondary-button org-row-btn";
  editButton.textContent = "Rename";
  editButton.addEventListener("click", () => startRename(li, titleSpan, onRename));
  const deleteButton = document.createElement("button");
  deleteButton.type = "button";
  deleteButton.className = "delete-button org-row-btn";
  deleteButton.textContent = "Delete";
  deleteButton.addEventListener("click", onDelete);
  actions.append(editButton, deleteButton);
  li.append(main, actions);
  return li;
}

function startRename(li, titleSpan, onRename) {
  if (li.querySelector("input.org-rename-input")) return;
  const input = document.createElement("input");
  input.type = "text";
  input.className = "org-rename-input";
  input.value = titleSpan.textContent;
  titleSpan.replaceWith(input);
  input.focus();
  input.select();
  const commit = () => {
    const value = input.value.trim();
    if (value && value !== titleSpan.textContent) {
      onRename(value);
    } else {
      input.replaceWith(titleSpan);
    }
  };
  input.addEventListener("blur", commit);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      input.blur();
    } else if (event.key === "Escape") {
      input.replaceWith(titleSpan);
    }
  });
}

function renderOrgManager() {
  dom.orgCourseList.replaceChildren();
  state.courses.forEach((course) => {
    dom.orgCourseList.appendChild(
      createOrgRow({
        title: course.name,
        subtitle: [course.teacher, course.semester].filter(Boolean).join(" · ") || null,
        swatch: course.color_hex,
        onRename: (newName) =>
          apiRequest(`/courses/${course.id}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: newName }),
          })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
        onDelete: () =>
          apiRequest(`/courses/${course.id}`, { method: "DELETE" })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
      }),
    );
  });

  dom.orgProjectList.replaceChildren();
  state.projects.forEach((project) => {
    const courseName =
      state.courses.find((c) => c.id === project.course_id)?.name || null;
    dom.orgProjectList.appendChild(
      createOrgRow({
        title: project.name,
        subtitle: courseName,
        onRename: (newName) =>
          apiRequest(`/projects/${project.id}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: newName }),
          })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
        onDelete: () =>
          apiRequest(`/projects/${project.id}`, { method: "DELETE" })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
      }),
    );
  });

  dom.orgTagList.replaceChildren();
  state.tags.forEach((tag) => {
    dom.orgTagList.appendChild(
      createOrgRow({
        title: tag.name,
        swatch: tag.color_hex,
        onRename: (newName) =>
          apiRequest(`/tags/${tag.id}`, {
            method: "PATCH",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: newName }),
          })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
        onDelete: () =>
          apiRequest(`/tags/${tag.id}`, { method: "DELETE" })
            .then(loadOrganization)
            .catch((error) => showError(error.message)),
      }),
    );
  });

  if (dom.orgProjectCourseSelect) {
    dom.orgProjectCourseSelect.replaceChildren(createOption("", "— no course —"));
    state.courses.forEach((course) => {
      dom.orgProjectCourseSelect.appendChild(
        createOption(String(course.id), course.name),
      );
    });
  }
}

function openOrgDialog() {
  if (typeof dom.orgDialog.showModal === "function") {
    dom.orgDialog.showModal();
  } else {
    dom.orgDialog.setAttribute("open", "");
  }
  renderOrgManager();
}

function closeOrgDialog() {
  if (dom.orgDialog.open && typeof dom.orgDialog.close === "function") {
    dom.orgDialog.close();
    return;
  }
  dom.orgDialog.removeAttribute("open");
}

async function computeTagChanges(assignment, form) {
  const box = form.querySelector("#edit-tag-checkboxes");
  const selected = new Set(
    box
      ? [...box.querySelectorAll('input[name="tag_ids"]:checked')].map((el) =>
          Number(el.value),
        )
      : [],
  );
  let current = new Set();
  try {
    const links = await apiRequest(`/assignments/${assignment.id}/tags`);
    current = new Set(links.map((link) => link.tag_id));
  } catch {
    // If tag links cannot be read, treat as no diff to avoid clobbering.
  }
  const add = [...selected].filter((id) => !current.has(id));
  const remove = [...current].filter((id) => !selected.has(id));
  return { add, remove };
}

function initOrg() {
  if (dom.openOrg) {
    dom.openOrg.addEventListener("click", openOrgDialog);
  }
  if (dom.closeOrg) {
    dom.closeOrg.addEventListener("click", closeOrgDialog);
  }
  if (dom.orgDialog) {
    dom.orgDialog.addEventListener("click", (event) => {
      if (event.target === dom.orgDialog) closeOrgDialog();
    });
  }

  if (dom.orgDialog) {
    dom.orgDialog.querySelectorAll(".org-tab").forEach((tab) => {
      tab.addEventListener("click", () => {
        const target = tab.dataset.orgTab;
        dom.orgDialog
          .querySelectorAll(".org-tab")
          .forEach((t) => t.classList.toggle("is-active", t === tab));
        dom.orgDialog
          .querySelectorAll(".org-panel")
          .forEach((panel) => {
            panel.hidden = panel.dataset.orgPanel !== target;
          });
      });
    });
  }

  if (dom.orgCourseForm) {
    dom.orgCourseForm.addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = dom.orgCourseForm.querySelector("#org-course-name").value.trim();
      if (!name) return;
      const teacher = emptyToNull(
        dom.orgCourseForm.querySelector("#org-course-teacher").value,
      );
      const colorHex =
        dom.orgCourseForm.querySelector("#org-course-color").value.trim() || null;
      try {
        await apiRequest("/courses", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, teacher, color_hex: colorHex }),
        });
        dom.orgCourseForm.reset();
        await loadOrganization();
      } catch (error) {
        showError(error.message);
      }
    });
  }

  if (dom.orgProjectForm) {
    dom.orgProjectForm.addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = dom.orgProjectForm.querySelector("#org-project-name").value.trim();
      if (!name) return;
      const courseIdRaw = dom.orgProjectForm.querySelector("#org-project-course").value;
      const courseId = courseIdRaw ? Number(courseIdRaw) : null;
      try {
        await apiRequest("/projects", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, course_id: courseId }),
        });
        dom.orgProjectForm.reset();
        await loadOrganization();
      } catch (error) {
        showError(error.message);
      }
    });
  }

  if (dom.orgTagForm) {
    dom.orgTagForm.addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = dom.orgTagForm.querySelector("#org-tag-name").value.trim();
      if (!name) return;
      const colorHex =
        dom.orgTagForm.querySelector("#org-tag-color").value.trim() || null;
      try {
        await apiRequest("/tags", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, color_hex: colorHex }),
        });
        dom.orgTagForm.reset();
        await loadOrganization();
      } catch (error) {
        showError(error.message);
      }
    });
  }

  if (dom.coursePicker) {
    dom.coursePicker.addEventListener("change", () => {
      const id = dom.coursePicker.value;
      if (id) {
        const course = state.courses.find((c) => String(c.id) === id);
        state.draftCourseId = Number(id);
        const nameInput = dom.form.querySelector("#course-name");
        if (course && nameInput) nameInput.value = course.name;
      } else {
        state.draftCourseId = null;
      }
      populateProjectPicker();
    });
  }

  if (dom.projectPicker) {
    dom.projectPicker.addEventListener("change", () => {
      state.draftProjectId = dom.projectPicker.value
        ? Number(dom.projectPicker.value)
        : null;
    });
  }
}
