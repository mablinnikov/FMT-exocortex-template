[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [string]$GitHubUser = "",
    [switch]$Validate,
    [switch]$RefreshInstructions,
    [switch]$PrepareStrategist
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

function Convert-ToLfText {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Resolve-GitHubUser {
    if ($GitHubUser) { return $GitHubUser }
    $origin = git -C $TemplateDir remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $origin -match 'github\.com[/:]([^/]+)/') {
        return $Matches[1]
    }
    return "your-github-user"
}

function Resolve-CodexCli {
    # setup-codex installs the Codex adapter, so its generated runtime must prefer
    # Codex even when a legacy Claude CLI is also present. Returned as an msys path.
    $candidates = @(
        (Join-Path $env:APPDATA "npm\codex"),
        (Join-Path $env:USERPROFILE ".local\bin\codex")
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { return "codex" }
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
        '{{CLAUDE_PATH}}'         = 'claude'
        '{{CODEX_PATH}}'          = (Resolve-CodexCli)
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
        '> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-007 Ф10). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**',
        '> **Codex-развёртывание:** файл создаёт `FMT-exocortex-template/setup-codex.ps1`. НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.'
    )
    $Text = $Text.Replace(
        '> Общее ядро → `memory/reference/agent-core.md`. Агент-специфика Codex/Kimi → `AGENTS-agent-blocks.md`.',
        '> Канонический источник → `FMT-exocortex-template/memory/reference/agent-core.md`. Агент-специфика → `FMT-exocortex-template/AGENTS-agent-blocks.md`.'
    )
    return $Text
}

function Convert-ToMsysPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    return "/$drive" + ($full.Substring(2) -replace '\\', '/')
}

function Prepare-StrategistRuntime {
    $envFile = Join-Path $Workspace '.exocortex.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        throw "Strategist runtime config not found: $envFile"
    }

    $codexPath = Resolve-CodexCli
    if ($codexPath -eq 'codex') {
        throw 'Codex CLI not found. Install Codex before preparing Strategist runtime.'
    }

    $envText = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8
    $line = 'CODEX_PATH="' + $codexPath + '"'
    if ($envText -match '(?m)^CODEX_PATH=.*$') {
        $updated = [regex]::Replace($envText, '(?m)^CODEX_PATH=.*$', $line, 1)
    } else {
        $updated = $envText.TrimEnd() + [Environment]::NewLine + $line + [Environment]::NewLine
    }

    $bashPath = @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bashPath) { throw 'Git Bash not found; cannot build Strategist runtime.' }

    if ($PSCmdlet.ShouldProcess($envFile, 'Point legacy runtime slot to Codex and rebuild .iwe-runtime')) {
        if ($updated -cne $envText) {
            Write-Utf8File -Path $envFile -Content $updated
        }
        $buildScript = Convert-ToMsysPath (Join-Path $TemplateDir 'setup\build-runtime.sh')
        $workspaceMsys = Convert-ToMsysPath $Workspace
        $envMsys = Convert-ToMsysPath $envFile
        & $bashPath $buildScript '--workspace' $workspaceMsys '--env-file' $envMsys
        if ($LASTEXITCODE -ne 0) {
            throw "Strategist runtime build failed with exit code $LASTEXITCODE"
        }
        Write-Host 'Strategist runtime prepared for Codex. Scheduled Tasks were not changed.' -ForegroundColor Green
    }
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

function Install-AgentSkills {
    $sourceDir = Join-Path $TemplateDir '.agents\skills'
    $targetDir = Join-Path $Workspace '.agents\skills'
    Ensure-Directory $targetDir
    Get-ChildItem -LiteralPath $sourceDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceDir.Length).TrimStart('\', '/')
        $target = Join-Path $targetDir $relative
        $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        Write-Utf8File -Path $target -Content (Expand-IwePlaceholders $content)
    }
}

function Install-CodexConfig {
    $source = Join-Path $TemplateDir '.codex\config.toml'
    $target = Join-Path $Workspace '.codex\config.toml'
    if (-not (Test-Path -LiteralPath $target)) {
        $content = Get-Content -LiteralPath $source -Raw -Encoding UTF8
        Write-Utf8File -Path $target -Content (Expand-IwePlaceholders $content)
    }
}

