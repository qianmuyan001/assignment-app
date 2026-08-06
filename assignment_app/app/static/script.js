:root {
  color-scheme: dark;
  --background: #060807;
  --surface: rgba(18, 23, 21, 0.58);
  --surface-strong: rgba(27, 34, 31, 0.76);
  --surface-soft: rgba(255, 255, 255, 0.07);
  --surface-hover: rgba(255, 255, 255, 0.12);
  --border: rgba(255, 255, 255, 0.16);
  --border-strong: rgba(255, 255, 255, 0.26);
  --text: #f5fbf7;
  --muted: rgba(229, 239, 234, 0.66);
  --faint: rgba(229, 239, 234, 0.42);
  --primary: #36e286;
  --primary-dark: #16a765;
  --primary-soft: rgba(54, 226, 134, 0.12);
  --cyan: #62d7f7;
  --warning: #ffbe55;
  --danger: #ff5f6d;
  --danger-bg: rgba(255, 95, 109, 0.12);
  --shadow: 0 30px 90px rgba(0, 0, 0, 0.48);
  --spring: cubic-bezier(0.18, 0.89, 0.32, 1.28);
  --apple-out: cubic-bezier(0.2, 0, 0, 1);
  --apple-standard: cubic-bezier(0.25, 0.1, 0.25, 1);
}

* {
  box-sizing: border-box;
}

html {
  min-height: 100%;
  background: var(--background);
}

