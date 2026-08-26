[CmdletBinding()]
param()

# Codex SessionStart hook: safely refresh clean Git repositories under IWE.
# It never rebases, creates stashes, or merges diverged history. A repository is
# updated only when its current branch tracks a remote branch, the worktree is
# clean, no Git operation is in progress, and the update is a fast-forward.

$ErrorActionPreference = 'Stop'
$inputTimeoutMilliseconds = 4000

function Write-SessionContext {
    param(
        [Collections.Generic.List[string]]$Updated,
        [Collections.Generic.List[string]]$Warnings
    )

    $parts = [Collections.Generic.List[string]]::new()
    if ($Updated.Count -gt 0) {
        $parts.Add('Автоматически обновлены репозитории: ' + ($Updated -join ', ') + '.')
    }
    if ($Warnings.Count -gt 0) {
        $parts.Add('Не обновлены: ' + ($Warnings -join '; ') + '. Данные в них могут быть устаревшими.')
    }
    if ($parts.Count -eq 0) { return }

    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'SessionStart'
            additionalContext = $parts -join ' '
        }
    } | ConvertTo-Json -Depth 4 -Compress
}

function Write-SessionWarning {
    param([string]$Message)
    [ordered]@{
        systemMessage = "Автообновление репозиториев не выполнено: $Message"
    } | ConvertTo-Json -Depth 3 -Compress
}

function Read-HookEvent {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class IweSessionReadResult { public bool TimedOut; public string Line; public string Error; }
public static class IweSessionInputReader {
    public static IweSessionReadResult ReadLine(int timeoutMilliseconds) {
        string line = null; Exception failure = null;
        var reader = new Thread(() => { try { line = Console.In.ReadLine(); } catch (Exception ex) { failure = ex; } });
        reader.IsBackground = true; reader.Start();
        if (!reader.Join(timeoutMilliseconds)) return new IweSessionReadResult { TimedOut = true };
        return new IweSessionReadResult { Line = line, Error = failure == null ? null : failure.Message };
    }
}
'@
    } catch {
        Write-SessionWarning 'не удалось запустить ограниченное чтение stdin.'
        return $null
    }

    $result = [IweSessionInputReader]::ReadLine($inputTimeoutMilliseconds)
    if ($result.TimedOut) {
        Write-SessionWarning 'входной JSON не поступил за 4 секунды.'
        return $null
    }
    if ($result.Error -or [string]::IsNullOrWhiteSpace($result.Line)) {
        Write-SessionWarning 'получен пустой или недоступный stdin.'
        return $null
    }
    try {
        return ($result.Line | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-SessionWarning 'не удалось разобрать входной JSON.'
        return $null
    }
}

function Invoke-GitCommand {
    param(
        [string]$Repository,
        [string[]]$GitArguments
    )

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $baseArguments = @('-c', "safe.directory=$Repository", '-C', $Repository)
        $output = @(& git @baseArguments @GitArguments 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($output -join [Environment]::NewLine).Trim()
        }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Test-GitOperationInProgress {
    param([string]$Repository)

    foreach ($marker in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply')) {
        $pathResult = Invoke-GitCommand $Repository @('rev-parse', '--git-path', $marker)
        if ($pathResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($pathResult.Output)) { continue }
        $markerPath = $pathResult.Output
        if (-not [IO.Path]::IsPathRooted($markerPath)) {
            $markerPath = Join-Path $Repository $markerPath
        }
        if (Test-Path -LiteralPath $markerPath) { return $true }
    }
    return $false
}

$event = Read-HookEvent
if ($null -eq $event) { exit 0 }
if ([string]$event.hook_event_name -ne 'SessionStart' -or [string]::IsNullOrWhiteSpace([string]$event.cwd)) {
    Write-SessionWarning 'событие SessionStart не содержит обязательные поля.'
    exit 0
}

$sentinel = if ($env:IWE_DRY_RUN_SENTINEL) {
    $env:IWE_DRY_RUN_SENTINEL
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'iwe-dry-run.flag'
}
if (Test-Path -LiteralPath $sentinel) {
    Write-SessionWarning 'активен режим репетиции.'
    exit 0
}

$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
    Write-SessionWarning 'не найден корень рабочего пространства.'
    exit 0
}

$repositories = [Collections.Generic.List[IO.DirectoryInfo]]::new()
if (Test-Path -LiteralPath (Join-Path $workspace '.git')) {
    $repositories.Add((Get-Item -LiteralPath $workspace))
}
foreach ($directory in Get-ChildItem -LiteralPath $workspace -Directory -ErrorAction SilentlyContinue) {
    if (Test-Path -LiteralPath (Join-Path $directory.FullName '.git')) {
        $repositories.Add($directory)
    }
}

$updated = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

foreach ($repository in $repositories) {
    $path = $repository.FullName
    $name = $repository.Name
    try {
        if (Test-GitOperationInProgress $path) {
            $warnings.Add("${name}: незавершённая операция Git")
            continue
        }

        $status = Invoke-GitCommand $path @('status', '--porcelain=v1', '--untracked-files=normal')
        if ($status.ExitCode -ne 0) {
            $warnings.Add("${name}: Git недоступен")
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($status.Output)) {
            $warnings.Add("${name}: есть локальные изменения")
            continue
        }

        $branch = Invoke-GitCommand $path @('branch', '--show-current')
        if ($branch.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch.Output)) {
            $warnings.Add("${name}: нет активной ветки")
            continue
        }

        $upstream = Invoke-GitCommand $path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($upstream.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($upstream.Output)) {
            $warnings.Add("${name}: для ветки не задан upstream")
            continue
        }

        $remote = Invoke-GitCommand $path @('config', '--get', "branch.$($branch.Output).remote")
        if ($remote.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remote.Output) -or $remote.Output -eq '.') {
            $warnings.Add("${name}: не найден удалённый репозиторий")
            continue
        }

        $fetch = Invoke-GitCommand $path @(
            '-c', 'http.lowSpeedLimit=1',
            '-c', 'http.lowSpeedTime=15',
            'fetch', '--quiet', '--prune', $remote.Output
        )
        if ($fetch.ExitCode -ne 0) {
            $warnings.Add("${name}: не удалось получить обновления")
            continue
        }

        $statusAfterFetch = Invoke-GitCommand $path @('status', '--porcelain=v1', '--untracked-files=normal')
        if ($statusAfterFetch.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($statusAfterFetch.Output)) {
            $warnings.Add("${name}: состояние изменилось во время проверки")
            continue
        }

        $counts = Invoke-GitCommand $path @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')
        if ($counts.ExitCode -ne 0 -or $counts.Output -notmatch '^\s*(\d+)\s+(\d+)\s*$') {
            $warnings.Add("${name}: не удалось сравнить ветки")
            continue
        }
        $ahead = [int]$Matches[1]
        $behind = [int]$Matches[2]

        if ($ahead -gt 0 -and $behind -gt 0) {
            $warnings.Add("${name}: локальная и удалённая ветки разошлись")
            continue
        }
        if ($behind -eq 0) { continue }

        $merge = Invoke-GitCommand $path @('merge', '--ff-only', '--quiet', '@{upstream}')
        if ($merge.ExitCode -ne 0) {
            $warnings.Add("${name}: быстрое обновление не удалось")
            continue
        }
        $updated.Add($name)
    } catch {
        $warnings.Add("${name}: внутренняя ошибка безопасного обновления")
    }
}

Write-SessionContext $updated $warnings
exit 0
