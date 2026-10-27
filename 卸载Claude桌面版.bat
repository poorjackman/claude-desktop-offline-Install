@echo off
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if not %errorlevel%==0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-claude-desktop.ps1"

endlocal
