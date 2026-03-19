# Get-LogonCount
Queries the logonCount attribute from all domain controllers (RWDC + RODC), for user accounts (and optionally computer accounts).<br>
No dependencies — uses .NET DirectoryServices only.<br>
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
wildcard search
```
.\Get-LogonCount.ps1 -SamAccountName "admin*"
```
save report as CSV (all user accounts)
```
.\Get-LogonCount.ps1 -ExportCsv
```
