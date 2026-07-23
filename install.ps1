#Requires -Version 5.1
<#
.SYNOPSIS
    One-line installer for ccsm plus gc2cc's ccp/cxp wrappers.

.DESCRIPTION
    Installs/updates:
      - gc2cc proxy service and both wrappers: ccp, cxp
      - @bakapiano/ccsm
      - ccsm built-in Claude/Codex commands routed through ccp/cxp
      - ccsm default CLI (ccp by default)

    Intended entry point:
      irm https://bakapiano.github.io/ccsm-gc2cc/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string] $Gc2ccBaseUrl = 'https://bakapiano.github.io/gc2cc',
    [string] $CcsmPackage  = '@bakapiano/ccsm@latest',
    [string] $InstallClis  = 'ccp,cxp',
    [ValidateSet('ccp','cxp')]
    [string] $DefaultCli   = 'ccp',
    [switch] $SkipGc2cc,
    [switch] $SkipCcsm,
    [switch] $SkipCcsmConfig,
    [switch] $NoLaunch,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Info($m) { Write-Host "[ccsm-gc2cc] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ccsm-gc2cc] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[ccsm-gc2cc] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[ccsm-gc2cc] $m" -ForegroundColor Red; throw "[ccsm-gc2cc] $m" }

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @()
    if ($env:LOCALAPPDATA) { $extra += (Join-Path $env:LOCALAPPDATA 'gc2cc\bin') }
    if ($env:APPDATA)      { $extra += (Join-Path $env:APPDATA 'npm') }
    $env:Path = (@($env:Path, $m, $u) + $extra | Where-Object { $_ }) -join ';'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter()][string[]] $ArgumentList = @(),
        [Parameter()][string] $FailureMessage = "Command failed: $FilePath"
    )

    if ($DryRun) {
        Info ("DRY RUN: {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
        return
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($null -ne $code -and $code -ne 0) {
        Die "$FailureMessage (exit=$code)"
    }
}

function Resolve-RequiredCommand {
    param([Parameter(Mandatory)][string] $Name)
    Refresh-Path
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Resolve-Npm {
    $npm = Resolve-RequiredCommand 'npm.cmd'
    if ($npm) { return $npm }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\npm.cmd') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'nodejs\npm.cmd') }
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'npm\npm.cmd') }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Resolve-WindowsPowerShell {
    $candidates = @()
    if ($env:SystemRoot) { $candidates += (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
    if ($env:WINDIR)     { $candidates += (Join-Path $env:WINDIR     'System32\WindowsPowerShell\v1.0\powershell.exe') }
    if ($PSHOME)         { $candidates += (Join-Path $PSHOME 'powershell.exe') }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return 'powershell.exe'
}

function Invoke-Gc2ccInstall {
    if ($SkipGc2cc) {
        Warn 'Skipping gc2cc install by request.'
        return
    }

    $url = "$Gc2ccBaseUrl/install.ps1"
    $tmp = Join-Path $env:TEMP ("gc2cc-install-{0}.ps1" -f ([Guid]::NewGuid()))
    try {
        Info "Fetching gc2cc installer: $url"
        if (-not $DryRun) {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        }

        Info "Installing gc2cc wrappers: $InstallClis"
        Invoke-Native -FilePath (Resolve-WindowsPowerShell) -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $tmp,
            '-InstallClis', $InstallClis,
            '-NonInteractive'
        ) -FailureMessage 'gc2cc installer failed'
    } finally {
        if (-not $DryRun -and $tmp -and (Test-Path $tmp)) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-Ccsm {
    if ($SkipCcsm) {
        Warn 'Skipping ccsm npm install by request.'
        return
    }

    Refresh-Path
    $npm = Resolve-Npm
    if (-not $npm) {
        Die "npm.cmd was not found. Re-run after Node.js is installed, or let gc2cc finish installing Node.js first."
    }

    Info "Installing ccsm package: $CcsmPackage"
    Invoke-Native -FilePath $npm -ArgumentList @(
        'install',
        '-g',
        $CcsmPackage,
        '--no-fund',
        '--no-audit'
    ) -FailureMessage 'ccsm npm install failed'
    Refresh-Path
}

function Resolve-WrapperScript {
    param([Parameter(Mandatory)][ValidateSet('ccp','cxp')][string] $Name)

    $canonical = Join-Path $env:LOCALAPPDATA ("gc2cc\bin\{0}.ps1" -f $Name)
    if (Test-Path $canonical) { return $canonical }

    $cmd = Resolve-RequiredCommand ("$Name.cmd")
    if ($cmd) {
        $candidate = Join-Path (Split-Path $cmd -Parent) "$Name.ps1"
        if (Test-Path $candidate) { return $candidate }
    }

    return $canonical
}

function Get-RequestedWrapperNames {
    $names = @($InstallClis -split '[,;\s]+' |
        Where-Object { $_ -and $_ -ne 'none' } |
        ForEach-Object { $_.ToLowerInvariant() })
    return @($names | Where-Object { $_ -in @('ccp', 'cxp') } | Select-Object -Unique)
}

function Get-Gc2ccConfigPath {
    param([Parameter(Mandatory)][ValidateSet('ccp','cxp')][string] $Name)
    return (Join-Path $HOME (".local\share\gc2cc\{0}.json" -f $Name))
}

function Invoke-MissingGc2ccConfig {
    foreach ($name in Get-RequestedWrapperNames) {
        $configPath = Get-Gc2ccConfigPath $name
        if (Test-Path $configPath) {
            Ok "$name config already exists: $configPath"
            continue
        }

        $script = Resolve-WrapperScript $name
        if (-not (Test-Path $script)) {
            Die "$name wrapper script was not found at $script. The gc2cc install did not complete."
        }

        Info "$name config not found; running interactive '$name config' once."
        Invoke-Native -FilePath (Resolve-WindowsPowerShell) -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script,
            'config'
        ) -FailureMessage "$name config failed"
    }
}

function Get-CcsmHome {
    if ($env:CCSM_HOME) { return $env:CCSM_HOME }
    return (Join-Path $HOME '.ccsm')
}

function Get-CcsmPreferredPort {
    $configPath = Join-Path (Get-CcsmHome) 'config.json'
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.port) { return [int]$cfg.port }
        } catch {}
    }
    return 7777
}

