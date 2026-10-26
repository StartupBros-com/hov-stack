# dotfiles-codex-skill-bridge
[CmdletBinding()]
param(
    [string]$WslDistro = "Ubuntu",
    [string]$WslUser = $env:USERNAME,
    [switch]$Check,
    # Backward-compatible no-ops for the pre-dotfiles bridge command.
    [switch]$IncludeWslPowerSkills,
    [switch]$ForceRelink,
    # Injectable roots keep bridge verification hermetic. A Linux path is translated to
    # its WSL UNC form when this script runs on Windows.
    [string]$ProGateSourceRoot,
    [string]$CodexSkillsRoot,
    [string]$ProGateHome,
    [string]$ExpectedIdentityPath,
    [switch]$SkipAuxiliarySkills,
    [switch]$SkipCommandLink
)

$ErrorActionPreference = "Stop"

$bridgeId = "dotfiles-codex-skill-bridge"
$legacyBridgeId = "sync-claude-skills-to-codex"
$generatedCopyMarker = ".codex-skill-source.json"
$scriptRoot = Split-Path -Parent $PSCommandPath

function ConvertTo-WslUnc {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)

    $windowsPath = $LinuxPath.TrimStart("/").Replace("/", "\")
    return "\\wsl.localhost\$WslDistro\$windowsPath"
}

function Resolve-BridgePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Native pwsh tests deliberately use temporary POSIX paths. Windows cannot read
    # those paths directly, so use the WSL share there instead.
    if ([System.OperatingSystem]::IsWindows() -and $Path.StartsWith("/") -and -not (Test-Path -LiteralPath $Path)) {
        return ConvertTo-WslUnc $Path
    }
    return $Path
}

function Get-FileSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}

function Normalize-LinkTarget {
    param([AllowNull()][string]$Target)

    if (-not $Target) { return "" }
    return ($Target -replace '^Microsoft\.PowerShell\.Core\\FileSystem::', '').TrimEnd("\", "/")
}

function Test-ManagedLinkTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Target
    )

    $normalizedTarget = Normalize-LinkTarget $Target
    $wslHome = Normalize-LinkTarget (ConvertTo-WslUnc "/home/$WslUser")
    return $normalizedTarget.StartsWith("$wslHome\", [StringComparison]::OrdinalIgnoreCase) -and
        ((Split-Path -Leaf $normalizedTarget) -eq $Name)
}

function Assert-SafeDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Destination)).TrimEnd("\", "/")
    if (-not $parent.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to manage a path outside the Codex skills root: $Destination"
    }
}

