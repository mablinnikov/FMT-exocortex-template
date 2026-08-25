[CmdletBinding()]
param()

# Codex PreToolUse gate that blocks mutations while an IWE dry-run is active.
$ErrorActionPreference = 'Stop'
$ttlSeconds = 2400
$inputTimeoutMilliseconds = 4000

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
        Deny-ToolCall 'не удалось запустить ограниченное чтение stdin.'
    }
    $result = [IweHookInputReader]::ReadLine($inputTimeoutMilliseconds)
    if ($result.TimedOut) { Deny-ToolCall 'входной JSON не поступил за 4 секунды.' }
    if ($result.Error -or [string]::IsNullOrWhiteSpace($result.Line)) {
        Deny-ToolCall 'получен пустой или недоступный stdin.'
    }
    try { $parsed = $result.Line | ConvertFrom-Json -ErrorAction Stop }
    catch { Deny-ToolCall 'не удалось разобрать входной JSON.' }
    if ($null -eq $parsed) { Deny-ToolCall 'получен пустой JSON.' }
    return $parsed
}

function Remove-QuotedContent {
    param([string]$Command)
    $withoutSingle = [regex]::Replace($Command, "'[^']*'", ' Q ')
    return [regex]::Replace($withoutSingle, '"(?:\\.|[^"\\])*"', ' Q ')
}

function Get-CommandViews {
    param([string]$Command)

    $queue = [Collections.Generic.Queue[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue.Enqueue($Command)
    while ($queue.Count -gt 0 -and $seen.Count -lt 16) {
        $current = $queue.Dequeue().Trim()
        if ([string]::IsNullOrWhiteSpace($current) -or -not $seen.Add($current)) { continue }
        $current
        $patterns = @(
            '(?is)(?:^|[;&|]\s*)(?:powershell(?:\.exe)?|pwsh(?:\.exe)?)\b[^\r\n;&|]*?\s-(?:Command|c)\s+(?<payload>"[^"]*"|''[^'']*''|[^;&|\r\n]+)',
            '(?is)(?:^|[;&|]\s*)cmd(?:\.exe)?\b[^\r\n;&|]*?\s+/(?:c|k)\s+(?<payload>"[^"]*"|''[^'']*''|[^;&|\r\n]+)'
        )
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($current, $pattern)) {
                $payload = $match.Groups['payload'].Value.Trim()
                if ($payload.Length -ge 2 -and (
                    ($payload[0] -eq '"' -and $payload[$payload.Length - 1] -eq '"') -or
                    ($payload[0] -eq "'" -and $payload[$payload.Length - 1] -eq "'")
                )) { $payload = $payload.Substring(1, $payload.Length - 2) }
                if (-not [string]::IsNullOrWhiteSpace($payload)) { $queue.Enqueue($payload) }
            }
        }
    }
}

$event = Read-HookEvent
$toolName = [string]$event.tool_name
if ($toolName -ne 'Bash' -and $toolName -ne 'apply_patch' -and $toolName -notmatch '^mcp__') {
    Deny-ToolCall 'получено событие с неизвестным именем инструмента.'
}
if ($toolName -eq 'Bash' -and [string]::IsNullOrWhiteSpace([string]$event.tool_input.command)) {
    Deny-ToolCall 'Bash-событие не содержит command.'
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

$commandViews = @(Get-CommandViews $command)
foreach ($view in $commandViews) {
    $scan = Remove-QuotedContent $view
    $writePatterns = @(
        '(?im)(?:^|[;&|({]\s*)git(?:\s+-C\s+\S+)?\s+(?:add|commit|push|pull|reset|merge|rebase|mv|rm)\b',
        '(?im)(?:^|[;&|({]\s*)(?:rm|mv|Remove-Item|ri|Move-Item|Set-Content|Add-Content|Out-File|New-Item|Copy-Item|del|rd|rmdir)\b',
        '(?im)(?:^|\s)(?:>|>>)(?:\s|$)',
        '(?is)\bcurl\b.*(?:-X\s*(?:POST|PUT|DELETE|PATCH)|--data\b|-d\b)',
        '(?im)(?:^|[;&|({]\s*)(?:eval|source|xargs|Invoke-Expression|iex)\b',
        '(?im)(?:^|[;&|({]\s*)(?:powershell(?:\.exe)?|pwsh(?:\.exe)?)\b[^\r\n;&|]*?-(?:EncodedCommand|EncodedComman|EncodedComma|EncodedComm|EncodedCom|EncodedCo|EncodedC|Encoded|Encode|Encod|Enco|Enc|Ec|En|E)\b'
    )
    foreach ($pattern in $writePatterns) {
        if ($scan -match $pattern) {
            Deny-ToolCall "команда изменяет состояние: $command"
        }
    }
    $hasPsqlInvocation = $scan -match '(?im)(?:^|[;&|({]\s*)psql(?:\.exe)?\b'
    if ($hasPsqlInvocation -and $view -match '(?is)\b(?:INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)\b') {
        Deny-ToolCall "команда изменяет состояние: $command"
    }
}

exit 0
