@echo off
rem Installs Claude Token Overlay (see install.ps1). Pass -Uninstall to remove it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 pause
