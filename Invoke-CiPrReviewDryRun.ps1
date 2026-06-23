#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Local dry-run harness for the CI reviewer trio. Runs the SAME reviewer-invocation path the GitHub
  pipeline uses (via CiReviewCore.ps1) against a diff, then prints findings, the gate decision, and a
  preview of what WOULD be posted to a PR. Posts nothing; needs no GitHub token.

.DESCRIPTION
  Diff source (one of): -DiffPath <file>, -FromGit '<spec>' (e.g. 'main...HEAD'), or piped stdin.
  Live mode (default) calls Claude and needs ANTHROPIC_API_KEY + the 'claude' CLI.
  -MockFindingsPath <file> skips Claude and loads a findings JSON array instead, to validate the
  partition / gate / post-preview plumbing offline and deterministically.

.EXAMPLE
  ./Invoke-CiPrReviewDryRun.ps1 -DiffPath sample.diff
.EXAMPLE
  git diff main...HEAD | ./Invoke-CiPrReviewDryRun.ps1 -RepoRoot ../my-service
.EXAMPLE
  ./Invoke-CiPrReviewDryRun.ps1 -DiffPath sample.diff -MockFindingsPath mock-findings.json
#>
[CmdletBinding()]
param(
    [string]   $DiffPath,
    [string]   $FromGit,
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'ci-review.config.json'),
    [string]   $RepoRoot = '.',
    [string[]] $Reviewers,
    [string]   $MockFindingsPath,
    [string]   $OutFile,
    [string]   $SummaryJsonPath,
    [string]   $DiffLabel
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CiReviewCore.ps1')

$script:RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Get-DryRunDiff {
    if ($DiffPath) {
        if (-not (Test-Path -LiteralPath $DiffPath)) { throw "Diff file not found: $DiffPath" }
        return (Get-Content -LiteralPath $DiffPath -Raw)
    }
    if ($FromGit) {
        return (& git -C $script:RepoRoot diff $FromGit | Out-String)
    }
    if (-not [Console]::IsInputRedirected) {
        throw 'No diff provided. Use -DiffPath, -FromGit, or pipe a diff via stdin.'
    }
    return ([Console]::In.ReadToEnd())
}

function Get-MockFindings {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Mock findings file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return @($raw | ForEach-Object {
            $reviewer = if (($_.PSObject.Properties.Name -contains 'reviewer') -and $_.reviewer) { "$($_.reviewer)" } else { 'mock' }
            ConvertTo-NormalizedFinding -Finding $_ -Reviewer $reviewer
        } | Where-Object { $_ })
}

function Write-Section { param([string] $Title) Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }

