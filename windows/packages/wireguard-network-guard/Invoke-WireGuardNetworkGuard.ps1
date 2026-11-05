<#
.SYNOPSIS
    Network-aware guard for Windows WireGuard tunnel services (WireGuardTunnel$*).
    Stops matching WireGuard tunnel services when the device connects to a trusted
    office network and starts them again when the device moves to an external network.

.DESCRIPTION
    WireGuard for Windows has no built-in On-Demand or Trusted Network Detection.
    When a laptop runs a WireGuardTunnel$<name> Windows service on an office VLAN,
    WireGuard's /24 AllowedIPs routes override the physical adapter's default route
    (0.0.0.0/0) or connected route (metric 256 vs metric 0), sending local office
    traffic into the VPN tunnel.

    Invoke-WireGuardNetworkGuard.ps1 supports four modes via -Action (or -DeploymentType):
    - Install (also Update, Repair, Reinstall): Validates the trusted network rules,
      writes the configuration and a local copy of this script to
      %ProgramData%\Relian\WireGuardNetworkGuard (hardened to SYSTEM and Administrators),
      registers the SYSTEM scheduled task \Relian\Relian-WireGuardNetworkGuard triggered
      at boot, wake, and Microsoft-Windows-NetworkProfile/Operational events 10000/10001,
      and runs an immediate evaluation pass.
    - Evaluate: Loads the saved configuration (or uses inline parameters), checks all
      active physical network adapters against the trusted gateway IP+MAC rules (re-probing
      stale or incomplete ARP entries before trusting a cached neighbor MAC) and optional
      DomainAuthenticated / DNS suffix rules, and stops or starts matching WireGuardTunnel$*
      services accordingly.
    - Check: Read-only evaluation that reports whether the device is on a trusted network
      and which WireGuardTunnel$* services would be stopped or started, without changing
      services, files, or scheduled tasks.
    - Uninstall: Unregisters the scheduled task, restarts any WireGuardTunnel$* service
      stopped by the guard (or configured as Automatic), and removes the install directory.

    Can be invoked directly with parameters or through Invoke-RelianRunner.ps1 via
    base64-encoded JSON in -PackageArguments.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$TrustedGateways = '',
    [string]$TrustedGatewayMacs = '',
    [string]$TunnelPattern = 'WireGuardTunnel$*',
    [string]$TrustDomainAuthenticated = 'false',
    [string]$TrustedDnsSuffixes = '',
    [string]$AllowGatewayIpOnly = 'false',
    [string]$ManageOffNetwork = 'true',
    [string]$TaskName = 'Relian-WireGuardNetworkGuard',
    [string]$InstallRoot = '',
    [string]$SourceScriptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WgTaskPath = '\Relian\'
$script:WgSourceScriptPath = $PSCommandPath

function Write-WgStatus {
    param([string]$Message, [string]$Level = 'INFO')
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        return
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$stamp] [$Level] [wireguard-network-guard] $Message"
}

function Limit-WgText {
    param([string]$Text, [int]$MaxLength = 180)
    if ($null -eq $Text) { return $null }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength)
}

function Get-WgDefaultInstallRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    return (Join-Path (Join-Path $programData 'Relian') 'WireGuardNetworkGuard')
}

