@echo off
:: ========== Anti-Crash Guard Shell ==========
if /i not "%~1"=="--guarded" (
    start "Relay Launcher" cmd /k ""%~f0" --guarded"
    exit /b 0
)
:: ========== End Guard ==========
setlocal enabledelayedexpansion
title Relay Server Startup
echo   ========================================
echo     Hearing-Assist Relay - Startup Script
echo   ========================================
set "SCRIPT_DIR=%~dp0"
set "RELAY_PORT=8262"

:: 1. Check and clean port
echo [1/4] Checking port %RELAY_PORT%...
for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":%RELAY_PORT% " ^| findstr "LISTENING"') do (
    echo   Port in use ^(PID: %%a^), killing...
    taskkill /F /PID %%a >nul 2>&1
)

:: 2. Enter relay directory
echo [2/4] Checking relay folder...
cd /d "%SCRIPT_DIR%"
if errorlevel 1 ( echo   ERROR: cannot cd into relay folder & goto :hold )
if not exist "app.py" ( echo   ERROR: app.py not found & goto :hold )

:: 3. Check python deps (auto install)
echo [3/4] Checking python dependencies...
python -c "import fastapi, uvicorn, qrcode" >nul 2>&1
if errorlevel 1 (
    echo   Installing dependencies from requirements.txt...
    call python -m pip install -r requirements.txt
    if errorlevel 1 ( echo   pip install failed & goto :hold )
)

:: 4. Start relay server
echo [4/4] Starting relay server on port %RELAY_PORT%...
start "Relay-8262" cmd /k "python -m uvicorn app:app --host 0.0.0.0 --port %RELAY_PORT%"
timeout /t 3 /nobreak >nul

echo   Startup complete!  Relay: http://localhost:%RELAY_PORT%/health
echo   H5 result page pattern: http://localhost:%RELAY_PORT%/r/{code}

:hold
echo.
echo Press any key to close this launcher window...
pause >nul
endlocal
