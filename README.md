# Assignment Schedule App

[![Latest release](https://img.shields.io/github/v/release/qianmuyan001/assignment-app?display_name=tag)](https://github.com/qianmuyan001/assignment-app/releases/latest)

This project has a FastAPI backend, a SQLite database, and a desktop GUI for managing school assignments.

Current version: **2.0.0**. See [CHANGELOG.md](CHANGELOG.md) for release history. Versions follow [Semantic Versioning](https://semver.org/): fixes increment the patch number, backward-compatible features increment the minor number, and breaking changes increment the major number.

## Assignment App 2.0 preview

The repository now contains the shared 2.0 task contract, a versioned SQLite v2
migration, and independent Apple and Windows implementations of the first 2.0
task-management workflow. Both clients use the same task fields, status and
priority mappings, date-list rules, fixtures, and acceptance cases.

Because the original iPadOS project was not present, the approved Apple
alternative is a real SwiftUI iPadOS project at
`native/apple/AssignmentApp2.xcodeproj`. Its single application target also
supports Mac Catalyst, while the existing `native/macos` SwiftPM 1.0 client is
preserved unchanged. The Apple client provides task CRUD, completion/restoring,
All/Today/This Week/Overdue/Completed views, search, filters, sorting,
simple/professional modes, and persistent appearance settings. See
`native/apple/README.md` for the database safety model and verification details.

Shared rules and disposable migration tests:

```bash
python3 -m unittest discover -s shared/tests -v
```

Apple iPad Simulator and Mac Catalyst builds require the installed full Xcode
beta and an available iPad simulator UUID:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project native/apple/AssignmentApp2.xcodeproj \
  -scheme AssignmentApp2 -configuration Debug \
  -destination 'platform=iOS Simulator,id=55D6D2F6-FB7A-429C-ADFA-8BF9F8F2286F' \
  -derivedDataPath /private/tmp/assignment-app-xcode-derived-data \
  CODE_SIGNING_ALLOWED=NO build

./native/apple/package-catalyst.sh
```

The packaging script writes an ad-hoc-signed Debug app, ZIP, logs, and build
metadata to a new timestamped directory under `artifacts/apple/`.

Windows x64 build and publish (run on Windows with Visual Studio 2022 and the
.NET 8 SDK installed):

```powershell
.\native\windows\publish-x64.ps1
```

The resulting self-contained test directory is `artifacts\windows-x64`. See
`native/windows/README.md` for prerequisites, manual commands, database
selection, and smoke-test details.

The active backend lives in `backend/`. The desktop GUI lives in `desktop_gui/` and talks to the backend through HTTP requests.

## Native macOS and Windows versions

The performance-focused clients now live in `native/` and share the existing
SQLite assignment schema without replacing or deleting the database.

| Platform | UI/browser | Secure credential store | Status |
| --- | --- | --- | --- |
| Apple | SwiftUI iPadOS + Mac Catalyst | Local app sandbox | 2.0 Debug preview; iPad and Apple Silicon Catalyst builds verified |
| macOS legacy | SwiftUI + WKWebView | macOS Keychain | Existing 1.0 native baseline retained unchanged |
| Windows | WinUI 3 + WebView2 | Windows Credential Locker | 2.0 preview source; build and smoke-test on Windows |

Apple 2.0:

```bash
open native/apple/AssignmentApp2.xcodeproj
./native/apple/package-catalyst.sh
```

Legacy macOS 1.0:

```bash
cd /path/to/assignment-app
./native/local-ai/start-macos.command
open native/macos/dist/Assignments.app
```

The llama.cpp runtime is included. On first use, the start script downloads the
default Qwen3 1.7B model into llama.cpp's local cache.
For copying the app, use
`native/macos/dist/Assignments-macOS-arm64.zip`.

The retained native macOS 1.0 source connector supports two login modes:

1. Interactive login: type the password directly into the website. The app and
   model never read the password.
2. Saved credential fill: store one credential for an exact HTTPS website
   origin (host and non-default port) in the operating system credential store.
   Filling is opt-in and never submits the form.

After login, choose **Scan Current Page**. Visible page text is sent only to the
loopback local model, strict JSON candidates are shown for review, and confirmed
items are inserted with duplicate detection.

See `native/README.md`, `native/SECURITY.md`, and the platform README files for
build and security details.

## One-click Start

The easiest way to run the whole app is to use the start scripts in the project root.

For macOS or Linux Terminal:

```bash
cd /path/to/assignment-app
./start.sh
```

For macOS Finder double click:

- Double-click `start.command`.

If macOS blocks the file or says it is not executable, run this once:

```bash
cd /path/to/assignment-app
chmod +x start.sh start.command
```

For Windows:

```bat
start.bat
```

The start script will:

- Open the project folder automatically.
- Create `.venv` if it does not exist.
- Install packages from `requirements.txt`.
- Start the FastAPI backend in the background.
- Start the desktop GUI.
- Stop the backend when the GUI closes.

If the backend is left running for any reason, stop it with:

```bash
cd /path/to/assignment-app
./stop.sh
```

## Install

From the project root:

```bash
cd /path/to/assignment-app
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run The Backend

```bash
cd /path/to/assignment-app
source .venv/bin/activate
uvicorn backend.app.main:app --reload
```

The API will run at:

- `http://127.0.0.1:8000`
- `http://127.0.0.1:8000/docs`

## Run The Desktop GUI

Open a second terminal while the backend is still running:

```bash
cd /path/to/assignment-app
source .venv/bin/activate
python desktop_gui/main_window.py
```

To point the GUI at a different backend URL:

```bash
ASSIGNMENT_API_BASE_URL=http://127.0.0.1:8000 python desktop_gui/main_window.py
```

## HTML Import

The desktop GUI can import possible assignments from a local `.html` or `.htm` file that you saved manually from Canvas or another course website.

How to use it:

1. Start the app with `./start.sh` or start the backend and GUI manually.
2. Choose a parser mode in the desktop GUI: `Auto`, `AI`, or `Rule-based`.
3. Click `Import from HTML`.
4. Choose a local `.html` or `.htm` file.
5. Enter a default course name.
6. Review the extracted assignments before saving anything.
7. Edit any fields that need cleanup.
8. Click `Import` for one item or `Import all` for every pending item.
9. Click `Ignore` for anything that is not really an assignment.

How to save an HTML page manually:

1. Open the assignment page, module page, or course page in your browser.
2. Use the browser's save option.
3. Choose `Webpage, HTML only` if your browser offers that option.
4. Save the file somewhere easy to find.
5. Select that saved file from the desktop GUI.

What this feature can do:

- Read a local HTML file selected by you.
- Remove scripts and page markup to get readable text.
- Use AI parsing when configured, or simple rules as a fallback.
- Track where imported assignments came from with `source_name`, `source_type`, `source_file`, and `source_url`.
- Leave the due date blank if no date is detected.

Limitations of the legacy Python HTML importer:

- It does not log in to Canvas or any course website.
- It does not automatically scrape websites.
- It does not perfectly understand every course page layout.
- It may find extra items or miss assignments, so review before importing.

The separate native clients add the secure signed-in browser and local AI page
scanner; the statements above apply only to the legacy HTML-file importer.

## AI Assignment Parsing

The HTML importer now uses a reusable import pipeline:

```text
input source -> raw content -> cleaned text -> parser -> normalized candidates -> pending review -> confirmed import -> saved assignments
```

Parser modes:

- `Auto`: tries AI if configured, then falls back to rule-based parsing.
- `AI`: uses AI only. If AI is not configured, the GUI shows a clear error.
- `Rule-based`: skips AI and uses the local rule parser.

The app still works without API keys. AI parsed assignments are never saved automatically; they always go to the pending review window first.

OpenAI setup example:

```bash
export ASSIGNMENT_AI_PROVIDER=openai
export ASSIGNMENT_AI_MODEL=gpt-4o-mini
export OPENAI_API_KEY=your_key_here
```

Local model future setup example:

```bash
export ASSIGNMENT_AI_PROVIDER=ollama
export ASSIGNMENT_AI_MODEL=llama3.1
export ASSIGNMENT_AI_BASE_URL=http://localhost:11434
```

For local development tests, a mock AI response can be provided with:

```bash
export ASSIGNMENT_AI_PROVIDER=mock
export ASSIGNMENT_AI_MOCK_RESPONSE='[]'
```

Future AI agent page downloading can reuse `parse_import_content()` in `backend/app/services/import_pipeline.py` directly. It accepts cleaned text plus source information, so a future agent can pass Canvas page text, browser-exported HTML text, PDF text, CSV text, or pasted text without requiring a local file path.

## Desktop GUI Features

- Use English by default or switch the interface to Chinese in **Settings → Language**. The choice is remembered for future launches.
- View all assignments.
- Search by course, title, description, source name, link, or source URL.
- Filter by status and course.
- Sort by due date, earliest first.
- Add, edit, delete, and mark assignments completed.
- Import possible assignments from a local HTML file with Auto, AI, or Rule-based parsing.
- Show totals for incomplete, completed, overdue, due today, and due this week assignments.

## Current Backend Fields

The current SQLite backend supports:

- `course_name`
- `title`
- `due_date`
- `description`
- `link`
- `source_name`
- `source_type`
- `source_file`
- `source_url`
- `status`
- `priority` (`low`, `medium`, or `high`; existing records migrate to `medium`)

The 2.0 API and desktop UI use `todo`, `in_progress`, and `done`. SQLite keeps
the compatible 1.0 values `not_started`, `in_progress`, and `completed`; the
Repository layer performs the mapping. A successful upgrade sets
`PRAGMA user_version=2`. Existing databases are backed up with SQLite's online
backup API before any migration, including databases with uncheckpointed WAL
content.

Manual assignments use `source_type` as `manual`. HTML imports use `source_type` as `local_html` and store the selected file name in `source_file`.
