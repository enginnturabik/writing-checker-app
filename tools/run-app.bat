@echo off
title Writing Checker - app
cd /d "%~dp0.."
node "tools\serve-web.mjs"
echo.
echo The app server stopped. Press any key to close.
pause >nul
