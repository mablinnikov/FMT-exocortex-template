<#
.SYNOPSIS
Installs the recurring Strategist (R1) jobs as Windows Scheduled Tasks.

.DESCRIPTION
The template ships the Strategist schedule as launchd plists (macOS) and systemd
timers (Linux) only; roles/strategist/install.sh exits early when launchctl and
systemctl are both absent, so a Windows workspace silently ends up with no
recurring Strategist runs at all. This script is the Windows equivalent of that
install step and registers the same two jobs:

  IWE\Strategist Morning     -> strategist.sh morning      (daily)
  IWE\Strategist WeekReview  -> strategist.sh week-review  (weekly)

Times are LOCAL machine time. The TIMEZONE_HOUR value in .exocortex.env is a UTC
hour and must not be passed here verbatim -- Task Scheduler has no UTC mode.

Both tasks run under the current user with an interactive logon, so no password
is stored and nothing runs while the user is logged off. StartWhenAvailable
covers the common case of the machine being off at the scheduled moment.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File setup\install-windows-tasks.ps1 -WhatIf

.EXAMPLE
powershell -ExecutionPolicy Bypass -File setup\install-windows-tasks.ps1 -Remove
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Workspace = "",
    [string]$MorningTime = "07:00",
    [ValidateSet("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")]
    [string]$WeekReviewDay = "Monday",
    [string]$WeekReviewTime = "00:00",
    [string]$BashPath = "C:\Program Files\Git\bin\bash.exe",
    [string]$ClaudeCliPath = "",
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# $PSScriptRoot is not reliably populated inside param() defaults under Windows
# PowerShell 5.1, so the workspace default is resolved here instead: setup/ ->
# FMT-exocortex-template/ -> workspace root.
if (-not $Workspace) {
    $Workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$TaskFolder = "\IWE"
$Tasks = [ordered]@{
    "Strategist Morning"    = "morning"
    "Strategist WeekReview" = "week-review"
}

function ConvertTo-MsysPath {
    # C:\Users\X\IWE -> /c/Users/X/IWE  (Git Bash understands only the latter in `source`)
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    return "/$drive" + ($full.Substring(2) -replace '\\', '/')
}

function Remove-IweTasks {
    foreach ($name in $Tasks.Keys) {
        $existing = Get-ScheduledTask -TaskName $name -TaskPath "$TaskFolder\" -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            Write-Host "  - $name - not registered, nothing to remove"
            continue
        }
        if ($PSCmdlet.ShouldProcess("$TaskFolder\$name", "Unregister scheduled task")) {
            Unregister-ScheduledTask -TaskName $name -TaskPath "$TaskFolder\" -Confirm:$false
            Write-Host "  x $name - removed"
        }
    }
}

if ($Remove) {
    Write-Host "=== Removing IWE Strategist tasks ==="
    Remove-IweTasks
    return
}

# --- Preconditions -----------------------------------------------------------

$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$runtimeScript = Join-Path $Workspace ".iwe-runtime\roles\strategist\scripts\strategist.sh"
$pathsFile = Join-Path $Workspace ".iwe-paths"

if (-not (Test-Path -LiteralPath $runtimeScript)) {
    throw "Runtime script not found: $runtimeScript`nRun: bash FMT-exocortex-template/setup/build-runtime.sh"
}
if (-not (Test-Path -LiteralPath $pathsFile)) {
    throw "IWE env file not found: $pathsFile`nRun: bash FMT-exocortex-template/setup/install-iwe-paths.sh --workspace <ws>"
}
if (-not (Test-Path -LiteralPath $BashPath)) {
    throw "Git Bash not found: $BashPath`nPass -BashPath with the correct location."
}

# The runner aborts with exit 127 unless it can resolve a CLI, and Task Scheduler
# does not run a login shell, so PATH cannot be relied on -- hand it the resolved
# binary explicitly. claude comes first: strategist.sh drives the CLI with Claude
# Code's own flags (--allowedTools, --model, -p), which codex rejects outright.
if (-not $ClaudeCliPath) {
    $candidates = @(
        (Join-Path $env:APPDATA "npm\claude"),
        (Join-Path $env:USERPROFILE ".local\bin\claude"),
        (Join-Path $env:APPDATA "npm\codex")
    )
    $ClaudeCliPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ClaudeCliPath) {
    throw "No agent CLI found (looked for claude, then codex). Pass -ClaudeCliPath explicitly."
}

$wsMsys = ConvertTo-MsysPath $Workspace
$cliMsys = ConvertTo-MsysPath $ClaudeCliPath

Write-Host "=== install-windows-tasks ==="
Write-Host "  Workspace:  $Workspace"
Write-Host "  Runner:     $runtimeScript"
Write-Host "  Agent CLI:  $ClaudeCliPath"
Write-Host "  Morning:    daily $MorningTime (local)"
Write-Host "  WeekReview: $WeekReviewDay $WeekReviewTime (local)"
Write-Host ""

# --- Registration ------------------------------------------------------------

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

foreach ($entry in $Tasks.GetEnumerator()) {
    $name = $entry.Key
    $scenario = $entry.Value

    # -l gives the login shell PATH (git, python); .iwe-paths supplies IWE_* which
    # strategist.sh needs to locate the workspace, and without which it would fall
    # back to $HOME/IWE and operate on a directory that does not exist here.
    #
    # The secrets file is sourced only if present, and the `|| true` keeps a missing
    # or unreadable file from breaking the && chain -- the run should reach the CLI
    # and fail there with a legible auth error, not die silently in the wrapper.
    # It carries ANTHROPIC_API_KEY: claude.ai returns 403 from this egress, so the
    # OAuth login flow is unavailable and key auth against api.anthropic.com (which
    # answers 401, i.e. reachable, not country-blocked) is the way in.
    $inner = "source '$wsMsys/.iwe-paths' && " +
             "{ [ -f '$wsMsys/.secrets/anthropic_key.env' ] && set -a && . '$wsMsys/.secrets/anthropic_key.env' && set +a || true; } && " +
             "export CLAUDE_CLI_PATH='$cliMsys' && " +
             "exec `"`$IWE_RUNTIME/roles/strategist/scripts/strategist.sh`" $scenario"
    $argument = '-l -c "' + $inner.Replace('"', '\"') + '"'

    if ($scenario -eq "morning") {
        $trigger = New-ScheduledTaskTrigger -Daily -At $MorningTime
    } else {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeekReviewDay -At $WeekReviewTime
    }

    $action = New-ScheduledTaskAction -Execute $BashPath -Argument $argument -WorkingDirectory $Workspace

    if ($PSCmdlet.ShouldProcess("$TaskFolder\$name", "Register scheduled task")) {
        $existing = Get-ScheduledTask -TaskName $name -TaskPath "$TaskFolder\" -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Unregister-ScheduledTask -TaskName $name -TaskPath "$TaskFolder\" -Confirm:$false
        }
        Register-ScheduledTask -TaskName $name -TaskPath $TaskFolder `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description "IWE Strategist (R1): $scenario" | Out-Null
        Write-Host "  + $name -> strategist.sh $scenario"
    }
}

Write-Host ""
Write-Host "Verify: Get-ScheduledTask -TaskPath '\IWE\' | Format-Table TaskName, State"
Write-Host "Logs:   $env:USERPROFILE\logs\strategist\"
