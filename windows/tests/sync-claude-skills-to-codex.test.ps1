# Self-contained U7 conformance for the Windows Codex Desktop skill bridge.
[CmdletBinding()]
param(
    [string]$ProGateRepositoryRoot = $env:PRO_GATE_REPOSITORY_ROOT,
    [string]$CandidateArchive = $env:PRO_GATE_CANDIDATE_ARCHIVE,
    [string]$CandidateChecksum = $env:PRO_GATE_CANDIDATE_CHECKSUM
)

$ErrorActionPreference = "Stop"
$testRoot = Split-Path -Parent $PSCommandPath
$windowsRoot = Split-Path -Parent $testRoot
$bridge = Join-Path $windowsRoot "sync-claude-skills-to-codex.ps1"
$wrapper = Join-Path $windowsRoot "sync-claude-skills-to-codex.sh"
$fixture = Join-Path $testRoot "fixtures/pro-gate-review-decision-v1.json"
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-That {
    param([bool]$Condition, [string]$Name, [string]$Detail = "")
    if ($Condition) { Write-Output "ok - $Name" }
    else { $script:failures.Add("not ok - $Name$([Environment]::NewLine)$Detail") }
}

function Get-PwshExecutable {
    $native = Join-Path $PSHOME "pwsh"
    if (Test-Path -LiteralPath $native) { return $native }
    $windows = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path -LiteralPath $windows) { return $windows }
    return "pwsh"
}

function Invoke-Bridge {
    param([string[]]$Arguments)
    $output = @(& (Get-PwshExecutable) -NoLogo -NoProfile -NonInteractive -File $bridge @Arguments 2>&1)
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
}

function Assert-ValidationFailure {
    param([string]$Name, $Result, [string]$ExpectedDiagnostic)

    # Stable machine IDs are the cross-platform contract; rendered exception prose is not.
    # Every caller separately asserts the destination stayed absent or byte-identical.
    $diagnosticFound = $Result.Output.Contains($ExpectedDiagnostic)
    Assert-That ($Result.ExitCode -ne 0 -and $diagnosticFound) $Name $Result.Output
}

function Copy-RepositorySkill {
    param([string]$SourceRepository, [string]$DestinationRepository)
    New-Item -ItemType Directory -Force -Path (Join-Path $DestinationRepository "skills") | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRepository "skills/pro-gate") -Destination (Join-Path $DestinationRepository "skills") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $SourceRepository ".claude-plugin") -Destination $DestinationRepository -Recurse -Force
    return Join-Path $DestinationRepository "skills/pro-gate"
}

