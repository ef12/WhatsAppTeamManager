@echo off
setlocal
cd /d "%~dp0"
if not exist node_modules (echo Run install-reader.cmd first.& pause& exit /b 1)
npm start
pause
