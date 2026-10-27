<#
.SYNOPSIS
    Remove-WindowsOld.ps1 - the partial-removal reporting path.

.DESCRIPTION
    The only suite that exercises a Tasks\ script's live -Delete path, because this one
    cannot be verified any other way: it only misbehaves when Remove-Item partially fails,
    which never happens on a healthy test machine and cannot be provoked in report mode.

    THE TWO BUGS THIS LOCKS IN

      1. Over-reporting. The task measured the tree, called
         "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue", then unconditionally
         added the full pre-measured size to the reclaimed total. There was no failure
         counter at all. Partial failure is normal on these trees (locked files, ACL edge
         cases), so ReclaimedGB could claim a whole tree that was still sitting on disk.

      2. A takeown failure aborted the entire task. takeown/icacls were invoked as
         "& takeown.exe ... *>$null" to discard their output, but in PowerShell 5.1
         redirecting a native command's stderr wraps each line in a NativeCommandError,
         which under $ErrorActionPreference = 'Stop' is TERMINATING. takeown writes to
         stderr on exactly the failures worth reporting, so the task threw on its first
         stderr line and reported FAILED without attempting the removal.

    HOW IT IS SAFE

      C:\Windows.old is never touched. A patched copy of the script is pointed at a
      throwaway temp tree, and only that copy is ever run. Both patches are anchored on
      exact source strings and the suite throws if either anchor is missing, so it fails
      loudly rather than silently testing nothing if the script is restructured.

      The tree is 3 MB, of which 2 MB is held open with FileShare.None for the duration of
      the child process. That is what makes Remove-Item partially fail on demand.

.NOTES
    Elevation: not required, and deliberately not asserted. Unelevated is in fact the more
    interesting run, because takeown then fails and exercises bug 2 as well as bug 1.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

$Src = Get-ScriptUnderTest 'Invoke-DiskCleanup\Tasks\Remove-WindowsOld.ps1'
$ws  = New-TestWorkspace -Label 'woPartial'

# Patch anchors. Both must match exactly or the suite is testing nothing.
$TargetAnchor = 'foreach ($target in @("$SystemDrive\Windows.old", "$SystemDrive\`$Windows.~BT", "$SystemDrive\`$Windows.~WS")) {'
$LogAnchor    = "`$LogDir        = 'C:\INS-Temp\Logs'"

$lock = $null
Reset-TestChecks
try {
    $tree   = Join-Path $ws 'Windows.old'
    $logDir = Join-Path $ws 'logs'
    New-Item -ItemType Directory -Path $tree   -Force | Out-Null
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    $deletable = Join-Path $tree 'deletable.dat'
    $locked    = Join-Path $tree 'locked.dat'
    New-AgedFile -Path $deletable -Bytes 1MB
    New-AgedFile -Path $locked    -Bytes 2MB

    # Past the rollback window, or the task correctly refuses to act at all.
    (Get-Item -LiteralPath $tree).CreationTime = (Get-Date).AddDays(-99)

    $raw = Get-Content -LiteralPath $Src -Raw
    Add-TestCheck 'patch: target anchor present' $true ($raw.Contains($TargetAnchor))
    Add-TestCheck 'patch: logdir anchor present' $true ($raw.Contains($LogAnchor))
    if (-not $raw.Contains($TargetAnchor) -or -not $raw.Contains($LogAnchor)) {
        throw 'Remove-WindowsOld.ps1 has been restructured - update this suite''s anchors.'
    }

    $copy = Join-Path $ws 'Remove-WindowsOld.ps1'
    $raw.Replace($TargetAnchor, 'foreach ($target in @($env:WOTEST_TARGET)) {').
         Replace($LogAnchor,    '$LogDir        = $env:WOTEST_LOGDIR') |
        Set-Content -LiteralPath $copy -Encoding utf8

    $env:WOTEST_TARGET = $tree
    $env:WOTEST_LOGDIR = $logDir

    # Hold locked.dat open with no sharing for the duration of the child process.
    $lock = [IO.File]::Open($locked, 'Open', 'Read', 'None')

    $null = Invoke-ScriptUnderTest -Path $copy -Arguments @('-Delete')
    Add-TestCheck 'task exits 0 despite partial failure' 0 (Get-LastScriptExit)

    $sumPath = Join-Path $logDir 'DiskCleanup_WindowsOld_Summary.json'
    Add-TestCheck 'summary written' $true (Test-Path -LiteralPath $sumPath)

    if (Test-Path -LiteralPath $sumPath) {
        $task = @((Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json).Tasks)[0]

        # The bug-1 assertion. 1 MB went, 2 MB did not; the old code reported all 3 MB.
        Add-TestCheck 'reports only the bytes that went' ([double]1MB) ([double]$task.Bytes)
        Add-TestCheck 'does NOT report the full tree'    $false ([double]$task.Bytes -eq [double]3MB)
        Add-TestCheck 'counts the tree in Failed'        1      ([int]$task.Failed)
        Add-TestCheck 'status is WARN'                   'WARN' ([string]$task.Status)
    }

    Add-TestCheck 'unlocked file really deleted' $false (Test-Path -LiteralPath $deletable)
    Add-TestCheck 'locked file left in place'    $true  (Test-Path -LiteralPath $locked)

    # The bug-2 assertion: a takeown/icacls failure must be logged and survivable, not
    # thrown. Unelevated, takeown always fails here; elevated it may well succeed, so
    # this only asserts the task was not aborted by it.
    $log = Get-Content -LiteralPath (Join-Path $logDir 'DiskCleanup_WindowsOld.log') -Raw
    Add-TestCheck 'task not aborted by native stderr' $false ([bool]($log -match "Task 'WindowsOld' failed"))
    Add-TestCheck 'partial removal logged as WARN'    $true  ([bool]($log -match 'Partially removed'))
    if (-not (Test-IsElevated)) {
        Add-TestCheck 'takeown failure logged (unelevated)' $true ([bool]($log -match 'takeown .* exited'))
    }
}
finally {
    if ($lock) { $lock.Close(); $lock.Dispose() }
    Remove-Item Env:\WOTEST_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:\WOTEST_LOGDIR -ErrorAction SilentlyContinue
    Remove-TestWorkspace -Path $ws
}

Write-TestSummary -SuiteName 'Invoke-DiskCleanup / WindowsOldPartial'
exit (Get-TestFailureCount)
