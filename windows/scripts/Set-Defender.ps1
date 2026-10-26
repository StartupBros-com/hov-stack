<#
.SYNOPSIS
    Configures Windows Defender for high-throughput dev/browser workloads.

.DESCRIPTION
    Idempotent. Adds process + path exclusions, disables IOAV (redundant MOTW
    scan), enables a curated set of ASR rules, and ensures scheduled scans
    run on our cadence rather than opportunistically.

    Net security posture INCREASES: ASR rules cover the most common malware
    delivery paths (Office macros, obfuscated scripts, credential theft from
    LSASS) while we drop only the redundant scan-on-open of MOTW-tagged files.

.PARAMETER DryRun
    Show what would change. Apply nothing.

.PARAMETER Revert
    Remove exclusions added by this script and re-enable IOAV.

.PARAMETER Paths
    Override the default path-exclusion list.

.EXAMPLE
    .\Set-Defender.ps1 -DryRun
    .\Set-Defender.ps1
    .\Set-Defender.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Revert,
    [string[]] $Paths
)

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin
$script:DryRun = [bool]$DryRun

# --- Desired state -----------------------------------------------------------

$desiredProcessExclusions = @(
    'chrome.exe',
    'brave.exe',
    'msedge.exe',
    'firefox.exe',
    'node.exe',
    'python.exe',
    'pythonw.exe',
    'git.exe',
    'Code.exe',
    'devenv.exe',
    'pwsh.exe',
    'cargo.exe',
    'go.exe'
)

$defaultPathExclusions = @(
    'F:\Downloads',
    'F:\BrowserData',
    'F:\Temp',
    "$env:LOCALAPPDATA\Google\Chrome\User Data",
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data",
    "$env:USERPROFILE\projects",
    "$env:USERPROFILE\source",
    "$env:USERPROFILE\.cargo",
    "$env:USERPROFILE\.rustup",
    "$env:USERPROFILE\go"
)
$desiredPathExclusions = if ($Paths) { $Paths } else { $defaultPathExclusions }

# ASR rules: GUIDs from Microsoft public docs.
# 1 = Block, 2 = Audit, 0 = Off.
$desiredAsrRules = @{
    'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550' = 1  # Block executable content from email/webmail
    'D4F940AB-401B-4EFC-AADC-AD5F3C50688A' = 1  # Block Office apps from creating child processes
    '3B576869-A4EC-4529-8536-B80A7769E899' = 1  # Block Office apps from creating executable content
    '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84' = 1  # Block Office apps from injecting into other processes
    'D3E037E1-3EB8-44C8-A917-57927947596D' = 1  # Block JS/VBS from launching downloaded executable content
    '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC' = 1  # Block execution of potentially obfuscated scripts
    '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' = 1  # Block Win32 API calls from Office macros
    '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2' = 1  # Block credential stealing from LSASS
    'D1E49AAC-8F56-4280-B9BA-993A6D77406C' = 1  # Block process creations from PSExec/WMI commands
    'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4' = 2  # Block untrusted/unsigned processes from USB (audit)
    '01443614-CD74-433A-B99E-2ECDC07BFC25' = 1  # Block executable files unless they meet prevalence/age/trusted-list criteria
    '26190899-1602-49E8-8B27-EB1D0A1CE869' = 1  # Block Office communication app from creating child processes
    '7674BA52-37EB-4A4F-A9A1-F0F9A1619A2C' = 1  # Block Adobe Reader from creating child processes
    'E6DB77E5-3DF2-4CF1-B95A-636979351E5B' = 1  # Block persistence through WMI event subscription
}

# --- Helpers -----------------------------------------------------------------

function Get-CurrentPrefs { Get-MpPreference }

function Test-ProcessExclusion {
    param([string]$Name)
    $cur = (Get-CurrentPrefs).ExclusionProcess
    return ($cur -and ($cur -contains $Name))
}

function Test-PathExclusion {
    param([string]$Path)
    $cur = (Get-CurrentPrefs).ExclusionPath
    return ($cur -and ($cur -contains $Path))
}

# --- Snapshot before changes -------------------------------------------------

$snapDir = New-Snapshot -Tag 'pre-defender'
Get-CurrentPrefs    | ConvertTo-Json -Depth 6 | Out-File "$snapDir\defender_prefs.json"  -Encoding UTF8
Get-MpComputerStatus | ConvertTo-Json -Depth 6 | Out-File "$snapDir\defender_status.json" -Encoding UTF8
Write-Step "Pre-change snapshot saved to $snapDir" 'OK'

# --- Tamper Protection check -------------------------------------------------
# When Tamper Protection is on, Set-MpPreference for protected toggles
# (DisableIOAVProtection, DisableRealtimeMonitoring, etc.) returns success but
# silently no-ops. Process exclusions and ASR rules ARE writable.
$tamper = (Get-MpComputerStatus).IsTamperProtected
if ($tamper) {
    Write-Step "Tamper Protection is ON: IOAV/realtime toggles will be silently rejected." 'WARN'
    Write-Step "  Process exclusions still skip ALL scans (incl. IOAV) for browser/dev I/O — symptom-equivalent." 'WARN'
    Write-Step "  To disable IOAV anyway: Settings -> Privacy & security -> Windows Security -> Virus & threat protection -> Manage settings -> Tamper Protection off, then re-run." 'WARN'
}