function Test-WgNoReparsePoint {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $cur = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($cur)
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and $cur.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        if (Test-Path -LiteralPath $cur) {
            $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
            if (([int64]$item.Attributes -band [int64][IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) {
            break
        }
        $cur = $parent
    }
    return $true
}

# Normalizes a MAC address (00:53:00:11:22:33, 00-53-00-11-22-33, 0053.0011.2233, or 12 hex chars)
# to uppercase XX-XX-XX-XX-XX-XX. Returns $null when invalid, all-zero, or broadcast.
function ConvertTo-WgCanonicalMac {
    param([AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $trimmed = $Mac.Trim()
    $hex = ''
    if ($trimmed -match '^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$') {
        $hex = ($trimmed -replace '[:-]', '').ToUpperInvariant()
    } elseif ($trimmed -match '^[0-9A-Fa-f]{4}(\.[0-9A-Fa-f]{4}){2}$') {
        $hex = ($trimmed -replace '\.', '').ToUpperInvariant()
    } elseif ($trimmed -match '^[0-9A-Fa-f]{12}$') {
        $hex = $trimmed.ToUpperInvariant()
    } else {
        return $null
    }
    if ($hex -eq '000000000000' -or $hex -eq 'FFFFFFFFFFFF') {
        return $null
    }
    $bytes = for ($i = 0; $i -lt 12; $i += 2) { $hex.Substring($i, 2) }
    return ($bytes -join '-')
}

function Test-WgGatewayIpv4 {
    param([AllowEmptyString()][string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $trimmed = $Ip.Trim()
    if ($trimmed -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($trimmed, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $parsed.GetAddressBytes()
    # Reject 0.x.x.x, 127.x.x.x (loopback), 169.254.x.x (APIPA), and >= 224.0.0.0 (multicast/reserved/broadcast).
    if ($b[0] -eq 0 -or $b[0] -eq 127 -or $b[0] -ge 224) { return $false }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
    return $true
}

# Parses TrustedGateways and TrustedGatewayMacs into normalized rule objects:
# @{ ip = '192.0.2.1'; macs = @('00-53-00-11-22-33') }
function ConvertFrom-WgGatewayRules {
    param(
        [AllowEmptyString()][string]$TrustedGateways = '',
        [AllowEmptyString()][string]$TrustedGatewayMacs = '',
        [switch]$AllowGatewayIpOnly
    )
    $sharedMacs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($TrustedGatewayMacs)) {
        foreach ($token in ($TrustedGatewayMacs -split '[,;|]')) {
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            $canon = ConvertTo-WgCanonicalMac -Mac $token
            if ($null -eq $canon) {
                throw "invalid MAC address '$($token.Trim())' in TrustedGatewayMacs."
            }
            if (-not $sharedMacs.Contains($canon)) {
                [void]$sharedMacs.Add($canon)
            }
        }
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($TrustedGateways)) {
        return $rules.ToArray()
    }

    $byIp = @{}
    foreach ($entry in ($TrustedGateways -split '[,;]')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $raw = $entry.Trim()
        $ipPart = $raw
        $macPart = ''
        $sepIdx = $raw.IndexOfAny([char[]]'=@')
        if ($sepIdx -ge 0) {
            $ipPart = $raw.Substring(0, $sepIdx).Trim()
            $macPart = $raw.Substring($sepIdx + 1).Trim()
        }
        if (-not (Test-WgGatewayIpv4 -Ip $ipPart)) {
            throw "invalid gateway IPv4 '$ipPart' in TrustedGateways."
        }
        $macList = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($macPart)) {
            foreach ($m in ($macPart -split '[|/]')) {
                if ([string]::IsNullOrWhiteSpace($m)) { continue }
                $canon = ConvertTo-WgCanonicalMac -Mac $m
                if ($null -eq $canon) {
                    throw "invalid gateway MAC '$($m.Trim())' for gateway '$ipPart'."
                }
                if (-not $macList.Contains($canon)) {
                    [void]$macList.Add($canon)
                }
            }
        } else {
            foreach ($sm in $sharedMacs) {
                if (-not $macList.Contains($sm)) {
                    [void]$macList.Add($sm)
                }
            }
        }

        if ($macList.Count -eq 0 -and -not $AllowGatewayIpOnly) {
            throw "gateway '$ipPart' requires a trusted MAC (pass IP=MAC in TrustedGateways, set TrustedGatewayMacs, or set AllowGatewayIpOnly to true)."
        }

        if ($byIp.ContainsKey($ipPart)) {
            $existing = $byIp[$ipPart]
            foreach ($m in $macList) {
                if ($existing.macs -notcontains $m) {
                    $existing.macs += $m
                }
            }
        } else {
            $ruleObj = [ordered]@{
                ip   = $ipPart
                macs = @($macList.ToArray())
            }
            $byIp[$ipPart] = $ruleObj
            [void]$rules.Add($ruleObj)
        }
    }

    return $rules.ToArray()
}

function ConvertFrom-WgTunnelPatterns {
    param([AllowEmptyString()][string]$TunnelPattern = 'WireGuardTunnel$*')
    $raw = if ([string]::IsNullOrWhiteSpace($TunnelPattern)) { 'WireGuardTunnel$*' } else { $TunnelPattern }
    $patterns = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ($raw -split '[,;]')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $p = $part.Trim()
        if ($p -notmatch '(?i)^WireGuardTunnel\$[A-Za-z0-9_.*-]+$') {
            throw "TunnelPattern '$p' must start with 'WireGuardTunnel$' and contain only [A-Za-z0-9_.*-]."
        }
        if (-not $patterns.Contains($p)) {
            [void]$patterns.Add($p)
        }
    }
    if ($patterns.Count -eq 0) {
        throw 'TunnelPattern must contain at least one WireGuardTunnel$ pattern.'
    }
    return $patterns.ToArray()
}

function ConvertFrom-WgDnsSuffixes {
    param([AllowEmptyString()][string]$TrustedDnsSuffixes = '')
    $suffixes = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($TrustedDnsSuffixes)) {
        return $suffixes.ToArray()
    }
    foreach ($part in ($TrustedDnsSuffixes -split '[,;]')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $s = $part.Trim().TrimStart('.').ToLowerInvariant()
        if ($s -notmatch '^[a-z0-9][a-z0-9.-]{0,251}[a-z0-9]$') {
            throw "invalid DNS suffix '$part' in TrustedDnsSuffixes."
        }
        if (-not $suffixes.Contains($s)) {
            [void]$suffixes.Add($s)
        }
    }
    return $suffixes.ToArray()
}

function ConvertTo-WgBool {
    param([AllowEmptyString()][string]$Value, [bool]$Default, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -eq 'true' -or $v -eq '1') { return $true }
    if ($v -eq 'false' -or $v -eq '0') { return $false }
    throw "$Name must be true or false."
}

function Get-WgConfigPath {
    param([string]$Root)
    return (Join-Path $Root 'config.json')
}

function Get-WgStatePath {
    param([string]$Root)
    return (Join-Path $Root 'state.json')
}

function Get-WgScriptCopyPath {
    param([string]$Root)
    return (Join-Path $Root 'Invoke-WireGuardNetworkGuard.ps1')
}

function Read-WgSavedConfig {
    param([string]$Root)
    $path = Get-WgConfigPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        throw "configuration file not found at $path"
    }
    if (-not (Test-WgNoReparsePoint -Path $path)) {
        throw "refusing reparse point at $path"
    }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $doc = $raw | ConvertFrom-Json
    if ($null -eq $doc) {
        throw 'saved config.json is empty'
    }
    $allowIpOnly = [bool]($null -ne $doc.PSObject.Properties['allowGatewayIpOnly'] -and $doc.allowGatewayIpOnly)
    $trustDomain = [bool]($null -ne $doc.PSObject.Properties['trustDomainAuthenticated'] -and $doc.trustDomainAuthenticated)
    $gateways = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $doc.PSObject.Properties['trustedGateways'] -and $null -ne $doc.trustedGateways) {
        foreach ($g in @($doc.trustedGateways)) {
            if ($null -eq $g) { continue }
            $ip = [string]$g.ip
            if (-not (Test-WgGatewayIpv4 -Ip $ip)) {
                throw "invalid gateway IPv4 '$ip' in saved config.json"
            }
            $macs = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $g.PSObject.Properties['macs'] -and $null -ne $g.macs) {
                foreach ($m in @($g.macs)) {
                    if ([string]::IsNullOrWhiteSpace([string]$m)) { continue }
                    $canon = ConvertTo-WgCanonicalMac -Mac ([string]$m)
                    if ($null -eq $canon) {
                        throw "invalid MAC '$m' in saved config.json"
                    }
                    [void]$macs.Add($canon)
                }
            }
            if ($macs.Count -eq 0 -and -not $allowIpOnly) {
                throw "gateway '$ip' in saved config.json has no MAC and allowGatewayIpOnly is false"
            }
            [void]$gateways.Add([ordered]@{ ip = $ip; macs = @($macs.ToArray()) })
        }
    }
    if ($gateways.Count -eq 0 -and -not $trustDomain) {
        throw 'saved config.json contains no trusted network rules'
    }
    $patterns = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $doc.PSObject.Properties['tunnelPatterns'] -and $null -ne $doc.tunnelPatterns) {
        foreach ($p in @($doc.tunnelPatterns)) {
            foreach ($v in @(ConvertFrom-WgTunnelPatterns -TunnelPattern ([string]$p))) {
                if (-not $patterns.Contains($v)) { [void]$patterns.Add($v) }
            }
        }
    }
    if ($patterns.Count -eq 0) {
        [void]$patterns.Add('WireGuardTunnel$*')
    }
    $suffixes = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $doc.PSObject.Properties['trustedDnsSuffixes'] -and $null -ne $doc.trustedDnsSuffixes) {
        foreach ($s in @($doc.trustedDnsSuffixes)) {
            foreach ($v in @(ConvertFrom-WgDnsSuffixes -TrustedDnsSuffixes ([string]$s))) {
                if (-not $suffixes.Contains($v)) { [void]$suffixes.Add($v) }
            }
        }
    }
    $taskName = if ($null -ne $doc.PSObject.Properties['taskName'] -and -not [string]::IsNullOrWhiteSpace([string]$doc.taskName)) {
        [string]$doc.taskName
    } else {
        'Relian-WireGuardNetworkGuard'
    }
    if ($taskName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw 'invalid taskName in saved config.json'
    }
    return [ordered]@{
        trustedGateways          = @($gateways.ToArray())
        tunnelPatterns           = @($patterns.ToArray())
        trustDomainAuthenticated = $trustDomain
        trustedDnsSuffixes       = @($suffixes.ToArray())
        allowGatewayIpOnly       = $allowIpOnly
        manageOffNetwork         = $(if ($null -ne $doc.PSObject.Properties['manageOffNetwork']) { [bool]$doc.manageOffNetwork } else { $true })
        taskName                 = $taskName
    }
}

