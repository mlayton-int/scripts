<#
.SYNOPSIS
    Discovers and runs every test suite under Tests\, then reports an aggregate result.

.DESCRIPTION
    Each suite is a standalone script that exits with its failure count, so this runner
    just invokes them and sums the exit codes. Run a suite directly for its full
    check-by-check table; this view is the roll-up.

    Suites are gated automatically:
      - Anything calling Assert-Elevated is reported SKIPPED when not running elevated,
        rather than failing.
      - Anything taking -AllowRealProfile (i.e. it writes into the current user's real
        profile) is SKIPPED unless -IncludeRealProfile is passed.

.PARAMETER IncludeRealProfile
    Also run the suite that plants a synthetic cache under $env:USERPROFILE. It has its
    own safety gate and aborts if a real Autodesk tree already exists.

.EXAMPLE
    .\Invoke-AllTests.ps1
    Runs everything safe for the current session.

.EXAMPLE
    .\Invoke-AllTests.ps1 -IncludeRealProfile
    Full coverage. Run elevated.
#>

[CmdletBinding()]
param([switch]$IncludeRealProfile)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestCommon.ps1')

$elevated = Test-IsElevated
Write-Output "Elevated: $elevated"
if (-not $elevated) {
    Write-Warning 'Not elevated - suites requiring admin will be skipped.'
}

$suites = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter 'Test-*.ps1' | Sort-Object FullName

# Collected into an explicit list, NOT via "$rows = foreach {...}". Write-Output for
# progress inside such a loop would be captured into the result set - the same
# success-stream-pollution trap these suites exist to guard against.
$rows = New-Object System.Collections.Generic.List[object]

foreach ($s in $suites) {
    $text        = Get-Content -LiteralPath $s.FullName -Raw
    $needsElev   = $text -match 'Assert-Elevated'
    $needsRealFs = $text -match 'AllowRealProfile'
    $rel         = $s.FullName.Substring($PSScriptRoot.Length).TrimStart('\')

    if ($needsElev -and -not $elevated) {
        $rows.Add([PSCustomObject]@{ Suite = $rel; Result = 'SKIPPED'; Failures = 0; Note = 'needs elevation' })
        continue
    }
    if ($needsRealFs -and -not $IncludeRealProfile) {
        $rows.Add([PSCustomObject]@{ Suite = $rel; Result = 'SKIPPED'; Failures = 0; Note = 'needs -IncludeRealProfile' })
        continue
    }

    $suiteArgs = if ($needsRealFs) { @('-AllowRealProfile') } else { @() }
    Write-Output "`n--- $rel ---"
    $out   = Invoke-ScriptUnderTest -Path $s.FullName -Arguments $suiteArgs
    $fails = Get-LastScriptExit
    # Echo just the suite's own summary line; the full table stays in the suite output.
    $summary = @(($out | Out-String) -split "`n" | Where-Object { $_ -match '(\d+) passed,\s*(\d+) failed' })
    $summary | ForEach-Object { Write-Output $_.Trim() }

    # A suite that ran ZERO checks is an error, not a pass. An error inside a suite's
    # try/finally aborts the whole block; finally runs, and because suites set
    # $ErrorActionPreference = 'Continue' execution then resumes at Write-TestSummary,
    # which duly reports "0 passed, 0 failed" and exits 0. Scoring that on the exit code
    # alone reports a suite that died on its first assertion as PASS - which is exactly
    # how a removed property silently disabled the whole LogPollution suite once.
    $ran = -1
    if ($summary.Count -gt 0 -and $summary[-1] -match '(\d+) passed,\s*(\d+) failed') {
        $ran = [int]$Matches[1] + [int]$Matches[2]
    }

    $result = 'PASS'; $note = ''
    if ($ran -lt 0)      { $result = 'ERROR'; $note = 'no summary line - suite did not complete' }
    elseif ($ran -eq 0)  { $result = 'ERROR'; $note = 'ran 0 checks - suite aborted early' }
    elseif ($fails -gt 0){ $result = 'FAIL' }

    $rows.Add([PSCustomObject]@{
        Suite    = $rel
        Result   = $result
        Failures = $(if ($result -eq 'ERROR' -and $fails -eq 0) { 1 } else { $fails })
        Note     = $note
    })
}

Write-Output "`n══ Aggregate ══"
$rows | Format-Table -AutoSize

# Measure-Object over an empty set returns nothing, so .Sum would throw under
# StrictMode - which is the all-passing case. ERROR rows count toward the total so an
# aborted suite can never exit 0.
$badRows   = @($rows | Where-Object { $_.Result -in @('FAIL','ERROR') })
$totalFail = 0
if ($badRows.Count -gt 0) {
    $totalFail = [int](($badRows | Measure-Object -Property Failures -Sum).Sum)
}
$errored = @($rows | Where-Object Result -eq 'ERROR').Count

Write-Output ("Suites: {0} pass, {1} fail, {2} error, {3} skipped. Total failing checks: {4}" -f
    @($rows | Where-Object Result -eq 'PASS').Count,
    @($rows | Where-Object Result -eq 'FAIL').Count,
    $errored,
    @($rows | Where-Object Result -eq 'SKIPPED').Count,
    $totalFail)

if ($errored -gt 0) {
    Write-Warning "$errored suite(s) aborted without running their checks - see the Note column."
}

exit $totalFail
