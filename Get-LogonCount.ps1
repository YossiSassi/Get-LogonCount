# Get-LogonCount.ps1
# Queries the logonCount attribute from all domain controllers (RWDC + RODC) for all or specific user accounts (and optionally computer accounts), with additional statistics, and optional effective lastlogon date.
# version: 1.3.1
# comments to yossis@protonmail.com
# No dependencies — uses .NET DirectoryServices only.
#
# Quick Examples (see full help for more):
#   .\Get-LogonCount.ps1                                  # all user accounts
#   .\Get-LogonCount.ps1 -IncludeComputers                # users + computers
#   .\Get-LogonCount.ps1 -SamAccountName svc_backup       # specific account
#   .\Get-LogonCount.ps1 -SamAccountName "admin*"         # wildcard match
#   .\Get-LogonCount.ps1 -IncludeLastLogonDate            # include last logon date
#   .\Get-LogonCount.ps1 -ExportCsv                       # save report as CSV
#   .\Get-LogonCount.ps1 -Top 10                          # show only top 10 accounts
#   .\Get-LogonCount.ps1 -MinLogons 10                    # filter accounts with <10 logons
#   .\Get-LogonCount.ps1 -SortBy LogonsPerDay             # sort by per-day rate
#   .\Get-LogonCount.ps1 -IncludeLastLogonDate -StaleDays 180  # custom stale threshold (default: 90 days)

<#
.SYNOPSIS
    Queries the logonCount attribute from all domain controllers (RWDC + RODC)
    for user (and optionally computer) accounts, and produces per-account,
    per-DC, and domain-wide statistics.

.DESCRIPTION
    Get-LogonCount enumerates every domain controller in the current domain
    and queries each one directly for the logonCount attribute. Because
    logonCount is a non-replicated attribute that increments locally on the
    DC handling each authentication, querying each DC individually gives a
    more complete picture than relying on a single DC's value.

    The script also calculates account age (from whenCreated), the average
    logons per day, identifies the most/least active accounts, detects
    replication divergence between DCs, and optionally reports the most
    recent lastLogon timestamp across all DCs.

    Requires no PowerShell modules — uses only .NET System.DirectoryServices.
    Needs to run from a domain-joined machine with permission to read AD (any authenticated user).

.PARAMETER SamAccountName
    Limit the query to a specific account by samAccountName. Wildcards
    (e.g. "svc_*", "admin*") are supported and passed through to the LDAP
    filter. When a single non-wildcard account is matched, the domain-wide
    summary and Top N leaderboards are suppressed (they are not meaningful
    for a single account).

.PARAMETER IncludeComputers
    Include computer accounts in the query in addition to user accounts.
    Without this switch only user accounts are returned. Ignored when
    -SamAccountName is specified.

.PARAMETER IncludeLastLogonDate
    Also query the lastLogon attribute (FILETIME) from each DC and report
    the most recent value across all DCs as LastLogonDate (local time).
    Required for stale-account detection.

.PARAMETER ExportCsv
    Export three CSV files to the script directory:
      - LogonCount_Accounts_<timestamp>.csv  (per-account data)
      - LogonCount_DCs_<timestamp>.csv       (per-DC stats)
      - LogonCount_Summary_<timestamp>.csv   (domain-wide summary)
    The Accounts CSV reflects the same -Top / -MinLogons / -SortBy filters
    applied to the console output.

.PARAMETER Top
    Limit the per-account console table (and Accounts CSV) to the top N
    accounts after sorting. Default is 0 (show all). Useful in large
    domains. Note: this does NOT affect the Top 5 leaderboards in the
    domain summary, which are always 5.

.PARAMETER StaleDays
    Threshold in days for stale-account detection. Accounts whose most
    recent lastLogon is older than this are counted as stale. Default 90.
    Only applied when -IncludeLastLogonDate is also specified.

.PARAMETER MinLogons
    Filter out accounts with fewer than N total logons across all DCs.
    Default 0 (no filtering). Applied before -Top and -SortBy.