function Get-WgOptions {
    param(
        [string]$DeploymentType = '',
        [string]$Action = '',
        [string]$TrustedGateways = '',
        [string]$TrustedGatewayMacs = '',
        [string]$TunnelPattern = 'WireGuardTunnel$*',
        [string]$TrustDomainAuthenticated = 'false',
        [string]$TrustedDnsSuffixes = '',
        [string]$AllowGatewayIpOnly = 'false',
        [string]$ManageOffNetwork = 'true',
        [string]$TaskName = 'Relian-WireGuardNetworkGuard',
        [string]$InstallRoot = '',
        [string]$SourceScriptPath = ''
    )
    $effectiveAction = if (-not [string]::IsNullOrWhiteSpace($Action)) {
        $Action.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($DeploymentType)) {
        $DeploymentType.Trim()
    } else {
        'Install'
    }
    if ($DeploymentType -eq 'Uninstall') {
        $effectiveAction = 'Uninstall'
    }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall', 'Evaluate', 'Check') -notcontains $effectiveAction) {
        throw 'Action must be Install, Update, Repair, Reinstall, Uninstall, Evaluate, or Check.'
    }

    $root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) { Get-WgDefaultInstallRoot } else { [IO.Path]::GetFullPath($InstallRoot) }
    $srcPath = if (-not [string]::IsNullOrWhiteSpace($SourceScriptPath)) { $SourceScriptPath } else { $script:WgSourceScriptPath }
    $cleanTaskName = if ([string]::IsNullOrWhiteSpace($TaskName)) { 'Relian-WireGuardNetworkGuard' } else { $TaskName.Trim() }
    if ($cleanTaskName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw 'TaskName must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$.'
    }

    $mode = switch ($effectiveAction) {
        'Uninstall' { 'uninstall' }
        'Evaluate'  { 'evaluate' }
        'Check'     { 'check' }
        default     { 'install' }
    }

    if ($mode -eq 'uninstall') {
        $patterns = @(ConvertFrom-WgTunnelPatterns -TunnelPattern $TunnelPattern)
        return [ordered]@{
            mode                     = 'uninstall'
            installRoot              = $root
            sourceScriptPath         = $srcPath
            taskName                 = $cleanTaskName
            tunnelPatterns           = $patterns
            trustedGateways          = @()
            trustDomainAuthenticated = $false
            trustedDnsSuffixes       = @()
            allowGatewayIpOnly       = $false
            manageOffNetwork         = $true
        }
    }

    $allowIpOnly = ConvertTo-WgBool -Value $AllowGatewayIpOnly -Default $false -Name 'AllowGatewayIpOnly'
    $trustDomain = ConvertTo-WgBool -Value $TrustDomainAuthenticated -Default $false -Name 'TrustDomainAuthenticated'
    $manageOff = ConvertTo-WgBool -Value $ManageOffNetwork -Default $true -Name 'ManageOffNetwork'

    # Evaluate or Check without inline criteria loads saved config.json when present.
    $hasInlineCriteria = (-not [string]::IsNullOrWhiteSpace($TrustedGateways)) -or $trustDomain
    if (($mode -eq 'evaluate' -or $mode -eq 'check') -and -not $hasInlineCriteria) {
        $saved = Read-WgSavedConfig -Root $root
        return [ordered]@{
            mode                     = $mode
            installRoot              = $root
            sourceScriptPath         = $srcPath
            taskName                 = $saved.taskName
            tunnelPatterns           = $saved.tunnelPatterns
            trustedGateways          = $saved.trustedGateways
            trustDomainAuthenticated = $saved.trustDomainAuthenticated
            trustedDnsSuffixes       = $saved.trustedDnsSuffixes
            allowGatewayIpOnly       = $saved.allowGatewayIpOnly
            manageOffNetwork         = $saved.manageOffNetwork
        }
    }

    $gatewayRules = @(ConvertFrom-WgGatewayRules -TrustedGateways $TrustedGateways -TrustedGatewayMacs $TrustedGatewayMacs -AllowGatewayIpOnly:$allowIpOnly)
    $patterns = @(ConvertFrom-WgTunnelPatterns -TunnelPattern $TunnelPattern)
    $suffixes = @(ConvertFrom-WgDnsSuffixes -TrustedDnsSuffixes $TrustedDnsSuffixes)

    if ($gatewayRules.Count -eq 0 -and -not $trustDomain) {
        throw 'At least one trusted network rule is required (pass TrustedGateways or set TrustDomainAuthenticated to true).'
    }

    return [ordered]@{
        mode                     = $mode
        installRoot              = $root
        sourceScriptPath         = $srcPath
        taskName                 = $cleanTaskName
        tunnelPatterns           = $patterns
        trustedGateways          = $gatewayRules
        trustDomainAuthenticated = $trustDomain
        trustedDnsSuffixes       = $suffixes
        allowGatewayIpOnly       = $allowIpOnly
        manageOffNetwork         = $manageOff
    }
}

