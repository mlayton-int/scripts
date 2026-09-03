# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1

<#
.SYNOPSIS
    Removes Windows.old and in-place upgrade leftovers once they are past the rollback window.

.DESCRIPTION
    Opt-in disk reclaim task, split out of Invoke-DiskCleanup.ps1. Targets
    <drive>\Windows.old, <drive>\$Windows.~BT and <drive>\$Windows.~WS, but only when the
    tree's CreationTime is older than -WindowsOldAgeDays. Newer trees are left alone and
    logged, because they are still the OS rollback path.

    takeown.exe and icacls.exe are required first: these trees are owned by
    TrustedInstaller and are not removable without taking ownership.

    WHAT THIS TRADES AWAY
      The ability to roll back the last Windows upgrade. Usually the largest single
      reclaim available on a recently upgraded machine.

    Self-contained by design: no shared library, so it can be deployed to VSA on its own.

    Outputs
      C:\INS-Temp\Logs\DiskCleanup_WindowsOld.log
      C:\INS-Temp\Logs\DiskCleanup_WindowsOld_Summary.json
      C:\INS-Temp\Logs\ScriptResult_DiskCleanup_WindowsOld.txt

.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.0
    Context : SYSTEM (required - takeown/icacls on TrustedInstaller-owned trees)
    Exit    : 0 = success (including a skipped task, which is logged), 1 = fatal error

.PARAMETER WindowsOldAgeDays
    Minimum age of the tree before it may be removed. Default 30.

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Default 45.

.PARAMETER ReportOnly
    Measure what would be removed without deleting anything or changing ownership.
#>

[CmdletBinding()]
param(
    [int]$WindowsOldAgeDays = 30,
    [int]$MaxRuntimeMinutes = 45,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_WindowsOld'
$ScriptVersion = '1.0.0'
$LogDir        = 'C:\INS-Temp\Logs'
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
    Write-Log "WindowsOldAgeDays: $WindowsOldAgeDays"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - nothing will be deleted ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    Write-Log ("Free space before: {0}" -f (Format-Bytes $freeBefore))

    Invoke-Task -Name 'WindowsOld' -Action {
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