.PARAMETER SortBy
    Sort the per-account output by one of:
      Total           - total logonCount across all DCs (default, descending)
      LogonsPerDay    - logon rate per day of account age (descending)
      LastLogon       - most recent lastLogon date (descending; requires
                        -IncludeLastLogonDate, otherwise falls back to Total)
      WhenCreated     - account creation date (descending)
      SamAccountName  - account name (ascending)

.EXAMPLE
    .\Get-LogonCount.ps1
    Query all user accounts in the domain.

.EXAMPLE
    .\Get-LogonCount.ps1 -SamAccountName svc_backup -IncludeLastLogonDate
    Get full details for a single service account including effective last logon date.

.EXAMPLE
    .\Get-LogonCount.ps1 -IncludeLastLogonDate -StaleDays 180 -ExportCsv
    Full domain report with 180-day stale threshold, exported to CSV.

.EXAMPLE
    .\Get-LogonCount.ps1 -Top 10 -SortBy LogonsPerDay -MinLogons 5
    Show the 10 accounts with the highest logons-per-day rate, excluding
    accounts that have logged on fewer than 5 times.

.EXAMPLE
    .\Get-LogonCount.ps1 -IncludeComputers -SortBy WhenCreated
    Query both user and computer accounts, sorted by creation date.

.NOTES
    Author : yossis@protonmail.com
    Version: 1.3

    logonCount is non-replicated — values typically differ across DCs.
    A dash (-) in the per-DC columns means the account was not returned
    by that DC, which is common with RODCs that only replicate a subset
    of accounts via the Password Replication Policy.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SamAccountName,

    [switch]$IncludeComputers,

    [switch]$IncludeLastLogonDate,

    [switch]$ExportCsv,

    [int]$Top = 0,

    [int]$StaleDays = 90,

    [int]$MinLogons = 0,

    [ValidateSet('Total', 'LogonsPerDay', 'LastLogon', 'WhenCreated', 'SamAccountName')]
    [string]$SortBy = 'Total'
)

## Discover domain
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

## Discover all DCs (primaryGroupID 516 = RWDC, 521 = RODC)
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

## Build LDAP filter 
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

## Query each DC for logonCount 
# logonCount increments on the DC that processes the logon, then replicates.
# Due to replication latency and concurrent logons, values typically differ across DCs - that's expected and why we query each one.

$accountData = @{}      # samAccountName -> @{ DCName = logonCount; ... }
$whenCreatedData = @{}  # samAccountName -> [DateTime] whenCreated (replicated, same on all DCs)
$lastLogonData = @{}    # samAccountName -> [DateTime] most recent lastLogon across all DCs
$lastLogonPerDC = @{}   # dcName -> @{ samAccountName = [DateTime]; ... }

