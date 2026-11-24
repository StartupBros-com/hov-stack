<#
.SYNOPSIS
    Idempotent Windows configuration bootstrapper.

.DESCRIPTION
    Runs the phase scripts you name. Each phase script is itself idempotent
    and supports -DryRun. Phases are intentionally separate so a failure in
    one does not prevent re-running the others.

.PARAMETER Phases
    Phase names to run: DiskLayout. Nothing runs unless you name it, because
    DiskLayout adds a partition.

    Defender is no longer a phase: the Defender script was removed on
    2026-11-23. Naming it prints a notice and changes nothing. README.md in
    this directory says what that script set and how to undo it.

.PARAMETER DryRun
    Pass through to all phase scripts.

.EXAMPLE
    .\bootstrap.ps1 -Phases DiskLayout -DryRun
    .\bootstrap.ps1 -Phases DiskLayout
#>
[CmdletBinding()]
param(
    [string[]] $Phases = @(),
    [switch]   $DryRun
)

. "$PSScriptRoot\lib\Common.ps1"

$map = @{
    DiskLayout = "$PSScriptRoot\scripts\Set-DiskLayout.ps1"
}
# Phases this script used to run. Naming one says where it went, not "unknown".
$removed = @{
    Defender = 'removed on 2026-11-23, so nothing was changed. See "Defender script removed" in README.md in this directory'
}

$toRun = @()
# "powershell -File bootstrap.ps1 -Phases A,B" hands over one string, "A,B".
$named = @($Phases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $named) {
    if ($removed.ContainsKey($name)) { Write-Step "Phase ${name}: $($removed[$name])" 'WARN'; continue }
    if (-not $map.ContainsKey($name)) { Write-Step "Unknown phase: $name" 'WARN'; continue }
    $toRun += $name
}
if ($toRun.Count -eq 0) {
    Write-Step "No phase to run. Name one with -Phases: $(($map.Keys | Sort-Object) -join ', ')" 'SKIP'
    return
}

Assert-Admin
foreach ($name in $toRun) {
    $path = $map[$name]
    if (-not (Test-Path $path)) { Write-Step "Phase script missing: $path (skipping)" 'SKIP'; continue }
    Write-Step "==== Phase: $name ====" 'STEP'
    if ($DryRun) { & $path -DryRun } else { & $path }
}

Write-Step "bootstrap complete" 'OK'
