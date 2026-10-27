#Requires -Version 5.1
<#
.SYNOPSIS
    彻底卸载 Claude Code 桌面端（Claude Desktop）及 Cowork 残留数据。

.DESCRIPTION
    官方卸载器常会遗留：
      - Cowork VM 虚拟机包（可达 ~10GB）
      - CoworkVMService Windows 服务
      - MSIX 沙盒数据 (%LOCALAPPDATA%\Packages\Claude_*)
      - WindowsApps 中的 claude 命令别名（会抢占终端里的 claude 命令）

    本脚本会：结束相关进程 → 卸载 MSIX 包 → 移除 VM 服务 → 清理所有已知残留。
    正常卸载无需重启；仅当 MSIX 卸不掉或重装报错时，才建议重启。

    默认保留 ~/.claude（Claude Code CLI 配置）。仅卸载桌面端请加 -KeepCliConfig（默认即保留）；
    若也要删除 CLI 配置，请加 -RemoveCliConfig。

.PARAMETER Force
    跳过确认提示，直接执行。

.PARAMETER KeepCliConfig
    保留 %USERPROFILE%\.claude（默认行为，可省略）。

.PARAMETER RemoveCliConfig
    同时删除 %USERPROFILE%\.claude 目录。

.PARAMETER CleanEnvVars
    从用户环境变量中移除 ANTHROPIC_*（Helper 或桌面端可能写入的项）。

.PARAMETER RemoveAppData
    同时删除 %LOCALAPPDATA%\Claude-3p 与 Claude-Data（应用设置、会话和离线运行时，可达 10GB）。
    默认保留这两个目录，避免误删用户数据。

.PARAMETER DryRun
    只扫描并显示将删除/保留的内容，不执行卸载。

.EXAMPLE
    # 以管理员身份运行 PowerShell：
    .\uninstall-claude-desktop.ps1

.EXAMPLE
    .\uninstall-claude-desktop.ps1 -Force -RemoveCliConfig -CleanEnvVars
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepCliConfig,
    [switch]$RemoveCliConfig,
    [switch]$CleanEnvVars,
    [switch]$RemoveAppData,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Message) Write-Host "   [OK]   $Message" -ForegroundColor Green }
function Write-Skip  { param([string]$Message) Write-Host "   [SKIP] $Message" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$Message) Write-Host "   [WARN] $Message" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PathSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64]$sum
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Expand-PathPatterns {
    param([string[]]$Patterns)
    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $Patterns) {
        if ($pattern -match '[\*\?]') {
            $parent = Split-Path $pattern -Parent
            $leaf = Split-Path $pattern -Leaf
            if ([string]::IsNullOrWhiteSpace($parent)) { $parent = '.' }
            if (Test-Path -LiteralPath $parent) {
                Get-ChildItem -Path $parent -Filter $leaf -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $resolved.Add($_.FullName) }
            }
        }
        elseif (Test-Path -LiteralPath $pattern) {
            $resolved.Add((Resolve-Path -LiteralPath $pattern).Path)
        }
    }
    return $resolved | Select-Object -Unique
}

function Remove-Target {
    param(
        [string]$Path,
        [string]$Label = $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Skip "不存在: $Label"
        return $true
    }
    $size = Get-PathSizeBytes -Path $Path
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Ok "已删除 ($((Format-Size $size))): $Label"
        return $true
    }
    catch {
        Write-Fail "无法删除 $Label — $($_.Exception.Message)"
        return $false
    }
}

function Remove-RegistryKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Skip "注册表不存在: $Path"
        return $true
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Ok "已删除注册表: $Path"
        return $true
    }
    catch {
        Write-Fail "无法删除注册表 $Path — $($_.Exception.Message)"
        return $false
    }
}

function Stop-ClaudeProcesses {
    $names = @('Claude', 'cowork-svc', 'cowork')
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $n = $_.ProcessName
            ($names -contains $n) -or
            ($n -like 'Claude*' -and $n -notlike '*claude-code-helper*' -and $n -ne 'claude-code-helper')
        }
    if (-not $procs) {
        Write-Skip '未发现 Claude 桌面端相关进程'
        return
    }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Ok "已结束 $($procs.Count) 个进程"
}

function Get-CoworkVmServiceState {
    $svcName = 'CoworkVMService'
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { return 'Absent' }

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService'
    $regExists = Test-Path -LiteralPath $regPath
    $cim = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
    $pathEmpty = -not $cim -or [string]::IsNullOrWhiteSpace($cim.PathName)

    if (-not $regExists -and $pathEmpty) { return 'Ghost' }
    return 'Present'
}

