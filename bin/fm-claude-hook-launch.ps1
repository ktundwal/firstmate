#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Script,

    [switch]$SkipIfGrok,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = 'Stop'

if ($SkipIfGrok -and ($env:GROK_AGENT -or $env:GROK_HOOK_EVENT)) {
    exit 0
}

if ($Script -notmatch '^[A-Za-z0-9_.-]+\.sh$') {
    Write-Error "fm-claude-hook-launch.ps1: rejected -Script value '$Script' (expected a bare <name>.sh with no path separators)"
    exit 1
}

$binDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $binDir $Script
$resolvedTarget = $null
try {
    $resolvedTarget = (Resolve-Path -LiteralPath $target -ErrorAction Stop).ProviderPath
} catch {
    Write-Error "fm-claude-hook-launch.ps1: target script not found: $target"
    exit 1
}
if ((Split-Path -Parent $resolvedTarget) -ne (Resolve-Path -LiteralPath $binDir).ProviderPath) {
    Write-Error "fm-claude-hook-launch.ps1: resolved target '$resolvedTarget' escaped $binDir"
    exit 1
}

$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Error 'fm-claude-hook-launch.ps1: git.exe not found on PATH; cannot locate Git Bash.'
    exit 1
}
$gitBash = $null
$dir = Split-Path $gitCmd.Source -Parent
for ($i = 0; $i -lt 4; $i++) {
    $candidate = Join-Path $dir 'bin\bash.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $gitBash = $candidate
        break
    }
    $parent = Split-Path $dir -Parent
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
}
if (-not $gitBash) {
    Write-Error "fm-claude-hook-launch.ps1: Git Bash (bin\bash.exe) not found near git.exe at $($gitCmd.Source); a non-Git-for-Windows git install is not supported by this launcher."
    exit 1
}

$ErrorActionPreference = 'Continue'
& $gitBash $resolvedTarget @ScriptArgs
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) {
    Write-Error 'fm-claude-hook-launch.ps1: Git Bash did not report an exit code; treating as failure.'
    exit 1
}
if ($exitCode -eq 0) {
    exit 0
}
