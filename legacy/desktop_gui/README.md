# Archived Python desktop GUI

This CustomTkinter frontend is retained for historical compatibility and for
its HTML import workflow. It is not an active 2.0 platform deliverable and is
not launched by the repository root start scripts.

The archived client still talks to the FastAPI backend over HTTP. Start the
backend from the repository root:

```bash
source .venv/bin/activate
uvicorn backend.app.main:app --reload
```

Then launch the archived GUI from a second terminal:

```bash
source .venv/bin/activate
python legacy/desktop_gui/main_window.py
```

To use another backend URL:

```bash
ASSIGNMENT_API_BASE_URL=http://127.0.0.1:8000 \
  python legacy/desktop_gui/main_window.py
```

Retained features include English/Chinese UI switching, task CRUD, search,
status/course filters, appearance settings, and reviewed HTML import using the
Auto, AI, or Rule-based parser modes.

New product work should target the web client, `native/apple/`, or
`native/windows/`. Changes here should be limited to compatibility or data
recovery needs.