function Remove-CoworkVmService {
    $svcName = 'CoworkVMService'
    $state = Get-CoworkVmServiceState
    if ($state -eq 'Absent') {
        Write-Skip 'CoworkVMService 不存在'
        return 'Absent'
    }

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
    $state = Get-CoworkVmServiceState
    if ($state -eq 'Absent') {
        Write-Ok '已删除 CoworkVMService'
        return 'Absent'
    }

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService'
    if (Test-Path -LiteralPath $regPath) {
        Write-Warn 'sc.exe delete 未成功，尝试删除注册表项...'
        Remove-RegistryKey -Path $regPath | Out-Null
        Start-Sleep -Seconds 1
        $state = Get-CoworkVmServiceState
        if ($state -eq 'Absent') {
            Write-Ok '已通过注册表移除 CoworkVMService'
            return 'Absent'
        }
    }

    $state = Get-CoworkVmServiceState
    if ($state -eq 'Ghost') {
        Write-Warn 'CoworkVMService 为幽灵登记（无注册表、无程序路径），可忽略'
        Write-Host '         MSIX 已卸时通常不影响重装，无需重启。' -ForegroundColor DarkGray
        return 'Ghost'
    }

    Write-Warn 'CoworkVMService 仍存在（sc delete 常被 DACL 拦截，属已知问题）'
    return 'Present'
}

function Invoke-OfficialUninstall {
    Write-Step '调用官方卸载器（MSIX / Squirrel）'

    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Claude*' }
    foreach ($pkg in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop
            Write-Ok "已移除预置包: $($pkg.PackageName)"
        }
        catch {
            Write-Warn "预置包移除失败 ($($pkg.PackageName)): $($_.Exception.Message)"
        }
    }
    if (-not $provisioned) {
        Write-Skip '未发现 Claude 预置包'
    }

    $msixPackages = @(
        Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Claude*' }
    ) | Sort-Object PackageFullName -Unique

    if ($msixPackages) {
        foreach ($pkg in $msixPackages) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Ok "已卸载 MSIX: $($pkg.PackageFullName)"
            }
            catch {
                Write-Warn "MSIX 卸载失败 ($($pkg.PackageFullName)): $($_.Exception.Message)"
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    Write-Ok "已卸载 MSIX（当前用户）: $($pkg.PackageFullName)"
                }
                catch {
                    Write-Fail "MSIX 仍无法卸载: $($_.Exception.Message)"
                }
            }
        }
    }
    else {
        Write-Skip '未发现 MSIX 包'
    }

    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Update.exe'
    if (Test-Path -LiteralPath $squirrel) {
        try {
            Start-Process -FilePath $squirrel -ArgumentList '--uninstall' -Wait -NoNewWindow
            Start-Sleep -Seconds 3
            Write-Ok '已运行 Squirrel 卸载器'
        }
        catch {
            Write-Warn "Squirrel 卸载失败: $($_.Exception.Message)"
        }
    }
    else {
        Write-Skip '未发现 Squirrel 卸载器'
    }
}

function Get-ResidualPathPatterns {
    $patterns = @(
        "$env:APPDATA\Claude",
        "$env:LOCALAPPDATA\AnthropicClaude",
        "$env:LOCALAPPDATA\Claude",
        "$env:LOCALAPPDATA\Programs\Claude",
        "$env:ProgramData\Claude",
        "$env:LOCALAPPDATA\Packages\Claude_*",
        "$env:LOCALAPPDATA\Packages\AnthropicPBC.Claude_*",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\Claude.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\claude.exe"
    )

    # MSIX 数据可能被重定向到非 C 盘（EXDEV / 应用存储迁移）
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[A-Z]$' }
    foreach ($drive in $drives) {
        $patterns += "$($drive.Name):\WpSystem\*\AppData\Local\Packages\Claude_*"
    }

    return $patterns
}

function Get-AppDataPathPatterns {
    # 3p / Claude-Data 里装着应用设置、会话和离线运行时，默认保留。
    return @(
        (Join-Path $env:LOCALAPPDATA 'Claude-3p'),
        (Join-Path $env:LOCALAPPDATA 'Claude-Data')
    )
}

function Remove-Shortcuts {
    Write-Step '删除快捷方式'

    $shortcutRoots = @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    )

    foreach ($root in $shortcutRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -Path $root -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Claude' -and $_.Extension -in '.lnk', '.url' } |
            ForEach-Object { Remove-Target -Path $_.FullName -Label $_.FullName | Out-Null }
    }
}

function Remove-RegistryResiduals {
    Write-Step '清理注册表残留'

    $fixedKeys = @(
        'HKCU:\Software\Anthropic',
        'HKCU:\Software\Classes\claude',
        'HKLM:\Software\Anthropic'
    )
    foreach ($key in $fixedKeys) {
        Remove-RegistryKey -Path $key | Out-Null
    }

    $uninstallHives = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($hive in $uninstallHives) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
            Where-Object {
                $display = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName
                $display -match 'Claude'
            } |
            ForEach-Object { Remove-RegistryKey -Path $_.PSPath | Out-Null }
    }
}

