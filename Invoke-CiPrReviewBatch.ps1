#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Batch dry-run: runs every diff in a directory through Invoke-CiPrReviewDryRun.ps1, captures each
  full report under an output directory, and prints/writes one comparison table across all diffs.

.DESCRIPTION
  Each diff is run in its own child 'pwsh' process so a per-diff exit code never affects the batch.
  Per diff, writes:  <name>.txt (full report), <name>.findings.json, <name>.summary.json.
  Aggregate:         summary.json (array) + summary.md (table), also printed to the console.

  Live mode needs ANTHROPIC_API_KEY + the 'claude' CLI. -MockFindingsPath runs every diff offline
  against the same fixture (validates the plumbing without API spend).

.EXAMPLE
  ./Invoke-CiPrReviewBatch.ps1 -RepoRoot ./AgenticPr
.EXAMPLE
  ./Invoke-CiPrReviewBatch.ps1 -MockFindingsPath samples/mock-findings.json
#>
[CmdletBinding()]
param(
    [string] $DiffDirectory = (Join-Path $PSScriptRoot 'TestDiffs'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'TestDiffs/results'),
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'ci-review.config.json'),
    [string] $RepoRoot = '.',
    [string] $MockFindingsPath,
    [string] $Pattern = '*.diff'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dryRunScript = Join-Path $PSScriptRoot 'Invoke-CiPrReviewDryRun.ps1'
if (-not (Test-Path -LiteralPath $dryRunScript)) { throw "Dry-run script not found: $dryRunScript" }
if (-not (Test-Path -LiteralPath $DiffDirectory)) { throw "Diff directory not found: $DiffDirectory" }

$diffs = @(Get-ChildItem -LiteralPath $DiffDirectory -Filter $Pattern -File | Sort-Object Name)
if ($diffs.Count -eq 0) { throw "No diffs matching '$Pattern' in $DiffDirectory." }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$rows = @()
foreach ($diff in $diffs) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($diff.Name)
    $reportPath = Join-Path $OutputDirectory "$base.txt"
    $findingsPath = Join-Path $OutputDirectory "$base.findings.json"
    $summaryPath = Join-Path $OutputDirectory "$base.summary.json"

    Write-Host ("Running {0} ..." -f $diff.Name) -ForegroundColor Cyan

    $invokeArgs = @(
        '-NoProfile', '-File', $dryRunScript,
        '-DiffPath', $diff.FullName,
        '-ConfigPath', $ConfigPath,
        '-RepoRoot', $RepoRoot,
        '-OutFile', $findingsPath,
        '-SummaryJsonPath', $summaryPath,
        '-DiffLabel', $base
    )
    if ($MockFindingsPath) { $invokeArgs += @('-MockFindingsPath', $MockFindingsPath) }

    & pwsh @invokeArgs *> $reportPath
    $childExit = $LASTEXITCODE

    if (Test-Path -LiteralPath $summaryPath) {
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $status = if (@($summary.failedReviewers).Count -gt 0) { 'INCOMPLETE' } else { 'OK' }
        $rows += [pscustomobject]@{
            Diff       = $summary.label
            Findings   = $summary.totalFindings
            Crit       = $summary.bySeverity.critical
            High       = $summary.bySeverity.high
            Med        = $summary.bySeverity.medium
            Low        = $summary.bySeverity.low
            Breaching  = $summary.breaching
            WouldBlock = $summary.wouldBlock
            Failed     = (@($summary.failedReviewers) -join ',')
            Status     = $status
        }
    }
    else {
        $rows += [pscustomobject]@{
            Diff = $base; Findings = 0; Crit = 0; High = 0; Med = 0; Low = 0
            Breaching = 0; WouldBlock = $false; Failed = ''; Status = "ERROR(exit $childExit)"
        }
    }
}

Write-Host ''
Write-Host '=== Batch summary ===' -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-String | Write-Host

$markdown = @(
    '| Diff | Findings | Crit | High | Med | Low | Breaching | Would block | Failed | Status |',
    '|---|---|---|---|---|---|---|---|---|---|'
)
foreach ($row in $rows) {
    $markdown += "| $($row.Diff) | $($row.Findings) | $($row.Crit) | $($row.High) | $($row.Med) | $($row.Low) | $($row.Breaching) | $($row.WouldBlock) | $($row.Failed) | $($row.Status) |"
}
$markdownPath = Join-Path $OutputDirectory 'summary.md'
$summaryJsonPath = Join-Path $OutputDirectory 'summary.json'
($markdown -join "`n") | Set-Content -LiteralPath $markdownPath -Encoding utf8
$rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryJsonPath -Encoding utf8

$errorCount = @($rows | Where-Object { $_.Status -like 'ERROR*' }).Count
$blockCount = @($rows | Where-Object { $_.WouldBlock }).Count
Write-Host ("Diffs: {0} | would-block: {1} | errors: {2}" -f $rows.Count, $blockCount, $errorCount)
Write-Host ("Reports + summary written to {0}" -f $OutputDirectory)

exit $(if ($errorCount -gt 0) { 1 } else { 0 })
