#!/usr/bin/env pwsh
# Windows-native launcher for the Claude-compat hooks tracked in
# .claude/settings.json.
#
# GitHub Copilot CLI reads .claude/settings.json using its own hook schema
# (bash/powershell/command/exec/args/cwd/env/timeoutSec), not Claude Code's
# minimal one. Per GitHub's own hooks reference, a settings.json "command"
# field is copied into "powershell" only when an explicit "powershell" field
# is absent - and every entry here previously had POSIX/Bash-only "command"
# strings, so Copilot ran that Bash syntax through PowerShell and failed to
# parse it (every tool call was denied with "hook errored"). This script is
# what the "powershell" field now points at instead; the existing "command"
# field is untouched and still drives Claude Code / Bash-based harnesses.
#
# The guard scripts under bin/ derive their own root from ${BASH_SOURCE[0]}
# (see e.g. fm-subagent-pretool-check.sh's SCRIPT_DIR/FM_ROOT block), so this
# launcher's only job is to invoke the right script file under Git Bash with
# its arguments and stdin intact - it does not need to compute or forward a
# project-root variable.
#
# A bare `bash` on PATH can resolve to the WSL launcher
# (C:\Windows\System32\bash.exe) instead of Git Bash, which is a different,
# unrelated environment. Git Bash is instead resolved from git.exe's own
# install layout (<gitroot>\cmd\git.exe -> <gitroot>\bin\bash.exe), since
# `git` itself must already be on PATH for this repository to be usable.
#
# Usage (matches settings.json "powershell" fields):
#   fm-claude-hook-launch.ps1 -Script <name>.sh [-SkipIfGrok] [-- <args...>]
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

# Reject anything that isn't a bare "<name>.sh" - the launcher only ever
# forwards to a fixed, tracked script under bin/, so path separators or a
# non-.sh name indicate a caller bug rather than a legitimate target.
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
# git.exe's install-relative location varies with which of it is first on
# PATH: <gitroot>\cmd\git.exe (typical from a plain Windows shell) sits one
# level above <gitroot>, but <gitroot>\mingw64\bin\git.exe (what a Git Bash
# session itself puts first on PATH) sits two levels above it. bash.exe only
# ever lives at <gitroot>\bin\bash.exe in a standard Git for Windows install,
# so walk a bounded number of ancestor directories from git.exe looking for
# that sibling instead of assuming a fixed depth.
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
# Deliberately do not `exit <nonzero>` here. Verified empirically: under
# `pwsh -NoProfile -Command "& thisScript.ps1 ..."`, a nonzero `exit N` raised
# *inside* an `&`-invoked (or dot-sourced) nested script gets collapsed to a
# bare 1 by the outer host - the real code N never reaches the process exit
# code. That would silently downgrade Claude's exit-2 "blocking deny" into a
# generic exit-1 error, i.e. exactly the fail-open/silently-inert-guard risk
# this launcher exists to avoid. $LASTEXITCODE itself is an unscoped engine
# value, not a normal script-scoped variable, so it survives across that `&`
# boundary as long as nothing calls `exit` afterward. Every settings.json
# "powershell" field that uses this launcher MUST therefore end with
# `; exit $LASTEXITCODE` so the real guard-script exit code (already sitting
# in $LASTEXITCODE from the invocation above) becomes the actual process exit
# code once control returns there.
