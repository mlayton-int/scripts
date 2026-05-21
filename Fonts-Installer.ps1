#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Extracts and installs all .ttf fonts from a ZIP file for all users (system-wide).

.DESCRIPTION
    Extracts all .ttf font files from a specified ZIP archive, copies them to the
    Windows system fonts directory (%WINDIR%\Fonts), and registers each font in the
    registry under HKLM so they are available to all users without requiring a reboot.

    - Idempotent: skips fonts that are already installed at the same file size.
    - Cleans up the temp extraction directory on exit (success or failure).
    - Exits with code 0 on full success, 3 on partial failure, 1 on total failure,
      and 2 on prerequisite errors (zip not found, no TTFs inside, etc.).

.NOTES
    Tested:  Windows 11 25H2

    Font registration key:
        HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts
    Font files installed to:
        %WINDIR%\Fonts
#>

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit these values before deploying
# ══════════════════════════════════════════════════════════════════════════════

# Path to the ZIP file containing .ttf fonts.
# Examples:
#   Local path : "C:\Staging\CorporateFonts.zip"
#   Network UNC : "\\fileserver\IT\Fonts\CorporateFonts.zip"
#   Same folder as script: (Join-Path $PSScriptRoot "CorporateFonts.zip")
$ZipPath = "C:\INS-Temp\Fonts.zip"

# Path to write the deployment log.
$LogPath = "C:\INS-Temp\Fonts-Installer.log"

# Set to $true to overwrite fonts that are already installed.
# Set to $false to skip fonts whose filename and size already match.
$Force = $true

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS      = 0
$EXIT_FAILURE      = 1
$EXIT_PREREQ_ERROR = 2
$EXIT_PARTIAL      = 3

$exitCode   = $EXIT_SUCCESS
$tempDir    = $null
$installed  = 0
$skipped    = 0
$failed     = 0

# ── Logging ───────────────────────────────────────────────────────────────────
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Error   $Message }
        'WARN'  { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Output  $Message }
    }
}

Write-Log "===== Fonts-Installer started | Host: $env:COMPUTERNAME | User: $env:USERNAME ====="
Write-Log "ZipPath : $ZipPath"
Write-Log "LogPath : $LogPath"
Write-Log "Force   : $Force"

# ── Helper: register a font in HKLM ──────────────────────────────────────────
function Register-Font {
    param([string]$FontFile)

    $fontRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $fontName    = [System.IO.Path]::GetFileNameWithoutExtension($FontFile)
    $regValue    = "$fontName (TrueType)"
    $fileName    = [System.IO.Path]::GetFileName($FontFile)

    try {
        Set-ItemProperty -Path $fontRegPath -Name $regValue -Value $fileName -Type String -Force
        Write-Log "  Registered in registry: '$regValue' = '$fileName'"
        return $true
    } catch {
        Write-Log "  Failed to register font in registry: $FontFile - $_" -Level ERROR
        return $false
    }
}

# ── Helper: notify GDI that fonts have changed (no reboot needed) ─────────────
function Invoke-FontCacheRefresh {
    $signature = @'
[DllImport("gdi32.dll")]
public static extern int AddFontResource(string lpFileName);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
'@
    try {
        $type = Add-Type -MemberDefinition $signature -Name FontAPI -Namespace Win32 -PassThru -ErrorAction SilentlyContinue
        $HWND_BROADCAST  = [IntPtr]0xFFFF
        $WM_FONTCHANGE   = 0x001D

        foreach ($t in $type) {
            if ($t.Name -eq 'FontAPI') {
                $null = $t::SendMessage($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero)
                Write-Log "GDI WM_FONTCHANGE broadcast sent - running apps will see new fonts."
                return
            }
        }
    } catch {
        Write-Log "Could not broadcast WM_FONTCHANGE (non-fatal): $_" -Level WARN
    }
}