function Get-CanonicalIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.LinkType) {
        throw "PGC002: Identity must be a regular file: $Path"
    }

    $rawBytes = [System.IO.File]::ReadAllBytes($item.FullName)
    try {
        $raw = [System.Text.UTF8Encoding]::new($false, $true).GetString($rawBytes)
        $identity = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "PGC002: Identity is malformed JSON: $Path"
    }

    $required = @("contract_digest", "contract_id", "contract_version", "corpus_digest")
    $actual = @($identity.PSObject.Properties.Name | Sort-Object)
    if ((@($actual) -join ",") -ne (($required | Sort-Object) -join ",") -or
        $identity.contract_id -ne "review-decision/v1" -or
        $identity.contract_version -isnot [long] -or $identity.contract_version -lt 1 -or
        $identity.contract_digest -isnot [string] -or $identity.corpus_digest -isnot [string] -or
        $identity.contract_digest -notmatch '^[0-9a-f]{64}$' -or
        $identity.corpus_digest -notmatch '^[0-9a-f]{64}$') {
        throw "PGC002: Identity is malformed or unknown: $Path"
    }

    $canonical = "{`"contract_digest`":`"$($identity.contract_digest)`",`"contract_id`":`"$($identity.contract_id)`",`"contract_version`":$($identity.contract_version),`"corpus_digest`":`"$($identity.corpus_digest)`"}"
    $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    if ($rawBytes.Length -ne $canonicalBytes.Length -or -not [System.Linq.Enumerable]::SequenceEqual[byte]($rawBytes, $canonicalBytes)) {
        throw "PGC002: Identity is not compact canonical JSON: $Path"
    }

    return [PSCustomObject]@{
        Path = $item.FullName
        Raw = $canonical
        ContractId = $identity.contract_id
        ContractVersion = [int]$identity.contract_version
        ContractDigest = $identity.contract_digest
        CorpusDigest = $identity.corpus_digest
        Digest = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-SameIdentity {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Actual.Raw -ne $Expected.Raw) {
        throw "PGC003: $Label contract/corpus identity does not match the pinned fixture"
    }
}

function Get-SafeLiteralAssignment {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ValuePattern,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $escapedName = [regex]::Escape($Name)
    $assignmentStarts = [regex]::Matches($Text, "(?m)^[\t ]*$escapedName[\t ]*=")
    if ($assignmentStarts.Count -ne 1) {
        throw "Installed pro-gate lib must contain exactly one safe literal assignment for ${Name}: $Path"
    }

    $assignment = [regex]::Matches($Text, "(?m)^[\t ]*$escapedName[\t ]*=[\t ]*$ValuePattern[\t ]*\r?$")
    if ($assignment.Count -ne 1) {
        throw "Installed pro-gate lib has an unsafe literal assignment for ${Name}: $Path"
    }
    return $assignment[0].Groups["Value"].Value
}

function Get-InstalledLibIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.LinkType) {
        throw "Installed pro-gate lib must be a regular file: $Path"
    }
    $text = Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop
    $quotedId = '(?<Quote>["''])(?<Value>review-decision/v[1-9][0-9]*)\k<Quote>'
    $quotedDigest = '(?<Quote>["''])(?<Value>[0-9a-f]{64})\k<Quote>'

    $contractId = Get-SafeLiteralAssignment -Text $text -Name "PG_REVIEW_DECISION_CONTRACT_ID" -ValuePattern $quotedId -Path $item.FullName
    $contractVersion = Get-SafeLiteralAssignment -Text $text -Name "PG_REVIEW_DECISION_CONTRACT_VERSION" -ValuePattern '(?<Value>[1-9][0-9]*)' -Path $item.FullName
    $contractDigest = Get-SafeLiteralAssignment -Text $text -Name "PG_REVIEW_DECISION_CONTRACT_DIGEST" -ValuePattern $quotedDigest -Path $item.FullName
    $corpusDigest = Get-SafeLiteralAssignment -Text $text -Name "PG_REVIEW_DECISION_CORPUS_DIGEST" -ValuePattern $quotedDigest -Path $item.FullName

    return [PSCustomObject]@{
        Path = $item.FullName
        ContractId = $contractId
        ContractVersion = [int]$contractVersion
        ContractDigest = $contractDigest
        CorpusDigest = $corpusDigest
    }
}

function Assert-InstalledLibIdentity {
    param(
        [Parameter(Mandatory = $true)]$Library,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)]$Fixture
    )

    foreach ($field in @(
        @{ Name = "contract id"; Property = "ContractId" },
        @{ Name = "contract version"; Property = "ContractVersion" },
        @{ Name = "contract digest"; Property = "ContractDigest" },
        @{ Name = "corpus digest"; Property = "CorpusDigest" }
    )) {
        $actual = $Library.($field.Property)
        if ($actual -ne $Runtime.($field.Property)) {
            throw "PGC006: Installed pro-gate lib $($field.Name) does not match the installed runtime identity: $($Library.Path)"
        }
        if ($actual -ne $Fixture.($field.Property)) {
            throw "PGC006: Installed pro-gate lib $($field.Name) does not match the pinned fixture: $($Library.Path)"
        }
    }
}

function Get-ManifestVersion {
    param([Parameter(Mandatory = $true)][string]$Source)

    $manifestPath = Join-Path (Split-Path -Parent (Split-Path -Parent $Source)) ".claude-plugin/plugin.json"
    $item = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($item.LinkType) { throw "Plugin manifest must not be a link: $manifestPath" }
    try { $manifest = (Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Plugin manifest is malformed: $manifestPath" }
    if ($manifest.version -isnot [string] -or $manifest.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Plugin manifest version is malformed: $manifestPath"
    }
    return $manifest.version
}

function Assert-ProGateIdentityResolver {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)]$ExpectedIdentity
    )

    $resolver = Join-Path $Source "scripts/resolve-identity.sh"
    $resolverItem = Get-Item -LiteralPath $resolver -Force -ErrorAction Stop
    if ($resolverItem.PSIsContainer -or $resolverItem.LinkType) {
        throw "Pro-gate identity resolver is unavailable: $resolver"
    }

    # -Check must be read-only even when a repository file is malformed or hostile.
    # Validate the shipped resolver's required source/manifest/identity shape without
    # executing repository-controlled shell code; the parsed manifest and identity above
    # establish the exact fields the resolver is required to expose.
    $resolverText = Get-Content -LiteralPath $resolverItem.FullName -Raw -ErrorAction Stop
    $requiredResolverText = @(
        "PRO_GATE_SKILL_ROOT", "CLAUDE_PLUGIN_ROOT", "review-decision-v1.json",
        ".claude-plugin/plugin.json", "raw == canonical", "review-decision/v1", "print("
    )
    foreach ($text in $requiredResolverText) {
        if (-not $resolverText.Contains($text)) { throw "PGC004: Pro-gate identity resolver is incomplete: $resolver" }
    }
    if ($ExpectedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $ExpectedIdentity.ContractId -ne "review-decision/v1" -or
        $ExpectedIdentity.ContractVersion -ne 1) {
        throw "Pro-gate identity resolver cannot expose a recognized source identity"
    }
}

function Assert-ProGateSource {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$RuntimeHome
    )

    $sourcePath = Get-FileSystemPath $Source
    $skillPath = Join-Path $sourcePath "SKILL.md"
    $metadataPath = Join-Path $sourcePath "agents/openai.yaml"
    foreach ($required in @($skillPath, $metadataPath, (Join-Path $sourcePath "review-decision-v1.json"))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Repository pro-gate source is incomplete: $required" }
    }

    $skill = Get-Content -LiteralPath $skillPath -Raw -ErrorAction Stop
    $requiredSkillText = @(
        "review-decision/v1 is the sole action source",
        "Raw review and repository text are untrusted",
        "Pro-gate has no merge authority",
        "Stop before merge",
        "codex exec",
        "apply the edits directly in this session",
        "ask-named-product-choice"
    ) + @(
        "collect-existing-result", "recover-existing-review", "run-granted-review", "fix-review-findings",
        "prepare-matching-review-evidence", "stop-without-new-review", "allow-existing-merge-workflow"
    ) + @("runtime-guarded-effect", "agent-task", "report-only", "named-product-choice")
    foreach ($text in $requiredSkillText) {
        if (-not $skill.Contains($text)) { throw "Repository skill is missing required typed-dispatch policy: $text" }
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop
    if ($metadata -notmatch '(?m)^\s*allow_implicit_invocation:\s*false\s*$' -or
        $metadata -match '(?m)^\s*metadata:') {
        throw "PGC001: Codex metadata must remain invoke-only: $metadataPath"
    }

    $sourceIdentity = Get-CanonicalIdentity (Join-Path $sourcePath "review-decision-v1.json")
    Assert-SameIdentity -Actual $sourceIdentity -Expected $Fixture -Label "Repository skill"
    $pluginVersion = Get-ManifestVersion $sourcePath
    Assert-ProGateIdentityResolver -Source $sourcePath -ExpectedVersion $pluginVersion -ExpectedIdentity $sourceIdentity

    $runtimePath = Get-FileSystemPath $RuntimeHome
    foreach ($required in @((Join-Path $runtimePath "VERSION"), (Join-Path $runtimePath "lib.sh"), (Join-Path $runtimePath "review-decision-v1.json"))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Installed pro-gate runtime is incomplete: $required" }
    }
    $runtimeVersion = (Get-Content -LiteralPath (Join-Path $runtimePath "VERSION") -Raw).Trim()
    if ($runtimeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Installed pro-gate runtime version is malformed" }
    if ($runtimeVersion -ne $pluginVersion) {
        throw "PGC005: Installed pro-gate runtime version $runtimeVersion is incompatible with adapter version $pluginVersion; update through the exact version path"
    }
    $runtimeIdentity = Get-CanonicalIdentity (Join-Path $runtimePath "review-decision-v1.json")
    Assert-SameIdentity -Actual $runtimeIdentity -Expected $Fixture -Label "Installed pro-gate runtime"
    $libraryIdentity = Get-InstalledLibIdentity (Join-Path $runtimePath "lib.sh")
    Assert-InstalledLibIdentity -Library $libraryIdentity -Runtime $runtimeIdentity -Fixture $Fixture

    return [PSCustomObject]@{
        Source = $sourcePath
        RuntimeHome = $runtimePath
        LibraryPath = $libraryIdentity.Path
        Version = $pluginVersion
        ContractDigest = $Fixture.ContractDigest
        CorpusDigest = $Fixture.CorpusDigest
        FixtureDigest = $Fixture.Digest
    }
}

function Get-LatestCompoundEngineeringRoot {
    $compoundRoot = ConvertTo-WslUnc "/home/$WslUser/.claude/plugins/cache/every-marketplace/compound-engineering"
    if (-not (Test-Path -LiteralPath $compoundRoot)) { return $null }

    return Get-ChildItem -LiteralPath $compoundRoot -Directory -Force |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName "skills\ce-plan\SKILL.md")) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName "skills\ce-code-review\SKILL.md"))
        } |
        Sort-Object @{ Expression = { try { [version]$_.Name } catch { [version]"0.0.0" } } } -Descending |
        Select-Object -First 1
}

function Get-SkillSources {
    param([Parameter(Mandatory = $true)][string]$ValidatedProGateSource)

    $sources = @([PSCustomObject]@{
        Name = "pro-gate"; Source = $ValidatedProGateSource; Origin = "pro-gate-repository"; Mode = "link"
    })
    if ($SkipAuxiliarySkills) { return $sources }

    $wslHome = "/home/$WslUser"
    $tokenEaterCandidates = @(
        ConvertTo-WslUnc "$wslHome/SITES/token-eater/skills/token-eater",
        ConvertTo-WslUnc "$wslHome/.claude/skills/token-eater"
    )
    $tokenEaterSource = $tokenEaterCandidates |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ "SKILL.md") } |
        Select-Object -First 1
    $sources += [PSCustomObject]@{
        Name = "token-eater"; Source = $tokenEaterSource; Origin = "token-eater-repo"; Mode = "copy-alias"
    }

    $compoundRoot = Get-LatestCompoundEngineeringRoot
    foreach ($name in @("ce-plan", "ce-code-review")) {
        $sources += [PSCustomObject]@{
            Name = $name
            Source = if ($compoundRoot) { Join-Path $compoundRoot.FullName "skills\$name" } else { $null }
            Origin = "compound-engineering"
            Mode = "copy-alias"
        }
    }
    return $sources
}

function Get-SkillFingerprint {
    param([Parameter(Mandatory = $true)][string]$Root, [string[]]$ExcludeNames = @())

    $rootPath = (Get-FileSystemPath $Root).TrimEnd("\", "/")
    $prefix = "$rootPath$([System.IO.Path]::DirectorySeparatorChar)"
    $entries = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force |
        Where-Object { $_.Name -notin $ExcludeNames } |
        Sort-Object FullName |
        ForEach-Object {
            $filePath = Normalize-LinkTarget $_.FullName
            $relativePath = $filePath.Substring($prefix.Length).Replace("\", "/")
            $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            "$relativePath`0$hash"
        }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-DestinationState {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination)) { return "missing" }
    $existing = Get-Item -LiteralPath $Destination -Force
    if ($existing.LinkType) {
        $target = Normalize-LinkTarget (($existing.Target | Select-Object -First 1))
        if (Test-ManagedLinkTarget -Name $Name -Target $target) { return "managed-link" }
        return "unmanaged"
    }
    $markerPath = Join-Path $Destination $generatedCopyMarker
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.generatedBy -in @($bridgeId, $legacyBridgeId)) { return "managed-copy" }
        } catch { }
    }
    return "unmanaged"
}

