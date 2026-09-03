<#
.SYNOPSIS
    Invoke-DiskCleanup.ps1 - regression suite for the log-pollution bug class.

.DESCRIPTION
    Guards against a whole class of bug that once affected four functions at once, one of
    which silently defeated the path safety gate.

    THE BUG CLASS
    Write-Log routes INFO and WARN to Write-Output, i.e. the success stream. So any
    function that logged AND returned a value actually returned:

        @(log strings..., realValue)

    Consequences that were live in the shipped script:

      - Test-SafeCleanupPath logged a WARN before returning $false in 6 of its 8
        rejection paths. "-not @(str, $false)" is $false, so the gate in
        Clear-PathAgedFiles did not fire and deletion PROCEEDED on paths the gate had
        just rejected, while the log said "Path rejected". The reachable trigger was the
        reparse-point rejection: a junctioned cleanup target got walked through.
      - Test-TaskEnabled did the same, so -SkipTasks logged "skipped" and then ran the
        task anyway. The deadline and free-space-target gates were equally inert.
      - Clear-PathAgedFiles logged when preserving a protected extension, so the
        caller's $r.Bytes threw under Set-StrictMode -Version Latest. A .bak in a temp
        folder was enough to kill the task.
      - Get-UserProfilePath logged in its CIM-failure fallback, injecting log strings
        into $profilePaths, which were then treated as profile paths.

    THE FIX these tests lock in: all four are pure predicates/producers that do no
    logging. Reasons come back via [ref] out-parameters; diagnostics Clear-PathAgedFiles
    cannot emit are collected in $script:PathSkips / $script:ProtectedSkips and logged by
    Invoke-CleanupTask, which returns nothing and so is safe to log from.

    Functions are extracted from the script by AST and dot-sourced with the scope
    variables they expect. Set-StrictMode -Version Latest is set here because the real
    script sets it - without it, member enumeration over a polluted return silently
    succeeds and hides the fault.

    Runs entirely on a throwaway temp tree. Measurement mode only, so nothing the test
    creates is ever deleted by the code under test. No elevation required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

$Src = Get-ScriptUnderTest 'Invoke-DiskCleanup\Invoke-DiskCleanup.ps1'
$ws  = New-TestWorkspace -Label 'dcbugs'

# ── Extract the functions under test ──────────────────────────────────────────
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Src, [ref]$null, [ref]$null)
$want = @('Write-Log','Format-Bytes','Get-FreeSpaceBytes','Test-Deadline','Test-TargetReached',
          'Test-TaskEnabled','Add-TaskResult','Test-ProcessRunning','Test-SafeCleanupPath',
          'Clear-PathAgedFiles','Get-UserProfilePath','Invoke-CleanupTask')
