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
    [string]$WeekReviewDay = "Saturday",
    [string]$WeekReviewTime = "11:00",
    [string]$BashPath = "C:\Program Files\Git\bin\bash.exe",
    [string]$CodexCliPath = "",
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

if (-not $CodexCliPath) {
    $candidates = @(
        (Join-Path $env:APPDATA "npm\codex"),
        (Join-Path $env:USERPROFILE ".local\bin\codex")
    )
    $CodexCliPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $CodexCliPath) {
    throw "Codex CLI not found. Pass -CodexCliPath explicitly."
}

$wsMsys = ConvertTo-MsysPath $Workspace
$cliMsys = ConvertTo-MsysPath $CodexCliPath

Write-Host "=== install-windows-tasks ==="
Write-Host "  Workspace:  $Workspace"
Write-Host "  Runner:     $runtimeScript"
Write-Host "  Agent:      Codex"
Write-Host "  Agent CLI:  $CodexCliPath"
Write-Host "  Morning:    daily $MorningTime (local)"
Write-Host "  WeekReview: $WeekReviewDay $WeekReviewTime (local)"
Write-Host ""

# Task Scheduler cmdlets contact the Windows service even when their result is
# used only to build an object. In restricted Codex sessions that can emit
# Access denied before ShouldProcess sees -WhatIf. Keep rehearsal deterministic
# and completely service-free.
if ($WhatIfPreference) {
    Write-Host "What if: register $TaskFolder\Strategist Morning -> morning at $MorningTime daily"
    Write-Host "What if: register $TaskFolder\Strategist WeekReview -> week-review at $WeekReviewTime on $WeekReviewDay"
    Write-Host "No Scheduled Tasks were changed."
    return
}

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
    $inner = "source '$wsMsys/.iwe-paths' && " +
             "export CODEX_CLI_PATH='$cliMsys' IWE_STRATEGIST_NOTIFY=false && " +
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
            -Description "IWE Strategist (R1, Codex): $scenario" | Out-Null
        Write-Host "  + $name -> strategist.sh $scenario"
    }
}

Write-Host ""
Write-Host "Verify: Get-ScheduledTask -TaskPath '\IWE\' | Format-Table TaskName, State"
Write-Host "Logs:   $env:USERPROFILE\logs\strategist\"
