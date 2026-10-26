Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Write-Step {
    param([string]$Message, [string]$Tag = 'STEP')
    $color = switch ($Tag) {
        'STEP'   { 'Cyan' }
        'OK'     { 'Green' }
        'SKIP'   { 'DarkGray' }
        'CHANGE' { 'Yellow' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        default  { 'White' }
    }
    Write-Host "[$Tag] $Message" -ForegroundColor $color
}

function Invoke-Idempotent {
    <#
        .SYNOPSIS
        Run a change only if a test condition is not already true.
        Honors -DryRun via $script:DryRun in the calling script.
        Param name $StepName (not $Name) avoids collisions with caller-scope
        $name vars referenced inside Test/Apply scriptblocks.
    #>
    param(
        [Parameter(Mandatory)] [string]    $StepName,
        [Parameter(Mandatory)] [scriptblock] $Test,
        [Parameter(Mandatory)] [scriptblock] $Apply
    )
    if (& $Test) {
        Write-Step "$StepName -> already in desired state" 'SKIP'
        return $false
    }
    if ($script:DryRun) {
        Write-Step "$StepName -> WOULD APPLY (dry-run)" 'CHANGE'
        return $false
    }
    Write-Step "$StepName -> applying" 'CHANGE'
    & $Apply
    Write-Step "$StepName -> applied" 'OK'
    return $true
}

function New-Snapshot {
    param([string]$Tag = 'manual')
    $root = "$PSScriptRoot\..\snapshots"
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir = Join-Path $root "${Tag}_$ts"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}
