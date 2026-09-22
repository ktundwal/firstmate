#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$Path,
    [ValidateSet('file', 'directory')]
    [string]$Kind = 'directory'
)
$ErrorActionPreference = 'Stop'

function Test-FmPrivateAcl {
    param(
        [Security.AccessControl.FileSystemSecurity]$Acl,
        [Security.Principal.SecurityIdentifier]$CurrentUser
    )
    if ($Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $CurrentUser.Value) {
        return $false
    }
    $allowed = @($CurrentUser.Value, 'S-1-5-18', 'S-1-5-32-544')
    $hasOwnerControl = $false
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Value -notin $allowed) {
            return $false
        }
        if ($rule.IdentityReference.Value -eq $CurrentUser.Value -and
            -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl) {
            $hasOwnerControl = $true
        }
    }
    return $hasOwnerControl
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Private Windows data requires an absolute local drive path' }
$item = Get-Item -LiteralPath $Path -Force
if (($Kind -eq 'directory') -ne $item.PSIsContainer) { throw "Unexpected private-path type: $Path" }
$ancestor = $item
while ($null -ne $ancestor) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Private-path validation refuses a reparse point: $($ancestor.FullName)"
    }
    $ancestor = if ($ancestor -is [IO.DirectoryInfo]) { $ancestor.Parent } else { $ancestor.Directory }
}
$acl = Get-Acl -LiteralPath $item.FullName
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
if (-not (Test-FmPrivateAcl $acl $user)) {
    [Console]::Error.WriteLine("Private data requires current-user ownership and access limited to that user, SYSTEM and Administrators: $Path")
    exit 1
}
exit 0
