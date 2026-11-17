<#
.SYNOPSIS
    Sends a Wake-on-LAN magic packet from this device to one sleeping device on the same subnet.
.DESCRIPTION
    Runs on an online PEER, not on the target: a sleeping device cannot run a script. The caller (the
    read-job loader, which passes -DeploymentType, -Action and -PinVersion) supplies only two values, both
    validated before any socket opens:

      Mac        the target's MAC, six hex pairs joined by '-' (AA-BB-CC-DD-EE-FF). Not all-zero, not
                 broadcast, not multicast: a NIC address is unicast.
      Broadcast  the IPv4 address to send to: the subnet's directed broadcast (for example 192.168.1.255)
                 or the limited broadcast 255.255.255.255. Only RFC 1918 addresses and 255.255.255.255
                 are accepted, so a packet never leaves for a public network.
      Port       9 (default, discard) or 7 (echo).

    The magic packet is 6 bytes of FF then the MAC 16 times (102 bytes). It is sent 3 times, 200 ms apart,
    over UDP with broadcast enabled. Nothing else happens: no file, registry, service or custom-field write,
    no download. Prints one JSON line: version, timestamp, status (sent, failed or refused), targetMac (only
    the last three octets), broadcast, port, packetsSent, elapsedSeconds, error. A sent packet says nothing
    about whether the target woke; the caller polls the target's online state.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mac = '',
    [string]$Broadcast = '',
    [string]$Port = '9'
)
$ProgressPreference = 'SilentlyContinue'

$script:WakeClock = [Diagnostics.Stopwatch]::StartNew()
$script:WakeCount = 3
$script:WakeGapMs = 200
$script:MacPattern = '\A[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}\z'
$script:OctetPattern = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'

# Seams. Tests replace them.
$script:Pause = { param($Ms) [Threading.Thread]::Sleep([int]$Ms) }
$script:SendPacket = {
    param([byte[]]$Packet, [string]$Address, [int]$UdpPort)
    $client = [Net.Sockets.UdpClient]::new()
    try {
        $client.EnableBroadcast = $true
        $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($Address), $UdpPort)
        return $client.Send($Packet, $Packet.Length, $endpoint)
    } finally {
        $client.Dispose()
    }
}

# $null when the MAC is a valid unicast NIC address, else a fixed reason.
function Test-WakeMac {
    param([AllowEmptyString()][string]$Value)
    if ($Value -cnotmatch $script:MacPattern) { return 'bad mac' }
    $first = [Convert]::ToByte($Value.Substring(0, 2), 16)
    if (($first -band 1) -ne 0) { return 'bad mac' }   # group bit: multicast and FF-FF-FF-FF-FF-FF
    if ($Value -eq '00-00-00-00-00-00') { return 'bad mac' }
    return $null
}

# $null when the address is 255.255.255.255 or an RFC 1918 address, else a fixed reason.
function Test-WakeBroadcast {
    param([AllowEmptyString()][string]$Value)
    $o = $script:OctetPattern
    if ($Value -cnotmatch "\A$o\.$o\.$o\.$o\z") { return 'bad broadcast' }
    if ($Value -eq '255.255.255.255') { return $null }
    $b = @($Value.Split('.') | ForEach-Object { [int]$_ })
    $private = ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
    if (-not $private) { return 'bad broadcast' }
    return $null
}

function ConvertTo-WakePacket {
    param([string]$Value)
    $macBytes = [byte[]]@($Value.Split('-') | ForEach-Object { [Convert]::ToByte($_, 16) })
    $packet = [byte[]]::new(102)
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($r = 0; $r -lt 16; $r++) { [Array]::Copy($macBytes, 0, $packet, 6 + 6 * $r, 6) }
    return , $packet
}

# Only the last three octets (the NIC part) leave the device; a malformed value is not echoed.
function Get-WakeMaskedMac {
    param([AllowEmptyString()][string]$Value)
    if ($Value -cnotmatch $script:MacPattern) { return $null }
    return '**-**-**-' + $Value.Substring(9).ToUpperInvariant()
}

function Invoke-WakeDevice {
    param([AllowEmptyString()][string]$Mac, [AllowEmptyString()][string]$Broadcast, [AllowEmptyString()][string]$Port = '9')
    $report = [ordered]@{
        version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'refused'
        targetMac = (Get-WakeMaskedMac $Mac); broadcast = $null; port = $null; packetsSent = 0; elapsedSeconds = 0; error = $null
    }
    $reason = Test-WakeMac $Mac
    if (-not $reason) { $reason = Test-WakeBroadcast $Broadcast }
    if (-not $reason -and @('9', '7') -cnotcontains $Port) { $reason = 'bad port' }
    if ($reason) {
        $report.error = $reason
    } else {
        $report.broadcast = $Broadcast
        $report.port = [int]$Port
        $packet = ConvertTo-WakePacket $Mac
        try {
            for ($n = 1; $n -le $script:WakeCount; $n++) {
                $written = & $script:SendPacket $packet $Broadcast ([int]$Port)
                if ([int]$written -ne $packet.Length) { throw [Net.Sockets.SocketException]::new() }
                $report.packetsSent = $n
                if ($n -lt $script:WakeCount) { [void](& $script:Pause $script:WakeGapMs) }
            }
            $report.status = 'sent'
        } catch {
            $report.status = 'failed'
            $report.error = $_.Exception.GetType().Name
        }
    }
    $report.elapsedSeconds = [Math]::Round($script:WakeClock.Elapsed.TotalSeconds, 1)
    return ($report | ConvertTo-Json -Compress)
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
$line = Invoke-WakeDevice -Mac $Mac -Broadcast $Broadcast -Port $Port
Write-Output $line
if ($line.Contains('"status":"sent"')) { exit 0 }
exit 1
