# One-off job module for windows/runner/Invoke-RelianJob.ps1, run as SYSTEM. Read only: changes nothing.
# Finds where an RMM-driven SentinelOne install left its installer and what it logged, so a manual
# reinstall can use the same signed package. Prints: S1 uninstall entries, last boot and pending-reboot
# flags, signed SentinelOne installer files (path, size, date, SHA256, signer) under the RMM agent and
# temp folders, and the last S1-related lines of the RMM agent logs. Token-shaped strings are redacted.
[CmdletBinding()]
param([switch]$ReportOnly)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off  # the loader runs modules under Latest; optional registry values are read below
$out = [Collections.Generic.List[string]]::new()
function Add-Line([string]$s) {
    $s = ($s -replace '[A-Za-z0-9+/=_-]{40,}', '[redacted]') -replace '(?i)(site_?key|token|passphrase|password)\S*\s*[:=]\s*\S+', '$1=[redacted]'
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + '..' }
    $out.Add($s)
}

Add-Line ("host={0} time={1:u}" -f $env:COMPUTERNAME, (Get-Date).ToUniversalTime())
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) { Add-Line ("os={0} {1} arch={2} lastBoot={3:u}" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture, $os.LastBootUpTime.ToUniversalTime()) }
$pend = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'WU' }
$pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pfr) { $pend += "PFR($(@($pfr | Where-Object { $_ }).Count); s1=$(@($pfr | Where-Object { $_ -match 'Sentinel' }).Count))" }
Add-Line ("pendingReboot: " + $(if ($pend) { $pend -join ',' } else { 'none' }))

$unk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($a in @(Get-ItemProperty $unk -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'Sentinel' })) {
    $p = $a.PSObject.Properties
    Add-Line ("uninstallKey: {0} {1} key={2} msi={3} uninst={4} quiet={5}" -f $a.DisplayName, $a.DisplayVersion, $a.PSChildName,
        $(if ($p['WindowsInstaller']) { $a.WindowsInstaller } else { '' }), $(if ($p['UninstallString']) { $a.UninstallString } else { '' }),
        $(if ($p['QuietUninstallString']) { $a.QuietUninstallString } else { '' }))
}
Add-Line ("s1Dirs: " + ((@(Get-ChildItem 'C:\Program Files\SentinelOne' -Directory -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join '; '))
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Sentinel|LogProcessor' })) {
    Add-Line ("svc {0}: {1}/{2}" -f $s.Name, $s.State, $s.StartMode)
}

# RMM agent folders: the service binary's folder and ProgramData.
$roots = [Collections.Generic.List[string]]::new()
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NinjaRMM' })) {
    if ($s.PathName -match '^"?([^"]+\\)[^\\"]+\.exe') { $roots.Add($Matches[1].TrimEnd('\')) }
}
foreach ($r in @('C:\ProgramData\NinjaRMMAgent', 'C:\Windows\Temp', 'C:\ProgramData\Sentinel', 'C:\ProgramData\SentinelOne', "$env:SystemRoot\SystemTemp")) { $roots.Add($r) }
$roots = @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
Add-Line ("roots: " + ($roots -join '; '))

$found = 0
foreach ($r in $roots) {
    foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe', '.msi' -and $_.Name -match 'Sentinel|S1|Installer' -and $_.Length -gt 5MB } | Select-Object -First 15)) {
        try {
        $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $signer = if ($sig -and $sig.SignerCertificate) { ($sig.SignerCertificate.Subject -split ',')[0] } else { '' }
        if ($signer -notmatch 'Sentinel' -and $f.Name -notmatch 'Sentinel') { continue }
        $ver = $f.VersionInfo.ProductVersion
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        Add-Line ("installer: {0} size={1} date={2:u} ver={3} sig={4} signer={5} sha256={6}" -f $f.FullName, $f.Length, $f.LastWriteTimeUtc, $ver,
            $(if ($sig) { $sig.Status } else { '' }), $signer, $(if ($h) { $h.ToLowerInvariant() } else { '' }))
        $found++
        } catch { Add-Line ("installer: {0} unreadable: {1}" -f $f.FullName, $_.Exception.GetType().Name) }
    }
}
Add-Line "installers found: $found"

# What protects the device if SentinelOne is removed: Defender state and policy.
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Add-Line ("defender: amRunningMode={0} rtp={1} avEnabled={2} sigAge={3}" -f $mp.AMRunningMode, $mp.RealTimeProtectionEnabled, $mp.AntivirusEnabled, $mp.AntivirusSignatureAge)
} catch { Add-Line ("defender: Get-MpComputerStatus failed: " + $_.Exception.GetType().Name) }
$dp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -ErrorAction SilentlyContinue
Add-Line ("defenderPolicy: DisableAntiSpyware={0} DisableAntiVirus={1}" -f $dp.DisableAntiSpyware, $dp.DisableAntiVirus)
foreach ($p in @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)) {
    Add-Line ("wsc: {0} state=0x{1:x}" -f $p.displayName, [int]$p.productState)
}

# Last S1-related lines of the RMM agent logs (the URL host is kept; query strings are cut).
$logs = @(foreach ($r in $roots) { if ($r -match 'Ninja') { Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.log', '.txt' } } }) |
    Sort-Object LastWriteTime -Descending | Select-Object -First 12
Add-Line ("logs: " + (($logs | ForEach-Object { "$($_.FullName)@$($_.LastWriteTime.ToString('MM-dd'))" }) -join '; '))
$hits = [Collections.Generic.List[string]]::new()
foreach ($l in $logs) {
    try {
        foreach ($m in @(Select-String -LiteralPath $l.FullName -Pattern 'sentinel' -SimpleMatch -ErrorAction Stop | Select-Object -Last 15)) {
            $hits.Add(("{0}: {1}" -f $l.Name, ($m.Line -replace '\?[^\s"'']*', '?..')))
        }
    } catch { }
}
foreach ($h in @($hits | Select-Object -Last 30)) { Add-Line ("log " + $h) }

$out | ForEach-Object { Write-Output $_ }