function ConvertTo-TestWslPath {
    param([string]$Path)
    if (-not [System.OperatingSystem]::IsWindows()) { return $Path }
    if ($Path.StartsWith("/")) { return "\\wsl.localhost\Ubuntu\" + $Path.TrimStart("/").Replace("/", "\") }
    return $Path
}

function Get-WslPathForTest {
    param([string]$Path)
    if ($Path.StartsWith("\\wsl.localhost\Ubuntu\", [StringComparison]::OrdinalIgnoreCase)) {
        return "/" + $Path.Substring("\\wsl.localhost\Ubuntu\".Length).Replace("\", "/")
    }
    $result = @(& wsl.exe -d Ubuntu -- wslpath -u $Path 2>&1)
    if ($LASTEXITCODE -ne 0 -or $result.Count -ne 1) { throw "Could not convert temporary path for candidate installation: $Path" }
    return $result[0].Trim()
}

function Invoke-WslWrapper {
    param([string[]]$Arguments)

    $output = @(& wsl.exe -d Ubuntu -- bash (Get-WslPathForTest $wrapper) @Arguments 2>&1)
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
}

function Install-CandidateRuntime {
    param([string]$Installer, [string]$Version, [string]$Archive, [string]$Checksum, [string]$RuntimeHome, [string]$OracleHome)
    if ([System.OperatingSystem]::IsWindows()) {
        $output = @(& wsl.exe -d Ubuntu -- env "PRO_GATE_HOME=$(Get-WslPathForTest $RuntimeHome)" "ORACLE_DIR=$(Get-WslPathForTest $OracleHome)" bash (Get-WslPathForTest $Installer) --version $Version --archive (Get-WslPathForTest $Archive) --checksum (Get-WslPathForTest $Checksum) --skip-services 2>&1)
    }
    else {
        $output = @(& bash $Installer --version $Version --archive $Archive --checksum $Checksum --skip-services 2>&1)
    }
    if ($LASTEXITCODE -ne 0) { throw "Checksum-pinned candidate installation failed: $($output -join ' ')" }
}

if (-not $ProGateRepositoryRoot) {
    $linuxUser = if ($env:USER) { $env:USER } else { $env:USERNAME }
    $candidateRoot = ConvertTo-TestWslPath "/home/$linuxUser/SITES/pro-gate/.claude/worktrees/pro-gate-simplification-ideation"
    if (Test-Path -LiteralPath $candidateRoot) { $ProGateRepositoryRoot = $candidateRoot }
    else { $ProGateRepositoryRoot = Join-Path $HOME "SITES/pro-gate" }
}
if (-not $CandidateArchive) { $CandidateArchive = Join-Path $ProGateRepositoryRoot "dist/pro-gate-runtime-0.59.0.tar.gz" }
if (-not $CandidateChecksum) { $CandidateChecksum = "$CandidateArchive.sha256" }

foreach ($required in @($bridge, $fixture, (Join-Path $ProGateRepositoryRoot "install.sh"), (Join-Path $ProGateRepositoryRoot "skills/pro-gate/SKILL.md"), $CandidateArchive, $CandidateChecksum)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "U7 fixture prerequisite is missing: $required" }
}

$checksumText = Get-Content -LiteralPath $CandidateChecksum -Raw
$expectedArchiveDigest = ([regex]::Match($checksumText, '(?m)^[0-9a-fA-F]{64}(?=\s)')).Value.ToLowerInvariant()
$actualArchiveDigest = (Get-FileHash -LiteralPath $CandidateArchive -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-That ($expectedArchiveDigest.Length -eq 64 -and $actualArchiveDigest -eq $expectedArchiveDigest) "checksum-pinned candidate archive is exact" "expected=$expectedArchiveDigest actual=$actualArchiveDigest"

$tempLeaf = "sync-claude-skills-to-codex-" + [guid]::NewGuid().ToString("N")
$temp = if ([System.OperatingSystem]::IsWindows()) { "\\wsl.localhost\Ubuntu\tmp\$tempLeaf" } else { Join-Path ([System.IO.Path]::GetTempPath()) $tempLeaf }
$oldHome = $env:PRO_GATE_HOME
$oldOracle = $env:ORACLE_DIR
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $sourceRepository = Join-Path $temp "source-repository"
    $sourceSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $sourceRepository
    $runtimeHome = Join-Path $temp "pro-gate-home"
    $env:PRO_GATE_HOME = $runtimeHome
    $env:ORACLE_DIR = Join-Path $temp "oracle"
    $version = (Get-Content -LiteralPath (Join-Path $sourceRepository ".claude-plugin/plugin.json") -Raw | ConvertFrom-Json).version
    Install-CandidateRuntime -Installer (Join-Path $ProGateRepositoryRoot "install.sh") -Version $version -Archive $CandidateArchive -Checksum $CandidateChecksum -RuntimeHome $runtimeHome -OracleHome $env:ORACLE_DIR
    Assert-That (Test-Path -LiteralPath (Join-Path $runtimeHome "review-decision-v1.json")) "candidate archive installs an actual runtime identity"
    Assert-That ((Get-Content -LiteralPath $fixture -Raw) -ceq (Get-Content -LiteralPath (Join-Path $runtimeHome "review-decision-v1.json") -Raw)) "candidate runtime identity equals pinned fixture"

    $codexRoot = if ([System.OperatingSystem]::IsWindows()) { Join-Path ([System.IO.Path]::GetTempPath()) ("codex-skills-" + [guid]::NewGuid().ToString("N")) } else { Join-Path $temp "codex-skills" }
    $baseArguments = @(
        "-ProGateSourceRoot", $sourceSkill,
        "-CodexSkillsRoot", $codexRoot,
        "-ProGateHome", $runtimeHome,
        "-ExpectedIdentityPath", $fixture,
        "-SkipAuxiliarySkills",
        "-SkipCommandLink"
    )

    if ([System.OperatingSystem]::IsWindows() -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $wrapperCodexRoot = Join-Path $temp "wrapper-codex-skills"
        New-Item -ItemType Directory -Force -Path $wrapperCodexRoot | Out-Null
        $wrapperDestination = Join-Path $wrapperCodexRoot "pro-gate"
        $wrapperArguments = @(
            "-ProGateSourceRoot", (Get-WslPathForTest $sourceSkill),
            "-CodexSkillsRoot", (Get-WslPathForTest $wrapperCodexRoot),
            "-ProGateHome", (Get-WslPathForTest $runtimeHome),
            "-ExpectedIdentityPath", (Get-WslPathForTest $fixture),
            "-SkipAuxiliarySkills",
            "-SkipCommandLink",
            "-Check"
        )
        $wrapperCheck = Invoke-WslWrapper $wrapperArguments
        Assert-That ($wrapperCheck.ExitCode -ne 0 -and $wrapperCheck.Output -match 'validated' -and $wrapperCheck.Output -match 'missing' -and -not (Test-Path -LiteralPath $wrapperDestination)) "WSL wrapper check accepts injected roots and remains mutation-free" $wrapperCheck.Output
    }

    $beforeCheck = Invoke-Bridge ($baseArguments + "-Check")
    Assert-That ($beforeCheck.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $codexRoot)) "missing mount check is mutation-free" $beforeCheck.Output

    $mount = Invoke-Bridge $baseArguments
    $destination = Join-Path $codexRoot "pro-gate"
    $destinationItem = if (Test-Path -LiteralPath $destination) { Get-Item -LiteralPath $destination -Force } else { $null }
    Assert-That ($mount.ExitCode -eq 0 -and $destinationItem -and $destinationItem.LinkType) "repository pro-gate skill is linked without a cache copy" $mount.Output
    if (-not $destinationItem) { throw "Initial bridge mount failed: $($mount.Output)" }
    $target = [string]($destinationItem.Target | Select-Object -First 1)
    Assert-That ($target -match 'skills[/\\]pro-gate$' -and $target -notmatch '[\\/]\.claude[\\/]skills[\\/]pro-gate$') "link source is repository skills/pro-gate" "target=$target"

    $readyCheck = Invoke-Bridge ($baseArguments + "-Check")
    Assert-That ($readyCheck.ExitCode -eq 0 -and $readyCheck.Output -match 'validated' -and $readyCheck.Output -match 'unchanged') "ready check reads and reports without copying" $readyCheck.Output

    $installedLib = Join-Path $runtimeHome "lib.sh"
    $installedLibOriginal = Get-Content -LiteralPath $installedLib -Raw
    foreach ($case in @(
        @{ Name = "contract id"; Pattern = "(?m)^PG_REVIEW_DECISION_CONTRACT_ID='[^']*'$"; Replacement = "PG_REVIEW_DECISION_CONTRACT_ID='review-decision/v999'"; ExpectedDiagnostic = "PGC006" },
        @{ Name = "contract version"; Pattern = '(?m)^PG_REVIEW_DECISION_CONTRACT_VERSION=[0-9]+$'; Replacement = "PG_REVIEW_DECISION_CONTRACT_VERSION=999"; ExpectedDiagnostic = "PGC006" },
        @{ Name = "contract digest"; Pattern = "(?m)^PG_REVIEW_DECISION_CONTRACT_DIGEST='[0-9a-f]{64}'$"; Replacement = "PG_REVIEW_DECISION_CONTRACT_DIGEST='0000000000000000000000000000000000000000000000000000000000000000'"; ExpectedDiagnostic = "PGC006" },
        @{ Name = "corpus digest"; Pattern = "(?m)^PG_REVIEW_DECISION_CORPUS_DIGEST='[0-9a-f]{64}'$"; Replacement = "PG_REVIEW_DECISION_CORPUS_DIGEST='0000000000000000000000000000000000000000000000000000000000000000'"; ExpectedDiagnostic = "PGC006" }
    )) {
        $mutatedLib = [regex]::Replace($installedLibOriginal, $case.Pattern, $case.Replacement, 1)
        Assert-That ($mutatedLib -ne $installedLibOriginal) "installed lib $($case.Name) mutation changes its assignment" "pattern=$($case.Pattern)"
        Set-Content -LiteralPath $installedLib -Value $mutatedLib -NoNewline
        $libraryResult = Invoke-Bridge ($baseArguments + "-Check")
        Assert-ValidationFailure -Name "installed lib $($case.Name) mismatch reports before destination status" -Result $libraryResult -ExpectedDiagnostic $case.ExpectedDiagnostic
        $currentDestination = Get-Item -LiteralPath $destination -Force
        $currentTarget = [string]($currentDestination.Target | Select-Object -First 1)
        Assert-That ($currentDestination.LinkType -and $currentTarget -eq $target) "installed lib $($case.Name) mismatch does not mutate the existing mount" $libraryResult.Output
        Set-Content -LiteralPath $installedLib -Value $installedLibOriginal -NoNewline
    }
    $convergedCheck = Invoke-Bridge ($baseArguments + "-Check")
    Assert-That ($convergedCheck.ExitCode -eq 0 -and $convergedCheck.Output -match 'validated' -and $convergedCheck.Output -match 'unchanged') "matching installed library succeeds after convergence" $convergedCheck.Output

    # The frozen corpus has one named choice and seven safe actions across all four classes.
    $actions = @(
        @{ action = "collect-existing-result"; class = "runtime-guarded-effect"; prompts = $false },
        @{ action = "recover-existing-review"; class = "runtime-guarded-effect"; prompts = $false },
        @{ action = "run-granted-review"; class = "runtime-guarded-effect"; prompts = $false },
        @{ action = "fix-review-findings"; class = "agent-task"; prompts = $false },
        @{ action = "prepare-matching-review-evidence"; class = "agent-task"; prompts = $false },
        @{ action = "stop-without-new-review"; class = "report-only"; prompts = $false },
        @{ action = "allow-existing-merge-workflow"; class = "report-only"; prompts = $false },
        @{ action = "ask-named-product-choice"; class = "named-product-choice"; prompts = $true }
    )
    $skillText = Get-Content -LiteralPath (Join-Path $sourceSkill "SKILL.md") -Raw
    Assert-That ($actions.Count -eq 8 -and (@($actions.class | Sort-Object -Unique).Count -eq 4)) "canonical corpus covers all 8 actions and 4 execution classes"
    Assert-That ((@($actions | Where-Object { -not $_.prompts }).Count -eq 7) -and (@($actions | Where-Object { $_.prompts }).action -eq "ask-named-product-choice")) "safe classes are prompt-free and named choice is the only prompt"
    Assert-That (($actions | ForEach-Object { $skillText.Contains($_.action) } | Where-Object { -not $_ }).Count -eq 0) "mounted skill preserves every canonical action"
    Assert-That ($skillText.Contains("prepare-matching-review-evidence") -and $skillText.Contains("re-enters after code or policy change")) "agent task re-entry remains typed"
    Assert-That ($skillText.Contains("allow-existing-merge-workflow") -and $skillText.Contains("Pro-gate has no merge authority") -and $skillText.Contains("Stop before merge")) "report-only merge handoff grants no merge authority"
    Assert-That ($skillText -match 'Compound Engineering when available,\r?\nthen `codex exec`, then apply the edits directly in this session') "post-review Codex fixer fallback text is preserved"

    Remove-Item -LiteralPath $destination -Force
    New-Item -ItemType SymbolicLink -Path $destination -Target (Join-Path $ProGateRepositoryRoot "skills/pro-gate") | Out-Null
    $staleCheck = Invoke-Bridge ($baseArguments + "-Check")
    Assert-That ($staleCheck.ExitCode -ne 0 -and (Test-Path -LiteralPath $destination)) "stale managed mount is reported without relinking" $staleCheck.Output

    Remove-Item -LiteralPath $destination -Force
    New-Item -ItemType Directory -Path $destination | Out-Null
    Set-Content -LiteralPath (Join-Path $destination "operator-file") -Value "preserve" -NoNewline
    $unmanagedCheck = Invoke-Bridge ($baseArguments + "-Check")
    Assert-That ($unmanagedCheck.ExitCode -ne 0 -and (Get-Content -LiteralPath (Join-Path $destination "operator-file") -Raw) -eq "preserve") "unmanaged destination is preserved by check" $unmanagedCheck.Output

    $badMetadataRepository = Join-Path $temp "bad-metadata"
    $badMetadataSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $badMetadataRepository
    Set-Content -LiteralPath (Join-Path $badMetadataSkill "agents/openai.yaml") -Value "policy:`n  allow_implicit_invocation: true" -NoNewline
    $badMetadataRoot = Join-Path $temp "bad-metadata-destination"
    $badMetadataCheck = Invoke-Bridge @("-ProGateSourceRoot", $badMetadataSkill, "-CodexSkillsRoot", $badMetadataRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "malformed invoke-only metadata reports its validation failure" -Result $badMetadataCheck -ExpectedDiagnostic "PGC001"
    Assert-That (-not (Test-Path -LiteralPath $badMetadataRoot)) "malformed invoke-only metadata creates no destination root" $badMetadataCheck.Output

    foreach ($case in @(
        @{ Name = "unknown identity"; Replacement = '"contract_id":"review-decision/v999"'; ExpectedDiagnostic = "PGC002" },
        @{ Name = "corpus mismatch"; Replacement = '"corpus_digest":"0000000000000000000000000000000000000000000000000000000000000000"'; ExpectedDiagnostic = "PGC003" }
    )) {
        $caseRepository = Join-Path $temp ($case.Name -replace ' ', '-')
        $caseSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $caseRepository
        $identityPath = Join-Path $caseSkill "review-decision-v1.json"
        $identity = Get-Content -LiteralPath $identityPath -Raw
        if ($case.Name -eq "unknown identity") { $identity = $identity -replace '"contract_id":"review-decision/v1"', $case.Replacement }
        else { $identity = $identity -replace '"corpus_digest":"[0-9a-f]{64}"', $case.Replacement }
        Set-Content -LiteralPath $identityPath -Value $identity -NoNewline
        $caseRoot = Join-Path $temp ("destination-" + ($case.Name -replace ' ', '-'))
        $caseResult = Invoke-Bridge @("-ProGateSourceRoot", $caseSkill, "-CodexSkillsRoot", $caseRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
        Assert-ValidationFailure -Name "$($case.Name) reports its validation failure before destination status" -Result $caseResult -ExpectedDiagnostic $case.ExpectedDiagnostic
        Assert-That (-not (Test-Path -LiteralPath $caseRoot)) "$($case.Name) creates no destination root" $caseResult.Output
    }

    $malformedRepository = Join-Path $temp "malformed-identity"
    $malformedSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $malformedRepository
    Set-Content -LiteralPath (Join-Path $malformedSkill "review-decision-v1.json") -Value "{}" -NoNewline
    $malformedRoot = Join-Path $temp "malformed-identity-destination"
    $malformedResult = Invoke-Bridge @("-ProGateSourceRoot", $malformedSkill, "-CodexSkillsRoot", $malformedRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "malformed identity reports its validation failure before destination status" -Result $malformedResult -ExpectedDiagnostic "PGC002"
    Assert-That (-not (Test-Path -LiteralPath $malformedRoot)) "malformed identity creates no destination root" $malformedResult.Output

    $resolverRepository = Join-Path $temp "incomplete-resolver"
    $resolverSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $resolverRepository
    Set-Content -LiteralPath (Join-Path $resolverSkill "scripts/resolve-identity.sh") -Value "#!/usr/bin/env bash" -NoNewline
    $resolverRoot = Join-Path $temp "incomplete-resolver-destination"
    $resolverResult = Invoke-Bridge @("-ProGateSourceRoot", $resolverSkill, "-CodexSkillsRoot", $resolverRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "incomplete resolver reports its validation failure before destination status" -Result $resolverResult -ExpectedDiagnostic "PGC004"
    Assert-That (-not (Test-Path -LiteralPath $resolverRoot)) "incomplete resolver creates no destination root" $resolverResult.Output

    $badFixture = Join-Path $temp "fixture-digest-drift.json"
    $badFixtureText = (Get-Content -LiteralPath $fixture -Raw) -replace '"contract_digest":"[0-9a-f]{64}"', '"contract_digest":"0000000000000000000000000000000000000000000000000000000000000000"'
    Set-Content -LiteralPath $badFixture -Value $badFixtureText -NoNewline
    $fixtureDriftRoot = Join-Path $temp "fixture-drift"
    $fixtureDriftResult = Invoke-Bridge @("-ProGateSourceRoot", $sourceSkill, "-CodexSkillsRoot", $fixtureDriftRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $badFixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "fixture contract digest drift reports its validation failure before destination status" -Result $fixtureDriftResult -ExpectedDiagnostic "PGC003"
    Assert-That (-not (Test-Path -LiteralPath $fixtureDriftRoot)) "fixture contract digest drift creates no destination root" $fixtureDriftResult.Output

    $runtimeVersionPath = Join-Path $runtimeHome "VERSION"
    $runtimeVersion = Get-Content -LiteralPath $runtimeVersionPath -Raw
    Set-Content -LiteralPath $runtimeVersionPath -Value "999.0.0" -NoNewline
    $newerRoot = Join-Path $temp "runtime-newer"
    $newerResult = Invoke-Bridge @("-ProGateSourceRoot", $sourceSkill, "-CodexSkillsRoot", $newerRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "runtime-newer version reports its validation failure before destination status" -Result $newerResult -ExpectedDiagnostic "PGC005"
    Assert-That (-not (Test-Path -LiteralPath $newerRoot)) "runtime-newer version creates no destination root" $newerResult.Output
    Set-Content -LiteralPath $runtimeVersionPath -Value $runtimeVersion -NoNewline

    $adapterRepository = Join-Path $temp "adapter-newer"
    $adapterSkill = Copy-RepositorySkill -SourceRepository $ProGateRepositoryRoot -DestinationRepository $adapterRepository
    $manifestPath = Join-Path $adapterRepository ".claude-plugin/plugin.json"
    $manifestOriginal = Get-Content -LiteralPath $manifestPath -Raw
    $manifestText = [regex]::Replace($manifestOriginal, '(?m)("version"\s*:\s*")[0-9]+\.[0-9]+\.[0-9]+(")', '${1}999.0.0${2}', 1)
    Assert-That ($manifestText -ne $manifestOriginal -and $manifestText -match '"version"\s*:\s*"999\.0\.0"') "adapter-newer manifest mutation handles whitespace and changes the manifest"
    Set-Content -LiteralPath $manifestPath -Value $manifestText -NoNewline
    $adapterRoot = Join-Path $temp "adapter-newer-destination"
    $adapterResult = Invoke-Bridge @("-ProGateSourceRoot", $adapterSkill, "-CodexSkillsRoot", $adapterRoot, "-ProGateHome", $runtimeHome, "-ExpectedIdentityPath", $fixture, "-SkipAuxiliarySkills", "-SkipCommandLink", "-Check")
    Assert-ValidationFailure -Name "adapter-newer version reports its validation failure before destination status" -Result $adapterResult -ExpectedDiagnostic "PGC005"
    Assert-That (-not (Test-Path -LiteralPath $adapterRoot)) "adapter-newer version creates no destination root" $adapterResult.Output
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:PRO_GATE_HOME -ErrorAction SilentlyContinue } else { $env:PRO_GATE_HOME = $oldHome }
    if ($null -eq $oldOracle) { Remove-Item Env:ORACLE_DIR -ErrorAction SilentlyContinue } else { $env:ORACLE_DIR = $oldOracle }
    if ($codexRoot) { Remove-Item -LiteralPath $codexRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output "ALL PASS"
