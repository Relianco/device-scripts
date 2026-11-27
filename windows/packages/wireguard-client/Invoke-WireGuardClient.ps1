# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# The installer pins are windows/releases/wireguard-client.json. The runner copies
# this script alone, so the values are inlined.
#
# Installs WireGuard for Windows and one split tunnel as a service. The private key
# is generated on the device by wg.exe, lives only in the tunnel config inside a
# folder that SYSTEM and Administrators alone can read, and is never printed.
# The run prints one JSON line with the PUBLIC key; the operator adds that key as a
# peer on the server. Optional: NRPT rules that send chosen DNS namespaces to the
# office DNS servers, and turning off Global Secure Access Private Access for the
# users whose hives are loaded.
#
# Intune (see docs/wireguard-client.md): Prepare makes the device key in <tunnel>.key,
# writes tenant.json, stages this package in bin\ and installs the network guard, with
# no tunnel. Report and Apply read tenant.json and a signed address map; Apply installs
# the tunnel with the mapped address, or runs Revoke or Rotate, which delete the key and
# make a new one. Legacy tunnels matching LegacyPattern are removed only once the managed
# tunnel has a handshake under 180 seconds.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.1.msi',
    [string]$InstallerSha256 = '7bfed60ad61b785c914b38b61555a975488e1d3ec472dbfb2fcdf498fca75242',
    [string]$ArmInstallerUrl = 'https://download.wireguard.com/windows-client/wireguard-arm64-1.1.1.msi',
    [string]$ArmInstallerSha256 = '8336335c738d4aff040fa9d11b752da65a80b6f41d3262d6ba5e82f97ebd1bd4',
    [string]$CancelPath = '',
    [string]$Mode = '',
    [string]$TunnelName = '',
    [string]$Address = '',
    [string]$ServerPublicKey = '',
    [string]$Endpoint = '',
    [string]$AllowedIPs = '',
    [string]$PersistentKeepalive = '25',
    [string]$NrptNamespaces = '',
    [string]$NrptServers = '',
    [string]$DisableGsaPrivateAccess = 'false',
    [string]$MapUrl = '',
    [string]$MapKey = '',
    [string]$LegacyPattern = '',
    [string]$TrustedGateways = '',
    [string]$TrustedGatewayMacs = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WgcErrors = [System.Collections.Generic.List[string]]::new()
$script:NrptTagPrefix = 'Relian WireGuard client: '
$script:WgcRoot = $PSScriptRoot
# tenant.json field for each setting. Every value is a string.
$script:TenantFields = [ordered]@{
    TunnelName = 'tunnel'; Endpoint = 'endpoint'; ServerPublicKey = 'serverPublicKey'; AllowedIPs = 'allowedIPs'
    NrptNamespaces = 'nrptNamespaces'; NrptServers = 'nrptServers'; PersistentKeepalive = 'persistentKeepalive'
    MapUrl = 'mapUrl'; MapKey = 'mapKey'; LegacyPattern = 'legacyPattern'; DisableGsaPrivateAccess = 'disableGsaPrivateAccess'
    TrustedGateways = 'trustedGateways'; TrustedGatewayMacs = 'trustedGatewayMacs'
}
# Files Prepare stages in bin\ for the Remediation.
$script:StagedFiles = @('Invoke-WireGuardClient.ps1', 'Detect-WireGuardTunnel.ps1', 'Remediate-WireGuardTunnel.ps1', 'Invoke-WireGuardNetworkGuard.ps1')

