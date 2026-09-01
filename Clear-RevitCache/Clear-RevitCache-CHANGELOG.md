# Changelog — Clear-RevitCache.ps1

## 2026-09-01

- Replaced `-WhatIf` / `-Confirm` (`SupportsShouldProcess`) with a `$ReportOnly`
  configuration variable. When `$true`, the script performs the same discovery and
  staleness filter and logs how much space would be freed, without deleting anything.
  A report-only run always exits `0`.
- `Clear-CacheFolder` now takes an explicit `-ReportOnly` switch and measures instead of
  deleting when set.
- Per-folder and summary log lines are mode-aware (`Scanning`/`Cleaning`,
  `Reclaimable`/`Freed`) and now include the MB freed/reclaimable per folder.
- The script emits a summary object to the pipeline (`ReportOnly`, `Folders`, `Files`,
  `Bytes`, `FreedMB`, `Failed`) so callers can consume totals without parsing the log.
- Renamed accumulators (`$filesDeleted` → `$filesAffected`, `$foldersCleared` →
  `$foldersProcessed`) and the `Clear-CacheFolder` result property (`FilesDeleted` →
  `Files`) for clarity now that the script can measure as well as delete.
- Renamed helper `Get-RevitCollaborationCachePaths` → `Get-RevitCollaborationCachePath`
  to satisfy PSScriptAnalyzer's `PSUseSingularNouns` rule.
- Added a UTF-8 BOM to the file to satisfy PSScriptAnalyzer's
  `PSUseBOMForUnicodeEncodedFile` rule (the script's banner comments use non-ASCII
  box-drawing characters).
