#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared CI-review library. Dot-source this; it defines functions + script-scoped state but runs
  no main flow. Used by Invoke-CiPrReview.ps1 (GitHub entrypoint) and Invoke-CiPrReviewDryRun.ps1
  (local validation harness) so both exercise the SAME reviewer-invocation path.

  Script state (callers may override after dot-sourcing):
    $script:ScriptRoot  - directory holding agents/ and schemas/ (defaults to this file's dir)
    $script:RepoRoot    - directory of the code under review; code-reviewer's working dir
                          (defaults to $script:ScriptRoot; the harness sets it to the target repo)
#>

$script:CorrelationId = [System.Guid]::CreateVersion7().ToString()
$script:ScriptRoot = $PSScriptRoot
$script:RepoRoot = $PSScriptRoot
$script:SeverityRank = @{ low = 1; medium = 2; high = 3; critical = 4 }

function Write-StructuredLog {
    param(
        [Parameter(Mandatory)] [ValidateSet('Information', 'Warning', 'Error')] [string] $Level,
        [Parameter(Mandatory)] [string] $EventName,
        [hashtable] $Data = @{}
    )
    $record = [ordered]@{
        timestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        event         = $EventName
        correlationId = $script:CorrelationId
    }
    foreach ($key in $Data.Keys) { $record[$key] = $Data[$key] }
    Write-Output ($record | ConvertTo-Json -Compress -Depth 6)
}

function Read-ReviewConfiguration {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration not found at '$Path'. Fast-fail: refusing to assume an enforcement mode."
    }

    $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    if ($configuration.enforcementMode -notin @('advisory', 'blocking')) {
        throw "Invalid enforcementMode '$($configuration.enforcementMode)'. Expected 'advisory' or 'blocking'."
    }
    if ($configuration.blockingSeverityThreshold -notin @('low', 'medium', 'high', 'critical')) {
        throw "Invalid blockingSeverityThreshold '$($configuration.blockingSeverityThreshold)'."
    }
    if (-not $configuration.targetLanguages -or @($configuration.targetLanguages).Count -lt 1) {
        throw 'targetLanguages must list at least one language.'
    }

    return $configuration
}

function Assert-AnthropicKey {
    if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
        throw "Required environment variable 'ANTHROPIC_API_KEY' is not set."
    }
}

function Assert-ClaudeAvailable {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        throw "The 'claude' CLI is not on PATH. Install it (npm install -g @anthropic-ai/claude-code)."
    }
}

function Get-AgentDefinition {
    param([Parameter(Mandatory)] [string] $Reviewer)

    $path = Join-Path $script:ScriptRoot "agents/$Reviewer.md"
    if (-not (Test-Path -LiteralPath $path)) { throw "Vendored agent definition not found: $path" }

    $raw = Get-Content -LiteralPath $path -Raw
    $match = [regex]::Match($raw, '(?s)^\s*---\s*(.*?)\s*---\s*(.*)$')
    if (-not $match.Success) { throw "Agent file '$path' is missing YAML frontmatter." }

    $model = ([regex]::Match($match.Groups[1].Value, '(?m)^model:\s*(\S+)')).Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'sonnet' }

    return [pscustomobject]@{ Model = $model; SystemPrompt = $match.Groups[2].Value }
}

