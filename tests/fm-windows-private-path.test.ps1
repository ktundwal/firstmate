param([Parameter(Mandatory)][string]$Library)
$ErrorActionPreference = 'Stop'
. $Library
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')

function New-PrivateAcl {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($user)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    $acl
}

$acl = New-PrivateAcl
if (-not (Test-FmPrivateAcl $acl $user)) { throw 'Owner-private ACL was rejected' }
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $system, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
if (-not (Test-FmPrivateAcl $acl $user)) { throw 'Trusted SYSTEM access was rejected' }
Write-Output 'ok - native owner-private ACLs permit the current user and trusted system access'

$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $everyone, 'ReadAndExecute', 'None', 'None', 'Allow'))
if (Test-FmPrivateAcl $acl $user) { throw 'Everyone read access was accepted as private' }
Write-Output 'ok - broad read access is not accepted as a private ACL'

$acl = New-PrivateAcl
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $everyone, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'InheritOnly', 'Allow'))
if (Test-FmPrivateAcl $acl $user) { throw 'Broad inherited child access was accepted' }
Write-Output 'ok - broad child inheritance cannot expose newly created receipts'

$acl = New-PrivateAcl
$acl.SetOwner($system)
if (Test-FmPrivateAcl $acl $user) { throw 'A foreign owner was accepted' }
Write-Output 'ok - the object must belong to the current user'

$acl = New-PrivateAcl
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $user, 'Write', 'None', 'None', 'Deny'))
if (Test-FmPrivateAcl $acl $user) { throw 'An ambiguous deny ACL was accepted' }
Write-Output 'ok - deny rules do not produce a private writable success'
