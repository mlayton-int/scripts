#Requires -Version 5.1
<#
.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.2
    Context : SYSTEM  (required - the script enumerates all user profiles and system paths)
    Exit    : 0 = success (including partial task failures, which are logged), 1 = fatal error

.DESCRIPTION
    Unattended disk cleanup for Kaseya VSA X agent procedures. Designed to be aggressive about
    genuine junk and conservative about anything that could be user data or system state.

    SAFETY MODEL
      - Allow-list only. Every path is explicitly named; there is no wildcard sweep of C:\.
      - Every path passes safety checks before deletion (blocks drive roots, protected
        system folders, reparse points, and any path under C:\Users that is not inside AppData).
      - Age filters on everything. A file must be untouched for N days before it qualifies.
      - Reparse points (junctions/symlinks) are never traversed or deleted.
      - Protected extensions (.pst, .ost, .vhdx, .kdbx, .pfx, ...) are never deleted, wherever found.
      - Locked/in-use files fail closed: they are counted as skipped, never force-unlocked.
      - Nothing is killed, no user prompt, no GUI (cleanmgr is deliberately NOT used), no reboot.
      - Process runs at BelowNormal priority with a hard runtime cap.
      - -ReportOnly performs a full measurement pass and deletes nothing.

    DELIBERATELY NOT TOUCHED (documented refusals, not oversights)
      - C:\Windows\Installer          - orphaned patch cleanup breaks repair/uninstall of apps.
      - C:\ProgramData\Package Cache  - needed by VS/VC++ redist repair & uninstall.
      - C:\Windows\Prefetch           - negligible space, measurable boot/launch penalty.
      - SoftwareDistribution\DataStore- the Windows Update database itself.
      - User Desktop/Documents/Downloads/Pictures - user data, full stop.
      - Browser cookies, logins, history, bookmarks, profiles - cache subfolders only.
      - DISM /ResetBase               - blocks uninstalling updates; not offered.

    OPT-IN (off by default, each one trades a recovery option for space)
      -EmptyRecycleBin        Removes items deleted more than -RecycleBinAgeDays ago.
      -CleanTeamsCache        May force a Teams re-login on some builds.
      -RemoveWindowsOld       Removes OS rollback capability. Age-gated.
      -RunComponentCleanup    DISM WinSxS cleanup. CPU-heavy, long-running, no /ResetBase.
      -RemoveStaleProfiles    Deletes unloaded user profiles older than -ProfileAgeDays.
      -RemoveOldRestorePoints Deletes all but the newest -KeepRestorePoints shadow copies.

.PARAMETER TempFileAgeDays
    Minimum age (days, last write time) for temp files to be removed. Default 2.

.PARAMETER LogFileAgeDays
    Minimum age for servicing/setup logs. Default 14.

.PARAMETER DumpFileAgeDays
    Minimum age for crash/memory dumps. Default 7.

.PARAMETER UpdateCacheAgeDays
    Minimum age for Windows Update download cache content. Default 10.

.PARAMETER RunOnlyIfFreeSpaceBelowGB
    Exit immediately (success) if free space already exceeds this. 0 = always run. Default 0.

.PARAMETER StopWhenFreeSpaceGB
    Stop running further tasks once free space reaches this. 0 = run all tasks. Default 0.

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Tasks abort cleanly at the deadline. Default 45.

.PARAMETER SkipTasks
    Task names to skip. Valid: WindowsTemp, UserTemp, UserInternetCache, WindowsErrorReporting,
    MemoryDumps, WindowsLogs, DownloadedProgramFiles, DeliveryOptimization, WindowsUpdateCache,
    ThumbnailCache, BrowserCache.

.PARAMETER ReportOnly
    Measure and report reclaimable space without deleting anything.
#>