# Scriptblock seams for unit tests (no network or service calls when mocked).
$script:WgGetPhysicalGateways = {
    $results = [System.Collections.Generic.List[object]]::new()
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })
    if ($routes.Count -eq 0) {
        return $results.ToArray()
    }
    $adapters = @{}
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        if ($null -ne $a.PSObject.Properties['HardwareInterface'] -and -not [bool]$a.HardwareInterface) { continue }
        if ($null -ne $a.PSObject.Properties['Virtual'] -and [bool]$a.Virtual) { continue }
        $adapters[[int]$a.ifIndex] = $a
    }
    $profiles = @{}
    foreach ($p in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        $profiles[[int]$p.InterfaceIndex] = $p
    }
    $dnsClients = @{}
    foreach ($d in @(Get-DnsClient -ErrorAction SilentlyContinue)) {
        $dnsClients[[int]$d.InterfaceIndex] = $d
    }

    foreach ($route in $routes) {
        $ifIndex = [int]$route.InterfaceIndex
        if (-not $adapters.ContainsKey($ifIndex)) { continue }
        $adapter = $adapters[$ifIndex]
        if ([string]$adapter.Status -ne 'Up') { continue }
        $desc = [string]$adapter.InterfaceDescription
        $alias = [string]$route.InterfaceAlias
        if ([string]::IsNullOrWhiteSpace($alias)) {
            $alias = [string]$adapter.Name
        }
        # Exclude WireGuard / Wintun / loopback / virtual tunnel interfaces.
        if ($alias -match '(?i)^(WireGuard|wg|Loopback)' -or $desc -match '(?i)(WireGuard|Wintun)') {
            continue
        }
        $category = ''
        if ($profiles.ContainsKey($ifIndex)) {
            $category = [string]$profiles[$ifIndex].NetworkCategory
        }
        $suffix = ''
        if ($dnsClients.ContainsKey($ifIndex)) {
            $suffix = [string]$dnsClients[$ifIndex].ConnectionSpecificSuffix
        }
        [void]$results.Add([pscustomobject]@{
            InterfaceIndex       = $ifIndex
            InterfaceAlias       = $alias
            InterfaceDescription = $desc
            GatewayIp            = [string]$route.NextHop
            NetworkCategory      = $category
            DnsSuffix            = $suffix
        })
    }
    return $results.ToArray()
}

