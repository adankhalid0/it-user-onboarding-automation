<#
.SYNOPSIS
    Reports local user accounts that have not been used for a number of days.

.DESCRIPTION
    Lists local accounts whose name starts with the given prefix and marks each one as
    Active, Inactive or New. Accounts that have never logged in are judged by when the
    password was last set. The report is shown in the console and saved as a CSV file.

    With -DisableInactive the inactive accounts are disabled. Use -WhatIf to see which
    accounts would be disabled first. Disabling needs an elevated PowerShell.

.PARAMETER Days
    Accounts with no activity for more than this many days are inactive. Default 30.
    Use -Days 0 to treat every account that has not logged in since it was created as inactive.

.PARAMETER Prefix
    Only accounts whose name starts with this prefix are included. Default 'demo-'.
    Use an empty string to list all local accounts (not allowed together with -DisableInactive).

.EXAMPLE
    .\scripts\Get-InactiveAccounts.ps1 -Days 0

.EXAMPLE
    .\scripts\Get-InactiveAccounts.ps1 -Days 0 -DisableInactive -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$Days = 30,
    [string]$Prefix = 'demo-',
    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output'),
    [switch]$DisableInactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DisableInactive -and $Prefix.Length -lt 3) {
    throw '-DisableInactive requires a prefix of at least 3 characters, to protect real accounts.'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($DisableInactive -and -not $WhatIfPreference -and -not $isAdmin) {
    throw 'Run PowerShell as Administrator to disable accounts, or add -WhatIf.'
}

if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -WhatIf:$false | Out-Null
}

$now = Get-Date
$cutoff = $now.AddDays(-$Days)
$users = @(Get-LocalUser | Where-Object { $_.Name -like "$Prefix*" })

$report = @(foreach ($user in $users) {
    $lastLogon = $user.LastLogon
    $passwordSet = $user.PasswordLastSet

    # Local accounts have no creation date. For an account that has never logged in, use the
    # date the password was set. When a password change is forced at first logon, Windows leaves
    # that date empty, so fall back to the onboarding date that New-UserOnboarding.ps1 writes
    # in the account description ("Onboarded yyyy-MM-dd (Department)").
    $created = $passwordSet
    if ($null -eq $created -and $user.Description -match 'Onboarded (\d{4}-\d{2}-\d{2})') {
        $created = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }

    if ($null -ne $lastLogon) {
        $reference = $lastLogon
        if ($lastLogon -lt $cutoff) { $status = 'Inactive' } else { $status = 'Active' }
    }
    else {
        $reference = $created
        if ($null -eq $created) {
            $status = 'Unknown (never logged in)'
        }
        elseif ($created -lt $cutoff) {
            $status = 'Inactive (never logged in)'
        }
        else {
            $status = 'New (never logged in)'
        }
    }

    $daysSince = $null
    if ($null -ne $reference) {
        $daysSince = [int]($now - $reference).TotalDays
    }

    [pscustomobject]@{
        Name              = $user.Name
        FullName          = $user.FullName
        Enabled           = $user.Enabled
        LastLogon         = $lastLogon
        PasswordLastSet   = $passwordSet
        Created           = $created
        DaysSinceActivity = $daysSince
        Status            = $status
    }
})

Write-Host ('Accounts matching "{0}*": {1}. Inactive means no activity for more than {2} day(s).' -f $Prefix, $report.Count, $Days)
Write-Host ''
if ($report.Count -gt 0) {
    $report | Format-Table Name, FullName, Enabled, LastLogon, Created, DaysSinceActivity, Status -AutoSize

    $file = Join-Path $OutputDir ('inactive_report_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $report | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host ('Report saved: ' + $file)
}

if ($DisableInactive) {
    $toDisable = @($report | Where-Object { $_.Status -like 'Inactive*' -and $_.Enabled })
    foreach ($account in $toDisable) {
        if ($PSCmdlet.ShouldProcess($account.Name, 'Disable local user')) {
            Disable-LocalUser -Name $account.Name
            Write-Host ('Disabled: ' + $account.Name)
        }
    }
    if ($toDisable.Count -eq 0) {
        Write-Host 'No enabled inactive accounts to disable.'
    }
}
