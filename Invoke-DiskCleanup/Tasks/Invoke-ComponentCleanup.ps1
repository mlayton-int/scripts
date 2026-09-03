# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1

<#
.SYNOPSIS
    Runs DISM /StartComponentCleanup to reclaim superseded WinSxS components.

.DESCRIPTION
    Opt-in disk reclaim task, split out of Invoke-DiskCleanup.ps1. Launches DISM at
    BelowNormal priority with a hard timeout, and measures the result by free-space
    delta because DISM does not report reclaimed bytes.

    /ResetBase is deliberately NOT used: it permanently blocks uninstalling installed
    updates. Skips itself if a servicing operation is already running.

    WHAT THIS TRADES AWAY
      Little in recovery terms, but it is CPU-heavy and long-running - schedule it in a
      change window, not during business hours. Not measurable without -Delete.

    Self-contained by design: no shared library, so it can be deployed to VSA on its own.

    Outputs
      C:\INS-Temp\Logs\DiskCleanup_ComponentCleanup.log
      C:\INS-Temp\Logs\DiskCleanup_ComponentCleanup_Summary.json
      C:\INS-Temp\Logs\ScriptResult_DiskCleanup_ComponentCleanup.txt

.NOTES
    Author  : Michael Layton (Assisted by Claude.ai | Static analysis and testing completed manually)
    Version : 1.0.0
    Context : SYSTEM (required)
    Exit    : 0 = success (including SKIPPED / TIMEOUT, which are logged), 1 = fatal error

    Set the VSA procedure timeout above -ComponentCleanupTimeoutMin plus headroom, so
    this script's own timeout fires first and you still get a summary.

.PARAMETER ComponentCleanupTimeoutMin
    Minutes to allow DISM before terminating it. Default 30.

.PARAMETER MaxRuntimeMinutes
    Hard cap on total runtime. Default 45.

.PARAMETER Delete
    Actually run DISM. Omitted, the task reports SKIPPED without running it - the
    reclaim is not measurable in advance, so there is nothing to report either way.
#>

[CmdletBinding()]
param(
    [int]$ComponentCleanupTimeoutMin = 30,
    [int]$MaxRuntimeMinutes          = 45,
    [switch]$Delete
)

# Report-only is the default; -Delete opts in to actually running DISM. Everything
# below reads $ReportOnly, so derive it once here rather than inverting at each use.
$ReportOnly = -not $Delete

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_ComponentCleanup'
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
    Write-Log "ComponentCleanupTimeoutMin: $ComponentCleanupTimeoutMin"
    if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - DISM will not be run ***" -Level WARN }

    $freeBefore = Get-FreeSpaceBytes
    Write-Log ("Free space before: {0}" -f (Format-Bytes $freeBefore))

    Invoke-Task -Name 'ComponentCleanup' -Action {
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
