[CmdletBinding()]
param()

# Codex PreToolUse:Bash guard for irreversible local operations.
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

function Remove-QuotedContent {
    param([string]$Command)
    $withoutSingle = [regex]::Replace($Command, "'[^']*'", ' Q ')
    return [regex]::Replace($withoutSingle, '"(?:\\.|[^"\\])*"', ' Q ')
}

function Get-GitInvocations {
    param([string]$Command)

    $scan = Remove-QuotedContent $Command
    foreach ($segment in ($scan -split '[;&|()`{}\r\n]+')) {
        $tokens = @([regex]::Matches($segment, '[^\s]+') | ForEach-Object Value)
        if ($tokens.Count -eq 0) { continue }

        $index = 0
        while ($index -lt $tokens.Count -and (
            $tokens[$index] -match '^[A-Za-z_][A-Za-z0-9_]*=' -or
            $tokens[$index] -in @('command', 'env', 'nohup', 'time', 'sudo', 'exec', 'builtin', 'if', 'elif', 'while', 'until', 'then', 'else', 'do', '!')
        )) { $index++ }

        if ($index -ge $tokens.Count -or $tokens[$index] -ne 'git') { continue }
        $index++
        while ($index -lt $tokens.Count) {
            if ($tokens[$index] -in @('-C', '--git-dir', '--work-tree', '-c')) {
                $index += 2
            } elseif ($tokens[$index] -match '^--(?:git-dir|work-tree)=' -or $tokens[$index] -match '^-c.+') {
                $index++
            } else {
                break
            }
        }
        if ($index -ge $tokens.Count) { continue }

        $arguments = @()
        if (($index + 1) -lt $tokens.Count) {
            $arguments = @($tokens[($index + 1)..($tokens.Count - 1)])
        }

        [pscustomobject]@{
            Subcommand = $tokens[$index]
            Arguments = $arguments
            Segment = $segment.Trim()
        }
    }
}

$readTask = [Console]::In.ReadLineAsync()
if (-not $readTask.Wait(5000)) {
    Deny-ToolCall 'Защитный Codex-hook не получил входной JSON за 5 секунд; команда заблокирована.'
}
$raw = [string]$readTask.Result
try {
    $event = $raw | ConvertFrom-Json
} catch {
    Deny-ToolCall 'Защитный Codex-hook не смог разобрать входной JSON; команда заблокирована.'
}

if ($event.tool_name -ne 'Bash') { exit 0 }
$command = [string]$event.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }
if ($env:IWE_ALLOW_DESTRUCTIVE_INPUT -eq '1') { exit 0 }

$scan = Remove-QuotedContent $command
if ($scan -match '(?im)(?:^|[;&|]\s*)cd\s+') {
    Deny-ToolCall 'Верхнеуровневый cd запрещён: используй рабочий каталог инструмента, git -C или абсолютный путь.'
}

foreach ($git in @(Get-GitInvocations $command)) {
    $args = @($git.Arguments)
    switch ($git.Subcommand) {
        'add' {
            if ($args | Where-Object { $_ -in @('-A', '--all', '-u', '--update', '.') }) {
                Deny-ToolCall 'git add . и массовые режимы -A/--all/-u/--update запрещены. Добавляй только конкретные файлы.'
            }
        }
        'push' {
            $unsafeForce = $args | Where-Object {
                ($_ -eq '--force') -or ($_ -match '^-[A-Za-z]*f[A-Za-z]*$')
            }
            if ($unsafeForce) {
                Deny-ToolCall 'git push --force запрещён. При согласованной необходимости используй --force-with-lease.'
            }
        }
        'reset' {
            if ($args -contains '--hard') {
                Deny-ToolCall 'git reset --hard запрещён: он может удалить незакоммиченные изменения и локальную историю.'
            }
        }
        'clean' {
            if ($args | Where-Object { $_ -match '^-[A-Za-z]*[fdx][A-Za-z]*$' }) {
                Deny-ToolCall 'git clean с удаляющими флагами запрещён: он удаляет неотслеживаемые файлы.'
            }
        }
    }
}

$tempLike = $scan -match '(?i)(?:/tmp/|/scratchpad/|\.codex[/\\]worktrees[/\\]|\\Temp\\)'
$hasUnixRemove = $scan -match '(?im)(?:^|[;&|]\s*)rm\s+'
$hasUnixRecursiveFlag = $scan -match '(?im)(?:^|[;&|]\s*)rm\s+[^\r\n;&|]*(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)'
$hasUnixForceFlag = $scan -match '(?im)(?:^|[;&|]\s*)rm\s+[^\r\n;&|]*(?:-[A-Za-z]*f[A-Za-z]*|--force)'
$hasUnixRecursiveDelete = $hasUnixRemove -and $hasUnixRecursiveFlag -and $hasUnixForceFlag
$hasPowerShellRemove = $scan -match '(?im)(?:^|[;&|]\s*)Remove-Item\b'
$hasPowerShellRecurse = $scan -match '(?im)(?:^|[;&|]\s*)Remove-Item\b[^\r\n;&|]*-Recurse\b'
$hasPowerShellForce = $scan -match '(?im)(?:^|[;&|]\s*)Remove-Item\b[^\r\n;&|]*-Force\b'
$hasPowerShellRecursiveDelete = $hasPowerShellRemove -and $hasPowerShellRecurse -and $hasPowerShellForce
$hasCmdRemove = $scan -match '(?im)(?:^|[;&|]\s*)(?:rd|rmdir|del)\b'
$hasCmdQuiet = $scan -match '(?im)(?:^|[;&|]\s*)(?:rd|rmdir|del)\b[^\r\n;&|]*/q\b'
$hasCmdRecursive = $scan -match '(?im)(?:^|[;&|]\s*)(?:rd|rmdir|del)\b[^\r\n;&|]*/s\b'
$hasCmdRecursiveDelete = $hasCmdRemove -and $hasCmdQuiet -and $hasCmdRecursive
if (($hasUnixRecursiveDelete -or $hasPowerShellRecursiveDelete -or $hasCmdRecursiveDelete) -and -not $tempLike) {
    Deny-ToolCall 'Рекурсивное принудительное удаление вне временного каталога запрещено.'
}

if ($scan -match '(?is)\bpsql\b.*\b(?:DROP\s+(?:TABLE|SCHEMA|DATABASE)|TRUNCATE)\b') {
    Deny-ToolCall 'DROP/TRUNCATE через psql запрещён: операция необратима.'
}
if ($scan -match '(?is)\bpsql\b.*\bDELETE\s+FROM\b' -and $scan -notmatch '(?is)\bDELETE\s+FROM\b[^;]*\bWHERE\b') {
    Deny-ToolCall 'DELETE FROM без WHERE через psql запрещён.'
}
if ($scan -match '(?im)(?:^|[;&|]\s*)gh\s+repo\s+delete\b') {
    Deny-ToolCall 'gh repo delete запрещён: удаление репозитория необратимо.'
}

exit 0
