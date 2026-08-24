[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [string]$GitHubUser = "",
    [switch]$Validate,
    [switch]$RefreshInstructions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TemplateDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Resolve-GitHubUser {
    if ($GitHubUser) { return $GitHubUser }
    $origin = git -C $TemplateDir remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $origin -match 'github\.com[/:]([^/]+)/') {
        return $Matches[1]
    }
    return "your-github-user"
}

function Resolve-AgentCli {
    # strategist.sh drives the CLI with Claude Code's own flags (--allowedTools,
    # --model, -p), which codex rejects with exit 2 -- so claude wins when both are
    # installed. Returned as an msys path: the value lands in .exocortex.env, which
    # Git Bash sources.
    $candidates = @(
        (Join-Path $env:APPDATA "npm\claude"),
        (Join-Path $env:USERPROFILE ".local\bin\claude"),
        (Join-Path $env:APPDATA "npm\codex")
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { return "claude" }
    $full = [System.IO.Path]::GetFullPath($found)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    return "/$drive" + ($full.Substring(2) -replace '\\', '/')
}

function Expand-IwePlaceholders {
    param([string]$Text)

    $homeDir = [Environment]::GetFolderPath('UserProfile')
    $slug = ($Workspace -replace '[:\\/ ]', '-')
    $values = [ordered]@{
        '{{GITHUB_USER}}'         = (Resolve-GitHubUser)
        '{{WORKSPACE_DIR}}'       = $Workspace
        '{{HOME_DIR}}'            = $homeDir
        '{{CLAUDE_PATH}}'         = (Resolve-AgentCli)
        '{{CLAUDE_PROJECT_SLUG}}' = $slug
        '{{TIMEZONE_HOUR}}'       = '21'
        '{{TIMEZONE_DESC}}'       = '08:00 Asia/Sakhalin (UTC+11)'
        '{{GOVERNANCE_REPO}}'     = 'DS-strategy'
        '{{IWE_TEMPLATE}}'        = $TemplateDir
        '{{IWE_RUNTIME}}'         = (Join-Path $Workspace '.iwe-runtime')
    }
    foreach ($entry in $values.GetEnumerator()) {
        $Text = $Text.Replace($entry.Key, [string]$entry.Value)
    }
    return $Text
}

function Convert-ToCodexAgentInstructions {
    param([string]$Text)

    $Text = $Text.Replace(
        '> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-394 Ф4.2). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**',
        '> **Codex-развёртывание:** файл создаёт `FMT-exocortex-template/setup-codex.ps1`. НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.'
    )
    $Text = $Text.Replace(
        '> Общее ядро → блок `<!-- SYNC-CORE -->` в `CLAUDE.md`. Агент-специфика → `AGENTS-agent-blocks.md`.',
        '> Канонический источник → `FMT-exocortex-template/AGENTS.md`. Агент-специфика → `AGENTS-agent-blocks.md`.'
    )
    return $Text
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-MissingTree {
    param([string]$Source, [string]$Destination)
    Ensure-Directory $Destination
    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
        $target = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $target)) {
            Ensure-Directory (Split-Path -Parent $target)
            Copy-Item -LiteralPath $_.FullName -Destination $target
        }
    }
}

function Write-CodexSkill {
    param([string]$Name, [string]$Content)
    $skillPath = Join-Path $Workspace ".agents\skills\$Name\SKILL.md"
    Write-Utf8File -Path $skillPath -Content $Content
}

function Refresh-AgentInstructions {
    $adapterHeader = @'
> **Codex adapter for Windows/Yandex Disk.** This file is generated from the upstream IWE `AGENTS.md`.
> Codex-specific rules: use `.agents/skills/`; treat `.claude/hooks/`, Claude slash commands and `~/.claude` paths as inactive unless explicitly adapted. Keep workspace files physical (no symlinks). Do not work on this synced folder from two computers at the same time.

'@
    $agentsSource = Get-Content -LiteralPath (Join-Path $TemplateDir 'AGENTS.md') -Raw -Encoding UTF8
    $agentsSource = Convert-ToCodexAgentInstructions $agentsSource
    $agentsContent = Expand-IwePlaceholders ($adapterHeader + $agentsSource)
    Write-Utf8File -Path (Join-Path $Workspace 'AGENTS.md') -Content $agentsContent

    $blocksSource = Get-Content -LiteralPath (Join-Path $TemplateDir 'AGENTS-agent-blocks.md') -Raw -Encoding UTF8
    Write-Utf8File -Path (Join-Path $Workspace 'AGENTS-agent-blocks.md') -Content (Expand-IwePlaceholders $blocksSource)
}

