# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1

<#
.SYNOPSIS
    Deletes unloaded local user profiles that have not been used for N days.

.DESCRIPTION
    Opt-in disk reclaim task, split out of Invoke-DiskCleanup.ps1. Removal goes through
    Win32_UserProfile so the registry profile entry is cleaned up too - deleting the
    folder alone leaves a broken profile behind.

    Guards applied before anything is removed:
      - Special (system) profiles are never touched.
      - Loaded profiles are never touched.
      - The currently logged-on user is excluded.
      - Built-in and service names are excluded (Administrator, defaultuser0, ...).
      - Only profiles under <drive>\Users qualify.
      - LastUseTime must be older than -ProfileAgeDays.
      - At most -MaxProfilesToRemove per run, oldest first.

    WHAT THIS TRADES AWAY
      Everything in those profiles - documents, desktop, app data. There is no undo.
      Run with -ReportOnly first and read the candidate list.

    Self-contained by design: no shared library, so it can be deployed to VSA on its own.

    Outputs
      C:\ProgramData\Kaseya\Logs\DiskCleanup_StaleProfiles.log
      C:\ProgramData\Kaseya\Logs\DiskCleanup_StaleProfiles_Summary.json
      C:\ProgramData\Kaseya\ScriptResult_DiskCleanup_StaleProfiles.txt

.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.0
    Context : SYSTEM (required)
    Exit    : 0 = success (including a skipped task, which is logged), 1 = fatal error

.PARAMETER ProfileAgeDays
    Minimum days since LastUseTime before a profile qualifies. Default 120.

.PARAMETER MaxProfilesToRemove
    Safety cap on removals per run, oldest first. Default 5.

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Default 45.

.PARAMETER ReportOnly
    List and measure candidates without removing anything.
#>

[CmdletBinding()]
param(
    [int]$ProfileAgeDays      = 120,
    [int]$MaxProfilesToRemove = 5,
    [int]$MaxRuntimeMinutes   = 45,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_StaleProfiles'
$ScriptVersion = '1.0.0'
$LogDir        = 'C:\ProgramData\Kaseya\Logs'
$LogPath       = "$LogDir\$ScriptName.log"
$SummaryPath   = "$LogDir\${ScriptName}_Summary.json"
$SystemDrive   = $env:SystemDrive

$script:Deadline    = (Get-Date).AddMinutes($MaxRuntimeMinutes)
$script:TaskResults = New-Object System.Collections.Generic.List[object]
$script:StopReason  = ''

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
    try { $Result | Out-File -FilePath "C:\ProgramData\Kaseya\ScriptResult_$ScriptName.txt" -Encoding UTF8 -Force } catch { }
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

function Invoke-Task {
    <#
        Isolates the task so a failure still produces a summary and a result string.
        Retained (rather than inlining the body) so the lifted task code keeps its
        original 'return' semantics - at script scope, return would skip the summary.
    #>
    param([string]$Name, [scriptblock]$Action)
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

    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "ProfileAgeDays: $ProfileAgeDays | MaxProfilesToRemove: $MaxProfilesToRemove"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - no profiles will be removed ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    Write-Log ("Free space before: {0}" -f (Format-Bytes $freeBefore))

    Invoke-Task -Name 'StaleProfiles' -Action {
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