function Write-WgcError {
    param([string]$Message)
    $script:WgcErrors.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-WgcKey {
    param([AllowEmptyString()][string]$Key)
    if ($Key -cnotmatch '^[A-Za-z0-9+/]{43}=$') {
        return $false
    }
    try {
        return ([Convert]::FromBase64String($Key)).Length -eq 32
    } catch {
        return $false
    }
}

function Test-WgcTunnelName {
    param([AllowEmptyString()][string]$Name)
    # Becomes the service name WireGuardTunnel$<name> and the file name <name>.conf.
    return $Name -cmatch '^[a-z][a-z0-9-]{0,31}$'
}

function Test-WgcIpv4Cidr {
    param([AllowEmptyString()][string]$Cidr)
    if ($Cidr -cnotmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        return $false
    }
    foreach ($i in 1..4) {
        if ([int]$Matches[$i] -gt 255) {
            return $false
        }
    }
    return [int]$Matches[5] -le 32
}

function ConvertTo-WgcList {
    param([AllowEmptyString()][string]$Text)
    return @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Test-WgcEndpoint {
    param([AllowEmptyString()][string]$Endpoint)
    if ($Endpoint -cnotmatch '^([A-Za-z0-9.-]{1,253}):(\d{1,5})$') {
        return $false
    }
    $port = [int]$Matches[2]
    return $port -ge 1 -and $port -le 65535
}

function Test-WgcNamespace {
    param([AllowEmptyString()][string]$Namespace)
    # NRPT suffix (.example.invalid) or an exact name (host.example.invalid).
    return $Namespace -cmatch '^\.?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
}

function Test-WgcIpv4 {
    param([AllowEmptyString()][string]$Ip)
    return (Test-WgcIpv4Cidr -Cidr "$Ip/32")
}

function Test-WgcLegacyPattern {
    param([AllowEmptyString()][string]$Pattern)
    return $Pattern -cmatch '^[a-z0-9_-]+\*?$'
}

function Test-WgcMapUrl {
    param([AllowEmptyString()][string]$Url)
    $u = $null
    return [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -ceq 'https' -and [string]::IsNullOrEmpty($u.UserInfo)
}

# The public key ToXmlString($false) writes.
function Test-WgcMapKey {
    param([AllowEmptyString()][string]$Xml)
    return $Xml -cmatch '^<RSAKeyValue><Modulus>[A-Za-z0-9+/]+={0,2}</Modulus><Exponent>[A-Za-z0-9+/]+={0,2}</Exponent></RSAKeyValue>$'
}

# A CIPP variable the tenant lacks stays literal.
function Test-WgcUnreplaced {
    param([AllowEmptyString()][string]$Value)
    return $Value.Trim() -match '^%[a-z0-9]+%$'
}

# Pure. Returns a list of reasons; empty means valid.
function Get-WgcSettingsErrors {
    param($Settings, [switch]$NoAddress)
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-WgcTunnelName -Name $Settings.TunnelName)) { $errors.Add('TunnelName must be lower case letters, digits, or dashes') }
    if (-not $NoAddress -and -not (Test-WgcIpv4Cidr -Cidr $Settings.Address)) { $errors.Add('Address must be an IPv4 CIDR such as 192.0.2.10/32') }
    if (-not (Test-WgcKey -Key $Settings.ServerPublicKey)) { $errors.Add('ServerPublicKey is not a WireGuard key') }
    if (-not (Test-WgcEndpoint -Endpoint $Settings.Endpoint)) { $errors.Add('Endpoint must be host:port') }
    $allowed = @(ConvertTo-WgcList -Text $Settings.AllowedIPs)
    if ($allowed.Count -eq 0) {
        $errors.Add('AllowedIPs is empty')
    }
    foreach ($a in $allowed) {
        if (-not (Test-WgcIpv4Cidr -Cidr $a)) {
            $errors.Add("AllowedIPs entry $a is not an IPv4 CIDR")
        } elseif ($a -ceq '0.0.0.0/0') {
            # A full tunnel would also take the DNS and the endpoint route. Out of scope.
            $errors.Add('AllowedIPs must not contain 0.0.0.0/0')
        }
    }
    if ($Settings.PersistentKeepalive -cnotmatch '^\d{1,5}$' -or [int]$Settings.PersistentKeepalive -gt 65535) {
        $errors.Add('PersistentKeepalive must be 0-65535')
    }
    $namespaces = @(ConvertTo-WgcList -Text $Settings.NrptNamespaces)
    $servers = @(ConvertTo-WgcList -Text $Settings.NrptServers)
    foreach ($n in $namespaces) {
        if (-not (Test-WgcNamespace -Namespace $n)) { $errors.Add("NRPT namespace $n is not a DNS name") }
    }
    foreach ($s in $servers) {
        if (-not (Test-WgcIpv4 -Ip $s)) { $errors.Add("NRPT server $s is not an IPv4 address") }
    }
    if (($namespaces.Count -gt 0) -ne ($servers.Count -gt 0)) {
        $errors.Add('NrptNamespaces and NrptServers go together')
    }
    if (@('true', 'false') -cnotcontains $Settings.DisableGsaPrivateAccess) {
        $errors.Add('DisableGsaPrivateAccess must be true or false')
    }
    if ($Settings.LegacyPattern -ne '' -and -not (Test-WgcLegacyPattern -Pattern $Settings.LegacyPattern)) {
        $errors.Add('LegacyPattern must be lower case letters, digits, _ or -, with an optional trailing *')
    }
    return ,$errors
}

# Pure. Prepare needs every setting except the optional NRPT pair and LegacyPattern.
function Get-WgcPrepareErrors {
    param($Settings)
    $errors = [System.Collections.Generic.List[string]]::new()
    $optional = @('NrptNamespaces', 'NrptServers', 'LegacyPattern')
    foreach ($name in @($script:TenantFields.Keys)) {
        $value = [string]$Settings.$name
        if (Test-WgcUnreplaced -Value $value) {
            $errors.Add("$name is not substituted")
        } elseif ($value.Trim() -eq '' -and $optional -notcontains $name) {
            $errors.Add("$name is empty")
        }
    }
    if ($errors.Count -gt 0) {
        return ,$errors
    }
    foreach ($e in (Get-WgcSettingsErrors -Settings $Settings -NoAddress)) { $errors.Add($e) }
    if (-not (Test-WgcMapUrl -Url $Settings.MapUrl)) { $errors.Add('MapUrl must be an https URL without user info') }
    if (-not (Test-WgcMapKey -Xml $Settings.MapKey)) { $errors.Add('MapKey must be an RSA public key in .NET XML form') }
    foreach ($g in @(ConvertTo-WgcList -Text $Settings.TrustedGateways)) {
        if (-not (Test-WgcIpv4 -Ip $g)) { $errors.Add("TrustedGateways entry $g is not an IPv4 address") }
    }
    foreach ($m in @(ConvertTo-WgcList -Text $Settings.TrustedGatewayMacs)) {
        if ($m -cnotmatch '^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$') { $errors.Add("TrustedGatewayMacs entry $m is not a MAC address") }
    }
    return ,$errors
}

# Pure. Settings from tenant.json text, with the tunnel address given. $null when it does not parse.
function ConvertFrom-WgcTenantJson {
    param([AllowEmptyString()][string]$Text, [string]$Address = '')
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $doc = $Text | ConvertFrom-Json
    } catch {
        return $null
    }
    $settings = [ordered]@{ Address = $Address }
    foreach ($name in @($script:TenantFields.Keys)) {
        $p = $doc.PSObject.Properties[$script:TenantFields[$name]]
        $settings[$name] = if ($null -ne $p -and $null -ne $p.Value) { [string]$p.Value } else { '' }
    }
    return [pscustomobject]$settings
}

function ConvertTo-WgcTenantJson {
    param($Settings)
    $doc = [ordered]@{}
    foreach ($name in @($script:TenantFields.Keys)) { $doc[$script:TenantFields[$name]] = [string]$Settings.$name }
    return ($doc | ConvertTo-Json -Depth 2)
}

# Pure. Lower-case hex SHA-256 of the ASCII bytes of a text (the map key for a public key).
function Get-WgcSha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Test-WgcJsonInt {
    param($Value)
    return $Value -is [int] -or $Value -is [long]
}

