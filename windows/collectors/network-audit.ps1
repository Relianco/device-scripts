<#
.SYNOPSIS
    Relian Network Audit Collector
    Collects network adapter and connectivity details and prints one JSON object.

.DESCRIPTION
    Gathers per-adapter details: name, MAC, status, speed, type, IP config.
    For WiFi: SSID, signal strength, band, protocol.
    Connection type classification (wired, WiFi, VPN, unknown).
    Prints one compressed JSON object on the success stream.
    Pass -AdapterName to keep one adapter. An empty name keeps every adapter.

.PARAMETER AdapterName
    Adapter name to keep. Comparison is equality, ordinal and case-insensitive.
    Empty keeps every adapter.

.NOTES
    Requirements: Windows PowerShell 5.1+
    Duration: <10 seconds
    No external module dependencies
    Version: 1.0
#>

# Script parameters are not Mandatory: a mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$AdapterName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

# Get WiFi details via netsh
function Get-WifiDetails {
    $wifiInfo = @{
        ssid           = $null
        signalPercent  = $null
        band           = $null
        protocol       = $null
        authentication = $null
        channel        = $null
    }

    try {
        $output = netsh wlan show interfaces 2>$null
        if (-not $output) { return $wifiInfo }

        foreach ($line in $output) {
            $line = $line.Trim()
            if ($line -match '^\s*SSID\s*:\s*(.+)$' -and $line -notmatch 'BSSID') {
                $wifiInfo.ssid = $Matches[1].Trim()
            }
            elseif ($line -match '^\s*Signal\s*:\s*(\d+)%') {
                $wifiInfo.signalPercent = [int]$Matches[1]
            }
            elseif ($line -match '^\s*Radio type\s*:\s*(.+)$') {
                $radioType = $Matches[1].Trim()
                # Map radio type to WiFi generation
                if ($radioType -match '802\.11ax' -or $radioType -match 'Wi-Fi 6') {
                    $wifiInfo.protocol = "WiFi 6"
                } elseif ($radioType -match '802\.11ac' -or $radioType -match 'Wi-Fi 5') {
                    $wifiInfo.protocol = "WiFi 5"
                } elseif ($radioType -match '802\.11n' -or $radioType -match 'Wi-Fi 4') {
                    $wifiInfo.protocol = "WiFi 4"
                } else {
                    $wifiInfo.protocol = $radioType
                }
            }
            elseif ($line -match '^\s*Band\s*:\s*(.+)$') {
                $wifiInfo.band = $Matches[1].Trim()
            }
            elseif ($line -match '^\s*Channel\s*:\s*(\d+)') {
                $channel = [int]$Matches[1]
                $wifiInfo.channel = $channel
                # Infer band from channel if not explicitly set
                if (-not $wifiInfo.band) {
                    if ($channel -le 14) { $wifiInfo.band = "2.4 GHz" }
                    elseif ($channel -le 177) { $wifiInfo.band = "5 GHz" }
                    else { $wifiInfo.band = "6 GHz" }
                }
            }
            elseif ($line -match '^\s*Authentication\s*:\s*(.+)$') {
                $wifiInfo.authentication = $Matches[1].Trim()
            }
        }
    } catch {
        Write-Status "WiFi details query failed: $_" "WARN"
    }

    return $wifiInfo
}

# Classify connection type
function Get-ConnectionType {
    param($Adapter, $IpConfig, $WifiDetails)

    if ($Adapter.type -eq "VPN") { return "vpn" }

    if ($Adapter.type -eq "WiFi") {
        $ssid = $WifiDetails.ssid
        if ($ssid -and ($ssid -match 'Corp|Office|Enterprise|Business')) {
            return "wifi-corporate"
        }
        return "wifi"
    }

    if ($Adapter.type -eq "Ethernet") {
        # Check for domain membership as a hint of corporate network
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.PartOfDomain) { return "wired-corporate" }
        } catch { }
        return "wired"
    }

    return "unknown"
}

