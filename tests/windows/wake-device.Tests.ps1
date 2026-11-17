$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/wake-device/Invoke-WakeDevice.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no syntax newer than Windows PowerShell 5.1, and calls no write cmdlet or download.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
$own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
foreach ($c in @($commands | Where-Object { $own -notcontains $_ })) { Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Out|Invoke)-') "no $c" }
$text = Get-Content -LiteralPath $path -Raw
foreach ($banned in @('[IO.File]', 'Registry', 'WebRequest', 'WebClient', 'HttpClient', 'Ninja-Property')) { Assert (-not $text.Contains($banned)) "no $banned" }

# Packet: 6 x FF then the MAC 16 times.
$p = ConvertTo-WakePacket '0a-1B-2c-3D-4e-5F'
Assert ($p.Length -eq 102) 'packet is 102 bytes'
Assert (@($p[0..5] | Where-Object { $_ -ne 0xFF }).Count -eq 0) 'sync stream'
$macBytes = [byte[]](0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F)
for ($r = 0; $r -lt 16; $r++) { Assert ([BitConverter]::ToString($macBytes) -eq [BitConverter]::ToString($p, 6 + 6 * $r, 6)) "mac repeat $r" }

# MAC validation: dash form only, unicast only.
foreach ($ok in @('00-11-22-33-44-55', 'aa-bb-cc-dd-ee-f0', 'AC-DE-48-00-11-22')) { Assert ($null -eq (Test-WakeMac $ok)) "mac ok $ok" }
foreach ($bad in @('', '00:11:22:33:44:55', '001122334455', '00-11-22-33-44', '00-11-22-33-44-55-66', '00-11-22-33-44-5G', ' 00-11-22-33-44-55',
        '00-11-22-33-44-55 ', "00-11-22-33-44-55`n", '00-00-00-00-00-00', 'FF-FF-FF-FF-FF-FF', '01-00-5E-00-00-01', '33-33-00-00-00-01', '00-11-22-33-44-55;x')) {
    Assert ((Test-WakeMac $bad) -eq 'bad mac') "mac refused [$bad]"
}

# Broadcast validation: dotted IPv4, RFC 1918 or the limited broadcast.
foreach ($ok in @('192.168.1.255', '10.0.255.255', '172.16.0.255', '172.31.255.255', '255.255.255.255', '10.40.4.127')) { Assert ($null -eq (Test-WakeBroadcast $ok)) "broadcast ok $ok" }
foreach ($bad in @('', '8.8.8.8', '172.32.0.255', '172.15.255.255', '127.0.0.1', '224.0.0.1', '0.0.0.0', '192.168.1', '192.168.1.256', '192.168.01.255',
        '192.168.1.255 ', 'example.invalid', '::1', '192.168.1.255/24', '192-168-1-255')) {
    Assert ((Test-WakeBroadcast $bad) -eq 'bad broadcast') "broadcast refused [$bad]"
}

# Masking: the first three octets never leave; a bad value is not echoed.
Assert ((Get-WakeMaskedMac 'aa-bb-cc-dd-ee-ff') -eq '**-**-**-DD-EE-FF') 'mac masked'
Assert ($null -eq (Get-WakeMaskedMac 'not;a mac')) 'bad mac not echoed'

# Sends 3 packets to the given address and port, with no real socket.
$script:Pause = { param($Ms) }
$sent = [Collections.Generic.List[object]]::new()
$script:SendPacket = { param($Packet, $Address, $UdpPort) $sent.Add(@($Packet.Length, $Address, $UdpPort)); return $Packet.Length }
$r = Invoke-WakeDevice -Mac '00-11-22-33-44-55' -Broadcast '192.168.1.255' | ConvertFrom-Json
Assert ($r.status -eq 'sent' -and $r.packetsSent -eq 3 -and $r.error -eq $null) 'sent 3'
Assert ($r.targetMac -eq '**-**-**-33-44-55' -and $r.broadcast -eq '192.168.1.255' -and $r.port -eq 9 -and $r.version -eq '1') 'result fields'
Assert ($sent.Count -eq 3 -and $sent[0][0] -eq 102 -and $sent[0][1] -eq '192.168.1.255' -and $sent[0][2] -eq 9) 'packet sent to broadcast:9'
$sent.Clear()
$r = Invoke-WakeDevice -Mac '00-11-22-33-44-55' -Broadcast '255.255.255.255' -Port '7' | ConvertFrom-Json
Assert ($r.status -eq 'sent' -and $sent[0][2] -eq 7) 'port 7'

