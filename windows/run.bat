@echo off
rem Starts Claude Token Overlay without a console window.
where pyw >nul 2>nul && (start "" pyw "%~dp0token_overlay.py" & exit /b)
where pythonw >nul 2>nul && (start "" pythonw "%~dp0token_overlay.py" & exit /b)
echo Python 3 not found. Install it from https://www.python.org/downloads/ (tick "Add to PATH").
pause
