[CmdletBinding()]
param()

# Codex PreToolUse guard for irreversible MCP operations.
$ErrorActionPreference = 'Stop'

function Deny-ToolCall {
    param([string]$Reason)
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $Reason
        }
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}

$readTask = [Console]::In.ReadLineAsync()
if (-not $readTask.Wait(5000)) {
    Deny-ToolCall 'Защитный Codex-hook не получил входной JSON за 5 секунд; MCP-вызов заблокирован.'
}
$raw = [string]$readTask.Result
try {
    $event = $raw | ConvertFrom-Json
} catch {
    Deny-ToolCall 'Защитный Codex-hook не смог разобрать входной JSON; MCP-вызов заблокирован.'
}

$toolName = [string]$event.tool_name
if ($toolName -notmatch '^mcp__') { exit 0 }
if ($env:IWE_ALLOW_DESTRUCTIVE_INPUT -eq '1') { exit 0 }

$destructiveResource = '(?i)(?:remove|delete)[_-]?(?:service|volume|tcp[_-]?proxy|bucket|domain|repository|database)'
if ($toolName -match $destructiveResource) {
    Deny-ToolCall "Инструмент $toolName необратимо удаляет внешний ресурс. Для разового согласованного обхода пилот может запустить Codex с IWE_ALLOW_DESTRUCTIVE_INPUT=1."
}

exit 0
