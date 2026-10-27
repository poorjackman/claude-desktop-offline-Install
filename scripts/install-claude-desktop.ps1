#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 完全离线安装（MSIX + Cowork 运行时）。

.DESCRIPTION
    1. 安装 pkg\Claude.msix
    2. 把 pkg\runtime 下的 Claude Code / Cowork VM 运行时预置到数据目录
    3. 首次启动 Cowork 时由 Claude 自己解压 rootfs.vhdx，不再联网下载约 1.5GB

.PARAMETER PackagePath
    MSIX 路径，默认 pkg\Claude.msix。

.PARAMETER DeploymentMode
    Auto / 3p / Standard。Auto 会优先使用 3p 目录（如果存在），否则按标准模式。

.PARAMETER DataRoot
    显式指定数据根目录，优先级最高。用于测试或非默认安装位置。

.PARAMETER SkipRuntime
    只安装 MSIX，不部署离线运行时。

.PARAMETER SkipMsix
    跳过 MSIX 安装，只部署运行时（用于补装/测试，不会卸载现有 Claude）。

.PARAMETER DryRun
    只检查并打印计划，不结束进程、不安装、不复制文件。

.PARAMETER NoPause
    结束后不等待回车（便于自动化）。

.EXAMPLE
    # 正常离线安装
    .\install-claude-desktop.ps1

.EXAMPLE
    # 只补装运行时
    .\install-claude-desktop.ps1 -SkipMsix -DeploymentMode 3p

.EXAMPLE
    # 试运行，不改动系统
    .\install-claude-desktop.ps1 -DryRun -NoPause
#>

[CmdletBinding()]
param(
    [string]$PackagePath = '',

    [ValidateSet('Auto', '3p', 'Standard')]
    [string]$DeploymentMode = 'Auto',

    [string]$DataRoot = '',

    [switch]$SkipRuntime,

    [switch]$SkipMsix,

    [switch]$DryRun,

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ExitCode = 0
$script:LogPath = ''

function Write-Step([string]$Message) {
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "   $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "   $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "   $Message" -ForegroundColor Red
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'ClaudeOffline.Common.ps1')

function Stop-ClaudeInstallBlockers {
    Write-Step '安装前清理（进程 / 残留服务 / 旧版 MSIX）...'

    $names = @('Claude', 'cowork-svc', 'cowork', 'chrome-native-host')
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $n = $_.ProcessName
            ($names -contains $n) -or ($n -like 'Claude*')
        }
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok "已结束 $($procs.Count) 个 Claude 相关进程"
    }
    else {
        Write-Warn '未发现运行中的 Claude 进程'
    }

    $svcName = 'CoworkVMService'
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        try {
            Stop-Service -Name $svcName -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Write-Ok '已停止 CoworkVMService'
        }
        catch {
            Write-Warn "停止 CoworkVMService 失败: $($_.Exception.Message)"
        }
    }

    $null = & sc.exe delete $svcName 2>&1
    Start-Sleep -Seconds 1

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService'
    if (Test-Path -LiteralPath $regPath) {
        try {
            Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction Stop
            Write-Ok '已删除 CoworkVMService 注册表残留'
        }
        catch {
            Write-Warn 'CoworkVMService 注册表仍存在，若安装失败请先运行 卸载Claude桌面版.bat 后重启'
        }
    }

    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Claude*' }
    foreach ($pkg in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop
            Write-Ok "已移除旧版预置包: $($pkg.PackageName)"
        }
        catch {
            Write-Warn "旧版预置包未能移除: $($pkg.PackageName) — $($_.Exception.Message)"
        }
    }
    if (-not $provisioned) {
        Write-Warn '未发现 Claude 预置包'
    }

    $packages = @(
        Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Claude*' }
    ) | Sort-Object PackageFullName -Unique

    foreach ($pkg in $packages) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-Ok "已移除旧版 MSIX: $($pkg.PackageFullName)"
        }
        catch {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Ok "已移除旧版 MSIX（当前用户）: $($pkg.PackageFullName)"
            }
            catch {
                Write-Warn "旧版 MSIX 未能移除: $($pkg.PackageFullName)"
            }
        }
    }

    if (-not $packages) {
        Write-Warn '未发现已安装的 Claude MSIX'
    }
}