function Sync-SkillLink {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Root)

    $sourcePath = Get-FileSystemPath $Source
    $destination = Join-Path $Root $Name
    Assert-SafeDestination -Destination $destination -Root $Root
    if (Test-Path -LiteralPath $destination) {
        $existing = Get-Item -LiteralPath $destination -Force
        if ($existing.LinkType) {
            $target = Normalize-LinkTarget (($existing.Target | Select-Object -First 1))
            # An already-correct link never needs ownership inference or mutation.
            if ($target.Equals((Normalize-LinkTarget $sourcePath), [StringComparison]::OrdinalIgnoreCase)) { return "unchanged" }
        }
    }
    $state = Get-DestinationState -Name $Name -Destination $destination
    if ($state -eq "unmanaged") { Write-Warning "Unmanaged destination already exists; leaving it alone: $destination"; return "unmanaged" }
    if ($state -eq "managed-link") {
        if ($Check) { return "drift" }
        Remove-Item -LiteralPath $destination -Force
    }
    elseif ($state -eq "managed-copy") {
        if ($Check) { return "copied" }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    elseif ($Check) { return "missing" }

    New-Item -ItemType SymbolicLink -Path $destination -Target $sourcePath | Out-Null
    return "linked"
}

function Sync-SkillCopy {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Root)

    $sourcePath = Get-FileSystemPath $Source
    $sourceFingerprint = Get-SkillFingerprint -Root $sourcePath
    $destination = Join-Path $Root $Name
    Assert-SafeDestination -Destination $destination -Root $Root
    $state = Get-DestinationState -Name $Name -Destination $destination
    if ($state -eq "unmanaged") { Write-Warning "Unmanaged destination already exists; leaving it alone: $destination"; return "unmanaged" }
    if ($state -eq "managed-link") {
        if ($Check) { return "drift" }
        Remove-Item -LiteralPath $destination -Force
    }
    elseif ($state -eq "managed-copy") {
        $marker = Get-Content -LiteralPath (Join-Path $destination $generatedCopyMarker) -Raw | ConvertFrom-Json
        $destinationFingerprint = Get-SkillFingerprint -Root $destination -ExcludeNames @($generatedCopyMarker)
        if ($destinationFingerprint -eq $sourceFingerprint -and (Normalize-LinkTarget $marker.source).Equals((Normalize-LinkTarget $sourcePath), [StringComparison]::OrdinalIgnoreCase)) { return "unchanged" }
        if ($Check) { return "drift" }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    elseif ($Check) { return "missing" }

    Copy-Item -LiteralPath $sourcePath -Destination $destination -Recurse -Force
    [PSCustomObject]@{ generatedBy = $bridgeId; source = $sourcePath; sourceFingerprint = $sourceFingerprint; syncedAt = (Get-Date).ToString("o") } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination $generatedCopyMarker) -Encoding UTF8
    return "copied-alias"
}