function Test-CcsmHealth {
    param([Parameter(Mandatory)][int] $Port)
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        $health = $r.Content | ConvertFrom-Json
        return ($health.name -eq '@bakapiano/ccsm')
    } catch {
        return $false
    }
}

function Get-RunningCcsmPort {
    $preferred = Get-CcsmPreferredPort
    foreach ($port in @($preferred) + @(1..9 | ForEach-Object { $preferred + $_ })) {
        if (Test-CcsmHealth -Port $port) { return $port }
    }
    return $null
}

function Set-ObjectProperty {
    param($Object, [string] $Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function New-Gc2ccBuiltinCli {
    param([Parameter(Mandatory)][ValidateSet('ccp','cxp')][string] $Name)
    $command = Join-Path $env:LOCALAPPDATA ("gc2cc\bin\{0}.cmd" -f $Name)
    if (-not (Test-Path $command)) {
        Die "$Name wrapper was not found at $command. The gc2cc install did not complete."
    }

    if ($Name -eq 'ccp') {
        return [pscustomobject][ordered]@{
            id               = 'claude'
            name             = 'Claude Code via Copilot (ccp)'
            command          = $command
            args             = @()
            resumeLatestArgs = @('--continue')
            resumePickerArgs = @('--resume')
            resumeIdArgs     = @('--resume', '<id>')
            shell            = 'direct'
            type             = 'claude'
            builtin          = $true
        }
    }

    return [pscustomobject][ordered]@{
        id               = 'codex'
        name             = 'Codex via Copilot (cxp)'
        command          = $command
        args             = @()
        resumeLatestArgs = @('resume', '--last')
        resumePickerArgs = @('resume')
        resumeIdArgs     = @('resume', '<id>')
        shell            = 'direct'
        type             = 'codex'
        builtin          = $true
    }
}

function Merge-Gc2ccBuiltins {
    param($Config)
    $requested = @(Get-RequestedWrapperNames)
    if ($requested.Count -eq 0) { return $Config }

    $replaceIds = @()
    if ($requested -contains 'ccp') { $replaceIds += 'claude' }
    if ($requested -contains 'cxp') { $replaceIds += 'codex' }

    # Remove old custom ccp/cxp entries and the built-ins being replaced.
    $preserved = @()
    if (($Config.PSObject.Properties.Name -contains 'clis') -and $Config.clis) {
        $preserved = @($Config.clis | Where-Object {
            $_.id -notin @('ccp', 'cxp') -and $_.id -notin $replaceIds
        })
    }

    $managed = @()
    foreach ($name in $requested) { $managed += New-Gc2ccBuiltinCli $name }
    Set-ObjectProperty $Config 'clis' @($managed + $preserved)

    $effectiveDefault = $DefaultCli
    if ($requested -notcontains $effectiveDefault) {
        $effectiveDefault = $requested[0]
        Warn "Requested default '$DefaultCli' is not installed; using '$effectiveDefault'."
    }
    $defaultId = if ($effectiveDefault -eq 'cxp') { 'codex' } else { 'claude' }
    Set-ObjectProperty $Config 'defaultCliId' $defaultId
    return $Config
}

function Configure-Gc2ccAsCcsmBuiltins {
    if ($SkipCcsmConfig) {
        Warn 'Skipping ccsm CLI registration by request.'
        return
    }

    $requested = @(Get-RequestedWrapperNames)
    if ($requested.Count -eq 0) {
        Warn 'No gc2cc wrappers selected; skipping ccsm CLI replacement.'
        return
    }

    if ($DryRun) {
        $defaultId = if ($DefaultCli -eq 'cxp') { 'codex' } else { 'claude' }
        Info ("DRY RUN: replace ccsm built-ins with {0}; set defaultCliId={1}" -f ($requested -join ','), $defaultId)
        return
    }

    $ccsmHome = Get-CcsmHome
    $configPath = Join-Path $ccsmHome 'config.json'
    $runningPort = Get-RunningCcsmPort

    if ($runningPort) {
        $baseUrl = "http://localhost:$runningPort"
        Info "Replacing ccsm built-in CLIs through $baseUrl/api/config"
        try {
            $cfg = (Invoke-WebRequest -Uri "$baseUrl/api/config" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop).Content | ConvertFrom-Json
            $cfg = Merge-Gc2ccBuiltins $cfg
            $json = $cfg | ConvertTo-Json -Depth 50
            Invoke-WebRequest -Uri "$baseUrl/api/config" -Method PUT -Body $json `
                -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
        } catch {
            Die "Failed to configure running ccsm at ${baseUrl}: $_"
        }
    } else {
        Info "ccsm is not running; updating $configPath directly"
        if (Test-Path $configPath) {
            try {
                $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Die "$configPath is invalid JSON; refusing to overwrite it: $_"
            }
        } else {
            New-Item -ItemType Directory -Force -Path $ccsmHome | Out-Null
            $cfg = [pscustomobject]@{}
        }
        $cfg = Merge-Gc2ccBuiltins $cfg
        $json = $cfg | ConvertTo-Json -Depth 50
        [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding $false))
    }

    $effectiveDefault = if ($requested -contains $DefaultCli) { $DefaultCli } else { $requested[0] }
    $defaultLabel = if ($effectiveDefault -eq 'cxp') { 'Codex via Copilot (cxp)' } else { 'Claude Code via Copilot (ccp)' }
    Ok ("Replaced ccsm built-in entries with: {0}." -f ($requested -join ', '))
    Ok "ccsm default CLI: $defaultLabel"
}

function Resolve-CcsmCommand {
    $cmd = Resolve-RequiredCommand 'ccsm.cmd'
    if ($cmd) { return $cmd }

    $npm = Resolve-Npm
    if ($npm) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $prefix = (& $npm prefix -g 2>$null | Select-Object -Last 1)
            if ($prefix) {
                $candidate = Join-Path ([string]$prefix).Trim() 'ccsm.cmd'
                if (Test-Path $candidate) { return $candidate }
            }
        } finally {
            $ErrorActionPreference = $prev
        }
    }

    if ($env:APPDATA) {
        $candidate = Join-Path $env:APPDATA 'npm\ccsm.cmd'
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Launch-Ccsm {
    if ($NoLaunch) {
        Warn 'Skipping ccsm launch by request.'
        return
    }

    Refresh-Path
    $ccsm = Resolve-CcsmCommand
    if (-not $ccsm) {
        Warn 'ccsm.cmd was installed but is not visible on PATH yet. Open a fresh shell and run ccsm.'
        return
    }

    Info 'Starting ccsm'
    Invoke-Native -FilePath $ccsm -ArgumentList @() -FailureMessage 'ccsm launch failed'
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Die 'This installer is Windows-only.'
}

Write-Host ''
Info 'Installing ccsm + gc2cc (ccp,cxp).'
Info 'gc2cc may prompt for UAC and GitHub Copilot device-code auth.'
Write-Host ''

Invoke-Gc2ccInstall
Invoke-MissingGc2ccConfig
Install-Ccsm
Configure-Gc2ccAsCcsmBuiltins
Launch-Ccsm

Write-Host ''
Ok 'Install complete.'
Write-Host '  ccsm : https://bakapiano.github.io/ccsm/'
Write-Host '  ccp  : Claude Code via GitHub Copilot'
Write-Host '  cxp  : Codex CLI via GitHub Copilot'
Write-Host ''
Write-Host 'Open a fresh terminal if ccp/cxp/ccsm are not visible on PATH yet.'