foreach ($n in $want) {
    $fn = $ast.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $x.Name -eq $n }, $true) | Select-Object -First 1
    if (-not $fn) { throw "function $n not found - has the script changed?" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# ── Scope variables the extracted functions read ──────────────────────────────
$SystemDrive = $env:SystemDrive
$LogPath     = Join-Path $ws 'test.log'
$ScriptName  = 'DiskCleanupTest'
$ReportOnly  = $true          # measurement only: safe, and still exposes every bug
$SkipTasks   = @()
$StopWhenFreeSpaceGB = 0
$ProtectedExtensions = @('.pst','.ost','.bak')
$script:ProtectedPaths = @("$SystemDrive\", "$SystemDrive\Windows", "$SystemDrive\Users")
$script:Deadline       = (Get-Date).AddMinutes(30)
$script:TaskResults    = New-Object System.Collections.Generic.List[object]
$script:StopReason     = ''
$script:PathSkips      = New-Object System.Collections.Generic.List[string]
$script:ProtectedSkips = 0

# The real script sets this. Without it, member enumeration over a polluted return
# silently succeeds and the fault is invisible.
Set-StrictMode -Version Latest

Reset-TestChecks
try {
    # ══ 1. The path safety gate must not be bypassable ════════════════════════
    # A junction is a reparse point, which Test-SafeCleanupPath rejects. If the gate
    # works, Clear-PathAgedFiles reports Skipped and never looks inside.
    $sentinelDir = Join-Path $ws 'SENTINEL'
    New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
    $sentinelFile = Join-Path $sentinelDir 'DO-NOT-TOUCH.dat'
    New-AgedFile -Path $sentinelFile -Bytes 2MB -AgeDays 60

    $junction = Join-Path $ws 'junction'
    cmd /c mklink /J "$junction" "$sentinelDir" | Out-Null

    $g = Clear-PathAgedFiles -Path $junction -OlderThanDays 1
    Add-TestCheck 'gate: reported Skipped'    $true (@($g)[-1].Skipped)
    Add-TestCheck 'gate: measured nothing'    0     (@($g)[-1].Items)
    Add-TestCheck 'gate: sentinel intact'     $true (Test-Path -LiteralPath $sentinelFile)

    # The predicate itself must return exactly one boolean plus a reason.
    $why = ''
    $rejected = Test-SafeCleanupPath -Path $junction -Reason ([ref]$why)
    Add-TestCheck 'gate predicate: 1 value'   1      (@($rejected).Count)
    Add-TestCheck 'gate predicate: False'     $false ($rejected)
    Add-TestCheck 'gate predicate: reason set' $true ([bool]($why -match 'reparse point'))

    # ══ 2. -SkipTasks and the deadline must actually skip ═════════════════════
    $SkipTasks = @('SkipMe')
    $script:ranSkipped = $false
    Invoke-CleanupTask -Name 'SkipMe' -Action { $script:ranSkipped = $true }
    Add-TestCheck 'SkipTasks: action did NOT run' $false $script:ranSkipped
    $SkipTasks = @()

    $savedDeadline   = $script:Deadline
    $script:Deadline = (Get-Date).AddMinutes(-5)   # already past
    $script:ranDead  = $false
    Invoke-CleanupTask -Name 'PastDeadline' -Action { $script:ranDead = $true }
    Add-TestCheck 'deadline: action did NOT run' $false $script:ranDead
    $script:Deadline   = $savedDeadline
    $script:StopReason = ''

    # ══ 3. A protected extension must not break the return value ═════════════
    $pdir = Join-Path $ws 'protected'
    New-AgedFile -Path (Join-Path $pdir 'keep.bak') -Bytes 1MB -AgeDays 60
    New-AgedFile -Path (Join-Path $pdir 'junk.tmp') -Bytes 1MB -AgeDays 60

    $r3 = Clear-PathAgedFiles -Path $pdir -OlderThanDays 1
    Add-TestCheck 'protected ext: return is clean' 1 (@($r3).Count)
    # Accessed exactly as the real callers do - $r.Bytes on the raw return, no indexing.
    $bytesOk = $false
    try { $null = $r3.Bytes; $bytesOk = $true } catch { $bytesOk = $false }
    Add-TestCheck 'protected ext: $r.Bytes readable' $true $bytesOk
    Add-TestCheck 'protected ext: counted only .tmp' 1    $r3.Items
    Add-TestCheck 'protected ext: counter incremented' 1  $r3.ProtectedSkipped
    Add-TestCheck 'protected ext: .bak still present' $true (Test-Path -LiteralPath (Join-Path $pdir 'keep.bak'))

    # ══ 4. Get-UserProfilePath fallback must return only paths ═══════════════
    # Shadow Get-CimInstance so the CIM branch fails and the fallback runs.
    function Get-CimInstance { throw 'simulated CIM failure' }
    $fbReason = ''
    $profiles = Get-UserProfilePath -FallbackReason ([ref]$fbReason)
    Remove-Item function:Get-CimInstance
    Add-TestCheck 'profile fallback: reason reported' $true ([bool]($fbReason -match 'simulated CIM failure'))
    $allDirs = $true
    foreach ($p in @($profiles)) {
        if (-not (Test-Path -LiteralPath ([string]$p) -PathType Container)) { $allDirs = $false }
    }
    Add-TestCheck 'profile fallback: every item is a directory' $true $allDirs
}
finally {
    Remove-TestWorkspace -Path $ws
}

Write-TestSummary -SuiteName 'Invoke-DiskCleanup / LogPollution'
exit (Get-TestFailureCount)
