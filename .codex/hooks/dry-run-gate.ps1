[CmdletBinding()]
param()

# Codex PreToolUse gate that blocks mutations while an IWE dry-run is active.
$ErrorActionPreference = 'Stop'
$ttlSeconds = 2400

function Deny-ToolCall {
    param([string]$Reason)
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = "Dry-run gate: $Reason"
        }
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}

$sentinel = if ($env:IWE_DRY_RUN_SENTINEL) {
    $env:IWE_DRY_RUN_SENTINEL
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'iwe-dry-run.flag'
}
$sentinelDirectory = Split-Path -Parent $sentinel

if (-not (Test-Path -LiteralPath $sentinel)) {
    $owner = Get-ChildItem -LiteralPath $sentinelDirectory -Filter 'iwe-dry-run-owner-*.token' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner) {
        Deny-ToolCall "sentinel отсутствует, но остался файл владельца $($owner.Name); защита потеряна в ходе репетиции."
    }
    exit 0
}

$age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $sentinel).LastWriteTimeUtc
if ($age.TotalSeconds -gt $ttlSeconds) {
    Deny-ToolCall "sentinel старше $ttlSeconds секунд; репетиция не была корректно закрыта."
}

$raw = [Console]::In.ReadToEnd()
try {
    $event = $raw | ConvertFrom-Json
} catch {
    Deny-ToolCall 'не удалось разобрать входной JSON.'
}

$toolName = [string]$event.tool_name
if ($toolName -eq 'apply_patch') {
    Deny-ToolCall 'apply_patch изменяет файлы во время активной репетиции.'
}

if ($toolName -match '^mcp__') {
    $writeName = '(?i)(?:create|write|update|delete|remove|deploy|set|share|move|disconnect|connect|label|respond)'
    if ($toolName -match $writeName) {
        Deny-ToolCall "$toolName классифицирован как изменяющий MCP-вызов."
    }
    exit 0
}

if ($toolName -ne 'Bash') { exit 0 }
$command = [string]$event.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

$writePatterns = @(
    '(?im)(?:^|[;&|]\s*)git(?:\s+-C\s+\S+)?\s+(?:add|commit|push|pull|reset|merge|rebase|mv|rm)\b',
    '(?im)(?:^|[;&|]\s*)(?:rm|mv|Remove-Item|Move-Item|Set-Content|Add-Content|Out-File|New-Item|Copy-Item)\b',
    '(?im)(?:^|\s)(?:>|>>)(?:\s|$)',
    '(?is)\bcurl\b.*(?:-X\s*(?:POST|PUT|DELETE|PATCH)|--data\b|-d\b)',
    '(?is)\bpsql\b.*\b(?:INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)\b',
    '(?im)(?:^|[;&|]\s*)(?:eval|source|xargs|Invoke-Expression)\b'
)
foreach ($pattern in $writePatterns) {
    if ($command -match $pattern) {
        Deny-ToolCall "команда изменяет состояние: $command"
    }
}

exit 0