function Install-ClaudeRuntime {
    param(
        [string]$PkgDir,
        [string]$TargetDataRoot,
        [ValidateSet('Auto', '3p', 'Standard')]
        [string]$Mode,
        [switch]$DryRun
    )

    Write-Step '部署离线 Cowork 运行时（免下载）'

    $runtimeDir = Join-Path $PkgDir 'runtime'
    $manifestPath = Join-Path $PkgDir 'manifest.json'

    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        Write-Warn "未找到运行时目录：$runtimeDir"
        Write-Warn '本次只安装 MSIX；首次使用 Cowork 时仍会联网下载约 1.5GB。'
        return
    }

    $resolved = Resolve-ClaudeDataRoot -Mode $Mode -ExplicitPath $TargetDataRoot
    $targetRoot = $resolved.Path
    Write-Ok "数据目录：$targetRoot（$($resolved.Mode)：$($resolved.Reason)）"

    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
        catch {
            Write-Warn "manifest.json 解析失败：$($_.Exception.Message)"
        }
    }
    else {
        Write-Warn '未找到 manifest.json，将按目录内容部署，但不做哈希校验。'
    }

    $installed = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($manifest -and $installed -and $manifest.app.version) {
        if ([string]$installed.Version -ne [string]$manifest.app.version) {
            Write-Warn "MSIX 版本 $($installed.Version) 与运行时包版本 $($manifest.app.version) 不一致。"
            Write-Warn '若首次启动 Cowork 仍要下载，请用与 MSIX 同版本的机器重新运行 collect-runtime.ps1。'
        }
    }

    $free = Get-ClaudeFreeSpaceBytes -Path $targetRoot
    if ($null -ne $free) {
        $minimum = [int64]12GB
        if ($free -lt $minimum) {
            Write-Warn "目标盘剩余 $([math]::Round($free / 1GB, 1)) GB，建议至少 12 GB（首次启动要解压约 7.3 GB 的 rootfs）。"
        }
        else {
            Write-Ok "目标盘剩余 $([math]::Round($free / 1GB, 1)) GB"
        }
    }

    $files = @()
    if ($manifest -and $manifest.files) {
        $files = @($manifest.files)
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $runtimeDir -Recurse -File | ForEach-Object {
            [pscustomobject]@{
                path   = $_.FullName.Substring($runtimeDir.Length).TrimStart('\', '/').Replace('\', '/')
                size   = [int64]$_.Length
                sha256 = $null
            }
        })
    }

    if ($files.Count -eq 0) {
        Write-Warn '运行时目录为空，跳过部署。'
        return
    }

    $copied = 0
    $skipped = 0
    $replaced = 0

    foreach ($f in $files) {
        $rel = [string]$f.path
        $source = Join-Path $runtimeDir ($rel -replace '/', '\')
        $dest = Join-Path $targetRoot ($rel -replace '/', '\')

        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warn "包内缺少文件：$rel"
            continue
        }
        $sourceItem = Get-Item -LiteralPath $source
        if ($f.size -and ($sourceItem.Length -ne [int64]$f.size)) {
            Write-Warn "包内文件大小不符：$rel（$($sourceItem.Length) != $($f.size)）"
            continue
        }

        if ($DryRun) {
            Write-Host "   [DRY] $rel（$(Format-ClaudeSize $sourceItem.Length)）" -ForegroundColor DarkGray
            continue
        }

        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -ItemType Directory -Force -Path $destDir
        }

        if (Test-Path -LiteralPath $dest) {
            $valid = $true
            if ($f.sha256) {
                $valid = Test-ClaudeSha256 -Path $dest -Expected ([string]$f.sha256)
            }
            else {
                $valid = ((Get-Item -LiteralPath $dest).Length -eq $sourceItem.Length)
            }
            if ($valid) {
                $skipped++
                continue
            }
            $backup = "$dest.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Move-Item -LiteralPath $dest -Destination $backup -Force
            $replaced++
        }

        Copy-Item -LiteralPath $source -Destination $dest -Force
        $copied++
    }

    if ($DryRun) {
        Write-Ok "试运行：将部署 $($files.Count) 个文件到 $targetRoot（未写入任何文件）"
        return
    }

    Write-Step '校验已部署文件'
    $bad = @()
    foreach ($f in $files) {
        if (-not $f.sha256) { continue }
        $dest = Join-Path $targetRoot ([string]$f.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dest)) {
            $bad += "$($f.path)（缺失）"
            continue
        }
        if (-not (Test-ClaudeSha256 -Path $dest -Expected ([string]$f.sha256))) {
            $bad += "$($f.path)（哈希不符）"
        }
    }
    if ($bad.Count -gt 0) {
        Write-Fail '以下文件校验失败：'
        $bad | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        throw '离线运行时校验失败，请重新运行 collect-runtime.ps1。'
    }
    Write-Ok '全部文件校验通过'

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        & $icacls $targetRoot /grant "$($identity):(OI)(CI)M" /T /Q | Out-Null
        Write-Ok "已授予 $identity 对数据目录的修改权限"
    }
    catch {
        Write-Warn "设置目录权限失败：$($_.Exception.Message)"
    }

    Write-Ok "运行时已就位：新写入 $copied 个，已存在跳过 $skipped 个，替换 $replaced 个"
    Write-Ok '首次启动 Cowork 时会自动解压 rootfs.vhdx（约 7.3GB，通常 16–60 秒），无需联网下载。'
}