function New-NetworkAuditResult {
    param(
        $Adapters,
        [AllowEmptyString()][string]$AdapterName = ''
    )

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in @($Adapters)) {
        if ($null -eq $adapter) {
            continue
        }
        if (-not [string]::IsNullOrEmpty($AdapterName)) {
            $name = [string]$adapter.name
            if (-not $name.Equals([string]$AdapterName, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }
        [void]$filtered.Add($adapter)
    }

    $dnsServers = New-Object System.Collections.Generic.List[string]
    $connected = 0
    $wifi = 0
    $ethernet = 0
    foreach ($adapter in $filtered) {
        if ([string]$adapter.status -eq 'Connected') {
            $connected = $connected + 1
        }
        if ([string]$adapter.type -eq 'WiFi') {
            $wifi = $wifi + 1
        }
        if ([string]$adapter.type -eq 'Ethernet') {
            $ethernet = $ethernet + 1
        }
        if ($null -eq $adapter.dnsServers) {
            continue
        }
        foreach ($dns in @($adapter.dnsServers)) {
            if ([string]::IsNullOrEmpty([string]$dns)) {
                continue
            }
            $text = [string]$dns
            if (-not $dnsServers.Contains($text)) {
                [void]$dnsServers.Add($text)
            }
        }
    }

    $primary = $null
    if ($dnsServers.Count -gt 0) {
        $primary = $dnsServers[0]
    }

    $result = @{
        adapters       = @($filtered.ToArray())
        totalAdapters  = $filtered.Count
        connectedCount = $connected
        primaryDns     = $primary
        allDnsServers  = @($dnsServers.ToArray())
        hasWifi        = ($wifi -gt 0)
        hasEthernet    = ($ethernet -gt 0)
        timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        version        = "1.0"
    }

    return ($result | ConvertTo-Json -Depth 4 -Compress)
}

function Invoke-NetworkAudit {
    param(
        [AllowEmptyString()][string]$AdapterName = ''
    )

    Write-Status "Relian Network Audit v1.0 starting"

    # Get physical network adapters
    $adapters = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
        Where-Object { $_.PhysicalAdapter -eq $true -and $_.NetConnectionID }

    # Get IP configuration
    $ipConfigs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction Stop |
        Where-Object { $_.IPEnabled -eq $true }

    # Get WiFi details
    $wifiDetails = Get-WifiDetails

    $adapterList = @()

    if ($adapters) {
        foreach ($adapter in $adapters) {
            # Determine adapter type
            $adapterType = "Other"
            if ($adapter.Name -match 'Wi-?Fi|Wireless|802\.11') {
                $adapterType = "WiFi"
            } elseif ($adapter.Name -match 'Ethernet|LAN|Realtek|Intel.*I2[0-9]|Broadcom|Killer') {
                $adapterType = "Ethernet"
            } elseif ($adapter.Name -match 'VPN|Tunnel|TAP|WireGuard|Cisco|Palo Alto|FortiClient') {
                $adapterType = "VPN"
            } elseif ($adapter.Name -match 'Virtual|Hyper-V|VMware|VirtualBox') {
                $adapterType = "Virtual"
            }

            # Speed
            $speedMbps = 0
            if ($adapter.Speed) {
                $speedMbps = [math]::Round($adapter.Speed / 1000000)
            }

            # Status
            $statusText = switch ([int]$adapter.NetConnectionStatus) {
                0 { "Disconnected" }
                1 { "Connecting" }
                2 { "Connected" }
                3 { "Disconnecting" }
                7 { "Media disconnected" }
                default { "Unknown" }
            }

            $entry = @{
                name        = $adapter.Name
                description = $adapter.Description
                macAddress  = $adapter.MACAddress
                status      = $statusText
                speedMbps   = $speedMbps
                type        = $adapterType
            }

            # Find matching IP config
            $ipConfig = $ipConfigs | Where-Object { $_.Index -eq $adapter.Index } | Select-Object -First 1
            if ($ipConfig) {
                $ipv4Addresses = @()
                $ipv6Addresses = @()
                if ($ipConfig.IPAddress) {
                    foreach ($ip in $ipConfig.IPAddress) {
                        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { $ipv4Addresses += $ip }
                        elseif ($ip -match ':') { $ipv6Addresses += $ip }
                    }
                }

                $entry.ipv4 = $ipv4Addresses
                $entry.ipv6 = $ipv6Addresses
                $entry.subnet = if ($ipConfig.IPSubnet) { $ipConfig.IPSubnet[0] } else { $null }
                $entry.gateway = if ($ipConfig.DefaultIPGateway) { $ipConfig.DefaultIPGateway[0] } else { $null }
                $entry.dnsServers = if ($ipConfig.DNSServerSearchOrder) { @($ipConfig.DNSServerSearchOrder) } else { @() }
                $entry.dhcpEnabled = $ipConfig.DHCPEnabled
            }

            # Add WiFi-specific details
            if ($adapterType -eq "WiFi" -and $wifiDetails.ssid) {
                $entry.wifi = @{
                    ssid          = $wifiDetails.ssid
                    signalPercent = $wifiDetails.signalPercent
                    band          = $wifiDetails.band
                    protocol      = $wifiDetails.protocol
                    channel       = $wifiDetails.channel
                }
            }

            # Connection type classification
            $entry.connectionType = Get-ConnectionType -Adapter $entry -IpConfig $ipConfig -WifiDetails $wifiDetails

            # Performance hint: check if speed is below expected for type
            $speedHint = $null
            if ($statusText -eq "Connected" -and $speedMbps -gt 0) {
                if ($adapterType -eq "Ethernet" -and $speedMbps -lt 1000) {
                    $speedHint = "Below typical 1 Gbps for wired ($speedMbps Mbps)"
                } elseif ($adapterType -eq "WiFi" -and $speedMbps -lt 100) {
                    $speedHint = "Low WiFi speed ($speedMbps Mbps)"
                }
            }
            if ($speedHint) { $entry.speedHint = $speedHint }

            $adapterList += $entry
        }
    }

    $json = New-NetworkAuditResult -Adapters $adapterList -AdapterName $AdapterName
    Write-Status "Network audit collected: $($json.Length) bytes, $(@($adapterList).Count) adapters"
    Write-Output $json
    Write-Status "Network audit complete"
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    Invoke-NetworkAudit -AdapterName ([string]$AdapterName)
} catch {
    Write-Status "Network audit error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
