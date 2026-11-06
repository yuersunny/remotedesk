# 开启 Windows「开发者模式」（Flutter 建插件符号链接的前置）
#
# 为什么必须开：Flutter 在 Windows 上给插件包建的是符号链接。没开这个开关时，
# `flutter pub get` 会以
#     Building with plugins requires symlink support.
# 结束 —— 看起来像网络或依赖问题，其实是系统权限，折腾 pub 镜像不会好。
#
# 本脚本写一个注册表值（需要管理员），会弹一次 UAC。不重启即可生效。

$ErrorActionPreference = 'Stop'

$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$name = 'AllowDevelopmentWithoutDevLicense'

function Test-DevMode {
    try {
        $value = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name
        return ($value -eq 1)
    } catch {
        return $false
    }
}

Write-Host ''
Write-Host '== 开发者模式检查 ==' -ForegroundColor Cyan

if (Test-DevMode) {
    Write-Host '[OK] 已经是开启状态，不需要改动。' -ForegroundColor Green
    Write-Host '     直接跑 04-install-vs-buildtools.cmd 装 C++ 工具链即可。' -ForegroundColor DarkGray
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '[..] 需要管理员权限写注册表，正在弹出 UAC 确认框…' -ForegroundColor Yellow
    Write-Host '     请在弹窗里点「是」。' -ForegroundColor Yellow
    Write-Host ''
    try {
        $self = $MyInvocation.MyCommand.Path
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"" `
            -Verb RunAs -Wait -PassThru
        $code = $proc.ExitCode
    } catch {
        # UAC 被拒，或提权进程的退出码读不到。先看结果再下结论：
        # 读不到退出码不代表失败，注册表可能已经写好了。
        if (Test-DevMode) {
            Write-Host '[OK] 开发者模式已开启（无需重启）。' -ForegroundColor Green
            Write-Host '     下一步：03-install-vs-buildtools.cmd 装 VS C++ 工具链。' -ForegroundColor DarkGray
            exit 0
        }
        Write-Host '[x] 未能提权（UAC 被拒绝）。' -ForegroundColor Red
        Write-Host '    手改路径：设置 → 隐私和安全性 → 开发者选项 → 打开「开发人员模式」' -ForegroundColor Yellow
        Write-Host '    或运行：start ms-settings:developers' -ForegroundColor DarkGray
        exit 1
    }
    exit $code
}

try {
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    New-ItemProperty -Path $key -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
} catch {
    Write-Host "[x] 写注册表失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '    手改路径：设置 → 隐私和安全性 → 开发者选项 → 打开「开发人员模式」' -ForegroundColor Yellow
    exit 1
}

if (Test-DevMode) {
    Write-Host '[OK] 开发者模式已开启（无需重启）。' -ForegroundColor Green
    Write-Host '     下一步：04-install-vs-buildtools.cmd 装 VS C++ 工具链。' -ForegroundColor DarkGray
    exit 0
}

Write-Host '[!] 注册表写了，但读回来仍不是 1 —— 可能是组策略接管了这项设置。' -ForegroundColor Yellow
Write-Host '    手动开：start ms-settings:developers' -ForegroundColor Yellow
exit 1
