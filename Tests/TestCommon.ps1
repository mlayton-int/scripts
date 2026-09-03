# Shared scaffolding for the test suites in this folder. Dot-source it:
#
#     . (Join-Path $PSScriptRoot '..\TestCommon.ps1')
#
# Unlike the production scripts (which are deliberately self-contained so each can be
# uploaded to VSA on its own), the tests are never deployed, so sharing helpers here is
# free and avoids repeating this block in every suite.

Set-StrictMode -Version Latest

# ── Repo location ─────────────────────────────────────────────────────────────
function Get-RepoRoot {
    # TestCommon.ps1 lives in <repo>\Tests\, so the repo root is one level up.
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-ScriptUnderTest {
    <# Resolves a repo-relative script path and fails loudly if it has moved. #>
    param([Parameter(Mandatory)][string]$RelativePath)
    $full = Join-Path (Get-RepoRoot) $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Script under test not found: $full"
    }
    return $full
}

# ── Environment ───────────────────────────────────────────────────────────────
function Test-IsElevated {
    return (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevated {
    param([string]$SuiteName = 'This suite')
    if (-not (Test-IsElevated)) {
        throw "$SuiteName requires an ELEVATED session. Re-run PowerShell as Administrator."
    }
}

# ── Workspace ─────────────────────────────────────────────────────────────────
function New-TestWorkspace {
    <# A throwaway directory under TEMP. Never inside the repo. #>
    param([string]$Label = 'suite')
    $path = Join-Path ([IO.Path]::GetTempPath()) ("psTests_{0}_{1}" -f $Label, [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    <#
        Removes reparse points with rmdir FIRST. Remove-Item -Recurse would otherwise
        follow a junction and delete the target's contents - the exact hazard some of
        these suites deliberately create in order to test the safety gate.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { cmd /c rmdir "$($_.FullName)" | Out-Null }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-AgedFile {
    <# Creates a file of a given size with a backdated LastWriteTime. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Bytes,
        [int]$AgeDays = 0
    )
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    if ($AgeDays -gt 0) {
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    }
}

function Get-TreeBytes {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length
    if ($null -eq $m.Sum) { return [int64]0 }
    return [int64]$m.Sum
}

# ── Running a script under test ───────────────────────────────────────────────
$script:LastExitCode2 = 0

function Invoke-ScriptUnderTest {
    <#
        Runs a script in a child powershell.exe and returns its combined output.
        The exit code lands in (Get-LastScriptExit).

        Child runs legitimately write to stderr (Write-Error / Write-Warning). With
        $ErrorActionPreference = 'Stop' in the suite, PowerShell turns native-command
        stderr into a terminating NativeCommandError, so drop to Continue for the
        duration of the child process only.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$VerboseRun
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Path) + $Arguments
        if ($VerboseRun) { $argList += '-Verbose' }
        $out = & powershell @argList 2>&1
        $script:LastExitCode2 = $LASTEXITCODE
        return $out
    } finally { $ErrorActionPreference = $old }
}

function Get-LastScriptExit { return $script:LastExitCode2 }

function Get-ScriptHelpText {
    <#
        Renders Get-Help for a script. Used to guard the PowerShell 5.1 quirk where any
        non-blank line abutting the <# help block (a #Requires, or even a comment)
        suppresses comment-based help entirely, leaving only a bare syntax line.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Help '$Path' -Full | Out-String" 2>&1 | Out-String)
    } finally { $ErrorActionPreference = $old }
}

# ── Assertions / reporting ────────────────────────────────────────────────────
$script:Checks = @()

function Reset-TestChecks { $script:Checks = @() }

function Add-TestCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual
    )
    $script:Checks += [PSCustomObject]@{
        Test     = $Name
        Expected = $Expected
        Actual   = $Actual
        Result   = $(if ($Expected -eq $Actual) { 'PASS' } else { 'FAIL' })
    }
}

function Write-TestSummary {
    <#
        Prints the results table and the pass/fail line. Emits no return value - use
        Get-TestFailureCount for the exit code, so the table's formatting objects can
        never end up mixed into it.
    #>
    param([string]$SuiteName = '', [switch]$FailuresOnly)
    $rows = if ($FailuresOnly) { $script:Checks | Where-Object Result -eq 'FAIL' } else { $script:Checks }
    if ($rows) { $rows | Format-Table -AutoSize }
    $pass = @($script:Checks | Where-Object Result -eq 'PASS').Count
    $fail = @($script:Checks | Where-Object Result -eq 'FAIL').Count
    $label = if ($SuiteName) { "[$SuiteName] " } else { '' }
    "`n${label}$pass passed, $fail failed"
}

function Get-TestFailureCount {
    return @($script:Checks | Where-Object Result -eq 'FAIL').Count
}