body {
  min-height: 100vh;
  margin: 0;
  overflow-x: hidden;
  background:
    radial-gradient(circle at 52% 5%, rgba(70, 255, 157, 0.18), transparent 29rem),
    radial-gradient(circle at 86% 72%, rgba(98, 215, 247, 0.12), transparent 24rem),
    radial-gradient(circle at 16% 86%, rgba(255, 190, 85, 0.08), transparent 18rem),
    linear-gradient(145deg, #050605 0%, #0c100e 46%, #050706 100%);
  color: var(--text);
  font-family: Inter, -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", sans-serif;
  line-height: 1.5;
}

button,
input,
textarea,
select {
  font: inherit;
}

button {
  position: relative;
  isolation: isolate;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  min-height: 44px;
  padding: 11px 16px;
  overflow: hidden;
  border: 1px solid transparent;
  border-radius: 14px;
  color: #ffffff;
  font-weight: 760;
  cursor: pointer;
  transform: translate3d(0, 0, 0);
  transition:
    transform 460ms var(--spring),
    border-color 320ms var(--apple-out),
    background 320ms var(--apple-out),
    box-shadow 320ms var(--apple-out),
    color 320ms var(--apple-out),
    opacity 240ms var(--apple-out);
  user-select: none;
}

button::after {
  content: "";
  position: absolute;
  inset: 0;
  z-index: -1;
  background: radial-gradient(circle at var(--press-x, 50%) var(--press-y, 50%), rgba(255, 255, 255, 0.32), transparent 32%);
  opacity: 0;
  transform: scale(0.74);
  transition: opacity 360ms var(--apple-out), transform 520ms var(--spring);
}

button:hover:not(:disabled) {
  transform: translateY(-2px) scale(1.015);
}

button:active:not(:disabled),
button.is-pressing:not(:disabled) {
  transform: translateY(1px) scale(0.965);
  transition-duration: 120ms;
}

button.is-pressing::after {
  opacity: 1;
  transform: scale(1.14);
}

button:disabled {
  cursor: not-allowed;
  opacity: 0.38;
}

button:focus-visible,
input:focus-visible,
textarea:focus-visible,
select:focus-visible,
a:focus-visible,
.cover-flow:focus-visible {
  outline: 2px solid rgba(98, 215, 247, 0.92);
  outline-offset: 3px;
}

h1,
h2,
h3,
p {
  margin-top: 0;
}

h1 {
  margin-bottom: 0;
  font-size: clamp(2.15rem, 4vw, 4.5rem);
  line-height: 0.95;
  letter-spacing: 0;
}

h2 {
  margin-bottom: 0;
  font-size: clamp(1.22rem, 2vw, 1.68rem);
  line-height: 1.1;
  letter-spacing: 0;
}

a {
  color: #91f7c0;
  word-break: break-word;
}

.scene {
  position: fixed;
  inset: 0;
  z-index: -2;
  pointer-events: none;
}

.scene::before {
  content: "";
  position: absolute;
  inset: 0;
  background-image:
    linear-gradient(rgba(255, 255, 255, 0.035) 1px, transparent 1px),
    linear-gradient(90deg, rgba(255, 255, 255, 0.035) 1px, transparent 1px);
  background-size: 42px 42px;
  mask-image: linear-gradient(to bottom, transparent, #000 18%, #000 78%, transparent);
}

.scanline {
  position: absolute;
  inset: 0;
  background: repeating-linear-gradient(to bottom, rgba(255, 255, 255, 0.028), rgba(255, 255, 255, 0.028) 1px, transparent 1px, transparent 7px);
  opacity: 0.18;
}

.glass-rail {
  position: absolute;
  width: 56vw;
  height: 92px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 999px;
  background: linear-gradient(90deg, rgba(255, 255, 255, 0.04), rgba(50, 215, 130, 0.12), rgba(255, 255, 255, 0.03));
  filter: blur(0.2px);
  transform: rotate(-6deg);
}

.rail-one {
  top: 94px;
  left: 20vw;
}

.rail-two {
  right: -7vw;
  bottom: 15vh;
  opacity: 0.42;
}

.beam {
  position: absolute;
  width: 42vw;
  height: 42vw;
  border-radius: 50%;
  filter: blur(76px);
  opacity: 0.28;
}

.beam-green {
  top: 18vh;
  left: -12vw;
  background: #26d676;
}

.beam-cyan {
  right: -18vw;
  bottom: -8vw;
  background: #52cff4;
}

.page {
  width: min(1540px, calc(100% - 32px));
  margin: 0 auto;
  padding: 28px 0 40px;
}

.glass-panel {
  position: relative;
  overflow: hidden;
  border: 1px solid var(--border);
  background:
    linear-gradient(145deg, rgba(255, 255, 255, 0.12), rgba(255, 255, 255, 0.035)),
    var(--surface);
  box-shadow: var(--shadow), inset 0 1px 0 rgba(255, 255, 255, 0.18);
  backdrop-filter: blur(26px) saturate(1.45);
  -webkit-backdrop-filter: blur(26px) saturate(1.45);
}

.glass-panel::before {
  content: "";
  position: absolute;
  inset: 0;
  border-radius: inherit;
  background: linear-gradient(115deg, rgba(255, 255, 255, 0.17), transparent 32%, rgba(50, 215, 130, 0.09) 62%, transparent);
  opacity: 0.66;
  pointer-events: none;
}

.page-header {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: end;
  gap: 22px;
  min-height: 214px;
  margin-bottom: 18px;
  padding: clamp(22px, 4vw, 42px);
  border-radius: 32px;
}

.brand-area,
.header-actions,
.command-strip,
.section,
.list-header,
.filters,
.flow-toolbar,
.flow-stage,
.selected-detail {
  position: relative;
  z-index: 1;
}

.brand-area {
  display: flex;
  align-items: center;
  gap: 18px;
}

.brand-mark {
  display: grid;
  flex: 0 0 auto;
  width: 64px;
  height: 64px;
  place-items: center;
  border: 1px solid rgba(255, 255, 255, 0.22);
  border-radius: 20px;
  background:
    linear-gradient(145deg, rgba(113, 255, 176, 0.28), rgba(21, 165, 92, 0.11)),
    rgba(3, 8, 6, 0.34);
  box-shadow: 0 18px 48px rgba(28, 200, 112, 0.2), inset 0 1px 0 rgba(255, 255, 255, 0.32);
  backdrop-filter: blur(18px) saturate(1.35);
  -webkit-backdrop-filter: blur(18px) saturate(1.35);
  color: #f9fff9;
  font-size: 1.9rem;
  font-weight: 850;
}

.header-actions {
  display: grid;
  gap: 12px;
  justify-items: end;
  align-self: start;
}

.eyebrow {
  margin-bottom: 9px;
  color: var(--muted);
  font-size: 0.75rem;
  font-weight: 760;
  letter-spacing: 0;
  text-transform: uppercase;
}

.command-strip {
  display: grid;
  grid-template-columns: repeat(4, minmax(70px, 1fr));
  gap: 8px;
  min-width: min(460px, 100%);
  padding: 8px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 24px;
  background: rgba(0, 0, 0, 0.24);
  backdrop-filter: blur(20px) saturate(1.25);
  -webkit-backdrop-filter: blur(20px) saturate(1.25);
}

.strip-item {
  padding: 12px 12px 11px;
  border-radius: 18px;
  background: rgba(255, 255, 255, 0.06);
}

.strip-item.accent {
  border: 1px solid rgba(116, 255, 182, 0.2);
  background:
    linear-gradient(145deg, rgba(54, 226, 134, 0.16), rgba(255, 255, 255, 0.06)),
    rgba(0, 0, 0, 0.18);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.14), 0 0 28px rgba(54, 226, 134, 0.12);
}

.strip-value,
.strip-label {
  display: block;
}

.strip-value {
  color: #ffffff;
  font-size: 1.45rem;
  font-weight: 850;
  line-height: 1;
}

.strip-label {
  margin-top: 4px;
  color: var(--faint);
  font-size: 0.72rem;
  font-weight: 720;
}

.app-workspace {
  display: grid;
  grid-template-columns: minmax(620px, 1.42fr) minmax(320px, 0.58fr);
  gap: 18px;
  align-items: start;
}

.section {
  border-radius: 28px;
}

.detail-panel {
  position: sticky;
  top: 22px;
  padding: 22px;
}

.flow-panel {
  min-height: 650px;
  padding: 22px;
}

.section-heading {
  margin-bottom: 18px;
}

.assignment-form,
.filters,
.edit-form {
  position: relative;
  z-index: 1;
  display: grid;
  gap: 14px;
}

.assignment-form,
.detail-edit-form {
  grid-template-columns: 1fr;
}

.filters {
  grid-template-columns: 0.78fr 0.88fr minmax(170px, 1.15fr) auto;
  align-items: end;
  margin-bottom: 16px;
}

label {
  display: grid;
  gap: 8px;
  color: var(--muted);
  font-size: 0.78rem;
  font-weight: 760;
}

input,
textarea,
select {
  width: 100%;
  min-height: 44px;
  padding: 11px 13px;
  border: 1px solid rgba(255, 255, 255, 0.13);
  border-radius: 14px;
  background: rgba(255, 255, 255, 0.08);
  color: var(--text);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
  transition:
    background 240ms var(--apple-out),
    border-color 240ms var(--apple-out),
    box-shadow 240ms var(--apple-out),
    transform 360ms var(--spring);
}

textarea {
  resize: vertical;
}

select {
  appearance: none;
  background-image:
    linear-gradient(45deg, transparent 50%, rgba(244, 251, 247, 0.72) 50%),
    linear-gradient(135deg, rgba(244, 251, 247, 0.72) 50%, transparent 50%);
  background-position:
    calc(100% - 18px) 50%,
    calc(100% - 13px) 50%;
  background-size: 5px 5px, 5px 5px;
  background-repeat: no-repeat;
  padding-right: 34px;
}

input:hover,
textarea:hover,
select:hover {
  background-color: rgba(255, 255, 255, 0.105);
  border-color: rgba(255, 255, 255, 0.2);
}

input:focus,
textarea:focus,
select:focus {
  background-color: rgba(255, 255, 255, 0.13);
  border-color: rgba(98, 215, 247, 0.6);
  box-shadow: 0 0 0 5px rgba(98, 215, 247, 0.11), inset 0 1px 0 rgba(255, 255, 255, 0.12);
  transform: translateY(-1px);
}

input::placeholder {
  color: rgba(229, 239, 234, 0.38);
}

.primary-button {
  width: 100%;
  border-color: rgba(116, 255, 182, 0.34);
  background:
    linear-gradient(145deg, rgba(106, 255, 174, 0.22), rgba(19, 143, 82, 0.1)),
    rgba(0, 0, 0, 0.28);
  box-shadow:
    0 18px 42px rgba(23, 190, 102, 0.18),
    0 0 32px rgba(54, 226, 134, 0.1),
    inset 0 1px 0 rgba(255, 255, 255, 0.28),
    inset 0 -16px 38px rgba(54, 226, 134, 0.08);
  backdrop-filter: blur(20px) saturate(1.35);
  -webkit-backdrop-filter: blur(20px) saturate(1.35);
}

.primary-button:hover {
  border-color: rgba(136, 255, 194, 0.52);
  background:
    linear-gradient(145deg, rgba(126, 255, 190, 0.3), rgba(22, 167, 101, 0.14)),
    rgba(0, 0, 0, 0.34);
  box-shadow:
    0 20px 48px rgba(23, 190, 102, 0.22),
    0 0 48px rgba(54, 226, 134, 0.16),
    inset 0 1px 0 rgba(255, 255, 255, 0.34),
    inset 0 -16px 42px rgba(54, 226, 134, 0.1);
}

.header-add-button {
  width: auto;
  min-width: 176px;
  justify-self: end;
}

.secondary-button {
  background: rgba(255, 255, 255, 0.08);
  border-color: rgba(255, 255, 255, 0.14);
  color: var(--text);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.12);
}

