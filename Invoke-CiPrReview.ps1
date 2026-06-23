#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CI PR review orchestrator (GitHub Actions entrypoint) - runs the diff-only reviewer trio against a
  pull-request diff and posts findings to GitHub. Shared logic lives in CiReviewCore.ps1.

.DESCRIPTION
  Enforcement posture (advisory vs blocking) and target languages come from ci-review.config.json.
  Validate-first / fast-fail: an invalid config, missing PR context, or a missing API key aborts.

  Expected environment (set by .github/workflows/ci-pr-review.yml):
    ANTHROPIC_API_KEY  - Claude API key (secret)
    GH_TOKEN           - GITHUB_TOKEN with pull-requests:write (required when postInlineComments)
    PR_NUMBER          - pull request number
    BASE_REF           - target branch (falls back to GITHUB_BASE_REF)
    REPOSITORY         - owner/repo (falls back to GITHUB_REPOSITORY)
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'ci-review.config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CiReviewCore.ps1')

$script:GitHubApiBase = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }

function Assert-RequiredEnvironment {
    param([Parameter(Mandatory)] [object] $Configuration)

    Assert-AnthropicKey
    Assert-ClaudeAvailable
    if ($Configuration.postInlineComments -and [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw "postInlineComments is true but 'GH_TOKEN' is not set."
    }
}

function Get-PullRequestContext {
    $pullRequestNumber = $env:PR_NUMBER
    $targetBranch = if ($env:BASE_REF) { $env:BASE_REF } else { $env:GITHUB_BASE_REF }
    $repository = if ($env:REPOSITORY) { $env:REPOSITORY } else { $env:GITHUB_REPOSITORY }

    if ([string]::IsNullOrWhiteSpace($pullRequestNumber) -or [string]::IsNullOrWhiteSpace($targetBranch) -or [string]::IsNullOrWhiteSpace($repository)) {
        throw 'Not running in a pull-request context (PR_NUMBER / BASE_REF / REPOSITORY absent).'
    }

    return [pscustomobject]@{
        PullRequestNumber = $pullRequestNumber
        TargetBranch      = ($targetBranch -replace '^refs/heads/', '')
        Repository        = $repository
    }
}

function Get-PullRequestDiff {
    param([Parameter(Mandatory)] [string] $TargetBranch)

    git fetch --no-tags origin $TargetBranch *> $null
    return (git diff "origin/$TargetBranch...HEAD")
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Path, [object] $Body)

    $headers = @{
        Authorization          = "Bearer $env:GH_TOKEN"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'ci-pr-review'
    }
    $uri = "$script:GitHubApiBase$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Publish-FindingsToPullRequest {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings,
        [Parameter(Mandatory)] [object]   $Configuration,
        [Parameter(Mandatory)] [object]   $PullRequest,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $FailedReviewers,
        [Parameter(Mandatory)] [string]   $Diff
    )

    $owner, $repo = $PullRequest.Repository -split '/', 2
    $pull = $PullRequest.PullRequestNumber
    $marker = if ($Configuration.botThreadMarker) { $Configuration.botThreadMarker } else { '[ci-review]' }

    if ($Configuration.reconcilePriorBotThreads) {
        try {
            $existing = Invoke-GitHubApi -Method GET -Path "/repos/$owner/$repo/pulls/$pull/comments?per_page=100"
            foreach ($comment in $existing) {
                if ("$($comment.body)".StartsWith($marker)) {
                    try { Invoke-GitHubApi -Method DELETE -Path "/repos/$owner/$repo/pulls/comments/$($comment.id)" | Out-Null }
                    catch { Write-StructuredLog -Level Warning -EventName 'ci-review.reconcile-delete-failed' -Data @{ commentId = $comment.id } }
                }
            }
        }
        catch { Write-StructuredLog -Level Warning -EventName 'ci-review.reconcile-list-failed' -Data @{ message = $_.Exception.Message } }
    }

    $plan = Get-ReviewPlan -Findings $Findings -Configuration $Configuration -Diff $Diff -Marker $marker

    $summary = @("$marker **CI PR Review** — $(@($Findings).Count) finding(s); $($plan.Breaching) at/above ``$($Configuration.blockingSeverityThreshold)``.")
    if (@($FailedReviewers).Count -gt 0) { $summary += "WARNING — reviewers that did not complete: $($FailedReviewers -join ', '). This review is INCOMPLETE." }
    if (@($plan.BodyOnly).Count -gt 0) { $summary += ''; $summary += 'Findings not anchored to a diff line:'; $summary += $plan.BodyOnly }
    $reviewBody = ($summary -join "`n")

    $payload = @{ event = $plan.Event; body = $reviewBody }
    if (@($plan.Inline).Count -gt 0) { $payload.comments = $plan.Inline }

    try {
        Invoke-GitHubApi -Method POST -Path "/repos/$owner/$repo/pulls/$pull/reviews" -Body $payload | Out-Null
        Write-StructuredLog -Level Information -EventName 'ci-review.posted' -Data @{ event = $plan.Event; inline = @($plan.Inline).Count; bodyOnly = @($plan.BodyOnly).Count }
    }
    catch {
        Write-StructuredLog -Level Warning -EventName 'ci-review.post-retry-bodyonly' -Data @{ message = $_.Exception.Message }
        Invoke-GitHubApi -Method POST -Path "/repos/$owner/$repo/pulls/$pull/reviews" -Body @{ event = $plan.Event; body = $reviewBody } | Out-Null
    }
}

