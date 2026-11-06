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
  echo     Expected bundled: %KIT%\node\node.exe
  echo     Or install Node.js LTS:  winget install OpenJS.NodeJS.LTS
  echo.
  pause
  exit /b 1
)

echo ==========================================================
echo   RemoteDesk M1 - web preview  (nothing to install)
echo ==========================================================
echo.
echo   Uses the bundled node.exe. No Node, no Flutter needed.
echo.

echo [1/3] starting signaling server on port 8787 ...
start "RemoteDesk signaling 8787" "%NODE%" "%KIT%\src\remotedesk\server\index.js"
timeout /t 2 /nobreak >nul

echo [2/3] starting web server on port 8080 ...
start "RemoteDesk web 8080" "%NODE%" "%KIT%\tools\serve.mjs" "%KIT%\web-preview" 8080
timeout /t 2 /nobreak >nul

echo [3/3] opening browser ...
"%NODE%" "%KIT%\tools\lan-info.mjs"
start "" "http://localhost:8080/?id=win-pc"

echo.
echo ----------------------------------------------------------
echo  Two console windows were opened - they ARE the servers.
echo  Close them to stop. Or press Ctrl+C in each.
echo.
echo  If Windows Firewall asks, click "Allow access"
echo  (private networks) so the other machine can reach 8787.
echo ----------------------------------------------------------
echo.
pause
