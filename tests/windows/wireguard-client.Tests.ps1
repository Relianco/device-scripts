$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wireguard-client/Invoke-WireGuardClient.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/wireguard-client.json'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Pins: release record and inlined defaults agree.
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ($InstallerUrl -cne [string]$release.x64.sourceUrl -or $InstallerSha256 -cne [string]$release.x64.sha256) { Fail 'x64 pin differs from release json' }
if ($ArmInstallerUrl -cne [string]$release.arm64.sourceUrl -or $ArmInstallerSha256 -cne [string]$release.arm64.sha256) { Fail 'arm64 pin differs from release json' }
if (-not (Test-WgcPinHash -Sha256 $InstallerSha256) -or (Test-WgcPinHash -Sha256 ('0' * 64))) { Fail 'pin hash check' }
if ((Get-Content -LiteralPath $scriptPath -Raw) -match 'Mandatory\s*=') { Fail 'a parameter is Mandatory' }

# Validation.
# Synthetic keys built from byte runs, so no key-shaped literal sits in the repo.
$serverKey = [Convert]::ToBase64String([byte[]](0..31))
$devKey = [Convert]::ToBase64String([byte[]](32..1))
$devPub = [Convert]::ToBase64String([byte[]](40..9))
if (-not (Test-WgcKey -Key $serverKey)) { Fail 'valid key rejected' }
if (Test-WgcKey -Key 'abc=') { Fail 'short key accepted' }
foreach ($bad in @('Office', 'a b', '', ('x' * 40))) { if (Test-WgcTunnelName -Name $bad) { Fail "tunnel name $bad accepted" } }
if (-not (Test-WgcIpv4Cidr -Cidr '192.0.2.10/32') -or (Test-WgcIpv4Cidr -Cidr '192.0.2.300/32') -or (Test-WgcIpv4Cidr -Cidr '192.0.2.1/33')) { Fail 'cidr check' }
if (-not (Test-WgcEndpoint -Endpoint '198.51.100.7:51820') -or (Test-WgcEndpoint -Endpoint '198.51.100.7') -or (Test-WgcEndpoint -Endpoint 'h:70000')) { Fail 'endpoint check' }

function New-Settings {
    param([hashtable]$Over = @{})
    $s = [ordered]@{
        TunnelName = 'office'; Address = '10.99.10.10/32'; ServerPublicKey = $serverKey; Endpoint = '198.51.100.7:51820'
        AllowedIPs = '192.0.2.0/24, 203.0.113.4/32'; PersistentKeepalive = '25'
        NrptNamespaces = '.corp.example.invalid,files.example.invalid'; NrptServers = '192.0.2.5,203.0.113.4'
        DisableGsaPrivateAccess = 'false'
    }
    foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
    return [pscustomobject]$s
}
if ((Get-WgcSettingsErrors -Settings (New-Settings)).Count -ne 0) { Fail 'good settings rejected' }
if ((Get-WgcSettingsErrors -Settings (New-Settings @{ AllowedIPs = '0.0.0.0/0' })).Count -eq 0) { Fail 'full tunnel accepted' }
if ((Get-WgcSettingsErrors -Settings (New-Settings @{ NrptServers = '' })).Count -eq 0) { Fail 'namespaces without servers accepted' }
if ((Get-WgcSettingsErrors -Settings (New-Settings @{ DisableGsaPrivateAccess = 'yes' })).Count -eq 0) { Fail 'bad bool accepted' }

# Config text: no DNS line, keys in place, key read back.
$text = Get-WgcConfigText -PrivateKey $devKey -Settings (New-Settings)
if ($text -match '(?m)^DNS') { Fail 'config has a DNS line' }
if ($text -notmatch [regex]::Escape("AllowedIPs = 192.0.2.0/24, 203.0.113.4/32")) { Fail 'AllowedIPs line' }
if ((Get-WgcPrivateKeyFromConfig -Text $text) -cne $devKey) { Fail 'private key not read back' }
if ((Get-WgcPrivateKeyFromConfig -Text "PrivateKey = nope") -ne '') { Fail 'bad key read back' }

# NRPT plan: foreign rules untouched, matching tagged rule kept, stale tagged rule removed.
$tag = 'Relian WireGuard client: office'
$existing = @(
    [pscustomobject]@{ Name = 'a'; Namespace = @('.corp.example.invalid'); NameServers = @('192.0.2.5', '203.0.113.4'); Comment = $tag },
    [pscustomobject]@{ Name = 'b'; Namespace = @('.old.example.invalid'); NameServers = @('192.0.2.5'); Comment = $tag },
    [pscustomobject]@{ Name = 'c'; Namespace = @('.corp.example.invalid'); NameServers = @('6.6.0.1'); Comment = 'someone else' }
)
$plan = Get-WgcNrptPlan -Existing $existing -Namespaces @('.corp.example.invalid', 'files.example.invalid') -Servers @('192.0.2.5', '203.0.113.4') -Tag $tag
if (@($plan.Remove).Count -ne 1 -or $plan.Remove[0].Name -cne 'b') { Fail 'nrpt remove plan' }
if (@($plan.Add).Count -ne 1 -or $plan.Add[0] -cne 'files.example.invalid') { Fail 'nrpt add plan' }
$plan = Get-WgcNrptPlan -Existing $existing -Namespaces @() -Servers @() -Tag $tag
if (@($plan.Remove).Count -ne 2 -or @($plan.Remove | Where-Object Name -ceq 'c').Count -ne 0) { Fail 'uninstall nrpt plan' }

