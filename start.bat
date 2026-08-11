@echo off
setlocal

REM Start the Assignment Schedule App on Windows.
REM This creates .venv if needed, starts the backend, opens the web client,
REM and stops the backend when the user closes this launcher.

set "PROJECT_ROOT=%~dp0"
set "PID_FILE=%PROJECT_ROOT%.assignment_app_backend.pid"

cd /d "%PROJECT_ROOT%"
if errorlevel 1 (
    echo Could not open the project folder: %PROJECT_ROOT%
    pause
    exit /b 1
)

where py >nul 2>nul
if %errorlevel%==0 (
    set "PYTHON=py -3"
) else (
    where python >nul 2>nul
    if errorlevel 1 (
        echo Python was not found. Please install Python 3 first.
        pause
        exit /b 1
    )
    set "PYTHON=python"
)

if not exist ".venv\Scripts\python.exe" (
    echo Creating virtual environment...
    %PYTHON% -m venv .venv
    if errorlevel 1 (
        echo Could not create the virtual environment.
        pause
        exit /b 1
    )
)

call ".venv\Scripts\activate.bat"
if errorlevel 1 (
    echo Could not activate the virtual environment.
    pause
    exit /b 1
)

echo Installing dependencies...
python -m pip install -r requirements.txt
if errorlevel 1 (
    echo Could not install dependencies from requirements.txt.
    pause
    exit /b 1
)

echo Starting backend...
set "BACKEND_PID="
for /f %%P in ('powershell -NoProfile -Command "$process = Start-Process -FilePath '.venv\Scripts\python.exe' -ArgumentList '-m uvicorn backend.app.main:app --host 127.0.0.1 --port 8000' -WorkingDirectory '%PROJECT_ROOT%' -WindowStyle Hidden -PassThru; $process.Id"') do (
    set "BACKEND_PID=%%P"
)

if not defined BACKEND_PID (
    echo Could not start the backend process.
    pause
    exit /b 1
)

echo %BACKEND_PID%>"%PID_FILE%"

echo Waiting for backend to be ready...
python scripts\wait_for_backend.py http://127.0.0.1:8000 --timeout 90
if errorlevel 1 (
    echo The backend did not become ready.
    taskkill /PID %BACKEND_PID% /T /F >nul 2>nul
    if exist "%PID_FILE%" del "%PID_FILE%"
    pause
    exit /b 1
)

echo Opening web client...
start "" http://127.0.0.1:8000

echo Web client is running at http://127.0.0.1:8000.
echo Press any key to stop the backend.
pause >nul

echo Stopping backend...
taskkill /PID %BACKEND_PID% /T /F >nul 2>nul
if exist "%PID_FILE%" del "%PID_FILE%"

exit /b 0