.secondary-button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.14);
  border-color: rgba(255, 255, 255, 0.22);
}

.delete-button {
  background: var(--danger-bg);
  border-color: rgba(255, 95, 109, 0.2);
  color: #ffd4d8;
}

.delete-button:hover:not(:disabled) {
  background: rgba(255, 95, 109, 0.22);
  border-color: rgba(255, 95, 109, 0.36);
}

.icon-button {
  width: 46px;
  min-width: 46px;
  height: 46px;
  padding: 0;
  border-radius: 16px;
}

.refresh-glyph {
  position: relative;
  width: 18px;
  height: 18px;
  border: 2px solid currentColor;
  border-right-color: transparent;
  border-radius: 50%;
  transition: transform 560ms var(--spring);
}

.refresh-glyph::after {
  content: "";
  position: absolute;
  top: -3px;
  right: -2px;
  width: 7px;
  height: 7px;
  border-top: 2px solid currentColor;
  border-right: 2px solid currentColor;
  transform: rotate(26deg);
}

.icon-button:hover .refresh-glyph {
  transform: rotate(132deg);
}

.button-icon {
  display: grid;
  width: 22px;
  height: 22px;
  place-items: center;
  border-radius: 999px;
  border: 1px solid rgba(155, 255, 204, 0.24);
  background: rgba(0, 0, 0, 0.2);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.18), 0 0 18px rgba(54, 226, 134, 0.16);
}

