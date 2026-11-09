 <#
.SYNOPSIS
    Reports on all Microsoft Entra ID tenant backups on a Veeam Backup & Replication server.

.DESCRIPTION
    Connects to a VBR server and collects, per Entra ID tenant backup job:
      - Job name, description, schedule state, retention
      - Protected tenant (name, Azure tenant ID, region)
      - Encryption state
      - Backup repository
      - Restore point count and oldest restore point
      - Status (OK / Stale / No restore points / Orphaned)
    Also produces a detail section with one row per restore point, including a
    count of each Entra ID object type (users, groups, roles, admin units,
    applications, Conditional Access policies, and any other types the
    installed module supports) present in that restore point.

    How item counts work:
      Get-VBREntraIDTenantItem returns every item a backup has ever captured,
      not what is in a given restore point. To get per-point counts, the script
      opens a read-only tenant restore session per backup and runs
      Validate-VBREntraIDTenantItem against each restore point, which returns
      the items whose data is NOT in that point. Count = total - missing.
      The session is closed gracefully when done. Nothing is restored.
      Restore sessions appear in VBR session history and the audit log.

    Role assignments and OAuth2 permission grants:
      These aren't standalone item types in Get-VBREntraIDTenantItem (Veeam
      protects them as properties of users and service principals), so they
      can't be counted the same way. Instead, the script reads the backup job
      session log for the run that created each restore point and pulls the
      "<type> collected: X of Y" lines. If the session has aged out of VBR
      session history, those columns show N/A.

    Entra ID log backups:
      The report also covers Entra ID log backup jobs: job settings, primary
      and secondary repositories, retention, and one row per restore point
      (each successful job run still inside the retention window).
      Veeam stores Entra ID logs as files and its session log only reports a
      file count and size, not a per-log-type entry count. Each restore point
      row therefore shows files and data backed up, plus a status for each log
      type (Audit, Sign-in) read from the session log, e.g. "Skipped (license)"
      when the tenant isn't licensed for sign-in log backup.

      Audit and sign-in log file counts come from a read-only file-level
      browse session on each log backup (Start-VBREntraIDLogsBackupFLRSession).
      Veeam stores one file per log type per hour, so a count of 24 means 24
      hours of logs, not 24 log entries. Each file is assigned to the first
      restore point that finished after its hour window closed. Veeam does not
      expose per-file sizes, so Data Size stays a job-level total.
      The browse session appears in VBR session history.

    Use -ReportType to limit the report to tenant backups or log backups.
    Output is an HTML report (see -HtmlPath).

.PARAMETER Server
    VBR server name or IP. Defaults to localhost.

.PARAMETER Port
    VBR server port. Defaults to 443 (VBR v13 / Veeam Software Appliance).
    Use 9392 for VBR 12.x on Windows.

.PARAMETER Login
    Prompts for the VBR user name and password when connecting. If omitted,
    the current Windows identity is used. Required for the Veeam Software
    Appliance (use the appliance's VBR user).

.PARAMETER ForceAcceptTlsCertificate
    Accepts the backup server's TLS certificate (needed for the default
    self-signed certificate on the Veeam Software Appliance). VBR v13 only.

.PARAMETER HtmlPath
    Path for the HTML report. If omitted, the report is saved in the current
    folder as:
      Entra ID Report - Tenant and Log - <yyyy-MM-dd HHmm>.html   (-ReportType Both)
      Entra ID Report - Tenant - <yyyy-MM-dd HHmm>.html           (-ReportType Tenant)
      Entra ID Report - Log - <yyyy-MM-dd HHmm>.html              (-ReportType Logs)

.PARAMETER PassThru
    Returns an object with Summary, RestorePoints, LogJobs and LogRestorePoints
    properties for pipeline use.

.PARAMETER LogFileTimesAreLocal
    Log file names carry their hour window (e.g. 2026-11-07T14:00:00_...).
    These are treated as UTC by default. Set this switch if your files turn
    out to be stamped in server local time.

.PARAMETER ReportType
    What to report on:
      Both    tenant backups and log backups (default)
      Tenant  tenant backup jobs and restore points only
      Logs    log backup jobs and restore points only

.PARAMETER EntraRepositoryLabel
    Name shown for tenant backups stored in the built-in PostgreSQL-based
    Microsoft Entra ID backup repository. VBR doesn't expose that repository
    through PowerShell, so the script can't read its name. Override this if you
    want something site-specific, e.g. "VSA01 Entra ID DB".

.PARAMETER StaleHours
    Flags a tenant backup as stale if the newest restore point is older than this. Default 24.

.EXAMPLE
    .\Get-VBREntraIDBackupReport.ps1 -Server 192.168.0.45 -Login -ForceAcceptTlsCertificate

.EXAMPLE
    .\Get-VBREntraIDBackupReport.ps1 -Server vbr01.corp.local -Port 9392 -ReportType Tenant

.EXAMPLE
    .\Get-VBREntraIDBackupReport.ps1 -Server vbr01 -Login -HtmlPath .\entra.html

.EXAMPLE
    .\Get-VBREntraIDBackupReport.ps1 -Server 192.168.0.45 -Login -ForceAcceptTlsCertificate -ReportType Logs -HtmlPath .\entra-logs.html

.NOTES
    Requires VBR 12.1 or later (Entra ID support) and the Veeam.Backup.PowerShell module.
    VBR v13 changed the default PowerShell connection port from 9392 to 443.
#>