# Install flow with every side effect mocked.
$state = [ordered]@{ Installed = ''; Msi = 0; Config = ''; Written = 0; Service = $null; Restarts = 0; Folder = 0; Rules = [System.Collections.Generic.List[object]]::new(); Gsa = 0; FolderBeforeWrite = $true }
$script:GetArch = { 'AMD64' }
$script:GetInstalledVersion = { $state.Installed }
$script:DownloadFile = { param($Url, $Destination) Set-Content -LiteralPath $Destination -Value 'msi' }
$script:GetFileSha256 = { param($Path) $InstallerSha256 }
$script:InvokeMsiExec = { param($InstallerPath) $state.Msi++; $state.Installed = '1.1.1'; 0 }
$script:InvokeWg = {
    param([string[]]$Arguments, [string]$StdIn = '')
    switch ($Arguments[0]) {
        'genkey' { return $devKey }
        'pubkey' { if ($StdIn -cne $devKey) { throw 'pubkey got the wrong key' }; return $devPub }
        default { return "$serverKey`t0" }
    }
}
$script:EnsureSecureFolder = { param($Path) $state.Folder++ }
$script:ReadConfig = { param($Path) $state.Config }
$script:WriteConfig = { param($Path, $Text) if ($state.Folder -eq 0) { $state.FolderBeforeWrite = $false }; $state.Config = $Text; $state.Written++ }
$script:GetService = { param($Name) $state.Service }
$script:InstallTunnelService = { param($ConfigPath) $state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Running'; StartType = 'Automatic' }; 0 }
$script:UninstallTunnelService = { param($TunnelName) $state.Service = $null; 0 }
$script:RestartService = { param($Name) $state.Restarts++ }
$script:GetNrptRules = { @($state.Rules) }
$script:AddNrptRule = { param($Namespace, [string[]]$Servers, $Comment) $state.Rules.Add([pscustomobject]@{ Name = [guid]::NewGuid().ToString(); Namespace = @($Namespace); NameServers = $Servers; Comment = $Comment }) }
$script:RemoveNrptRule = { param($Rule) [void]$state.Rules.Remove($Rule) }
$script:SetGsaPrivateAccess = { param([bool]$Disabled) if ($Disabled) { $state.Gsa = 1 } else { $state.Gsa = 0 }; 1 }
$script:GetLatestHandshake = { param($TunnelName) $null }

$pins = [pscustomobject]@{ Url = $InstallerUrl; Sha256 = $InstallerSha256; ArmUrl = $ArmInstallerUrl; ArmSha256 = $ArmInstallerSha256 }
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings @{ DisableGsaPrivateAccess = 'true' }) -Pins $pins
if ($out.ExitCode -ne 0) { Fail ("install exit $($out.ExitCode): " + ($script:WgcErrors -join '; ')) }
if ($state.Msi -ne 1 -or $state.Written -ne 1 -or $null -eq $state.Service -or $state.Gsa -ne 1) { Fail 'install did not converge' }
if (-not $state.FolderBeforeWrite) { Fail 'config written before the folder ACL' }
if ($state.Rules.Count -ne 2) { Fail 'nrpt rules not added' }
$json = $out.Report | ConvertTo-Json -Compress -Depth 4
if ($json.Contains($devKey)) { Fail 'private key in the report' }
if ($out.Report.publicKey -cne $devPub) { Fail 'public key missing from the report' }

# Second run: same key, nothing rewritten, no restart, no duplicate rules.
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings @{ DisableGsaPrivateAccess = 'true' }) -Pins $pins
if ($out.ExitCode -ne 0 -or $state.Msi -ne 1 -or $state.Written -ne 1 -or $state.Restarts -ne 0 -or $state.Rules.Count -ne 2) { Fail 'second run not idempotent' }

# Changed AllowedIPs: rewrite with the SAME key and restart the running tunnel.
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings @{ AllowedIPs = '192.0.2.0/24' }) -Pins $pins
if ($out.ExitCode -ne 0 -or $state.Written -ne 2 -or $state.Restarts -ne 1) { Fail 'config change not applied' }
if ((Get-WgcPrivateKeyFromConfig -Text $state.Config) -cne $devKey) { Fail 'key changed on update' }

