# RemoteDesk 环境自检（Windows）
# 只做检测，不改任何东西。输出 3 类标记：[OK] 就绪  [!!] 有但有问题  [--] 缺失

$ErrorActionPreference = 'SilentlyContinue'
$kit = Split-Path -Parent $PSScriptRoot

function Show-Item {
    param([string]$Mark, [string]$Name, [string]$Detail)
    $color = 'Gray'
    if ($Mark -eq '[OK]') { $color = 'Green' }
    if ($Mark -eq '[!!]') { $color = 'Yellow' }
    if ($Mark -eq '[--]') { $color = 'Red' }
    Write-Host ("{0} " -f $Mark) -ForegroundColor $color -NoNewline
    Write-Host ("{0,-24}" -f $Name) -NoNewline
    Write-Host $Detail
}

Write-Host ""
Write-Host "================ RemoteDesk 环境自检 ================" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. Node 运行时（网页版必需，已内置） ----------
$node = Join-Path $kit 'node\node.exe'
$nodeCmd = $null
if (Test-Path $node) {
    $ver = (& $node -v) 2>$null
    # node -v already prints the leading "v"; do not add another.
    Show-Item '[OK]' 'node.exe（内置）' ($ver + "  " + $node)
    $nodeCmd = $node
} else {
    $sysNode = Get-Command node -ErrorAction SilentlyContinue
    if ($sysNode) {
        $ver = (& node -v) 2>$null
        Show-Item '[!!]' 'node.exe' ("内置缺失，回退到系统 node " + $ver)
        $nodeCmd = 'node'
    } else {
        Show-Item '[--]' 'node.exe' '缺失 → 网页版跑不起来。重新解压完整压缩包'
    }
}

# ---------- 2. Flutter ----------
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    foreach ($candidate in @("$env:USERPROFILE\flutter\bin\flutter.bat", "C:\src\flutter\bin\flutter.bat", "C:\flutter\bin\flutter.bat")) {
        if (Test-Path $candidate) { $flutter = $candidate; break }
    }
}
if ($flutter) {
    $fpath = $flutter
    if ($flutter -is [System.Management.Automation.CommandInfo]) { $fpath = $flutter.Source }
    $fver = (& $fpath --version) 2>$null | Select-Object -First 1
    Show-Item '[OK]' 'Flutter' ($fver + "  " + $fpath)
    $flutterOk = $true
} else {
    Show-Item '[--]' 'Flutter' '缺失 → 运行 02-install-flutter.cmd（原生桌面版必需）'
    $flutterOk = $false
}

# ---------- 2.5 开发者模式（Flutter 建插件符号链接的前置） ----------
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = $false
try {
    $devValue = (Get-ItemProperty -Path $devKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
    $devMode = ($devValue -eq 1)
} catch {
    $devMode = $false
}
if ($devMode) {
    Show-Item '[OK]' '开发者模式' '已开启'
} elseif (-not $flutterOk) {
    # 没装 Flutter 时这条无意义，不刷红。
    Show-Item '[--]' '开发者模式' '未检查（先装 Flutter）'
} else {
    Show-Item '[--]' '开发者模式' '未开启 → pub get 会报 symlink 错误。设置→隐私和安全性→开发者选项'
}

# ---------- 3. Visual Studio C++ 工具链 ----------
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if ($vsPath) {
    Show-Item '[OK]' 'VS C++ 工具链' $vsPath
    $vsOk = $true
} else {
    Show-Item '[--]' 'VS C++ 工具链' '缺失 → 运行 03-install-vs-buildtools.cmd（原生桌面版必需）'
    $vsOk = $false
}

# ---------- 4. 浏览器（网页版必需） ----------
$browsers = @()
foreach ($b in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")) {
    if (Test-Path $b) { $browsers += $b }
}
if ($browsers.Count -gt 0) {
    Show-Item '[OK]' '浏览器' $browsers[0]
} else {
    Show-Item '[!!]' '浏览器' '未找到 Chrome/Edge → 网页版的屏幕采集需要 Chrome 或 Edge'
}

# ---------- 5. 端口占用 ----------
foreach ($p in @(8080, 8787)) {
    $busy = $false
    try {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop
        if ($conn) { $busy = $true }
    } catch {
        $lines = netstat -ano | Select-String (":" + $p + "\s")
        if ($lines) { $busy = $true }
    }
    if ($busy) {
        Show-Item '[!!]' ("端口 " + $p) '已被占用（可能上次的服务还在跑，先关掉旧窗口）'
    } else {
        Show-Item '[OK]' ("端口 " + $p) '空闲'
    }
}

# ---------- 6. 磁盘 ----------
$drive = Get-PSDrive C
if ($drive) {
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 10) {
        Show-Item '[!!]' 'C: 剩余空间' ($freeGb.ToString() + " GB  —— 装 Flutter/VS 建议留 20 GB 以上")
    } else {
        Show-Item '[OK]' 'C: 剩余空间' ($freeGb.ToString() + " GB")
    }
}

# ---------- 7. 本地代理 ----------
# 本机的全局代理会连 127.0.0.1 一起劫持，导致 flutter test 报
# "Unable to connect to flutter_tester process: Invalid WebSocket upgrade
# request"——看着像 Flutter 坏了，其实是测试控制台的 WebSocket 走了代理。
$proxy = $env:HTTP_PROXY
if (-not $proxy) { $proxy = $env:HTTPS_PROXY }
if ($proxy -and ($proxy -match '127\.0\.0\.1|localhost')) {
    Show-Item '[!!]' '代理' ("$proxy —— 本机回环代理：跑 flutter test 前要清掉 HTTP_PROXY/HTTPS_PROXY")
} elseif ($proxy) {
    Show-Item '[!!]' '代理' $proxy
} else {
    Show-Item '[OK]' '代理' '未设置'
}

# ---------- 结论 ----------
Write-Host ""
Write-Host "---------------- 结论 ----------------" -ForegroundColor Cyan
if ($nodeCmd) {
    Write-Host "路径 A 网页版（零安装，马上能用）：" -NoNewline -ForegroundColor Green
    Write-Host " 双击 00-RUN-WEB-NOW.cmd"
} else {
    Write-Host "路径 A 网页版：不可用（缺 node.exe）" -ForegroundColor Red
}
if ($flutterOk -and $vsOk -and $devMode) {
    Write-Host "路径 B 原生桌面版：" -NoNewline -ForegroundColor Green
    Write-Host " 双击 04-build-windows.cmd 开始编译"
} else {
    $missing = @()
    if (-not $flutterOk) { $missing += '02-install-flutter.cmd' }
    if (-not $vsOk) { $missing += '03-install-vs-buildtools.cmd' }
    if ($flutterOk -and -not $devMode) { $missing += '开启开发者模式' }
    Write-Host "路径 B 原生桌面版：还缺 " -NoNewline -ForegroundColor Yellow
    Write-Host ($missing -join ' + ')
}
Write-Host ""
Write-Host "注意：网页版要在【每台机器自己的 localhost】上打开，" -ForegroundColor Yellow
Write-Host "      不能用对方的 192.168.x.x 打开（Chrome 只允许 localhost 采集屏幕）。" -ForegroundColor Yellow
Write-Host ""