# ═════════════════════════════════════════════════════════════════════════════
try {

    # ── 1. Validate ZIP ───────────────────────────────────────────────────────
    $ZipPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ZipPath)
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        Write-Log "ZIP file not found: $ZipPath" -Level ERROR
        $exitCode = $EXIT_PREREQ_ERROR
        exit $exitCode
    }

    $zipItem = Get-Item -LiteralPath $ZipPath
    Write-Log "ZIP file: $($zipItem.FullName) ($([math]::Round($zipItem.Length / 1KB, 1)) KB)"

    # ── 2. Extract to temp dir ────────────────────────────────────────────────
    $tempDir = Join-Path $env:TEMP ("FontInstall_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Log "Extracting ZIP to temp: $tempDir"

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)
    } catch {
        Write-Log "Failed to extract ZIP: $_" -Level ERROR
        $exitCode = $EXIT_PREREQ_ERROR
        exit $exitCode
    }

    # ── 3. Enumerate TTF files (recurse into sub-folders) ─────────────────────
    $ttfFiles = Get-ChildItem -Path $tempDir -Filter '*.ttf' -Recurse -File
    Write-Log "Found $($ttfFiles.Count) .ttf file(s) in archive."

    if ($ttfFiles.Count -eq 0) {
        Write-Log "No .ttf files found in: $ZipPath" -Level WARN
        $exitCode = $EXIT_PREREQ_ERROR
        exit $exitCode
    }

    # ── 4. Install each font ──────────────────────────────────────────────────
    $fontsDir    = Join-Path $env:WINDIR 'Fonts'
    $fontRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    foreach ($ttf in $ttfFiles) {
        $destPath = Join-Path $fontsDir $ttf.Name
        Write-Log "Processing: $($ttf.Name)"

        # Skip if already installed (same name AND same size) unless -Force
        if (-not $Force -and (Test-Path -LiteralPath $destPath)) {
            $existing = Get-Item -LiteralPath $destPath
            if ($existing.Length -eq $ttf.Length) {
                Write-Log "  Already installed (same size). Skipping."
                $skipped++
                continue
            } else {
                Write-Log "  Exists but size differs (existing=$($existing.Length) new=$($ttf.Length)). Reinstalling." -Level WARN
            }
        }

        try {
            # Copy to system fonts directory
            Copy-Item -LiteralPath $ttf.FullName -Destination $destPath -Force
            Write-Log "  Copied to: $destPath"

            # Register in HKLM
            $regOk = Register-Font -FontFile $destPath
            if (-not $regOk) {
                # File is copied but not registered - count as partial
                $failed++
                continue
            }

            $installed++
            Write-Log "  Installed OK: $($ttf.Name)"
        } catch {
            Write-Log "  Failed to install $($ttf.Name): $_" -Level ERROR
            $failed++
        }
    }

    # ── 5. Broadcast font change to running processes ─────────────────────────
    if ($installed -gt 0) {
        Invoke-FontCacheRefresh
    }

    # ── 6. Summary ────────────────────────────────────────────────────────────
    Write-Log "-------------------------------------------"
    Write-Log "Summary: Installed=$installed | Skipped=$skipped | Failed=$failed"

    if ($failed -gt 0 -and $installed -eq 0) {
        Write-Log "All font installations failed." -Level ERROR
        $exitCode = $EXIT_FAILURE
    } elseif ($failed -gt 0) {
        Write-Log "Partial success - $failed font(s) failed to install." -Level WARN
        $exitCode = $EXIT_PARTIAL
    } else {
        Write-Log "All fonts processed successfully."
        $exitCode = $EXIT_SUCCESS
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    # ── Cleanup temp dir ──────────────────────────────────────────────────────
    if ($tempDir -and (Test-Path $tempDir)) {
        try {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Temp directory cleaned up: $tempDir"
        } catch {
            Write-Log "Could not remove temp dir '$tempDir': $_" -Level WARN
        }
    }

    Write-Log "===== Fonts-Installer finished. Exit code: $exitCode ====="
    exit $exitCode
}