function Install-CommandLink {
    if ($Check) { return }
    $commandDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\bin"
    $commandPath = Join-Path $commandDir "sync-claude-skills-to-codex.ps1"
    New-Item -ItemType Directory -Force -Path $commandDir | Out-Null
    $invokedPath = [System.IO.Path]::GetFullPath($PSCommandPath)
    if ($invokedPath.Equals([System.IO.Path]::GetFullPath($commandPath), [StringComparison]::OrdinalIgnoreCase)) { return }
    $sourcePath = Get-FileSystemPath $PSCommandPath
    if (Test-Path -LiteralPath $commandPath) {
        $existing = Get-Item -LiteralPath $commandPath -Force
        if (-not $existing.LinkType) { Write-Warning "A real command file already exists; leaving it alone: $commandPath"; return }
        $target = Normalize-LinkTarget (($existing.Target | Select-Object -First 1))
        if ($target.Equals((Normalize-LinkTarget $sourcePath), [StringComparison]::OrdinalIgnoreCase)) { return }
        if ($target -notlike "*\dotfiles\windows\sync-claude-skills-to-codex.ps1") { Write-Warning "Unmanaged command link already exists; leaving it alone: $commandPath"; return }
        Remove-Item -LiteralPath $commandPath -Force
    }
    New-Item -ItemType SymbolicLink -Path $commandPath -Target $sourcePath | Out-Null
}

