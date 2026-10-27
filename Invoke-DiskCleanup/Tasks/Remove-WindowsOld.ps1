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

    Partial removal is normal on these trees, so the tree is re-measured afterwards and
    only the bytes that actually went are reported. A tree that survives in part is
    counted in Failed and the task reports WARN.

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

.PARAMETER Delete
    Actually delete. Omitted, the script measures what would be removed without
    deleting anything or changing ownership - report-only is the default.
#>

[CmdletBinding()]
param(
    [int]$WindowsOldAgeDays = 30,
    [switch]$Delete
)

# Report-only is the default; -Delete opts in to actually removing anything. Everything
# below reads $ReportOnly, so derive it once here rather than inverting at each use.
$ReportOnly = -not $Delete

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$ScriptName    = 'DiskCleanup_WindowsOld'
$ScriptVersion = '1.0.0'
$LogDir        = 'C:\INS-Temp\Logs'
$LogPath       = "$LogDir\$ScriptName.log"
$SummaryPath   = "$LogDir\${ScriptName}_Summary.json"
$SystemDrive   = $env:SystemDrive

$script:TaskResults = New-Object System.Collections.Generic.List[object]

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

function Invoke-NativeTool {
    <#
        Runs a console tool, discards its output, and logs a WARN if it exits non-zero.

        $ErrorActionPreference is dropped to Continue for the duration, and this is the
        whole point of the function. In Windows PowerShell 5.1, redirecting a native
        command's stderr inside PowerShell wraps each line in a NativeCommandError
        ErrorRecord - which under 'Stop' is a TERMINATING error. So "takeown.exe ...
        *>$null" threw the instant takeown wrote its first stderr line, aborting the whole
        task before any exit code could be examined, and takeown writes to stderr on
        exactly the failures worth reporting. Verified: both '*>$null' and '2>$null' throw;
        only lowering the preference around the call does not.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Label
    )
    $output = @()
    $code   = 0
    $eap    = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Exe @Arguments 2>&1
        $code   = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }

    if ($code -ne 0) {
        $first = @($output | Where-Object { "$_".Trim() } | Select-Object -First 1)
        Write-Log "$Label exited $code; removal may be incomplete. $first" -Level WARN
    }
}

function Get-TreeBytes {
    <#
        Total size of a directory tree, or 0 if it is absent. Called twice per target:
        once before removal, and again afterwards if anything survived, so the reported
        figure reflects what actually went rather than what was attempted.

        Measure-Object returns .Sum = $null for an empty set, which [double] renders as 0.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [double]0 }
    return [double]((Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum)
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
        $b = [double]0; $i = 0; $f = 0
        $cutoff = (Get-Date).AddDays(-$WindowsOldAgeDays)
        foreach ($target in @("$SystemDrive\Windows.old", "$SystemDrive\`$Windows.~BT", "$SystemDrive\`$Windows.~WS")) {
            if (-not (Test-Path -LiteralPath $target)) { continue }
            $created = (Get-Item -LiteralPath $target -Force).CreationTime
            if ($created -ge $cutoff) {
                Write-Log "Skipping '$target': only $([int]((Get-Date)-$created).TotalDays) day(s) old (rollback window)." -Level WARN
                continue
            }
            $size = [double](Get-TreeBytes -Path $target)

            if ($ReportOnly) { $b += $size; $i++; continue }

            # takeown/icacls are required; these trees are owned by TrustedInstaller.
            # Failure here surfaces later only as a removal that quietly under-delivers,
            # so the exit codes are logged rather than discarded.
            Invoke-NativeTool -Exe 'takeown.exe' -Label "takeown on '$target'" `
                              -Arguments @('/F', $target, '/R', '/A', '/D', 'Y')
            Invoke-NativeTool -Exe 'icacls.exe'  -Label "icacls on '$target'" `
                              -Arguments @($target, '/grant', '*S-1-5-32-544:F', '/T', '/C')

            # SilentlyContinue on purpose: a partial failure must not abort the task. But
            # its result cannot be trusted either, so measure what actually went rather
            # than assuming the whole tree did - otherwise a locked subtree is still
            # reported as reclaimed and ReclaimedGB silently disagrees with the free-space
            # delta.
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $target) {
                $left = [double](Get-TreeBytes -Path $target)
                $b += [math]::Max(0, $size - $left)
                $f++
                Write-Log ("Partially removed '{0}': {1} of {2} left behind (locked or ACL-denied)." -f `
                           $target, (Format-Bytes $left), (Format-Bytes $size)) -Level WARN
                continue
            }
            $b += $size; $i++
        }
        $status = if ($f -gt 0) { 'WARN' } else { 'OK' }
        $detail = if ($f -gt 0) {
            "OS rollback capability removed. $f tree(s) only partially removed - see WARN lines."
        } else {
            'OS rollback capability removed for these trees.'
        }
        Add-TaskResult -Task 'WindowsOld' -Bytes $b -Items $i -Failed $f -Status $status -Detail $detail
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
