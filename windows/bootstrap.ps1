<#
.SYNOPSIS
    Idempotent Windows configuration bootstrapper.

.DESCRIPTION
    Run on a fresh machine, after a Windows feature update, or any time you
    suspect drift. Each phase script is itself idempotent and supports
    -DryRun. Phases are intentionally separate so a failure in one does not
    prevent re-running the others.

.PARAMETER Phases
    Subset of phase names to run: Defender, DiskLayout. Default: Defender.
    DiskLayout is opt-in because it adds a partition.

.PARAMETER DryRun
    Pass through to all phase scripts.

.EXAMPLE
    .\bootstrap.ps1 -DryRun
    .\bootstrap.ps1 -Phases Defender,DiskLayout -DryRun
    .\bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string[]] $Phases = @('Defender'),
    [switch]   $DryRun
)

. "$PSScriptRoot\lib\Common.ps1"
Assert-Admin

$map = @{
    Defender   = "$PSScriptRoot\scripts\Set-Defender.ps1"
    DiskLayout = "$PSScriptRoot\scripts\Set-DiskLayout.ps1"
}

foreach ($name in $Phases) {
    if (-not $map.ContainsKey($name)) { Write-Step "Unknown phase: $name" 'WARN'; continue }
    $path = $map[$name]
    if (-not (Test-Path $path)) { Write-Step "Phase script missing: $path (skipping)" 'SKIP'; continue }
    Write-Step "==== Phase: $name ====" 'STEP'
    if ($DryRun) { & $path -DryRun } else { & $path }
}

Write-Step "bootstrap complete" 'OK'
