@echo off
setlocal
cd /d "%~dp0"
rem Same two source locations as 05-run-windows-app.cmd
set "SRC=%CD%\src\remotedesk"
if not exist "%SRC%\app\pubspec.yaml" set "SRC=%CD%\..\..\source"
set "EXE=%SRC%\app\build\windows\x64\runner\Release\remotedesk.exe"
if not exist "%EXE%" (
  echo [x] Native Windows build not found:
  echo     "%EXE%"
  echo.
  echo     Run 04-build-windows.cmd first.
  echo     Or use 00-RUN-WEB-NOW.cmd for controller-only mode.
  echo.
  pause
  exit /b 1
)
echo Starting RemoteDesk as ADMINISTRATOR:
echo   "%EXE%"
echo.
echo A UAC prompt will appear. Click Yes to allow it.
echo After it opens, MINIMIZE the RemoteDesk window before connecting.
echo.
set "RD_EXE=%EXE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Start-Process -FilePath $env:RD_EXE -Verb RunAs } catch { Write-Host ('[x] Elevation cancelled or failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 (
  echo.
  echo [x] Could not start as administrator. Nothing was changed.
  echo     If UAC was declined, just run this script again.
  pause
  exit /b 1
)
echo.
echo [ok] Started elevated. Minimize the RemoteDesk window, then connect from the other machine.
echo.
echo Tip - make this permanent without a script:
echo   Right-click remotedesk.exe - Properties - Compatibility -
echo   check "Run this program as an administrator" - OK.
echo.
echo Why: Windows UIPI drops input sent by a normal process to elevated
echo windows such as Task Manager. Running RemoteDesk elevated fixes it.
echo.
pause