.add-dialog {
  position: fixed;
  width: min(560px, calc(100vw - 28px));
  max-height: min(760px, calc(100vh - 38px));
  margin: auto;
  padding: 22px;
  overflow: auto;
  border-radius: 28px;
  color: var(--text);
  transform: translateY(10px) scale(0.97);
  opacity: 0;
}

.add-dialog[open] {
  animation: dialog-in 420ms var(--spring) forwards;
}

.add-dialog::backdrop {
  background:
    radial-gradient(circle at 50% 40%, rgba(54, 226, 134, 0.12), transparent 28rem),
    rgba(0, 0, 0, 0.58);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
}

.dialog-header {
  position: relative;
  z-index: 1;
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 18px;
}

.full-width {
  grid-column: 1 / -1;
}

.error-message {
  display: none;
  margin: 0 0 14px;
  padding: 12px 14px;
  border: 1px solid rgba(255, 95, 109, 0.28);
  border-radius: 16px;
  background: var(--danger-bg);
  color: #ffdce0;
  font-weight: 760;
}

.error-message.visible {
  display: block;
  animation: notice-in 380ms var(--spring) both;
}

.list-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 18px;
}

.flow-toolbar {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  margin: 4px 0 12px;
}

.flow-position {
  min-width: 90px;
  padding: 10px 14px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.2);
  color: var(--muted);
  font-size: 0.82rem;
  font-weight: 780;
  text-align: center;
}

.flow-stage {
  min-height: 474px;
  overflow: hidden;
  border-radius: 24px;
  background:
    radial-gradient(ellipse at 50% 58%, rgba(54, 226, 134, 0.08), transparent 35%),
    radial-gradient(ellipse at 50% 98%, rgba(98, 215, 247, 0.12), transparent 38%),
    linear-gradient(180deg, rgba(255, 255, 255, 0.04), rgba(0, 0, 0, 0.18));
  perspective: 1200px;
  perspective-origin: 50% 44%;
}

.orbit-line {
  position: absolute;
  left: 50%;
  top: 54%;
  width: min(94%, 860px);
  height: 160px;
  border-top: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 50%;
  box-shadow: 0 -18px 48px rgba(54, 226, 134, 0.09);
  opacity: 0.72;
  transform: translateX(-50%) rotateX(66deg);
}

