[CmdletBinding()]
param()

# Codex PreToolUse guard for irreversible MCP operations.
$ErrorActionPreference = 'Stop'
$inputTimeoutMilliseconds = 4000

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

function Read-HookEvent {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class IweHookReadResult { public bool TimedOut; public string Line; public string Error; }
public static class IweHookInputReader {
    public static IweHookReadResult ReadLine(int timeoutMilliseconds) {
        string line = null; Exception failure = null;
        var reader = new Thread(() => { try { line = Console.In.ReadLine(); } catch (Exception ex) { failure = ex; } });
        reader.IsBackground = true; reader.Start();
        if (!reader.Join(timeoutMilliseconds)) return new IweHookReadResult { TimedOut = true };
        return new IweHookReadResult { Line = line, Error = failure == null ? null : failure.Message };
    }
}
'@
    } catch {
        Deny-ToolCall 'Защитный Codex-hook не смог запустить ограниченное чтение stdin; MCP-вызов заблокирован.'
    }
    $result = [IweHookInputReader]::ReadLine($inputTimeoutMilliseconds)
    if ($result.TimedOut) { Deny-ToolCall 'Входной JSON не поступил за 4 секунды; MCP-вызов заблокирован.' }
    if ($result.Error -or [string]::IsNullOrWhiteSpace($result.Line)) {
        Deny-ToolCall 'Получен пустой или недоступный stdin; MCP-вызов заблокирован.'
    }
    try { $parsed = $result.Line | ConvertFrom-Json -ErrorAction Stop }
    catch { Deny-ToolCall 'Защитный Codex-hook не смог разобрать входной JSON; MCP-вызов заблокирован.' }
    if ($null -eq $parsed) { Deny-ToolCall 'Защитный Codex-hook получил пустой JSON; MCP-вызов заблокирован.' }
    return $parsed
}

$event = Read-HookEvent

$toolName = [string]$event.tool_name
if ($toolName -notmatch '^mcp__') {
    Deny-ToolCall 'Защитный Codex-hook получил событие не для MCP; вызов заблокирован.'
}
if ($env:IWE_ALLOW_DESTRUCTIVE_INPUT -eq '1') { exit 0 }

$destructiveResource = '(?i)(?:remove|delete)[_-]?(?:service|volume|tcp[_-]?proxy|bucket|domain|repository|database)'
if ($toolName -match $destructiveResource) {
    Deny-ToolCall "Инструмент $toolName необратимо удаляет внешний ресурс. Для разового согласованного обхода пилот может запустить Codex с IWE_ALLOW_DESTRUCTIVE_INPUT=1."
}

exit 0