$script:WgGetNeighbor = {
    param([int]$InterfaceIndex, [string]$IPAddress)
    $n = @(Get-NetNeighbor -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($n.Count -eq 0 -or $null -eq $n[0]) { return $null }
    return [pscustomobject]@{
        State            = [string]$n[0].State
        LinkLayerAddress = [string]$n[0].LinkLayerAddress
    }
}

$script:WgProbeGateway = {
    param([int]$InterfaceIndex, [string]$IPAddress)
    # Force Layer-2 ARP resolution on the specific physical InterfaceIndex even when a running
    # WireGuard tunnel currently owns a lower-metric route for the gateway's subnet:
    # 1. Bind a UDP socket with IP_UNICAST_IF (option 31) and the adapter's source IPv4 to InterfaceIndex.
    # 2. Invoke iphlpapi.dll SendARP using the physical adapter's source IPv4 so Windows sends an
    #    ARP request directly on that interface and waits for the reply.
    try {
        $srcIpObj = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1)
        $dstIp = [System.Net.IPAddress]::Parse($IPAddress)
        $udp = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp
        )
        try {
            if ($srcIpObj.Count -gt 0 -and $null -ne $srcIpObj[0].IPAddress) {
                $srcIp = [System.Net.IPAddress]::Parse([string]$srcIpObj[0].IPAddress)
                $udp.Bind([System.Net.IPEndPoint]::new($srcIp, 0))
            }
            $ifNetOrder = [System.Net.IPAddress]::HostToNetworkOrder([int]$InterfaceIndex)
            $udp.SetSocketOption(
                [System.Net.Sockets.SocketOptionLevel]::IP,
                [System.Net.Sockets.SocketOptionName]31,
                [BitConverter]::GetBytes($ifNetOrder)
            )
            $null = $udp.SendTo([byte[]]@(0), [System.Net.IPEndPoint]::new($dstIp, 33434))
        } finally {
            $udp.Dispose()
        }

        if (-not ('Relian.WgArpNative' -as [type])) {
            Add-Type -Namespace 'Relian' -Name 'WgArpNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("iphlpapi.dll", ExactSpelling = true)]
public static extern int SendARP(uint DestIP, uint SrcIP, byte[] pMacAddr, ref int PhyAddrLen);
'@ -ErrorAction SilentlyContinue
        }
        if ('Relian.WgArpNative' -as [type]) {
            $dstUint = [BitConverter]::ToUInt32($dstIp.GetAddressBytes(), 0)
            $srcUint = [uint32]0
            if ($srcIpObj.Count -gt 0 -and $null -ne $srcIpObj[0].IPAddress) {
                $srcParsed = [System.Net.IPAddress]::Parse([string]$srcIpObj[0].IPAddress)
                $srcUint = [BitConverter]::ToUInt32($srcParsed.GetAddressBytes(), 0)
            }
            $macBuf = New-Object byte[] 6
            $macLen = 6
            $null = [Relian.WgArpNative]::SendARP($dstUint, $srcUint, $macBuf, [ref]$macLen)
        }
    } catch { }
}

$script:WgWaitNeighbor = {
    param([int]$Milliseconds = 150)
    Start-Sleep -Milliseconds $Milliseconds
}

$script:WgGetServices = {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($svc in @(Get-Service -Name 'WireGuardTunnel$*' -ErrorAction SilentlyContinue)) {
        $startType = ''
        try {
            $startType = [string]$svc.StartType
        } catch {
            $startType = 'Automatic'
        }
        [void]$out.Add([pscustomobject]@{
            Name      = [string]$svc.Name
            Status    = [string]$svc.Status
            StartType = $startType
        })
    }
    return $out.ToArray()
}

$script:WgStopService = {
    param([string]$Name)
    Stop-Service -Name $Name -Force -ErrorAction Stop
}

$script:WgStartService = {
    param([string]$Name)
    Start-Service -Name $Name -ErrorAction Stop
}

$script:WgRegisterTask = {
    param([string]$TaskName, [string]$Xml)
    $null = Register-ScheduledTask -TaskPath $WgTaskPath -TaskName $TaskName -Xml $Xml -Force -ErrorAction Stop
}

$script:WgUnregisterTask = {
    param([string]$TaskName)
    $existing = try { Get-ScheduledTask -TaskPath $WgTaskPath -TaskName $TaskName -ErrorAction Stop } catch { $null }
    if ($null -ne $existing) {
        Unregister-ScheduledTask -TaskPath $WgTaskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }
}

$script:WgTestTaskPresent = {
    param([string]$TaskName)
    $existing = try { Get-ScheduledTask -TaskPath $WgTaskPath -TaskName $TaskName -ErrorAction Stop } catch { $null }
    return ($null -ne $existing)
}

$script:WgHardenDirectoryAcl = {
    param([string]$Path)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $isContainer = [bool]$item.PSIsContainer
    $acl = if ($isContainer) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = if ($isContainer) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sidStr in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidStr)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $full, $inherit, $prop, $allow)
        $acl.AddAccessRule($rule)
    }
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($adminSid)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Resolve-WgGatewayMac {
    param([int]$InterfaceIndex, [string]$GatewayIp)
    $confirmedStates = @('Reachable', 'Permanent')
    $neighbor = & $script:WgGetNeighbor -InterfaceIndex $InterfaceIndex -IPAddress $GatewayIp
    $state = if ($null -ne $neighbor) { [string]$neighbor.State } else { '' }
    $mac = if ($null -ne $neighbor) { ConvertTo-WgCanonicalMac -Mac ([string]$neighbor.LinkLayerAddress) } else { $null }

    # Always actively probe on the physical InterfaceIndex when missing, Incomplete, Unreachable,
    # Stale, Delay, or Probe so a cached ARP entry from a previous network before sleep/roaming
    # cannot spoof a trusted gateway MAC. Wait up to 3 polls for confirmed Reachable/Permanent state.
    if ($null -eq $mac -or $confirmedStates -notcontains $state) {
        & $script:WgProbeGateway -InterfaceIndex $InterfaceIndex -IPAddress $GatewayIp
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $neighbor = & $script:WgGetNeighbor -InterfaceIndex $InterfaceIndex -IPAddress $GatewayIp
            $state = if ($null -ne $neighbor) { [string]$neighbor.State } else { '' }
            $mac = if ($null -ne $neighbor) { ConvertTo-WgCanonicalMac -Mac ([string]$neighbor.LinkLayerAddress) } else { $null }
            if ($null -ne $mac -and $confirmedStates -contains $state) {
                return $mac
            }
            if ($attempt -lt 3) {
                & $script:WgWaitNeighbor -Milliseconds 150
            }
        }
        return $null
    }
    return $mac
}

