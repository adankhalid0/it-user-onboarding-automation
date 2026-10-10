<#
.SYNOPSIS
    Creates local Windows users and department groups from a CSV file.

.DESCRIPTION
    Reads a CSV file with the columns FirstName, LastName and Department, validates every
    row and creates one local user per valid row. Each user is added to a group named after
    the department. Everything the script creates gets the prefix 'demo-', so it is easy to
    find again and can be removed with Remove-DemoUsers.ps1.

    Use -WhatIf for a dry run that shows what would happen without changing anything.
    A real run needs an elevated (administrator) PowerShell.

.PARAMETER CsvPath
    Path to the CSV file. Defaults to data\users.csv in this repository.

.PARAMETER OutputDir
    Folder for the log file and the temporary passwords. Defaults to output\ (ignored by git).

.PARAMETER Prefix
    Prefix for all user and group names. Defaults to 'demo-'.

.EXAMPLE
    .\scripts\New-UserOnboarding.ps1 -WhatIf

.EXAMPLE
    .\scripts\New-UserOnboarding.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CsvPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\users.csv'),
    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output'),
    [string]$Prefix = 'demo-'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AllowedDepartments = @('IT', 'Sales', 'HR', 'Finance')
$MaxUsernameLength = 20   # Windows limit for local account names
$script:Rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$script:Results = New-Object System.Collections.Generic.List[object]
$script:LogFile = Join-Path $OutputDir ('onboarding_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # The log is written even during a dry run, so -WhatIf:$false is intentional.
    Add-Content -Path $script:LogFile -Value $line -WhatIf:$false
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Add-Result {
    param(
        [int]$Line,
        [string]$Username,
        [string]$Department,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Line       = $Line
        Username   = $Username
        Department = $Department
        Status     = $Status
        Detail     = $Detail
    })
    $level = 'INFO'
    if ($Status -eq 'Invalid') { $level = 'WARN' }
    if ($Status -eq 'Failed') { $level = 'ERROR' }
    Write-Log -Level $level -Message ('Line {0}: {1} {2} {3}' -f $Line, $Username, $Status, $Detail)
}

function ConvertTo-AsciiName {
    # Lowercase, replace Norwegian letters and strip everything that is not a-z or 0-9.
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    $t = $t.Replace([string][char]0x00E6, 'ae').Replace([string][char]0x00F8, 'o').Replace([string][char]0x00E5, 'a')
    $decomposed = $t.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return ($sb.ToString() -replace '[^a-z0-9]', '')
}

function Get-RandomIndex {
    # Returns a random integer from 0 to Max-1 using a cryptographic random number generator.
    param([int]$Max)
    $bytes = New-Object byte[] 4
    $script:Rng.GetBytes($bytes)
    return [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$Max)
}

function Get-TemporaryPassword {
    # 16 characters with at least one upper case, lower case, digit and symbol.
    # Look-alike characters (0, O, 1, l, I) are left out so it can be read out loud.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@')
    $all = -join $sets
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) {
        $chars.Add($set[(Get-RandomIndex $set.Length)])
    }
    while ($chars.Count -lt 16) {
        $chars.Add($all[(Get-RandomIndex $all.Length)])
    }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-RandomIndex ($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }
    return -join $chars
}

# --- Preconditions -------------------------------------------------------------------------

if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -WhatIf:$false | Out-Null
}

if (-not $WhatIfPreference -and -not (Test-IsAdmin)) {
    throw 'Run PowerShell as Administrator, or use -WhatIf for a dry run.'
}