.cover-flow {
  --drag-x: 0px;
  position: relative;
  width: 100%;
  min-height: 474px;
  cursor: grab;
  touch-action: pan-y;
  transform-style: preserve-3d;
  transform: translateX(var(--drag-x));
  transition: transform 320ms var(--apple-out);
}

.cover-flow.is-dragging {
  cursor: grabbing;
  transition-duration: 80ms;
}

.cover-flow.is-gliding .flow-card,
.cover-flow.is-dragging .flow-card {
  transition:
    transform 120ms var(--apple-out),
    opacity 120ms var(--apple-out),
    filter 120ms var(--apple-out),
    border-color 220ms var(--apple-out),
    background 220ms var(--apple-out),
    box-shadow 220ms var(--apple-out);
}

.cover-flow.is-empty {
  display: grid;
  place-items: center;
  cursor: default;
}

.flow-card {
  --card-accent: rgba(245, 251, 247, 0.82);
  position: absolute;
  left: 50%;
  top: 50%;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  width: 212px;
  height: 330px;
  padding: 22px 18px;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 26px;
  background:
    linear-gradient(112deg, rgba(255, 255, 255, 0.36), rgba(255, 255, 255, 0.08) 32%, rgba(255, 255, 255, 0.18) 68%, rgba(255, 255, 255, 0.05)),
    rgba(234, 242, 238, 0.14);
  box-shadow:
    calc(var(--offset) * -9px) 32px 62px rgba(0, 0, 0, 0.48),
    inset 0 1px 0 rgba(255, 255, 255, 0.46),
    inset 0 -18px 48px rgba(255, 255, 255, 0.08);
  color: #f9fffb;
  opacity: var(--opacity);
  filter: blur(var(--blur)) saturate(var(--saturate));
  transform:
    translate(-50%, -50%)
    translateX(var(--x))
    translateZ(var(--z))
    rotateY(var(--rotate))
    rotateZ(calc(var(--offset) * -0.55deg))
    scale(var(--scale));
  transform-style: preserve-3d;
  transition:
    transform 720ms var(--spring),
    opacity 420ms var(--apple-out),
    filter 520ms var(--apple-out),
    border-color 360ms var(--apple-out),
    background 360ms var(--apple-out),
    box-shadow 520ms var(--apple-out);
  user-select: none;
}

.flow-card::before,
.flow-card::after {
  content: "";
  position: absolute;
  pointer-events: none;
}

.flow-card::before {
  inset: 9px;
  border: 1px solid rgba(255, 255, 255, 0.26);
  border-radius: 21px;
  background:
    linear-gradient(90deg, rgba(255, 255, 255, 0.2), transparent 14%, transparent 86%, rgba(255, 255, 255, 0.16)),
    repeating-linear-gradient(90deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0.06) 1px, transparent 1px, transparent 14px);
  opacity: 0.58;
}

.flow-card::after {
  inset: -30% -55%;
  background: linear-gradient(105deg, transparent 24%, rgba(255, 255, 255, 0.36) 38%, transparent 52%);
  opacity: 0.46;
  transform: translateX(calc(var(--offset) * -16px)) rotate(3deg);
}

.flow-card:hover:not(.is-selected) {
  border-color: rgba(255, 255, 255, 0.38);
  opacity: min(1, calc(var(--opacity) + 0.18));
  filter: blur(var(--hover-blur)) saturate(1.22);
  transform:
    translate(-50%, -50%)
    translateX(var(--x))
    translateZ(calc(var(--z) + 58px))
    rotateY(calc(var(--rotate) * 0.86))
    rotateZ(calc(var(--offset) * -0.35deg))
    scale(calc(var(--scale) + 0.035));
}

.flow-card.is-selected {
  --card-accent: var(--primary);
  width: 252px;
  height: 360px;
  border-color: rgba(119, 255, 181, 0.5);
  background:
    radial-gradient(circle at 50% 26%, rgba(255, 255, 255, 0.18), transparent 27%),
    linear-gradient(135deg, rgba(146, 255, 194, 0.24), rgba(40, 201, 116, 0.1) 42%, rgba(255, 255, 255, 0.11)),
    rgba(0, 0, 0, 0.24);
  box-shadow:
    0 42px 92px rgba(0, 0, 0, 0.55),
    0 0 56px rgba(54, 226, 134, 0.28),
    0 0 120px rgba(54, 226, 134, 0.12),
    inset 0 1px 0 rgba(255, 255, 255, 0.45),
    inset 0 -24px 70px rgba(5, 255, 132, 0.08);
  backdrop-filter: blur(20px) saturate(1.36);
  -webkit-backdrop-filter: blur(20px) saturate(1.36);
  opacity: 1;
  filter: blur(0) saturate(1.45);
}