foreach ($dc in $domainControllers) {
    $dcName = $dc.Name
    Write-Host "  Querying $dcName..." -ForegroundColor Yellow -NoNewline

    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = [ADSI]"LDAP://$($dc.HostName)/$domainDN"
        $searcher.Filter = $ldapFilter
        $propsToLoad = @('samAccountName', 'logonCount', 'whenCreated')
        if ($IncludeLastLogonDate) { $propsToLoad += 'lastLogon' }
        $searcher.PropertiesToLoad.AddRange($propsToLoad)
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

            if (-not $whenCreatedData.ContainsKey($sam) -and $result.Properties['whencreated'].Count -gt 0) {
                $whenCreatedData[$sam] = [DateTime]$result.Properties['whencreated'][0]
            }

            if ($IncludeLastLogonDate -and $result.Properties['lastlogon'].Count -gt 0) {
                $fileTime = [long]$result.Properties['lastlogon'][0]
                if ($fileTime -gt 0) {
                    $logonDate = [DateTime]::FromFileTime($fileTime)
                    if (-not $lastLogonData.ContainsKey($sam) -or $logonDate -gt $lastLogonData[$sam]) {
                        $lastLogonData[$sam] = $logonDate
                    }
                    if (-not $lastLogonPerDC.ContainsKey($dcName)) {
                        $lastLogonPerDC[$dcName] = @{}
                    }
                    $lastLogonPerDC[$dcName][$sam] = $logonDate
                }
            }
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

## Build per-account output
# A dash (-) means the account was not returned by that DC (common with RODCs
# that only replicate a subset of accounts via the Password Replication Policy).

$output = foreach ($sam in $accountData.Keys | Sort-Object) {
    $props = [ordered]@{ SamAccountName = $sam }
    $total = 0
    $dcValues = @()
    $missingFromRODC = $false
    foreach ($dcName in $dcNames) {
        if ($accountData[$sam].ContainsKey($dcName)) {
            $val = $accountData[$sam][$dcName]
            $props[$dcName] = $val
            $total += $val
            $dcValues += $val
        }
        else {
            $props[$dcName] = '-'
            $dcType = ($domainControllers | Where-Object { $_.Name -eq $dcName }).Type
            if ($dcType -eq 'RODC') { $missingFromRODC = $true }
        }
    }
    $props['Total'] = $total
    # Replication divergence: max - min across DCs that returned the account
    if ($dcValues.Count -gt 1) {
        $props['ReplDivergence'] = ($dcValues | Measure-Object -Maximum).Maximum - ($dcValues | Measure-Object -Minimum).Minimum
    }
    else {
        $props['ReplDivergence'] = 0
    }
    $props['MissingFromRODC'] = $missingFromRODC
    if ($whenCreatedData.ContainsKey($sam)) {
        $created = $whenCreatedData[$sam]
        $props['WhenCreated'] = $created.ToString('yyyy-MM-dd HH:mm:ss')
        $ageDays = [math]::Max(1, [int]((Get-Date) - $created).TotalDays)
        $props['AccountAgeDays'] = $ageDays
        $props['LogonsPerDay'] = [math]::Round($total / $ageDays, 2)
    }
    else {
        $props['WhenCreated'] = $null
        $props['AccountAgeDays'] = $null
        $props['LogonsPerDay'] = $null
    }
    if ($IncludeLastLogonDate) {
        if ($lastLogonData.ContainsKey($sam)) {
            $props['LastLogonDate'] = $lastLogonData[$sam].ToString('yyyy-MM-dd HH:mm:ss')
        }
        else {
            $props['LastLogonDate'] = 'Never'
        }
    }
    [PSCustomObject]$props
}

# Apply -MinLogons filter
if ($MinLogons -gt 0) {
    $filteredOutput = $output | Where-Object { $_.Total -ge $MinLogons }
    Write-Host "  Filtered: $($filteredOutput.Count) of $($output.Count) accounts have >= $MinLogons logons" -ForegroundColor DarkGray
}
else {
    $filteredOutput = $output
}

# Apply -SortBy
$sortDescending = $true
$sortProperty = switch ($SortBy) {
    'Total'          { 'Total' }
    'LogonsPerDay'   { 'LogonsPerDay' }
    'LastLogon'      { 'LastLogonDate' }
    'WhenCreated'    { 'WhenCreated' }
    'SamAccountName' { $sortDescending = $false; 'SamAccountName' }
}
if ($SortBy -eq 'LastLogon' -and -not $IncludeLastLogonDate) {
    Write-Host '  [Warning] -SortBy LastLogon requires -IncludeLastLogonDate; falling back to Total' -ForegroundColor Yellow
    $sortProperty = 'Total'
}

$sortedOutput = $filteredOutput | Sort-Object -Property $sortProperty -Descending:$sortDescending

# Apply -Top
$displayOutput = if ($Top -gt 0) { $sortedOutput | Select-Object -First $Top } else { $sortedOutput }
if ($Top -gt 0) {
    Write-Host "  Showing top $Top accounts (sorted by $SortBy)" -ForegroundColor DarkGray
}

$displayOutput | Format-Table -AutoSize

## Domain-wide summary statistics
# Skip domain summary + Top N sections when a single specific account was queried
# (wildcards still show the summary since they may match multiple accounts)
$singleAccountQuery = $SamAccountName -and $SamAccountName -notmatch '\*' -and $output.Count -le 1

if (-not $singleAccountQuery) {
Write-Host '  Domain Summary:' -ForegroundColor Cyan
Write-Host "  $('-' * 56)" -ForegroundColor DarkGray

$activeAccounts = $output | Where-Object { $_.Total -gt 0 }
$neverAccounts  = $output | Where-Object { $_.Total -eq 0 }
$totalAccounts  = $output.Count
$activeCount    = ($activeAccounts | Measure-Object).Count
$neverCount     = ($neverAccounts  | Measure-Object).Count
$activePct      = if ($totalAccounts -gt 0) { [math]::Round(($activeCount / $totalAccounts) * 100, 1) } else { 0 }

# LogonsPerDay stats — only for accounts that have logged on at least once and have a valid age
$lpdValues = $activeAccounts | Where-Object { $null -ne $_.LogonsPerDay } | ForEach-Object { [double]$_.LogonsPerDay }
if ($lpdValues.Count -gt 0) {
    $avgLpd = [math]::Round(($lpdValues | Measure-Object -Average).Average, 2)
    $sortedLpd = $lpdValues | Sort-Object
    $mid = [math]::Floor($sortedLpd.Count / 2)
    if ($sortedLpd.Count % 2 -eq 0) {
        $medianLpd = [math]::Round((($sortedLpd[$mid - 1] + $sortedLpd[$mid]) / 2), 2)
    }
    else {
        $medianLpd = [math]::Round($sortedLpd[$mid], 2)
    }
}
else {
    $avgLpd = 0
    $medianLpd = 0
}

# Max / Min by total logons (min excludes 0/never)
$maxAccount = $activeAccounts | Sort-Object Total -Descending | Select-Object -First 1
$minAccount = $activeAccounts | Sort-Object Total | Select-Object -First 1

# Most active by LogonsPerDay
$mostActiveByLpd = $activeAccounts | Where-Object { $null -ne $_.LogonsPerDay } | Sort-Object LogonsPerDay -Descending | Select-Object -First 1

$summary = [ordered]@{
    'Total accounts'           = $totalAccounts
    'Activated (ever loggedOn)'       = "$activeCount ($activePct%)"
    'Never logged on'          = $neverCount
    'Average LogonsPerDay'     = $avgLpd
    'Median LogonsPerDay'      = $medianLpd
    'Max logons account'       = if ($maxAccount) { "$($maxAccount.SamAccountName) ($($maxAccount.Total))" } else { 'N/A' }
    'Min logons account'       = if ($minAccount) { "$($minAccount.SamAccountName) ($($minAccount.Total))" } else { 'N/A' }
    'Most active (per day)'    = if ($mostActiveByLpd) { "$($mostActiveByLpd.SamAccountName) ($($mostActiveByLpd.LogonsPerDay)/day)" } else { 'N/A' }
    'Missing from RODCs'       = ($output | Where-Object { $_.MissingFromRODC }).Count
    'Divergent accounts'       = ($output | Where-Object { $_.ReplDivergence -gt 0 }).Count
}

foreach ($key in $summary.Keys) {
    Write-Host ("    {0,-25} : {1}" -f $key, $summary[$key]) -ForegroundColor White
}
Write-Host ''

# Top 5 leaderboards
Write-Host '  Top 5 by Total Logons:' -ForegroundColor Cyan
$activeAccounts | Sort-Object Total -Descending | Select-Object -First 5 SamAccountName, Total, LogonsPerDay | Format-Table -AutoSize

Write-Host '  Top 5 by LogonsPerDay:' -ForegroundColor Cyan
$activeAccounts | Where-Object { $null -ne $_.LogonsPerDay } | Sort-Object LogonsPerDay -Descending | Select-Object -First 5 SamAccountName, Total, LogonsPerDay | Format-Table -AutoSize
} # end if (-not $singleAccountQuery)

# Stale accounts (only if -IncludeLastLogonDate)
if ($IncludeLastLogonDate) {
    $staleCutoff = (Get-Date).AddDays(-$StaleDays)
    $staleCount = ($activeAccounts | Where-Object {
            $_.LastLogonDate -and $_.LastLogonDate -ne 'Never' -and
            ([DateTime]::ParseExact($_.LastLogonDate, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) -lt $staleCutoff)
        } | Measure-Object).Count
    Write-Host "  Stale accounts (no logon in $StaleDays days): $staleCount" -ForegroundColor Yellow
    Write-Host ''
}

## Replication health
Write-Host '  Replication Health:' -ForegroundColor Cyan
Write-Host "  $('-' * 56)" -ForegroundColor DarkGray

$missingRodcCount = ($output | Where-Object { $_.MissingFromRODC }).Count
$divergentAccounts = $output | Where-Object { $_.ReplDivergence -gt 0 } | Sort-Object ReplDivergence -Descending

Write-Host "    Account(s) missing from one or more RODCs : $missingRodcCount" -ForegroundColor White
Write-Host "    Account(s) with logonCount divergence     : $($divergentAccounts.Count)" -ForegroundColor White

if ($divergentAccounts.Count -gt 0) {
    Write-Host ''
    Write-Host '  Top 5 accounts by replication divergence (max-min logonCount across DCs):' -ForegroundColor Cyan
    $divergentAccounts | Select-Object -First 5 SamAccountName, Total, ReplDivergence | Format-Table -AutoSize
}
else {
    Write-Host ''
}

## DC summary stats
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

    $dcObj = [ordered]@{
        DC          = $dcName
        Type        = $dcType
        Accounts    = $dcAccountCount
        TotalLogons = $dcTotal
    }
    if ($IncludeLastLogonDate -and $lastLogonPerDC.ContainsKey($dcName)) {
        $latestOnDC = ($lastLogonPerDC[$dcName].Values | Sort-Object -Descending | Select-Object -First 1)
        $dcObj['LatestLogon'] = $latestOnDC.ToString('yyyy-MM-dd HH:mm:ss')
    }
    elseif ($IncludeLastLogonDate) {
        $dcObj['LatestLogon'] = 'N/A'
    }
    [PSCustomObject]$dcObj
}

