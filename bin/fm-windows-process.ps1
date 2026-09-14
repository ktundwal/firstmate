#!/usr/bin/env pwsh
# Read native process evidence only. Never acquire locks or signal processes.
# Usage: fm-windows-process.ps1 -Operation ancestry -Value <Windows PID>
#        fm-windows-process.ps1 -Operation inspect -Value win:<PID>:<creation ticks>
[CmdletBinding()]
param(
    [ValidateSet('ancestry', 'inspect', 'copilot-owner')]
    [string]$Operation = 'ancestry',
    [string]$Value
)

$ErrorActionPreference = 'Stop'

function Get-FmWindowsAncestry {
    param([hashtable]$Table, [uint32]$StartProcessId)

    $rows = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[uint32]]::new()
    $cursor = $StartProcessId
    $childCreated = [long]::MaxValue
    $termination = 'depth-limit'
    for ($hop = 0; $hop -lt 16; $hop++) {
        if (-not $seen.Add($cursor)) { $termination = 'cycle'; break }
        if (-not $Table.ContainsKey($cursor)) { $termination = 'missing-parent'; break }
        $row = $Table[$cursor]
        if ($row.CreatedTicks -le 0 -or [string]::IsNullOrWhiteSpace($row.Path)) {
            $termination = 'unreadable-process'
            break
        }
        # Windows retains a dead parent's PID. A later process using that PID is not the parent.
        if ($row.CreatedTicks -gt $childCreated) { $termination = 'reused-parent'; break }
        $rows.Add($row)
        $childCreated = $row.CreatedTicks
        $cursor = $row.ParentPid
        if ($cursor -eq 0) { $termination = 'root'; break }
    }
    [pscustomobject]@{ processes = $rows.ToArray(); termination = $termination }
}

function ConvertTo-FmWindowsProcess {
    param([object]$Process)

    $created = if ($null -eq $Process.CreationDate) { 0L } else {
        $Process.CreationDate.ToUniversalTime().Ticks
    }
    [pscustomobject]@{
        Pid = [uint32]$Process.ProcessId
        ParentPid = [uint32]$Process.ParentProcessId
        CreatedTicks = $created
        Identity = "win:$($Process.ProcessId):$created"
        Path = [string]$Process.ExecutablePath
        CommandLine = [string]$Process.CommandLine
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Operation -eq 'copilot-owner') {
    if ($Value -notmatch '^[1-9][0-9]*$' -or
        $env:COPILOT_AGENT_SESSION_ID -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Copilot owner lookup requires its published PID and session GUID'
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([uint32]$Value)" -OperationTimeoutSec 5
    $found = $false
    $row = $null
    if ($null -ne $process) {
        $row = ConvertTo-FmWindowsProcess $process
        if ([IO.Path]::GetFileName($row.Path) -ieq 'copilot.exe' -and $row.CreatedTicks -gt 0) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FmWindowsArguments {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Parse(string command) {
        int count;
        IntPtr memory = CommandLineToArgvW(command, out count);
        if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            return result;
        } finally { LocalFree(memory); }
    }
}
'@
            $arguments = [FmWindowsArguments]::Parse($row.CommandLine)
            $sessions = [Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $arguments.Length; $i++) {
                if ($arguments[$i] -eq '--') { break }
                if ($arguments[$i] -eq '--session-id' -and $i + 1 -lt $arguments.Length) {
                    $sessions.Add($arguments[++$i])
                } elseif ($arguments[$i].StartsWith('--session-id=')) {
                    $sessions.Add($arguments[$i].Substring('--session-id='.Length))
                }
            }
            $found = $sessions.Count -eq 1 -and $sessions[0] -ceq $env:COPILOT_AGENT_SESSION_ID
        }
    }
    [pscustomobject]@{ found = $found; process = $row } | ConvertTo-Json -Compress
    exit 0
}

if ($Operation -eq 'inspect') {
    if ($Value -notmatch '^win:([1-9][0-9]*):([1-9][0-9]*)$') {
        throw 'Expected a generation-bound Windows identity: win:<PID>:<creation ticks>'
    }
    $processId = [uint32]$Matches[1]
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -OperationTimeoutSec 5
    if ($null -eq $process) {
        [pscustomobject]@{ found = $false } | ConvertTo-Json -Compress
    } else {
        $row = ConvertTo-FmWindowsProcess $process
        if ([string]::IsNullOrWhiteSpace($row.Path) -or $row.CreatedTicks -le 0) {
            throw "Cannot read native identity for Windows process $processId"
        }
        [pscustomobject]@{ found = ($row.Identity -eq $Value); process = $row } |
            ConvertTo-Json -Compress
    }
    exit 0
}

if ($Value -notmatch '^[1-9][0-9]*$') { throw 'Expected a positive Windows process ID' }
$table = @{}
Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,ExecutablePath,CommandLine `
    -OperationTimeoutSec 5 | ForEach-Object {
        $row = ConvertTo-FmWindowsProcess $_
        $table[$row.Pid] = $row
    }
Get-FmWindowsAncestry -Table $table -StartProcessId ([uint32]$Value) |
    ConvertTo-Json -Depth 4 -Compress