# A tunnel stopped by the network guard is not restarted on a config change.
$state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Stopped'; StartType = 'Automatic' }
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings @{ AllowedIPs = '192.0.2.0/25' }) -Pins $pins
if ($out.ExitCode -ne 0 -or $state.Restarts -ne 1) { Fail 'stopped tunnel was restarted' }

# Hash mismatch fails and installs nothing.
$state.Installed = ''
$script:GetFileSha256 = { param($Path) 'f' * 64 }
$msiBefore = $state.Msi
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings) -Pins $pins
if ($out.ExitCode -ne 1 -or $state.Msi -ne $msiBefore) { Fail 'hash mismatch not refused' }
$state.Installed = '1.1.1'

# Bad settings fail before anything is touched.
$written = $state.Written
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings @{ ServerPublicKey = 'x' }) -Pins $pins
if ($out.ExitCode -ne 1 -or $state.Written -ne $written) { Fail 'bad settings not refused' }

# Empty pin is a no-op.
if ((Invoke-WireGuardClientAction -Action 'Install' -PinVersion '' -Settings (New-Settings) -Pins $pins).ExitCode -ne 0) { Fail 'empty pin' }

# Uninstall: service gone, only tagged rules removed, GSA value cleared.
$state.Rules.Add([pscustomobject]@{ Name = 'foreign'; Namespace = @('.x.example.invalid'); NameServers = @('6.6.0.1'); Comment = 'GSA' })
$out = Invoke-WireGuardClientAction -Action 'Uninstall' -PinVersion '1.1.1' -Settings (New-Settings) -Pins $pins
if ($out.ExitCode -ne 0 -or $null -ne $state.Service -or $state.Gsa -ne 0) { Fail 'uninstall' }
if ($state.Rules.Count -ne 1 -or $state.Rules[0].Name -cne 'foreign') { Fail 'uninstall removed a foreign rule or kept its own' }

# Uninstall never downloads, so a bad installer URL does not block it.
$state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Running'; StartType = 'Automatic' }
$badPins = [pscustomobject]@{ Url = 'https://user@example.invalid/w.msi'; Sha256 = $InstallerSha256; ArmUrl = $ArmInstallerUrl; ArmSha256 = $ArmInstallerSha256 }
$out = Invoke-WireGuardClientAction -Action 'Uninstall' -PinVersion '1.1.1' -Settings (New-Settings) -Pins $badPins
if ($out.ExitCode -ne 0 -or $null -ne $state.Service) { Fail 'uninstall blocked by an installer URL' }
# Install with the same URL is refused before any download.
$downloads = 0
$script:DownloadFile = { param($Url, $Destination) $script:downloads++ }
$state.Installed = ''
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings) -Pins $badPins
if ($out.ExitCode -ne 1 -or $downloads -ne 0) { Fail 'userinfo URL not refused on install' }

# Downloads: a 404 is tried once, a 503 three times.
$script:RetryDelay = { param($Seconds) }
$script:DownloadFile = { param($Url, $Destination) $script:downloads++; throw [System.Net.Http.HttpRequestException]::new('x', $null, [System.Net.HttpStatusCode]::NotFound) }
$downloads = 0
if (Save-WgcInstaller -Url $InstallerUrl -Sha256 $InstallerSha256 -Destination (Join-Path ([IO.Path]::GetTempPath()) 'wgc-test.msi')) { Fail '404 reported success' }
if ($downloads -ne 1) { Fail "404 was tried $downloads times" }
$script:DownloadFile = { param($Url, $Destination) $script:downloads++; throw [System.Net.Http.HttpRequestException]::new('x', $null, [System.Net.HttpStatusCode]::ServiceUnavailable) }
$downloads = 0
[void](Save-WgcInstaller -Url $InstallerUrl -Sha256 $InstallerSha256 -Destination (Join-Path ([IO.Path]::GetTempPath()) 'wgc-test.msi'))
if ($downloads -ne 3) { Fail "503 was tried $downloads times" }

# ARM64 with an empty ARM64 hash is a no-op: nothing downloaded or written.
$script:GetArch = { 'ARM64' }
$written = $state.Written
$downloads = 0
$armOff = [pscustomobject]@{ Url = $InstallerUrl; Sha256 = $InstallerSha256; ArmSha256 = '' }
# The URL must not be read when the hash is empty. A getter exception can be swallowed, so count reads.
$script:urlReads = 0
$armOff | Add-Member -MemberType ScriptProperty -Name ArmUrl -Value { $script:urlReads++; 'https://example.invalid/w.msi' }
$out = Invoke-WireGuardClientAction -Action 'Install' -PinVersion '1.1.1' -Settings (New-Settings) -Pins $armOff
if ($out.ExitCode -ne 0 -or $downloads -ne 0 -or $state.Written -ne $written) { Fail 'empty ARM64 hash was not a no-op on ARM64' }
if ($script:urlReads -ne 0) { Fail 'installer URL was read before the empty-hash no-op' }

Write-Output 'wireguard-client tests passed'