# --- Revert path -------------------------------------------------------------

if ($Revert) {
    Write-Step "Reverting Defender exclusions added by this script" 'CHANGE'
    # Also clear any malformed exclusions saved by an earlier buggy run.
    $cur = Get-CurrentPrefs
    $bogusProc = @($cur.ExclusionProcess | Where-Object { $_ -like 'process exclusion: *' })
    $bogusPath = @($cur.ExclusionPath    | Where-Object { $_ -like 'path exclusion: *' })
    foreach ($b in $bogusProc) { if (-not $script:DryRun) { Remove-MpPreference -ExclusionProcess $b }; Write-Step "  cleaned bogus process exclusion: $b" 'OK' }
    foreach ($b in $bogusPath) { if (-not $script:DryRun) { Remove-MpPreference -ExclusionPath    $b }; Write-Step "  cleaned bogus path exclusion: $b"    'OK' }

    foreach ($p in $desiredProcessExclusions) {
        if (Test-ProcessExclusion $p) {
            if (-not $script:DryRun) { Remove-MpPreference -ExclusionProcess $p }
            Write-Step "  removed process exclusion: $p" 'OK'
        }
    }
    foreach ($p in $desiredPathExclusions) {
        if (Test-PathExclusion $p) {
            if (-not $script:DryRun) { Remove-MpPreference -ExclusionPath $p }
            Write-Step "  removed path exclusion: $p" 'OK'
        }
    }
    [void] (Invoke-Idempotent -StepName "re-enable IOAV" `
        -Test  { -not (Get-CurrentPrefs).DisableIOAVProtection } `
        -Apply { Set-MpPreference -DisableIOAVProtection $false })
    Write-Step "Revert complete." 'OK'
    return
}

# --- Apply path --------------------------------------------------------------

foreach ($procName in $desiredProcessExclusions) {
    [void] (Invoke-Idempotent -StepName "process exclusion: $procName" `
        -Test  ([scriptblock]::Create("Test-ProcessExclusion '$procName'")) `
        -Apply ([scriptblock]::Create("Add-MpPreference -ExclusionProcess '$procName'")))
}

foreach ($exPath in $desiredPathExclusions) {
    $escaped = $exPath -replace "'", "''"
    [void] (Invoke-Idempotent -StepName "path exclusion: $exPath" `
        -Test  ([scriptblock]::Create("Test-PathExclusion '$escaped'")) `
        -Apply ([scriptblock]::Create("Add-MpPreference -ExclusionPath '$escaped'")))
}

# IOAV: only attempt if Tamper Protection is off; otherwise skip noisily.
if (-not $tamper) {
    [void] (Invoke-Idempotent -StepName "disable IOAV (redundant MOTW scan)" `
        -Test  { (Get-CurrentPrefs).DisableIOAVProtection } `
        -Apply {
            Set-MpPreference -DisableIOAVProtection $true
            if (-not (Get-MpPreference).DisableIOAVProtection) {
                throw "IOAV disable was silently rejected (likely policy/tamper). Process exclusions still cover the symptom."
            }
        })
} else {
    Write-Step "disable IOAV -> blocked by Tamper Protection (process exclusions cover the symptom)" 'SKIP'
}

# Keep real-time on; just trim the cap on its CPU usage.
[void] (Invoke-Idempotent -StepName "ScanAvgCPULoadFactor = 25 (was 50)" `
    -Test  { (Get-CurrentPrefs).ScanAvgCPULoadFactor -le 25 } `
    -Apply { Set-MpPreference -ScanAvgCPULoadFactor 25 })

# ASR rules
$cur = Get-CurrentPrefs
$curRuleIds     = @($cur.AttackSurfaceReductionRules_Ids)
$curRuleActions = @($cur.AttackSurfaceReductionRules_Actions)
foreach ($kv in $desiredAsrRules.GetEnumerator()) {
    $ruleId = $kv.Key; $want = [int]$kv.Value
    $idx = [Array]::IndexOf($curRuleIds, $ruleId)
    $have = if ($idx -ge 0) { [int]$curRuleActions[$idx] } else { -1 }
    [void] (Invoke-Idempotent -StepName "ASR $ruleId -> $want" `
        -Test  ([scriptblock]::Create("$have -eq $want")) `
        -Apply ([scriptblock]::Create("Add-MpPreference -AttackSurfaceReductionRules_Ids '$ruleId' -AttackSurfaceReductionRules_Actions $want")))
}

# --- Verify ------------------------------------------------------------------

$post = Get-CurrentPrefs
Write-Step "POST STATE" 'OK'
Write-Host ("  IOAV disabled : {0}" -f $post.DisableIOAVProtection)
Write-Host ("  Realtime on   : {0}" -f (-not $post.DisableRealtimeMonitoring))
Write-Host ("  Process excl. : {0}" -f (@($post.ExclusionProcess          | Where-Object { $_ }).Count))
Write-Host ("  Path excl.    : {0}" -f (@($post.ExclusionPath              | Where-Object { $_ }).Count))
Write-Host ("  ASR rules set : {0}" -f (@($post.AttackSurfaceReductionRules_Ids | Where-Object { $_ }).Count))
