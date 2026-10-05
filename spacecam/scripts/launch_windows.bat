@echo off
setlocal
cd /d "%~dp0.."
if not exist ".venv\Scripts\python.exe" (
    py -3 -m venv .venv
    if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -c "import spacecam, PySide6, scipy, trimesh, matplotlib, PIL, h5py" >nul 2>&1
if errorlevel 1 (
    ".venv\Scripts\python.exe" -m pip install -e .
    if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -m spacecam
if errorlevel 1 goto failed
exit /b 0
:failed
echo Setup or launch failed. Install Python 3.11 or newer and check the error above.
pause
exit /b 1
