[CmdletBinding()]
param()

# Codex PreToolUse gate for platform-owned files edited through apply_patch.
$ErrorActionPreference = 'Stop'

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

$readTask = [Console]::In.ReadLineAsync()
if (-not $readTask.Wait(5000)) {
    Deny-ToolCall 'входной JSON не поступил за 5 секунд; правка заблокирована.'
}
$raw = [string]$readTask.Result
try {
    $event = $raw | ConvertFrom-Json
} catch {
    Deny-ToolCall 'не удалось разобрать входной JSON; правка заблокирована.'
}

if ($event.tool_name -ne 'apply_patch') { exit 0 }
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
