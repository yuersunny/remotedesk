@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "KIT=%CD%"

set "NODE="
if exist "%KIT%\node\node.exe" set "NODE=%KIT%\node\node.exe"
if not defined NODE (
  where node >nul 2>nul
  if not errorlevel 1 set "NODE=node"
)
if not defined NODE (
  echo [x] Node runtime not found.
  echo     Expected bundled: %KIT%\node\node.exe
  echo     Or install Node.js LTS:  winget install OpenJS.NodeJS.LTS
  echo.
  pause
  exit /b 1
)

echo ==========================================================
echo   RemoteDesk - browser edition  (nothing to install)
echo ==========================================================
echo.
echo   Runs off the bundled node.exe. No Node, no Flutter.
echo.
echo   IMPORTANT: this build is CONTROLLER ONLY.
echo   It can drive another machine, but nothing can drive it.
echo   To be controlled, build the native exe (04-build-windows.cmd).
echo.

echo [1/2] serving the app on http://localhost:8080 ...
start "RemoteDesk web 8080" "%NODE%" "%KIT%\tools\serve.mjs" "%KIT%\web-preview" 8080
timeout /t 2 /nobreak >nul

echo [2/2] opening browser ...
start "" "http://localhost:8080/"

echo.
echo ----------------------------------------------------------
echo  A console window opened - it IS the web server.
echo  Close it (or Ctrl+C) to stop.
echo.
echo  In the page, click "manual address" and type the OTHER
echo  machine's IP, e.g.  192.168.1.20   or   192.168.1.20:8787
echo  (or paste the pairing code it shows).
echo.
echo  Keep this page on localhost. Chrome only allows screen
echo  capture from localhost or https, never from a LAN IP.
echo ----------------------------------------------------------
echo.
pause