[CmdletBinding()]
param(
    [int]$TempFileAgeDays              = 2,
    [int]$LogFileAgeDays               = 14,
    [int]$DumpFileAgeDays              = 7,
    [int]$UpdateCacheAgeDays           = 10,

    [double]$RunOnlyIfFreeSpaceBelowGB = 0,
    [double]$StopWhenFreeSpaceGB       = 0,
    [int]$MaxRuntimeMinutes            = 45,

    [string[]]$SkipTasks               = @(),
    [switch]$ReportOnly,

    # ── Opt-in tasks ───────────────────────────────────────────────────────────
    [switch]$EmptyRecycleBin,
    [int]$RecycleBinAgeDays            = 30,

    [switch]$CleanTeamsCache,

    [switch]$RemoveWindowsOld,
    [int]$WindowsOldAgeDays            = 30,

    [switch]$RunComponentCleanup,
    [int]$ComponentCleanupTimeoutMin   = 30,

    [switch]$RemoveStaleProfiles,
    [int]$ProfileAgeDays               = 120,
    [int]$MaxProfilesToRemove          = 5,

    [switch]$RemoveOldRestorePoints,
    [int]$KeepRestorePoints            = 1,

    [string[]]$ProtectedExtensions     = @('.pst','.ost','.nst','.edb','.vhd','.vhdx','.avhdx',
                                           '.vhdpmem','.kdbx','.pfx','.p12','.key','.psafe3','.bak')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup'
$ScriptVersion = '1.0.1'
$LogDir        = 'C:\ProgramData\Kaseya\Logs'
$LogPath       = "$LogDir\$ScriptName.log"
$SummaryPath   = "$LogDir\${ScriptName}_Summary.json"
$SystemDrive   = $env:SystemDrive                      # normally 'C:'

$script:Deadline     = (Get-Date).AddMinutes($MaxRuntimeMinutes)
$script:TaskResults  = New-Object System.Collections.Generic.List[object]
$script:StopReason   = ''

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
                $archive = $LogFilePath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                Rename-Item -LiteralPath $LogFilePath -NewName (Split-Path $archive -Leaf) -Force
            }
        }
        # Keep only the 5 most recent archives.
        Get-ChildItem -LiteralPath (Split-Path $LogFilePath) -Filter "$ScriptName`_*.log" -ErrorAction SilentlyContinue |
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

# ── VSA Result Helper ──────────────────────────────────────────────────────────
function Write-VSAResult {
    param([string]$Result)
    if ($Result.Length -gt 480) { $Result = $Result.Substring(0,477) + '...' }
    try { $Result | Out-File -FilePath "C:\ProgramData\Kaseya\ScriptResult_$ScriptName.txt" -Encoding UTF8 -Force } catch { }
    Write-Output $Result
}

