[CmdletBinding()]
param()

# Codex PreToolUse:Bash guard for irreversible local operations.
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

public sealed class IweHookReadResult {
    public bool TimedOut;
    public string Line;
    public string Error;
}

public static class IweHookInputReader {
    public static IweHookReadResult ReadLine(int timeoutMilliseconds) {
        string line = null;
        Exception failure = null;
        var reader = new Thread(() => {
            try { line = Console.In.ReadLine(); }
            catch (Exception ex) { failure = ex; }
        });
        reader.IsBackground = true;
        reader.Start();
        if (!reader.Join(timeoutMilliseconds)) {
            return new IweHookReadResult { TimedOut = true };
        }
        return new IweHookReadResult {
            Line = line,
            Error = failure == null ? null : failure.Message
        };
    }
}
'@
    } catch {
        Deny-ToolCall 'Защитный Codex-hook не смог запустить ограниченное чтение stdin; команда заблокирована.'
    }

    $result = [IweHookInputReader]::ReadLine($inputTimeoutMilliseconds)
    if ($result.TimedOut) {
        Deny-ToolCall 'Защитный Codex-hook не получил входной JSON за 4 секунды; команда заблокирована.'
    }
    if ($result.Error -or [string]::IsNullOrWhiteSpace($result.Line)) {
        Deny-ToolCall 'Защитный Codex-hook получил пустой или недоступный stdin; команда заблокирована.'
    }
    try {
        $parsed = $result.Line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Deny-ToolCall 'Защитный Codex-hook не смог разобрать входной JSON; команда заблокирована.'
    }
    if ($null -eq $parsed) {
        Deny-ToolCall 'Защитный Codex-hook получил пустой JSON; команда заблокирована.'
    }
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
                )) {
                    $payload = $payload.Substring(1, $payload.Length - 2)
                }
                if (-not [string]::IsNullOrWhiteSpace($payload)) { $queue.Enqueue($payload) }
            }
        }
    }
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

$event = Read-HookEvent

if ($event.tool_name -ne 'Bash') {
    Deny-ToolCall 'Защитный Codex-hook получил событие не для Bash; команда заблокирована.'
}
$command = [string]$event.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) {
    Deny-ToolCall 'Защитный Codex-hook не получил Bash-команду; вызов заблокирован.'
}
if ($env:IWE_ALLOW_DESTRUCTIVE_INPUT -eq '1') { exit 0 }

$commandViews = @(Get-CommandViews $command)
foreach ($view in $commandViews) {
    $scan = Remove-QuotedContent $view
    if ($scan -match '(?im)(?:^|[;&|({]\s*)cd\s+') {
        Deny-ToolCall 'Верхнеуровневый cd запрещён: используй рабочий каталог инструмента, git -C или абсолютный путь.'
    }
    if ($scan -match '(?im)(?:^|[;&|({]\s*)(?:powershell(?:\.exe)?|pwsh(?:\.exe)?)\b[^\r\n;&|]*?-(?:EncodedCommand|EncodedComman|EncodedComma|EncodedComm|EncodedCom|EncodedCo|EncodedC|Encoded|Encode|Encod|Enco|Enc|Ec|En|E)\b') {
        Deny-ToolCall 'PowerShell EncodedCommand нельзя безопасно проверить; команда заблокирована.'
    }

    foreach ($git in @(Get-GitInvocations $view)) {
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
    $hasUnixRemove = $scan -match '(?im)(?:^|[;&|({]\s*)rm\s+'
    $hasUnixRecursiveFlag = $scan -match '(?im)(?:^|[;&|({]\s*)rm\s+[^\r\n;&|]*(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)'
    $hasUnixForceFlag = $scan -match '(?im)(?:^|[;&|({]\s*)rm\s+[^\r\n;&|]*(?:-[A-Za-z]*f[A-Za-z]*|--force)'
    $hasUnixRecursiveDelete = $hasUnixRemove -and $hasUnixRecursiveFlag -and $hasUnixForceFlag
    $hasPowerShellRemove = $scan -match '(?im)(?:^|[;&|({]\s*)(?:Remove-Item|ri|rm|rmdir|del|erase|rd)\b'
    $hasPowerShellRecurse = $scan -match '(?im)(?:^|[;&|({]\s*)(?:Remove-Item|ri|rm|rmdir|del|erase|rd)\b[^\r\n;&|]*-Recurse\b'
    $hasPowerShellForce = $scan -match '(?im)(?:^|[;&|({]\s*)(?:Remove-Item|ri|rm|rmdir|del|erase|rd)\b[^\r\n;&|]*-Force\b'
    $hasPowerShellRecursiveDelete = $hasPowerShellRemove -and $hasPowerShellRecurse -and $hasPowerShellForce
    $hasCmdRemove = $scan -match '(?im)(?:^|[;&|({]\s*)(?:rd|rmdir|del)\b'
    $hasCmdQuiet = $scan -match '(?im)(?:^|[;&|({]\s*)(?:rd|rmdir|del)\b[^\r\n;&|]*/q\b'
    $hasCmdRecursive = $scan -match '(?im)(?:^|[;&|({]\s*)(?:rd|rmdir|del)\b[^\r\n;&|]*/s\b'
    $hasCmdRecursiveDelete = $hasCmdRemove -and $hasCmdQuiet -and $hasCmdRecursive
    if (($hasUnixRecursiveDelete -or $hasPowerShellRecursiveDelete -or $hasCmdRecursiveDelete) -and -not $tempLike) {
        Deny-ToolCall 'Рекурсивное принудительное удаление вне временного каталога запрещено.'
    }

    $hasPsqlInvocation = $scan -match '(?im)(?:^|[;&|({]\s*)psql(?:\.exe)?\b'
    if ($hasPsqlInvocation -and $view -match '(?is)\b(?:DROP\s+(?:TABLE|SCHEMA|DATABASE)|TRUNCATE)\b') {
        Deny-ToolCall 'DROP/TRUNCATE через psql запрещён: операция необратима.'
    }
    if ($hasPsqlInvocation) {
        $delete = [regex]::Match($view, '(?is)\bDELETE\s+FROM\b(?<statement>[^;]*)')
        if ($delete.Success -and $delete.Groups['statement'].Value -notmatch '(?i)\bWHERE\b') {
            Deny-ToolCall 'DELETE FROM без WHERE через psql запрещён.'
        }
    }
    if ($scan -match '(?im)(?:^|[;&|({]\s*)gh\s+repo\s+delete\b') {
        Deny-ToolCall 'gh repo delete запрещён: удаление репозитория необратимо.'
    }
}

exit 0
