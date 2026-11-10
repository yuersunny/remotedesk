# 编译原生 Windows 桌面版（Flutter Windows）
# 前置：Flutter SDK + VS 2022 C++ 工具链（用 02 / 03 脚本装）

$ErrorActionPreference = 'Continue'
$kit = Split-Path -Parent $PSScriptRoot
# 源码可能在两处：套件自带的快照（src\remotedesk），或发行包里并列的 source\
$appDir = $null
foreach ($candidate in @(
    (Join-Path $kit 'src\remotedesk\app'),
    (Join-Path $kit '..\..\source\app'),
    (Join-Path $kit '..\source\app'))) {
    if (Test-Path (Join-Path $candidate 'pubspec.yaml')) { $appDir = $candidate; break }
}
if (-not $appDir) { $appDir = Join-Path $kit 'src\remotedesk\app' }

Write-Host ""
Write-Host "================ 编译 Windows 原生版 ================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path (Join-Path $appDir 'pubspec.yaml'))) {
    Write-Host "[x] 找不到工程：$appDir" -ForegroundColor Red
    Write-Host "    压缩包可能没解压完整。" -ForegroundColor Red
    exit 1
}

# ---------- 找 flutter ----------
$flutter = $null
$cmd = Get-Command flutter -ErrorAction SilentlyContinue
if ($cmd) {
    $flutter = $cmd.Source
} else {
    foreach ($candidate in @("$env:USERPROFILE\flutter\bin\flutter.bat", "C:\src\flutter\bin\flutter.bat", "C:\flutter\bin\flutter.bat")) {
        if (Test-Path $candidate) { $flutter = $candidate; break }
    }
}
if (-not $flutter) {
    Write-Host "[x] 没找到 Flutter。" -ForegroundColor Red
    Write-Host "    先运行 02-install-flutter.cmd（装完要开新窗口才认 PATH）。" -ForegroundColor Yellow
    exit 1
}
Write-Host "Flutter: $flutter" -ForegroundColor DarkGray

# ---------- 找 VS ----------
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsPath) {
    Write-Host "[x] 没检测到 VS C++ 工具链。" -ForegroundColor Red
    Write-Host "    先运行 03-install-vs-buildtools.cmd。" -ForegroundColor Yellow
    Write-Host "    （只想看画面的话，网页版 00-RUN-WEB-NOW.cmd 不用编译。）" -ForegroundColor Yellow
    exit 1
}
Write-Host "VS C++ : $vsPath" -ForegroundColor DarkGray

# ---------- 开发者模式（pub get 的隐藏前置） ----------
# Flutter 在 Windows 上为插件建符号链接。没开开发者模式时，pub get 会以
# "Building with plugins requires symlink support" 结束 —— 看起来像依赖
# 或网络问题，实际是系统权限。提前挡掉，比让用户对着那句报错猜要好。
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = $false
try {
    $devValue = (Get-ItemProperty -Path $devKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
    $devMode = ($devValue -eq 1)
} catch {
    $devMode = $false
}
if (-not $devMode) {
    Write-Host ""
    Write-Host "[x] 没开「开发者模式」，pub get 一定失败。" -ForegroundColor Red
    Write-Host "    Flutter 要给 Windows 插件建符号链接，没这个权限会报：" -ForegroundColor Yellow
    Write-Host "      Building with plugins requires symlink support" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    开法：设置 → 隐私和安全性 → 开发者选项 → 开发人员模式（打开）" -ForegroundColor Yellow
    Write-Host "    或运行：start ms-settings:developers" -ForegroundColor DarkGray
    Write-Host "    开完回来重跑本脚本（不用重启）。" -ForegroundColor Yellow
    exit 1
}
Write-Host "开发者模式: 已开启" -ForegroundColor DarkGray

if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn' }
if (-not $env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }

Write-Host ""
Write-Host "[1/3] flutter config --enable-windows-desktop"
& $flutter config --enable-windows-desktop

Write-Host ""
Write-Host "[2/3] flutter pub get"
Push-Location $appDir
& $flutter pub get
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Write-Host "[x] pub get 失败，先解决上面的报错。" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[3/3] flutter build windows --release（首次编译约 3~8 分钟）"
& $flutter build windows --release
$code = $LASTEXITCODE
Pop-Location

Write-Host ""
$exe = Join-Path $appDir 'build\windows\x64\runner\Release\remotedesk.exe'
if ($code -eq 0 -and (Test-Path $exe)) {
    Write-Host "================ 编译成功 ================" -ForegroundColor Green
    Write-Host "可执行文件：$exe"
    Write-Host ""
    Write-Host "双击 05-run-windows-app.cmd 启动，或直接跑上面这个 exe。" -ForegroundColor Cyan
    Write-Host "注意：首次启动 Windows 防火墙会询问，选【允许访问】。" -ForegroundColor Yellow
} else {
    Write-Host "[x] 编译失败（退出码 ${code}）。" -ForegroundColor Red
    Write-Host "常见原因：" -ForegroundColor Yellow
    Write-Host "  - VS 缺 '使用 C++ 的桌面开发' 工作负载 → 重跑 03-install-vs-buildtools.cmd"
    Write-Host "  - 首次 pub get 被网络拦住 → 确认 PUB_HOSTED_URL 是 https://pub.flutter-io.cn"
    Write-Host "  - 路径里有中文或空格 → 把整个包挪到 C:\remotedesk 再试"
}
Write-Host ""
