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
            $m = [string]$_.Message; if ($m.Length -gt 260) { $m = $m.Substring(0, 260) }
            [ordered]@{ t = $_.TimeCreated.ToString('s'); id = $_.Id; p = $_.ProviderName; lvl = $_.Level; m = ($m -replace '\s+', ' ') }
        })
    } catch { return @("err: $($_.Exception.Message)") }
}

$r = [ordered]@{}
$os = Get-CimInstance Win32_OperatingSystem
$r.host = $env:COMPUTERNAME
$r.boot = $os.LastBootUpTime.ToString('s')
$r.now = (Get-Date).ToString('s')
$r.drives = [ordered]@{}
foreach ($k in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' })) {
    foreach ($d in @(Get-ChildItem -LiteralPath "$($k.PSPath)\Network" -ErrorAction SilentlyContinue)) { $r.drives["$($k.PSChildName.Substring($k.PSChildName.Length-6)):$($d.PSChildName)"] = $d.GetValue('RemotePath') }
}
foreach ($n in @('SITKASERVER', 'sitkaserver.sitkalaw.local', 'svfs')) { try { $r["dns_$n"] = (@(Resolve-DnsName $n -ErrorAction Stop | ForEach-Object { "$($_.Type)=$($_.IPAddress)$($_.NameHost)" }) -join ',') } catch { $r["dns_$n"] = "err: $($_.Exception.Message)" } }
try { $r.hosts = (@(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -match '^\s*[^#\s]' }) -join ';') } catch { }
$r.ev = [ordered]@{}
$r.ev.smbSec = Get-FsEvents 'Microsoft-Windows-SmbClient/Security' 40
$r.ev.smbConn = @(Get-FsEvents 'Microsoft-Windows-SmbClient/Connectivity' 60 | Where-Object { $_ -is [string] -or $_.id -notin 30810, 30811 })
$r.ev.ntlm = Get-FsEvents 'Microsoft-Windows-NTLM/Operational' 30
$r.ev.kerb = Get-FsEvents 'Microsoft-Windows-Kerberos/Operational' 30
$r.ev.sysErr = @(Get-FsEvents 'System' 60 @(1, 2, 3) | Where-Object { $_ -is [string] -or $_.p -match 'Kerberos|Lsa|Netlogon|SMB|Mup|Workstation|DNS|Time' })
$r.ev.aad = Get-FsEvents 'Microsoft-Windows-AAD/Operational' 15 @(1, 2)
$r.ev.sec4625 = @(Get-FsEvents 'Security' 40 | Where-Object { $_ -is [string] -or $_.id -in 4625, 4776, 4771, 4768, 4769 } | Select-Object -First 15)

$j = $r | ConvertTo-Json -Depth 6 -Compress
Write-Output $j
exit 0
