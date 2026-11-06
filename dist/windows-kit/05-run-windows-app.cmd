@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
set "EXE=%CD%\src\remotedesk\app\build\windows\x64\runner\Release\remotedesk.exe"
if not exist "%EXE%" (
  echo [x] Native Windows build not found:
  echo     %EXE%
  echo.
  echo     Run 04-build-windows.cmd first ^(needs Flutter + Visual Studio C++^).
  echo     Or just use 00-RUN-WEB-NOW.cmd - no build required.
  echo.
  pause
  exit /b 1
)
echo Starting %EXE%
start "" "%EXE%"