function Test-WgTrustedNetwork {
    param($Options, [object[]]$PhysicalGateways)
    $reasons = [System.Collections.Generic.List[string]]::new()
    $matchedAdapters = [System.Collections.Generic.List[object]]::new()

    $suffixes = @($Options.trustedDnsSuffixes)
    foreach ($gw in @($PhysicalGateways)) {
        if ($null -eq $gw) { continue }
        $ifIndex = [int]$gw.InterfaceIndex
        $alias = [string]$gw.InterfaceAlias
        $gwIp = [string]$gw.GatewayIp
        $cat = [string]$gw.NetworkCategory
        $dnsSuffix = ([string]$gw.DnsSuffix).Trim().TrimStart('.').ToLowerInvariant()

        $suffixOk = ($suffixes.Count -eq 0) -or ($suffixes -contains $dnsSuffix)

        if ($Options.trustDomainAuthenticated -and $cat -eq 'DomainAuthenticated' -and $suffixOk) {
            [void]$reasons.Add("adapter '$alias' ($gwIp) is DomainAuthenticated")
            [void]$matchedAdapters.Add([ordered]@{
                interfaceIndex = $ifIndex
                interfaceAlias = $alias
                gatewayIp      = $gwIp
                gatewayMac     = $null
                matchType      = 'DomainAuthenticated'
            })
            continue
        }

        foreach ($rule in @($Options.trustedGateways)) {
            if ($null -eq $rule) { continue }
            if ([string]$rule.ip -ne $gwIp) { continue }
            if (-not $suffixOk) { continue }

            $ruleMacs = @($rule.macs)
            if ($ruleMacs.Count -eq 0 -and $Options.allowGatewayIpOnly) {
                [void]$reasons.Add("adapter '$alias' matched gateway IP $gwIp")
                [void]$matchedAdapters.Add([ordered]@{
                    interfaceIndex = $ifIndex
                    interfaceAlias = $alias
                    gatewayIp      = $gwIp
                    gatewayMac     = $null
                    matchType      = 'GatewayIp'
                })
                break
            }

            $resolvedMac = Resolve-WgGatewayMac -InterfaceIndex $ifIndex -GatewayIp $gwIp
            if ($null -ne $resolvedMac -and ($ruleMacs -contains $resolvedMac)) {
                [void]$reasons.Add("adapter '$alias' matched gateway $gwIp ($resolvedMac)")
                [void]$matchedAdapters.Add([ordered]@{
                    interfaceIndex = $ifIndex
                    interfaceAlias = $alias
                    gatewayIp      = $gwIp
                    gatewayMac     = $resolvedMac
                    matchType      = 'GatewayIpAndMac'
                })
                break
            }
        }
    }

    return [ordered]@{
        onTrustedNetwork = ($matchedAdapters.Count -gt 0)
        reasons          = @($reasons.ToArray())
        matchedAdapters  = @($matchedAdapters.ToArray())
    }
}

function Get-WgMatchingServices {
    param([string[]]$Patterns)
    $all = @(& $script:WgGetServices)
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($svc in $all) {
        if ($null -eq $svc) { continue }
        $name = [string]$svc.Name
        if ($name -notmatch '(?i)^WireGuardTunnel\$[A-Za-z0-9_.-]{1,64}$') {
            continue
        }
        foreach ($pattern in @($Patterns)) {
            if ($name -like $pattern) {
                [void]$matched.Add($svc)
                break
            }
        }
    }
    return $matched.ToArray()
}

function Read-WgState {
    param([string]$Root)
    $path = Get-WgStatePath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{ stoppedByGuard = @() }
    }
    try {
        if (-not (Test-WgNoReparsePoint -Path $path)) {
            return [ordered]@{ stoppedByGuard = @() }
        }
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $doc = $raw | ConvertFrom-Json
        $stopped = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['stoppedByGuard'] -and $null -ne $doc.stoppedByGuard) {
            foreach ($s in @($doc.stoppedByGuard)) {
                $name = [string]$s
                if ($name -match '(?i)^WireGuardTunnel\$[A-Za-z0-9_.-]{1,64}$' -and -not $stopped.Contains($name)) {
                    [void]$stopped.Add($name)
                }
            }
        }
        return [ordered]@{ stoppedByGuard = @($stopped.ToArray()) }
    } catch {
        return [ordered]@{ stoppedByGuard = @() }
    }
}

function Write-WgJsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    if (-not (Test-WgNoReparsePoint -Path $Path)) {
        throw "refusing to write through reparse point at $Path"
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    $json = ConvertTo-Json -InputObject $Object -Depth 6 -Compress
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, ($json + "`n"), $utf8NoBom)
    & $script:WgHardenDirectoryAcl -Path $Path
}