[CmdletBinding()]
param(
    [string]$Server = "localhost",
    [int]$Port = 443,
    [switch]$Login,
    [switch]$ForceAcceptTlsCertificate,
    [string]$HtmlPath,
    [int]$StaleHours = 24,
    [string]$EntraRepositoryLabel = "Microsoft Entra ID Repository (PostgreSQL)",
    [switch]$LogFileTimesAreLocal,
    [ValidateSet('Both', 'Tenant', 'Logs')]
    [string]$ReportType = 'Both',
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

#region Module and connection
try {
    if (-not (Get-Module -Name Veeam.Backup.PowerShell)) {
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
    }
}
catch {
    Write-Error "Unable to load Veeam.Backup.PowerShell. Run this from a VBR server or a machine with the VBR console installed."
    return
}

$weConnected = $false
$existing = Get-VBRServerSession -ErrorAction SilentlyContinue

if ($existing -and $existing.Server -ne $Server) {
    Disconnect-VBRServer
    $existing = $null
}

if (-not $existing) {
    $connectArgs = @{ Server = $Server; Port = $Port }
    if ($Login) {
        $cred = Get-Credential -Message "Enter VBR credentials for $Server"
        if (-not $cred) { Write-Error "No credentials entered. Exiting."; return }
        $connectArgs.Credential = $cred
    }
    if ($ForceAcceptTlsCertificate) { $connectArgs.ForceAcceptTlsCertificate = $true }
    try {
        Connect-VBRServer @connectArgs
        $weConnected = $true
        Write-Host "Connected to $Server" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to ${Server}:$Port. $($_.Exception.Message)"
        return
    }
}
#endregion

try {
    #region Collect data
    $includeTenant = $ReportType -in 'Both', 'Tenant'
    $includeLogs   = $ReportType -in 'Both', 'Logs'

    $jobs    = @()
    $backups = @()
    if ($includeTenant) {
        $jobs    = @(Get-VBREntraIDTenantBackupJob)
        $backups = @(Get-VBREntraIDTenantBackup)
        if ($jobs.Count -eq 0 -and $backups.Count -eq 0) {
            Write-Warning "No Entra ID tenant backup jobs or backups found on $Server."
            if (-not $includeLogs) { return }
        }
    }

    # Repository lookup.
    # Entra ID tenant backups are stored in the PostgreSQL-based Microsoft Entra ID
    # backup repository, not in a standard, object storage or scale-out repository.
    # Veeam PowerShell has no Get- cmdlet for that repository, so its ID will not
    # resolve through the lookup below. The lookup is kept for any backup whose
    # RepositoryId does point at a regular repository.
    $repoLookup = @{}
    $repoCmds = Get-Command -Module Veeam.Backup.PowerShell -Name 'Get-VBR*Repository' -ErrorAction SilentlyContinue
    foreach ($cmd in $repoCmds) {
        $runnable = $cmd.ParameterSets | Where-Object {
            -not ($_.Parameters | Where-Object { $_.IsMandatory })
        }
        if (-not $runnable) { continue }
        try {
            foreach ($r in @(& $cmd.Name -ErrorAction Stop)) {
                if ($r.Id -and $r.Name -and -not $repoLookup.ContainsKey([guid]$r.Id)) {
                    $repoLookup[[guid]$r.Id] = $r.Name
                }
            }
        } catch {
            Write-Verbose "Repository lookup via $($cmd.Name) failed: $($_.Exception.Message)"
        }
    }
    # Scale-out repositories aren't always returned by the default call
    try {
        foreach ($r in @(Get-VBRBackupRepository -ScaleOut -ErrorAction Stop)) {
            if (-not $repoLookup.ContainsKey([guid]$r.Id)) { $repoLookup[[guid]$r.Id] = $r.Name }
        }
    } catch { }

    function Resolve-RepoName {
        param($RepositoryId)
        if (-not $RepositoryId) { return "" }
        $key = [guid]$RepositoryId
        if ($repoLookup.ContainsKey($key)) { return $repoLookup[$key] }
        # Not a regular repository, so it's the built-in PostgreSQL-based Entra ID repository
        Write-Verbose "Repository ID $RepositoryId is not a regular repository; reporting as the Entra ID repository."
        return $EntraRepositoryLabel
    }
    #endregion

    #region Build report
    $now = Get-Date
    $rpReport = [System.Collections.Generic.List[object]]::new()

    #region Item type discovery
    # Read the item types from the installed module so new types (devices,
    # Intune policies, etc. on newer builds) are picked up automatically.
    $itemTypes = @()
    try {
        $typeParam = (Get-Command Get-VBREntraIDTenantItem).Parameters['Type'].ParameterType
        if ($typeParam.IsArray) { $typeParam = $typeParam.GetElementType() }
        if ($typeParam.IsEnum) { $itemTypes = [Enum]::GetNames($typeParam) }
    } catch { }
    if (-not $itemTypes) {
        $itemTypes = @('User', 'Group', 'Role', 'AdminUnit', 'Application', 'ConditionalAccessPolicy')
    }

    $friendly = @{
        User                    = 'Users'
        Group                   = 'Groups'
        Role                    = 'Roles'
        AdminUnit               = 'Administrative Units'
        Application             = 'Applications'
        ConditionalAccessPolicy = 'Conditional Access Policies'
        DeviceConfiguration     = 'Intune Policies'
        OrgContacts             = 'Organizational Contacts'
    }
    $typeColumns = [ordered]@{}
    foreach ($t in $itemTypes) {
        $typeColumns[$t] = if ($friendly.ContainsKey($t)) { $friendly[$t] } else { $t }
    }
    #endregion

    function Get-RestorePointItemCounts {
        # Returns @{ <RestorePointId> = [ordered]@{ Users = n; Groups = n; ... } }
        param($Backup, $Points)

        $result = @{}
        if (-not $Points) { return $result }

        # All items the backup knows about, per type
        $itemsByType = [ordered]@{}
        foreach ($t in $typeColumns.Keys) {
            try {
                $itemsByType[$t] = @(Get-VBREntraIDTenantItem -Backup $Backup -Type $t -ErrorAction Stop)
            } catch {
                # Type not licensed (e.g. CA policies below Enterprise Plus) or not supported
                Write-Verbose "[$($Backup.Name)] $t not available: $($_.Exception.Message)"
                $itemsByType[$t] = $null
            }
        }

        $session = $null
        try {
            $session = Start-VBREntraIDTenantRestore -Backup $Backup
        } catch {
            Write-Warning "[$($Backup.Name)] Could not open a restore session for item counts: $($_.Exception.Message)"
        }

        try {
            $pi = 0
            foreach ($rp in $Points) {
                $pi++
                Write-Progress -Activity "Counting Entra ID items: $($Backup.Name)" `
                    -Status "Restore point $pi of $($Points.Count) ($($rp.CreationTime))" `
                    -PercentComplete (($pi / $Points.Count) * 100)

                $counts = [ordered]@{}
                foreach ($t in $typeColumns.Keys) {
                    $col   = $typeColumns[$t]
                    $items = $itemsByType[$t]

                    if ($null -eq $items) { $counts[$col] = "N/A"; continue }
                    if ($items.Count -eq 0) { $counts[$col] = 0; continue }
                    if (-not $session)    { $counts[$col] = "N/A"; continue }

                    try {
                        $missing = 0
                        # Validate in chunks to keep individual calls a sane size
                        for ($c = 0; $c -lt $items.Count; $c += 500) {
                            $chunk = $items[$c..([math]::Min($c + 499, $items.Count - 1))]
                            $missing += @(Validate-VBREntraIDTenantItem -Session $session `
                                -RestorePointId $rp.Id -Items $chunk -ErrorAction Stop).Count
                        }
                        $counts[$col] = $items.Count - $missing
                    } catch {
                        Write-Verbose "[$($Backup.Name)] Validate failed for $t at $($rp.Id): $($_.Exception.Message)"
                        $counts[$col] = "Error"
                    }
                }
                $result[$rp.Id] = $counts
            }
        }
        finally {
            Write-Progress -Activity "Counting Entra ID items: $($Backup.Name)" -Completed
            if ($session) {
                try { Stop-VBREntraIDTenantRestore -Session $session -Graceful } catch {
                    Write-Warning "[$($Backup.Name)] Restore session did not close cleanly. Check VBR for an open Entra ID restore session."
                }
            }
        }
        return $result
    }

    #region Job session log counts (role assignments, OAuth2 grants)
    # Session log label -> report column. Add more here if the job log shows
    # other types you want reported (log labels are matched case-insensitively,
    # ignoring spaces).
    $sessionLogColumns = [ordered]@{
        'Role Assignment'         = 'Role Assignments'
        'Oauth2 Permission Grant' = 'OAuth2 Grants'
    }

    # Entra ID job sessions aren't reliably returned by Get-VBRBackupSession.
    # Get-VBRSession -Type <Entra type> does return them (as "lite" sessions).
    # Session types are read from the installed module, so this works across builds.
    $sessionsByJob = @{}
    if ($jobs.Count) {
        $jobIdSet   = @{}
        $jobNameMap = @{}
        foreach ($j in $jobs) {
            $jobIdSet[[guid]$j.Id] = $true
            $jobNameMap[$j.Name.ToLowerInvariant()] = [guid]$j.Id
        }

        $entraTypes = @()
        try {
            $tp = (Get-Command Get-VBRSession -ErrorAction Stop).Parameters['Type'].ParameterType
            if ($tp.IsArray) { $tp = $tp.GetElementType() }
            # Only the tenant backup sessions carry the "collected" lines
            if ($tp.IsEnum) { $entraTypes = [Enum]::GetNames($tp) | Where-Object { $_ -match 'Entra' -and $_ -match 'ItemBackup' } }
        } catch { }
        if (-not $entraTypes) { $entraTypes = @('EntraIdItemBackup') }
        Write-Verbose "Entra ID session types: $($entraTypes -join ', ')"

        foreach ($st in $entraTypes) {
            try {
                foreach ($sess in @(Get-VBRSession -Type $st -ErrorAction Stop)) {
                    $jid = [guid]$sess.JobId
                    if (-not $jobIdSet.ContainsKey($jid)) {
                        # Session JobId doesn't match the job object's Id; fall back to name
                        $nm = "$($sess.Name)".ToLowerInvariant()
                        if ($jobNameMap.ContainsKey($nm)) { $jid = $jobNameMap[$nm] } else { continue }
                    }
                    if (-not $sessionsByJob.ContainsKey($jid)) { $sessionsByJob[$jid] = [System.Collections.Generic.List[object]]::new() }
                    $sessionsByJob[$jid].Add($sess)
                }
            } catch {
                Write-Verbose "Get-VBRSession -Type $st failed: $($_.Exception.Message)"
            }
        }
        foreach ($j in $jobs) {
            $n = if ($sessionsByJob.ContainsKey([guid]$j.Id)) { $sessionsByJob[[guid]$j.Id].Count } else { 0 }
            Write-Verbose "Job '$($j.Name)': $n session(s) found"
        }
    }

    function Get-LogCountsFromTitles {
        param([string[]]$Titles, [hashtable]$Counts)
        foreach ($t in $Titles) {
            if ($t -match '^\s*(?<label>.+?)\s+collected:\s*(?<done>\d+)\s+of\s+(?<total>\d+)') {
                $key = ($Matches.label -replace '\s', '').ToLowerInvariant()
                # Sum across tasks in case a job session has more than one
                $Counts[$key] = [int]($Counts[$key]) + [int]$Matches.done
            }
        }
    }

    $sessionLogCache = @{}
    function Get-SessionLogCounts {
        # Returns @{ <normalised label> = <count collected> } for a job session.
        # The "collected" lines live in the per-tenant task session log, not the
        # job-level log, so check the job log first and then the task logs.
        param($Session)
        if ($sessionLogCache.ContainsKey($Session.Id)) { return $sessionLogCache[$Session.Id] }
        $counts = @{}

        # 1. Job-level log (lite session from Get-VBRSession exposes .Log)
        try {
            if ($Session.Log) { Get-LogCountsFromTitles -Titles @($Session.Log | ForEach-Object { $_.Title }) -Counts $counts }
        } catch { }

        # 2. Task session logs (needs the full CBackupSession)
        if ($counts.Count -eq 0) {
            try {
                $full  = Get-VBRBackupSession -Id $Session.Id -ErrorAction Stop
                $tasks = @(Get-VBRTaskSession -Session $full -ErrorAction Stop)
                foreach ($task in $tasks) {
                    $titles = @($task.Logger.GetLog().UpdatedRecords | ForEach-Object { $_.Title })
                    Get-LogCountsFromTitles -Titles $titles -Counts $counts
                }
                # Some builds keep the lines on the job logger instead
                if ($counts.Count -eq 0 -and $full.Logger) {
                    Get-LogCountsFromTitles -Titles @($full.Logger.GetLog().UpdatedRecords | ForEach-Object { $_.Title }) -Counts $counts
                }
            } catch {
                Write-Verbose "Could not read task logs for session $($Session.Id): $($_.Exception.Message)"
            }
        }

        if ($counts.Count -eq 0) { Write-Verbose "Session $($Session.Id) ($($Session.CreationTime)): no 'collected' lines found" }
        $sessionLogCache[$Session.Id] = $counts
        return $counts
    }

    $offsetByJob = @{}
    function Get-SessionTimeOffset {
        # Restore point timestamps and session timestamps can come back in
        # different time zones (e.g. appliance in UTC, console in local time).
        # Try offsets from -14h to +14h in 15-minute steps and keep the one that
        # lines up the most restore points with a session window.
        param($JobId, $Points)
        $key = [guid]$JobId
        if ($offsetByJob.ContainsKey($key)) { return $offsetByJob[$key] }

        $sessions = @($sessionsByJob[$key] | Where-Object { $_.EndTime -and $_.EndTime -gt [datetime]'1900-01-01' })
        $slack    = [timespan]::FromMinutes(10)
        $best     = [timespan]::Zero
        $bestHits = -1

        if ($sessions.Count -and $Points) {
            for ($m = -840; $m -le 840; $m += 15) {
                $off  = [timespan]::FromMinutes($m)
                $hits = 0
                foreach ($p in $Points) {
                    $t = $p.CreationTime + $off
                    foreach ($sx in $sessions) {
                        if ($t -ge ($sx.CreationTime - $slack) -and $t -le ($sx.EndTime + $slack)) { $hits++; break }
                    }
                }
                # Prefer the smallest offset on ties so zero wins when times already agree
                if ($hits -gt $bestHits -or ($hits -eq $bestHits -and [math]::Abs($m) -lt [math]::Abs($best.TotalMinutes))) {
                    $bestHits = $hits; $best = $off
                }
            }
            Write-Verbose ("Job {0}: restore point/session time offset {1:N2}h, matched {2} of {3} points" -f `
                $JobId, $best.TotalHours, $bestHits, @($Points).Count)
        }
        $offsetByJob[$key] = $best
        return $best
    }

    function Find-SessionForPoint {
        # The job session that produced a restore point, after adjusting for any
        # time zone offset between the two timestamp sources.
        param($JobId, $Point, [timespan]$Offset = [timespan]::Zero)
        if (-not $JobId -or -not $sessionsByJob.ContainsKey([guid]$JobId)) { return $null }
        $slack = [timespan]::FromMinutes(10)
        $t     = $Point.CreationTime + $Offset
        $all   = $sessionsByJob[[guid]$JobId]
        $match = $all |
            Where-Object {
                $_.CreationTime -le ($t + $slack) -and
                ($null -eq $_.EndTime -or $_.EndTime -le [datetime]'1900-01-01' -or $_.EndTime -ge ($t - $slack))
            } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        if ($match) { return $match }

        # No session window contains the point. Fall back to the nearest session
        # (by start or end time) within 2 hours, and say so in verbose output.
        $nearest = $all | ForEach-Object {
            $d1 = [math]::Abs(($_.CreationTime - $t).TotalMinutes)
            $d2 = if ($_.EndTime -and $_.EndTime -gt [datetime]'1900-01-01') { [math]::Abs(($_.EndTime - $t).TotalMinutes) } else { $d1 }
            [pscustomobject]@{ Session = $_; Minutes = [math]::Min($d1, $d2) }
        } | Sort-Object Minutes | Select-Object -First 1
        if ($nearest -and $nearest.Minutes -le 120) {
            Write-Verbose ("Point {0}: no session window match, using nearest session {1} ({2:N0} min away)" -f `
                $Point.CreationTime, $nearest.Session.CreationTime, $nearest.Minutes)
            return $nearest.Session
        }
        Write-Verbose ("Point {0}: no session within 2h (offset {1:N2}h, {2} sessions for job)" -f `
            $Point.CreationTime, $Offset.TotalHours, @($all).Count)
        return $null
    }
    #endregion

    function Add-RestorePointRows {
        param($Points, $JobName, $TenantName, $AzureTenantId, $BackupLookup, $JobId)

        # Item counts, one restore session per backup
        $countLookup = @{}
        if ($Points) {
            foreach ($grp in ($Points | Group-Object BackupId)) {
                $bk = $BackupLookup[[guid]$grp.Name]
                if ($bk) {
                    $c = Get-RestorePointItemCounts -Backup $bk -Points @($grp.Group)
                    foreach ($k in $c.Keys) { $countLookup[$k] = $c[$k] }
                }
            }
        }

        $tzOffset = [timespan]::Zero
        if ($JobId -and $sessionsByJob.ContainsKey([guid]$JobId)) {
            $tzOffset = Get-SessionTimeOffset -JobId $JobId -Points $Points
        }

        # Newest first, numbered 1..n
        $sorted = @($Points | Sort-Object CreationTime -Descending)
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $rp = $sorted[$i]
            $bk = $BackupLookup[$rp.BackupId]
            $row = [ordered]@{
                JobName          = $JobName
                TenantName       = $TenantName
                AzureTenantId    = $AzureTenantId
                BackupName       = if ($bk) { $bk.Name } else { "" }
                Repository       = if ($bk) { Resolve-RepoName $bk.RepositoryId } else { "" }
                PointNumber      = $i + 1
                IsLatest         = ($i -eq 0)
                CreationTime     = $rp.CreationTime
                RestorePointName = $rp.Name
                RestorePointId   = $rp.Id
            }
            if ($typeColumns.Count) {
                $counts = $countLookup[$rp.Id]
                $total  = 0
                foreach ($col in $typeColumns.Values) {
                    $v = if ($counts) { $counts[$col] } else { "N/A" }
                    $row[$col] = $v
                    if ($v -is [int]) { $total += $v }
                }

                # Role assignments / OAuth2 grants from the job session log
                $sess      = Find-SessionForPoint -JobId $JobId -Point $rp -Offset $tzOffset
                $logCounts = if ($sess) { Get-SessionLogCounts -Session $sess } else { $null }
                foreach ($label in $sessionLogColumns.Keys) {
                    $key = ($label -replace '\s', '').ToLowerInvariant()
                    $v = if ($logCounts -and $logCounts.ContainsKey($key)) { $logCounts[$key] } else { "N/A" }
                    $row[$sessionLogColumns[$label]] = $v
                    if ($v -is [int]) { $total += $v }
                }
                $row['TotalItems'] = $total
            }
            $rpReport.Add([pscustomobject]$row)
        }
    }

    $backupLookup = @{}
    foreach ($b in $backups) { $backupLookup[$b.Id] = $b }

    # Result of the most recent run of a tenant backup job. Reuses the sessions
    # already collected for item counts; otherwise queries them once here.
    $lastRunCache = $null
    function Get-TenantJobLastRun {
        param($Job)
        $jid  = [guid]$Job.Id
        $list = if ($sessionsByJob.ContainsKey($jid)) { @($sessionsByJob[$jid]) } else { @() }
        if (-not $list.Count) {
            if ($null -eq $script:lastRunCache) {
                $script:lastRunCache = @()
                try { $script:lastRunCache = @(Get-VBRSession -Type EntraIdItemBackup -ErrorAction Stop) } catch {
                    Write-Verbose "Last run lookup failed: $($_.Exception.Message)"
                }
            }
            $list = @($script:lastRunCache | Where-Object {
                ("$($_.JobId)" -eq "$($Job.Id)") -or ("$($_.Name)" -eq "$($Job.Name)")
            })
        }
        $last = $list | Sort-Object CreationTime | Select-Object -Last 1
        if (-not $last) { return "" }
        $r = "$($last.Result)"
        if (-not $r -or $r -eq 'None') { $r = "$($last.State)" }   # still running
        return $r
    }

    function Format-Retention {
        # "<n> Days|Weeks|Months|Years" from a period and a retention type
        # (handles Days/Daily, Weeks/Weekly, etc.). Tenant jobs default to days.
        param($Period, $Type)
        $unit = switch -Regex ("$Type") {
            'Day|Daily'           { 'Day' }
            'Week'                { 'Week' }
            'Month'               { 'Month' }
            'Year|Annual'         { 'Year' }
            'Point'               { 'Restore Point' }
            '^\s*$'               { 'Day' }
            default               { "$Type" }
        }
        $n = 0
        if (-not [int]::TryParse("$Period", [ref]$n) -or $n -le 0) { return "" }
        if ($n -ne 1) { $unit = "${unit}s" }
        return "$n $unit"
    }

    $report = @(foreach ($job in $jobs) {
        $jobBackups = @($backups | Where-Object { $_.JobId -eq $job.Id })

        $points = foreach ($b in $jobBackups) {
            try { Get-VBREntraIDTenantRestorePoint -Backup $b } catch { }
        }
        $points  = @($points | Sort-Object CreationTime)
        Add-RestorePointRows -Points $points -JobName $job.Name -TenantName $job.Tenant.Name `
            -AzureTenantId $job.Tenant.AzureTenantId -BackupLookup $backupLookup -JobId $job.Id
        $oldest  = if ($points.Count) { $points[0].CreationTime } else { $null }
        $newest  = if ($points.Count) { $points[-1].CreationTime } else { $null }
        $ageHrs  = if ($newest) { [math]::Round(($now - $newest).TotalHours, 1) } else { $null }

        $repoNames = ($jobBackups | ForEach-Object {
            Resolve-RepoName $_.RepositoryId
        } | Select-Object -Unique) -join "; "

        $status = if (-not $newest) { "No restore points" }
                  elseif ($ageHrs -gt $StaleHours) { "Stale (>$StaleHours h)" }
                  else { "OK" }

        [pscustomobject]@{
            'Job Name'             = $job.Name
            Description            = $job.Description
            'Tenant Name'          = $job.Tenant.Name
            Region                 = $job.Tenant.Region
            'Scheduled'            = $job.EnableSchedule
            'Retention'            = Format-Retention -Period $job.RetentionPolicy -Type $job.RetentionType
            Encrypted              = [bool]$job.EncryptionOptions.EnableEncryption
            Repository             = $repoNames
            'Restore Points'       = $points.Count
            'Oldest Point'         = $oldest
            'Last Run'             = Get-TenantJobLastRun -Job $job
            Status                 = $status
        }
    })

    # Orphaned backups (backup exists but job was deleted)
    $orphans = $backups | Where-Object { $jobs.Id -notcontains $_.JobId }
    foreach ($b in $orphans) {
        $points = @(@(try { Get-VBREntraIDTenantRestorePoint -Backup $b } catch { }) | Sort-Object CreationTime)
        Add-RestorePointRows -Points $points -JobName "$($b.Name) (orphaned)" -TenantName "" `
            -AzureTenantId $b.TenantId -BackupLookup $backupLookup
        $report += [pscustomobject]@{
            'Job Name'             = "$($b.Name) (orphaned)"
            Description            = ""
            'Tenant Name'          = ""
            Region                 = ""
            'Scheduled'            = $false
            'Retention'            = ""
            Encrypted              = ""
            Repository             = Resolve-RepoName $b.RepositoryId
            'Restore Points'       = $points.Count
            'Oldest Point'         = if ($points.Count) { $points[0].CreationTime } else { $null }
            'Last Run'             = ""
            Status                 = "Orphaned backup"
        }
    }
    #endregion

    #region Entra ID log backups
    $logReport      = @()
    $logRpReport    = [System.Collections.Generic.List[object]]::new()
    # Restore point columns for log backups
    $logTypeColumns = [System.Collections.Generic.List[string]]::new()
    foreach ($c in 'Audit Log Files', 'Sign-in Log Files', 'Total Files', 'Data Size') { $logTypeColumns.Add($c) }

    # Log type folder in the backup -> report column
    $logFolderColumns = @{
        'Audit Logs'   = 'Audit Log Files'
        'Sign-in Logs' = 'Sign-in Log Files'
    }
    # Session log status key -> report column it decorates
    $logStatusColumns = @{
        'Audit Logs'   = 'Audit Log Files'
        'Sign-in Logs' = 'Sign-in Log Files'
    }

    # Log types and the words used for them in the session log
    $logTypes = [ordered]@{
        'Audit Logs'   = 'audit'
        'Sign-in Logs' = 'sign[\s-]?in'
    }

    function Get-FirstValue {
        # First non-empty value from a list of property paths (e.g. 'Tenant.Name')
        param($Object, [string[]]$Paths)
        foreach ($p in $Paths) {
            $v = $Object
            foreach ($part in $p.Split('.')) {
                if ($null -eq $v) { break }
                $prop = $v.PSObject.Properties[$part]
                $v = if ($prop) { $prop.Value } else { $null }
            }
            if ($null -ne $v -and "$v" -ne '') { return $v }
        }
        return $null
    }

    function Get-LogSessionCounts {
        # Returns [ordered]@{ Files; 'Data Size'; 'Audit Logs'; 'Sign-in Logs' }
        # parsed from one log backup session (job log + task logs).
        param($Session)
        $titles = [System.Collections.Generic.List[string]]::new()
        try {
            $full = Get-VBRBackupSession -Id $Session.Id -ErrorAction Stop
            if (-not $full) { $full = $Session }
            foreach ($task in @(Get-VBRTaskSession -Session $full -ErrorAction SilentlyContinue)) {
                try { $task.Logger.GetLog().UpdatedRecords | ForEach-Object { $titles.Add([string]$_.Title) } } catch { }
            }
            try { $full.Logger.GetLog().UpdatedRecords | ForEach-Object { $titles.Add([string]$_.Title) } } catch { }
        } catch {
            Write-Verbose "Log session $($Session.Id): could not read log ($($_.Exception.Message))"
        }
        if ($titles.Count -eq 0 -and $Session.PSObject.Properties['Log']) {
            $Session.Log | ForEach-Object { $titles.Add([string]$_.Title) }
        }
        $titles = @($titles | Select-Object -Unique)

        $result = [ordered]@{}
        if ($titles.Count -eq 0) { return $result }

        # Files and size: "Backed up 49 files (53.9 KB)"
        $files = $null; $size = $null
        foreach ($t in $titles) {
            if ($t -match '^\s*Backed up\s+(?<n>[\d,]+)\s+files?\s*\((?<size>[^)]+)\)') {
                $files = [int]($Matches.n -replace ',', ''); $size = $Matches.size.Trim(); break
            }
        }
        $result['Total Files'] = if ($null -ne $files) { $files } else { "N/A" }
        $result['Data Size'] = if ($size) { $size } else { "N/A" }

        # Per log type status from warning/error lines that name the type
        foreach ($type in $logTypes.Keys) {
            $word    = $logTypes[$type]
            $problem = $titles | Where-Object { $_ -match $word -and $_ -match 'unable|skipp|fail|error|not permit|denied' } | Select-Object -First 1
            $result[$type] = if ($problem) {
                if     ($problem -match 'licen[cs]e')       { "Skipped (license)" }
                elseif ($problem -match 'permission|denied') { "Skipped (permissions)" }
                elseif ($problem -match 'fail|error')       { "Failed" }
                else                                        { "Skipped" }
            }
            elseif ($files -gt 0) { "Backed up" }
            else                  { "No data" }
        }

        if ($null -eq $files) {
            Write-Verbose "Log session $($Session.Id) ($($Session.CreationTime)): no 'Backed up N files' line. Raw log:"
            $titles | ForEach-Object { Write-Verbose "    $_" }
        }
        return $result
    }

    function Resolve-LogJobTenantName {
        # Tenant name for a log job: from the job object, then by tenant ID,
        # then from the "Processing <tenant>" line in the latest session log.
        param($Job, $Sessions)
        $name = Get-FirstValue $Job.BackupObject @('Tenant.Name', 'TenantName', 'Name')
        if ($name) { return "$name" }

        $id = Get-FirstValue $Job.BackupObject @('Tenant.AzureTenantId', 'AzureTenantId', 'Tenant.Id', 'TenantId', 'Id')
        if ($id -and $tenantNameById.ContainsKey("$id".ToLowerInvariant())) { return $tenantNameById["$id".ToLowerInvariant()] }

        $latest = $Sessions | Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($latest) {
            $titles = @()
            try { $titles = @($latest.Logger.GetLog().UpdatedRecords | ForEach-Object { $_.Title }) } catch { }
            if (-not $titles -and $latest.PSObject.Properties['Log']) { $titles = @($latest.Log | ForEach-Object { $_.Title }) }
            foreach ($t in $titles) {
                if ($t -match '^\s*Processing\s+(?<n>.+?)\s*$' -and $t -notmatch 'finished|started') { return $Matches.n }
            }
        }
        return ""
    }

    function Get-LogFlrTree {
        # Lists files under a log backup FLR folder by browsing each folder in
        # turn. Returns @{ Trail = @(<folder>, <folder>, <file>); Truncated }
        param($Session, $Folder, [string[]]$Trail, [int]$Depth = 0)
        if ($Depth -gt 6) { return }
        $children = if ($Folder) {
            @(Get-VBREntraIDLogsBackupFLRItem -Session $Session -Folder $Folder -ErrorAction Stop)
        } else {
            @(Get-VBREntraIDLogsBackupFLRItem -Session $Session -ErrorAction Stop)
        }
        $truncated = $children.Count -ge 10000
        foreach ($c in $children) {
            $leaf = @("$($c.Name)" -split '\|')[-1]
            $next = @($Trail) + $leaf
            if ("$($c.Type)" -eq 'Folder' -or $c.GetType().Name -match 'Folder') {
                Get-LogFlrTree -Session $Session -Folder $c -Trail $next -Depth ($Depth + 1)
            } else {
                $own = if ("$($c.Path)") { "$($c.Path)" } else { "$($c.Name)" }
                [pscustomobject]@{ Trail = $next; FullPath = $own; Truncated = $truncated }
            }
        }
    }

    function Get-LogFileInventory {
        # Lists every log file in a log backup through a read-only FLR browse
        # session. Returns @{ Files = @(@{ Column; Start; End }); Status }
        param($Backup, $Tenant)
        $inv = @{ Files = @(); Status = 'OK' }
        if (-not $Backup) { $inv.Status = 'Not available (log backup not found)'; return $inv }
        if (-not $Tenant) { $inv.Status = 'Not available (tenant not found)'; return $inv }

        # UTC by default: parse as UTC, then convert to local time below
        $style = if ($LogFileTimesAreLocal) { [Globalization.DateTimeStyles]::AssumeLocal }
                 else { [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal }
        $fmt   = "yyyy-MM-dd'T'HH:mm:ss"
        $ci    = [Globalization.CultureInfo]::InvariantCulture

        $flr = $null
        try {
            $flr   = Start-VBREntraIDLogsBackupFLRSession -Backup $Backup -Tenant $Tenant -ErrorAction Stop
            # Walk the folder tree (Month > Log type > files) one level at a time.
            # -Recurse triggers a server-side search that can fail with
            # "Container record already exists", so it's only used as a fallback.
            $entries = $null
            try {
                $entries = @(Get-LogFlrTree -Session $flr -Folder $null -Trail @())
            } catch {
                Write-Verbose "[$($Backup.Name)] Folder walk failed, trying -Recurse: $($_.Exception.Message)"
                $entries = @(Get-VBREntraIDLogsBackupFLRItem -Session $flr -Recurse -ErrorAction Stop |
                    Where-Object { "$($_.Type)" -eq 'File' } |
                    ForEach-Object { [pscustomobject]@{ Trail = @("$($_.Path)" -split '\|'); FullPath = "$($_.Path)"; Truncated = $false } })
            }
            if (@($entries | Where-Object Truncated).Count) { $inv.Status = 'Truncated (10,000 item limit)' }

            # A folder listing can return files from sibling folders, so count each
            # file once (by its own path) and read its log type from that path,
            # not from the folder that was being listed.
            $seen = @{}
            $files = foreach ($en in $entries) {
                $key = "$($en.FullPath)".ToLowerInvariant()
                if ($key) {
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                }
                $ownParts = @("$($en.FullPath)" -split '\|')
                $trail = if ($ownParts.Count -ge 2) { $ownParts } else { @($en.Trail) }
                if ($trail.Count -lt 2) { continue }
                $folder = "$($trail[-2])".Trim()          # e.g. "Audit Logs"
                $fname  = "$($trail[-1])"
                $col    = if ($logFolderColumns.ContainsKey($folder)) { $logFolderColumns[$folder] } else { "$folder Files" }
                if ($fname -match '(?<s>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)_(?<e>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)') {
                    [pscustomobject]@{
                        Column = $col
                        Start  = ([datetime]::ParseExact($Matches.s, $fmt, $ci, $style)).ToLocalTime()
                        End    = ([datetime]::ParseExact($Matches.e, $fmt, $ci, $style)).ToLocalTime()
                    }
                } else {
                    [pscustomobject]@{ Column = $col; Start = $null; End = $null }
                }
            }
            $inv.Files = @($files)
        } catch {
            $inv.Status = "Failed: $($_.Exception.Message)"
            Write-Verbose "[$($Backup.Name)] Log file inventory failed: $($_.Exception.Message)"
        } finally {
            if ($flr) {
                try { Stop-VBREntraIDLogsBackupFLRSession -Session $flr | Out-Null } catch {
                    Write-Warning "[$($Backup.Name)] Log browse session did not close cleanly. Check VBR for an open Entra ID log restore session."
                }
            }
        }
        return $inv
    }

    if ($includeLogs) {
        # Tenant ID -> name lookup, used to match log jobs to tenants
        $tenantNameById = @{}
        $tenantObjById  = @{}
        $tenantObjByName = @{}
        try {
            foreach ($t in @(Get-VBREntraIDTenant -ErrorAction Stop)) {
                foreach ($k in @($t.Id, $t.AzureTenantId, $t.TenantId)) {
                    if ($k) {
                        $tenantNameById["$k".ToLowerInvariant()] = "$($t.Name)"
                        $tenantObjById["$k".ToLowerInvariant()]  = $t
                    }
                }
                if ($t.Name) { $tenantObjByName["$($t.Name)".Trim().ToLowerInvariant()] = $t }
            }
        } catch { Write-Verbose "Get-VBREntraIDTenant failed: $($_.Exception.Message)" }
        foreach ($j in $jobs) {
            foreach ($k in @($j.Tenant.Id, $j.Tenant.AzureTenantId)) {
                if ($k) { $tenantNameById["$k".ToLowerInvariant()] = "$($j.Tenant.Name)" }
            }
        }

        $logJobs    = @()
        $logBackups = @()
        try { $logJobs    = @(Get-VBREntraIDLogsBackupJob -ErrorAction Stop) } catch { Write-Verbose "Get-VBREntraIDLogsBackupJob failed: $($_.Exception.Message)" }
        try { $logBackups = @(Get-VBREntraIDLogsBackup    -ErrorAction Stop) } catch { Write-Verbose "Get-VBREntraIDLogsBackup failed: $($_.Exception.Message)" }
        if ($logJobs.Count -eq 0) { Write-Warning "No Entra ID log backup jobs found on $Server." }

        # Sessions per log job, deduplicated by session ID
        $logSessionsByJob = @{}
        $logJobIdSet      = @{}
        $logJobNameMap    = @{}
        foreach ($lj in $logJobs) {
            $logJobIdSet[[guid]$lj.Id] = $true
            $logJobNameMap["$($lj.Name)".ToLowerInvariant()] = [guid]$lj.Id
            $logSessionsByJob[[guid]$lj.Id] = @{}
        }

        function Add-LogSession {
            param($Sess)
            $jid = $null
            try { $jid = [guid]$Sess.JobId } catch { }
            if (-not ($jid -and $logJobIdSet.ContainsKey($jid))) {
                $nm = "$($Sess.Name)".ToLowerInvariant()
                if ($logJobNameMap.ContainsKey($nm)) { $jid = $logJobNameMap[$nm] } else { return }
            }
            $logSessionsByJob[$jid][[string]$Sess.Id] = $Sess
        }

        if ($logJobs.Count) {
            # 1. Sessions by job ID
            foreach ($lj in $logJobs) {
                try { foreach ($x in @([Veeam.Backup.Core.CBackupSession]::GetByJob([guid]$lj.Id))) { Add-LogSession $x } } catch { }
            }
            # 2. Entra ID session types
            try {
                $tp = (Get-Command Get-VBRSession -ErrorAction Stop).Parameters['Type'].ParameterType
                if ($tp.IsArray) { $tp = $tp.GetElementType() }
                $logSessTypes = if ($tp.IsEnum) { [Enum]::GetNames($tp) | Where-Object { $_ -match 'Entra' -and $_ -notmatch 'Restore|Repository' } } else { @() }
                foreach ($st in $logSessTypes) {
                    try { foreach ($x in @(Get-VBRSession -Type $st -ErrorAction Stop)) { Add-LogSession $x } } catch { }
                }
            } catch { }
            # 3. Full backup session list, only if nothing turned up
            if (-not ($logSessionsByJob.Values | Where-Object { $_.Count -gt 0 })) {
                try { foreach ($x in @(Get-VBRBackupSession -ErrorAction Stop)) { Add-LogSession $x } } catch { }
            }
        }

        $logReport = @(foreach ($lj in $logJobs) {
            $jid      = [guid]$lj.Id
            $sessions = @($logSessionsByJob[$jid].Values | Sort-Object CreationTime)
            Write-Verbose "Log job '$($lj.Name)': $($sessions.Count) session(s) found"

            # A run that finished Success/Warning produced a restore point
            $done = @($sessions | Where-Object {
                "$($_.Result)" -match 'Success|Warning' -and
                $_.EndTime -and $_.EndTime -gt [datetime]'1900-01-01'
            })

            # Runs older than the retention window no longer have restore points
            $retType   = "$($lj.ShortTermRetentionType)"
            $retPeriod = [int]$lj.ShortTermRetentionPeriod
            $cutoff    = $null
            if ($retPeriod -gt 0) {
                switch -Regex ($retType) {
                    'Day|Daily' { $cutoff = $now.AddDays(-$retPeriod) }
                    'Week'  { $cutoff = $now.AddDays(-7 * $retPeriod) }
                    'Month' { $cutoff = $now.AddMonths(-$retPeriod) }
                    'Year'  { $cutoff = $now.AddYears(-$retPeriod) }
                }
            }
            if ($cutoff) { $done = @($done | Where-Object { $_.EndTime -ge $cutoff }) }

            $tenantName = Resolve-LogJobTenantName -Job $lj -Sessions $sessions
            $primary    = Get-FirstValue $lj @('ShortTermBackupRepository.Name')
            $secondary  = if ($lj.SecondaryTargetEnabled) {
                (@($lj.SecondaryTarget) | ForEach-Object {
                    Get-FirstValue $_ @('BackupRepository.Name', 'Repository.Name', 'Target.Name', 'Name')
                } | Where-Object { $_ }) -join '; '
            } else { '' }
            $lb = $logBackups | Where-Object { "$($_.JobId)" -eq "$($lj.Id)" } | Select-Object -First 1
            if (-not $lb) { $lb = $logBackups | Where-Object { "$($_.Name)" -eq "$($lj.Name)" } | Select-Object -First 1 }
            if (-not $lb -and $logBackups.Count -eq 1 -and $logJobs.Count -eq 1) { $lb = $logBackups[0] }

            $sorted = @($done | Sort-Object EndTime -Descending)

            # Log file inventory (one browse session per log job)
            $inv = $null
            $filesByPoint = @{}
            $fileTotals   = [ordered]@{}
            if ($sorted.Count) {
                $tenantObj = $null
                $tid = Get-FirstValue $lj.BackupObject @('Tenant.AzureTenantId', 'AzureTenantId', 'Tenant.Id', 'TenantId')
                if ($tid -and $tenantObjById.ContainsKey("$tid".ToLowerInvariant())) { $tenantObj = $tenantObjById["$tid".ToLowerInvariant()] }
                elseif ($tenantName -and $tenantObjByName.ContainsKey($tenantName.Trim().ToLowerInvariant())) { $tenantObj = $tenantObjByName[$tenantName.Trim().ToLowerInvariant()] }

                if ($tenantObj) {
                    $inv = Get-LogFileInventory -Backup $lb -Tenant $tenantObj
                } else {
                    # Tenant couldn't be matched from the job: try each registered
                    # tenant until one opens a browse session on this backup
                    $inv = @{ Files = @(); Status = 'Not available (tenant not found)' }
                    foreach ($cand in @($tenantObjByName.Values | Select-Object -Unique)) {
                        $try = Get-LogFileInventory -Backup $lb -Tenant $cand
                        if ($try.Status -notmatch '^(Failed|Not available)') { $inv = $try; break }
                        $inv = $try
                    }
                }
                if ($inv.Status -ne 'OK') {
                    Write-Warning "[$($lj.Name)] Log file counts: $($inv.Status)"
                }

                # Assign each file to the first restore point that finished after
                # its hour window closed (oldest point first)
                $ascending = @($sorted | Sort-Object EndTime)
                foreach ($f in $inv.Files) {
                    if (-not $logTypeColumns.Contains($f.Column)) { $logTypeColumns.Insert(0, $f.Column) }
                    $fileTotals[$f.Column] = [int]($fileTotals[$f.Column]) + 1

                    $target = $null
                    if ($f.End) { $target = $ascending | Where-Object { $_.EndTime -ge $f.End } | Select-Object -First 1 }
                    if (-not $target) { $target = $ascending[-1] }   # window still open at last run, or no timestamp
                    $key = [string]$target.Id
                    if (-not $filesByPoint.ContainsKey($key)) { $filesByPoint[$key] = @{} }
                    $filesByPoint[$key][$f.Column] = [int]($filesByPoint[$key][$f.Column]) + 1
                }
            }

            # One row per restore point, newest first
            for ($i = 0; $i -lt $sorted.Count; $i++) {
                $sx     = $sorted[$i]
                $counts = Get-LogSessionCounts -Session $sx
                $pf     = $filesByPoint[[string]$sx.Id]
                $logRpReport.Add([pscustomobject]@{
                    TenantName   = $tenantName
                    JobName      = $lj.Name
                    PointNumber  = $i + 1
                    IsLatest     = ($i -eq 0)
                    CreationTime = $sx.EndTime
                    _Counts      = $counts
                    _Files       = if ($pf) { $pf } else { @{} }
                    _InvOK       = [bool]($inv -and $inv.Status -notmatch '^(Failed|Not available)')
                })
            }

            $newest = if ($sorted.Count) { $sorted[0].EndTime } else { $null }
            $oldest = if ($sorted.Count) { $sorted[-1].EndTime } else { $null }
            $age    = if ($newest) { ($now - $newest).TotalHours } else { $null }
            $last   = $sessions | Select-Object -Last 1

            [pscustomobject]@{
                'Job Name'             = $lj.Name
                Description            = $lj.Description
                'Tenant Name'          = $tenantName
                'Scheduled'            = $lj.ScheduleEnabled
                'Retention'            = Format-Retention -Period $retPeriod -Type $retType
                Encrypted              = if ($lb) { [bool]$lb.IsEncrypted } else { $null }
                Repository             = $primary
                'Secondary Repository' = $secondary
                'Restore Points'       = $sorted.Count
                'Oldest Point'         = $oldest
                'Audit Log Files'      = if ($inv -and $inv.Status -notmatch '^(Failed|Not available)') { [int]$fileTotals['Audit Log Files'] } else { "N/A" }
                'Sign-in Log Files'    = if ($inv -and $inv.Status -notmatch '^(Failed|Not available)') { [int]$fileTotals['Sign-in Log Files'] } else { "N/A" }
                'Logs Covered'         = if ($inv -and @($inv.Files | Where-Object Start).Count) {
                                             $st = ($inv.Files | Where-Object Start | Measure-Object Start -Minimum).Minimum
                                             $en = ($inv.Files | Where-Object End   | Measure-Object End   -Maximum).Maximum
                                             "{0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}" -f $st, $en
                                         } else { "" }
                'File Inventory'       = if ($inv) { $inv.Status } else { "" }
                'Last Run'             = if ($last) { "$($last.Result)" } else { "" }
                Status                 = if (-not $newest) { "No restore points" }
                                         elseif ($age -gt $StaleHours) { "Stale (>$StaleHours h)" }
                                         else { "OK" }
            }
        })

        # Expand the parsed values into columns
        $expanded = foreach ($r in $logRpReport) {
            $row = [ordered]@{}
            foreach ($p in $r.PSObject.Properties) { if ($p.Name -notlike '_*') { $row[$p.Name] = $p.Value } }

            # Session log status per type, e.g. "Skipped (license)"
            $statusFor = @{}
            foreach ($k in $logStatusColumns.Keys) {
                if ($r._Counts.Contains($k)) { $statusFor[$logStatusColumns[$k]] = $r._Counts[$k] }
            }

            foreach ($col in $logTypeColumns) {
                if ($col -eq 'Total Files' -and $r._InvOK) {
                    # Sum of the per-type columns so the row adds up
                    $sum = 0
                    foreach ($fc in $logTypeColumns) {
                        if ($fc -like '* Files' -and $fc -ne 'Total Files') { $sum += [int]($r._Files[$fc]) }
                    }
                    $row[$col] = $sum
                }
                elseif ($r._Counts.Contains($col)) {
                    # Data Size (and Total Files when the inventory failed) from the session log
                    $row[$col] = $r._Counts[$col]
                }
                elseif ($r._InvOK) {
                    $n  = [int]($r._Files[$col])
                    $st = $statusFor[$col]
                    $row[$col] = if ($n -eq 0 -and $st -and $st -notmatch 'Backed up|No data') { "0 - $st" } else { $n }
                }
                elseif ($statusFor.ContainsKey($col)) {
                    $row[$col] = $statusFor[$col]   # inventory skipped/failed: show status
                }
                else { $row[$col] = "N/A" }
            }
            [pscustomobject]$row
        }
        $logRpReport = [System.Collections.Generic.List[object]]::new()
        foreach ($e in @($expanded)) { $logRpReport.Add($e) }
    }
    #endregion

    #region Output

    #Write-Host ""
    #Write-Host "Entra ID Backup Report - $Server - $($now.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan
    #Write-Host ("Jobs: {0}  |  Backups: {1}  |  Restore points: {2}  |  Stale/Empty: {3}" -f `
    #    $jobs.Count, $backups.Count, $rpReport.Count, @($report | Where-Object Status -ne "OK").Count)

    #Write-Host "`nJob Summary" -ForegroundColor Cyan
    #$report | Format-Table JobName, TenantName, Repository, RestorePoints, OldestPoint, Status -AutoSize | Out-Host

    #Write-Host "Restore Points" -ForegroundColor Cyan
    #$rpCols = @('PointNumber', 'CreationTime')
    #$rpCols += @($typeColumns.Values) + @($sessionLogColumns.Values) + 'TotalItems'
    #$rpReport | Format-Table $rpCols -AutoSize -GroupBy JobName | Out-Host

    # Default HTML report name when -HtmlPath isn't given
    if (-not $HtmlPath) {
        $scope = switch ($ReportType) {
            'Both'   { 'Tenant and Log' }
            'Tenant' { 'Tenant' }
            'Logs'   { 'Log' }
        }
        $HtmlPath = Join-Path (Get-Location).Path ("Entra ID Report - {0} - {1:yyyy-MM-dd HHmm}.html" -f $scope, (Get-Date))
    }

    if ($HtmlPath) {
        $css = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; }
h1 { color: #00B336; margin: 0 0 6px 0; }
.report-info { margin: 0; padding-bottom: 8px; border-bottom: 3px solid #00B336; }
h3 { color: #005F4B; margin-top: 24px; }
table { border-collapse: collapse; width: 100%; }
th { background: #005F4B; color: #fff; padding: 6px; text-align: left; }
td { border-bottom: 1px solid #ddd; padding: 6px; }
tr:nth-child(even) { background: #f4f4f4; }

/* One block per tenant */
.tenant { margin-top: 24px; padding-top: 4px; border-top: 3px solid #00B336; }
.tenant.first { margin-top: 12px; padding-top: 0; border-top: none; }
.jobs h3 { margin-top: 8px; }
.note { color: #8a6d00; font-style: italic; margin: 4px 0 0 0; }

/* Jobs section: lighter Veeam green so it stands apart from restore point tables */
.jobs h3 { color: #00894B; }
.jobs th { background: #00894B; }
.jobs tr:nth-child(even) { background: #eef7f1; }
.jobtype-tenant { font-weight: 600; }
.jobtype-log    { font-weight: 600; }
</style>
"@
        $headerMap = @{
            PointNumber     = '#'
            IsLatest        = 'Latest'
            CreationTime    = 'Created'
            TotalItems      = 'Total Objects'
        }
        function Get-HtmlSelect {
            param([string[]]$Columns)
            foreach ($c in $Columns) {
                if ($headerMap.ContainsKey($c)) { @{ Name = $headerMap[$c]; Expression = [scriptblock]::Create("`$_.'$c'") } }
                else { $c }
            }
        }
        function ConvertTo-HtmlTable {
            # HTML table for a set of rows, or a short message when there are none
            param($Rows, $Select, [string]$Heading, [string]$Tag = 'h3', [string]$Empty = 'None found.')
            $Rows = @($Rows)
            if ($Rows.Count -eq 0) { return "<$Tag>$Heading</$Tag><p>$Empty</p>" }
            $Rows | Select-Object $Select | ConvertTo-Html -Fragment -PreContent "<$Tag>$Heading</$Tag>" | Out-String
        }
        function Get-TenantKey { param($Name) if ("$Name".Trim()) { "$Name".Trim().ToLowerInvariant() } else { '~unknown' } }

        # Columns (tenant name is dropped from tables; it's in the heading)
        $rpHtmlCols = @('PointNumber', 'IsLatest', 'CreationTime')
        $rpHtmlCols += @($typeColumns.Values) + @($sessionLogColumns.Values) + 'TotalItems'
        $rpHtmlSelect     = Get-HtmlSelect $rpHtmlCols
        $logRpHtmlSelect  = Get-HtmlSelect (@('PointNumber', 'IsLatest', 'CreationTime') + @($logTypeColumns))
        $summarySelect    = if ($report.Count)    { @($report[0].PSObject.Properties.Name    | Where-Object { $_ -ne 'Tenant Name' }) } else { @() }
        $logSummarySelect = if ($logReport.Count) { @($logReport[0].PSObject.Properties.Name | Where-Object { $_ -ne 'Tenant Name' }) } else { @() }

        # Every tenant that appears in either half of the report, A-Z, unknown last
        $tenantNames = [ordered]@{}
        $allNames = @()
        if ($includeTenant) { $allNames += @($report    | ForEach-Object { $_.'Tenant Name' }) }
        if ($includeLogs)   { $allNames += @($logReport | ForEach-Object { $_.'Tenant Name' }) }
        foreach ($n in ($allNames | Sort-Object { if ("$_".Trim()) { "$_" } else { [char]0xFFFF } })) {
            $k = Get-TenantKey $n
            if (-not $tenantNames.Contains($k)) { $tenantNames[$k] = if ("$n".Trim()) { "$n".Trim() } else { 'Unknown Tenant' } }
        }

        # Combined jobs table: one column set for both job types
        $jobCols = @('Job Type', 'Job Name', 'Description', 'Scheduled', 'Retention', 'Encrypted',
                     'Repository', 'Secondary Repository', 'Restore Points', 'Oldest Point', 'Last Run', 'Status')
        function ConvertTo-JobRow {
            param($Row, [string]$Type)
            $o = [ordered]@{}
            foreach ($c in $jobCols) {
                $o[$c] = switch ($c) {
                    'Job Type'  { $Type }
                    default     { if ($Row.PSObject.Properties[$c]) { $Row.$c } else { "" } }
                }
            }
            [pscustomobject]$o
        }

        $sections = @()
        if ($tenantNames.Count -eq 0) { $sections += "<p>No Entra ID backup jobs found.</p>" }

        $firstTenant = $true
        foreach ($k in $tenantNames.Keys) {
            $tn = $tenantNames[$k]
            $sections += if ($firstTenant) { "<div class='tenant first'>" } else { "<div class='tenant'>" }
            $firstTenant = $false

            # --- Jobs (tenant + log), lighter green
            $jobRows = @()
            if ($includeTenant) {
                $jobRows += @($report | Where-Object { (Get-TenantKey $_.'Tenant Name') -eq $k } |
                    ForEach-Object { ConvertTo-JobRow -Row $_ -Type 'Tenant Backup' })
            }
            if ($includeLogs) {
                $jobRows += @($logReport | Where-Object { (Get-TenantKey $_.'Tenant Name') -eq $k } |
                    ForEach-Object { ConvertTo-JobRow -Row $_ -Type 'Log Backup' })
            }
            # Drop columns that are empty for every job in this tenant
            $usedCols = @($jobCols | Where-Object { $c = $_; @($jobRows | Where-Object { "$($_.$c)" -ne '' }).Count })
            $jobsHtml = ConvertTo-HtmlTable -Rows $jobRows -Select $usedCols -Heading "$tn - Jobs" -Empty 'No jobs for this tenant.'
            $jobsHtml = $jobsHtml -replace '<td>Tenant Backup</td>', "<td class='jobtype-tenant'>Tenant Backup</td>" `
                                  -replace '<td>Log Backup</td>',    "<td class='jobtype-log'>Log Backup</td>"
            $sections += "<div class='jobs'>$jobsHtml</div>"

            # --- Tenant backup restore points
            if ($includeTenant) {
                $tPoints = @($rpReport | Where-Object { (Get-TenantKey $_.TenantName) -eq $k })
                $byJob   = @($tPoints | Group-Object JobName)
                if ($byJob.Count -le 1) {
                    $sections += ConvertTo-HtmlTable -Rows $tPoints -Select $rpHtmlSelect `
                        -Heading "$tn - Tenant Backup Restore Points ($($tPoints.Count))" -Empty 'No restore points.'
                } else {
                    foreach ($g in $byJob) {
                        $sections += ConvertTo-HtmlTable -Rows $g.Group -Select $rpHtmlSelect `
                            -Heading "$tn - Tenant Backup Restore Points: $($g.Name) ($($g.Count))"
                    }
                }
            }

            # --- Log backup restore points
            if ($includeLogs) {
                $lJobs   = @($logReport | Where-Object { (Get-TenantKey $_.'Tenant Name') -eq $k })
                $lPoints = @($logRpReport | Where-Object { $lJobs.'Job Name' -contains $_.JobName })
                if ($lJobs.Count -le 1) {
                    $sections += ConvertTo-HtmlTable -Rows $lPoints -Select $logRpHtmlSelect `
                        -Heading "$tn - Log Restore Point Backups ($($lPoints.Count))" -Empty 'No log restore points.'
                    if ($lJobs.Count -eq 1 -and $lJobs[0].'File Inventory' -and $lJobs[0].'File Inventory' -ne 'OK') {
                        $sections += "<p class='note'>Log file counts unavailable: $($lJobs[0].'File Inventory')</p>"
                    }
                } else {
                    foreach ($lj in $lJobs) {
                        $jp = @($lPoints | Where-Object { $_.JobName -eq $lj.'Job Name' })
                        $sections += ConvertTo-HtmlTable -Rows $jp -Select $logRpHtmlSelect `
                            -Heading "$tn - Log Restore Point Backups: $($lj.'Job Name') ($($jp.Count))" -Empty 'No log restore points.'
                    }
                }
            }

            $sections += "</div>"
        }

        $html = ConvertTo-Html -Head $css `
            -PreContent "<h1>Entra ID Backup Report</h1><p class='report-info'>Server: $Server<br>Generated: $now</p>" `
            -PostContent $sections | Out-String
        # ConvertTo-Html with no input emits an empty <table>; it adds a gap under the header
        $html = $html -replace '(?s)<table>\s*</table>', ''
        $html | Out-File -FilePath $HtmlPath -Encoding UTF8
        Write-Host "HTML saved to $HtmlPath" -ForegroundColor Green
    }

    if ($PassThru) {
        [pscustomobject]@{
            Summary          = $report
            RestorePoints    = $rpReport.ToArray()
            LogJobs          = $logReport
            LogRestorePoints = $logRpReport.ToArray()
        }
    }
    #endregion
}
finally {
    if ($weConnected) { Disconnect-VBRServer }
} 
