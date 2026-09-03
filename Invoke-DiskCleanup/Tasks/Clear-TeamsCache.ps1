# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1

<#
.SYNOPSIS
    Clears Microsoft Teams cache folders for every local user profile.

.DESCRIPTION
    Opt-in disk reclaim task, split out of Invoke-DiskCleanup.ps1. Clears cache
    subfolders for both classic Teams (AppData\Roaming\Microsoft\Teams) and the new
    MSTeams package. Skips itself entirely if Teams is running.

    Unlike the other task scripts this one carries the full deletion engine, because it
    walks user profile trees: the path safety gate, the protected-extension rule, and the
    reparse-point-safe directory walk.

    SAFETY MODEL (same as the parent script)
      - Allow-list only; every path is explicitly named.
      - Every path passes Test-SafeCleanupPath before deletion.
      - Reparse points are never traversed or deleted.
      - Protected extensions are never deleted, wherever found.
      - Locked files fail closed - counted as skipped, never force-unlocked.

    WHAT THIS TRADES AWAY
      May force a Teams re-login on some builds. Cache only - no message history.

    Self-contained by design: no shared library, so it can be deployed to VSA on its own.

    Outputs
      C:\INS-Temp\Logs\DiskCleanup_TeamsCache.log
      C:\INS-Temp\Logs\DiskCleanup_TeamsCache_Summary.json
      C:\INS-Temp\Logs\ScriptResult_DiskCleanup_TeamsCache.txt

.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.0
    Context : SYSTEM (required - enumerates all user profiles)
    Exit    : 0 = success (including a skipped task, which is logged), 1 = fatal error

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Default 45.

.PARAMETER ProtectedExtensions
    File extensions that are never deleted, wherever they are found.

.PARAMETER Delete
    Actually delete. Omitted, the script measures reclaimable space and deletes
    nothing - report-only is the default.
#>

[CmdletBinding()]
param(
    [int]$MaxRuntimeMinutes        = 45,
    [string[]]$ProtectedExtensions = @('.pst','.ost','.nst','.edb','.vhd','.vhdx','.avhdx',
                                       '.vhdpmem','.kdbx','.pfx','.p12','.key','.psafe3','.bak'),
    [switch]$Delete
)

# Report-only is the default; -Delete opts in to actually removing anything. Everything
# below reads $ReportOnly, so derive it once here rather than inverting at each use.
$ReportOnly = -not $Delete

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_TeamsCache'
$ScriptVersion = '1.0.0'
$LogDir        = 'C:\INS-Temp\Logs'
$LogPath       = "$LogDir\$ScriptName.log"
$SummaryPath   = "$LogDir\${ScriptName}_Summary.json"
$SystemDrive   = $env:SystemDrive

$script:Deadline    = (Get-Date).AddMinutes($MaxRuntimeMinutes)
$script:TaskResults = New-Object System.Collections.Generic.List[object]
$script:StopReason  = ''

# Diagnostics that Clear-PathAgedFiles cannot log itself: Write-Log writes to the
# success stream, which would corrupt its return value. Invoke-Task drains these.
$script:PathSkips      = New-Object System.Collections.Generic.List[string]
$script:ProtectedSkips = 0

# Paths that must never be handed to the deletion engine, even by mistake.
$script:ProtectedPaths = @(
    "$SystemDrive\", "$SystemDrive\Windows", "$SystemDrive\Windows\System32",
    "$SystemDrive\Windows\SysWOW64", "$SystemDrive\Windows\WinSxS", "$SystemDrive\Windows\Fonts",
    "$SystemDrive\Windows\Installer", "$SystemDrive\Windows\Prefetch",
    "$SystemDrive\Windows\System32\config", "$SystemDrive\Windows\SoftwareDistribution",
    "$SystemDrive\Windows\SoftwareDistribution\DataStore",
    "$SystemDrive\Program Files", "$SystemDrive\Program Files (x86)",
    "$SystemDrive\Users", "$SystemDrive\Users\Public", "$SystemDrive\Users\Default",
    "$SystemDrive\ProgramData", "$SystemDrive\ProgramData\Package Cache",
    "$SystemDrive\ProgramData\Kaseya"
)

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ── Logging ────────────────────────────────────────────────────────────────────
function Invoke-LogRotation {
    param([string]$LogFilePath, [long]$MaxSizeBytes = 5MB)
    try {
        if (Test-Path -LiteralPath $LogFilePath) {
            if ((Get-Item -LiteralPath $LogFilePath).Length -gt $MaxSizeBytes) {
                $archive = $LogFilePath -replace '\.log$', "-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                Rename-Item -LiteralPath $LogFilePath -NewName (Split-Path $archive -Leaf) -Force
            }
        }
        Get-ChildItem -LiteralPath (Split-Path $LogFilePath) -Filter "$ScriptName-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    if ($Level -eq 'ERROR') { Write-Error $Message -ErrorAction Continue }
    else                    { Write-Output $line }
}

function Write-VSAResult {
    param([string]$Result)
    if ($Result.Length -gt 480) { $Result = $Result.Substring(0,477) + '...' }
    try { $Result | Out-File -FilePath "$LogDir\ScriptResult_$ScriptName.txt" -Encoding UTF8 -Force } catch { }
    Write-Output $Result
}

# ── Utility ────────────────────────────────────────────────────────────────────
function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$([math]::Round($Bytes,0)) B"
}

