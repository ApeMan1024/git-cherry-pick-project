@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0git-cherry-pick-gui.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" echo GUI exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