try {
    Write-StructuredLog -Level Information -EventName 'ci-review.start' -Data @{ configPath = $ConfigPath }

    $configuration = Read-ReviewConfiguration -Path $ConfigPath
    Assert-RequiredEnvironment -Configuration $configuration
    $pullRequest = Get-PullRequestContext

    $diff = Get-PullRequestDiff -TargetBranch $pullRequest.TargetBranch
    if ([string]::IsNullOrWhiteSpace($diff)) {
        Write-StructuredLog -Level Information -EventName 'ci-review.no-diff' -Data @{ pullRequest = $pullRequest.PullRequestNumber }
        exit 0
    }

    if (($configuration.PSObject.Properties.Name -contains 'maxDiffBytes') -and ($diff.Length -gt $configuration.maxDiffBytes)) {
        Write-StructuredLog -Level Warning -EventName 'ci-review.diff-truncated' -Data @{ originalBytes = $diff.Length; maxDiffBytes = $configuration.maxDiffBytes }
        $diff = $diff.Substring(0, $configuration.maxDiffBytes)
    }

    $trio = Invoke-ReviewerTrio -Diff $diff -Reviewers $configuration.reviewers -TargetLanguages $configuration.targetLanguages

    if ($configuration.postInlineComments) {
        Publish-FindingsToPullRequest -Findings $trio.Findings -Configuration $configuration -PullRequest $pullRequest -FailedReviewers $trio.FailedReviewers -Diff $diff
    }

    $decision = Resolve-GateDecision -Findings $trio.Findings -Configuration $configuration
    Write-StructuredLog -Level Information -EventName 'ci-review.decision' -Data @{
        pullRequest     = $pullRequest.PullRequestNumber
        enforcementMode = $decision.EnforcementMode
        findings        = $decision.TotalFindingCount
        breaching       = $decision.BreachingCount
        failedReviewers = ($trio.FailedReviewers -join ',')
        shouldBlock     = $decision.ShouldBlock
    }

    if ($decision.ShouldBlock) {
        Write-StructuredLog -Level Error -EventName 'ci-review.blocked' -Data @{ pullRequest = $pullRequest.PullRequestNumber }
        exit 1
    }

    exit 0
}
catch {
    Write-StructuredLog -Level Error -EventName 'ci-review.failed' -Data @{ message = $_.Exception.Message }
    exit 1
}