$dcStats | Format-Table -AutoSize

$grandTotal = ($dcStats | Measure-Object -Property TotalLogons -Sum).Sum
Write-Host "  Grand Total: $($grandTotal.ToString('N0')) logons across $($domainControllers | measure-object | select -expand count) DCs, $($accountData.Count) accounts" -ForegroundColor Green
Write-Host ''

# Export to CSV 
if ($ExportCsv) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvAccounts = Join-Path $scriptDir "LogonCount_Accounts_$timestamp.csv"
    $csvDcStats  = Join-Path $scriptDir "LogonCount_DCs_$timestamp.csv"
    
    $displayOutput | Export-Csv -Path $csvAccounts -NoTypeInformation -Encoding UTF8
    $dcStats | Export-Csv -Path $csvDcStats -NoTypeInformation -Encoding UTF8
    
    Write-Host "  CSV exported:" -ForegroundColor Cyan
    Write-Host "    Accounts: $csvAccounts" -ForegroundColor White
    Write-Host "    DC Stats: $csvDcStats" -ForegroundColor White
    
    if (-not $singleAccountQuery) {
        $csvSummary  = Join-Path $scriptDir "LogonCount_Summary_$timestamp.csv"
            $summary.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Metric = $_.Key; Value = $_.Value } } |
        Export-Csv -Path $csvSummary -NoTypeInformation -Encoding UTF8
        Write-Host "    Summary:  $csvSummary" -ForegroundColor White
    }

    Write-Host ''
}
