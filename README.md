# CI PR Review — diff-only reviewer trio

Tier-1 pull-request review for **GitHub Actions**. Runs three Claude Code reviewer agents headless
against a PR diff and posts findings back to the PR as a review. Reviews **C# and TypeScript**.
**No GavinBrain dependency** — the vendored agents under `agents/` are brain-free, so this runs on
any GitHub runner.

## Layout

| File | Purpose |
|---|---|
| `ci-review.config.json` | Enforcement posture, reviewer selection, target languages. |
| `schemas/ci-review-config.schema.json` | Schema for the config. |
| `schemas/ci-review-finding.schema.json` | Normalized finding envelope all three reviewers emit. |
| `CiReviewCore.ps1` | Shared library — reviewer invocation, normalization, diff parsing, gate/post planning. Dot-sourced by both entrypoints. |
| `Invoke-CiPrReview.ps1` | GitHub Actions entrypoint — adds PR context, posting, and the main flow. |
| `Invoke-CiPrReviewDryRun.ps1` | Local validation harness — runs the reviewers on a diff and prints findings + a post preview. Posts nothing. |
| `Invoke-CiPrReviewBatch.ps1` | Runs every diff in a directory through the harness, captures each report, and prints one comparison table. |
| `.github/workflows/ci-pr-review.yml` | GitHub Actions workflow. |
| `agents/` | Vendored, **brain-free** reviewer definitions (`blind-hunter`, `edge-case-hunter`, `code-reviewer`), tuned for C# + TS. |
| `samples/` | A sample diff + mock findings for the dry-run harness. |

## How it runs

On each PR the workflow checks out the PR, installs the Claude Code CLI, and runs the orchestrator:

1. **Reviewer invocation** — each reviewer runs via `claude -p --output-format json`, fanned out in
   parallel (`Start-ThreadJob`; sequential fallback if unavailable), with **neutral handoff**:
   - `blind-hunter` and `edge-case-hunter` run in an **empty temp directory with no filesystem
     tools** (`--disallowedTools Read Grep Glob …`). The diff (and, for edge-case-hunter, a
     CI-assembled facts-only Reachability Brief) is the only input — blindness is preserved even
     though the repo is checked out.
   - `code-reviewer` runs in the **repo root with `Read Grep Glob`** for full-file context.
   - Model + system prompt come from each vendored `agents/*.md`. Failed/empty reviewers are
     retried once, then surfaced as INCOMPLETE in the posted review (never silently dropped).
2. **Posting** — findings become one PR review via `POST /pulls/{n}/reviews`. Findings whose line
   is in the diff become inline comments; the rest go in the review body. The diff is parsed to know
   which lines are commentable, so non-diff-line comments don't 422 the whole review (with a
   body-only fallback if a post fails). Prior bot comments tagged with `botThreadMarker` are deleted
   first to avoid duplicate spam on re-push.

## Validate locally before deploying (dry run)

`Invoke-CiPrReviewDryRun.ps1` runs the exact reviewer path the pipeline uses (shared via
`CiReviewCore.ps1`) against a diff, then prints findings, the gate decision, and a preview of the PR
review that WOULD be posted — without posting or needing a GitHub token.

```powershell
# Live (calls Claude; needs ANTHROPIC_API_KEY + the claude CLI):
./Invoke-CiPrReviewDryRun.ps1 -DiffPath samples/sample.diff
git diff main...HEAD | ./Invoke-CiPrReviewDryRun.ps1 -RepoRoot ../my-service

# Offline plumbing check (no API) — validates normalization, inline/body partition, and gate logic:
./Invoke-CiPrReviewDryRun.ps1 -DiffPath samples/sample.diff -MockFindingsPath samples/mock-findings.json
```

It exits 1 if the findings would block under the configured `enforcementMode`, else 0 — the same
decision the pipeline makes. Use `-Reviewers` to test a subset, `-FromGit '<spec>'` to diff the
current repo, and `-OutFile` to dump normalized findings JSON.

### Batch run (all diffs → one table)

`Invoke-CiPrReviewBatch.ps1` runs every `*.diff` in a directory through the harness (each in its own
child `pwsh` process), captures per-diff output, and prints/writes one comparison table.

```powershell
# Live across all TestDiffs, resolving full-file context against the target repo:
./Invoke-CiPrReviewBatch.ps1 -RepoRoot ./AgenticPr

# Offline plumbing check across all diffs (no API), same fixture for each:
./Invoke-CiPrReviewBatch.ps1 -MockFindingsPath samples/mock-findings.json
```

Defaults: `-DiffDirectory TestDiffs`, `-OutputDirectory TestDiffs/results`. Per diff it writes
`<name>.txt` (full report), `<name>.findings.json`, and `<name>.summary.json`; the aggregate goes to
`results/summary.md` + `results/summary.json`. Exit 1 if any diff errored (a would-block is reported,
not an error).

## Enforcement is a configuration setting

`ci-review.config.json::enforcementMode`:

- `advisory` — posts a `COMMENT` review; the check always succeeds (exit 0).
- `blocking` — a finding at/above `blockingSeverityThreshold` posts a `REQUEST_CHANGES` review and
  **fails the check** (exit 1). With branch protection requiring this check, the PR can't merge.

`targetLanguages` (`["csharp","typescript"]`) is passed into every reviewer prompt so the right rule
variants apply. A missing/invalid config, missing PR context, or missing `ANTHROPIC_API_KEY` **fails
the run** — no silent defaults.

## Wiring it up in GitHub

1. **Place the files at the repo root** so `.github/workflows/ci-pr-review.yml` is discovered and
   `Invoke-CiPrReview.ps1` / `agents/` / `schemas/` sit alongside it.
2. **Secret** — add `ANTHROPIC_API_KEY` (Settings → Secrets and variables → Actions).
3. **Token** — the workflow passes the automatic `GITHUB_TOKEN` (with `pull-requests: write`) as
   `GH_TOKEN`; no extra setup.
4. **Blocking** — to enforce, add a branch protection rule (or ruleset) requiring the **CI PR
   Review** status check to pass.

## Caveats

- **CLI flag drift.** Invocation uses `claude -p --output-format json --append-system-prompt
  --allowedTools/--disallowedTools --model --max-turns`. If a Claude Code CLI version renames these,
  adjust `Build-ClaudeArguments` in `Invoke-CiPrReview.ps1`.
- **Reviewer failure is surfaced, not fatal.** A reviewer that fails twice is reported as INCOMPLETE
  in the review body and logged at Error level, but does not by itself fail the check (avoids
  wedging PRs on a flaky API). Change this in `Resolve-GateDecision` if you want stricter behavior.
- **Brain-free vendored agents.** The `agents/` copies are intentionally forked from
  `~/.claude/agents/`: removed the `gavin-brain-mcp` tools + brain-consultation, the BMAD-gate /
  orchestration plumbing (Planning-Coordinator, `gate-controller.ps1`/`decision-log.json`,
  attestations, FailedLayersTripwire, `~/.claude/**` paths), and the "No YAML" checklist row (this
  repo uses Actions YAML). Kept: handoff immunization, blind/intent-blind input contracts, the
  hunting rubrics, the dual-language (C#/TS) hard-rule checklist. Re-vendoring requires re-applying
  these removals.

## Note

The wider environment is Azure DevOps; this tooling targets GitHub Actions per an explicit decision
for this repo. The no-YAML hard rule is waived only under `C:\Development\inter\` (see the dated
exemption in `yaml-blocker.ps1`); it stands everywhere else.
