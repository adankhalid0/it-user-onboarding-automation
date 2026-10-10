<#
.SYNOPSIS
    Removes the demo users and groups created by New-UserOnboarding.ps1.

.DESCRIPTION
    Removes all local users and groups whose name starts with the prefix (default 'demo-').
    The script asks for confirmation for each object unless -Force is used. Use -WhatIf to see
    what would be removed. A real run needs an elevated (administrator) PowerShell.

.PARAMETER Prefix
    Prefix of the objects to remove. Must be at least 5 characters, so the script cannot
    be pointed at real accounts by accident.

.EXAMPLE
    .\scripts\Remove-DemoUsers.ps1 -WhatIf

.EXAMPLE
    .\scripts\Remove-DemoUsers.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Prefix = 'demo-',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Prefix.Length -lt 5) {
    throw 'The prefix must be at least 5 characters long.'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $WhatIfPreference -and -not $isAdmin) {
    throw 'Run PowerShell as Administrator, or use -WhatIf to see what would be removed.'
}

if ($Force) {
    $ConfirmPreference = 'None'
}

$users = @(Get-LocalUser | Where-Object { $_.Name -like "$Prefix*" })
$groups = @(Get-LocalGroup | Where-Object { $_.Name -like "$Prefix*" })

Write-Host ('Found {0} user(s) and {1} group(s) with the prefix "{2}".' -f $users.Count, $groups.Count, $Prefix)

foreach ($user in $users) {
    if ($PSCmdlet.ShouldProcess($user.Name, 'Remove local user')) {
        Remove-LocalUser -Name $user.Name
        Write-Host ('Removed user: ' + $user.Name)
    }
}

foreach ($group in $groups) {
    if ($PSCmdlet.ShouldProcess($group.Name, 'Remove local group')) {
        Remove-LocalGroup -Name $group.Name
        Write-Host ('Removed group: ' + $group.Name)
    }
}

if ($users.Count -eq 0 -and $groups.Count -eq 0) {
    Write-Host 'Nothing to remove.'
}
