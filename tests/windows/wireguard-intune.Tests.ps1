$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Intune flow of the wireguard-client package: Prepare, Revoke, Rotate, legacy removal, the signed map,
# Report (Remediation detection), Apply, the Win32 detection script and intune.json.
# Runs under pwsh and Windows PowerShell 5.1. Test RSA keys are made at run time; no key is in the repo.

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/wireguard-client'
$scriptPath = Join-Path $packageDir 'Invoke-WireGuardClient.ps1'
$detectPath = Join-Path $packageDir 'Detect-WireGuardClient.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Synthetic WireGuard keys built from byte runs. Each generated key differs.
$serverKey = [Convert]::ToBase64String([byte[]](0..31))
$script:genCount = 0
function New-TestKey { param([int]$Seed) return [Convert]::ToBase64String([byte[]]@(($Seed)..($Seed + 31))) }
function Get-TestPub { param([string]$Key) return [Convert]::ToBase64String([byte[]]@([Convert]::FromBase64String($Key) | ForEach-Object { 255 - $_ })) }

function New-Rsa { param([int]$Bits) $r = [Security.Cryptography.RSA]::Create(); $r.KeySize = $Bits; return $r }
$signer = New-Rsa 3072
$mapKey = $signer.ToXmlString($false)
$otherSigner = New-Rsa 3072

function New-Settings {
    param([hashtable]$Over = @{})
    $s = [ordered]@{
        TunnelName = 'office'; Address = ''; ServerPublicKey = $serverKey; Endpoint = '198.51.100.7:51820'
        AllowedIPs = '192.0.2.0/24'; PersistentKeepalive = '25'; NrptNamespaces = '.corp.example.invalid'; NrptServers = '192.0.2.5'
        DisableGsaPrivateAccess = 'false'; MapUrl = 'https://example.invalid/wgmap/office.json'; MapKey = $mapKey
        LegacyPattern = 'client_*'; TrustedGateways = '192.0.2.1'; TrustedGatewayMacs = '00-53-00-11-22-33'
    }
    foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
    return [pscustomobject]$s
}

function New-Map {
    param([hashtable]$Entries = @{}, [int]$Serial = 5, [string]$Tunnel = 'office', $Version = 1, $Signer = $signer, [switch]$Tamper)
    $doc = [ordered]@{ v = $Version; tenant = 'example.invalid'; tunnel = $Tunnel; serial = $Serial; entries = $Entries }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($doc | ConvertTo-Json -Compress -Depth 5))
    $sig = $Signer.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($Tamper) {
        $doc.serial = $Serial + 1
        $bytes = [Text.Encoding]::UTF8.GetBytes(($doc | ConvertTo-Json -Compress -Depth 5))
    }
    return (@{ payload = [Convert]::ToBase64String($bytes); sig = [Convert]::ToBase64String($sig) } | ConvertTo-Json -Compress)
}

# ---- Pure checks ----
if (-not (Test-WgcMapKey -Xml $mapKey)) { Fail 'generated map key rejected' }
if (Test-WgcMapKey -Xml $signer.ToXmlString($true)) { Fail 'private key XML accepted as the map key' }
if (-not (Test-WgcMapUrl -Url 'https://example.invalid/m.json') -or (Test-WgcMapUrl -Url 'http://example.invalid/m.json') -or (Test-WgcMapUrl -Url 'https://u@example.invalid/m.json')) { Fail 'map url check' }
foreach ($good in @('client_*', 'client_', 'old-tunnel')) { if (-not (Test-WgcLegacyPattern -Pattern $good)) { Fail "legacy pattern $good rejected" } }
foreach ($bad in @('*', 'Client_*', 'a*b', 'a?', 'x y')) { if (Test-WgcLegacyPattern -Pattern $bad) { Fail "legacy pattern $bad accepted" } }

