#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 离线安装脚本的共用函数。

.DESCRIPTION
    只放不含副作用的纯函数：数据目录探测、版本标记读取、哈希校验、大小格式化。
    安装、收集、卸载脚本通过 dot-source 引入。
#>

function Get-ClaudeDataRootCandidates {
    [CmdletBinding()]
    param()

    return [ordered]@{
        '3p'       = Join-Path $env:LOCALAPPDATA 'Claude-3p'
        'standard' = Join-Path $env:APPDATA 'Claude'
        'data'     = Join-Path $env:LOCALAPPDATA 'Claude-Data'
        'legacy'   = Join-Path $env:LOCALAPPDATA 'Claude'
    }
}

function Get-ClaudeDeploymentModeFromConfig {
    [CmdletBinding()]
    param()

    $configPath = Join-Path $env:LOCALAPPDATA 'Claude\claude_desktop_config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }

    try {
        $json = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'deploymentMode') {
            return [string]$json.deploymentMode
        }
    }
    catch {
        # 配置损坏时按“未配置”处理，由后续目录探测决定。
    }
    return $null
}

function Resolve-ClaudeDataRoot {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', '3p', 'Standard')]
        [string]$Mode = 'Auto',

        [string]$ExplicitPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [pscustomobject]@{
            Path   = $ExplicitPath
            Mode   = 'Explicit'
            Reason = '由 -DataRoot 指定'
        }
    }

    $candidates = Get-ClaudeDataRootCandidates

    if ($Mode -eq '3p') {
        return [pscustomobject]@{
            Path   = $candidates['3p']
            Mode   = '3p'
            Reason = '-DeploymentMode 3p'
        }
    }
    if ($Mode -eq 'Standard') {
        return [pscustomobject]@{
            Path   = $candidates['standard']
            Mode   = 'Standard'
            Reason = '-DeploymentMode Standard'
        }
    }

    # Auto：优先 3p（配置或目录存在），其次标准目录，最后按标准模式默认。
    $configMode = Get-ClaudeDeploymentModeFromConfig
    if ($configMode -eq '3p' -or (Test-Path -LiteralPath $candidates['3p'])) {
        return [pscustomobject]@{
            Path   = $candidates['3p']
            Mode   = '3p'
            Reason = '检测到 3p 配置或数据目录'
        }
    }
    if (Test-Path -LiteralPath $candidates['standard']) {
        return [pscustomobject]@{
            Path   = $candidates['standard']
            Mode   = 'Standard'
            Reason = '检测到标准数据目录'
        }
    }
    if (Test-Path -LiteralPath $candidates['data']) {
        return [pscustomobject]@{
            Path   = $candidates['data']
            Mode   = 'Data'
            Reason = '检测到 Claude-Data 目录'
        }
    }
    if (Test-Path -LiteralPath $candidates['legacy']) {
        return [pscustomobject]@{
            Path   = $candidates['legacy']
            Mode   = 'Legacy'
            Reason = '检测到 Claude 目录'
        }
    }

    return [pscustomobject]@{
        Path   = $candidates['standard']
        Mode   = 'Standard'
        Reason = '未检测到现有目录，按标准模式默认'
    }
}

function Get-ClaudeRuntimeStamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DataRoot
    )

    $stamp = [ordered]@{
        ClaudeCodeVersion = $null
        ClaudeCodeBuildId = $null
        VmVersion         = $null
        VmBundleVersion   = $null
    }

    $ccRoot = Join-Path $DataRoot 'claude-code'
    if (Test-Path -LiteralPath $ccRoot) {
        $versionDirs = @(Get-ChildItem -LiteralPath $ccRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' })
        if ($versionDirs.Count -eq 0) {
            $versionDirs = @(Get-ChildItem -LiteralPath $ccRoot -Directory -ErrorAction SilentlyContinue)
        }
        $versionDir = $versionDirs |
            Sort-Object -Property @{ Expression = { try { [version]$_.Name } catch { [version]'0.0.0' } } } -Descending |
            Select-Object -First 1
        if ($versionDir) {
            $stamp.ClaudeCodeVersion = $versionDir.Name
            # 同版本下可能有多个构建；取最近一次校验通过（.verified 最新）且含 claude.exe 的。
            $buildDirs = @(Get-ChildItem -LiteralPath $versionDir.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match '^[0-9a-f]{12}$' -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'claude.exe'))
                })
            $buildDir = $buildDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($buildDir) { $stamp.ClaudeCodeBuildId = $buildDir.Name }
        }
    }

    $vmRoot = Join-Path $DataRoot 'claude-code-vm'
    if (Test-Path -LiteralPath $vmRoot) {
        $sdkVersion = Join-Path $vmRoot '.sdk-version'
        if (Test-Path -LiteralPath $sdkVersion) {
            $stamp.VmVersion = (Get-Content -LiteralPath $sdkVersion -Raw -ErrorAction SilentlyContinue).Trim()
        }
        if (-not $stamp.VmVersion) {
            $versionDir = Get-ChildItem -LiteralPath $vmRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
                Sort-Object -Property @{ Expression = { try { [version]$_.Name } catch { [version]'0.0.0' } } } -Descending |
                Select-Object -First 1
            if ($versionDir) { $stamp.VmVersion = $versionDir.Name }
        }
    }

    $adopted = Join-Path $DataRoot 'vm_bundles\claudevm.bundle\.cowork-adopted'
    if (Test-Path -LiteralPath $adopted) {
        $stamp.VmBundleVersion = (Get-Content -LiteralPath $adopted -Raw -ErrorAction SilentlyContinue).Trim()
    }

    return [pscustomobject]$stamp
}

function Get-ClaudeSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Test-ClaudeSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Expected
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-ClaudeSha256 -Path $Path) -eq $Expected.ToLowerInvariant())
}

function Format-ClaudeSize {
    [CmdletBinding()]
    param([int64]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-ClaudeFreeSpaceBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $qualifier = Split-Path -Qualifier $Path
        $driveName = $qualifier.TrimEnd(':')
        $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
        return [int64]$drive.Free
    }
    catch {
        return $null
    }
}
