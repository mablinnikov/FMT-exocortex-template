[CmdletBinding()]
param()

# Codex PreToolUse gate for platform-owned files edited through apply_patch.
$ErrorActionPreference = 'Stop'
$inputTimeoutMilliseconds = 4000

function Deny-ToolCall {
    param([string]$Reason)
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = "Extensions Gate: $Reason"
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
        Deny-ToolCall 'не удалось запустить ограниченное чтение stdin; правка заблокирована.'
    }
    $result = [IweHookInputReader]::ReadLine($inputTimeoutMilliseconds)
    if ($result.TimedOut) { Deny-ToolCall 'входной JSON не поступил за 4 секунды; правка заблокирована.' }
    if ($result.Error -or [string]::IsNullOrWhiteSpace($result.Line)) {
        Deny-ToolCall 'получен пустой или недоступный stdin; правка заблокирована.'
    }
    try { $parsed = $result.Line | ConvertFrom-Json -ErrorAction Stop }
    catch { Deny-ToolCall 'не удалось разобрать входной JSON; правка заблокирована.' }
    if ($null -eq $parsed) { Deny-ToolCall 'получен пустой JSON; правка заблокирована.' }
    return $parsed
}

$event = Read-HookEvent

if ($event.tool_name -ne 'apply_patch') {
    Deny-ToolCall 'получено событие не для apply_patch; правка заблокирована.'
}
$patch = [string]$event.tool_input.command
if ([string]::IsNullOrWhiteSpace($patch)) {
    Deny-ToolCall 'apply_patch не содержит command; путь правки неизвестен.'
}

$pathMatches = @([regex]::Matches($patch, '(?m)^\*\*\* (?:Add|Update|Delete) File: (.+?)\r?$'))
$pathMatches += @([regex]::Matches($patch, '(?m)^\*\*\* Move to: (.+?)\r?$'))
if ($pathMatches.Count -eq 0) {
    Deny-ToolCall 'не удалось извлечь пути из apply_patch; правка не классифицируется.'
}

$workspace = if ($event.cwd) { [string]$event.cwd } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$authorMode = $false
$paramsPath = Join-Path $workspace 'params.yaml'
if (Test-Path -LiteralPath $paramsPath) {
    $authorMode = [bool](Select-String -LiteralPath $paramsPath -Pattern '^author_mode:\s*true\s*$' -Quiet)
}

foreach ($match in $pathMatches) {
    $declaredPath = $match.Groups[1].Value.Trim()
    if ($declaredPath -match '(^|[/\\])\.\.([/\\]|$)') {
        Deny-ToolCall "путь '$declaredPath' содержит '..'."
    }

    try {
        $absolutePath = if ([IO.Path]::IsPathRooted($declaredPath)) {
            [IO.Path]::GetFullPath($declaredPath)
        } else {
            [IO.Path]::GetFullPath((Join-Path $workspace $declaredPath))
        }
    } catch {
        Deny-ToolCall "путь '$declaredPath' не удалось нормализовать."
    }

    $normalized = $absolutePath -replace '\\', '/'
    if ($normalized -match '(?i)/update-manifest\.json$') {
        Deny-ToolCall 'update-manifest.json изменяется только штатным генератором.'
    }

    $isPlatformFile = $normalized -match '(?i)/\.agents/skills/' -or $normalized -match '(?i)/memory/protocol-[^/]+\.md$'
    if (-not $isPlatformFile) { continue }
    if ($normalized -match '(?i)/FMT-exocortex-template/') { continue }
    if ($authorMode) { continue }

    Deny-ToolCall 'платформенный файл нельзя менять в развёрнутой копии. Изменяй канонический источник в FMT-exocortex-template и заново запускай setup-codex.ps1.'
}

exit 0
