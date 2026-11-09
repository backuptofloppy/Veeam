# Veeam Entra ID Backup Report

A PowerShell script that connects to a Veeam Backup & Replication (VBR) server and builds an HTML report on Microsoft Entra ID protection: tenant backup jobs, log backup jobs, and the contents of each restore point.

The report is grouped by tenant, so each protected tenant gets its own section with its jobs and restore points.

## What's in the report

For each tenant:

**Jobs**
One table covering both tenant backup and log backup jobs, with the job type identified on each row.

| Column | Description |
|---|---|
| Job Type | Tenant Backup or Log Backup |
| Job Name / Description | From the job configuration |
| Scheduled | Whether the job schedule is enabled |
| Retention | Number plus Days, Weeks, Months or Years, as configured |
| Encrypted | Whether backup encryption is enabled |
| Repository | Primary repository |
| Secondary Repository | Secondary copy target, if configured (log backups) |
| Restore Points | Restore points currently retained |
| Oldest Point | Oldest retained restore point |
| Last Run | Result of the most recent job run |
| Status | OK, Stale, No restore points or Orphaned backup |

**Tenant Backup Restore Points**
One row per restore point, with a count of each Entra ID object type in that point: users, groups, roles, administrative units, applications, Conditional Access policies, devices, organizational contacts, device configuration, role assignments, OAuth2 permission grants, and a total.

**Log Restore Point Backups**
One row per log backup restore point, with the number of audit log files and sign-in log files added in that point, the total, and the data size reported by the job.

## Requirements

- Veeam Backup & Replication **v13** (the default connection port is 443). VBR 12.1 or later works with `-Port 9392`.
- The **Veeam Backup & Replication console** installed on the machine running the script. It provides the `Veeam.Backup.PowerShell` module. The console build must match the server build.
- **PowerShell 7** or Windows PowerShell 5.1.
- A VBR account with permission to view jobs and perform restores. Item counts open read-only restore sessions, so a view-only role isn't enough.
- Log backup jobs require Veeam Universal License or Enterprise Plus.

Works against both Windows-based VBR servers and the Veeam Software Appliance (VSA).

## Quick start

```powershell
# Veeam Software Appliance or any server that needs a VBR login
.\Get-VBREntraIDBackupReport.ps1 -Server vbr01.corp.local -Login -ForceAcceptTlsCertificate

# Windows-based VBR server, signing in with your Windows identity
.\Get-VBREntraIDBackupReport.ps1 -Server vbr01.corp.local

# Tenant backups only
.\Get-VBREntraIDBackupReport.ps1 -Server vbr01.corp.local -Login -ReportType Tenant

# Log backups only, saved to a specific file
.\Get-VBREntraIDBackupReport.ps1 -Server vbr01.corp.local -Login -ReportType Logs -HtmlPath C:\Reports\entra-logs.html
```

If you don't pass `-HtmlPath`, the report is saved in the current folder:

| -ReportType | File name |
|---|---|
| Both (default) | `Entra ID Report - Tenant and Log - yyyy-MM-dd HHmm.html` |
| Tenant | `Entra ID Report - Tenant - yyyy-MM-dd HHmm.html` |
| Logs | `Entra ID Report - Log - yyyy-MM-dd HHmm.html` |

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Server` | `localhost` | VBR server name or IP address |
| `-Port` | `443` | Connection port. Use `9392` for VBR 12.x |
| `-Login` | off | Prompts for a VBR user name and password. Without it, your Windows identity is used |
| `-ForceAcceptTlsCertificate` | off | Accepts the server's TLS certificate, such as the VSA's self-signed certificate |
| `-ReportType` | `Both` | `Both`, `Tenant` or `Logs` |
| `-HtmlPath` | auto | Path for the HTML report. See the naming table above |
| `-StaleHours` | `24` | Flags a job as Stale if its newest restore point is older than this |
| `-EntraRepositoryLabel` | `Microsoft Entra ID Repository (PostgreSQL)` | Name shown for the built-in Entra ID repository (see Notes) |

## Signing in

- **Windows-based VBR:** run without `-Login` to use your Windows identity. Your account, or a group it belongs to, must be in **Users and Roles** on the server.
- **Veeam Software Appliance:** Windows identity sign-in isn't supported, so use `-Login`. If you forget, the script detects the error and prompts for credentials.
- **MFA:** accounts with MFA enabled can't sign in from PowerShell. Use a VBR account flagged as a service account.
- If you're already connected (for example, running from the VBR console's PowerShell window), the existing session is reused.

## How the numbers are gathered

Veeam doesn't expose every figure in this report through a single supported cmdlet, so the script combines several sources.

**Tenant object counts** (users, groups, roles and so on)
`Get-VBREntraIDTenantItem` lists every item a backup has ever captured, not what's in a given restore point. To get per-point counts, the script opens a read-only tenant restore session and runs `Validate-VBREntraIDTenantItem` against each restore point. That returns the items missing from that point, and the count is total minus missing. Nothing is restored.

**Role assignments and OAuth2 permission grants**
These aren't standalone item types in Veeam PowerShell. The script reads them from the job session log line for each run (`Role Assignment collected: X of Y`).

**Log file counts**
The script opens a read-only file-level browse session on each log backup (`Start-VBREntraIDLogsBackupFLRSession`) and lists the files folder by folder. Veeam stores one file per log type per hour, so each file is assigned to the first restore point that finished after its hour window closed.

## Notes and limitations

- **Restore sessions appear in history.** Item counts and log file counts each open a read-only session. These show up in VBR session history and the audit log. 
- **Log counts are hours, not entries.** A count of 24 audit log files means 24 hours of audit logs, not 24 log entries. Counting individual entries would require restoring and parsing the files.
- **Sign-in logs need Entra ID P1 or P2.** On tenants without that license, Veeam skips sign-in logs and the report shows `0 - Skipped (license)`.
- **Repository name for tenant backups.** Tenant backups are stored in a PostgreSQL-based Entra ID repository that PowerShell can't query by name, so the report shows `-EntraRepositoryLabel` instead.
- **Session history retention.** If a job session has been purged from VBR history, the role assignment and OAuth2 columns show N/A for that restore point.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Failed to connect ... timed out` | Wrong port. v13 uses 443, v12 uses 9392 |
| `InternalServerError` when connecting | Windows identity rejected, or the console build doesn't match the server. Try `-Login` |
| `grant type value is not supported` | The server doesn't accept Windows identity sign-in (typical on the VSA). Use `-Login` |
| Object counts show N/A | A restore session couldn't be opened, often because one from an earlier run is still open. Close it in the console under History > Restore |
| Log file counts show a status instead of a number | The browse session failed. The console warning and the note in the report give the reason |
| Role assignment or OAuth2 columns show N/A | The job session has aged out of history, or the VBR build or tenant license doesn't protect those types |

Run with `-Verbose` for detailed diagnostics, including session matching and raw session log lines.

## Disclaimer

This script is provided as-is, without warranty or official Veeam support. It reads configuration and backup metadata and opens read-only restore and browse sessions, but makes no changes to jobs or backups. Test it in a lab before using it in production.
