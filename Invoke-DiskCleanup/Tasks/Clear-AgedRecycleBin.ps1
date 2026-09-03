# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1

<#
.SYNOPSIS
    Empties Recycle Bin items that were deleted more than N days ago.

.DESCRIPTION
    Opt-in disk reclaim task, split out of Invoke-DiskCleanup.ps1. Walks
    <drive>\$Recycle.Bin per-SID and removes items whose deletion date is older than
    -RecycleBinAgeDays. The $I* metadata file is written at deletion time, so its
    LastWriteTime is the deletion date; the matching $R* file holds the data.

    Age-aware on purpose: a blanket empty destroys a user's most recent safety net,
    while an age gate leaves recent deletions recoverable.

    WHAT THIS TRADES AWAY
      Recovery of anything deleted longer ago than the age gate.

    Self-contained by design: no shared library, so it can be deployed to VSA on its own.

    Outputs
      C:\ProgramData\Kaseya\Logs\DiskCleanup_RecycleBin.log
      C:\ProgramData\Kaseya\Logs\DiskCleanup_RecycleBin_Summary.json
      C:\ProgramData\Kaseya\ScriptResult_DiskCleanup_RecycleBin.txt

.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.0
    Context : SYSTEM (required - the bin is per-SID across all profiles)
    Exit    : 0 = success (including a skipped task, which is logged), 1 = fatal error

.PARAMETER RecycleBinAgeDays
    Only remove items deleted more than this many days ago. Default 30.

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Default 45.

.PARAMETER ReportOnly
    Measure what would be removed without deleting anything.
#>

[CmdletBinding()]
param(
    [int]$RecycleBinAgeDays = 30,
    [int]$MaxRuntimeMinutes = 45,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_RecycleBin'
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
    Write-Log "RecycleBinAgeDays: $RecycleBinAgeDays"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - nothing will be deleted ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    Write-Log ("Free space before: {0}" -f (Format-Bytes $freeBefore))

    Invoke-Task -Name 'RecycleBin' -Action {
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