function Build-ReachabilityBrief {
    param([Parameter(Mandatory)] [string] $Diff, [Parameter(Mandatory)] [string[]] $TargetLanguages)

    $files = @()
    foreach ($line in ($Diff -split "\r?\n")) {
        if ($line -match '^\+\+\+ b/(.+)$') { $files += $Matches[1] }
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('REACHABILITY BRIEF (facts only; CI-assembled). Use the Missing-fact protocol for anything below marked NOT PROVIDED.')
    [void]$builder.AppendLine("Target languages: $($TargetLanguages -join ', ').")
    [void]$builder.AppendLine('Changed files:')
    foreach ($file in ($files | Select-Object -Unique)) { [void]$builder.AppendLine("  - $file") }
    [void]$builder.AppendLine('NOT PROVIDED: DB schema / DDL / migrations, type-closure beyond the diff, upstream call-site contracts, cross-cutting architectural invariants, runtime configuration.')
    return $builder.ToString()
}

function Build-ReviewerUserPrompt {
    param(
        [Parameter(Mandatory)] [string]   $Reviewer,
        [Parameter(Mandatory)] [string]   $Diff,
        [Parameter(Mandatory)] [string]   $Brief,
        [Parameter(Mandatory)] [string[]] $TargetLanguages
    )

    $languages = $TargetLanguages -join ', '
    $instruction = "Target languages for this repository: $languages. Output ONLY a JSON array of findings conforming to the ci-review-finding schema (fields: reviewer, severity in [low,medium,high,critical], filePath, line or null, title, detail, optional ruleId). No prose, no code fences. Output an empty array [] if there is nothing to report."

    switch ($Reviewer) {
        'edge-case-hunter' { return "$instruction`n`n$Brief`n`n--- DIFF ---`n$Diff" }
        'code-reviewer'    { return "$instruction You may read files in the working directory for full-file context.`n`n--- DIFF ---`n$Diff" }
        default            { return "$instruction`n`n--- DIFF ---`n$Diff" }
    }
}

function Get-ReviewerToolPolicy {
    param([Parameter(Mandatory)] [string] $Reviewer)

    if ($Reviewer -eq 'code-reviewer') {
        return [pscustomobject]@{
            AllowedTools     = 'Read Grep Glob'
            DisallowedTools  = $null
            WorkingDirectory = $script:RepoRoot
            MaxTurns         = 8
        }
    }

    $isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-review-" + [System.Guid]::CreateVersion7().ToString())
    New-Item -ItemType Directory -Path $isolated -Force | Out-Null
    return [pscustomobject]@{
        AllowedTools     = $null
        DisallowedTools  = 'Read Grep Glob Bash Edit Write WebFetch WebSearch Task'
        WorkingDirectory = $isolated
        MaxTurns         = 2
    }
}

function Build-ClaudeArguments {
    param([Parameter(Mandatory)] [object] $Definition, [Parameter(Mandatory)] [object] $ToolPolicy)

    $arguments = @('-p', '--output-format', 'json', '--model', $Definition.Model, '--max-turns', [string]$ToolPolicy.MaxTurns)
    if ($ToolPolicy.AllowedTools)    { $arguments += @('--allowedTools', $ToolPolicy.AllowedTools) }
    if ($ToolPolicy.DisallowedTools) { $arguments += @('--disallowedTools', $ToolPolicy.DisallowedTools) }
    $arguments += @('--append-system-prompt', $Definition.SystemPrompt)
    return $arguments
}

function ConvertTo-NormalizedFinding {
    param([Parameter(Mandatory)] [object] $Finding, [Parameter(Mandatory)] [string] $Reviewer)

    $filePath = "$($Finding.filePath)"
    $title = "$($Finding.title)"
    if ([string]::IsNullOrWhiteSpace($filePath) -or [string]::IsNullOrWhiteSpace($title)) {
        Write-StructuredLog -Level Warning -EventName 'ci-review.finding-dropped' -Data @{ reviewer = $Reviewer; reason = 'missing filePath or title' }
        return $null
    }

    $severity = "$($Finding.severity)".ToLowerInvariant()
    if ($severity -notin @('low', 'medium', 'high', 'critical')) { $severity = 'medium' }

    $line = $null
    if (($Finding.PSObject.Properties.Name -contains 'line') -and $Finding.line) { $line = [int]$Finding.line }

    $ruleId = $null
    if ($Finding.PSObject.Properties.Name -contains 'ruleId') { $ruleId = "$($Finding.ruleId)" }

    return [pscustomobject]@{
        reviewer = $Reviewer
        severity = $severity
        filePath = $filePath
        line     = $line
        title    = $title
        detail   = "$($Finding.detail)"
        ruleId   = $ruleId
    }
}

function ConvertFrom-ReviewerOutput {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw, [Parameter(Mandatory)] [string] $Reviewer)

    if ([string]::IsNullOrWhiteSpace($Raw)) { throw "empty output from $Reviewer" }

    $envelope = $Raw | ConvertFrom-Json
    if (($envelope.PSObject.Properties.Name -contains 'is_error') -and $envelope.is_error) {
        throw "claude reported an error for ${Reviewer}: $($envelope.result)"
    }

    $text = "$($envelope.result)".Trim()
    $text = [regex]::Replace($text, '(?s)^```(?:json)?\s*', '')
    $text = [regex]::Replace($text, '(?s)\s*```$', '')

    $start = $text.IndexOf('[')
    $end = $text.LastIndexOf(']')
    if ($start -lt 0 -or $end -lt $start) { throw "no JSON array found in $Reviewer output" }

    $parsed = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed | ForEach-Object { ConvertTo-NormalizedFinding -Finding $_ -Reviewer $Reviewer } | Where-Object { $_ })
}