# Refused before any socket: bad MAC, bad broadcast, bad port.
foreach ($case in @(@('00:11:22:33:44:55', '192.168.1.255', '9', 'bad mac'), @('00-11-22-33-44-55', '8.8.8.8', '9', 'bad broadcast'), @('00-11-22-33-44-55', '192.168.1.255', '80', 'bad port'))) {
    $sent.Clear()
    $r = Invoke-WakeDevice -Mac $case[0] -Broadcast $case[1] -Port $case[2] | ConvertFrom-Json
    Assert ($r.status -eq 'refused' -and $r.error -eq $case[3] -and $r.packetsSent -eq 0 -and $sent.Count -eq 0) "refused $($case[3])"
}

# A socket error mid-run is reported as failed with the count so far, never as sent.
$script:n = 0
$script:SendPacket = { param($Packet, $Address, $UdpPort) $script:n++; if ($script:n -eq 2) { throw [Net.Sockets.SocketException]::new(10051) }; return $Packet.Length }
$r = Invoke-WakeDevice -Mac '00-11-22-33-44-55' -Broadcast '10.0.0.255' | ConvertFrom-Json
Assert ($r.status -eq 'failed' -and $r.packetsSent -eq 1 -and $r.error -eq 'SocketException') 'socket error'
$script:SendPacket = { param($Packet, $Address, $UdpPort) return 10 }
$r = Invoke-WakeDevice -Mac '00-11-22-33-44-55' -Broadcast '10.0.0.255' | ConvertFrom-Json
Assert ($r.status -eq 'failed' -and $r.packetsSent -eq 0) 'short send is a failure'

# The JSON line stays well under the loader's 8000-byte cap.
Assert ([Text.Encoding]::UTF8.GetByteCount((Invoke-WakeDevice -Mac '00-11-22-33-44-55' -Broadcast '10.0.0.255')) -lt 400) 'small line'

# The real sender puts the exact packet on a real UDP socket (loopback here; the validator never admits loopback).
$listener = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
try {
    $listener.Client.ReceiveTimeout = 5000
    $lport = ([Net.IPEndPoint]$listener.Client.LocalEndPoint).Port
    . $path
    $packet = ConvertTo-WakePacket '00-11-22-33-44-55'
    $count = & $script:SendPacket $packet '127.0.0.1' $lport
    $from = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
    $got = $listener.Receive([ref]$from)
    Assert ($count -eq 102 -and $got.Length -eq 102 -and [BitConverter]::ToString($packet) -eq [BitConverter]::ToString($got)) 'real socket round trip'
} finally {
    $listener.Dispose()
}

# The script run end to end: refused input exits 1 and prints the refusal.
# RELIAN_DEPLOY_TEST=1 is inherited on purpose: the package skips its entry point only when dot-sourced (InvocationName '.'), and -File is not.
$out = & pwsh -NoProfile -File $path -Action Install -Mac 'zz' -Broadcast '192.168.1.255'
Assert ($LASTEXITCODE -eq 1 -and ($out | ConvertFrom-Json).error -eq 'bad mac') 'script exits 1 on a refusal'
$out = & pwsh -NoProfile -File $path -Action Uninstall
Assert ($LASTEXITCODE -eq 0 -and $out -match 'nothingToUninstall') 'uninstall is a no-op'

Write-Output 'wake-device tests passed'