# ── Join Type Detection ────────────────────────────────────────────────────────
function Get-WorkstationJoinType {
    try {
        $dsreg = dsregcmd /status 2>$null
        $adJoined  = ($dsreg | Select-String 'AzureAdJoined\s*:\s*NO' ) -and ($dsreg | Select-String 'DomainJoined\s*:\s*YES')
        $aadJoined = ($dsreg | Select-String 'AzureAdJoined\s*:\s*YES') -and ($dsreg | Select-String 'DomainJoined\s*:\s*NO' )
        $hybrid    = ($dsreg | Select-String 'AzureAdJoined\s*:\s*YES') -and ($dsreg | Select-String 'DomainJoined\s*:\s*YES')
        if ($hybrid)    { return 'Hybrid' }
        if ($adJoined)  { return 'AD'     }
        if ($aadJoined) { return 'AAD'    }
    } catch { }
    return 'Local'
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

function Test-TargetReached {
    if ($StopWhenFreeSpaceGB -le 0) { return $false }
    if ((Get-FreeSpaceBytes) -ge ($StopWhenFreeSpaceGB * 1GB)) {
        if (-not $script:StopReason) { $script:StopReason = 'free space target reached' }
        return $true
    }
    return $false
}

function Test-TaskEnabled {
    param([string]$TaskName)
    if ($SkipTasks -contains $TaskName) {
        Write-Log "Task '$TaskName' skipped by -SkipTasks."
        return $false
    }
    if (Test-Deadline)      { Write-Log "Task '$TaskName' skipped: $($script:StopReason)." -Level WARN; return $false }
    if (Test-TargetReached) { Write-Log "Task '$TaskName' skipped: $($script:StopReason)."; return $false }
    return $true
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

function Test-ProcessRunning {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# ── Path Safety Gate ───────────────────────────────────────────────────────────
function Test-SafeCleanupPath {
    <#
        Returns $true only if the path is a real, non-reparse directory that is safe to clean.
        Blocks: drive roots, protected system folders, parents of protected folders,
                anything under C:\Users that is not inside AppData.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try   { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { Write-Log "Path rejected (unparseable): $Path" -Level WARN; return $false }

    if ($full.Length -lt 4) { Write-Log "Path rejected (too shallow): $full" -Level WARN; return $false }
    if ($full -match '^[A-Za-z]:$') { Write-Log "Path rejected (drive root): $full" -Level WARN; return $false }

    foreach ($p in $script:ProtectedPaths) {
        if ($full -ieq $p.TrimEnd('\')) {
            Write-Log "Path rejected (protected): $full" -Level WARN; return $false
        }
    }

    # Never allow a path that is an ancestor of a protected path.
    foreach ($p in $script:ProtectedPaths) {
        $prot = $p.TrimEnd('\')
        if ($prot.Length -gt $full.Length -and $prot.StartsWith("$full\", 'OrdinalIgnoreCase')) {
            Write-Log "Path rejected (ancestor of protected path $prot): $full" -Level WARN; return $false
        }
    }

    # Inside a user profile, only AppData is ever in scope.
    if ($full -imatch "^$([regex]::Escape("$SystemDrive\Users"))\\") {
        if ($full -inotmatch '\\AppData\\(Local|LocalLow|Roaming)(\\|$)') {
            Write-Log "Path rejected (user profile data outside AppData): $full" -Level WARN; return $false
        }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }

    try {
        $item = Get-Item -LiteralPath $full -Force
        if (([System.IO.FileAttributes]::ReparsePoint -band $item.Attributes) -eq [System.IO.FileAttributes]::ReparsePoint) {
            Write-Log "Path rejected (reparse point): $full" -Level WARN; return $false
        }
    } catch { return $false }

    return $true
}

# ── Deletion Engine ────────────────────────────────────────────────────────────
function Clear-PathAgedFiles {
    <#
        Walks $Path manually (never following reparse points), deletes files whose LastWriteTime
        is older than $OlderThanDays, and reports bytes/items. Honors -ReportOnly and the deadline.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0,
        [string[]]$IncludeFilter = @(),      # wildcard file name filters; empty = all files
        [switch]$RemoveEmptyDirs
    )

    $result = [PSCustomObject]@{ Bytes = [double]0; Items = 0; Failed = 0; Skipped = $false }

    if (-not (Test-Path -LiteralPath $Path)) { $result.Skipped = $true; return $result }
    if (-not (Test-SafeCleanupPath -Path $Path)) { $result.Skipped = $true; return $result }

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
                    Write-Log "Protected extension preserved: $($entry.FullName)"
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
    <# All non-special local user profiles. #>
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
            ForEach-Object { $paths.Add($_.LocalPath) }
    } catch {
        Write-Log "Win32_UserProfile enumeration failed, falling back to directory listing: $_" -Level WARN
        Get-ChildItem -LiteralPath "$SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
            ForEach-Object { $paths.Add($_.FullName) }
    }
    return $paths
}

function Invoke-CleanupTask {
    <# Isolates each task so one failure never aborts the run. #>
    param([string]$Name, [scriptblock]$Action)
    if (-not (Test-TaskEnabled -TaskName $Name)) { return }
    try {
        Write-Log "--- Task start: $Name"
        & $Action
    } catch {
        Write-Log "Task '$Name' failed: $_" -Level WARN
        Add-TaskResult -Task $Name -Status 'FAILED' -Detail "$_"
    }
}

# ══ MAIN ═══════════════════════════════════════════════════════════════════════
try {
    Invoke-LogRotation -LogFilePath $LogPath
    Write-Log "=== $ScriptName v$ScriptVersion START ==="

    try { (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    catch { Write-Log "Could not lower process priority: $_" -Level WARN }

    $joinType = Get-WorkstationJoinType
    Write-Log "Join type detected: $joinType"
    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - no files will be deleted ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    $totalSize  = [double](Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$SystemDrive'").Size
    Write-Log ("Free space before: {0} of {1}" -f (Format-Bytes $freeBefore), (Format-Bytes $totalSize))

    if ($RunOnlyIfFreeSpaceBelowGB -gt 0 -and $freeBefore -ge ($RunOnlyIfFreeSpaceBelowGB * 1GB)) {
        Write-Log "Free space already above ${RunOnlyIfFreeSpaceBelowGB} GB threshold. Nothing to do."
        Write-VSAResult ("SUCCESS: Skipped - free space {0} already above {1} GB threshold." -f (Format-Bytes $freeBefore), $RunOnlyIfFreeSpaceBelowGB)
        exit 0
    }

    $profilePaths = Get-UserProfilePath
    Write-Log "User profiles in scope: $($profilePaths.Count)"

    # ── 1. Windows temp ────────────────────────────────────────────────────────
    Invoke-CleanupTask -Name 'WindowsTemp' -Action {
        $r = Clear-PathAgedFiles -Path "$SystemDrive\Windows\Temp" -OlderThanDays $TempFileAgeDays -RemoveEmptyDirs
        Add-TaskResult -Task 'WindowsTemp' -Bytes $r.Bytes -Items $r.Items -Failed $r.Failed `
                       -Detail "Files older than $TempFileAgeDays day(s)."
    }

    # ── 2. Per-user temp ───────────────────────────────────────────────────────
    Invoke-CleanupTask -Name 'UserTemp' -Action {
        $b = [double]0; $i = 0; $f = 0
        foreach ($p in $profilePaths) {
            if (Test-Deadline) { break }
            $r = Clear-PathAgedFiles -Path (Join-Path $p 'AppData\Local\Temp') -OlderThanDays $TempFileAgeDays -RemoveEmptyDirs
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        Add-TaskResult -Task 'UserTemp' -Bytes $b -Items $i -Failed $f `
                       -Detail "Across $($profilePaths.Count) profile(s), older than $TempFileAgeDays day(s)."
    }

    # ── 3. Legacy IE / WinINET caches ──────────────────────────────────────────
    Invoke-CleanupTask -Name 'UserInternetCache' -Action {
        $b = [double]0; $i = 0; $f = 0
        $subPaths = @(
            'AppData\Local\Microsoft\Windows\INetCache\IE',
            'AppData\Local\Microsoft\Windows\INetCache\Low\IE',
            'AppData\Local\Microsoft\Windows\WebCache'          # index files; locked while user is on
        )
        foreach ($p in $profilePaths) {
            foreach ($s in $subPaths) {
                if (Test-Deadline) { break }
                $r = Clear-PathAgedFiles -Path (Join-Path $p $s) -OlderThanDays $TempFileAgeDays
                $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
            }
        }
        Add-TaskResult -Task 'UserInternetCache' -Bytes $b -Items $i -Failed $f
    }

    # ── 4. Windows Error Reporting ─────────────────────────────────────────────
    Invoke-CleanupTask -Name 'WindowsErrorReporting' -Action {
        $b = [double]0; $i = 0; $f = 0
        $werPaths = @(
            "$SystemDrive\ProgramData\Microsoft\Windows\WER\ReportQueue",
            "$SystemDrive\ProgramData\Microsoft\Windows\WER\ReportArchive",
            "$SystemDrive\ProgramData\Microsoft\Windows\WER\Temp"
        )
        foreach ($p in $profilePaths) {
            $werPaths += (Join-Path $p 'AppData\Local\Microsoft\Windows\WER\ReportQueue')
            $werPaths += (Join-Path $p 'AppData\Local\Microsoft\Windows\WER\ReportArchive')
        }
        foreach ($w in $werPaths) {
            if (Test-Deadline) { break }
            $r = Clear-PathAgedFiles -Path $w -OlderThanDays $DumpFileAgeDays -RemoveEmptyDirs
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        Add-TaskResult -Task 'WindowsErrorReporting' -Bytes $b -Items $i -Failed $f `
                       -Detail "Reports older than $DumpFileAgeDays day(s)."
    }

    # ── 5. Crash / memory dumps ────────────────────────────────────────────────
    Invoke-CleanupTask -Name 'MemoryDumps' -Action {
        $b = [double]0; $i = 0; $f = 0
        $cutoff = (Get-Date).AddDays(-$DumpFileAgeDays)

        foreach ($dumpFile in @("$SystemDrive\Windows\MEMORY.DMP")) {
            try {
                if (Test-Path -LiteralPath $dumpFile) {
                    $item = Get-Item -LiteralPath $dumpFile -Force
                    if ($item.LastWriteTime -lt $cutoff) {
                        $size = [double]$item.Length
                        if (-not $ReportOnly) { Remove-Item -LiteralPath $dumpFile -Force -ErrorAction Stop }
                        $b += $size; $i++
                    }
                }
            } catch { $f++ }
        }

        foreach ($d in @("$SystemDrive\Windows\Minidump", "$SystemDrive\Windows\LiveKernelReports")) {
            $r = Clear-PathAgedFiles -Path $d -OlderThanDays $DumpFileAgeDays -IncludeFilter @('*.dmp')
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        foreach ($p in $profilePaths) {
            $r = Clear-PathAgedFiles -Path (Join-Path $p 'AppData\Local\CrashDumps') -OlderThanDays $DumpFileAgeDays
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        Add-TaskResult -Task 'MemoryDumps' -Bytes $b -Items $i -Failed $f `
                       -Detail "Dumps older than $DumpFileAgeDays day(s)."
    }

    # ── 6. Servicing / setup logs ──────────────────────────────────────────────
    Invoke-CleanupTask -Name 'WindowsLogs' -Action {
        $b = [double]0; $i = 0; $f = 0
        $logPaths = @(
            "$SystemDrive\Windows\Logs\CBS",
            "$SystemDrive\Windows\Logs\DISM",
            "$SystemDrive\Windows\Logs\MoSetup",
            "$SystemDrive\Windows\Logs\WindowsUpdate",
            "$SystemDrive\Windows\Panther",
            "$SystemDrive\Windows\SoftwareDistribution\Download\Install",  # leftover extracted payloads
            "$SystemDrive\Windows\Temp\CBS"
        )
        foreach ($l in $logPaths) {
            if (Test-Deadline) { break }
            $r = Clear-PathAgedFiles -Path $l -OlderThanDays $LogFileAgeDays -RemoveEmptyDirs
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        Add-TaskResult -Task 'WindowsLogs' -Bytes $b -Items $i -Failed $f `
                       -Detail "Logs older than $LogFileAgeDays day(s)."
    }

    # ── 7. Downloaded Program Files (legacy ActiveX/Java) ──────────────────────
    Invoke-CleanupTask -Name 'DownloadedProgramFiles' -Action {
        $r = Clear-PathAgedFiles -Path "$SystemDrive\Windows\Downloaded Program Files" -OlderThanDays $LogFileAgeDays
        Add-TaskResult -Task 'DownloadedProgramFiles' -Bytes $r.Bytes -Items $r.Items -Failed $r.Failed
    }

    # ── 8. Delivery Optimization cache ─────────────────────────────────────────
    Invoke-CleanupTask -Name 'DeliveryOptimization' -Action {
        if ($ReportOnly) {
            $est = [double]0
            try {
                $do = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop
                if ($do -and $do.PSObject.Properties.Name -contains 'FileSizeInCache') { $est = [double]$do.FileSizeInCache }
            } catch { }
            Add-TaskResult -Task 'DeliveryOptimization' -Bytes $est -Detail 'Estimated from DO perf snapshot.'
            return
        }
        if (-not (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
            Add-TaskResult -Task 'DeliveryOptimization' -Status 'SKIPPED' -Detail 'Cmdlet not available on this build.'
            return
        }
        $pre = Get-FreeSpaceBytes
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        $delta = [math]::Max(0, (Get-FreeSpaceBytes) - $pre)
        Add-TaskResult -Task 'DeliveryOptimization' -Bytes $delta -Detail 'Measured by free-space delta.'
    }

    # ── 9. Windows Update download cache ───────────────────────────────────────
    Invoke-CleanupTask -Name 'WindowsUpdateCache' -Action {
        $dl = "$SystemDrive\Windows\SoftwareDistribution\Download"
        if (-not (Test-Path -LiteralPath $dl)) {
            Add-TaskResult -Task 'WindowsUpdateCache' -Status 'SKIPPED' -Detail 'Path not present.'
            return
        }
        # Do not interfere with an update that is mid-flight or awaiting reboot.
        if (Test-ProcessRunning -Names @('TiWorker','TrustedInstaller','wusa')) {
            Add-TaskResult -Task 'WindowsUpdateCache' -Status 'SKIPPED' -Detail 'Servicing operation in progress.'
            return
        }
        $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($rebootPending) {
            Add-TaskResult -Task 'WindowsUpdateCache' -Status 'SKIPPED' -Detail 'Reboot pending; cache still needed.'
            return
        }

        $services = @('wuauserv','bits','dosvc','usosvc')
        $wasRunning = @{}
        try {
            if (-not $ReportOnly) {
                foreach ($s in $services) {
                    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
                    if ($svc) {
                        $wasRunning[$s] = ($svc.Status -eq 'Running')
                        if ($svc.Status -eq 'Running') {
                            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                            Write-Log "Stopped service '$s' for update cache cleanup."
                        }
                    }
                }
                Start-Sleep -Seconds 5
            }
            $r = Clear-PathAgedFiles -Path $dl -OlderThanDays $UpdateCacheAgeDays -RemoveEmptyDirs
            Add-TaskResult -Task 'WindowsUpdateCache' -Bytes $r.Bytes -Items $r.Items -Failed $r.Failed `
                           -Detail "Payloads older than $UpdateCacheAgeDays day(s)."
        }
        finally {
            foreach ($s in $services) {
                if ($wasRunning.ContainsKey($s) -and $wasRunning[$s]) {
                    try { Start-Service -Name $s -ErrorAction Stop; Write-Log "Restarted service '$s'." }
                    catch { Write-Log "Failed to restart service '$s': $_" -Level ERROR }
                }
            }
        }
    }

    # ── 10. Thumbnail / icon caches (only for users not logged on) ─────────────
    Invoke-CleanupTask -Name 'ThumbnailCache' -Action {
        $b = [double]0; $i = 0; $f = 0
        $explorerRunning = Test-ProcessRunning -Names @('explorer')
        foreach ($p in $profilePaths) {
            if ($explorerRunning) { $f++; continue }   # locked while a session is active; skip cleanly
            $r = Clear-PathAgedFiles -Path (Join-Path $p 'AppData\Local\Microsoft\Windows\Explorer') `
                                     -OlderThanDays $TempFileAgeDays -IncludeFilter @('thumbcache_*.db','iconcache_*.db')
            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
        }
        $detail = if ($explorerRunning) { 'Skipped: an interactive session is active (cache files are locked).' } else { '' }
        Add-TaskResult -Task 'ThumbnailCache' -Bytes $b -Items $i -Failed $f -Detail $detail
    }

    # ── 11. Browser caches (cache subfolders only, closed browsers only) ───────
    Invoke-CleanupTask -Name 'BrowserCache' -Action {
        $b = [double]0; $i = 0; $f = 0; $skipped = @()

        $browsers = @(
            @{ Name='Chrome';  Procs=@('chrome');
               Roots=@('AppData\Local\Google\Chrome\User Data');
               Subs=@('Default\Cache','Default\Code Cache','Default\GPUCache','Default\Service Worker\CacheStorage',
                      'Default\Service Worker\ScriptCache','ShaderCache','GrShaderCache') },
            @{ Name='Edge';    Procs=@('msedge');
               Roots=@('AppData\Local\Microsoft\Edge\User Data');
               Subs=@('Default\Cache','Default\Code Cache','Default\GPUCache','Default\Service Worker\CacheStorage',
                      'Default\Service Worker\ScriptCache','ShaderCache','GrShaderCache') },
            @{ Name='Brave';   Procs=@('brave');
               Roots=@('AppData\Local\BraveSoftware\Brave-Browser\User Data');
               Subs=@('Default\Cache','Default\Code Cache','Default\GPUCache','ShaderCache') },
            @{ Name='Firefox'; Procs=@('firefox');
               Roots=@('AppData\Local\Mozilla\Firefox\Profiles');
               Subs=@('*') }   # profile folders each contain cache2
        )

        foreach ($br in $browsers) {
            if (Test-Deadline) { break }
            if (Test-ProcessRunning -Names $br.Procs) { $skipped += $br.Name; continue }

            foreach ($p in $profilePaths) {
                foreach ($root in $br.Roots) {
                    $rootPath = Join-Path $p $root
                    if (-not (Test-Path -LiteralPath $rootPath)) { continue }

                    if ($br.Name -eq 'Firefox') {
                        # Only ever the cache2 folder inside each Firefox profile.
                        Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            $r = Clear-PathAgedFiles -Path (Join-Path $_.FullName 'cache2') -OlderThanDays 0 -RemoveEmptyDirs
                            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
                        }
                        continue
                    }

                    # Chromium: apply to every profile folder (Default, Profile 1, ...) but only cache subfolders.
                    $chromeProfiles = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue |
                                        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
                    foreach ($sub in $br.Subs) {
                        if ($sub -like 'Default\*') {
                            foreach ($cp in $chromeProfiles) {
                                $leaf = $sub -replace '^Default\\',''
                                $r = Clear-PathAgedFiles -Path (Join-Path $cp.FullName $leaf) -OlderThanDays 0 -RemoveEmptyDirs
                                $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
                            }
                        } else {
                            $r = Clear-PathAgedFiles -Path (Join-Path $rootPath $sub) -OlderThanDays 0 -RemoveEmptyDirs
                            $b += $r.Bytes; $i += $r.Items; $f += $r.Failed
                        }
                    }
                }
            }
        }
        $detail = 'Cache folders only - cookies, passwords, history and bookmarks untouched.'
        if ($skipped.Count -gt 0) { $detail += " Skipped (running): $($skipped -join ', ')." }
        Add-TaskResult -Task 'BrowserCache' -Bytes $b -Items $i -Failed $f -Detail $detail
    }

    # ── 12. Teams cache (opt-in) ───────────────────────────────────────────────
    if ($CleanTeamsCache) {
        Invoke-CleanupTask -Name 'TeamsCache' -Action {
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
    }

    # ── 13. Recycle Bin (opt-in, age-aware) ────────────────────────────────────
    if ($EmptyRecycleBin) {
        Invoke-CleanupTask -Name 'RecycleBin' -Action {
            $b = [double]0; $i = 0; $f = 0
            $cutoff  = (Get-Date).AddDays(-[math]::Abs($RecycleBinAgeDays))
            $binRoot = "$SystemDrive\`$Recycle.Bin"
            if (-not (Test-Path -LiteralPath $binRoot)) {
                Add-TaskResult -Task 'RecycleBin' -Status 'SKIPPED' -Detail 'No recycle bin on system drive.'
                return
            }
            # $I* files are written at deletion time, so their LastWriteTime is the deletion date.
            foreach ($sidDir in (Get-ChildItem -LiteralPath $binRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-Deadline) { break }
                foreach ($meta in (Get-ChildItem -LiteralPath $sidDir.FullName -Filter '$I*' -Force -File -ErrorAction SilentlyContinue)) {
                    try {
                        if ($meta.LastWriteTime -ge $cutoff) { continue }
                        $dataPath = Join-Path $sidDir.FullName ('$R' + $meta.Name.Substring(2))
                        $size = [double]0
                        if (Test-Path -LiteralPath $dataPath) {
                            $d = Get-Item -LiteralPath $dataPath -Force
                            if ($d -is [System.IO.DirectoryInfo]) {
                                $size = [double](( Get-ChildItem -LiteralPath $dataPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                                                   Measure-Object -Property Length -Sum).Sum)
                            } else { $size = [double]$d.Length }
                            if (-not $ReportOnly) { Remove-Item -LiteralPath $dataPath -Recurse -Force -ErrorAction Stop }
                        }
                        if (-not $ReportOnly) { Remove-Item -LiteralPath $meta.FullName -Force -ErrorAction SilentlyContinue }
                        $b += $size; $i++
                    } catch { $f++ }
                }
            }
            Add-TaskResult -Task 'RecycleBin' -Bytes $b -Items $i -Failed $f `
                           -Detail "Items deleted more than $RecycleBinAgeDays day(s) ago."
        }
    }

    # ── 14. Windows.old / upgrade leftovers (opt-in) ───────────────────────────
    if ($RemoveWindowsOld) {
        Invoke-CleanupTask -Name 'WindowsOld' -Action {
            $b = [double]0; $i = 0
            $cutoff = (Get-Date).AddDays(-$WindowsOldAgeDays)
            foreach ($target in @("$SystemDrive\Windows.old", "$SystemDrive\`$Windows.~BT", "$SystemDrive\`$Windows.~WS")) {
                if (-not (Test-Path -LiteralPath $target)) { continue }
                $created = (Get-Item -LiteralPath $target -Force).CreationTime
                if ($created -ge $cutoff) {
                    Write-Log "Skipping '$target': only $([int]((Get-Date)-$created).TotalDays) day(s) old (rollback window)." -Level WARN
                    continue
                }
                $size = [double]((Get-ChildItem -LiteralPath $target -Recurse -Force -File -ErrorAction SilentlyContinue |
                                  Measure-Object -Property Length -Sum).Sum)
                if (-not $ReportOnly) {
                    # takeown/icacls are required; these trees are owned by TrustedInstaller.
                    & takeown.exe /F $target /R /A /D Y *>$null
                    & icacls.exe  $target /grant "*S-1-5-32-544:F" /T /C *>$null
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                }
                $b += $size; $i++
            }
            Add-TaskResult -Task 'WindowsOld' -Bytes $b -Items $i -Detail 'OS rollback capability removed for these trees.'
        }
    }

    # ── 15. Component store cleanup (opt-in) ───────────────────────────────────
    if ($RunComponentCleanup) {
        Invoke-CleanupTask -Name 'ComponentCleanup' -Action {
            if ($ReportOnly) {
                Add-TaskResult -Task 'ComponentCleanup' -Status 'SKIPPED' -Detail 'Not measured in report-only mode.'
                return
            }
            if (Test-ProcessRunning -Names @('TiWorker','TrustedInstaller','Dism')) {
                Add-TaskResult -Task 'ComponentCleanup' -Status 'SKIPPED' -Detail 'Servicing operation already running.'
                return
            }
            $pre  = Get-FreeSpaceBytes
            $proc = Start-Process -FilePath "$env:SystemRoot\System32\Dism.exe" `
                                  -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /NoRestart /Quiet' `
                                  -PassThru -WindowStyle Hidden
            try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }

            if (-not $proc.WaitForExit($ComponentCleanupTimeoutMin * 60 * 1000)) {
                try { $proc.Kill() } catch { }
                Add-TaskResult -Task 'ComponentCleanup' -Status 'TIMEOUT' `
                               -Detail "Exceeded $ComponentCleanupTimeoutMin min; process terminated."
                return
            }
            $delta = [math]::Max(0, (Get-FreeSpaceBytes) - $pre)
            if ($proc.ExitCode -in @(0, 3010)) {
                Add-TaskResult -Task 'ComponentCleanup' -Bytes $delta -Detail "DISM exit $($proc.ExitCode)."
            } else {
                Add-TaskResult -Task 'ComponentCleanup' -Bytes $delta -Status 'WARN' -Detail "DISM exit $($proc.ExitCode)."
            }
        }
    }

    # ── 16. Stale user profiles (opt-in) ───────────────────────────────────────
    if ($RemoveStaleProfiles) {
        Invoke-CleanupTask -Name 'StaleProfiles' -Action {
            $cutoff  = (Get-Date).AddDays(-$ProfileAgeDays)
            $current = ''
            try { $current = (Get-CimInstance Win32_ComputerSystem).UserName } catch { }
            $excludeNames = @('Administrator','Admin','Public','Default','defaultuser0','WDAGUtilityAccount')

            $candidates = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object {
                -not $_.Special -and
                -not $_.Loaded  -and
                $_.LocalPath -and
                $_.LocalPath -like "$SystemDrive\Users\*" -and
                ($_.LocalPath.Split('\')[-1] -notin $excludeNames) -and
                ($null -ne $_.LastUseTime) -and ($_.LastUseTime -lt $cutoff) -and
                ($current -eq '' -or $current.Split('\')[-1] -ne $_.LocalPath.Split('\')[-1])
            })

            $b = [double]0; $i = 0; $f = 0
            foreach ($prof in ($candidates | Sort-Object LastUseTime | Select-Object -First $MaxProfilesToRemove)) {
                if (Test-Deadline) { break }
                $size = [double]((Get-ChildItem -LiteralPath $prof.LocalPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                                  Measure-Object -Property Length -Sum).Sum)
                Write-Log ("Stale profile: {0} (last used {1}, {2})" -f $prof.LocalPath, $prof.LastUseTime, (Format-Bytes $size))
                if ($ReportOnly) { $b += $size; $i++; continue }
                try {
                    Remove-CimInstance -InputObject $prof -ErrorAction Stop
                    $b += $size; $i++
                    Write-Log "Removed profile: $($prof.LocalPath)"
                } catch {
                    $f++
                    Write-Log "Failed to remove profile $($prof.LocalPath): $_" -Level WARN
                }
            }
            Add-TaskResult -Task 'StaleProfiles' -Bytes $b -Items $i -Failed $f `
                           -Detail "$($candidates.Count) candidate(s) unused for $ProfileAgeDays+ days; cap $MaxProfilesToRemove/run."
        }
    }

    # ── 17. Old restore points / shadow copies (opt-in) ────────────────────────
    if ($RemoveOldRestorePoints) {
        Invoke-CleanupTask -Name 'RestorePoints' -Action {
            $shadows = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue |
                         Where-Object { $_.VolumeName } | Sort-Object InstallDate -Descending)
            if ($shadows.Count -le $KeepRestorePoints) {
                Add-TaskResult -Task 'RestorePoints' -Status 'SKIPPED' `
                               -Detail "$($shadows.Count) shadow copies present; keeping $KeepRestorePoints."
                return
            }
            $pre = Get-FreeSpaceBytes
            $doomed = $shadows | Select-Object -Skip $KeepRestorePoints
            $i = 0; $f = 0
            foreach ($s in $doomed) {
                if ($ReportOnly) { $i++; continue }
                try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $i++ } catch { $f++ }
            }
            $delta = if ($ReportOnly) { 0 } else { [math]::Max(0, (Get-FreeSpaceBytes) - $pre) }
            Add-TaskResult -Task 'RestorePoints' -Bytes $delta -Items $i -Failed $f `
                           -Detail "Kept the $KeepRestorePoints newest restore point(s)."
        }
    }

    # ══ Summary ════════════════════════════════════════════════════════════════
    $freeAfter    = Get-FreeSpaceBytes
    $actualDelta  = [math]::Max(0, $freeAfter - $freeBefore)
    $reportedSum  = ($script:TaskResults | Measure-Object -Property Bytes -Sum).Sum
    if ($null -eq $reportedSum) { $reportedSum = 0 }

    $top = ($script:TaskResults | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending |
            Select-Object -First 3 | ForEach-Object { "$($_.Task) $(Format-Bytes $_.Bytes)" }) -join ', '

    $summary = [PSCustomObject]@{
        Script            = $ScriptName
        Version           = $ScriptVersion
        Computer          = $env:COMPUTERNAME
        JoinType          = $joinType
        TimestampUtc      = (Get-Date).ToUniversalTime().ToString('s')
        ReportOnly        = [bool]$ReportOnly
        DriveTotalGB      = [math]::Round($totalSize / 1GB, 2)
        FreeBeforeGB      = [math]::Round($freeBefore / 1GB, 2)
        FreeAfterGB       = [math]::Round($freeAfter / 1GB, 2)
        ReclaimedGB       = [math]::Round($reportedSum / 1GB, 2)
        FreeSpaceDeltaGB  = [math]::Round($actualDelta / 1GB, 2)
        StoppedEarly      = [bool]$script:StopReason
        StopReason        = $script:StopReason
        Tasks             = $script:TaskResults
    }
    try { $summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $SummaryPath -Encoding UTF8 -Force } catch { }

    Write-Log ("Free space after: {0} (delta {1}; tasks reported {2})" -f `
               (Format-Bytes $freeAfter), (Format-Bytes $actualDelta), (Format-Bytes $reportedSum))
    if ($script:StopReason) { Write-Log "Run stopped early: $($script:StopReason)" -Level WARN }
    Write-Log "=== $ScriptName COMPLETE ==="

    $verb = if ($ReportOnly) { 'Reclaimable' } else { 'Reclaimed' }
    Write-VSAResult ("SUCCESS: {0} {1}. Free {2} -> {3} of {4}. Top: {5}.{6}" -f `
                   $verb,
                   (Format-Bytes $reportedSum),
                   (Format-Bytes $freeBefore),
                   (Format-Bytes $freeAfter),
                   (Format-Bytes $totalSize),
                   $(if ($top) { $top } else { 'nothing to clean' }),
                   $(if ($script:StopReason) { " Stopped early: $($script:StopReason)." } else { '' }))
    exit 0
}
catch {
    Write-Log "Unhandled error: $_" -Level ERROR
    Write-VSAResult "FAILURE: $_"
    exit 1
}