function Remove-ScheduledTasks {
    Write-Step '删除计划任务'
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'Claude|Cowork' -or $_.TaskPath -match 'Claude|Cowork' } |
        ForEach-Object {
            try {
                Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
                Write-Ok "已删除计划任务: $($_.TaskPath)$($_.TaskName)"
            }
            catch {
                Write-Warn "计划任务删除失败 ($($_.TaskName)): $($_.Exception.Message)"
            }
        }
}

function Remove-AnthropicUserEnvVars {
    if (-not $CleanEnvVars) { return }

    Write-Step '清理用户环境变量 ANTHROPIC_*'
    $keys = @(
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'ANTHROPIC_BASE_URL',
        'ANTHROPIC_MODEL',
        'ANTHROPIC_DEFAULT_HAIKU_MODEL',
        'ANTHROPIC_DEFAULT_SONNET_MODEL',
        'ANTHROPIC_DEFAULT_OPUS_MODEL'
    )
    foreach ($key in $keys) {
        $current = [Environment]::GetEnvironmentVariable($key, 'User')
        if ([string]::IsNullOrWhiteSpace($current)) {
            Write-Skip "未设置: $key"
            continue
        }
        try {
            [Environment]::SetEnvironmentVariable($key, $null, 'User')
            Write-Ok "已移除: $key"
        }
        catch {
            Write-Warn "无法移除 ${key}: $($_.Exception.Message)"
        }
    }
}