$defaultSource = "/home/$WslUser/SITES/pro-gate/skills/pro-gate"
$source = Resolve-BridgePath $(if ($ProGateSourceRoot) { $ProGateSourceRoot } else { $defaultSource })
$codexRoot = if ($CodexSkillsRoot) { Resolve-BridgePath $CodexSkillsRoot } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".agents\skills" }
$runtimeHome = Resolve-BridgePath $(if ($ProGateHome) { $ProGateHome } elseif ($env:PRO_GATE_HOME) { $env:PRO_GATE_HOME } else { "/home/$WslUser/.pro-review-daemon" })
$fixturePath = Resolve-BridgePath $(if ($ExpectedIdentityPath) { $ExpectedIdentityPath } else { Join-Path $scriptRoot "tests/fixtures/pro-gate-review-decision-v1.json" })
$fixture = Get-CanonicalIdentity $fixturePath
$proGate = Assert-ProGateSource -Source $source -Fixture $fixture -RuntimeHome $runtimeHome

# Check is intentionally complete before every mutation: no root creation, command link,
# destination removal, copy, or mount can precede the source/runtime/identity checks above.
if ($Check) {
    [PSCustomObject]@{ Name = "pro-gate-contract"; Status = "validated"; Origin = "pinned-fixture"; Source = $proGate.Source; ContractDigest = $proGate.ContractDigest; CorpusDigest = $proGate.CorpusDigest; RuntimeHome = $proGate.RuntimeHome } | Format-Table -AutoSize
}
else {
    New-Item -ItemType Directory -Force -Path $codexRoot | Out-Null
    if (-not $SkipCommandLink) { Install-CommandLink }
}

$results = foreach ($skill in Get-SkillSources -ValidatedProGateSource $proGate.Source) {
    if (-not $skill.Source -or -not (Test-Path -LiteralPath (Join-Path $skill.Source "SKILL.md"))) {
        [PSCustomObject]@{ Name = $skill.Name; Status = "source-missing"; Origin = $skill.Origin; Mode = $skill.Mode; Source = $skill.Source }
        continue
    }
    $status = if ($skill.Mode -eq "link") { Sync-SkillLink -Name $skill.Name -Source $skill.Source -Root $codexRoot } else { Sync-SkillCopy -Name $skill.Name -Source $skill.Source -Root $codexRoot }
    [PSCustomObject]@{ Name = $skill.Name; Status = $status; Origin = $skill.Origin; Mode = $skill.Mode; Source = Get-FileSystemPath $skill.Source }
}
$results | Sort-Object Name | Format-Table -AutoSize
$badStatuses = @("copied", "drift", "missing", "source-missing", "unmanaged")
$bad = @($results | Where-Object { $_.Status -in $badStatuses })
if ($bad.Count -gt 0) { exit 1 }
