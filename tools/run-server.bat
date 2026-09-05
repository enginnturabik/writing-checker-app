@echo off
title Writing Checker - server
cd /d "%~dp0..\server"
npm run dev
echo.
echo The server stopped. Press any key to close.
pause >nul