function New-CodexHookHandler {
    param(
        [string]$ScriptPath,
        [string]$StatusMessage,
        [int]$Timeout = 15
    )
    $command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    return [ordered]@{
        type = 'command'
        command = $command
        commandWindows = $command
        timeout = $Timeout
        statusMessage = $StatusMessage
    }
}

function Install-CodexHooks {
    $sourceDir = Join-Path $TemplateDir '.codex\hooks'
    $targetDir = Join-Path $Workspace '.codex\hooks'
    $hookNames = @(
        'destructive-guard.ps1',
        'destructive-mcp-guard.ps1',
        'extensions-gate.ps1',
        'dry-run-gate.ps1',
        'memory-exocortex-sync.ps1',
        'session-repo-refresh.ps1'
    )

    Ensure-Directory $targetDir
    foreach ($name in $hookNames) {
        $source = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Codex hook source not found: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $targetDir $name) -Force
    }

    # This validator moved to DS-strategy's Git pre-commit hook. Remove only
    # the exact generated Codex-era copy so stale files do not imply activation.
    $legacyProtocolHook = Join-Path $targetDir 'protocol-artifact-validate.ps1'
    if (Test-Path -LiteralPath $legacyProtocolHook) {
        Remove-Item -LiteralPath $legacyProtocolHook -Force
    }

    $destructiveGuard = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'destructive-guard.ps1') -StatusMessage 'Проверка безопасности команды'
    $dryRunGate = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'dry-run-gate.ps1') -StatusMessage 'Проверка режима репетиции'
    $extensionsGate = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'extensions-gate.ps1') -StatusMessage 'Проверка слоя файла'
    $destructiveMcpGuard = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'destructive-mcp-guard.ps1') -StatusMessage 'Проверка безопасности MCP-вызова'
    $memorySync = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'memory-exocortex-sync.ps1') -StatusMessage 'Синхронизация памяти с экзокортексом'
    $sessionRepoRefresh = New-CodexHookHandler -ScriptPath (Join-Path $targetDir 'session-repo-refresh.ps1') -StatusMessage 'Безопасное обновление репозиториев' -Timeout 120

    $configuration = [ordered]@{
        description = 'Native Codex lifecycle hooks installed by setup-codex.ps1.'
        hooks = [ordered]@{
            SessionStart = @(
                [ordered]@{
                    matcher = 'startup|resume'
                    hooks = @($sessionRepoRefresh)
                }
            )
            PreToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @($destructiveGuard, $dryRunGate)
                },
                [ordered]@{
                    matcher = 'Edit|Write'
                    hooks = @($extensionsGate, $dryRunGate)
                },
                [ordered]@{
                    matcher = '^mcp__.*'
                    hooks = @($destructiveMcpGuard, $dryRunGate)
                }
            )
            PostToolUse = @(
                [ordered]@{
                    matcher = 'Bash|Edit|Write'
                    hooks = @($memorySync)
                }
            )
        }
    }
    $json = $configuration | ConvertTo-Json -Depth 8
    Write-Utf8File -Path (Join-Path $Workspace '.codex\hooks.json') -Content ($json + [Environment]::NewLine)
}

