# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Strictly read-only: reports why a PC
# cannot reach an SMB file server. Prints the NTLM/LSA/Kerberos/SMB client policy values, SMB client config, DNS and
# TCP reachability of the target, tunnel and GSA service state, Kerberos tickets per interactive logon session
# (klist -li, names and times only) and recent SmbClient, NTLM, Kerberos and LSA events. Writes nothing.
# -ReportOnly is accepted because the loader forwards it, and ignored. Exit 0. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:FsHost = 'svfs.sitkalaw.local'
$script:FsIp = '192.168.10.10'
$script:Domain = 'sitkalaw.local'
$script:Hours = 6

function Get-FsReg {
    param([string]$Path, [string[]]$Names)
    $o = [ordered]@{}
    foreach ($n in $Names) {
        try { $o[$n] = (Get-ItemProperty -LiteralPath $Path -Name $n -ErrorAction Stop).$n } catch { $o[$n] = $null }
    }
    return $o
}

function Get-FsKeyAll {
    param([string]$Path)
    $o = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path
    foreach ($n in $item.GetValueNames()) { $v = $item.GetValue($n); $o[$n] = if ($v -is [array]) { ($v -join ';') } else { $v } }
    return $o
}

function Get-FsEvents {
    param([string]$Log, [int]$Max = 40, [int[]]$Levels)
    $start = (Get-Date).AddHours(-$script:Hours)
    $f = @{ LogName = $Log; StartTime = $start }
    if ($Levels) { $f.Level = $Levels }
    try {
        return @(Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction Stop | ForEach-Object {
            $m = [string]$_.Message; if ($m.Length -gt 400) { $m = $m.Substring(0, 400) }
            [ordered]@{ t = $_.TimeCreated.ToString('s'); id = $_.Id; p = $_.ProviderName; lvl = $_.Level; m = ($m -replace '\s+', ' ') }
        })
    } catch { return @("err: $($_.Exception.Message)") }
}

$r = [ordered]@{}
$os = Get-CimInstance Win32_OperatingSystem
$r.host = $env:COMPUTERNAME
$r.boot = $os.LastBootUpTime.ToString('s')
$r.now = (Get-Date).ToString('s')
$r.lsa = Get-FsReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' @('LmCompatibilityLevel', 'DisableDomainCreds', 'NoLMHash', 'RestrictAnonymous', 'RestrictAnonymousSAM', 'LsaCfgFlags', 'RunAsPPL', 'AllowOnlineID', 'everyoneincludesanonymous')
$r.msv = Get-FsReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' @('RestrictSendingNTLMTraffic', 'NtlmMinClientSec', 'NtlmMinServerSec', 'AuditReceivingNTLMTraffic', 'ClientAllowedNTLMServers', 'RestrictReceivingNTLMTraffic', 'allownullsessionfallback')
$r.pku2u = Get-FsKeyAll 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\pku2u'
$r.kerbPol = Get-FsKeyAll 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters'
$r.kerbParams = Get-FsKeyAll 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
$r.kerbCsp = Get-FsKeyAll 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kerberos'
$r.lmwParams = Get-FsKeyAll 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
$r.lmwPol = Get-FsKeyAll 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
$r.hardened = Get-FsKeyAll 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkProvider\HardenedPaths'
$r.pmSecOpt = Get-FsKeyAll 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalPoliciesSecurityOptions'
$r.pmLmw = Get-FsKeyAll 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LanmanWorkstation'
$r.pmKerb = Get-FsKeyAll 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Kerberos'
$r.pmRights = Get-FsKeyAll 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UserRights'
try { $r.smbClient = Get-SmbClientConfiguration | Select-Object RequireSecuritySignature, EnableSecuritySignature, EncryptionCiphers, EnableInsecureGuestLogons, RequireEncryption, Smb2DialectMin, Smb2DialectMax, AuditServerDoesNotSupportEncryption, AuditServerDoesNotSupportSigning, BlockNTLM, BlockNTLMServerExceptionList, EnableMailslots } catch { $r.smbClient = "err: $($_.Exception.Message)" }
try { $r.smbConn = @(Get-SmbConnection -ErrorAction Stop | Select-Object ServerName, ShareName, UserName, Dialect, Encrypted, Signed) } catch { $r.smbConn = "err: $($_.Exception.Message)" }
try { $r.dns = @(Resolve-DnsName $script:FsHost -ErrorAction Stop | Select-Object Name, Type, IPAddress) } catch { $r.dns = "err: $($_.Exception.Message)" }
try { $r.dnsSrv = @(Resolve-DnsName "_kerberos._tcp.$($script:Domain)" -Type SRV -ErrorAction Stop | Where-Object Type -eq 'SRV' | Select-Object NameTarget, Port) } catch { $r.dnsSrv = "err: $($_.Exception.Message)" }
$r.tcp = [ordered]@{}
foreach ($t in @("$($script:FsIp):445", "$($script:FsHost):445")) {
    $h, $p = $t -split ':'
    $c = New-Object Net.Sockets.TcpClient
    try { $ok = $c.ConnectAsync($h, [int]$p).Wait(4000); $r.tcp[$t] = $ok -and $c.Connected } catch { $r.tcp[$t] = "err: $($_.Exception.InnerException.Message)" } finally { $c.Dispose() }
}
if ($r.dnsSrv -is [array]) {
    foreach ($s in @($r.dnsSrv | Select-Object -First 2)) {
        foreach ($p in 88, 389) {
            $c = New-Object Net.Sockets.TcpClient
            try { $ok = $c.ConnectAsync($s.NameTarget, $p).Wait(4000); $r.tcp["$($s.NameTarget):$p"] = $ok -and $c.Connected } catch { $r.tcp["$($s.NameTarget):$p"] = 'err' } finally { $c.Dispose() }
        }
    }
}
$r.ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' } | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" })
$r.svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'WireGuard*' -or $_.Name -like 'GlobalSecureAccess*' -or $_.Name -in @('LanmanWorkstation', 'Netlogon', 'KeyIso') } | ForEach-Object { "$($_.Name)=$($_.Status)" })
try { $r.nrpt = @(Get-DnsClientNrptRule -ErrorAction Stop | ForEach-Object { "$($_.Namespace -join ',') -> $($_.NameServers -join ',')" }) } catch { $r.nrpt = 'err' }

