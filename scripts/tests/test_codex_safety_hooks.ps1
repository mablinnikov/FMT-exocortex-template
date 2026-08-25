[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$templateRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hooksRoot = Join-Path $templateRoot '.codex\hooks'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("iwe-codex-hooks-test-" + $PID + '-' + [guid]::NewGuid().ToString('N'))

function Invoke-Hook {
    param(
        [string]$Name,
        [hashtable]$Event,
        [hashtable]$Environment = @{}
    )

    $saved = @{}
    foreach ($entry in $Environment.GetEnumerator()) {
        $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }
    try {
        $json = $Event | ConvertTo-Json -Depth 8 -Compress
        $output = @($json | & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $hooksRoot $Name) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "$Name exited with code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
        }
        return ($output -join [Environment]::NewLine).Trim()
    } finally {
        foreach ($entry in $saved.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

function Invoke-HookProcess {
    param(
        [string]$Name,
        [hashtable]$Event = $null,
        [hashtable]$Environment = @{},
        [ValidateSet('JsonOpen', 'Eof', 'OpenEmpty')]
        [string]$InputMode = 'JsonOpen'
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = 'powershell.exe'
    $processInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $hooksRoot $Name) + '"'
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($entry in $Environment.GetEnumerator()) {
        $processInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    try {
        [void]$process.Start()
        if ($InputMode -eq 'JsonOpen') {
            $json = $Event | ConvertTo-Json -Depth 8 -Compress
            $process.StandardInput.WriteLine($json)
            $process.StandardInput.Flush()
        } elseif ($InputMode -eq 'Eof') {
            $process.StandardInput.Close()
        }

        $waitMilliseconds = if ($InputMode -eq 'OpenEmpty') { 6500 } else { 3000 }
        if (-not $process.WaitForExit($waitMilliseconds)) {
            $process.Kill()
            $process.WaitForExit()
            throw "$Name exceeded the bounded stdin wait in mode $InputMode"
        }

        $output = $process.StandardOutput.ReadToEnd().Trim()
        $errorOutput = $process.StandardError.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0) {
            throw "$Name exited with code $($process.ExitCode)`: $errorOutput"
        }
        return $output
    } finally {
        $process.Dispose()
    }
}

function New-ToolEvent {
    param([string]$ToolName, [hashtable]$ToolInput, [string]$Cwd = $testRoot)
    return @{
        session_id = 'test-session'
        turn_id = 'test-turn'
        cwd = $Cwd
        hook_event_name = 'PreToolUse'
        tool_name = $ToolName
        tool_use_id = 'test-tool'
        tool_input = $ToolInput
    }
}

function Assert-Denied {
    param([string]$Output, [string]$Case)
    if ([string]::IsNullOrWhiteSpace($Output)) { throw "$Case`: expected deny JSON, got empty output" }
    $parsed = $Output | ConvertFrom-Json
    if ($parsed.hookSpecificOutput.permissionDecision -ne 'deny') {
        throw "$Case`: expected deny, got $Output"
    }
}

function Assert-Allowed {
    param([string]$Output, [string]$Case)
    if ([string]::IsNullOrWhiteSpace($Output)) { return }
    $parsed = $Output | ConvertFrom-Json
    if ($parsed.hookSpecificOutput.permissionDecision -eq 'deny' -or $parsed.decision -eq 'block') {
        throw "$Case`: expected allow, got $Output"
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $blockedCommands = @(
        'git add .',
        'git add -A',
        'git add -u',
        'git push --force origin main',
        'git reset --hard HEAD~1',
        'git clean -fd',
        'rm -rf /workspace/project',
        'Remove-Item C:\workspace\project -Recurse -Force',
        'ri C:\workspace\project -Recurse -Force',
        'del C:\workspace\project -Recurse -Force',
        'psql -c "DROP TABLE accounts"',
        'psql -c "DELETE FROM accounts"',
        'powershell -NoProfile -Command "git reset --hard HEAD~1"',
        'powershell -Command "ri C:\workspace\project -Recurse -Force"',
        'cmd /c "git clean -fd"',
        'cmd /d /c "git reset --hard HEAD~1"',
        'cmd /c "rmdir C:\workspace\project /s /q"',
        'powershell -EncodedCommand ZABlAGwAZQB0AGUA'
    )
    foreach ($command in $blockedCommands) {
        $output = Invoke-Hook 'destructive-guard.ps1' (New-ToolEvent 'Bash' @{ command = $command })
        Assert-Denied $output "destructive command: $command"
    }
    Assert-Allowed (Invoke-Hook 'destructive-guard.ps1' (New-ToolEvent 'Bash' @{ command = 'git status --short' })) 'git status'
    Assert-Allowed (Invoke-Hook 'destructive-guard.ps1' (New-ToolEvent 'Bash' @{ command = 'git add src/app.ps1' })) 'targeted git add'
    Assert-Allowed (Invoke-Hook 'destructive-guard.ps1' (New-ToolEvent 'Bash' @{ command = 'psql -c "DELETE FROM accounts WHERE id = 1"' })) 'bounded SQL delete'
    Assert-Allowed (
        Invoke-HookProcess 'destructive-guard.ps1' (New-ToolEvent 'Bash' @{ command = 'Write-Output ok' })
    ) 'destructive guard without stdin EOF'
    Assert-Denied (Invoke-HookProcess 'destructive-guard.ps1' -InputMode Eof) 'destructive guard EOF without JSON'
    Assert-Denied (Invoke-HookProcess 'destructive-guard.ps1' -InputMode OpenEmpty) 'destructive guard bounded empty input'
    Assert-Denied (Invoke-HookProcess 'destructive-guard.ps1' @{}) 'destructive guard missing event fields'

    Assert-Denied (
        Invoke-Hook 'destructive-mcp-guard.ps1' (New-ToolEvent 'mcp__cloud__remove_bucket' @{ bucket = 'prod' })
    ) 'destructive MCP'
    Assert-Allowed (
        Invoke-Hook 'destructive-mcp-guard.ps1' (New-ToolEvent 'mcp__cloud__list_buckets' @{})
    ) 'read-only MCP'
    Assert-Allowed (
        Invoke-HookProcess 'destructive-mcp-guard.ps1' (New-ToolEvent 'mcp__cloud__list_buckets' @{})
    ) 'MCP guard without stdin EOF'
    Assert-Denied (Invoke-HookProcess 'destructive-mcp-guard.ps1' -InputMode Eof) 'MCP guard EOF without JSON'
    Assert-Denied (Invoke-HookProcess 'destructive-mcp-guard.ps1' @{}) 'MCP guard missing event fields'

    $protectedPatch = "*** Begin Patch`n*** Update File: .agents/skills/run-protocol/SKILL.md`n@@`n-old`n+new`n*** End Patch"
    $protectedMovePatch = "*** Begin Patch`n*** Update File: src/app.ps1`n*** Move to: .agents/skills/run-protocol/SKILL.md`n@@`n-old`n+new`n*** End Patch"
    $safePatch = "*** Begin Patch`n*** Update File: src/app.ps1`n@@`n-old`n+new`n*** End Patch"
    Assert-Denied (
        Invoke-Hook 'extensions-gate.ps1' (New-ToolEvent 'apply_patch' @{ command = $protectedPatch })
    ) 'protected platform edit'
    Assert-Denied (
        Invoke-Hook 'extensions-gate.ps1' (New-ToolEvent 'apply_patch' @{ command = $protectedMovePatch })
    ) 'move into protected platform path'
    Assert-Allowed (
        Invoke-Hook 'extensions-gate.ps1' (New-ToolEvent 'apply_patch' @{ command = $safePatch })
    ) 'safe targeted edit'
    Assert-Allowed (
        Invoke-HookProcess 'extensions-gate.ps1' (New-ToolEvent 'apply_patch' @{ command = $safePatch })
    ) 'extensions gate without stdin EOF'
    Assert-Denied (Invoke-HookProcess 'extensions-gate.ps1' -InputMode Eof) 'extensions gate EOF without JSON'
    Assert-Denied (Invoke-HookProcess 'extensions-gate.ps1' @{}) 'extensions gate missing event fields'

    $sentinel = Join-Path $testRoot 'iwe-dry-run.flag'
    Set-Content -LiteralPath $sentinel -Value '{"initiator":"test"}' -Encoding UTF8
    $dryRunEnvironment = @{ IWE_DRY_RUN_SENTINEL = $sentinel }
    Assert-Denied (
        Invoke-Hook 'dry-run-gate.ps1' (New-ToolEvent 'apply_patch' @{ command = $safePatch }) $dryRunEnvironment
    ) 'dry-run apply_patch'
    Assert-Allowed (
        Invoke-Hook 'dry-run-gate.ps1' (New-ToolEvent 'Bash' @{ command = 'git status --short' }) $dryRunEnvironment
    ) 'dry-run read-only command'
    Assert-Allowed (
        Invoke-HookProcess 'dry-run-gate.ps1' (New-ToolEvent 'Bash' @{ command = 'git status --short' }) $dryRunEnvironment
    ) 'dry-run gate without stdin EOF'
    Assert-Denied (Invoke-HookProcess 'dry-run-gate.ps1' -InputMode Eof) 'dry-run gate EOF without JSON'
    Assert-Denied (Invoke-HookProcess 'dry-run-gate.ps1' @{}) 'dry-run gate missing event fields'
    foreach ($nestedMutation in @(
        'powershell -NoProfile -Command "Set-Content C:\workspace\state.txt changed"',
        'powershell -Command "ri C:\workspace\project -Recurse -Force"',
        'cmd /c "del C:\workspace\state.txt"',
        'cmd /d /c "del C:\workspace\state.txt"',
        'iex "Set-Content C:\workspace\state.txt changed"'
    )) {
        Assert-Denied (
            Invoke-Hook 'dry-run-gate.ps1' (New-ToolEvent 'Bash' @{ command = $nestedMutation }) $dryRunEnvironment
        ) "dry-run nested mutation: $nestedMutation"
    }

    $governancePath = Join-Path $testRoot 'DS-strategy'
    $currentPath = Join-Path $governancePath 'current'
    New-Item -ItemType Directory -Path $currentPath -Force | Out-Null
    & git -C $governancePath init --quiet
    & git -C $governancePath config user.email 'test@example.invalid'
    & git -C $governancePath config user.name 'Codex hook test'
    $invalidDayPlan = Join-Path $currentPath 'DayPlan 2099-01-01.md'
    Set-Content -LiteralPath $invalidDayPlan -Value '# invalid' -Encoding UTF8
    & git -C $governancePath add 'current/DayPlan 2099-01-01.md'
    $protocolValidator = Join-Path $templateRoot 'seed\strategy\.githooks\protocol-artifact-validate.py'
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $protocolOutput = @(& python.exe $protocolValidator --repo $governancePath --staged 2>&1)
        $protocolExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($protocolExitCode -eq 0) {
        throw "invalid staged DayPlan: expected Git validator failure, got success: $($protocolOutput -join [Environment]::NewLine)"
    }

    $installRoot = Join-Path $testRoot 'installed'
    $installHooks = Join-Path $installRoot 'DS-strategy\.githooks'
    $installMemory = Join-Path $installRoot 'memory'
    $installExtensions = Join-Path $installRoot 'extensions'
    New-Item -ItemType Directory -Path $installHooks -Force | Out-Null
    New-Item -ItemType Directory -Path $installMemory -Force | Out-Null
    New-Item -ItemType Directory -Path $installExtensions -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installMemory 'pilot-memory.md') -Value "memory`r`nstate" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installExtensions 'pilot-extension.yaml') -Value "enabled: true" -Encoding UTF8
    $preCommitStub = @'
#!/bin/bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
exit 0
'@
    Set-Content -LiteralPath (Join-Path $installHooks 'pre-commit') -Value $preCommitStub -Encoding UTF8
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $templateRoot 'setup-codex.ps1') -Workspace $installRoot -RefreshInstructions | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'setup-codex.ps1 -RefreshInstructions failed' }
    $configuration = Get-Content -LiteralPath (Join-Path $installRoot '.codex\hooks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $commands = @($configuration.hooks.PreToolUse | ForEach-Object { $_.hooks } | ForEach-Object { $_.commandWindows })
    $postToolCommands = @($configuration.hooks.PostToolUse | ForEach-Object { $_.hooks } | ForEach-Object { $_.commandWindows })
    foreach ($name in @('destructive-guard.ps1', 'destructive-mcp-guard.ps1', 'extensions-gate.ps1', 'dry-run-gate.ps1')) {
        if (-not ($commands -match [regex]::Escape($name))) { throw "generated hooks.json does not register $name" }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot ".codex\hooks\$name"))) { throw "setup did not copy $name" }
    }
    if (-not ($postToolCommands -match 'memory-exocortex-sync\.ps1')) { throw 'generated hooks.json does not register memory-exocortex-sync.ps1' }
    $installedMemorySync = Join-Path $installRoot '.codex\hooks\memory-exocortex-sync.ps1'
    if (-not (Test-Path -LiteralPath $installedMemorySync)) { throw 'setup did not copy memory-exocortex-sync.ps1' }
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installedMemorySync
    if ($LASTEXITCODE -ne 0) { throw 'memory-exocortex-sync.ps1 failed' }
    $mirroredMemory = Join-Path $installRoot 'DS-strategy\exocortex\pilot-memory.md'
    $mirroredExtension = Join-Path $installRoot 'DS-strategy\exocortex\extensions\pilot-extension.yaml'
    if (-not (Test-Path -LiteralPath $mirroredMemory)) { throw 'memory-exocortex-sync.ps1 did not mirror memory' }
    if (-not (Test-Path -LiteralPath $mirroredExtension)) { throw 'memory-exocortex-sync.ps1 did not mirror extensions' }

    $syncSentinel = Join-Path $testRoot 'memory-sync-dry-run.flag'
    Set-Content -LiteralPath $syncSentinel -Value 'active' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installMemory 'pilot-memory.md') -Value 'must not mirror during dry-run' -Encoding UTF8
    $savedSyncSentinel = [Environment]::GetEnvironmentVariable('IWE_DRY_RUN_SENTINEL', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('IWE_DRY_RUN_SENTINEL', $syncSentinel, 'Process')
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installedMemorySync
    } finally {
        [Environment]::SetEnvironmentVariable('IWE_DRY_RUN_SENTINEL', $savedSyncSentinel, 'Process')
    }
    if ((Get-Content -LiteralPath $mirroredMemory -Raw -Encoding UTF8) -match 'must not mirror') {
        throw 'memory-exocortex-sync.ps1 wrote during dry-run'
    }
    if ($commands -match 'protocol-artifact-validate') { throw 'protocol validator must not be registered as a Codex hook' }
    if (-not (Test-Path -LiteralPath (Join-Path $installHooks 'protocol-artifact-validate.py'))) { throw 'setup did not install the Git validator' }
    $installedPreCommit = Get-Content -LiteralPath (Join-Path $installHooks 'pre-commit') -Raw -Encoding UTF8
    if (($installedPreCommit | Select-String -Pattern '# BEGIN IWE PROTOCOL ARTIFACT VALIDATION' -AllMatches).Matches.Count -ne 1) {
        throw 'setup did not install exactly one protocol validation block in pre-commit'
    }

    Write-Host 'PASS: Codex safety hook matrix'
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
}