.flow-card.is-selected::before {
  border-color: rgba(195, 255, 220, 0.54);
  background:
    radial-gradient(circle at 50% 27%, rgba(255, 255, 255, 0.32), transparent 18%),
    linear-gradient(90deg, rgba(255, 255, 255, 0.22), transparent 16%, transparent 84%, rgba(255, 255, 255, 0.2)),
    repeating-linear-gradient(90deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.1) 1px, transparent 1px, transparent 13px);
}

.flow-card.is-far {
  pointer-events: none;
}

.flow-card.status-in_progress {
  --card-accent: var(--cyan);
}

.flow-card.status-ignored {
  --card-accent: rgba(229, 239, 234, 0.48);
}

.flow-card.is-past-due {
  --card-accent: var(--danger);
}

.disc-core {
  position: absolute;
  left: 50%;
  top: 30%;
  width: 116px;
  height: 116px;
  border: 1px solid rgba(255, 255, 255, 0.28);
  border-radius: 50%;
  background:
    radial-gradient(circle, rgba(0, 0, 0, 0.48) 0 13%, rgba(255, 255, 255, 0.24) 14% 15%, transparent 16%),
    conic-gradient(from 80deg, rgba(255, 255, 255, 0.02), rgba(255, 255, 255, 0.34), rgba(54, 226, 134, 0.12), rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.02));
  box-shadow: inset 0 0 22px rgba(255, 255, 255, 0.16), 0 0 26px rgba(255, 255, 255, 0.1);
  opacity: 0.7;
  transform: translateX(-50%);
}

.flow-card.is-selected .disc-core {
  border-color: rgba(162, 255, 202, 0.55);
  box-shadow: inset 0 0 22px rgba(255, 255, 255, 0.24), 0 0 38px rgba(54, 226, 134, 0.24);
  opacity: 0.94;
}

.flow-course,
.flow-due,
.flow-meta,
.flow-card h3,
.progress-meter {
  position: relative;
  z-index: 1;
}

.flow-course {
  width: fit-content;
  max-width: 100%;
  margin-bottom: 10px;
  padding: 6px 9px;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.2);
  color: rgba(245, 251, 247, 0.8);
  font-size: 0.72rem;
  font-weight: 780;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.flow-card h3,
.selected-hero h3 {
  margin-bottom: 8px;
  color: #ffffff;
  font-size: 1.1rem;
  line-height: 1.14;
  letter-spacing: 0;
}

.flow-card h3 {
  display: -webkit-box;
  overflow: hidden;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
}

.flow-card.is-selected h3 {
  font-size: 1.26rem;
}

.flow-due,
.selected-due {
  margin-bottom: 13px;
  color: rgba(245, 251, 247, 0.7);
  font-size: 0.82rem;
}

.flow-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
  margin-bottom: 13px;
}

.chip {
  display: inline-flex;
  align-items: center;
  min-height: 26px;
  max-width: 100%;
  padding: 5px 8px;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.17);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(245, 251, 247, 0.78);
  font-size: 0.72rem;
  font-weight: 760;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.progress-meter {
  height: 7px;
  overflow: hidden;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.24);
  box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.24);
}

.progress-meter span {
  display: block;
  width: var(--progress);
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, var(--card-accent), rgba(255, 255, 255, 0.78));
  box-shadow: 0 0 18px var(--card-accent);
  transition: width 620ms var(--spring);
}

.selected-detail {
  display: grid;
  gap: 14px;
}

.selected-hero {
  --card-accent: var(--primary);
  position: relative;
  overflow: hidden;
  padding: 18px;
  border: 1px solid rgba(119, 255, 181, 0.28);
  border-radius: 22px;
  background:
    radial-gradient(circle at 70% 0%, rgba(98, 215, 247, 0.12), transparent 34%),
    linear-gradient(145deg, rgba(54, 226, 134, 0.12), rgba(255, 255, 255, 0.055)),
    rgba(0, 0, 0, 0.26);
  box-shadow: 0 24px 58px rgba(0, 0, 0, 0.34), 0 0 34px rgba(54, 226, 134, 0.08), inset 0 1px 0 rgba(255, 255, 255, 0.18);
  backdrop-filter: blur(18px) saturate(1.22);
  -webkit-backdrop-filter: blur(18px) saturate(1.22);
}

