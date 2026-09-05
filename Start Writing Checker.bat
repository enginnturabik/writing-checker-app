@echo off
setlocal
title Writing Checker launcher
cd /d "%~dp0"

echo ===============================================
echo   Writing Checker
echo ===============================================
echo.

if not exist "server\.env" (
  echo ERROR: server\.env is missing.
  echo Copy server\.env.example to server\.env and put your Anthropic key in it.
  echo.
  pause
  exit /b 1
)

if not exist "server\node_modules" (
  echo Installing server dependencies, one moment...
  pushd server
  call npm install
  popd
  echo.
)

REM The web bundle is what gets served, so build it the first time.
if not exist "build\web\main.dart.js" (
  echo First run - building the app. This takes a couple of minutes.
  echo.
  call flutter build web --release
  if errorlevel 1 (
    echo.
    echo ERROR: the build failed. Scroll up for the reason.
    pause
    exit /b 1
  )
  echo.
)

echo Starting the server...
start "Writing Checker - server" /min "%~dp0tools\run-server.bat"

echo Starting the app...
start "Writing Checker - app" /min "%~dp0tools\run-app.bat"

REM Poll rather than guess at a fixed delay.
echo Waiting for them to come up...
set /a tries=0

:wait
set /a tries+=1
if %tries% gtr 60 goto timeout
curl -s -o nul http://127.0.0.1:8787/health
if errorlevel 1 (
  ping -n 2 127.0.0.1 >nul
  goto wait
)
curl -s -o nul http://127.0.0.1:5123/
if errorlevel 1 (
  ping -n 2 127.0.0.1 >nul
  goto wait
)

echo.
echo Ready. Opening the app...
start "" http://127.0.0.1:5123
echo.
echo Two small windows are running it in the background.
echo Close them, or run "Stop Writing Checker.bat", to shut everything down.
ping -n 6 127.0.0.1 >nul
exit /b 0

:timeout
echo.
echo ERROR: they did not start within a minute.
echo Check the two background windows for the reason.
pause
exit /b 1
