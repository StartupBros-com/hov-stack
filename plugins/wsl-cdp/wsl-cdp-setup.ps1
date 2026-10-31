# wsl-cdp-setup.ps1 — one-time elevated Windows half of the wsl-cdp bridge.
# Idempotent by delete-then-add: run it twice, get one rule.
#
# What it does (and nothing else):
#   1. Deletes ANY stale portproxy rule listening on $ProxyPort or $BrowserPort.
#      Stale rules are the #1 documented failure mode: a leftover rule on
#      127.0.0.1:$BrowserPort grabs the port before the browser binds it,
#      pushing the browser to [::1] and looping IPv4 traffic into empty replies.
#   2. Adds: v4tov4 listen 0.0.0.0:$ProxyPort -> 127.0.0.1:$BrowserPort.
#      (0.0.0.0 so the rule survives vEthernet IP churn across reboots; LAN
#      exposure is closed by the firewall scope below, and the browser itself
#      only ever listens on loopback.)
#   3. Recreates one inbound firewall rule for $ProxyPort scoped to $RemoteCidr
#      (default = the WSL NAT range). Nothing is opened to the LAN.
#   4. Creates the agent-profile directory ($HOME\.wsl-cdp\profile).
param(
  [int]$ProxyPort = 9224,
  [int]$BrowserPort = 9223,
  [string]$RemoteCidr = "172.16.0.0/12"
)
$ErrorActionPreference = "Stop"

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
    '-ProxyPort',$ProxyPort,'-BrowserPort',$BrowserPort,'-RemoteCidr',$RemoteCidr)
  exit
}

# Port-scoped so a second bridge (different WSL_CDP_PROXY_PORT) gets its OWN
# firewall rule instead of the remove-then-add below silently deleting the
# first bridge's rule.
$RuleName = "wsl-cdp bridge ($ProxyPort)"

# 1. stale-rule sweep (both ports, any listen address)
$lines = netsh interface portproxy show v4tov4 | Select-String "^\s*(\S+)\s+($ProxyPort|$BrowserPort)\s+\S+\s+\S+"
foreach ($m in $lines) {
  $addr = $m.Matches[0].Groups[1].Value
  $port = $m.Matches[0].Groups[2].Value
  netsh interface portproxy delete v4tov4 listenport=$port listenaddress=$addr | Out-Null
  Write-Host "deleted stale portproxy rule ${addr}:${port}"
}

# 2. the one rule
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$ProxyPort connectaddress=127.0.0.1 connectport=$BrowserPort | Out-Null
Write-Host "portproxy: 0.0.0.0:$ProxyPort -> 127.0.0.1:$BrowserPort"

# 3. firewall (remove-then-add keeps the count at exactly 1)
Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP `
  -LocalPort $ProxyPort -RemoteAddress $RemoteCidr -Action Allow | Out-Null
Write-Host "firewall: inbound TCP $ProxyPort allowed from $RemoteCidr only"

# 4. agent profile home
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.wsl-cdp\profile" | Out-Null

$proxyCount = (netsh interface portproxy show v4tov4 | Select-String "\s$ProxyPort\s+127\.0\.0\.1").Count
$fwCount = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue).Count
Write-Host ""
Write-Host "verify: portproxy rules for ${ProxyPort}: $proxyCount (want 1) | firewall rules: $fwCount (want 1)"
Write-Host "next (in WSL): wsl-cdp up"
Read-Host "Press Enter to close"
