#Requires -Version 5.1
<#
.SYNOPSIS
    从一台已安装并成功运行过 Cowork 的电脑上，收集离线安装所需的运行时文件。

.DESCRIPTION
    收集内容（全部来自 Anthropic 官方、未经修改）：
      - Claude Code 宿主二进制（Windows）
      - Cowork VM 内的 Claude Code 二进制
      - VM 镜像的原始压缩包 rootfs.vhdx.zst / vmlinuz.zst / initrd.zst
      - 上述文件对应的 .verified / .payload / .origin 标记
      - 可选的 Claude.msix 安装包

    不会收集 rootfs.vhdx、sessiondata.vhdx 等运行期磁盘，避免把本机工作区数据
    打进离线包。

    输出到 pkg\runtime 并生成 pkg\manifest.json，供 install-claude-desktop.ps1 校验和部署。

.PARAMETER DataRoot
    Claude 数据根目录。默认自动探测（3p / 标准 / Claude-Data）。

.PARAMETER DeploymentMode
    Auto / 3p / Standard，默认 Auto。

.PARAMETER OutputDir
    输出目录，默认仓库根目录下的 pkg。

.PARAMETER MsixPath
    Claude.msix 路径。默认读取 %LOCALAPPDATA%\ClaudeInstaller\cache\Claude-win-x64.msix。

.PARAMETER SkipMsix
    不收集 MSIX，只生成 runtime 包。

.PARAMETER NoPause
    结束后不等待回车（便于自动化）。

.EXAMPLE
    .\collect-runtime.ps1

.EXAMPLE
    .\collect-runtime.ps1 -DeploymentMode 3p -OutputDir D:\claude-offline-pkg
#>

[CmdletBinding()]
param(
    [string]$DataRoot = '',

    [ValidateSet('Auto', '3p', 'Standard')]
    [string]$DeploymentMode = 'Auto',

    [string]$OutputDir = '',

    [string]$MsixPath = '',

    [switch]$SkipMsix,

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'ClaudeOffline.Common.ps1')

