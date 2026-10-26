<#
.SYNOPSIS
    Idempotently establish the desired disk layout.

.DESCRIPTION
    Currently scope:
      - Phase 2a: Carve scratch partition S: from unallocated space on the selected disk.

    Designed to run multiple times safely. If the desired state is already
    present, the script reports SKIP and exits without touching disks.

    DESTRUCTIVE actions are gated:
      - We never resize, delete, or relocate existing partitions.
      - We only ADD a new partition in unallocated space.
      - Pass ExpectedDiskSerial to verify the selected disk before changing it;
        the template has no machine-specific serial number.

.PARAMETER DryRun
    Show what would change. Apply nothing.

.PARAMETER ScratchLetter
    Drive letter for the scratch volume. Default S.

.PARAMETER ScratchLabel
    Volume label. Default 'Scratch'.

.PARAMETER ExpectedDiskSerial
    Safety: assert the target disk's serial number matches. If empty, no check.
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [char]   $ScratchLetter = 'S',
    [string] $ScratchLabel  = 'Scratch',
    [int]    $TargetDiskNumber = 1,
    [string] $ExpectedDiskSerial = ''
)

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin
$script:DryRun = [bool]$DryRun

# --- Snapshot before changes -------------------------------------------------

$snapDir = New-Snapshot -Tag 'pre-disklayout'
Get-Disk        | Select-Object Number,FriendlyName,SerialNumber,Size,AllocatedSize,PartitionStyle | ConvertTo-Json -Depth 4 | Out-File "$snapDir\disks.json"      -Encoding UTF8
Get-Partition   | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,GptType,Offset,Size     | ConvertTo-Json -Depth 4 | Out-File "$snapDir\partitions.json" -Encoding UTF8
Get-Volume      | Select-Object DriveLetter,FileSystemLabel,FileSystem,Size,SizeRemaining,DriveType | ConvertTo-Json -Depth 4 | Out-File "$snapDir\volumes.json"    -Encoding UTF8
Write-Step "Pre-change snapshot saved to $snapDir" 'OK'

# --- Safety: identify target disk by serial ---------------------------------

$disk = Get-Disk -Number $TargetDiskNumber -ErrorAction Stop
if ($ExpectedDiskSerial) {
    $actual = $disk.SerialNumber.Trim()
    $expect = $ExpectedDiskSerial.Trim()
    if ($actual -ne $expect) {
        throw "Disk $TargetDiskNumber serial '$actual' does not match expected '$expect'. Aborting to avoid touching the wrong drive."
    }
    Write-Step "Disk $TargetDiskNumber serial matches expected ($actual)" 'OK'
}

# --- Idempotent target state check ------------------------------------------

$existing = Get-Volume -DriveLetter $ScratchLetter -ErrorAction SilentlyContinue
if ($existing) {
    $existingPart = Get-Partition -DriveLetter $ScratchLetter -ErrorAction SilentlyContinue
    if ($existingPart -and $existingPart.DiskNumber -eq $TargetDiskNumber -and $existing.FileSystemLabel -eq $ScratchLabel) {
        Write-Step "${ScratchLetter}: already present on Disk $TargetDiskNumber, label '$ScratchLabel' -> nothing to do" 'SKIP'
        return
    }
    throw "Drive letter ${ScratchLetter}: already exists but does not match desired (disk=$($existingPart.DiskNumber), label=$($existing.FileSystemLabel)). Refusing to touch it."
}

# --- Verify unallocated space -----------------------------------------------

$unallocBytes = $disk.Size - $disk.AllocatedSize
$unallocGB    = [math]::Round($unallocBytes / 1GB, 2)
if ($unallocBytes -lt 10GB) {
    throw "Disk $TargetDiskNumber has only $unallocGB GB unallocated. Refusing to create scratch partition this small."
}
Write-Step "Disk $TargetDiskNumber has $unallocGB GB unallocated -> will use as scratch" 'OK'

# --- Apply ------------------------------------------------------------------

if ($script:DryRun) {
    Write-Step "WOULD CREATE: New-Partition -DiskNumber $TargetDiskNumber -UseMaximumSize -DriveLetter $ScratchLetter" 'CHANGE'
    Write-Step "WOULD FORMAT: NTFS, label='$ScratchLabel', AllocationUnitSize 4K (default)" 'CHANGE'
    return
}

Write-Step "Creating partition on Disk $TargetDiskNumber (UseMaximumSize, drive letter $ScratchLetter)" 'CHANGE'
$newPart = New-Partition `
    -DiskNumber $TargetDiskNumber `
    -UseMaximumSize `
    -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' `
    -DriveLetter $ScratchLetter

Write-Step "Formatting ${ScratchLetter}: NTFS, label '$ScratchLabel'" 'CHANGE'
$newVol = Format-Volume `
    -DriveLetter $ScratchLetter `
    -FileSystem NTFS `
    -NewFileSystemLabel $ScratchLabel `
    -Confirm:$false `
    -Force

# --- Verify ------------------------------------------------------------------

$post = Get-Volume -DriveLetter $ScratchLetter
Write-Step "POST STATE" 'OK'
Write-Host ("  Drive       : {0}:" -f $post.DriveLetter)
Write-Host ("  Label       : {0}"  -f $post.FileSystemLabel)
Write-Host ("  Filesystem  : {0}"  -f $post.FileSystem)
Write-Host ("  Size        : {0} GB" -f [math]::Round($post.Size / 1GB, 2))
Write-Host ("  Free        : {0} GB" -f [math]::Round($post.SizeRemaining / 1GB, 2))
