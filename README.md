# Get-LogonCount
#### Queries the logonCount attribute from all domain controllers (RWDC + RODC), for all user accounts (and optionally computer accounts), or a specific account.<br>
Helps to validate patterns (especially compared to WhenCreated, lastlogon etc.), resolve DC affinity issues etc.<br>
Max value for LogonCount attribute is 65,535. Usually indicates programatic/service accounts.<br>
No dependencies — uses .NET DirectoryServices only.

<img src="/screenshots/screenshot_getlogoncount.png" alt="Sample default run" style="width:60%; height:auto;"><br>

### Examples:
all user account
```
.\Get-LogonCount.ps1
```
users + computers
```
.\Get-LogonCount.ps1 -IncludeComputers
```
specific account
```
.\Get-LogonCount.ps1 -SamAccountName svc_backup
```
specific computer account (need the '$' at the end of the name)
```
.\Get-LogonCount.ps1 -SamAccountName srvsps01$
```
wildcard search
```
.\Get-LogonCount.ps1 -SamAccountName "admin*"
```
save report as CSV (all user accounts)
```
.\Get-LogonCount.ps1 -ExportCsv
```
