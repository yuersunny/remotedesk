# 安装 Visual Studio 2022 Build Tools + "使用 C++ 的桌面开发" 工作负载
# 这是 flutter build windows 的硬性依赖。装完约 4~7 GB。

$ErrorActionPreference = 'Continue'

Write-Host ""
Write-Host "==== 安装 VS 2022 Build Tools（C++ 桌面开发）====" -ForegroundColor Cyan
Write-Host ""
Write-Host "说明：这是编译原生 Windows 版必须的。"
Write-Host "      只跑网页版（00-RUN-WEB-NOW.cmd）不需要装。"
Write-Host "      安装过程会弹 UAC 和安装器窗口，需要你点确认，约 10~20 分钟。"
Write-Host ""

# 已经装过就跳过
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere) {
    $installed = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($installed) {
        Write-Host "[i] 已经装了 C++ 工具链：$installed" -ForegroundColor Green
        Write-Host "    无需重复安装。" -ForegroundColor Green
        exit 0
    }
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Host "[x] 没找到 winget（应用安装程序）。" -ForegroundColor Red
    Write-Host ""
    Write-Host "手动装法（两条命令，在【管理员】PowerShell 里跑）：" -ForegroundColor Yellow
    Write-Host '  curl.exe -L -o "$env:TEMP\vs_buildtools.exe" https://aka.ms/vs/17/release/vs_buildtools.exe'
    Write-Host '  & "$env:TEMP\vs_buildtools.exe" --wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    Write-Host ""
    Write-Host "装完回来跑 01-check-env.cmd 复核。"
    exit 1
}

$vsArgs = '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
Write-Host "调用 winget 安装（保持这个窗口别关）..." -ForegroundColor Cyan
Write-Host ""

& winget install --id Microsoft.VisualStudio.2022.BuildTools -e `
    --accept-package-agreements --accept-source-agreements `
    --override $vsArgs

$code = $LASTEXITCODE
Write-Host ""
if ($code -eq 0) {
    Write-Host "================ 安装命令已返回成功 ================" -ForegroundColor Green
} else {
    Write-Host "winget 退出码 $code —— 可能是你取消了 UAC，或需要以管理员身份运行。" -ForegroundColor Yellow
    Write-Host "可以重跑本脚本，或手动执行上面的两条命令。" -ForegroundColor Yellow
}

# 复核
if (Test-Path $vsWhere) {
    $vc = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vc) {
        Write-Host "复核通过：$vc" -ForegroundColor Green
        Write-Host "下一步：运行 04-build-windows.cmd" -ForegroundColor Cyan
    } else {
        Write-Host "复核：仍未检测到 C++ 工具链。安装器可能还在后台跑，等它完成后再跑 01-check-env.cmd。" -ForegroundColor Yellow
    }
}
Write-Host ""