function Install-StrategyGitHooks {
    $strategyDir = Join-Path $Workspace 'DS-strategy'
    if (-not (Test-Path -LiteralPath $strategyDir)) { return }

    $sourceHooks = Join-Path $TemplateDir 'seed\strategy\.githooks'
    $targetHooks = Join-Path $strategyDir '.githooks'
    Ensure-Directory $targetHooks

    $validatorName = 'protocol-artifact-validate.py'
    Copy-Item -LiteralPath (Join-Path $sourceHooks $validatorName) -Destination (Join-Path $targetHooks $validatorName) -Force

    $preCommitPath = Join-Path $targetHooks 'pre-commit'
    if (-not (Test-Path -LiteralPath $preCommitPath)) {
        Copy-Item -LiteralPath (Join-Path $sourceHooks 'pre-commit') -Destination $preCommitPath
        return
    }

    $beginMarker = '# BEGIN IWE PROTOCOL ARTIFACT VALIDATION'
    $preCommit = Get-Content -LiteralPath $preCommitPath -Raw -Encoding UTF8
    if ($preCommit.Contains($beginMarker)) { return }

    $block = @'
# BEGIN IWE PROTOCOL ARTIFACT VALIDATION
IWE_PROTOCOL_PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version >/dev/null 2>&1; then
        IWE_PROTOCOL_PYTHON="$candidate"
        break
    fi
done
if [ -z "$IWE_PROTOCOL_PYTHON" ]; then
    echo "PROTOCOL ARTIFACT: Python не найден — обязательная проверка не выполнена."
    exit 1
fi
"$IWE_PROTOCOL_PYTHON" "$REPO_ROOT/.githooks/protocol-artifact-validate.py" --repo "$REPO_ROOT" --staged
# END IWE PROTOCOL ARTIFACT VALIDATION
'@
    $exitPattern = [regex]::new('(?m)^exit 0\r?$')
    if (-not $exitPattern.IsMatch($preCommit)) {
        throw "Cannot install protocol artifact validation: final 'exit 0' not found in $preCommitPath"
    }
    $updated = $exitPattern.Replace($preCommit, $block.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + 'exit 0', 1)
    Write-Utf8File -Path $preCommitPath -Content $updated
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

    # Platform-owned source of the generated adapters. It is physical on Windows
    # and refreshed explicitly; Copy-MissingTree intentionally preserves user files.
    $coreSource = Get-Content -LiteralPath (Join-Path $TemplateDir 'memory\reference\agent-core.md') -Raw -Encoding UTF8
    Write-Utf8File -Path (Join-Path $Workspace 'memory\reference\agent-core.md') -Content (Expand-IwePlaceholders $coreSource)
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
        'memory\reference\agent-core.md',
        'DS-strategy\docs\Strategy.md',
        'DS-strategy\docs\Dissatisfactions.md',
        '.agents\skills\iwe-session\SKILL.md',
        '.agents\skills\iwe-strategy-session\SKILL.md',
        '.agents\skills\iwe-day-open\SKILL.md',
        '.agents\skills\iwe-day-close\SKILL.md',
        '.agents\skills\iwe-week-close\SKILL.md',
        '.codex\config.toml',
        '.codex\hooks.json',
        '.codex\hooks\destructive-guard.ps1',
        '.codex\hooks\destructive-mcp-guard.ps1',
        '.codex\hooks\extensions-gate.ps1',
        '.codex\hooks\dry-run-gate.ps1',
        '.codex\hooks\memory-exocortex-sync.ps1',
        '.codex\hooks\session-repo-refresh.ps1',
        'DS-strategy\.githooks\protocol-artifact-validate.py'
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

    $hooksPath = Join-Path $Workspace '.codex\hooks.json'
    if (Test-Path -LiteralPath $hooksPath) {
        try {
            $hooksConfig = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $hooksConfig.hooks.SessionStart) { throw 'SessionStart is missing' }
            if (-not $hooksConfig.hooks.PreToolUse) { throw 'PreToolUse is missing' }
            Write-Host '  OK  Codex hooks generated and configured' -ForegroundColor Green
            Write-Host '  NOTE hook trust is user-managed; review changed hooks with /hooks' -ForegroundColor Yellow
        } catch {
            Write-Host "  ERR .codex/hooks.json is invalid: $($_.Exception.Message)" -ForegroundColor Red
            $errors++
        }
    }

    $corePath = Join-Path $Workspace 'memory\reference\agent-core.md'
    if (Test-Path -LiteralPath $corePath) {
        $expectedCore = Expand-IwePlaceholders (Get-Content -LiteralPath (Join-Path $TemplateDir 'memory\reference\agent-core.md') -Raw -Encoding UTF8)
        $installedCore = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
        if ((Convert-ToLfText $installedCore) -ceq (Convert-ToLfText $expectedCore)) {
            Write-Host '  OK  common agent core matches template' -ForegroundColor Green
        } else {
            Write-Host '  ERR common agent core differs from template' -ForegroundColor Red
            $errors++
        }
    }

    $codexConfigPath = Join-Path $Workspace '.codex\config.toml'
    if (Test-Path -LiteralPath $codexConfigPath) {
        $codexConfig = Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8
        if ($codexConfig -match '(?m)^\[mcp_servers\.iwe-knowledge\]$') {
            Write-Host '  OK  iwe-knowledge configured for Codex' -ForegroundColor Green
        } else {
            Write-Host '  ERR .codex\config.toml does not configure iwe-knowledge' -ForegroundColor Red
            $errors++
        }
    }

    # Validate executable/generated DS files, not user history and exocortex
    # backups where placeholder examples are legitimate content.
    $strategyDir = Join-Path $Workspace 'DS-strategy'
    $strategyValidationFiles = @()
    $strategyAgents = Join-Path $strategyDir 'AGENTS.md'
    if (Test-Path -LiteralPath $strategyAgents) {
        $strategyValidationFiles += Get-Item -LiteralPath $strategyAgents
    }
    foreach ($relativeDir in @('scripts', '.githooks')) {
        $scanDir = Join-Path $strategyDir $relativeDir
        if (Test-Path -LiteralPath $scanDir) {
            $strategyValidationFiles += Get-ChildItem -LiteralPath $scanDir -Recurse -File |
                Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.sh', '.py', '.txt') }
        }
    }
    $unresolved = @($strategyValidationFiles |
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

$requiredTemplateItems = @('AGENTS.md', 'AGENTS-agent-blocks.md', '.agents\skills', '.codex\config.toml', 'memory', 'seed\strategy')
foreach ($relative in $requiredTemplateItems) {
    if (-not (Test-Path -LiteralPath (Join-Path $TemplateDir $relative))) {
        throw "Template item not found: $relative"
    }
}

if ($RefreshInstructions) {
    Refresh-AgentInstructions
    Install-AgentSkills
    Install-CodexConfig
    Install-CodexHooks
    Install-StrategyGitHooks
    Write-Host 'Codex instructions and safety hooks refreshed.' -ForegroundColor Green
    exit 0
}

if ($PrepareStrategist) {
    Prepare-StrategistRuntime
    exit 0
}

Write-Host "Installing IWE for Codex"
Write-Host "  Template:  $TemplateDir"
Write-Host "  Workspace: $Workspace"

Ensure-Directory $Workspace
Ensure-Directory (Join-Path $Workspace 'extensions')
Ensure-Directory (Join-Path $Workspace '.agents\skills')
Ensure-Directory (Join-Path $Workspace '.codex\hooks')

Refresh-AgentInstructions
Install-AgentSkills
Install-CodexConfig
Install-CodexHooks

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
$strategyCreated = $false
if (-not (Test-Path -LiteralPath $strategyDir)) {
    Copy-Item -LiteralPath (Join-Path $TemplateDir 'seed\strategy') -Destination $strategyDir -Recurse
    $strategyCreated = $true
}

if ($strategyCreated) {
    Get-ChildItem -LiteralPath $strategyDir -Recurse -File |
        Where-Object { $_.Extension -in @('.md', '.yaml', '.yml', '.json', '.sh', '.txt') } |
        ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            $expanded = Expand-IwePlaceholders $text
            if ($expanded -ne $text) {
                Write-Utf8File -Path $_.FullName -Content $expanded
            }
        }
}

$strategyAgents = @'
# DS-strategy guidance for Codex

Before changing this repository, read `../AGENTS.md` and `../memory/MEMORY.md`.
This is the private governance repository for plans, strategy, captures, decisions, and session results.
Use Russian unless the user writes in English. Never invent goals or commitments for the user.
'@
Write-Utf8File -Path (Join-Path $strategyDir 'AGENTS.md') -Content $strategyAgents
Install-StrategyGitHooks

Test-Installation
Write-Host "Next: open $Workspace as a Codex workspace and start a new task." -ForegroundColor Cyan