function Test-Installation {
    $required = @(
        'AGENTS.md',
        'AGENTS-agent-blocks.md',
        'params.yaml',
        'memory\MEMORY.md',
        'memory\navigation.md',
        'memory\protocol-open.md',
        'memory\protocol-work.md',
        'memory\protocol-close.md',
        'DS-strategy\docs\Strategy.md',
        'DS-strategy\docs\Dissatisfactions.md',
        '.agents\skills\iwe-session\SKILL.md',
        '.agents\skills\iwe-strategy-session\SKILL.md',
        '.agents\skills\iwe-day-open\SKILL.md',
        '.agents\skills\iwe-day-close\SKILL.md'
    )

    $errors = 0
    foreach ($relative in $required) {
        $path = Join-Path $Workspace $relative
        if (Test-Path -LiteralPath $path) {
            Write-Host "  OK  $relative" -ForegroundColor Green
        } else {
            Write-Host "  ERR $relative" -ForegroundColor Red
            $errors++
        }
    }

    $agentsPath = Join-Path $Workspace 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsPath) {
        $agents = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
        if ($agents -match '\{\{(WORKSPACE_DIR|HOME_DIR|GOVERNANCE_REPO|IWE_TEMPLATE)\}\}') {
            Write-Host '  ERR AGENTS.md contains unresolved critical placeholders' -ForegroundColor Red
            $errors++
        } else {
            Write-Host '  OK  AGENTS.md placeholders resolved' -ForegroundColor Green
        }
    }

    $strategyDir = Join-Path $Workspace 'DS-strategy'
    $unresolved = @(Get-ChildItem -LiteralPath $strategyDir -Recurse -File |
        Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.sh', '.txt') } |
        Select-String -Pattern '\{\{(WORKSPACE_DIR|HOME_DIR|GITHUB_USER|GOVERNANCE_REPO|IWE_TEMPLATE)\}\}')
    if ($unresolved.Count -gt 0) {
        Write-Host "  ERR DS-strategy contains $($unresolved.Count) unresolved critical placeholder(s)" -ForegroundColor Red
        $errors++
    } else {
        Write-Host '  OK  DS-strategy placeholders resolved' -ForegroundColor Green
    }

    if ($errors -gt 0) {
        throw "Codex IWE validation failed: $errors error(s)."
    }
    Write-Host 'Codex IWE validation passed.' -ForegroundColor Green
}

if ($Validate) {
    Test-Installation
    exit 0
}

$requiredTemplateItems = @('AGENTS.md', 'AGENTS-agent-blocks.md', 'memory', 'seed\strategy')
foreach ($relative in $requiredTemplateItems) {
    if (-not (Test-Path -LiteralPath (Join-Path $TemplateDir $relative))) {
        throw "Template item not found: $relative"
    }
}

if ($RefreshInstructions) {
    Refresh-AgentInstructions
    Write-Host 'Codex instructions refreshed.' -ForegroundColor Green
    exit 0
}

Write-Host "Installing IWE for Codex"
Write-Host "  Template:  $TemplateDir"
Write-Host "  Workspace: $Workspace"

Ensure-Directory $Workspace
Ensure-Directory (Join-Path $Workspace 'extensions')
Ensure-Directory (Join-Path $Workspace '.agents\skills')

Refresh-AgentInstructions

Copy-MissingTree -Source (Join-Path $TemplateDir 'memory') -Destination (Join-Path $Workspace 'memory')
$memoryIndex = Join-Path $Workspace 'memory\MEMORY.md'
if (Test-Path -LiteralPath $memoryIndex) {
    $memoryText = Get-Content -LiteralPath $memoryIndex -Raw -Encoding UTF8
    $memoryText = Expand-IwePlaceholders $memoryText
    $memoryText = $memoryText.Replace('CLAUDE.md', 'AGENTS.md')
    Write-Utf8File -Path $memoryIndex -Content $memoryText
}

$paramsTarget = Join-Path $Workspace 'params.yaml'
if (-not (Test-Path -LiteralPath $paramsTarget)) {
    Copy-Item -LiteralPath (Join-Path $TemplateDir 'params.yaml.example') -Destination $paramsTarget
}

$strategyDir = Join-Path $Workspace 'DS-strategy'
if (-not (Test-Path -LiteralPath $strategyDir)) {
    Copy-Item -LiteralPath (Join-Path $TemplateDir 'seed\strategy') -Destination $strategyDir -Recurse
}

Get-ChildItem -LiteralPath $strategyDir -Recurse -File |
    Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.sh', '.txt') } |
    ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $expanded = Expand-IwePlaceholders $text
        if ($expanded -ne $text) {
            Write-Utf8File -Path $_.FullName -Content $expanded
        }
    }

$strategyAgents = @'
# DS-strategy guidance for Codex

