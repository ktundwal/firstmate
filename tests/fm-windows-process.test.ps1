param([Parameter(Mandatory)][string]$Library)
$ErrorActionPreference = 'Stop'
. $Library

function New-ProcessRow {
    param([uint32]$Id, [uint32]$Parent, [long]$Created)
    [pscustomobject]@{
        Pid = $Id
        ParentPid = $Parent
        CreatedTicks = $Created
        Identity = "win:${Id}:$Created"
        Path = 'C:\tools\copilot.exe'
        CommandLine = 'copilot'
    }
}

$table = @{}
$table[[uint32]10] = New-ProcessRow 10 20 200
$table[[uint32]20] = New-ProcessRow 20 0 100
$result = Get-FmWindowsAncestry $table 10
if (($result.processes.Pid -join ',') -ne '10,20' -or $result.termination -ne 'root') {
    throw 'An intact, creation-ordered parent chain was not preserved'
}
Write-Output 'ok - native ancestry preserves an intact parent chain'

$table[[uint32]20] = New-ProcessRow 20 0 300
$result = Get-FmWindowsAncestry $table 10
if (($result.processes.Pid -join ',') -ne '10' -or $result.termination -ne 'reused-parent') {
    throw 'A recycled parent PID entered the ancestry'
}
Write-Output 'ok - a parent created after its child is excluded'

$table.Remove([uint32]20)
$result = Get-FmWindowsAncestry $table 10
if (($result.processes.Pid -join ',') -ne '10' -or $result.termination -ne 'missing-parent') {
    throw 'A missing parent was treated as a complete chain'
}
Write-Output 'ok - a severed parent chain remains explicitly incomplete'

$table[[uint32]20] = New-ProcessRow 20 10 200
$result = Get-FmWindowsAncestry $table 10
if (($result.processes.Pid -join ',') -ne '10,20' -or $result.termination -ne 'cycle') {
    throw 'An ancestry cycle was not bounded'
}
Write-Output 'ok - cyclic process data does not repeat an ancestor'

$table[[uint32]20].Path = ''
$result = Get-FmWindowsAncestry $table 10
if (($result.processes.Pid -join ',') -ne '10' -or $result.termination -ne 'unreadable-process') {
    throw 'Unreadable executable identity was treated as usable evidence'
}
Write-Output 'ok - unreadable executable identity is excluded'
