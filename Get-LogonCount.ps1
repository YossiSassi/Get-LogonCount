# Get-LogonCount.ps1
# comments to yossis@protonmail.com
# Queries the logonCount attribute from all domain controllers (RWDC + RODC)
# for user accounts (and optionally computer accounts).
# No dependencies — uses .NET DirectoryServices only.
#
# Examples:
#   .\Get-LogonCount.ps1                                  # all user accounts
#   .\Get-LogonCount.ps1 -IncludeComputers                # users + computers
#   .\Get-LogonCount.ps1 -SamAccountName svc_backup       # specific account
#   .\Get-LogonCount.ps1 -SamAccountName "admin*"         # wildcard match
#   .\Get-LogonCount.ps1 -ExportCsv                       # save report as CSV

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SamAccountName,

    [switch]$IncludeComputers,

    [switch]$ExportCsv
)

# ── Discover domain ──────────────────────────────────────────────────────────
try {
    $rootDSE = [ADSI]'LDAP://RootDSE'
    $domainDN = $rootDSE.defaultNamingContext.Value
    $domainName = ($domainDN -replace ',DC=', '.' -replace '^DC=', '').ToUpper()
}
catch {
    Write-Host '  [Error] Cannot contact domain. Ensure this machine is domain-joined.' -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "  Get-LogonCount   Domain: $domainName" -ForegroundColor Green
Write-Host ''

# ── Discover all DCs (primaryGroupID 516 = RWDC, 521 = RODC) ────────────────
Write-Host '  Discovering domain controllers...' -ForegroundColor Cyan

$dcSearcher = New-Object System.DirectoryServices.DirectorySearcher
$dcSearcher.SearchRoot = [ADSI]"LDAP://$domainDN"
$dcSearcher.Filter = '(&(objectClass=computer)(|(primaryGroupID=516)(primaryGroupID=521)))'
$dcSearcher.PropertiesToLoad.AddRange(@('dNSHostName', 'name', 'primaryGroupID'))
$dcSearcher.PageSize = 1000

try {
    $dcEntries = $dcSearcher.FindAll()
}
catch {
    Write-Host "  [Error] Failed to enumerate DCs: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$domainControllers = @()
foreach ($entry in $dcEntries) {
    $domainControllers += [PSCustomObject]@{
        Name     = [string]$entry.Properties['name'][0]
        HostName = [string]$entry.Properties['dnshostname'][0]
        Type     = if ([int]$entry.Properties['primarygroupid'][0] -eq 521) { 'RODC' } else { 'RWDC' }
    }
}
$dcEntries.Dispose()

if ($domainControllers.Count -eq 0) {
    Write-Host '  [Error] No domain controllers found.' -ForegroundColor Red
    exit 1
}

$domainControllers = $domainControllers | Sort-Object Name
$dcNames = $domainControllers | ForEach-Object { $_.Name }

foreach ($dc in $domainControllers) {
    $label = $dc.Type
    $color = if ($dc.Type -eq 'RODC') { 'DarkYellow' } else { 'White' }
    Write-Host "    $($dc.Name) ($label) - $($dc.HostName)" -ForegroundColor $color
}
Write-Host ''

# ── Build LDAP filter ────────────────────────────────────────────────────────
if ($SamAccountName) {
    # Specific account lookup — works with wildcards (e.g. svc_*)
    $ldapFilter = "(samAccountName=$SamAccountName)"
    Write-Host "  Filter: samAccountName=$SamAccountName" -ForegroundColor White
}
elseif ($IncludeComputers) {
    $ldapFilter = '(|(objectCategory=person)(objectCategory=computer))'
    Write-Host '  Filter: all user + computer accounts' -ForegroundColor White
}
else {
    $ldapFilter = '(&(objectCategory=person)(objectClass=user))'
    Write-Host '  Filter: all user accounts (use -IncludeComputers for computer accounts)' -ForegroundColor White
}
Write-Host ''

# ── Query each DC for logonCount ─────────────────────────────────────────────
# logonCount increments on the DC that processes the logon, then replicates.
# Due to replication latency and concurrent logons, values typically differ
# across DCs — that's expected and why we query each one.

$accountData = @{}   # samAccountName -> @{ DCName = logonCount; ... }

foreach ($dc in $domainControllers) {
    $dcName = $dc.Name
    Write-Host "  Querying $dcName..." -ForegroundColor Yellow -NoNewline

    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = [ADSI]"LDAP://$($dc.HostName)/$domainDN"
        $searcher.Filter = $ldapFilter
        $searcher.PropertiesToLoad.AddRange(@('samAccountName', 'logonCount'))
        $searcher.PageSize = 1000
        $searcher.SizeLimit = 0

        $results = $searcher.FindAll()
        $queryCount = 0

        foreach ($result in $results) {
            $sam = [string]$result.Properties['samaccountname'][0]
            $logonCount = 0
            if ($result.Properties['logoncount'].Count -gt 0) {
                $logonCount = [int]$result.Properties['logoncount'][0]
            }

            if (-not $accountData.ContainsKey($sam)) {
                $accountData[$sam] = @{}
            }
            $accountData[$sam][$dcName] = $logonCount
            $queryCount++
        }
        $results.Dispose()

        Write-Host " $queryCount accounts" -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

Write-Host ''

if ($accountData.Count -eq 0) {
    Write-Host '  No accounts found matching the filter.' -ForegroundColor Yellow
    exit 0
}

# ── Build per-account output ─────────────────────────────────────────────────
# A dash (-) means the account was not returned by that DC (common with RODCs
# that only replicate a subset of accounts via the Password Replication Policy).

$output = foreach ($sam in $accountData.Keys | Sort-Object) {
    $props = [ordered]@{ SamAccountName = $sam }
    $total = 0
    foreach ($dcName in $dcNames) {
        if ($accountData[$sam].ContainsKey($dcName)) {
            $val = $accountData[$sam][$dcName]
            $props[$dcName] = $val
            $total += $val
        }
        else {
            $props[$dcName] = '-'
        }
    }
    $props['Total'] = $total
    [PSCustomObject]$props
}

$output | Sort-Object Total -Descending | Format-Table -AutoSize

# ── DC summary stats ─────────────────────────────────────────────────────────
Write-Host '  Logon Statistics per DC:' -ForegroundColor Cyan
Write-Host "  $('-' * 56)" -ForegroundColor DarkGray

$dcStats = foreach ($dcName in $dcNames) {
    $dcType = ($domainControllers | Where-Object { $_.Name -eq $dcName }).Type
    $dcTotal = 0
    $dcAccountCount = 0

    foreach ($sam in $accountData.Keys) {
        if ($accountData[$sam].ContainsKey($dcName)) {
            $dcTotal += $accountData[$sam][$dcName]
            $dcAccountCount++
        }
    }

    [PSCustomObject]@{
        DC          = $dcName
        Type        = $dcType
        Accounts    = $dcAccountCount
        TotalLogons = $dcTotal
    }
}

$dcStats | Format-Table -AutoSize

$grandTotal = ($dcStats | Measure-Object -Property TotalLogons -Sum).Sum
Write-Host "  Grand Total: $($grandTotal.ToString('N0')) logons across $($domainControllers | measure-object | select -expand count) DCs, $($accountData.Count) accounts" -ForegroundColor Green
Write-Host ''

# ── Export to CSV ────────────────────────────────────────────────────────────
if ($ExportCsv) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvAccounts = Join-Path $scriptDir "LogonCount_Accounts_$timestamp.csv"
    $csvDcStats  = Join-Path $scriptDir "LogonCount_DCs_$timestamp.csv"

    $output | Sort-Object Total -Descending | Export-Csv -Path $csvAccounts -NoTypeInformation -Encoding UTF8
    $dcStats | Export-Csv -Path $csvDcStats -NoTypeInformation -Encoding UTF8

    Write-Host "  CSV exported:" -ForegroundColor Cyan
    Write-Host "    Accounts: $csvAccounts" -ForegroundColor White
    Write-Host "    DC Stats: $csvDcStats" -ForegroundColor White
    Write-Host ''
}
