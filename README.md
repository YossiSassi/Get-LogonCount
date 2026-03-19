# Get-LogonCount
Queries the logonCount attribute from all domain controllers (RWDC + RODC), for user accounts (and optionally computer accounts).<br>
No dependencies — uses .NET DirectoryServices only.<br>
#### Note: max value for LogonCount attribute is 65,535. Usually indicates programatic/service accounts.
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