function New-WgTaskXml {
    param([string]$ScriptPath, [string]$InstallRoot)
    if ($ScriptPath.Contains('"') -or $InstallRoot.Contains('"')) {
        throw 'ScriptPath and InstallRoot must not contain double quotes.'
    }
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Action Evaluate -InstallRoot `"$InstallRoot`""
    $escapedArgs = [Security.SecurityElement]::Escape($arguments)
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Stops WireGuardTunnel services when connected to a trusted office network and starts them on external networks.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and (EventID=10000 or EventID=10001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Invoke-WgEvaluationStep {
    param($Options, [switch]$ReadOnly)
    $services = @(Get-WgMatchingServices -Patterns $Options.tunnelPatterns)
    $tunnelAliases = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $services) {
        $svcName = [string]$svc.Name
        if ($svcName -match '(?i)^WireGuardTunnel\$(.+)$') {
            [void]$tunnelAliases.Add($Matches[1].ToLowerInvariant())
        }
    }
    $rawGateways = @(& $script:WgGetPhysicalGateways)
    $gateways = @($rawGateways | Where-Object {
        $null -ne $_ -and ($tunnelAliases -notcontains ([string]$_.InterfaceAlias).ToLowerInvariant())
    })
    $detection = Test-WgTrustedNetwork -Options $Options -PhysicalGateways $gateways
    $state = Read-WgState -Root $Options.installRoot
    $stoppedByGuard = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($state.stoppedByGuard)) {
        if (-not $stoppedByGuard.Contains([string]$s)) {
            [void]$stoppedByGuard.Add([string]$s)
        }
    }

    # Pre-strip any WireGuard interface from tunnel names if a user named the adapter the same as the service suffix.
    $stoppedServices = [System.Collections.Generic.List[string]]::new()
    $startedServices = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($detection.onTrustedNetwork) {
        foreach ($svc in $services) {
            $name = [string]$svc.Name
            if ([string]$svc.Status -ne 'Stopped') {
                if ($ReadOnly) {
                    [void]$stoppedServices.Add($name)
                } else {
                    try {
                        & $script:WgStopService -Name $name
                        [void]$stoppedServices.Add($name)
                        if (-not $stoppedByGuard.Contains($name)) {
                            [void]$stoppedByGuard.Add($name)
                        }
                    } catch {
                        [void]$errors.Add("stop ${name}: $(Limit-WgText "$_" 120)")
                    }
                }
            }
        }
    } elseif ($Options.manageOffNetwork -and $gateways.Count -gt 0) {
        foreach ($svc in $services) {
            $name = [string]$svc.Name
            $startType = [string]$svc.StartType
            if ($startType -eq 'Disabled') { continue }
            $shouldStart = ($startType -eq 'Automatic') -or $stoppedByGuard.Contains($name)
            if (-not $shouldStart) { continue }
            if ([string]$svc.Status -eq 'Stopped') {
                if ($ReadOnly) {
                    [void]$startedServices.Add($name)
                } else {
                    try {
                        & $script:WgStartService -Name $name
                        [void]$startedServices.Add($name)
                        [void]$stoppedByGuard.Remove($name)
                    } catch {
                        [void]$errors.Add("start ${name}: $(Limit-WgText "$_" 120)")
                    }
                }
            }
        }
    }

    if (-not $ReadOnly -and (Test-Path -LiteralPath $Options.installRoot)) {
        try {
            Write-WgJsonFile -Path (Get-WgStatePath -Root $Options.installRoot) -Object ([ordered]@{
                stoppedByGuard   = @($stoppedByGuard.ToArray())
                onTrustedNetwork = [bool]$detection.onTrustedNetwork
                updatedAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
        } catch {
            [void]$errors.Add("state write: $(Limit-WgText "$_" 120)")
        }
    }

    $afterServices = @(Get-WgMatchingServices -Patterns $Options.tunnelPatterns | ForEach-Object {
        [ordered]@{
            name      = [string]$_.Name
            status    = [string]$_.Status
            startType = [string]$_.StartType
        }
    })

    return [ordered]@{
        onTrustedNetwork = [bool]$detection.onTrustedNetwork
        reasons          = @($detection.reasons)
        matchedAdapters  = @($detection.matchedAdapters)
        physicalGateways = @($gateways | ForEach-Object {
            [ordered]@{
                interfaceIndex = [int]$_.InterfaceIndex
                interfaceAlias = [string]$_.InterfaceAlias
                gatewayIp      = [string]$_.GatewayIp
            }
        })
        stoppedServices  = @($stoppedServices.ToArray())
        startedServices  = @($startedServices.ToArray())
        services         = $afterServices
        errors           = @($errors.ToArray())
    }
}

function Invoke-WgRun {
    param($Options)
    $mode = [string]$Options.mode
    $root = [string]$Options.installRoot
    $taskName = [string]$Options.taskName
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($mode -eq 'uninstall') {
        $wasPresent = (Test-Path -LiteralPath $root) -or [bool](& $script:WgTestTaskPresent -TaskName $taskName)
        $state = Read-WgState -Root $root
        $savedPatterns = $Options.tunnelPatterns
        if (Test-Path -LiteralPath (Get-WgConfigPath -Root $root)) {
            try {
                $savedCfg = Read-WgSavedConfig -Root $root
                $savedPatterns = $savedCfg.tunnelPatterns
                $taskName = $savedCfg.taskName
            } catch { }
        }

        try {
            if (& $script:WgTestTaskPresent -TaskName $taskName) {
                & $script:WgUnregisterTask -TaskName $taskName
            }
        } catch {
            [void]$errors.Add("unregister task: $(Limit-WgText "$_" 120)")
        }

        $restarted = [System.Collections.Generic.List[string]]::new()
        if ($wasPresent) {
            $services = @(Get-WgMatchingServices -Patterns $savedPatterns)
            foreach ($svc in $services) {
                $name = [string]$svc.Name
                $startType = [string]$svc.StartType
                if ($startType -eq 'Disabled') { continue }
                $shouldRestore = ($startType -eq 'Automatic') -or (@($state.stoppedByGuard) -contains $name)
                if ($shouldRestore -and [string]$svc.Status -eq 'Stopped') {
                    try {
                        & $script:WgStartService -Name $name
                        [void]$restarted.Add($name)
                    } catch {
                        [void]$errors.Add("restore ${name}: $(Limit-WgText "$_" 120)")
                    }
                }
            }
        }

        if (Test-Path -LiteralPath $root) {
            try {
                if (-not (Test-WgNoReparsePoint -Path $root)) {
                    throw "refusing reparse point at $root"
                }
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            } catch {
                [void]$errors.Add("remove install root: $(Limit-WgText "$_" 120)")
            }
        }

        $code = if ($errors.Count -eq 0) { 0 } else { 1 }
        $verdict = if ($code -ne 0) {
            "uninstall failed: $($errors -join '; ')"
        } elseif (-not $wasPresent) {
            'uninstalled: nothing was installed'
        } elseif ($restarted.Count -gt 0) {
            "uninstalled: removed task $taskName and restarted $($restarted -join ', ')"
        } else {
            "uninstalled: removed task $taskName"
        }

        $record = [ordered]@{
            mode            = 'uninstall'
            taskName        = $taskName
            startedServices = @($restarted.ToArray())
            errors          = @($errors.ToArray())
            verdict         = $verdict
            timestamp       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            version         = '1.0'
        }
        return [ordered]@{ record = $record; exitCode = $code }
    }

    if ($mode -eq 'install') {
        if (-not (Test-WgNoReparsePoint -Path $root)) {
            throw "refusing reparse point at $root"
        }
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        }
        & $script:WgHardenDirectoryAcl -Path $root

        $scriptCopy = Get-WgScriptCopyPath -Root $root
        $sourcePath = [string]$Options.sourceScriptPath
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath)) {
            throw 'source script path is missing; cannot stage scheduled task script.'
        }
        if (-not (Test-WgNoReparsePoint -Path $sourcePath) -or -not (Test-WgNoReparsePoint -Path $scriptCopy)) {
            throw "refusing reparse point when staging $scriptCopy"
        }
        if (-not [IO.Path]::GetFullPath($sourcePath).Equals([IO.Path]::GetFullPath($scriptCopy), [StringComparison]::OrdinalIgnoreCase)) {
            $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
            if (Test-Path -LiteralPath $scriptCopy) {
                Remove-Item -LiteralPath $scriptCopy -Force -ErrorAction Stop
            }
            [IO.File]::WriteAllBytes($scriptCopy, $sourceBytes)
        }
        & $script:WgHardenDirectoryAcl -Path $scriptCopy

        $configObj = [ordered]@{
            schema                   = 1
            taskName                 = $taskName
            tunnelPatterns           = @($Options.tunnelPatterns)
            trustedGateways          = @($Options.trustedGateways)
            trustDomainAuthenticated = [bool]$Options.trustDomainAuthenticated
            trustedDnsSuffixes       = @($Options.trustedDnsSuffixes)
            allowGatewayIpOnly       = [bool]$Options.allowGatewayIpOnly
            manageOffNetwork         = [bool]$Options.manageOffNetwork
        }
        Write-WgJsonFile -Path (Get-WgConfigPath -Root $root) -Object $configObj

        $xml = New-WgTaskXml -ScriptPath $scriptCopy -InstallRoot $root
        & $script:WgRegisterTask -TaskName $taskName -Xml $xml
    }

    $eval = Invoke-WgEvaluationStep -Options $Options -ReadOnly:($mode -eq 'check')
    foreach ($e in @($eval.errors)) {
        [void]$errors.Add([string]$e)
    }

    $code = if ($errors.Count -eq 0) { 0 } else { 1 }
    $netLabel = if ($eval.onTrustedNetwork) {
        "on trusted network ($($eval.reasons -join '; '))"
    } elseif (@($eval.physicalGateways).Count -eq 0) {
        'no active physical gateway'
    } else {
        'on external network'
    }
    $svcAction = if (@($eval.stoppedServices).Count -gt 0) {
        "stopped $($eval.stoppedServices -join ', ')"
    } elseif (@($eval.startedServices).Count -gt 0) {
        "started $($eval.startedServices -join ', ')"
    } else {
        'no service state change needed'
    }
    $verdict = if ($code -ne 0) {
        "${mode} incomplete: $netLabel; errors: $($errors -join '; ')"
    } else {
        "${mode}: $netLabel; $svcAction"
    }

    $record = [ordered]@{
        mode             = $mode
        taskName         = $taskName
        onTrustedNetwork = [bool]$eval.onTrustedNetwork
        reasons          = @($eval.reasons)
        matchedAdapters  = @($eval.matchedAdapters)
        physicalGateways = @($eval.physicalGateways)
        stoppedServices  = @($eval.stoppedServices)
        startedServices  = @($eval.startedServices)
        services         = @($eval.services)
        errors           = @($errors.ToArray())
        verdict          = $verdict
        timestamp        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        version          = '1.0'
    }
    return [ordered]@{ record = $record; exitCode = $code }
}