.selected-hero::before {
  content: "";
  position: absolute;
  inset: -20% -40%;
  background: linear-gradient(110deg, transparent 30%, rgba(255, 255, 255, 0.22), transparent 56%);
  opacity: 0.46;
}

.detail-actions {
  display: grid;
  grid-template-columns: 1fr;
  gap: 10px;
}

.detail-actions .status-control {
  width: 100%;
}

.full-detail-button {
  width: 100%;
}

.detail-extra {
  display: grid;
  gap: 10px;
  padding: 16px;
  border: 1px solid rgba(255, 255, 255, 0.13);
  border-radius: 18px;
  background: rgba(255, 255, 255, 0.055);
  animation: detail-in 420ms var(--spring) both;
}

.detail-extra p {
  margin-bottom: 0;
  color: var(--muted);
}

.detail-extra strong {
  color: var(--text);
}

.card-buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 9px;
}

.card-buttons button {
  flex: 1 1 112px;
}

.empty-message {
  margin-bottom: 0;
  padding: 48px 24px;
  border: 1px dashed rgba(255, 255, 255, 0.18);
  border-radius: 22px;
  background: rgba(255, 255, 255, 0.045);
  color: var(--muted);
  text-align: center;
}

@keyframes detail-in {
  0% {
    opacity: 0;
    transform: translateY(-8px) scale(0.98);
  }
  100% {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@keyframes notice-in {
  0% {
    opacity: 0;
    transform: translateY(-8px) scale(0.98);
  }
  100% {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@keyframes dialog-in {
  0% {
    opacity: 0;
    transform: translateY(12px) scale(0.965);
  }
  70% {
    opacity: 1;
    transform: translateY(-2px) scale(1.006);
  }
  100% {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    scroll-behavior: auto !important;
    transition-duration: 1ms !important;
    animation-duration: 1ms !important;
    animation-iteration-count: 1 !important;
  }
}

@media (max-width: 1240px) {
  .app-workspace {
    grid-template-columns: 1fr;
  }

  .detail-panel {
    position: relative;
    top: auto;
  }

  .selected-detail {
    grid-template-columns: minmax(260px, 0.8fr) minmax(320px, 1.2fr);
    align-items: start;
  }

  .selected-detail .full-detail-button,
  .selected-detail .detail-extra,
  .selected-detail .section-heading,
  .selected-detail .detail-edit-form {
    grid-column: 1 / -1;
  }
}

@media (max-width: 980px) {
  .page-header,
  .app-workspace {
    grid-template-columns: 1fr;
  }

  .header-actions {
    justify-items: stretch;
  }

  .command-strip {
    width: 100%;
  }

  .detail-panel {
    position: relative;
    top: auto;
  }

  .selected-detail {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 720px) {
  .page {
    width: min(100% - 20px, 1540px);
    padding-top: 10px;
  }

  .page-header,
  .flow-panel,
  .detail-panel {
    border-radius: 24px;
    padding: 18px;
  }

  .brand-area {
    align-items: flex-start;
  }

  .brand-mark {
    width: 52px;
    height: 52px;
    border-radius: 17px;
    font-size: 1.55rem;
  }

  .command-strip,
  .filters {
    grid-template-columns: 1fr;
  }

  .header-add-button {
    width: 100%;
  }

  .add-dialog {
    padding: 18px;
    border-radius: 24px;
  }

  .flow-stage,
  .cover-flow {
    min-height: 430px;
  }

  .flow-card {
    width: 178px;
    height: 292px;
    padding: 18px 14px;
    transform:
      translate(-50%, -50%)
      translateX(calc(var(--offset) * 78px))
      translateZ(var(--z))
      rotateY(calc(var(--rotate) * 0.64))
      scale(var(--scale));
  }

  .flow-card.is-selected {
    width: 214px;
    height: 322px;
  }

  .disc-core {
    width: 90px;
    height: 90px;
  }

  .flow-toolbar,
  .list-header,
  .card-buttons {
    align-items: stretch;
    flex-direction: column;
  }

  .icon-button {
    width: 100%;
  }
}
