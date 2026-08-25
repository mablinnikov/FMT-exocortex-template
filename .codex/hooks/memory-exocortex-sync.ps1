[CmdletBinding()]
param()

# Codex PostToolUse mirror for top-level memory/* and extensions/* files.
# The event payload is intentionally not read: Codex apply_patch does not expose
# Claude's tool_input.file_path contract, and a full flat-directory reconciliation
# is cheap, deterministic, and covers shell writes as well.
$ErrorActionPreference = 'Stop'

function Get-NormalizedBytes {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    return [Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Sync-FlatDirectory {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }

    $files = @(Get-ChildItem -LiteralPath $Source -File | Where-Object {
        $_.Extension -in @('.md', '.yaml', '.yml')
    })
    if ($files.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    foreach ($file in $files) {
        $target = Join-Path $Destination $file.Name
        $sourceBytes = Get-NormalizedBytes $file.FullName
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $targetBytes = Get-NormalizedBytes $target
            if (Test-BytesEqual $sourceBytes $targetBytes) { continue }
        }
        [IO.File]::WriteAllBytes($target, $sourceBytes)
    }
}

try {
    $sentinel = if ($env:IWE_DRY_RUN_SENTINEL) {
        $env:IWE_DRY_RUN_SENTINEL
    } else {
        Join-Path ([IO.Path]::GetTempPath()) 'iwe-dry-run.flag'
    }
    if (Test-Path -LiteralPath $sentinel) { exit 0 }

    $workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $exocortex = Join-Path $workspace 'DS-strategy\exocortex'
    Sync-FlatDirectory (Join-Path $workspace 'memory') $exocortex
    Sync-FlatDirectory (Join-Path $workspace 'extensions') (Join-Path $exocortex 'extensions')
} catch {
    # Advisory backup hook: never replace the original tool result with a sync failure.
}

exit 0