function Invoke-WgMain {
    $mutex = $null
    $acquired = $false
    try {
        try {
            $mutex = [System.Threading.Mutex]::new($false, 'Global\RelianWireGuardNetworkGuard')
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        } catch {
            $mutex = $null
        }
        if ($null -ne $mutex -and -not $acquired) {
            throw 'timed out waiting for Global\RelianWireGuardNetworkGuard mutex.'
        }

        $options = Get-WgOptions `
            -DeploymentType $DeploymentType `
            -Action $Action `
            -TrustedGateways $TrustedGateways `
            -TrustedGatewayMacs $TrustedGatewayMacs `
            -TunnelPattern $TunnelPattern `
            -TrustDomainAuthenticated $TrustDomainAuthenticated `
            -TrustedDnsSuffixes $TrustedDnsSuffixes `
            -AllowGatewayIpOnly $AllowGatewayIpOnly `
            -ManageOffNetwork $ManageOffNetwork `
            -TaskName $TaskName `
            -InstallRoot $InstallRoot `
            -SourceScriptPath $SourceScriptPath

        $run = Invoke-WgRun -Options $options
        $json = ConvertTo-Json -InputObject $run.record -Depth 6 -Compress
        Write-WgStatus "Verdict: $($run.record.verdict)"
        Write-Output $json
        exit $run.exitCode
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    } finally {
        if ($null -ne $mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            $mutex.Dispose()
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-WgMain