if (-not (Test-Path -Path $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0) {
    throw "The CSV file has no data rows: $CsvPath"
}
foreach ($column in @('FirstName', 'LastName', 'Department')) {
    if ($rows[0].PSObject.Properties.Name -notcontains $column) {
        throw "The CSV file is missing the column '$column'."
    }
}

Write-Log ('Start. Source: {0}, rows: {1}, dry run: {2}' -f $CsvPath, $rows.Count, [bool]$WhatIfPreference)

# --- Process rows --------------------------------------------------------------------------

$credentials = New-Object System.Collections.Generic.List[object]
$seen = @{}
$groupsHandled = @{}
$lineNumber = 1   # the header is line 1

foreach ($row in $rows) {
    $lineNumber++
    $first = ([string]$row.FirstName).Trim()
    $last = ([string]$row.LastName).Trim()
    $departmentInput = ([string]$row.Department).Trim()

    # 1. Validate
    $f = ConvertTo-AsciiName $first
    $l = ConvertTo-AsciiName $last
    if (-not $f -or -not $l) {
        Add-Result -Line $lineNumber -Username '-' -Department $departmentInput -Status 'Invalid' -Detail 'Missing first or last name'
        continue
    }

    $department = $AllowedDepartments | Where-Object { $_ -eq $departmentInput }
    if (-not $department) {
        Add-Result -Line $lineNumber -Username '-' -Department $departmentInput -Status 'Invalid' -Detail ('Unknown department (allowed: {0})' -f ($AllowedDepartments -join ', '))
        continue
    }

    $username = '{0}{1}{2}' -f $Prefix, $f.Substring(0, 1), $l
    if ($username.Length -gt $MaxUsernameLength) {
        Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Invalid' -Detail "Username is longer than $MaxUsernameLength characters"
        continue
    }

    if ($seen.ContainsKey($username)) {
        Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Skipped' -Detail 'Duplicate in CSV'
        continue
    }
    $seen[$username] = $true

    if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Skipped' -Detail 'User already exists'
        continue
    }

    # 2. Make sure the department group exists
    $groupName = '{0}{1}' -f $Prefix, $department
    if (-not $groupsHandled.ContainsKey($groupName)) {
        $groupsHandled[$groupName] = $true
        if (-not (Get-LocalGroup -Name $groupName -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess($groupName, 'Create local group')) {
                New-LocalGroup -Name $groupName -Description "Demo group for the $department department" | Out-Null
                Write-Log "Created group $groupName"
            }
        }
    }

    # 3. Create the user and add it to the group
    $fullName = '{0} {1}' -f $first, $last
    if ($PSCmdlet.ShouldProcess($username, "Create local user ($fullName, $department)")) {
        try {
            $plain = Get-TemporaryPassword
            # A new local account needs a SecureString. The password is generated at runtime and is never stored in the repository.
            $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $description = 'Onboarded {0} ({1})' -f (Get-Date -Format 'yyyy-MM-dd'), $department
            New-LocalUser -Name $username -FullName $fullName -Description $description -Password $secure -AccountNeverExpires | Out-Null

            # Force a password change at first logon.
            & net.exe user $username /logonpasswordchg:yes | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "net user returned exit code $LASTEXITCODE"
            }

            Add-LocalGroupMember -Group $groupName -Member $username
            $credentials.Add([pscustomobject]@{ Username = $username; TemporaryPassword = $plain })
            Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Created' -Detail ('Group: ' + $groupName)
        }
        catch {
            Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Failed' -Detail $_.Exception.Message
        }
    }
    else {
        Add-Result -Line $lineNumber -Username $username -Department $department -Status 'Would create' -Detail ('Group: ' + $groupName)
    }
}

# --- Summary -------------------------------------------------------------------------------

Write-Host ''
$script:Results | Format-Table Line, Username, Department, Status, Detail -AutoSize

$summary = $script:Results | Group-Object Status | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
Write-Log ('Done. ' + ($summary -join ', '))
Write-Host ('Log file: ' + $script:LogFile)

if ($credentials.Count -gt 0) {
    $credFile = Join-Path $OutputDir ('temporary_passwords_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $credentials | Export-Csv -Path $credFile -NoTypeInformation -Encoding UTF8
    Write-Host ('Temporary passwords: ' + $credFile) -ForegroundColor Yellow
    Write-Host 'Hand the passwords out securely and delete the file. It is ignored by git.' -ForegroundColor Yellow
}

if (@($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
    exit 1
}