function Invoke-ReviewerSynchronously {
    param(
        [Parameter(Mandatory)] [string]   $Reviewer,
        [Parameter(Mandatory)] [string]   $Diff,
        [Parameter(Mandatory)] [string]   $Brief,
        [Parameter(Mandatory)] [string[]] $TargetLanguages
    )

    $definition = Get-AgentDefinition -Reviewer $Reviewer
    $prompt = Build-ReviewerUserPrompt -Reviewer $Reviewer -Diff $Diff -Brief $Brief -TargetLanguages $TargetLanguages
    $policy = Get-ReviewerToolPolicy -Reviewer $Reviewer
    $arguments = Build-ClaudeArguments -Definition $definition -ToolPolicy $policy

    Push-Location -LiteralPath $policy.WorkingDirectory
    try { $raw = $prompt | & claude @arguments | Out-String }
    finally { Pop-Location }

    return ConvertFrom-ReviewerOutput -Raw $raw -Reviewer $Reviewer
}

function Invoke-ReviewerTrio {
    param(
        [Parameter(Mandatory)] [string]   $Diff,
        [Parameter(Mandatory)] [string[]] $Reviewers,
        [Parameter(Mandatory)] [string[]] $TargetLanguages
    )

    $brief = Build-ReachabilityBrief -Diff $Diff -TargetLanguages $TargetLanguages
    $canParallel = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    $findings = [System.Collections.Generic.List[object]]::new()
    $failed = @()

    $jobs = @{}
    if ($canParallel) {
        foreach ($reviewer in $Reviewers) {
            $definition = Get-AgentDefinition -Reviewer $reviewer
            $prompt = Build-ReviewerUserPrompt -Reviewer $reviewer -Diff $Diff -Brief $brief -TargetLanguages $TargetLanguages
            $policy = Get-ReviewerToolPolicy -Reviewer $reviewer
            $arguments = Build-ClaudeArguments -Definition $definition -ToolPolicy $policy
            $jobs[$reviewer] = Start-ThreadJob -ScriptBlock {
                param($claudeArgs, $stdin, $workingDirectory)
                Set-Location -LiteralPath $workingDirectory
                $stdin | & claude @claudeArgs | Out-String
            } -ArgumentList $arguments, $prompt, $policy.WorkingDirectory
        }
        $null = Wait-Job -Job (@($jobs.Values)) -Timeout 900
    }

    foreach ($reviewer in $Reviewers) {
        $result = $null

        if ($canParallel) {
            $job = $jobs[$reviewer]
            if ($job.State -eq 'Completed') {
                try { $result = @(ConvertFrom-ReviewerOutput -Raw (Receive-Job -Job $job | Out-String) -Reviewer $reviewer) }
                catch { $result = $null; Write-StructuredLog -Level Warning -EventName 'ci-review.parse-failed' -Data @{ reviewer = $reviewer; message = $_.Exception.Message } }
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        if ($null -eq $result) {
            Write-StructuredLog -Level Warning -EventName 'ci-review.retry' -Data @{ reviewer = $reviewer }
            try { $result = @(Invoke-ReviewerSynchronously -Reviewer $reviewer -Diff $Diff -Brief $brief -TargetLanguages $TargetLanguages) }
            catch { $result = $null; Write-StructuredLog -Level Error -EventName 'ci-review.reviewer-failed' -Data @{ reviewer = $reviewer; message = $_.Exception.Message } }
        }

        if ($null -eq $result) { $failed += $reviewer; continue }
        foreach ($finding in $result) { $findings.Add($finding) }
        Write-StructuredLog -Level Information -EventName 'ci-review.reviewer-done' -Data @{ reviewer = $reviewer; findings = @($result).Count }
    }

    return [pscustomobject]@{ Findings = $findings.ToArray(); FailedReviewers = $failed }
}

function Get-CommentableLine {
    param([Parameter(Mandatory)] [string] $Diff)

    $map = @{}
    $currentFile = $null
    $newLine = 0
    foreach ($line in ($Diff -split "\r?\n")) {
        if ($line -match '^\+\+\+ b/(.+)$') {
            $currentFile = $Matches[1]
            if (-not $map.ContainsKey($currentFile)) { $map[$currentFile] = [System.Collections.Generic.HashSet[int]]::new() }
            continue
        }
        if ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') { $newLine = [int]$Matches[1]; continue }
        if ($null -eq $currentFile) { continue }
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { [void]$map[$currentFile].Add($newLine); $newLine++; continue }
        if ($line.StartsWith('-') -and -not $line.StartsWith('---')) { continue }
        if ($line.StartsWith(' ')) { [void]$map[$currentFile].Add($newLine); $newLine++; continue }
    }
    return $map
}

function Get-SeverityEmoji {
    param([string] $Severity)
    switch ($Severity) {
        'critical' { return [System.Char]::ConvertFromUtf32(0x26D4) }
        'high'     { return [System.Char]::ConvertFromUtf32(0x1F534) }
        'medium'   { return [System.Char]::ConvertFromUtf32(0x1F7E1) }
        default    { return [System.Char]::ConvertFromUtf32(0x1F7E2) }
    }
}

function Get-ReviewPlan {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings,
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [string] $Diff,
        [Parameter(Mandatory)] [string] $Marker
    )

    $commentable = Get-CommentableLine -Diff $Diff
    $inline = @()
    $bodyOnly = @()
    foreach ($finding in $Findings) {
        $emoji = Get-SeverityEmoji -Severity $finding.severity
        $commentBody = "$Marker $emoji **[$($finding.reviewer)/$($finding.severity)]** $($finding.title)`n`n$($finding.detail)"
        if ($finding.line -and $commentable.ContainsKey($finding.filePath) -and $commentable[$finding.filePath].Contains([int]$finding.line)) {
            $inline += @{ path = $finding.filePath; line = [int]$finding.line; side = 'RIGHT'; body = $commentBody }
        }
        else {
            $locator = if ($finding.line) { "$($finding.filePath):$($finding.line)" } else { $finding.filePath }
            $bodyOnly += "- $emoji **[$($finding.reviewer)/$($finding.severity)]** ``$locator`` — $($finding.title)"
        }
    }

    $threshold = $script:SeverityRank[$Configuration.blockingSeverityThreshold]
    $breaching = @($Findings | Where-Object { $script:SeverityRank[$_.severity] -ge $threshold }).Count
    $event = if (($Configuration.enforcementMode -eq 'blocking') -and ($breaching -gt 0)) { 'REQUEST_CHANGES' } else { 'COMMENT' }

    return [pscustomobject]@{ Event = $event; Inline = $inline; BodyOnly = $bodyOnly; Breaching = $breaching }
}

function Resolve-GateDecision {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings, [Parameter(Mandatory)] [object] $Configuration)

    $threshold = $script:SeverityRank[$Configuration.blockingSeverityThreshold]
    $breaching = @($Findings | Where-Object { $script:SeverityRank[$_.severity] -ge $threshold })
    $shouldBlock = ($Configuration.enforcementMode -eq 'blocking') -and ($breaching.Count -gt 0)

    return [pscustomobject]@{
        EnforcementMode   = $Configuration.enforcementMode
        BreachingCount    = $breaching.Count
        TotalFindingCount = @($Findings).Count
        ShouldBlock       = $shouldBlock
    }
}