# sha256 lookup: lower-case hex of the ASCII bytes of the base64 public key.
$pubA = Get-TestPub (New-TestKey 10)
$sha = [Security.Cryptography.SHA256]::Create()
$expectHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($pubA))) -replace '-', '').ToLowerInvariant()
if ((Get-WgcSha256Hex -Text $pubA) -cne $expectHash -or $expectHash.Length -ne 64) { Fail 'sha256 of the public key' }

# ---- Map verification ----
$entries = @{ $expectHash = @{ state = 'active'; address = '10.99.10.20/32' } }
$e = Get-WgcMapEntry -MapText (New-Map -Entries $entries) -MapKey $mapKey -Tunnel 'office' -LastSerial 4 -PublicKey $pubA
if ($e.State -cne 'active' -or $e.Address -cne '10.99.10.20/32' -or $e.Serial -ne 5) { Fail "valid map not accepted: $($e.State)" }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries) -MapKey $mapKey -Tunnel 'office' -LastSerial 5 -PublicKey $pubA).State -cne 'active') { Fail 'equal serial rejected' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries) -MapKey $mapKey -Tunnel 'office' -LastSerial 6 -PublicKey $pubA).State -cne 'invalid') { Fail 'lower serial accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries -Tamper) -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'tampered payload accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries -Signer $otherSigner) -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'wrong signing key accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries) -MapKey $otherSigner.ToXmlString($false) -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'wrong map key accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries -Tunnel 'other') -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'wrong tunnel accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries -Version 2) -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'v 2 accepted' }
if ((Get-WgcMapEntry -MapText 'not json' -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'garbage accepted' }
$small = New-Rsa 2048
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries -Signer $small) -MapKey $small.ToXmlString($false) -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail '2048-bit map key accepted' }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $entries) -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey (Get-TestPub (New-TestKey 99))).State -cne 'none') { Fail 'unknown key not none' }
$badAddr = @{ $expectHash = @{ state = 'active'; address = '10.99.10.0/24' } }
if ((Get-WgcMapEntry -MapText (New-Map -Entries $badAddr) -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne 'invalid') { Fail 'non /32 address accepted' }
foreach ($st in @('revoked', 'rotate')) {
    $m = New-Map -Entries @{ $expectHash = @{ state = $st } }
    if ((Get-WgcMapEntry -MapText $m -MapKey $mapKey -Tunnel 'office' -LastSerial 0 -PublicKey $pubA).State -cne $st) { Fail "$st entry" }
}

# ---- Side effects mocked ----
$files = @{}
$state = [ordered]@{ Installed = '1.1.1'; Msi = 0; Service = $null; Uninstalled = [System.Collections.Generic.List[string]]::new(); Gen = 0; Folder = 0; WriteBeforeFolder = $false
    Staged = @(); GuardCalls = [System.Collections.Generic.List[object]]::new(); Rules = [System.Collections.Generic.List[object]]::new(); Handshake = $null; Tunnels = @(); Map = ''; MapFails = $false; Removed = [System.Collections.Generic.List[string]]::new() }
function Get-Leaf { param([string]$Path) return ($Path -split '[\\/]')[-1] }
$script:GetArch = { 'AMD64' }
$script:GetInstalledVersion = { $state.Installed }
$script:InvokeMsiExec = { param($InstallerPath) $state.Msi++; 0 }
$script:InvokeWg = {
    param([string[]]$Arguments, [string]$StdIn = '')
    switch ($Arguments[0]) {
        'genkey' { $state.Gen++; return (New-TestKey (100 + $state.Gen)) }
        'pubkey' { return (Get-TestPub $StdIn) }
        default { throw 'unexpected wg call' }
    }
}
$script:EnsureSecureFolder = { param($Path) $state.Folder++ }
$script:ReadConfig = { param($Path) $leaf = Get-Leaf $Path; if ($files.ContainsKey($leaf)) { $files[$leaf] } else { '' } }
$script:WriteConfig = { param($Path, $Text) if ($state.Folder -eq 0) { $state.WriteBeforeFolder = $true }; $files[(Get-Leaf $Path)] = $Text }
$script:RemoveFile = { param($Path) $leaf = Get-Leaf $Path; [void]$files.Remove($leaf); $state.Removed.Add($leaf) }
$script:StageFiles = { param([string[]]$Sources, $Destination) $state.Staged = @($Sources | ForEach-Object { Get-Leaf $_ }) }
$script:InvokeGuard = { param($ScriptPath, [hashtable]$Parameters) $state.GuardCalls.Add($Parameters); 0 }
$script:RunGuardTask = { }
$script:GetService = { param($Name) $state.Service }
$script:InstallTunnelService = { param($ConfigPath) $state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Running'; StartType = 'Automatic' }; 0 }
$script:UninstallTunnelService = {
    param($TunnelName)
    $state.Uninstalled.Add($TunnelName)
    if ($TunnelName -ceq 'office') { $state.Service = $null }
    0
}
$script:RestartService = { param($Name) }
$script:GetNrptRules = { @($state.Rules) }
$script:AddNrptRule = { param($Namespace, [string[]]$Servers, $Comment) $state.Rules.Add([pscustomobject]@{ Name = [guid]::NewGuid().ToString(); Namespace = @($Namespace); NameServers = $Servers; Comment = $Comment }) }
$script:RemoveNrptRule = { param($Rule) [void]$state.Rules.Remove($Rule) }
$script:SetGsaPrivateAccess = { param([bool]$Disabled) 0 }
$script:GetLatestHandshake = { param($TunnelName) $state.Handshake }
$script:GetTunnelServices = { @($state.Tunnels) }
$script:FetchMap = { param($Url) if ($state.MapFails) { throw 'offline' }; $state.Map }
$pins = [pscustomobject]@{ Url = $InstallerUrl; Sha256 = $InstallerSha256; ArmUrl = $ArmInstallerUrl; ArmSha256 = $ArmInstallerSha256 }
function Invoke-Act { param([string]$Action, $Settings = (New-Settings)) $script:WgcErrors.Clear(); return (Invoke-WireGuardClientAction -Action $Action -PinVersion '1.1.1' -Settings $Settings -Pins $pins) }
function Get-Json { param($Out) return ($Out.Report | ConvertTo-Json -Compress -Depth 4) }

# Unreplaced or empty settings: exit 1, nothing written.
foreach ($over in @(@{ TunnelName = '%wgtunnel%' }, @{ MapKey = '%wgmapkey%' }, @{ LegacyPattern = '%wglegacy%' }, @{ Endpoint = '' }, @{ TrustedGatewayMacs = '' }, @{ MapUrl = 'http://example.invalid/m.json' }, @{ LegacyPattern = '*' })) {
    $out = Invoke-Act 'Prepare' (New-Settings $over)
    if ($out.ExitCode -ne 1 -or $files.Count -ne 0 -or $state.Gen -ne 0 -or $state.GuardCalls.Count -ne 0) { Fail "Prepare accepted $(@($over.Keys)[0]) = '$(@($over.Values)[0])'" }
}

# Prepare: key generated once, tenant.json, staged files, guard installed, no tunnel.
$out = Invoke-Act 'Prepare' (New-Settings @{ LegacyPattern = ''; NrptNamespaces = ''; NrptServers = '' })
if ($out.ExitCode -ne 0) { Fail ("prepare exit $($out.ExitCode): " + ($script:WgcErrors -join '; ')) }
$key1 = ([string]$files['office.key']).Trim()
if ($state.Gen -ne 1 -or -not (Test-WgcKey -Key $key1)) { Fail 'prepare did not make one key' }
if ($state.WriteBeforeFolder) { Fail 'a file was written before the folder ACL' }
if ($files.ContainsKey('office.conf') -or $null -ne $state.Service) { Fail 'prepare installed a tunnel' }
if ($out.Report.publicKey -cne (Get-TestPub $key1) -or (Get-Json $out).Contains($key1)) { Fail 'prepare report key' }
$tenant = $files['tenant.json'] | ConvertFrom-Json
$fields = @('tunnel', 'endpoint', 'serverPublicKey', 'allowedIPs', 'nrptNamespaces', 'nrptServers', 'persistentKeepalive', 'mapUrl', 'mapKey', 'legacyPattern', 'disableGsaPrivateAccess', 'trustedGateways', 'trustedGatewayMacs')
if ((@($tenant.PSObject.Properties.Name) -join ',') -cne ($fields -join ',')) { Fail "tenant.json fields: $(@($tenant.PSObject.Properties.Name) -join ',')" }
if ($tenant.tunnel -cne 'office' -or $tenant.mapKey -cne $mapKey -or $tenant.trustedGatewayMacs -cne '00-53-00-11-22-33') { Fail 'tenant.json values' }
if ((@($state.Staged) -join ',') -cne 'Invoke-WireGuardClient.ps1,Detect-WireGuardTunnel.ps1,Remediate-WireGuardTunnel.ps1,Invoke-WireGuardNetworkGuard.ps1') { Fail "staged: $($state.Staged -join ',')" }
$g = $state.GuardCalls[0]
if ($g.Action -cne 'Install' -or $g.TrustedGateways -cne '192.0.2.1' -or $g.TrustedGatewayMacs -cne '00-53-00-11-22-33') { Fail 'guard install parameters' }
$settingsBack = ConvertFrom-WgcTenantJson -Text $files['tenant.json'] -Address '192.0.2.9/32'
if ($settingsBack.MapKey -cne $mapKey -or $settingsBack.TunnelName -cne 'office' -or $settingsBack.Address -cne '192.0.2.9/32') { Fail 'tenant.json does not read back' }

# Second Prepare keeps the key.
$out = Invoke-Act 'Prepare' (New-Settings @{ LegacyPattern = '' })
if ($out.ExitCode -ne 0 -or $state.Gen -ne 1 -or ([string]$files['office.key']).Trim() -cne $key1) { Fail 'prepare replaced the key' }

# A key already in office.conf is moved to office.key, not replaced.
$confKey = New-TestKey 50
$files.Remove('office.key')
$files['office.conf'] = "[Interface]`r`nPrivateKey = $confKey`r`nAddress = 10.99.10.20/32`r`n"
$out = Invoke-Act 'Prepare'
if ($out.ExitCode -ne 0 -or $state.Gen -ne 1 -or ([string]$files['office.key']).Trim() -cne $confKey) { Fail 'conf key not moved to the key file' }
$files.Remove('office.conf')

# Install with an address reads office.key and never makes a second key.
$out = Invoke-Act 'Install' (New-Settings @{ Address = '10.99.10.20/32' })
if ($out.ExitCode -ne 0 -or $state.Gen -ne 1 -or (Get-WgcPrivateKeyFromConfig -Text $files['office.conf']) -cne $confKey) { Fail 'install did not use the key file' }

# Legacy removal: only with a handshake under 180 s, never the managed tunnel.
$state.Tunnels = @(
    [pscustomobject]@{ Name = 'office'; ConfigPath = 'C:\x\office.conf' },
    [pscustomobject]@{ Name = 'client_a'; ConfigPath = 'C:\x\client_a.conf.dpapi' },
    [pscustomobject]@{ Name = 'other'; ConfigPath = 'C:\x\other.conf' }
)
foreach ($age in @($null, 180, 600)) {
    $state.Handshake = $age
    $state.Uninstalled.Clear()
    $out = Invoke-Act 'Install' (New-Settings @{ Address = '10.99.10.20/32' })
    if ($state.Uninstalled.Count -ne 0) { Fail "legacy removed with handshake $age" }
}
$state.Handshake = 30
$state.Removed.Clear()
$out = Invoke-Act 'Install' (New-Settings @{ Address = '10.99.10.20/32' })
if ((@($state.Uninstalled) -join ',') -cne 'client_a' -or (@($out.Report.legacyRemoved) -join ',') -cne 'client_a') { Fail "legacy removal: $($state.Uninstalled -join ',')" }
if (@($state.Removed) -notcontains 'client_a.conf.dpapi') { Fail 'legacy config not removed' }
$state.Uninstalled.Clear()
$out = Invoke-Act 'Install' (New-Settings @{ Address = '10.99.10.20/32'; LegacyPattern = 'office' })
if ($state.Uninstalled.Count -ne 0) { Fail 'a pattern matching the managed tunnel removed it' }

# Report (Remediation detection) with every map state.
function Set-Map { param([string]$MapState, [string]$Address = '10.99.10.20/32', [int]$Serial = 7)
    $pub = Get-TestPub ([string]$files['office.key']).Trim()
    $entry = @{ state = $MapState }
    if ($MapState -ceq 'active') { $entry.address = $Address }
    $state.Map = New-Map -Serial $Serial -Entries @{ (Get-WgcSha256Hex -Text $pub) = $entry }
}
$privNow = ([string]$files['office.key']).Trim()
$state.Tunnels = @([pscustomobject]@{ Name = 'office'; ConfigPath = '' })
$state.Handshake = 30
$files['state.json'] = '{"stoppedByGuard":[],"onTrustedNetwork":true}'
Set-Map 'active'
$out = Invoke-Act 'Report'
$json = Get-Json $out
if ($out.ExitCode -ne 0) { Fail "report exit for a matching tunnel: $json" }
$keys = @($out.Report.Keys) -join ','
if ($keys -cne 'v,tunnel,publicKey,address,service,handshakeAge,wgVersion,onOfficeLan,legacyTunnels,mapState,errors') { Fail "report fields $keys" }
if ($out.Report.publicKey -cne (Get-TestPub $privNow) -or $out.Report.address -cne '10.99.10.20/32' -or $out.Report.service -cne 'Running' -or $out.Report.onOfficeLan -ne $true -or $out.Report.mapState -cne 'active') { Fail "report values $json" }
if ($json.Contains($privNow) -or $json.Contains($confKey)) { Fail 'private key in the report' }
if ([string]$files['map-serial.txt'] -cne '7') { Fail 'serial not saved after a valid map' }

Set-Map 'active' -Address '10.99.10.21/32'
if ((Invoke-Act 'Report').ExitCode -ne 1) { Fail 'address change not detected' }
Set-Map 'active'
$state.Service = $null
if ((Invoke-Act 'Report').ExitCode -ne 1) { Fail 'absent tunnel not detected' }
$state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Stopped'; StartType = 'Automatic' }
$out = Invoke-Act 'Report'
if ($out.ExitCode -ne 0 -or $out.Report.service -cne 'Stopped') { Fail 'a tunnel the guard stopped is not a change' }
$state.Service = [pscustomobject]@{ Name = 'WireGuardTunnel$office'; Status = 'Running'; StartType = 'Automatic' }
$state.Tunnels = @([pscustomobject]@{ Name = 'office'; ConfigPath = '' }, [pscustomobject]@{ Name = 'client_b'; ConfigPath = '' })
$out = Invoke-Act 'Report'
if ($out.ExitCode -ne 1 -or (@($out.Report.legacyTunnels) -join ',') -cne 'client_b') { Fail 'legacy tunnel with a fresh handshake not detected' }
$state.Handshake = 900
if ((Invoke-Act 'Report').ExitCode -ne 0) { Fail 'legacy tunnel with a stale handshake is a change' }
foreach ($st in @('revoked', 'rotate')) {
    Set-Map $st
    if ((Invoke-Act 'Report').ExitCode -ne 1) { Fail "$st not detected" }
}
$state.Map = New-Map -Serial 8
$out = Invoke-Act 'Report'
if ($out.ExitCode -ne 0 -or $out.Report.mapState -cne 'none') { Fail 'no entry' }
$state.MapFails = $true
$out = Invoke-Act 'Report'
if ($out.ExitCode -ne 0 -or $out.Report.mapState -cne 'unavailable') { Fail 'unavailable map' }
$state.MapFails = $false
Set-Map 'revoked' -Serial 3
$out = Invoke-Act 'Report'
if ($out.ExitCode -ne 0 -or $out.Report.mapState -cne 'invalid' -or [string]$files['map-serial.txt'] -cne '8') { Fail 'older map not rejected' }

# The line stays at or under 2048 characters with many legacy tunnels and errors.
$state.Tunnels = @(1..60 | ForEach-Object { [pscustomobject]@{ Name = ('client_' + ('x' * 40) + $_); ConfigPath = '' } })
$script:FetchMap = { param($Url) foreach ($i in 1..10) { Write-WgcError ('e' * 300) }; throw 'offline' }
$json = Get-Json (Invoke-Act 'Report')
if ($json.Length -gt 2048) { Fail "report is $($json.Length) characters" }
$script:FetchMap = { param($Url) if ($state.MapFails) { throw 'offline' }; $state.Map }
$state.Tunnels = @([pscustomobject]@{ Name = 'office'; ConfigPath = '' })

# Apply: active installs with the mapped address; no entry or a bad map changes nothing.
$state.Service = $null
$files.Remove('office.conf')
Set-Map 'active' -Address '10.99.10.30/32' -Serial 9
$out = Invoke-Act 'Apply'
if ($out.ExitCode -ne 0 -or $null -eq $state.Service -or (Get-WgcAddressFromConfig -Text $files['office.conf']) -cne '10.99.10.30/32') { Fail 'apply active' }
$state.Map = New-Map -Serial 9 -Entries @{ (Get-WgcSha256Hex -Text (Get-TestPub $privNow)) = @{ state = 'revoked' } } -Tamper
$out = Invoke-Act 'Apply'
if ($out.ExitCode -ne 0 -or $null -eq $state.Service -or ([string]$files['office.key']).Trim() -cne $privNow) { Fail 'a tampered map changed the device' }

# Revoke through Apply: tunnel and NRPT gone, config and key replaced by a new key.
$state.Rules.Add([pscustomobject]@{ Name = 'foreign'; Namespace = @('.x.example.invalid'); NameServers = @('192.0.2.53'); Comment = 'other' })
Set-Map 'revoked' -Serial 10
$gen = $state.Gen
$out = Invoke-Act 'Apply'
$newKey = ([string]$files['office.key']).Trim()
if ($out.ExitCode -ne 0 -or $null -ne $state.Service -or $files.ContainsKey('office.conf')) { Fail 'revoke left the tunnel' }
if ($state.Gen -ne $gen + 1 -or $newKey -ceq $privNow -or -not (Test-WgcKey -Key $newKey)) { Fail 'revoke did not make a new key' }
if ($state.Rules.Count -ne 1 -or $state.Rules[0].Name -cne 'foreign') { Fail 'revoke NRPT rules' }
if ($out.Report.publicKey -cne (Get-TestPub $newKey) -or (Get-Json $out).Contains($newKey)) { Fail 'revoke report key' }
if ((Invoke-Act 'Report').ExitCode -ne 0) { Fail 'the new key is still flagged after revoke' }

# Rotate: tunnel uninstalled, new key, NRPT rules kept.
Set-Map 'active' -Serial 11
$null = Invoke-Act 'Apply'
$rulesBefore = $state.Rules.Count
$keyBefore = ([string]$files['office.key']).Trim()
Set-Map 'rotate' -Serial 12
$out = Invoke-Act 'Apply'
if ($out.ExitCode -ne 0 -or $null -ne $state.Service -or $files.ContainsKey('office.conf') -or ([string]$files['office.key']).Trim() -ceq $keyBefore) { Fail 'rotate' }
if ($state.Rules.Count -ne $rulesBefore) { Fail 'rotate changed NRPT rules' }

# Intune Uninstall removes what Prepare added and keeps the key.
$out = Invoke-Act 'Uninstall'
if ($out.ExitCode -ne 0 -or $files.ContainsKey('tenant.json') -or -not $files.ContainsKey('office.key') -or @($state.Removed) -notcontains 'bin') { Fail 'uninstall after prepare' }

# Map fetch: a 503 is tried three times, a 404 once; both leave the device as it is.
$script:RetryDelay = { param($Seconds) }
$script:fetches = 0
$script:FetchMap = { param($Url) $script:fetches++; throw [System.Net.WebException]::new('x', [System.Net.WebExceptionStatus]::Timeout) }
if ((Invoke-Act 'Report').Report.mapState -cne 'unavailable' -or $script:fetches -ne 3) { Fail "timeout fetched $script:fetches times" }
$script:fetches = 0
$script:FetchMap = { param($Url) $script:fetches++; throw [System.Net.WebException]::new('x', [System.Net.WebExceptionStatus]::TrustFailure) }
if ((Invoke-Act 'Report').Report.mapState -cne 'unavailable' -or $script:fetches -ne 1) { Fail "trust failure fetched $script:fetches times" }
$script:fetches = 0
$script:FetchMap = { param($Url) $script:fetches++; if ($script:fetches -lt 2) { throw [System.TimeoutException]::new('x') }; $state.Map }
if ((Invoke-Act 'Report').Report.mapState -ceq 'unavailable' -or $script:fetches -ne 2) { Fail 'retry did not recover' }

# A failed guard uninstall keeps tenant.json and bin for the next try.
$files['tenant.json'] = '{"tunnel":"office"}'
$script:InvokeGuard = { param($ScriptPath, [hashtable]$Parameters) 1 }
$realTestPath = Get-Command Test-Path
function Test-Path { param([string]$LiteralPath, $PathType) if ($LiteralPath.EndsWith('Invoke-WireGuardNetworkGuard.ps1')) { return $true }; & $realTestPath -LiteralPath $LiteralPath }
$state.Removed.Clear()
$out = Invoke-Act 'Uninstall'
Remove-Item Function:\Test-Path
if ($out.ExitCode -ne 1 -or -not $files.ContainsKey('tenant.json') -or @($state.Removed) -contains 'bin') { Fail 'failed guard uninstall removed the staged files' }

# ---- Detect-WireGuardClient.ps1 ----
. $detectPath
$floorLines = @([regex]::Matches((Get-Content -LiteralPath $detectPath -Raw), "(?m)^\`$RelianWireGuardFloor = '([0-9.]+)'\r?$"))
if ($floorLines.Count -ne 1 -or $floorLines[0].Groups[1].Value -cne '1.1.1') { Fail 'detection floor line' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('wgc-detect-' + [guid]::NewGuid().ToString('n'))
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
    function Test-Detect { param([string]$Version = '1.1.1', [bool]$Task = $true) Test-RelianWireGuardDetected -InstalledVersion $Version -Floor $RelianWireGuardFloor -Root $root -TaskPresent $Task }
    if (Test-Detect) { Fail 'detected with nothing in place' }
    Set-Content -LiteralPath (Join-Path $root 'tenant.json') -Value '{"tunnel":"office"}'
    Set-Content -LiteralPath (Join-Path $root 'office.key') -Value 'k'
    foreach ($n in $script:StagedFiles) { Set-Content -LiteralPath (Join-Path (Join-Path $root 'bin') $n) -Value '#' }
    if (-not (Test-Detect)) { Fail 'not detected with everything in place' }
    if (Test-Detect -Version '1.1.0') { Fail 'detected below the floor' }
    if (Test-Detect -Version '') { Fail 'detected with no version' }
    if (-not (Test-Detect -Version '1.2.0')) { Fail 'not detected above the floor' }
    if (Test-Detect -Task $false) { Fail 'detected without the guard task' }
    Remove-Item -LiteralPath (Join-Path (Join-Path $root 'bin') 'Remediate-WireGuardTunnel.ps1')
    if (Test-Detect) { Fail 'detected without a staged script' }
    Set-Content -LiteralPath (Join-Path (Join-Path $root 'bin') 'Remediate-WireGuardTunnel.ps1') -Value '#'
    Remove-Item -LiteralPath (Join-Path $root 'office.key')
    if (Test-Detect) { Fail 'detected without the key' }
    Set-Content -LiteralPath (Join-Path $root 'office.key') -Value 'k'
    Set-Content -LiteralPath (Join-Path $root 'tenant.json') -Value 'not json'
    if (Test-Detect) { Fail 'detected with a broken tenant.json' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- intune.json and the install wrapper ----
$meta = Get-Content -LiteralPath (Join-Path $packageDir 'intune.json') -Raw | ConvertFrom-Json
if ((@($meta.PSObject.Properties.Name) -join ',') -cne 'displayName,publisher,setupFile,installCommand,uninstallCommand,detectionScript,detectReplace') { Fail 'intune.json fields' }
if ($meta.displayName -cne 'Relian Managed - WireGuard' -or $meta.detectionScript -cne 'Detect-WireGuardClient.ps1') { Fail 'intune.json values' }
foreach ($f in @($meta.setupFile, $meta.detectionScript)) { if (-not (Test-Path -LiteralPath (Join-Path $packageDir $f))) { Fail "$f is not in the package" } }
if (-not ([string]$meta.installCommand).StartsWith('powershell.exe ') -or ([string]$meta.installCommand).Length -gt 1024) { Fail 'install command' }
if (-not ([string]$meta.uninstallCommand).Contains('-Action Uninstall -PinVersion 1.1.1')) { Fail 'uninstall command' }
$wrapper = Get-Content -LiteralPath (Join-Path $packageDir $meta.setupFile) -Raw
$tokens = @('wgtunnel', 'wgendpoint', 'wgserverkey', 'wgallowedips', 'wgnrptns', 'wgnrptdns', 'wggateways', 'wggatewaymacs', 'wgmapurl', 'wgmapkey', 'wglegacy', 'wgdisablepa')
foreach ($token in $tokens) {
    if (([regex]::Matches($wrapper, "(?m)^[A-Za-z]+=%$token%\r?$")).Count -ne 1) { Fail "wrapper token $token" }
}
if (@([regex]::Matches($wrapper, '%[A-Za-z0-9]+%')).Count -ne 12) { Fail 'wrapper has a %token% CIPP might replace' }
if (-not $wrapper.Contains('-Action Prepare')) { Fail 'wrapper does not run Prepare' }

# Substituted values are data: quotes, $() and backticks reach Prepare verbatim and run nothing.
$dir = Join-Path ([IO.Path]::GetTempPath()) ('wgc-wrap-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $hostile = "x' ; `$(Set-Content -LiteralPath '$dir/pwned' -Value 1) ``n '@"
    $filled = $wrapper
    foreach ($token in $tokens) { $filled = $filled.Replace("%$token%", "$token-$hostile") }
    Set-Content -LiteralPath (Join-Path $dir 'Install-WireGuardIntune.ps1') -Value $filled
    Set-Content -LiteralPath (Join-Path $dir 'Invoke-WireGuardClient.ps1') -Value 'param([string]$DeploymentType, [string]$Action, [string]$PinVersion, [string]$TunnelName, [string]$MapKey, [string]$LegacyPattern) [IO.File]::WriteAllText((Join-Path $PSScriptRoot "got.json"), (@{ a = $Action; t = $TunnelName; k = $MapKey; l = $LegacyPattern } | ConvertTo-Json -Compress)); exit 0'
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Install-WireGuardIntune.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "wrapper exit $LASTEXITCODE" }
    if (Test-Path -LiteralPath (Join-Path $dir 'pwned')) { Fail 'a substituted value ran code' }
    $got = Get-Content -LiteralPath (Join-Path $dir 'got.json') -Raw | ConvertFrom-Json
    if ($got.a -cne 'Prepare' -or $got.t -cne "wgtunnel-$($hostile.Trim())" -or $got.k -cne "wgmapkey-$($hostile.Trim())") { Fail "wrapper values: $($got.t)" }
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'wireguard-intune tests passed'