# Kerberos tickets per interactive logon session: names and times only.
$r.klist = [ordered]@{}
try {
    $sessions = & klist.exe sessions 2>&1 | Out-String
    $luids = @([regex]::Matches($sessions, '\[\d+\]\s+Session\s+\d+\s+0:(0x[0-9a-f]+)\s+(\S+)\s+(\S+):(\S+)') | Where-Object { $_.Groups[3].Value -notmatch 'Network|Service' -and $_.Groups[2].Value -notmatch '^(NT AUTHORITY|Font Driver|Window Manager)' })
    $r.sessions = ($sessions -split "\r?\n" | Where-Object { $_ -match 'Session' -and $_ -notmatch 'NT AUTHORITY|Font Driver|Window Manager' }) -join ' | '
    foreach ($m in $luids | Select-Object -First 6) {
        $l = $m.Groups[1].Value
        $out = & klist.exe -li $l 2>&1 | Out-String
        $r.klist[$l] = (($out -split "\r?\n") | Where-Object { $_ -match 'Client:|Server:|Cached Tickets|KerbTicket Encryption|Start Time|Error|failed' } | ForEach-Object { $_.Trim() }) -join ' | '
        $tgt = & klist.exe tgt -li $l 2>&1 | Out-String
        $r.klist["$l-tgt"] = (($tgt -split "\r?\n") | Where-Object { $_ -match 'ServiceName|TargetName|DomainName|Error|failed|KeyType|StartTime' } | ForEach-Object { $_.Trim() }) -join ' | '
    }
} catch { $r.klist.err = $_.Exception.Message }

$r.ev = [ordered]@{}
$r.ev.smbSec = Get-FsEvents 'Microsoft-Windows-SmbClient/Security' 40
$r.ev.smbConn = Get-FsEvents 'Microsoft-Windows-SmbClient/Connectivity' 30
$r.ev.ntlm = Get-FsEvents 'Microsoft-Windows-NTLM/Operational' 30
$r.ev.kerb = Get-FsEvents 'Microsoft-Windows-Kerberos/Operational' 30
$r.ev.sysErr = @(Get-FsEvents 'System' 60 @(1, 2, 3) | Where-Object { $_ -is [string] -or $_.p -match 'Kerberos|Lsa|Netlogon|SMB|Mup|Workstation|DNS|Time' })
$r.ev.aad = Get-FsEvents 'Microsoft-Windows-AAD/Operational' 15 @(1, 2)
$r.ev.sec4625 = @(Get-FsEvents 'Security' 40 | Where-Object { $_ -is [string] -or $_.id -in 4625, 4776, 4771, 4768, 4769 } | Select-Object -First 15)

$j = $r | ConvertTo-Json -Depth 6 -Compress
Write-Output $j
exit 0