function Show-InstallFailureHelp {
    Write-Host ''
    Write-Fail '安装失败。常见原因与处理：'
    Write-Host '   1. CoworkVMService 幽灵服务残留 — 先运行 卸载Claude桌面版.bat，重启后再装' -ForegroundColor Yellow
    Write-Host '   2. MSIX 文件不完整 — 重新下载 Claude.msix（约 280MB）' -ForegroundColor Yellow
    Write-Host '   3. 企业策略限制 — 联系 IT 放行 MSIX 侧载' -ForegroundColor Yellow
    Write-Host '   4. 运行时包不完整 — 重新运行 scripts\collect-runtime.ps1，或检查 pkg\manifest.json' -ForegroundColor Yellow
    Write-Host '   5. 查看完整日志 — 打开 log\install-claude-desktop.log' -ForegroundColor Yellow
    Write-Host ''
}

function Wait-BeforeClose {
    if ($NoPause) { return }
    Write-Host '----------------------------------------' -ForegroundColor DarkGray
    if ($script:LogPath) {
        Write-Host "完整日志: $script:LogPath" -ForegroundColor Cyan
    }
    if ($script:ExitCode -eq 0) {
        Write-Host '安装流程已结束（成功）。' -ForegroundColor Green
    }
    else {
        Write-Host '安装流程已结束（失败）。请查看上方红字或日志文件。' -ForegroundColor Red
    }
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    [void](Read-Host)
}

$pkgDir = Join-Path $rootDir 'pkg'
$logDir = Join-Path $rootDir 'log'
$null = New-Item -ItemType Directory -Force -Path $pkgDir, $logDir
$script:LogPath = Join-Path $logDir 'install-claude-desktop.log'