if (-not $OutputDir) { $OutputDir = Join-Path $rootDir 'pkg' }
$logDir = Join-Path $rootDir 'log'
$null = New-Item -ItemType Directory -Force -Path $OutputDir, $logDir
$logPath = Join-Path $logDir 'collect-runtime.log'
$runtimeRoot = Join-Path $OutputDir 'runtime'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   [OK]   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   [WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

function Wait-BeforeClose {
    if ($NoPause) { return }
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    [void](Read-Host)
}

$exitCode = 0
try {
    Start-Transcript -Path $logPath -Append -Force | Out-Null

    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host '   Claude Desktop 离线运行时收集' -ForegroundColor Magenta
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host "   输出目录: $OutputDir"
    Write-Host "   日志: $logPath"
    Write-Host ''

    $resolved = Resolve-ClaudeDataRoot -Mode $DeploymentMode -ExplicitPath $DataRoot
    $sourceRoot = $resolved.Path
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        throw "数据目录不存在：$sourceRoot"
    }
    Write-Ok "源数据目录：$sourceRoot（$($resolved.Mode)：$($resolved.Reason)）"

    $stamp = Get-ClaudeRuntimeStamp -DataRoot $sourceRoot
    if (-not $stamp.ClaudeCodeVersion -or -not $stamp.ClaudeCodeBuildId) {
        throw "未找到 Claude Code 宿主二进制版本目录（claude-code\<version>\<build>）。请先启动一次 Claude Desktop。"
    }
    if (-not $stamp.VmVersion) {
        throw "未找到 VM 内 Claude Code 版本（claude-code-vm\.sdk-version）。请先成功启动一次 Cowork 工作区。"
    }
    if (-not $stamp.VmBundleVersion) {
        throw "未找到 VM bundle 版本标记（.cowork-adopted）。请先成功启动一次 Cowork 工作区。"
    }

    Write-Ok "Claude Code（宿主）: $($stamp.ClaudeCodeVersion) / $($stamp.ClaudeCodeBuildId)"
    Write-Ok "Claude Code（VM）  : $($stamp.VmVersion)"
    Write-Ok "VM bundle         : $($stamp.VmBundleVersion)"

    $ccRel = "claude-code\$($stamp.ClaudeCodeVersion)\$($stamp.ClaudeCodeBuildId)"
    $vmRel = "claude-code-vm\$($stamp.VmVersion)"
    $bundleRel = 'vm_bundles\claudevm.bundle'

    $requiredRelativeFiles = @(
        "$ccRel\claude.exe",
        "$ccRel\.payload",
        "$ccRel\.verified",
        'claude-code-vm\.sdk-version',
        "$vmRel\claude",
        "$vmRel\.payload",
        "$vmRel\.verified",
        "$bundleRel\rootfs.vhdx.zst",
        "$bundleRel\.rootfs.vhdx.zst.origin",
        "$bundleRel\vmlinuz.zst",
        "$bundleRel\.vmlinuz.zst.origin",
        "$bundleRel\initrd.zst",
        "$bundleRel\.initrd.zst.origin",
        "$bundleRel\.cowork-adopted"
    )

    Write-Step '检查源文件'
    $missing = @()
    $sources = @()
    foreach ($rel in $requiredRelativeFiles) {
        $src = Join-Path $sourceRoot $rel
        if (-not (Test-Path -LiteralPath $src)) {
            $missing += $rel
            continue
        }
        $item = Get-Item -LiteralPath $src
        if ($item.Length -le 0) {
            $missing += "$rel（0 字节）"
            continue
        }
        $sources += [pscustomobject]@{
            Relative = $rel.Replace('\', '/')
            Source   = $src
            Size     = [int64]$item.Length
        }
    }
    if ($missing.Count -gt 0) {
        Write-Fail '以下必需文件缺失或不完整：'
        $missing | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        throw '请先在这台电脑上成功启动一次 Cowork 工作区，再重新运行本脚本。'
    }
    Write-Ok "共 $($sources.Count) 个文件，合计 $(Format-ClaudeSize (($sources | Measure-Object -Property Size -Sum).Sum))"

    Write-Step '复制运行时文件'
    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Force -Path $runtimeRoot

    $fileEntries = @()
    foreach ($entry in $sources) {
        $dst = Join-Path $runtimeRoot ($entry.Relative -replace '/', '\')
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) {
            $null = New-Item -ItemType Directory -Force -Path $dstDir
        }
        Copy-Item -LiteralPath $entry.Source -Destination $dst -Force
        $copied = Get-Item -LiteralPath $dst
        if ($copied.Length -ne $entry.Size) {
            throw "复制后大小不一致：$($entry.Relative)"
        }
        $hash = Get-ClaudeSha256 -Path $dst
        $fileEntries += [pscustomobject]@{
            path   = $entry.Relative
            size   = [int64]$copied.Length
            sha256 = $hash
        }
        Write-Ok "$($entry.Relative)（$(Format-ClaudeSize $copied.Length)）"
    }

    Write-Step '收集 MSIX'
    $msixEntry = $null
    if ($SkipMsix) {
        Write-Warn '已指定 -SkipMsix，跳过 MSIX。'
    }
    else {
        if (-not $MsixPath) {
            $MsixPath = Join-Path $env:LOCALAPPDATA 'ClaudeInstaller\cache\Claude-win-x64.msix'
        }
        if (Test-Path -LiteralPath $MsixPath) {
            $msixDst = Join-Path $OutputDir 'Claude.msix'
            Copy-Item -LiteralPath $MsixPath -Destination $msixDst -Force
            $msixItem = Get-Item -LiteralPath $msixDst
            $msixHash = Get-ClaudeSha256 -Path $msixDst
            $msixEntry = [pscustomobject]@{
                path   = 'Claude.msix'
                size   = [int64]$msixItem.Length
                sha256 = $msixHash
            }
            Write-Ok "Claude.msix（$(Format-ClaudeSize $msixItem.Length)）"
        }
        else {
            Write-Warn "未找到 MSIX：$MsixPath"
            Write-Warn '可以稍后手动把 Claude.msix 放进 pkg 目录。'
        }
    }

    Write-Step '读取应用版本'
    $appPkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Ok' } | Select-Object -First 1
    if (-not $appPkg) {
        $appPkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $appVersion = $null
    $appFamily = $null
    if ($appPkg) {
        $appVersion = [string]$appPkg.Version
        $appFamily = [string]$appPkg.PackageFamilyName
        Write-Ok "已安装应用：$appVersion（$appFamily）"
    }
    else {
        Write-Warn '未检测到已安装的 Claude MSIX，manifest 中应用版本将留空。'
    }

    Write-Step '生成 manifest.json'
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        app           = [ordered]@{
            name              = 'Claude'
            version           = $appVersion
            packageFamilyName = $appFamily
        }
        runtime       = [ordered]@{
            claudeCode = [ordered]@{
                version = $stamp.ClaudeCodeVersion
                buildId = $stamp.ClaudeCodeBuildId
            }
            vm         = [ordered]@{
                version = $stamp.VmVersion
            }
            vmBundle   = [ordered]@{
                version = $stamp.VmBundleVersion
            }
        }
        msix          = $msixEntry
        files         = $fileEntries
    }

    $manifestPath = Join-Path $OutputDir 'manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
    Write-Ok "manifest.json 已写入：$manifestPath"

    $totalBytes = [int64]0
    foreach ($f in $fileEntries) { $totalBytes += [int64]$f.size }
    if ($msixEntry) { $totalBytes += [int64]$msixEntry.size }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Ok "收集完成，共 $(Format-ClaudeSize $totalBytes)"
    Write-Host "   运行时目录: $runtimeRoot" -ForegroundColor Cyan
    Write-Host "   安装包目录: $OutputDir" -ForegroundColor Cyan
    Write-Host '   下一步：把 pkg 目录随仓库发布，或直接运行根目录的安装 bat。' -ForegroundColor DarkGray
    Write-Host '========================================' -ForegroundColor DarkGray
}
catch {
    Write-Fail "收集失败：$($_.Exception.Message)"
    $exitCode = 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    Wait-BeforeClose
    exit $exitCode
}
