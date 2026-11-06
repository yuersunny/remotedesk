@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
set "KIT=%CD%"

set "NODE="
if exist "%KIT%\node\node.exe" set "NODE=%KIT%\node\node.exe"
if not defined NODE (
  where node >nul 2>nul
  if not errorlevel 1 set "NODE=node"
)
if not defined NODE (
  echo [x] Node runtime not found.
  pause
  exit /b 1
)

echo Signaling server only - keep this window open.
echo Other machines connect to: ws://^<this-machine-ip^>:8787/ws
"%NODE%" "%KIT%\tools\lan-info.mjs"
echo.
"%NODE%" "%KIT%\src\remotedesk\server\index.js"
pause