try {
    Start-Transcript -Path $script:LogPath -Append -Force | Out-Null

    if (-not $PackagePath) {
        $PackagePath = Join-Path $pkgDir 'Claude.msix'
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host '   Claude Desktop 完全离线安装' -ForegroundColor Magenta
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host '   包含：MSIX 本体 + Claude Code + Cowork 运行时' -ForegroundColor DarkGray
    Write-Host '   首次启动 Cowork 不需要再下载 rootfs / claude 二进制' -ForegroundColor DarkGray
    Write-Host "   日志文件: $script:LogPath"
    if ($DryRun) {
        Write-Host '   当前为 -DryRun：只检查，不改动系统。' -ForegroundColor Yellow
    }
    Write-Host ''

    $isAdmin = Test-IsAdmin

    # C 盘空间硬性检查：低于 12GB 直接退出，避免装到一半无法解压 rootfs。
    $cFree = Get-ClaudeFreeSpaceBytes -Path (Join-Path $env:SystemDrive '\')
    $minFreeBytes = [int64]12GB
    if ($null -ne $cFree -and $cFree -lt $minFreeBytes) {
        $freeText = '{0:N1} GB' -f ($cFree / 1GB)
        if ($DryRun) {
            Write-Warn "C 盘剩余 $freeText，低于建议的 12 GB；实际安装时会退出。"
        }
        else {
            Write-Fail "C 盘剩余空间不足：$freeText（要求至少 12 GB）。"
            Write-Host '首次启动 Cowork 需要解压约 7.3GB 的 rootfs.vhdx，空间不足会导致工作区启动失败。' -ForegroundColor Yellow
            Write-Host '请清理 C 盘后重试。' -ForegroundColor Yellow
            $script:ExitCode = 1
        }
    }
    elseif ($null -ne $cFree) {
        Write-Ok ("C 盘剩余空间：{0:N1} GB" -f ($cFree / 1GB))
    }

    if ($script:ExitCode -eq 0 -and -not $SkipMsix) {
        if (-not (Test-Path -LiteralPath $PackagePath)) {
            Write-Fail "未找到 MSIX 安装包：$PackagePath"
            Write-Host '请把 Claude.msix 放进 pkg 目录，或使用 -SkipMsix 只部署运行时。' -ForegroundColor Yellow
            $script:ExitCode = 1
        }
        elseif (-not $isAdmin -and -not $DryRun) {
            Write-Fail '需要管理员权限。'
            Write-Host '请双击根目录的 离线安装Claude完整桌面版.bat，脚本会自动请求管理员权限。' -ForegroundColor Yellow
            $script:ExitCode = 1
        }
    }
    elseif ($script:ExitCode -eq 0 -and $SkipMsix) {
        Write-Warn '已指定 -SkipMsix：跳过 MSIX 安装，只部署离线运行时。'
        if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) {
            if (-not $DryRun) {
                Write-Warn '检测到 Claude 正在运行；建议先从托盘完全退出，避免文件被占用。'
            }
        }
    }

    if ($script:ExitCode -eq 0) {
        if (-not $SkipMsix) {
            $PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
            $msixSizeMb = [math]::Round((Get-Item -LiteralPath $PackagePath).Length / 1MB, 1)

            Write-Step "安装包：$PackagePath ($msixSizeMb MB)"
            if ($msixSizeMb -lt 150) {
                Write-Warn '安装包偏小，可能不是完整 MSIX，建议重新下载（通常约 280MB）'
            }

            if ($DryRun) {
                Write-Ok '试运行：将执行 结束进程 / 清理旧包 / 全用户预置安装 MSIX'
            }
            else {
                Stop-ClaudeInstallBlockers

                try {
                    Write-Step '正在全用户预置安装...'
                    Add-AppxProvisionedPackage -Online -PackagePath $PackagePath -SkipLicense -Regions 'all' | Out-Null
                    Write-Ok '全用户预置安装完成。'

                    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like '*Claude*' }
                    $installed = Get-AppxPackage -Name '*Claude*' -AllUsers -ErrorAction SilentlyContinue

                    if ($provisioned) {
                        Write-Ok "已预置包：$($provisioned.PackageName)"
                    }
                    if ($installed) {
                        Write-Ok "已注册用户包：$($installed.PackageFullName)"
                    }
                    if (-not $provisioned -and -not $installed) {
                        Write-Warn '命令执行完成，但未检测到 Claude 包。'
                        $script:ExitCode = 1
                    }
                    else {
                        $userPkgDir = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc'
                        $needsReboot = $false

                        if ($installed -and $installed.Status -ne 'Ok') {
                            $needsReboot = $true
                            Write-Warn "当前包状态：$($installed.Status)（未完成，此时打不开 Claude）"
                        }
                        if (-not (Test-Path -LiteralPath $userPkgDir)) {
                            $needsReboot = $true
                            Write-Warn '当前用户尚未完成注册（Packages 目录未生成）'
                        }

                        Write-Host ''
                        if ($needsReboot) {
                            Write-Host '========================================' -ForegroundColor Red
                            Write-Host '  重要：必须先重启电脑，才能打开 Claude！' -ForegroundColor Red
                            Write-Host '  安装成功 ≠ 可立即使用，Servicing 状态需重启完成注册' -ForegroundColor Red
                            Write-Host '========================================' -ForegroundColor Red
                        }
                        else {
                            Write-Ok 'MSIX 安装已完成。'
                        }
                    }
                }
                catch {
                    Write-Fail $_.Exception.Message
                    if ($_.Exception.Message -match '0x80073CF6|windows\.service|0x80070002') {
                        Write-Warn '常见原因：CoworkVMService 幽灵服务残留，请先卸载并重启。'
                    }
                    Show-InstallFailureHelp
                    $script:ExitCode = 1
                }
            }
        }

        if ($script:ExitCode -eq 0 -and -not $SkipRuntime) {
            Install-ClaudeRuntime -PkgDir $pkgDir -TargetDataRoot $DataRoot -Mode $DeploymentMode -DryRun:$DryRun
        }
        elseif ($SkipRuntime) {
            Write-Warn '已指定 -SkipRuntime：不部署离线运行时。'
        }

        if ($script:ExitCode -eq 0 -and -not $DryRun) {
            Write-Host ''
            Write-Host '========================================' -ForegroundColor DarkGray
            Write-Ok '离线安装完成。'
            Write-Host '   首次打开 Cowork 时会自动解压 rootfs.vhdx，期间请勿关闭 Claude。' -ForegroundColor DarkGray
            Write-Host '   若刚安装完 MSIX，请先重启电脑再打开 Claude。' -ForegroundColor DarkGray
            Write-Host '========================================' -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Fail "脚本异常: $($_.Exception.Message)"
    $script:ExitCode = 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    Wait-BeforeClose
    exit $script:ExitCode
}