function Show-PreScan {
    Write-Step '扫描待清理项'
    $patterns = Get-ResidualPathPatterns
    $appDataPatterns = Get-AppDataPathPatterns

    if ($RemoveAppData) {
        $patterns += $appDataPatterns
    }
    else {
        $preserved = Expand-PathPatterns -Patterns $appDataPatterns
        if ($preserved) {
            $preservedTotal = [int64]0
            foreach ($p in $preserved) { $preservedTotal += Get-PathSizeBytes -Path $p }
            Write-Skip ("将保留应用数据（{0}）：{1}" -f (Format-Size $preservedTotal), ($preserved -join '; '))
        }
    }

    $paths = Expand-PathPatterns -Patterns $patterns
    $total = [int64]0
    foreach ($p in $paths) {
        $size = Get-PathSizeBytes -Path $p
        $total += $size
        Write-Host ('   {0,-12} {1}' -f (Format-Size $size), $p) -ForegroundColor DarkYellow
    }
    if ($paths.Count -eq 0) {
        Write-Skip '未发现已知数据目录（可能已卸载或路径不同）'
    }
    else {
        Write-Host "`n   预计可释放约 $(Format-Size $total)" -ForegroundColor Yellow
    }
    return $paths
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host '   Claude Code 桌面端 — 彻底卸载脚本' -ForegroundColor Magenta
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host '   不会卸载 claude-code-helper 托盘工具。' -ForegroundColor DarkGray
Write-Host '   需要管理员权限（移除服务 / MSIX / 系统目录）。' -ForegroundColor DarkGray

if (-not (Test-IsAdmin) -and -not $DryRun) {
    Write-Fail '需要管理员权限。'
    Write-Host '请双击上级目录的 卸载Claude桌面版.bat，脚本会自动请求管理员权限。' -ForegroundColor Yellow
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    [void](Read-Host)
    exit 1
}

if ($RemoveCliConfig -and $KeepCliConfig) {
    Write-Fail '-RemoveCliConfig 与 -KeepCliConfig 不能同时使用。'
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    [void](Read-Host)
    exit 1
}

$keepCli = -not $RemoveCliConfig

$null = Show-PreScan

if ($DryRun) {
    Write-Host ''
    Write-Host '当前为 -DryRun：只扫描，不执行卸载。' -ForegroundColor Yellow
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    [void](Read-Host)
    exit 0
}

if (-not $Force) {
    Write-Host ''
    Write-Host '即将卸载 Claude 桌面端及 Cowork 相关数据。' -ForegroundColor Yellow
    if ($keepCli) {
        Write-Host '将保留 %USERPROFILE%\.claude（CLI 配置）。' -ForegroundColor DarkGray
    }
    else {
        Write-Host '将同时删除 %USERPROFILE%\.claude 。' -ForegroundColor Red
    }
    if ($CleanEnvVars) {
        Write-Host '将清理用户环境变量中的 ANTHROPIC_* 。' -ForegroundColor DarkGray
    }
    if ($RemoveAppData) {
        Write-Host '将删除 %LOCALAPPDATA%\Claude-3p / Claude-Data（应用数据、会话与离线运行时）。' -ForegroundColor Red
    }
    else {
        Write-Host '将保留 %LOCALAPPDATA%\Claude-3p / Claude-Data（应用数据与离线运行时）。' -ForegroundColor DarkGray
    }
    $answer = Read-Host '确认继续？输入 yes 后回车'
    if ($answer -notmatch '^(?i)yes$') {
        Write-Warn '已取消。'
        Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
        [void](Read-Host)
        exit 0
    }
}

$failures = [System.Collections.Generic.List[string]]::new()
$svcState = 'Absent'

Write-Step '结束 Claude 桌面端进程'
Stop-ClaudeProcesses

# 先卸 MSIX，再删服务——比直接 sc delete 更有效，且多数情况无需重启
Invoke-OfficialUninstall

Write-Step '移除 Cowork VM 服务'
$svcState = Remove-CoworkVmService

Write-Step '删除应用数据与残留目录'
$patterns = Get-ResidualPathPatterns
if ($RemoveAppData) {
    $patterns += Get-AppDataPathPatterns
}
$paths = Expand-PathPatterns -Patterns $patterns
foreach ($p in $paths) {
    if (-not (Remove-Target -Path $p)) {
        $failures.Add($p)
    }
}

if (-not $RemoveAppData) {
    $preserved = Expand-PathPatterns -Patterns (Get-AppDataPathPatterns)
    foreach ($p in $preserved) {
        $size = Get-PathSizeBytes -Path $p
        Write-Skip "已保留应用数据 ($((Format-Size $size))): $p（加 -RemoveAppData 可删除）"
    }
}

Remove-Shortcuts
Remove-RegistryResiduals
Remove-ScheduledTasks
Remove-AnthropicUserEnvVars

if (-not $keepCli) {
    Write-Step '删除 Claude Code CLI 配置'
    $cliDir = Join-Path $env:USERPROFILE '.claude'
    if (-not (Remove-Target -Path $cliDir)) {
        $failures.Add($cliDir)
    }
}

Write-Step '检查残留'
$checkPatterns = Get-ResidualPathPatterns
if ($RemoveAppData) {
    $checkPatterns += Get-AppDataPathPatterns
}
if (-not $keepCli) {
    $checkPatterns += (Join-Path $env:USERPROFILE '.claude')
}
$remaining = Expand-PathPatterns -Patterns $checkPatterns
$svcState = Get-CoworkVmServiceState
$msixLeft = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
$provisionedLeft = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Claude*' }

if ($remaining) {
    foreach ($p in $remaining) {
        $size = Get-PathSizeBytes -Path $p
        Write-Warn "仍存在 ($((Format-Size $size))): $p"
        $failures.Add($p)
    }
}
if ($svcState -eq 'Present') {
    Write-Warn 'CoworkVMService 仍存在（实体服务，非幽灵）'
    $failures.Add('CoworkVMService')
}
elseif ($svcState -eq 'Ghost') {
    Write-Warn 'CoworkVMService 幽灵登记仍在服务列表中，可忽略，无需重启'
}
if ($msixLeft) {
    Write-Warn "MSIX 包仍存在: $($msixLeft.PackageFullName) (Status: $($msixLeft.Status))"
    $failures.Add($msixLeft.PackageFullName)
}
if ($provisionedLeft) {
    foreach ($p in $provisionedLeft) {
        Write-Warn "预置包仍存在: $($p.PackageName)"
        $failures.Add($p.PackageName)
    }
}

$needsReboot = $false
if ($msixLeft -and $msixLeft.Status -eq 'Servicing') {
    $needsReboot = $true
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Magenta
if ($failures.Count -eq 0) {
    Write-Host '   Claude 桌面端已移除，可直接重装。' -ForegroundColor Green
    if ($svcState -eq 'Ghost') {
        Write-Host '   幽灵服务可忽略；仅当重装报错时再重启。' -ForegroundColor DarkGray
    }
    if ($keepCli) {
        Write-Host '   ~/.claude 已保留（CLI 仍可使用）。' -ForegroundColor DarkGray
    }
    if (-not $RemoveAppData) {
        $preserved = Expand-PathPatterns -Patterns (Get-AppDataPathPatterns)
        if ($preserved) {
            Write-Host '   %LOCALAPPDATA%\Claude-3p / Claude-Data 已保留；加 -RemoveAppData 可彻底删除。' -ForegroundColor DarkGray
        }
    }
}
else {
    Write-Host '   完成，但仍有需处理的残留（见上方 [WARN]/[FAIL]）。' -ForegroundColor Yellow
    if ($needsReboot) {
        Write-Host '   MSIX 卡在 Servicing：建议重启后再运行本脚本或重装。' -ForegroundColor Yellow
    }
    else {
        Write-Host '   可先尝试直接重装；仅当安装失败时再重启并重跑脚本。' -ForegroundColor Yellow
    }
}
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host ''
Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
[void](Read-Host)

if ($failures.Count -gt 0) { exit 2 }
exit 0