# Pure. Verifies the signed map (RSA PKCS#1 v1.5, SHA-256) and returns this public key's entry.
# State is active, revoked, rotate, none, or invalid. Anything unexpected is invalid, so nothing changes.
function Get-WgcMapEntry {
    param([string]$MapText, [string]$MapKey, [string]$Tunnel, [int64]$LastSerial, [AllowEmptyString()][string]$PublicKey)
    $invalid = [pscustomobject]@{ State = 'invalid'; Address = $null; Serial = $null }
    try {
        $outer = $MapText | ConvertFrom-Json
        $payload = [Convert]::FromBase64String([string]$outer.payload)
        $sig = [Convert]::FromBase64String([string]$outer.sig)
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.FromXmlString($MapKey)
            if ($rsa.KeySize -lt 3072) {
                return $invalid
            }
            $ok = $rsa.VerifyData($payload, $sig, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally {
            $rsa.Dispose()
        }
        if (-not $ok) {
            return $invalid
        }
        $doc = [Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
        if (-not (Test-WgcJsonInt $doc.v) -or $doc.v -ne 1 -or [string]$doc.tunnel -cne $Tunnel -or -not (Test-WgcJsonInt $doc.serial) -or $doc.serial -lt $LastSerial) {
            return $invalid
        }
        $result = [pscustomobject]@{ State = 'none'; Address = $null; Serial = [int64]$doc.serial }
        if ([string]::IsNullOrEmpty($PublicKey) -or $null -eq $doc.entries) {
            return $result
        }
        $p = $doc.entries.PSObject.Properties[(Get-WgcSha256Hex -Text $PublicKey)]
        if ($null -eq $p) {
            return $result
        }
        $state = [string]$p.Value.state
        if (@('active', 'revoked', 'rotate') -cnotcontains $state) {
            return $invalid
        }
        if ($state -ceq 'active') {
            $address = [string]$p.Value.address
            if (-not (Test-WgcIpv4Cidr -Cidr $address) -or -not $address.EndsWith('/32')) {
                return $invalid
            }
            $result.Address = $address
        }
        $result.State = $state
        return $result
    } catch {
        return $invalid
    }
}

# Pure. No DNS line: name resolution is done with NRPT, which is deterministic on a split tunnel.
function Get-WgcConfigText {
    param([string]$PrivateKey, $Settings)
    $allowed = (@(ConvertTo-WgcList -Text $Settings.AllowedIPs) -join ', ')
    $lines = @(
        '[Interface]',
        "PrivateKey = $PrivateKey",
        "Address = $($Settings.Address)",
        '',
        '[Peer]',
        "PublicKey = $($Settings.ServerPublicKey)",
        "Endpoint = $($Settings.Endpoint)",
        "AllowedIPs = $allowed"
    )
    if ([int]$Settings.PersistentKeepalive -gt 0) {
        $lines += "PersistentKeepalive = $([int]$Settings.PersistentKeepalive)"
    }
    return (($lines -join "`r`n") + "`r`n")
}

# Pure. The tunnel address in a config, or ''.
function Get-WgcAddressFromConfig {
    param([AllowEmptyString()][string]$Text)
    $m = [regex]::Match([string]$Text, '(?m)^\s*Address\s*=\s*(\S+)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Pure. The existing key is kept so the server peer stays valid across runs.
function Get-WgcPrivateKeyFromConfig {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $m = [regex]::Match($Text, '(?m)^\s*PrivateKey\s*=\s*([A-Za-z0-9+/]{43}=)\s*$')
    if ($m.Success -and (Test-WgcKey -Key $m.Groups[1].Value)) {
        return $m.Groups[1].Value
    }
    return ''
}

# Pure. Which tagged rules to remove and which namespaces to add.
function Get-WgcNrptPlan {
    param(
        [object[]]$Existing = @(),
        [string[]]$Namespaces = @(),
        [string[]]$Servers = @(),
        [string]$Tag
    )
    $want = @{}
    foreach ($n in $Namespaces) { $want[$n.ToLowerInvariant()] = $true }
    $serverText = ($Servers -join ',')
    $remove = [System.Collections.Generic.List[object]]::new()
    $have = @{}
    foreach ($rule in $Existing) {
        if ([string]$rule.Comment -cne $Tag) {
            # Never touch a rule this package did not write.
            continue
        }
        $ns = @($rule.Namespace)[0].ToLowerInvariant()
        $same = $want.ContainsKey($ns) -and ((@($rule.NameServers) -join ',') -ceq $serverText) -and -not $have.ContainsKey($ns)
        if ($same) {
            $have[$ns] = $true
        } else {
            $remove.Add($rule)
        }
    }
    $add = @($Namespaces | Where-Object { -not $have.ContainsKey($_.ToLowerInvariant()) })
    return [pscustomobject]@{ Remove = @($remove); Add = $add }
}

function Test-WgcPinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    return $text -cnotmatch '^(.)\1{63}$'
}

function Test-WgcUrlHasUserInfo {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.IsAbsoluteUri -and -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

function Test-WgcCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    return -not [string]::IsNullOrWhiteSpace($CancelPath) -and (Test-Path -LiteralPath $CancelPath)
}

function Get-WgcProgramFiles {
    # ProgramW6432 is the native folder, also in a 32-bit process; ProgramFiles is then Program Files (x86).
    $root = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    return [IO.Path]::Combine($root, 'WireGuard')
}

function Get-WgcConfigRoot {
    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\ProgramData'
    }
    return [IO.Path]::Combine($root, 'Relian', 'WireGuard')
}

# ---- Side effects. Each is a script block so the tests replace it. ----

# The machine-wide value is the OS architecture even when this PowerShell runs x64-emulated on ARM64,
# where both process variables say AMD64.
$script:ReadNativeArch = {
    try {
        return [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch {
        return $null
    }
}

$script:GetArch = {
    foreach ($arch in @((& $script:ReadNativeArch), $env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE)) {
        if (-not [string]::IsNullOrWhiteSpace($arch)) { return [string]$arch }
    }
    return ''
}

$script:GetInstalledVersion = {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $names = @($props.PSObject.Properties.Name)
            if ($names -contains 'DisplayName' -and [string]$props.DisplayName -ceq 'WireGuard' -and $names -contains 'DisplayVersion') {
                return [string]$props.DisplayVersion
            }
        }
    }
    return ''
}

$script:DownloadFile = {
    param($Url, $Destination)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:GetFileSha256 = {
    param($Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# msiexec is waited on and never killed. DO_NOT_LAUNCH keeps the manager UI closed.
$script:InvokeMsiExec = {
    param($InstallerPath)
    $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $process = Start-Process -FilePath $exe -ArgumentList @('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

# Runs wg.exe with optional stdin and returns stdout. Output is never written to a log.
$script:InvokeWg = {
    param([string[]]$Arguments, [string]$StdIn = '')
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path (Get-WgcProgramFiles) 'wg.exe'
    $startInfo.Arguments = ($Arguments -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($startInfo)
    try {
        if ($StdIn -ne '') { $proc.StandardInput.Write($StdIn + "`n") }
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw 'wg.exe failed' }
        return ([string]$out.Result).Trim()
    } finally {
        $proc.Dispose()
    }
}

# Creates the folder with SYSTEM and Administrators only, before any file is written.
$script:EnsureSecureFolder = {
    param($Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'config folder is a reparse point' }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($id, 'FullControl', $inherit, 'None', 'Allow'))
    }
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
    # Files already there drop any explicit ACL and take only the folder's, so an older loose ACL cannot survive.
    if (@(Get-ChildItem -LiteralPath $Path -File -Force).Count -gt 0) {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        & $icacls (Join-Path $Path '*') '/reset' '/C' '/Q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not reset config file ACLs' }
    }
}

$script:ReadConfig = {
    param($Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [IO.File]::ReadAllText($Path)
}

# Write beside the target, then replace, so a half-written config never starts.
$script:WriteConfig = {
    param($Path, $Text)
    $tmp = "$Path.new"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

$script:GetService = {
    param($Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $null }
    return [pscustomobject]@{ Name = $svc.Name; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}

$script:InstallTunnelService = {
    param($ConfigPath)
    $exe = Join-Path (Get-WgcProgramFiles) 'wireguard.exe'
    $p = Start-Process -FilePath $exe -ArgumentList @('/installtunnelservice', ('"{0}"' -f $ConfigPath)) -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

$script:UninstallTunnelService = {
    param($TunnelName)
    $exe = Join-Path (Get-WgcProgramFiles) 'wireguard.exe'
    $p = Start-Process -FilePath $exe -ArgumentList @('/uninstalltunnelservice', $TunnelName) -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

$script:RestartService = {
    param($Name)
    Restart-Service -Name $Name -Force
}

$script:GetNrptRules = {
    return @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)
}

$script:AddNrptRule = {
    param($Namespace, [string[]]$Servers, $Comment)
    Add-DnsClientNrptRule -Namespace $Namespace -NameServers $Servers -Comment $Comment | Out-Null
}

$script:RemoveNrptRule = {
    param($Rule)
    Remove-DnsClientNrptRule -Name $Rule.Name -Force
}

# Loaded user hives only. A user who is not signed in keeps the default until the next run.
$script:SetGsaPrivateAccess = {
    param([bool]$Disabled)
    $count = 0
    foreach ($hive in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($hive.PSChildName -cnotmatch '^S-1-(5-21|12-1)-[0-9-]+$') { continue }
        $key = "Registry::HKEY_USERS\$($hive.PSChildName)\Software\Microsoft\Global Secure Access Client"
        if ($Disabled) {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser' -PropertyType DWord -Value 1 -Force | Out-Null
            $count++
        } elseif (Test-Path -LiteralPath $key) {
            $v = Get-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser' -ErrorAction SilentlyContinue
            if ($null -ne $v -and [int]$v.IsPrivateAccessDisabledByUser -eq 1) {
                Remove-ItemProperty -LiteralPath $key -Name 'IsPrivateAccessDisabledByUser'
                $count++
            }
        }
    }
    return $count
}

$script:GetLatestHandshake = {
    param($TunnelName)
    try {
        $text = & $script:InvokeWg -Arguments @('show', $TunnelName, 'latest-handshakes')
        $epoch = [int64](($text -split '\s+')[-1])
        if ($epoch -le 0) { return $null }
        return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch)
    } catch {
        return $null
    }
}

# Every WireGuardTunnel$* service with the config path from its command line.
$script:GetTunnelServices = {
    foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -Filter 'Name LIKE ''WireGuardTunnel$%''' -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match([string]$svc.PathName, '/tunnelservice\s+"([^"]+)"')
        $path = ''
        if ($m.Success) { $path = $m.Groups[1].Value }
        [pscustomobject]@{ Name = ([string]$svc.Name).Substring(16); ConfigPath = $path }
    }
}

$script:RemoveFile = {
    param($Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

$script:StageFiles = {
    param([string[]]$Sources, $Destination)
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    foreach ($source in $Sources) { Copy-Item -LiteralPath $source -Destination $Destination -Force }
}

# Runs the network guard script in this process. Returns its exit code.
$script:InvokeGuard = {
    param($ScriptPath, [hashtable]$Parameters)
    $global:LASTEXITCODE = 0
    $null = & $ScriptPath @Parameters
    return [int]$LASTEXITCODE
}

# Lets the guard stop a tunnel that was just installed on the office LAN.
$script:RunGuardTask = {
    Start-ScheduledTask -TaskPath '\Relian\' -TaskName 'Relian-WireGuardNetworkGuard'
}

# Fetches the signed map: HTTPS, no redirect, 20 s timeout, at most 1 MB.
$script:FetchMap = {
    param($Url)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try {
        $stream = $response.GetResponseStream()
        $limit = 1048576
        $buffer = New-Object byte[] ($limit + 1)
        $total = 0
        while ($total -lt $buffer.Length) {
            $n = $stream.Read($buffer, $total, $buffer.Length - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        if ($total -gt $limit) { throw 'map is over 1 MB' }
        return [Text.Encoding]::UTF8.GetString($buffer, 0, $total)
    } finally {
        $response.Dispose()
    }
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

# Retry only timeouts, connection and DNS failures, and HTTP 408, 429, 500, 502, 503, 504.
function Test-WgcDownloadIsTransient {
    param($Exception)
    $current = $Exception
    for ($guard = 0; $null -ne $current -and $guard -lt 8; $guard++) {
        $names = @($current.PSObject.Properties.Name)
        $status = $null
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            $status = $current.StatusCode
        } elseif ($names -contains 'Response' -and $null -ne $current.Response -and @($current.Response.PSObject.Properties.Name) -contains 'StatusCode') {
            $status = $current.Response.StatusCode
        }
        if ($null -ne $status) {
            try { $code = [int]$status } catch { $code = 0 }
            if ($code -ge 100 -and $code -le 599) {
                return @(408, 429, 500, 502, 503, 504) -contains $code
            }
        }
        if ($current -is [System.TimeoutException] -or $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and @('Timeout', 'NameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'KeepAliveFailure') -contains [string]$current.Status) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Save-WgcInstaller {
    param([string]$Url, [string]$Sha256, [string]$Destination)
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_.Exception
        }
        if ($null -eq $thrown) {
            if ((& $script:GetFileSha256 -Path $Destination) -ceq $Sha256) {
                return $true
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            # A hash mismatch is not retried.
            Write-WgcError 'hash mismatch for installer'
            return $false
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if (-not (Test-WgcDownloadIsTransient -Exception $thrown) -or $attempt -eq 3) {
            break
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
    }
    Write-WgcError 'download failed for installer'
    return $false
}

# The hash for this device's architecture, and the name of its URL field.
# The URL itself is read only after the empty-hash no-op.
function Get-WgcApplicablePin {
    param($Pins, [string]$Arch)
    if ($Arch -ceq 'ARM64') {
        return [pscustomobject]@{ UrlField = 'ArmUrl'; Sha256 = [string]$Pins.ArmSha256 }
    }
    return [pscustomobject]@{ UrlField = 'Url'; Sha256 = [string]$Pins.Sha256 }
}

function Read-WgcDeviceKey {
    param([string]$KeyPath, [AllowEmptyString()][string]$ConfigText)
    $key = ([string](& $script:ReadConfig -Path $KeyPath)).Trim()
    if (Test-WgcKey -Key $key) {
        return $key
    }
    return (Get-WgcPrivateKeyFromConfig -Text $ConfigText)
}

# The device key: <tunnel>.key, else the key in <tunnel>.conf, else a new one. <tunnel>.key ends up holding it.
function Get-WgcDeviceKey {
    param([string]$KeyPath, [AllowEmptyString()][string]$ConfigText)
    $stored = ([string](& $script:ReadConfig -Path $KeyPath)).Trim()
    if (Test-WgcKey -Key $stored) {
        return $stored
    }
    $key = Get-WgcPrivateKeyFromConfig -Text $ConfigText
    if ($key -eq '') {
        $key = ([string](& $script:InvokeWg -Arguments @('genkey'))).Trim()
        if (-not (Test-WgcKey -Key $key)) {
            Write-WgcError 'wg.exe genkey returned no key'
            return ''
        }
    }
    & $script:WriteConfig -Path $KeyPath -Text ($key + "`r`n")
    return $key
}

# Tunnels other than the managed one whose names match LegacyPattern.
function Get-WgcLegacyTunnels {
    param($Settings)
    if ([string]::IsNullOrEmpty($Settings.LegacyPattern)) {
        return @()
    }
    return @(@(& $script:GetTunnelServices) | Where-Object { [string]$_.Name -ne $Settings.TunnelName -and [string]$_.Name -like $Settings.LegacyPattern })
}

# Removes legacy tunnels only while the managed tunnel has a handshake under 180 seconds.
function Remove-WgcLegacyTunnels {
    param($Settings)
    $removed = [System.Collections.Generic.List[string]]::new()
    $legacy = @(Get-WgcLegacyTunnels -Settings $Settings)
    if ($legacy.Count -eq 0) {
        return @()
    }
    $age = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName
    if ($null -eq $age -or $age -ge 180) {
        return @()
    }
    foreach ($t in $legacy) {
        $code = [int](& $script:UninstallTunnelService -TunnelName $t.Name)
        if ($code -ne 0) {
            Write-WgcError "uninstalltunnelservice $($t.Name) failed with $code"
            continue
        }
        if ([string]$t.ConfigPath -match '\.conf(\.dpapi)?$') {
            & $script:RemoveFile -Path $t.ConfigPath
        }
        $removed.Add([string]$t.Name)
    }
    return $removed.ToArray()
}

# Fetches and verifies the map. The last accepted serial is saved only after a valid map.
function Get-WgcMapState {
    param($Settings, [AllowEmptyString()][string]$PublicKey)
    if (-not (Test-WgcMapUrl -Url $Settings.MapUrl) -or -not (Test-WgcMapKey -Xml $Settings.MapKey)) {
        return [pscustomobject]@{ State = 'invalid'; Address = $null; Serial = $null }
    }
    # Three attempts for a transient failure, one for anything else, as for the installer.
    $text = $null
    $delays = @(5, 20)
    for ($attempt = 1; $null -eq $text; $attempt++) {
        try {
            $text = [string](& $script:FetchMap -Url $Settings.MapUrl)
        } catch {
            if ($attempt -ge 3 -or -not (Test-WgcDownloadIsTransient -Exception $_.Exception)) {
                return [pscustomobject]@{ State = 'unavailable'; Address = $null; Serial = $null }
            }
            [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        }
    }
    $serialPath = [IO.Path]::Combine((Get-WgcConfigRoot), 'map-serial.txt')
    $last = [int64]0
    [void][int64]::TryParse(([string](& $script:ReadConfig -Path $serialPath)).Trim(), [ref]$last)
    $entry = Get-WgcMapEntry -MapText $text -MapKey $Settings.MapKey -Tunnel $Settings.TunnelName -LastSerial $last -PublicKey $PublicKey
    if ($entry.State -cne 'invalid' -and $entry.Serial -gt $last) {
        & $script:WriteConfig -Path $serialPath -Text ([string]$entry.Serial)
    }
    return $entry
}

function Get-WgcPublicKey {
    param([AllowEmptyString()][string]$PrivateKey)
    if ($PrivateKey -eq '') {
        return $null
    }
    return [string](& $script:InvokeWg -Arguments @('pubkey') -StdIn $PrivateKey)
}

# Pure. Detection exit code: 1 when the device must change to match its map entry.
function Get-WgcReportExitCode {
    param($Report, $Entry)
    if (@('revoked', 'rotate') -ccontains $Report.mapState) {
        return 1
    }
    if ($Report.mapState -cne 'active') {
        return 0
    }
    if ($Report.service -ceq 'Absent' -or $Report.address -cne $Entry.Address) {
        return 1
    }
    if (@($Report.legacyTunnels).Count -gt 0 -and $null -ne $Report.handshakeAge -and $Report.handshakeAge -lt 180) {
        return 1
    }
    return 0
}

function Limit-WgcText {
    param([string]$Text, [int]$Max)
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max)
}

# Detection for the Intune Remediation: one JSON line of at most 2048 characters, never a private key.
function Invoke-WgcReport {
    param($Settings)
    $report = [ordered]@{
        v = 1; tunnel = $Settings.TunnelName; publicKey = $null; address = $null; service = 'Absent'; handshakeAge = $null
        wgVersion = $null; onOfficeLan = $null; legacyTunnels = @(); mapState = 'none'; errors = @()
    }
    $entry = $null
    try {
        $folder = Get-WgcConfigRoot
        $report.wgVersion = Limit-WgcText -Text ([string](& $script:GetInstalledVersion)) -Max 32
        $config = [string](& $script:ReadConfig -Path ([IO.Path]::Combine($folder, "$($Settings.TunnelName).conf")))
        $key = Read-WgcDeviceKey -KeyPath ([IO.Path]::Combine($folder, "$($Settings.TunnelName).key")) -ConfigText $config
        $report.publicKey = Get-WgcPublicKey -PrivateKey $key
        $key = $null
        $address = Get-WgcAddressFromConfig -Text $config
        $config = $null
        if ($address -ne '') { $report.address = $address }
        $svc = & $script:GetService -Name ('WireGuardTunnel$' + $Settings.TunnelName)
        if ($null -ne $svc) {
            $report.service = if ($svc.Status -ceq 'Running') { 'Running' } else { 'Stopped' }
            $age = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName
            if ($null -ne $age) { $report.handshakeAge = [int64]$age }
        }
        $guardState = [string](& $script:ReadConfig -Path ([IO.Path]::Combine((Split-Path -Parent $folder), 'WireGuardNetworkGuard', 'state.json')))
        if ($guardState -ne '') {
            try {
                $p = ($guardState | ConvertFrom-Json).PSObject.Properties['onTrustedNetwork']
                if ($null -ne $p -and $p.Value -is [bool]) { $report.onOfficeLan = $p.Value }
            } catch {
                Write-WgcError 'guard state does not parse'
            }
        }
        $report.legacyTunnels = @(Get-WgcLegacyTunnels -Settings $Settings | Select-Object -First 20 | ForEach-Object { Limit-WgcText -Text ([string]$_.Name) -Max 40 })
        $entry = Get-WgcMapState -Settings $Settings -PublicKey ([string]$report.publicKey)
        $report.mapState = $entry.State
    } catch {
        Write-WgcError 'report failed'
    }
    $report.errors = @($script:WgcErrors | Select-Object -First 4 | ForEach-Object { Limit-WgcText -Text $_ -Max 120 })
    return [pscustomobject]@{ ExitCode = (Get-WgcReportExitCode -Report $report -Entry $entry); Report = $report }
}

# The package files Prepare stages: next to this script, in remediation\, or in the network guard's package folder.
function Find-WgcPackageFile {
    param([string]$Name)
    foreach ($dir in @($script:WgcRoot, [IO.Path]::Combine($script:WgcRoot, 'remediation'), [IO.Path]::Combine((Split-Path -Parent $script:WgcRoot), 'wireguard-network-guard'))) {
        $path = [IO.Path]::Combine($dir, $Name)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }
    return ''
}

function Install-WgcMsi {
    param([string]$PinVersion, [string]$CancelPath, $Pins, $Applicable, [string]$Installed, $Report)
    $pin = [version]$PinVersion
    $have = $null
    if ($Installed -ne '') { try { $have = [version]$Installed } catch { $have = $null } }
    if ($null -ne $have -and $have.CompareTo($pin) -ge 0) {
        return 0
    }
    $url = [string]$Pins.($Applicable.UrlField)
    $sha = $Applicable.Sha256
    if (Test-WgcCancelled -CancelPath $CancelPath) { return 130 }
    $cache = Join-Path ([IO.Path]::GetTempPath()) ('relian-wireguard-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    try {
        $msi = Join-Path $cache ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
        if (-not (Save-WgcInstaller -Url $url -Sha256 $sha -Destination $msi)) { return 1 }
        $code = [int](& $script:InvokeMsiExec -InstallerPath $msi)
        if ($code -ne 0 -and $code -ne 3010) {
            Write-WgcError "installer failed with $code"
            return 1
        }
    } finally {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Report.installedVersion = [string](& $script:GetInstalledVersion)
    return 0
}

function Invoke-WireGuardClientAction {
    param([string]$Action, [string]$PinVersion, [string]$CancelPath, $Settings, $Pins)

    $report = [ordered]@{
        mode = $Action; tunnelName = $Settings.TunnelName; address = $Settings.Address; publicKey = $null
        installedVersion = $null; service = $null; latestHandshakeSecondsAgo = $null
        nrptNamespaces = @(); gsaHivesChanged = 0; legacyRemoved = @(); mapState = $null; errors = $script:WgcErrors
    }
    $result = { param($Code) [pscustomobject]@{ ExitCode = [int]$Code; Report = $report } }

    # An empty pin, or an empty hash for this device's architecture, disables the package.
    $applicable = Get-WgcApplicablePin -Pins $Pins -Arch ([string](& $script:GetArch))
    if ([string]::IsNullOrWhiteSpace($PinVersion) -or [string]::IsNullOrWhiteSpace($applicable.Sha256)) {
        return (& $result 0)
    }
    if (@('Install', 'Update', 'Repair', 'Uninstall', 'Check', 'Prepare', 'Revoke', 'Rotate', 'Report', 'Apply') -cnotcontains $Action) {
        Write-WgcError "action $Action is not supported"
        return (& $result 1)
    }
    # Only actions that may download check the pin. Uninstall, Check, Revoke, Rotate and Report never download.
    if (@('Install', 'Update', 'Repair', 'Prepare', 'Apply') -ccontains $Action -and ((Test-WgcUrlHasUserInfo -Url ([string]$Pins.($applicable.UrlField))) -or -not (Test-WgcPinHash -Sha256 $applicable.Sha256))) {
        Write-WgcError 'invalid installer pin'
        return (& $result 1)
    }
    if ($Action -ceq 'Prepare') {
        $prepareErrors = Get-WgcPrepareErrors -Settings $Settings
        if ($prepareErrors.Count -gt 0) {
            foreach ($e in $prepareErrors) { Write-WgcError $e }
            return (& $result 1)
        }
    }
    if (-not (Test-WgcTunnelName -Name $Settings.TunnelName)) {
        Write-WgcError 'TunnelName must be lower case letters, digits, or dashes'
        return (& $result 1)
    }
    $folder = Get-WgcConfigRoot
    $configPath = [IO.Path]::Combine($folder, "$($Settings.TunnelName).conf")
    $keyPath = [IO.Path]::Combine($folder, "$($Settings.TunnelName).key")
    $tenantPath = [IO.Path]::Combine($folder, 'tenant.json')
    $binPath = [IO.Path]::Combine($folder, 'bin')
    $serviceName = 'WireGuardTunnel$' + $Settings.TunnelName
    $tag = $script:NrptTagPrefix + $Settings.TunnelName

    if ($Action -ceq 'Report') {
        return (Invoke-WgcReport -Settings $Settings)
    }
    if ($Action -ceq 'Apply') {
        # The map is fetched and verified again here. Detection output is not trusted.
        if (-not (Test-WgcMapUrl -Url $Settings.MapUrl) -or -not (Test-WgcMapKey -Xml $Settings.MapKey)) {
            Write-WgcError 'MapUrl or MapKey in tenant.json is not valid'
            return (& $result 1)
        }
        $key = Read-WgcDeviceKey -KeyPath $keyPath -ConfigText ([string](& $script:ReadConfig -Path $configPath))
        $entry = Get-WgcMapState -Settings $Settings -PublicKey ([string](Get-WgcPublicKey -PrivateKey $key))
        $key = $null
        $report.mapState = $entry.State
        switch -CaseSensitive ($entry.State) {
            'active' {
                $Action = 'Install'
                $Settings = $Settings.PSObject.Copy()
                $Settings.Address = $entry.Address
                $report.address = $entry.Address
            }
            'revoked' { $Action = 'Revoke' }
            'rotate' { $Action = 'Rotate' }
            default { return (& $result 0) }
        }
    }

    if ($Action -ceq 'Uninstall') {
        if ($null -ne (& $script:GetService -Name $serviceName)) {
            $code = [int](& $script:UninstallTunnelService -TunnelName $Settings.TunnelName)
            if ($code -ne 0) {
                Write-WgcError "uninstalltunnelservice failed with $code"
                return (& $result 1)
            }
        }
        $plan = Get-WgcNrptPlan -Existing @(& $script:GetNrptRules) -Namespaces @() -Servers @() -Tag $tag
        foreach ($rule in $plan.Remove) { & $script:RemoveNrptRule -Rule $rule }
        $report.gsaHivesChanged = [int](& $script:SetGsaPrivateAccess -Disabled $false)
        & $script:RemoveFile -Path $configPath
        # Undo Prepare. The key stays, so a reinstall keeps the same public key.
        if (([string](& $script:ReadConfig -Path $tenantPath)) -ne '') {
            $guard = [IO.Path]::Combine($binPath, 'Invoke-WireGuardNetworkGuard.ps1')
            if (Test-Path -LiteralPath $guard) {
                $code = [int](& $script:InvokeGuard -ScriptPath $guard -Parameters @{ Action = 'Uninstall' })
                if ($code -ne 0) {
                    # Keep bin\ and tenant.json so the next uninstall can retry the guard.
                    Write-WgcError "network guard uninstall failed with $code"
                    return (& $result 1)
                }
            }
            foreach ($path in @($binPath, $tenantPath, [IO.Path]::Combine($folder, 'map-serial.txt'))) { & $script:RemoveFile -Path $path }
        }
        return (& $result 0)
    }

    if ($Action -ceq 'Revoke' -or $Action -ceq 'Rotate') {
        if ($null -ne (& $script:GetService -Name $serviceName)) {
            $code = [int](& $script:UninstallTunnelService -TunnelName $Settings.TunnelName)
            if ($code -ne 0) {
                Write-WgcError "uninstalltunnelservice failed with $code"
                return (& $result 1)
            }
        }
        if ($Action -ceq 'Revoke') {
            $plan = Get-WgcNrptPlan -Existing @(& $script:GetNrptRules) -Namespaces @() -Servers @() -Tag $tag
            foreach ($rule in $plan.Remove) { & $script:RemoveNrptRule -Rule $rule }
        }
        & $script:RemoveFile -Path $configPath
        & $script:RemoveFile -Path $keyPath
        & $script:EnsureSecureFolder -Path $folder
        $key = Get-WgcDeviceKey -KeyPath $keyPath -ConfigText ''
        if ($key -eq '') { return (& $result 1) }
        $report.publicKey = Get-WgcPublicKey -PrivateKey $key
        $key = $null
        return (& $result 0)
    }

    $installed = [string](& $script:GetInstalledVersion)
    $report.installedVersion = $installed
    if ($Action -ceq 'Check') {
        $report.service = & $script:GetService -Name $serviceName
        $key = Read-WgcDeviceKey -KeyPath $keyPath -ConfigText ([string](& $script:ReadConfig -Path $configPath))
        $report.publicKey = Get-WgcPublicKey -PrivateKey $key
        $key = $null
        $report.nrptNamespaces = @(@(& $script:GetNrptRules) | Where-Object { [string]$_.Comment -ceq $tag } | ForEach-Object { @($_.Namespace)[0] })
        $report.latestHandshakeSecondsAgo = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName
        return (& $result 0)
    }

    if ($Action -cne 'Prepare') {
        $settingErrors = Get-WgcSettingsErrors -Settings $Settings
        if ($settingErrors.Count -gt 0) {
            foreach ($e in $settingErrors) { Write-WgcError $e }
            return (& $result 1)
        }
    }

    # 1. Installer, when missing or below the pin.
    $code = Install-WgcMsi -PinVersion $PinVersion -CancelPath $CancelPath -Pins $Pins -Applicable $applicable -Installed $installed -Report $report
    if ($code -ne 0) { return (& $result $code) }

    # 2. Folder ACL first, then the key and the config.
    & $script:EnsureSecureFolder -Path $folder
    $current = [string](& $script:ReadConfig -Path $configPath)
    $privateKey = Get-WgcDeviceKey -KeyPath $keyPath -ConfigText $current
    if ($privateKey -eq '') { return (& $result 1) }
    $report.publicKey = Get-WgcPublicKey -PrivateKey $privateKey

    if ($Action -ceq 'Prepare') {
        # Key only: no tunnel until the map gives this key an address.
        $privateKey = $null
        & $script:WriteConfig -Path $tenantPath -Text (ConvertTo-WgcTenantJson -Settings $Settings)
        $sources = @($script:StagedFiles | ForEach-Object { Find-WgcPackageFile -Name $_ })
        if ($sources -contains '') {
            Write-WgcError 'a package file to stage is missing'
            return (& $result 1)
        }
        & $script:StageFiles -Sources $sources -Destination $binPath
        $guardParameters = @{ Action = 'Install'; TrustedGateways = $Settings.TrustedGateways; TrustedGatewayMacs = $Settings.TrustedGatewayMacs }
        $code = [int](& $script:InvokeGuard -ScriptPath ([IO.Path]::Combine($binPath, 'Invoke-WireGuardNetworkGuard.ps1')) -Parameters $guardParameters)
        if ($code -ne 0) {
            Write-WgcError "network guard install failed with $code"
            return (& $result 1)
        }
        return (& $result 0)
    }

    $wanted = Get-WgcConfigText -PrivateKey $privateKey -Settings $Settings
    $privateKey = $null
    $changed = $wanted -cne $current
    if ($changed) {
        & $script:WriteConfig -Path $configPath -Text $wanted
    }
    $wanted = $null
    $current = $null

    # 3. Tunnel service.
    $svc = & $script:GetService -Name $serviceName
    if ($null -eq $svc) {
        $code = [int](& $script:InstallTunnelService -ConfigPath $configPath)
        if ($code -ne 0) {
            Write-WgcError "installtunnelservice failed with $code"
            return (& $result 1)
        }
        # A new tunnel starts running. The guard Prepare installed stops it again if this is the office LAN.
        if (([string](& $script:ReadConfig -Path $tenantPath)) -ne '') {
            try { & $script:RunGuardTask } catch { Write-WgcError 'could not start the network guard task' }
        }
    } elseif ($changed -and $svc.Status -ceq 'Running') {
        # Only a running tunnel is restarted. A tunnel the network guard stopped stays stopped.
        & $script:RestartService -Name $serviceName
    }
    $report.service = & $script:GetService -Name $serviceName

    # 4. NRPT rules carrying this package's tag.
    $namespaces = @(ConvertTo-WgcList -Text $Settings.NrptNamespaces)
    $servers = @(ConvertTo-WgcList -Text $Settings.NrptServers)
    $plan = Get-WgcNrptPlan -Existing @(& $script:GetNrptRules) -Namespaces $namespaces -Servers $servers -Tag $tag
    foreach ($rule in $plan.Remove) { & $script:RemoveNrptRule -Rule $rule }
    foreach ($n in $plan.Add) { & $script:AddNrptRule -Namespace $n -Servers $servers -Comment $tag }
    $report.nrptNamespaces = $namespaces

    # 5. GSA Private Access, only when asked.
    if ($Settings.DisableGsaPrivateAccess -ceq 'true') {
        $report.gsaHivesChanged = [int](& $script:SetGsaPrivateAccess -Disabled $true)
    }
    $report.latestHandshakeSecondsAgo = & $script:GetLatestHandshake -TunnelName $Settings.TunnelName

    # 6. Legacy tunnels, once the managed tunnel has a recent handshake.
    $report.legacyRemoved = @(Remove-WgcLegacyTunnels -Settings $Settings)
    return (& $result 0)
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$pins = [pscustomobject]@{ Url = $InstallerUrl; Sha256 = $InstallerSha256; ArmUrl = $ArmInstallerUrl; ArmSha256 = $ArmInstallerSha256 }
# An empty hash for this device's architecture is a no-op before parameter validation.
if ([string]::IsNullOrWhiteSpace((Get-WgcApplicablePin -Pins $pins -Arch ([string](& $script:GetArch))).Sha256)) {
    exit 0
}
foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

$runAction = $Action
if ($Mode -ceq 'Check') {
    $runAction = 'Check'
}
$settings = [pscustomobject]@{
    TunnelName = $TunnelName; Address = $Address; ServerPublicKey = $ServerPublicKey; Endpoint = $Endpoint
    AllowedIPs = $AllowedIPs; PersistentKeepalive = $PersistentKeepalive; NrptNamespaces = $NrptNamespaces
    NrptServers = $NrptServers; DisableGsaPrivateAccess = $DisableGsaPrivateAccess; MapUrl = $MapUrl; MapKey = $MapKey
    LegacyPattern = $LegacyPattern; TrustedGateways = $TrustedGateways; TrustedGatewayMacs = $TrustedGatewayMacs
}
# Without a TunnelName, every action but Prepare takes its settings from the tenant.json that Prepare wrote.
if ($TunnelName -eq '' -and $runAction -cne 'Prepare') {
    $fromTenant = ConvertFrom-WgcTenantJson -Text ([string](& $script:ReadConfig -Path ([IO.Path]::Combine((Get-WgcConfigRoot), 'tenant.json')))) -Address $Address
    if ($null -ne $fromTenant) { $settings = $fromTenant }
}
try {
    $out = Invoke-WireGuardClientAction -Action $runAction -PinVersion $PinVersion -CancelPath $CancelPath -Settings $settings -Pins $pins
    $code = $out.ExitCode
    $report = $out.Report
} catch {
    # The exception text could quote a config line. Do not print it.
    [Console]::Error.WriteLine('WireGuard client package failed')
    $code = 1
    $report = [ordered]@{ mode = $runAction; errors = @('unhandled error') }
}
[Console]::Out.WriteLine(($report | ConvertTo-Json -Compress -Depth 4))
exit $code