function Get-FreeSpaceBytes {
    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$SystemDrive'" -ErrorAction Stop
        return [double]$d.FreeSpace
    } catch {
        return [double]((Get-PSDrive -Name $SystemDrive.TrimEnd(':')).Free)
    }
}

function Test-Deadline {
    if ((Get-Date) -ge $script:Deadline) {
        if (-not $script:StopReason) { $script:StopReason = 'runtime limit reached' }
        return $true
    }
    return $false
}

function Test-ProcessRunning {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Add-TaskResult {
    param(
        [string]$Task,
        [double]$Bytes = 0,
        [int]$Items = 0,
        [int]$Failed = 0,
        [string]$Status = 'OK',
        [string]$Detail = ''
    )
    $script:TaskResults.Add([PSCustomObject]@{
        Task = $Task; Bytes = $Bytes; Items = $Items; Failed = $Failed
        Status = $Status; Detail = $Detail
    })
    $verb = if ($ReportOnly) { 'Reclaimable' } else { 'Reclaimed' }
    Write-Log ("{0}: {1} {2} from {3} items ({4} skipped/locked). {5}" -f `
               $Task, $verb, (Format-Bytes $Bytes), $Items, $Failed, $Detail)
}

# ── Path Safety Gate ───────────────────────────────────────────────────────────
function Test-SafeCleanupPath {
    <#
        Returns $true only if the path is a real, non-reparse directory that is safe to clean.
        Blocks: drive roots, protected system folders, parents of protected folders,
                anything under C:\Users that is not inside AppData.

        Pure predicate - deliberately does NOT log. Write-Log writes to the success
        stream, so logging here would return @(log line, $false) to the caller, and
        "-not" on that non-empty array evaluates to $false, silently bypassing this
        gate. The rejection reason travels back through -Reason instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ref]$Reason
    )

    $Reason.Value = ''

    if ([string]::IsNullOrWhiteSpace($Path)) { $Reason.Value = 'empty path'; return $false }

    try   { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { $Reason.Value = "unparseable: $Path"; return $false }

    if ($full.Length -lt 4)         { $Reason.Value = "too shallow: $full"; return $false }
    if ($full -match '^[A-Za-z]:$') { $Reason.Value = "drive root: $full";  return $false }

    foreach ($p in $script:ProtectedPaths) {
        if ($full -ieq $p.TrimEnd('\')) {
            $Reason.Value = "protected: $full"; return $false
        }
    }

    # Never allow a path that is an ancestor of a protected path.
    foreach ($p in $script:ProtectedPaths) {
        $prot = $p.TrimEnd('\')
        if ($prot.Length -gt $full.Length -and $prot.StartsWith("$full\", 'OrdinalIgnoreCase')) {
            $Reason.Value = "ancestor of protected path ${prot}: $full"; return $false
        }
    }

    # Inside a user profile, only AppData is ever in scope.
    if ($full -imatch "^$([regex]::Escape("$SystemDrive\Users"))\\") {
        if ($full -inotmatch '\\AppData\\(Local|LocalLow|Roaming)(\\|$)') {
            $Reason.Value = "user profile data outside AppData: $full"; return $false
        }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        $Reason.Value = "not a directory: $full"; return $false
    }

    try {
        $item = Get-Item -LiteralPath $full -Force
        if (([System.IO.FileAttributes]::ReparsePoint -band $item.Attributes) -eq [System.IO.FileAttributes]::ReparsePoint) {
            $Reason.Value = "reparse point: $full"; return $false
        }
    } catch {
        $Reason.Value = "unreadable: $full"; return $false
    }

    return $true
}

# ── Deletion Engine ────────────────────────────────────────────────────────────
function Clear-PathAgedFiles {
    <#
        Walks $Path manually (never following reparse points), deletes files whose
        LastWriteTime is older than $OlderThanDays, and reports bytes/items. Honors
        -ReportOnly and the deadline.

        Does NOT log - it returns $result, and Write-Log writes to the success stream.
        Diagnostics go to $script:PathSkips / $script:ProtectedSkips, which Invoke-Task
        drains once the task has finished.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0,
        [string[]]$IncludeFilter = @(),      # wildcard file name filters; empty = all files
        [switch]$RemoveEmptyDirs
    )

    $result = [PSCustomObject]@{
        Bytes = [double]0; Items = 0; Failed = 0; Skipped = $false
        SkipReason = ''; ProtectedSkipped = 0
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Skipped = $true; $result.SkipReason = "path not present: $Path"
        return $result
    }

    $why = ''
    if (-not (Test-SafeCleanupPath -Path $Path -Reason ([ref]$why))) {
        $result.Skipped = $true; $result.SkipReason = $why
        $script:PathSkips.Add($why)
        return $result
    }

    $cutoff = (Get-Date).AddDays(-[math]::Abs($OlderThanDays))
    $stack  = New-Object System.Collections.Stack
    $dirs   = New-Object System.Collections.Generic.List[string]
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        if (Test-Deadline) { break }
        $current = $stack.Pop()

        $entries = $null
        try   { $entries = (New-Object System.IO.DirectoryInfo($current)).GetFileSystemInfos() }
        catch { continue }   # ACL-denied or vanished; leave it alone

        foreach ($entry in $entries) {
            try {
                # Never traverse or delete junctions/symlinks.
                if (([System.IO.FileAttributes]::ReparsePoint -band $entry.Attributes) -eq [System.IO.FileAttributes]::ReparsePoint) { continue }

                if ($entry -is [System.IO.DirectoryInfo]) {
                    $stack.Push($entry.FullName)
                    if ($RemoveEmptyDirs) { $dirs.Add($entry.FullName) }
                    continue
                }

                if ($entry.LastWriteTime -ge $cutoff) { continue }
                if ($ProtectedExtensions -contains $entry.Extension.ToLower()) {
                    $result.ProtectedSkipped++
                    $script:ProtectedSkips++
                    continue
                }
                if (([System.IO.FileAttributes]::System -band $entry.Attributes) -eq [System.IO.FileAttributes]::System) { continue }

                if ($IncludeFilter.Count -gt 0) {
                    $match = $false
                    foreach ($f in $IncludeFilter) { if ($entry.Name -like $f) { $match = $true; break } }
                    if (-not $match) { continue }
                }

                $size = [double]$entry.Length
                if ($ReportOnly) {
                    $result.Bytes += $size; $result.Items++
                } else {
                    try {
                        Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
                        $result.Bytes += $size; $result.Items++
                    } catch {
                        $result.Failed++     # in use / locked / denied - left in place by design
                    }
                }
            } catch {
                $result.Failed++
            }
        }
    }

    # Prune directories that are now empty (deepest first). Never removes $Path itself.
    if ($RemoveEmptyDirs -and -not $ReportOnly) {
        foreach ($d in ($dirs | Sort-Object -Property Length -Descending)) {
            try {
                if ((New-Object System.IO.DirectoryInfo($d)).GetFileSystemInfos().Count -eq 0) {
                    Remove-Item -LiteralPath $d -Force -ErrorAction Stop
                }
            } catch { }
        }
    }

    return $result
}

function Get-UserProfilePath {
    <#
        All non-special local user profiles.

        Does not log - it returns a collection, and Write-Log output would be prepended
        to it, so callers would treat log lines as profile paths.
    #>
    param([Parameter(Mandatory)][ref]$FallbackReason)

    $FallbackReason.Value = ''
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
            ForEach-Object { $paths.Add($_.LocalPath) }
    } catch {
        $FallbackReason.Value = "$_"
        Get-ChildItem -LiteralPath "$SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
            ForEach-Object { $paths.Add($_.FullName) }
    }
    return $paths
}

function Invoke-Task {
    <#
        Isolates the task so a failure still produces a summary and a result string.
        Retained (rather than inlining the body) so the lifted task code keeps its
        original 'return' semantics - at script scope, return would skip the summary.

        Returns nothing, which is why it is safe for this function to log - it is where
        the diagnostics collected by the non-logging engine functions get reported.
    #>
    param([string]$Name, [scriptblock]$Action)
    try {
        Write-Log "--- Task start: $Name"
        & $Action
    } catch {
        Write-Log "Task '$Name' failed: $_" -Level WARN
        Add-TaskResult -Task $Name -Status 'FAILED' -Detail "$_"
    } finally {
        while ($script:PathSkips.Count -gt 0) {
            Write-Log "Path rejected ($($script:PathSkips[0]))" -Level WARN
            $script:PathSkips.RemoveAt(0)
        }
        if ($script:ProtectedSkips -gt 0) {
            Write-Log "Task '$Name': $($script:ProtectedSkips) file(s) preserved by protected-extension rule."
            $script:ProtectedSkips = 0
        }
    }
}

# ══ MAIN ═══════════════════════════════════════════════════════════════════════
try {
    Invoke-LogRotation -LogFilePath $LogPath
    Write-Log "=== $ScriptName v$ScriptVersion START ==="

    try { (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    catch { Write-Log "Could not lower process priority: $_" -Level WARN }

    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - no files will be deleted ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    Write-Log ("Free space before: {0}" -f (Format-Bytes $freeBefore))

    $profileFallback = ''
    $profilePaths = Get-UserProfilePath -FallbackReason ([ref]$profileFallback)
    if ($profileFallback) {
        Write-Log "Win32_UserProfile enumeration failed, used directory listing: $profileFallback" -Level WARN
    }
    Write-Log "User profiles in scope: $($profilePaths.Count)"

    Invoke-Task -Name 'TeamsCache' -Action {
        if (Test-ProcessRunning -Names @('Teams','ms-teams')) {
            Add-TaskResult -Task 'TeamsCache' -Status 'SKIPPED' -Detail 'Teams is running.'
            return
        }
        $b = [double]0; $i = 0; $f = 0
        $subs = @(
            'AppData\Roaming\Microsoft\Teams\Cache',
            'AppData\Roaming\Microsoft\Teams\GPUCache',
            'AppData\Roaming\Microsoft\Teams\Code Cache',
            'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage',
            'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs'
        )
        foreach ($p in $profilePaths) {
            foreach ($s in $subs) {
                $r = Clear-PathAgedFiles -Path (Join-Path $p $s) -OlderThanDays 0 -RemoveEmptyDirs
                $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
            }
        }
        Add-TaskResult -Task 'TeamsCache' -Bytes $b -Items $i -Failed $f
    }

    # ══ Summary ════════════════════════════════════════════════════════════════
    $freeAfter   = Get-FreeSpaceBytes
    $actualDelta = [math]::Max(0, $freeAfter - $freeBefore)
    $reportedSum = ($script:TaskResults | Measure-Object -Property Bytes -Sum).Sum
    if ($null -eq $reportedSum) { $reportedSum = 0 }

    $summary = [PSCustomObject]@{
        Script           = $ScriptName
        Version          = $ScriptVersion
        Computer         = $env:COMPUTERNAME
        TimestampUtc     = (Get-Date).ToUniversalTime().ToString('s')
        ReportOnly       = [bool]$ReportOnly
        FreeBeforeGB     = [math]::Round($freeBefore / 1GB, 2)
        FreeAfterGB      = [math]::Round($freeAfter / 1GB, 2)
        ReclaimedGB      = [math]::Round($reportedSum / 1GB, 2)
        FreeSpaceDeltaGB = [math]::Round($actualDelta / 1GB, 2)
        StoppedEarly     = [bool]$script:StopReason
        StopReason       = $script:StopReason
        Tasks            = $script:TaskResults
    }
    try { $summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $SummaryPath -Encoding UTF8 -Force } catch { }

    Write-Log ("Free space after: {0} (delta {1})" -f (Format-Bytes $freeAfter), (Format-Bytes $actualDelta))
    if ($script:StopReason) { Write-Log "Run stopped early: $($script:StopReason)" -Level WARN }
    Write-Log "=== $ScriptName COMPLETE ==="

    $verb   = if ($ReportOnly) { 'Reclaimable' } else { 'Reclaimed' }
    $first  = $script:TaskResults | Select-Object -First 1
    $detail = if ($first) { "$($first.Status). $($first.Detail)" } else { 'nothing to do' }
    Write-VSAResult ("SUCCESS: {0} {1}. {2}" -f $verb, (Format-Bytes $reportedSum), $detail)
    exit 0
}
catch {
    Write-Log "Unhandled error: $_" -Level ERROR
    Write-VSAResult "FAILURE: $_"
    exit 1
}