try {
    $configuration = Read-ReviewConfiguration -Path $ConfigPath
    $reviewerList = if ($Reviewers) { $Reviewers } else { @($configuration.reviewers) }
    $diff = Get-DryRunDiff
    if ([string]::IsNullOrWhiteSpace($diff)) { throw 'The supplied diff is empty.' }

    $fileCount = @([regex]::Matches($diff, '(?m)^\+\+\+ b/')).Count
    $isMock = [bool]$MockFindingsPath

    Write-Section 'CI PR Review — DRY RUN'
    Write-Host ("Config        : {0}" -f $ConfigPath)
    Write-Host ("Mode          : {0} / threshold {1}" -f $configuration.enforcementMode, $configuration.blockingSeverityThreshold)
    Write-Host ("Languages     : {0}" -f ($configuration.targetLanguages -join ', '))
    Write-Host ("Reviewers     : {0}" -f ($reviewerList -join ', '))
    Write-Host ("Repo root     : {0}" -f $script:RepoRoot)
    Write-Host ("Diff          : {0} bytes, {1} changed file(s)" -f $diff.Length, $fileCount)
    Write-Host ("Source        : {0}" -f $(if ($isMock) { "MOCK ($MockFindingsPath)" } else { 'LIVE (calls Claude)' }))

    if ($isMock) {
        $findings = Get-MockFindings -Path $MockFindingsPath
        $failed = @()
    }
    else {
        Assert-AnthropicKey
        Assert-ClaudeAvailable
        $trio = Invoke-ReviewerTrio -Diff $diff -Reviewers $reviewerList -TargetLanguages $configuration.targetLanguages
        $findings = @($trio.Findings)
        $failed = @($trio.FailedReviewers)
    }

    Write-Section ("Findings ({0})" -f @($findings).Count)
    if (@($findings).Count -eq 0) {
        Write-Host '(none)'
    }
    else {
        foreach ($finding in ($findings | Sort-Object @{ Expression = { $script:SeverityRank[$_.severity] }; Descending = $true }, filePath)) {
            $locator = if ($finding.line) { "$($finding.filePath):$($finding.line)" } else { $finding.filePath }
            Write-Host ("[{0,-8}] {1,-16} {2}" -f $finding.severity, $finding.reviewer, $locator) -ForegroundColor Yellow
            Write-Host ("            {0}" -f $finding.title)
            if ($finding.detail) { Write-Host ("            {0}" -f $finding.detail) -ForegroundColor DarkGray }
        }
    }

    if (@($failed).Count -gt 0) {
        Write-Host ''
        Write-Host ("INCOMPLETE — reviewers that did not complete: {0}" -f ($failed -join ', ')) -ForegroundColor Red
    }

    $decision = Resolve-GateDecision -Findings $findings -Configuration $configuration
    $marker = if ($configuration.botThreadMarker) { $configuration.botThreadMarker } else { '[ci-review]' }
    $plan = Get-ReviewPlan -Findings $findings -Configuration $configuration -Diff $diff -Marker $marker

    Write-Section 'Gate decision'
    Write-Host ("enforcementMode : {0}" -f $decision.EnforcementMode)
    Write-Host ("findings        : {0}  (breaching >= {1}: {2})" -f $decision.TotalFindingCount, $configuration.blockingSeverityThreshold, $decision.BreachingCount)
    if ($decision.ShouldBlock) {
        Write-Host 'WOULD BLOCK     : YES (check fails, exit 1)' -ForegroundColor Red
    }
    else {
        Write-Host 'WOULD BLOCK     : no (check passes, exit 0)' -ForegroundColor Green
    }

    Write-Section 'GitHub post preview (NOT sent)'
    Write-Host ("review event    : {0}" -f $plan.Event)
    Write-Host ("inline comments : {0}" -f @($plan.Inline).Count)
    Write-Host ("body-only items : {0}" -f @($plan.BodyOnly).Count)
    foreach ($comment in @($plan.Inline)) { Write-Host ("  inline  {0}:{1}" -f $comment.path, $comment.line) -ForegroundColor DarkGray }
    foreach ($item in @($plan.BodyOnly)) { Write-Host ("  body    {0}" -f $item) -ForegroundColor DarkGray }

    if ($OutFile) {
        $findings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding utf8
        Write-Host ''
        Write-Host ("Findings written to {0}" -f $OutFile)
    }

    if ($SummaryJsonPath) {
        $bySeverity = [ordered]@{ critical = 0; high = 0; medium = 0; low = 0 }
        foreach ($finding in $findings) { if ($bySeverity.Contains($finding.severity)) { $bySeverity[$finding.severity]++ } }
        $label = if ($DiffLabel) { $DiffLabel } elseif ($DiffPath) { Split-Path -Leaf $DiffPath } else { 'stdin' }
        [pscustomobject]@{
            label           = $label
            source          = if ($isMock) { 'mock' } else { 'live' }
            totalFindings   = $decision.TotalFindingCount
            bySeverity      = $bySeverity
            breaching       = $decision.BreachingCount
            enforcementMode = $decision.EnforcementMode
            wouldBlock      = $decision.ShouldBlock
            failedReviewers = @($failed)
            inlineComments  = @($plan.Inline).Count
            bodyOnly        = @($plan.BodyOnly).Count
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryJsonPath -Encoding utf8
    }

    exit $(if ($decision.ShouldBlock) { 1 } else { 0 })
}
catch {
    Write-Host ("DRY RUN FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
