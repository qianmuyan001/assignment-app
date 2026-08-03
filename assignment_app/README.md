# Assignment App

This is a simple assignment app for collecting school assignments from different sources and storing them in one shared format.

It has a FastAPI backend and a beginner-friendly frontend built with plain HTML, CSS, and JavaScript.

For now, assignments are saved in a local JSON file. There is no database, login system, scraping, frontend framework, or AI parsing yet.

## What It Does

- Saves assignments with course name, title, due date, description, source information, status, and timestamps.
- Stores data in `data/assignments.json`.
- Provides API endpoints for creating, reading, updating, changing status, and deleting assignments.
- Shows a simple web page where you can add, view, edit, filter, search, change status, and delete assignments.
- Includes placeholder source reader files for future manual, web, and AI-based assignment collection.

## Install Packages

From this folder:

```bash
cd /Users/qianmuyan/Desktop/assignment-app/assignment_app
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run The Backend

```bash
uvicorn app.main:app --reload
```

## Open The Frontend

After the server starts, open:

- `http://127.0.0.1:8000`

That page is served by FastAPI from `app/static/index.html`.

The API docs are still available at:

- `http://127.0.0.1:8000/docs`

## How The Frontend Talks To The API

The frontend JavaScript in `app/static/script.js` uses `fetch()` to call the FastAPI routes:

- `GET /assignments` when the page loads.
- `POST /assignments` when the form is submitted.
- `PATCH /assignments/{assignment_id}` when an assignment edit is saved.
- `PATCH /assignments/{assignment_id}/status` when a status dropdown changes.
- `DELETE /assignments/{assignment_id}` when a delete button is clicked.

After each successful change, the frontend loads the assignment list again.

## Sort, Filter, And Search

The assignment list is sorted in the browser by due date from earliest to latest.

Assignments without a valid due date are placed at the bottom.

Above the assignment list, you can use:

- Status filter: show all assignments or only `todo`, `in_progress`, `done`, or `ignored`.
- Course filter: show all courses or one course from the current assignment list.
- Search box: search course name, title, description, and source name.
- Clear Filters button: reset status, course, and search back to the full list.

Each assignment card also shows a small due date helper, such as `Due today`, `Due in 3 days`, or `Past due`.

## Edit An Assignment

On the frontend page, each assignment card has an Edit button.

Click Edit to change:

- Course name
- Title
- Due date
- Description
- Source URL
- Source name

Click Save to send the changed fields to `PATCH /assignments/{assignment_id}`.

Click Cancel to return to the normal assignment card without saving.

## Test Endpoints

Create an assignment:

```bash
curl -X POST "http://127.0.0.1:8000/assignments" \
  -H "Content-Type: application/json" \
  -d '{
    "course_name": "Math",
    "title": "Homework 1",
    "due_date": "2026-07-15T23:59:00",
    "description": "Finish problems 1-10",
    "source_url": "https://example.com/math",
    "source_name": "Manual Entry",
    "status": "todo"
  }'
```

Get all assignments:

```bash
curl "http://127.0.0.1:8000/assignments"
```

Get one assignment:

```bash
curl "http://127.0.0.1:8000/assignments/1"
```

Update an assignment:

```bash
curl -X PATCH "http://127.0.0.1:8000/assignments/1" \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Homework 1"}'
```

Update only the status:

```bash
curl -X PATCH "http://127.0.0.1:8000/assignments/1/status" \
  -H "Content-Type: application/json" \
  -d '{"status": "done"}'
```

Delete an assignment:

```bash
curl -X DELETE "http://127.0.0.1:8000/assignments/1"
```

## Important Files

- `app/main.py`: Creates the FastAPI app.
- `app/routes.py`: Defines the API endpoints.
- `app/schemas.py`: Defines the assignment data models and validation rules.
- `app/storage.py`: Loads and saves assignments in the local JSON file.
- `app/static/index.html`: Defines the frontend page and filter controls.
- `app/static/style.css`: Adds the simple page styling, including the filter bar and edit form layout.
- `app/static/script.js`: Calls the backend API, sorts assignments, filters the list, updates the page, and handles edit mode.
- `app/source_readers/base.py`: Shows the shared interface for future assignment sources.
- `app/source_readers/manual_reader.py`: Converts manual input into the shared assignment format.
- `app/source_readers/placeholder_web_reader.py`: Placeholder for future website readers.
- `data/assignments.json`: Local storage file.

## What To Study Next

Start with the list helper functions in `app/static/script.js`: `renderFilteredAssignments`, `filterAssignments`, and `sortAssignmentsByDueDate`.

After that, study `app/routes.py` to see how each frontend request is handled by FastAPI.

## Future Steps

- Add a simple dashboard summary, such as counts for todo, in progress, done, and past due assignments.
- Add source readers for real websites or school systems.
- Add AI parsing after raw assignment text is collected.
- Replace JSON storage with a real database when the app grows.
- Add login only when multiple users need separate assignment lists.