Before changing this repository, read `../AGENTS.md` and `../memory/MEMORY.md`.
This is the private governance repository for plans, strategy, captures, decisions, and session results.
Use Russian unless the user writes in English. Never invent goals or commitments for the user.
'@
Write-Utf8File -Path (Join-Path $strategyDir 'AGENTS.md') -Content $strategyAgents

$sessionSkill = @'
---
name: iwe-session
description: Run the IWE Open-Work-Close protocol for any substantial task in this workspace. Use when starting, continuing, or closing focused work with Codex.
---

1. Read `memory/MEMORY.md`, `memory/navigation.md`, and the relevant current plan in `DS-strategy/current/`.
2. For opening, use `memory/protocol-open.md` conceptually; ignore Claude-only hooks and commands.
3. State the task, expected result, constraints, and verification before substantial changes.
4. During work, capture durable decisions or useful knowledge in the appropriate workspace file, not only in chat.
5. For closing, use `memory/protocol-close.md` conceptually: record the result, unresolved items, and the next action.
6. Do not schedule or contact external systems unless the user explicitly requests it.
'@
Write-CodexSkill -Name 'iwe-session' -Content $sessionSkill

$strategySkill = @'
---
name: iwe-strategy-session
description: Conduct an initial or weekly IWE strategy session in Russian. Use when the user asks for a strategic session, goals, dissatisfaction review, or a WeekPlan.
---

1. Read `../AGENTS.md` if working inside `DS-strategy`, then read `memory/MEMORY.md`.
2. Inspect `DS-strategy/docs/Strategy.md`, `DS-strategy/docs/Dissatisfactions.md`, and `DS-strategy/current/`.
3. Ask only the questions needed to distinguish the user's actual goals, current dissatisfaction, constraints, and weekly focus.
4. Never invent goals, metrics, deadlines, or commitments. Mark unresolved items explicitly.
5. Update the strategy documents and create or update the current WeekPlan only after the user confirms the substance.
6. Close with decisions, next actions, and what Codex should read in the next session.
'@
Write-CodexSkill -Name 'iwe-strategy-session' -Content $strategySkill

$dayOpenSkill = @'
---
name: iwe-day-open
description: Prepare the IWE plan for the current day. Use when the user asks to open the day, make today's plan, or choose today's priorities.
---

1. Read `memory/MEMORY.md`, the current WeekPlan, and the latest DayPlan or day-close result.
2. Identify carry-over work, blocked items, deadlines, and the smallest useful result for today.
3. Ask the user to resolve only choices that materially change the plan.
4. Create or update `DS-strategy/current/DayPlan YYYY-MM-DD.md` using `memory/templates-dayplan.md` as guidance.
5. Do not use Claude hooks, launchd, cron, or external calendars unless separately configured.
'@
Write-CodexSkill -Name 'iwe-day-open' -Content $dayOpenSkill

$dayCloseSkill = @'
---
name: iwe-day-close
description: Close the current IWE workday and preserve context. Use when the user asks to close the day, summarize results, or prepare tomorrow's handoff.
---

Before updating the DayPlan, read `params.yaml → multiplier_enabled`. When it is `true`, obtain today's physical time from WakaTime with the first available CLI: `$env:USERPROFILE\.wakatime\wakatime-cli-windows-amd64.exe`, `~/.wakatime/wakatime-cli`, or `wakatime-cli`. Run `--today`, then calculate the IWE multiplier as actual completed WP budget divided by WakaTime hours and include both values in the day result. If WakaTime is unavailable or returns zero, report that explicitly and do not invent a multiplier. Never print or copy the WakaTime API key. When the parameter is `false`, omit WakaTime and the multiplier completely.

1. Read today's DayPlan, the current WeekPlan, and the files changed during the day.
2. Separate completed results, unfinished work, decisions, captures, blockers, and tomorrow's first action.
3. Update or archive the DayPlan according to the existing `DS-strategy` structure.
4. Update `memory/MEMORY.md` only with durable context needed by future sessions.
5. FatSecret and Loop are completed by the user before sleep, after IWE Day Close. Do not wait for them, ask for confirmation, or mark them incomplete/partial during Day Close; record them as a post-close routine.
6. After Day Close, commit and push the related `DS-strategy` changes automatically. Stage only explicitly reviewed files; never use `git add .`, `git add -A`, or `git add -u`. Include the Codex attribution trailer when Codex changed files.
7. If commit or push fails, report the cause and leave the repository in a recoverable state. Report any unrelated uncommitted changes that were intentionally excluded.
'@
Write-CodexSkill -Name 'iwe-day-close' -Content $dayCloseSkill

Test-Installation
Write-Host "Next: open $Workspace as a Codex workspace and start a new task." -ForegroundColor Cyan
