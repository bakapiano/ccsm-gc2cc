#Requires -Version 5.1
<#
.SYNOPSIS
    One-line installer for ccsm plus gc2cc's ccp/cxp wrappers.

.DESCRIPTION
    Installs/updates:
      - gc2cc proxy service and both wrappers: ccp, cxp
      - @bakapiano/ccsm
      - ccsm CLI registrations for ccp and cxp

    Intended entry point:
      irm https://bakapiano.github.io/ccsm-gc2cc/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string] $Gc2ccBaseUrl = 'https://bakapiano.github.io/gc2cc',
    [string] $CcsmPackage  = '@bakapiano/ccsm@latest',
    [string] $InstallClis  = 'ccp,cxp',
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

function Register-Gc2ccWithCcsm {
    if ($SkipCcsmConfig) {
        Warn 'Skipping ccsm CLI registration by request.'
        return
    }

    foreach ($name in @('ccp', 'cxp')) {
        $script = Resolve-WrapperScript $name
        if (-not (Test-Path $script)) {
            Die "$name wrapper script was not found at $script. The gc2cc install did not complete."
        }
        Info "Registering $name in ccsm config"
        Invoke-Native -FilePath (Resolve-WindowsPowerShell) -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script,
            'ccsm'
        ) -FailureMessage "$name ccsm registration failed"
    }
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
Install-Ccsm
Register-Gc2ccWithCcsm
Launch-Ccsm

Write-Host ''
Ok 'Install complete.'
Write-Host '  ccsm : https://bakapiano.github.io/ccsm/'
Write-Host '  ccp  : Claude Code via GitHub Copilot'
Write-Host '  cxp  : Codex CLI via GitHub Copilot'
Write-Host ''
Write-Host 'Open a fresh terminal if ccp/cxp/ccsm are not visible on PATH yet.'
