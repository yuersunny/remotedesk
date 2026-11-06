# 安装 Flutter SDK（Windows）—— 只有编译原生桌面版时才需要
# 网页版（00-RUN-WEB-NOW.cmd）完全不需要这个。

$ErrorActionPreference = 'Stop'
$Version = '3.47.9'
$Target = Join-Path $env:USERPROFILE 'flutter'
$ZipPath = Join-Path $env:TEMP ("flutter_windows_" + $Version + ".zip")

$mirrors = @(
    "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_$Version-stable.zip",
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$Version-stable.zip"
)

Write-Host ""
Write-Host "================ 安装 Flutter $Version ================" -ForegroundColor Cyan
Write-Host ""

if (Test-Path (Join-Path $Target 'bin\flutter.bat')) {
    Write-Host "[i] 已经装过了：$Target" -ForegroundColor Yellow
    & (Join-Path $Target 'bin\flutter.bat') --version
    Write-Host ""
    Write-Host "如需重装，先手动删除该目录再运行本脚本。" -ForegroundColor Yellow
    exit 0
}

# ---------- 下载 ----------
$ok = $false
foreach ($url in $mirrors) {
    Write-Host "[1/3] 下载中（约 1 GB，请耐心等）..."
    Write-Host "      $url" -ForegroundColor DarkGray
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        # Two Windows-specific traps, both hit on the first real run:
        #  1. curl writes its progress meter to stderr, and with
        #     $ErrorActionPreference='Stop' PowerShell raises the first progress
        #     line as a fatal NativeCommandError — the download self-aborts
        #     after one line. Redirect stderr away.
        #  2. Windows' schannel fails certificate revocation checks when the
        #     CRL server is unreachable, so curl refuses to connect at all.
        #     --ssl-no-revoke keeps the TLS validation but skips that lookup.
        & curl.exe -L -f --ssl-no-revoke --retry 3 --retry-delay 3 -o $ZipPath $url 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true }
    } else {
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $ZipPath -UseBasicParsing
            $ok = $true
        } catch {
            $ok = $false
        }
    }
    if ($ok -and (Test-Path $ZipPath)) {
        $sizeMb = [math]::Round((Get-Item $ZipPath).Length / 1MB, 0)
        if ($sizeMb -lt 400) {
            Write-Host "      下载不完整（只有 $sizeMb MB），换下一个源" -ForegroundColor Yellow
            $ok = $false
        } else {
            Write-Host "      完成：$sizeMb MB" -ForegroundColor Green
            break
        }
    } else {
        Write-Host "      这个源失败，换下一个" -ForegroundColor Yellow
    }
}
if (-not $ok) {
    Write-Host ""
    Write-Host "[x] 两个源都下载失败。请检查网络，或手动下载后解压到 $Target" -ForegroundColor Red
    Write-Host "    $($mirrors[0])" -ForegroundColor DarkGray
    exit 1
}

# ---------- 解压 ----------
Write-Host "[2/3] 解压到 $env:USERPROFILE ..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$existing = Join-Path $env:USERPROFILE 'flutter'
if (Test-Path $existing) {
    Write-Host "      已存在 $existing ，先备份为 flutter.bak" -ForegroundColor Yellow
    if (Test-Path "$existing.bak") { Remove-Item "$existing.bak" -Recurse -Force }
    Move-Item $existing "$existing.bak"
}
[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $env:USERPROFILE)
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
Write-Host "      完成：$Target" -ForegroundColor Green

# ---------- 环境变量 ----------
Write-Host "[3/3] 写入用户环境变量（国内镜像 + PATH）..."
[Environment]::SetEnvironmentVariable('PUB_HOSTED_URL', 'https://pub.flutter-io.cn', 'User')
[Environment]::SetEnvironmentVariable('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn', 'User')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$flutterBin = Join-Path $Target 'bin'
if ($userPath -notlike "*$flutterBin*") {
    $newPath = $userPath
    if ($newPath -and -not $newPath.EndsWith(';')) { $newPath += ';' }
    $newPath += $flutterBin
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "      已把 $flutterBin 加入用户 PATH" -ForegroundColor Green
} else {
    Write-Host "      PATH 里已有，跳过" -ForegroundColor DarkGray
}

# 让当前窗口立即生效，并触发首次运行（会下载 Dart SDK 等依赖）
$env:PATH = "$flutterBin;$env:PATH"
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
Write-Host ""
Write-Host "首次运行 flutter --version，需要下载 Dart SDK（几分钟）..." -ForegroundColor Cyan
& (Join-Path $flutterBin 'flutter.bat') --version

Write-Host ""
Write-Host "================ Flutter 装好了 ================" -ForegroundColor Green

# ---------- 开发者模式 ----------
# Flutter 在 Windows 上给插件建符号链接，需要开发者模式；没开的话
# `flutter pub get` 会以 "Building with plugins requires symlink support"
# 结束，看起来像依赖问题，其实是权限问题。
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = $false
try {
    $value = (Get-ItemProperty -Path $devKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
    $devMode = ($value -eq 1)
} catch {
    $devMode = $false
}

if (-not $devMode) {
    Write-Host ""
    Write-Host "[!] 还需要打开「开发者模式」" -ForegroundColor Yellow
    Write-Host "    原因：Flutter 要在 Windows 上给插件建符号链接，没开开发者模式会报" -ForegroundColor Yellow
    Write-Host "          Building with plugins requires symlink support" -ForegroundColor DarkGray
    Write-Host "    开法：设置 → 隐私和安全性 → 开发者选项 → 开发人员模式（打开）" -ForegroundColor Yellow
    Write-Host "    或者直接运行：start ms-settings:developers" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "下一步：运行 03-install-vs-buildtools.cmd（编译原生版还需要 VS C++ 工具链）"
Write-Host "然后：运行 01-check-env.cmd 复核，再 04-build-windows.cmd"
Write-Host ""
Write-Host "提示：新开的命令行窗口才会自动带上 PATH。" -ForegroundColor Yellow
Write-Host ""
