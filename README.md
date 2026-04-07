# Get-LogonCount
#### Queries the logonCount attribute from all domain controllers (RWDC + RODC) for user (and optionally computer) accounts, and produces per-account, per-DC, and domain-wide statistics.<br>
Get-LogonCount enumerates every domain controller in the current domain and queries each one directly for the logonCount attribute. Because logonCount is a non-replicated attribute that increments locally on the DC handling each authentication, querying each DC individually gives a more complete picture than relying on a single DC's value.<br>
The script also calculates account age (from whenCreated), the average logons per day, identifies the most/least active accounts, detects replication divergence between DCs, and optionally reports the most recent lastLogon timestamp across all DCs.<br><br>
Requires no PowerShell modules — uses only .NET System.DirectoryServices.<br>
Needs to run from a domain-joined machine with permission to read AD (any authenticated user).<br>

### Parameters:
#### SamAccountName
Limit the query to a specific account by samAccountName.<br>
Wildcards (e.g. "svc_*", "admin*") are supported and passed through to the LDAP filter.<br>
When a single non-wildcard account is matched, the domain-wide summary and Top N leaderboards are suppressed (they are not meaningful for a single account).

#### IncludeComputers
Include computer accounts in the query in addition to user accounts.<br>
Without this switch only user accounts are returned. Ignored when -SamAccountName is specified.

#### IncludeLastLogonDate
Also query the lastLogon attribute (FILETIME) from each DC and report the most recent value across all DCs as LastLogonDate (local time).<br>
Required for stale-account detection.

#### ExportCsv
Export three CSV files to the script directory:<br>
- LogonCount_Accounts_<timestamp>.csv  (per-account data)<br>
- LogonCount_DCs_<timestamp>.csv       (per-DC stats)<br>
- LogonCount_Summary_<timestamp>.csv   (domain-wide summary)<br>
The Accounts CSV reflects the same -Top / -MinLogons / -SortBy filters applied to the console output.

#### Top
Limit the per-account console table (and Accounts CSV) to the top N accounts after sorting.<br>
Default is 0 (show all). Useful in large domains.<br>
Note: this does NOT affect the Top 5 leaderboards in the domain summary, which are always 5.

#### StaleDays
Threshold in days for stale-account detection. Accounts whose most recent lastLogon is older than this are counted as stale.<br>
Default is 90.<br>
Only applied when -IncludeLastLogonDate is also specified.

#### MinLogons
Filter out accounts with fewer than N total logons across all DCs.<br>
Default 0 (no filtering). Applied before -Top and -SortBy.

#### SortBy
Sort the per-account output by one of:<br>
Total           - total logonCount across all DCs (default, descending)<br>
LogonsPerDay    - logon rate per day of account age (descending)<br>
LastLogon       - most recent lastLogon date (descending; requires -IncludeLastLogonDate, otherwise falls back to Total)<br>
WhenCreated     - account creation date (descending)<br>
SamAccountName  - account name (ascending)<br>

### Examples:
Query all user accounts in the domain.<br>
```
.\Get-LogonCount.ps1
```
<img src="/screenshots/screenshot_getlogoncount.png" alt="Sample default run" style="width:90%; height:auto;"><br>

Get full details for a single service account including effective last logon date.<br>
```
.\Get-LogonCount.ps1 -SamAccountName svc_backup -IncludeLastLogonDate
```

Full domain report with 180-day stale threshold, exported to CSV.<br>
```
.\Get-LogonCount.ps1 -IncludeLastLogonDate -StaleDays 180 -ExportCsv
```

Show the 10 accounts with the highest logons-per-day rate, excluding accounts that have logged on fewer than 5 times.<br>
```
.\Get-LogonCount.ps1 -Top 10 -SortBy LogonsPerDay -MinLogons 5
```

Query both user and computer accounts, sorted by creation date.<br>
```
.\Get-LogonCount.ps1 -IncludeComputers -SortBy WhenCreated
```

Query all users & computers, including their last effective logon time, and export to CSV
```
.\Get-LogonCount.ps1 -IncludeComputers -IncludeLastLogonDate -ExportCSV
```
<img src="/screenshots/screenshot_getlogoncountandlastlogondate.png" alt="Sample run with computers and lastlogon date" style="width:110%; height:auto;"><br>
#### Sample statistics summary

<img src="/screenshots/dcstats.png" alt="epilogue of console output - dc statistics" style="width:110%; height:auto;"><br>
