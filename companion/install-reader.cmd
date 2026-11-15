@echo off
setlocal
cd /d "%~dp0"
where node >nul 2>nul || (echo Install Node.js 22.13 or newer first.& pause& exit /b 1)
call npm ci
if errorlevel 1 goto failed
echo Companion dependencies are ready. The reader will use installed Google Chrome.
pause
exit /b 0

:failed
echo Setup failed. Review the error above and try again.
pause
exit /b 1
