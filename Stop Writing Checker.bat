@echo off
setlocal
title Writing Checker - stop
cd /d "%~dp0"

echo Stopping Writing Checker...

REM Close the two launcher windows by their titles, so unrelated Node work
REM on this machine is left alone.
taskkill /f /fi "WINDOWTITLE eq Writing Checker - server*" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq Writing Checker - app*" >nul 2>&1

REM Anything still holding the two ports is ours as well.
for %%P in (8787 5123) do (
  for /f "tokens=5" %%A in ('netstat -ano ^| findstr ":%%P" ^| findstr "LISTENING"') do (
    taskkill /f /pid %%A >nul 2>&1
  )
)

echo Stopped.
ping -n 3 127.0.0.1 >nul
