<#
.SYNOPSIS
    Assert all fixed volumes have at least -MinPercent free. Toast on breach.

.DESCRIPTION
    Designed to run from a scheduled task. Exits non-zero on breach so the task
    history surfaces failures. Sends a toast notification to the interactive
    user.
#>
[CmdletBinding()]
param(
    [int]    $MinPercent = 20,
    [string[]] $IgnoreLetters = @()
)

$violations = @()
foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
    if ($IgnoreLetters -contains $v.DriveLetter) { continue }
    $pct = [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1)
    if ($pct -lt $MinPercent) {
        $violations += [PSCustomObject]@{
            Drive    = $v.DriveLetter
            Label    = $v.FileSystemLabel
            FreeGB   = [math]::Round($v.SizeRemaining / 1GB, 1)
            SizeGB   = [math]::Round($v.Size / 1GB, 1)
            Percent  = $pct
        }
    }
}

if ($violations.Count -eq 0) {
    Write-Host "OK: all volumes >= $MinPercent% free."
    exit 0
}

$msg = ($violations | ForEach-Object { "$($_.Drive): $($_.Percent)% ($($_.FreeGB)/$($_.SizeGB) GB)" }) -join "`n"
Write-Warning "Free-space violation:`n$msg"

try {
    [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
        [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $textNodes = $template.GetElementsByTagName('text')
    $textNodes.Item(0).AppendChild($template.CreateTextNode("Disk free-space below $MinPercent%")) | Out-Null
    $textNodes.Item(1).AppendChild($template.CreateTextNode($msg)) | Out-Null
    $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Assert-FreeSpace').Show($toast)
} catch {
    Write-Warning "Toast failed: $($_.Exception.Message)"
}

exit 1
