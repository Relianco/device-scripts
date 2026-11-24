<#
.SYNOPSIS
    Installs, upgrades and configures Duo Authentication for Windows Logon from Duo's pinned, hash-checked MSI.
.DESCRIPTION
    No key ever goes on a command line: msiexec gets only the MSI path, /qn /norestart and ISADMIN=1 (the MSI's
    silent-install launch condition). The integration settings arrive in-process as -Settings (IKey, SKey, Host and
    Marker, the key's fingerprint) from the caller (the Relian-CIPP Intune app) and are written to Duo's own key,
    HKLM\SOFTWARE\Duo Security\DuoCredProv (64-bit view), with AutoPush 1, FailOpen 0, RdpOnly 0 and EnableSSPRFix 1. Without -Settings
    (runner use) the PC keeps its own settings.

    Plan, from the installed product: none -> install the pin; older than the pin -> upgrade in place, but only from a
    build listed in $script:DuoArchive (Duo's archived zip, pinned by hash), whose MSI is downloaded and checked BEFORE
    anything changes, so the old build can be put back; at or above the pin -> settings only; an unreadable version or
    an unlisted older build -> refused, nothing changed.

    Duo fails closed on this fleet, so a PC must never be left without a working credential provider. Before a change
    every value under Duo's key is captured. After it the package checks the version, that Duo's credential provider is
    registered and its DLL exists, the settings, and that every value present before is still there (Duo's 5.2.x silent
    upgrade drops values; any that went missing are written back first). On a failure: a fresh install is removed again;
    an upgrade is undone (the new product removed, the archived old build installed, every captured value written back);
    a settings-only change gets its old values back. The Visual C++ 2015-2022 runtime the MSI requires is installed from
    Microsoft's pinned build when the MSI's own registry check would fail.

    No restart. msiexec 3010 is success with restartPending true: Windows finishes replacing a DLL that was in use at the
    next restart, and the installed version already reads as the pin. Prints one JSON line without any key.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [hashtable]$Settings
)
$ProgressPreference = 'SilentlyContinue'

# Pins: https://duo.com/docs/checksums (zips) and the SHA-256 of each MSI inside (windows/releases/duo-winlogon.json).
$script:DuoZip = 'https://dl.duosecurity.com/DuoWinLogon_MSIs_Policies_and_Documentation-{0}.zip'
$script:DuoPin = @{
    Version = '6.0.0.4198'; ZipUrl = ($script:DuoZip -f '6.0.0'); ZipSha = '24e30573e1429e6aaa9578969212b82be485df337860394fd68b5dc180b68e7a'
    Msi     = @{ x64 = @('DuoWindowsLogon64.msi', 'ce64870036390a8dcf91b04a68676bccbeacbe3ec51616aad0f3685187258f30')
                 ARM64 = @('DuoWindowsLogonARM64.msi', '58101667e6cdc1d91114ddd1923e33bd5e6d7eaefc54a77ba44a81122bbc9c2e') }
}
# Builds on the fleet in 2026-11 that may be upgraded, because they can be put back.
$script:DuoArchive = @{
    '4.3.1.4861' = @{ ZipUrl = ($script:DuoZip -f '4.3.1'); ZipSha = '0eb91974f11423157a2daa49c77ae6507200dd1efac8d409ba78f340a8f91daf'
                      Msi = @{ x64 = @('DuoWindowsLogon64.msi', '42768db1dc8fa38ec30e8956f37c0b0b421c9b6926af81ad33803048b78a95c7') } }
    '5.2.1.2007' = @{ ZipUrl = ($script:DuoZip -f '5.2.1'); ZipSha = 'c9ae978212e74859fdfc776db571bc7ac286e33d2ad0e44e64eb2026f83c9656'
                      Msi = @{ x64 = @('DuoWindowsLogon64.msi', '61c48c9e9b30d8b8cd575a0f44dca089035977e9b873253c0e99cb54e7283d44')
                               ARM64 = @('DuoWindowsLogonARM64.msi', '60dd7430dc90f7e72d2fae2f6a077e0b3a01cf10d63cf8e67372e421be596b14') } }
}
# Microsoft Visual C++ 2015-2022 Redistributable 14.52.37029.0 (winget Microsoft.VCRedist.2015+.x64 / .arm64).
$script:VcRedist = @{
    x64   = @('https://download.visualstudio.microsoft.com/download/pr/78d061c5-9ef3-42ab-98ed-3309d1095dc4/9C02C9ED120F671B900E6B9471D890E3B2414117A7E53F4AE2E855466FA2B7C9/VC_redist.x64.exe', '9c02c9ed120f671b900e6b9471d890e3b2414117a7e53f4ae2e855466fa2b7c9')
    ARM64 = @('https://download.visualstudio.microsoft.com/download/pr/78d061c5-9ef3-42ab-98ed-3309d1095dc4/3C81BCF5B06156858362400D7066F65ECE38E8ACCB5E687FC65BEF5735F31FFC/VC_redist.arm64.exe', '3c81bcf5b06156858362400d7066f65ece38e8accb5e687fc65bef5735f31ffc')
}
$script:DuoKey = 'SOFTWARE\Duo Security\DuoCredProv'
$script:Managed = @('IKey', 'SKey', 'Host', 'AutoPush', 'FailOpen', 'RdpOnly', 'EnableSSPRFix')
# The fleet's behaviour, read on 2026-11-23: automatic push, fail closed, console and RDP. EnableSSPRFix 1 (6.0.0+, off by
# default) lets Entra SSPR ("Reset password" at sign-in) run instead of an unauthenticated WsiAccount desktop
# (https://duo.com/docs/rdp-faq).
$script:Dwords = @(@('AutoPush', 1), @('FailOpen', 0), @('RdpOnly', 0), @('EnableSSPRFix', 1))
$script:ProviderClsid = '{44E2ED41-48C7-4712-A3C3-250C5E6D5D84}'  # CDuoPasswordCredentialProvider, the same in 4.x to 6.x
$script:MsiOk = @(0, 3010, 1641)

function Open-DuoHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# Seams. Tests replace them.
$script:ReadProducts = {
    foreach ($root in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $key = (Open-DuoHklm).OpenSubKey($root)
        if ($null -eq $key) { continue }
        try {
            foreach ($sub in $key.GetSubKeyNames()) {
                $e = $key.OpenSubKey($sub)
                if ($null -eq $e) { continue }
                try {
                    $name = [string]$e.GetValue('DisplayName', '')
                    if ($name -like 'Duo Authentication for Windows Logon*') {
                        [pscustomobject]@{ Name = $name; Version = [string]$e.GetValue('DisplayVersion', ''); Code = $sub }
                    }
                } finally { $e.Close() }
            }
        } finally { $key.Close() }
    }
}
$script:ReadTree = {
    # Duo's whole key: values (with type) and every subkey (Offline, Users: offline and passwordless enrolments), or $null.
    function Read-DuoKeyTree($k) {
        $t = @{ Values = @{}; Keys = @{} }
        foreach ($n in $k.GetValueNames()) { $t.Values[$n] = @($k.GetValue($n, $null, 'DoNotExpandEnvironmentNames'), [string]$k.GetValueKind($n)) }
        foreach ($s in $k.GetSubKeyNames()) { $c = $k.OpenSubKey($s); if ($null -ne $c) { try { $t.Keys[$s] = Read-DuoKeyTree $c } finally { $c.Close() } } }
        $t
    }
    $k = (Open-DuoHklm).OpenSubKey($script:DuoKey)
    if ($null -eq $k) { return $null }
    try { Read-DuoKeyTree $k } finally { $k.Close() }
}
$script:WriteTree = {
    # Writes a captured tree back under Duo's key. -MissingOnly writes only values and subkeys that are not there now.
    param($Tree, [bool]$MissingOnly)
    function Write-DuoKeyTree($k, $t, [bool]$MissingOnly) {
        $have = @($k.GetValueNames())
        foreach ($n in $t.Values.Keys) { if (-not $MissingOnly -or $have -notcontains $n) { $k.SetValue($n, $t.Values[$n][0], [Microsoft.Win32.RegistryValueKind]$t.Values[$n][1]) } }
        foreach ($s in $t.Keys.Keys) { $c = $k.CreateSubKey($s); try { Write-DuoKeyTree $c $t.Keys[$s] $MissingOnly } finally { $c.Close() } }
    }
    $k = (Open-DuoHklm).CreateSubKey($script:DuoKey)
    try { Write-DuoKeyTree $k $Tree $MissingOnly } finally { $k.Close() }
}
$script:SetValue = {
    param($Name, $Value, $Kind)
    $k = (Open-DuoHklm).CreateSubKey($script:DuoKey)
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() }
}
$script:DeleteValue = {
    param($Name)
    $k = (Open-DuoHklm).OpenSubKey($script:DuoKey, $true)
    if ($null -ne $k) { try { $k.DeleteValue($Name, $false) } finally { $k.Close() } }
}
$script:PolicyValueNames = {
    $k = (Open-DuoHklm).OpenSubKey('SOFTWARE\Policies\Duo Security\DuoCredProv')
    if ($null -eq $k) { return @() }
    try { $k.GetValueNames() } finally { $k.Close() }
}
$script:ProviderRegistered = {
    $hklm = Open-DuoHklm
    $cp = $hklm.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$($script:ProviderClsid)")
    if ($null -eq $cp) { return $false }
    $cp.Close()
    $srv = $hklm.OpenSubKey("SOFTWARE\Classes\CLSID\$($script:ProviderClsid)\InprocServer32")
    if ($null -eq $srv) { return $false }
    try { $dll = [Environment]::ExpandEnvironmentVariables([string]$srv.GetValue('', '')) } finally { $srv.Close() }
    $dll -and (Test-Path -LiteralPath $dll -PathType Leaf)
}
$script:VcPresent = {
    # The Duo MSI's own check (RegLocator CheckVC_*, 64-bit view): any of these with Installed = 1.
    foreach ($a in @('x86', 'x64', 'ARM64')) {
        $k = (Open-DuoHklm).OpenSubKey("SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$a")
        if ($null -ne $k) { try { if ([int]$k.GetValue('Installed', 0) -eq 1) { return $true } } finally { $k.Close() } }
    }
    $false
}
$script:WriteMarker = {
    param($Value)
    $k = (Open-DuoHklm).CreateSubKey('SOFTWARE\Relian\DuoWinLogon')
    try { $k.SetValue('Config', $Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $k.Close() }
}
$script:NewWorkDir = {
    # A fresh folder born with SYSTEM and Administrators only, in SYSTEM's temp folder, so nobody can swap a checked file.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('RelianDuo-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir, $acl)
    $dir
}
$script:RemoveWorkDir = { param($Dir) if ($Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue } }
$script:Download = {
    param($Url, $Dest)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}
$script:Fetch = {
    # Three tries for a timeout, a connection or name failure, or HTTP 408/429/5xx; anything else fails at once. The
    # hash is checked once, after: a mismatch is never retried and the file is removed.
    param($Url, $Sha, $Dest)
    for ($try = 1; ; $try++) {
        try { & $script:Download $Url $Dest; break } catch {
            if ($try -ge 3 -or -not (Test-DuoTransient $_.Exception)) { throw }
            & $script:Pause (5 * $try)
        }
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Dest).Hash.ToLowerInvariant() -ne $Sha) {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        throw "hash mismatch: $Url"
    }
    $Dest
}
$script:ExpandMsi = {
    param($Zip, $Name, $Sha, $Dir)
    $out = Join-Path $Dir ('x' + $Sha.Substring(0, 8))
    Expand-Archive -LiteralPath $Zip -DestinationPath $out -Force
    $msi = Join-Path $out $Name
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $msi).Hash.ToLowerInvariant() -ne $Sha) { throw "hash mismatch: $Name" }
    $msi
}
$script:RunExe = { param($File, $Arguments) (Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru).ExitCode }
$script:RunMsi = { param($Arguments) (Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -Wait -PassThru).ExitCode }
$script:Pause = { param($Seconds) Start-Sleep -Seconds $Seconds }

function Test-DuoTransient($Exception) {
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [Net.WebException]) {
            if (@('Timeout', 'NameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'KeepAliveFailure') -contains [string]$e.Status) { return $true }
            if ($null -ne $e.Response) { try { return @(408, 429, 500, 502, 503, 504) -contains [int]$e.Response.StatusCode } catch { return $false } }
        }
        if ($e -is [TimeoutException] -or $e -is [Net.Sockets.SocketException]) { return $true }
        $e = $e.InnerException
    }
    $false
}

function ConvertTo-DuoVersion([string]$Text) {
    try { return [version]$Text.Trim() } catch { return $null }
}

function Get-DuoArch {
    # Intune's or NinjaOne's 32-bit host sees x86; the real architecture is then in PROCESSOR_ARCHITEW6432.
    $real = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $real = $env:PROCESSOR_ARCHITEW6432 }
    if ($real -eq 'AMD64') { return 'x64' }
    if ($real -eq 'ARM64') { return 'ARM64' }
    ''
}

function Get-DuoInstalled($Products) {
    # The highest readable version, or '' (none, or none readable).
    $best = $null
    foreach ($p in @($Products)) { $v = ConvertTo-DuoVersion $p.Version; if ($null -ne $v -and ($null -eq $best -or $v -gt $best)) { $best = $v } }
    if ($null -eq $best) { return '' }
    $best.ToString()
}

function Get-DuoPlan($Products) {
    if (@($Products).Count -eq 0) { return 'install' }
    $installed = Get-DuoInstalled $Products
    if (-not $installed) { return 'refuse' }
    if ([version]$installed -ge [version]$script:DuoPin.Version) { return 'configure' }
    if ($script:DuoArchive.ContainsKey($installed)) { return 'upgrade' }
    'refuse'
}

function Get-DuoMsiFile($Build, [string]$Arch, [string]$Dir) {
    if (-not $Build.Msi.ContainsKey($Arch)) { throw "no Duo MSI pinned for '$Arch'" }
    $name, $sha = $Build.Msi[$Arch]
    $zip = & $script:Fetch $Build.ZipUrl $Build.ZipSha (Join-Path $Dir ('duo-' + $Build.ZipSha.Substring(0, 8) + '.zip'))
    & $script:ExpandMsi $zip $name $sha $Dir
}

function Install-DuoVcRuntime([string]$Arch, [string]$Dir) {
    if (& $script:VcPresent) { return }
    $url, $sha = $script:VcRedist[$Arch]
    $exe = & $script:Fetch $url $sha (Join-Path $Dir "vc_redist.$Arch.exe")
    $code = & $script:RunExe $exe @('/install', '/quiet', '/norestart')
    # 1638: a newer runtime is already installed.
    if (@(0, 3010, 1638, 1641) -notcontains [int]$code) { throw "VC++ runtime install exit $code" }
    if (-not (& $script:VcPresent)) { throw 'VC++ 2015-2022 runtime still missing' }
}

function Invoke-DuoMsi([string[]]$Arguments) {
    # 1618: another installation is running (Windows Update, an Intune app). Wait and try again rather than give up.
    for ($i = 1; $i -le 6; $i++) {
        $code = [int](& $script:RunMsi $Arguments)
        if ($code -ne 1618) { return $code }
        & $script:Pause 30
    }
    $code
}

function Set-DuoSettings($Settings) {
    foreach ($n in @('IKey', 'SKey', 'Host')) { & $script:SetValue $n $Settings[$n] 'String' }
    foreach ($d in $script:Dwords) { & $script:SetValue $d[0] $d[1] 'DWord' }
}

function Restore-DuoValues($Snapshot, [switch]$MissingOnly) {
    if ($null -ne $Snapshot) { & $script:WriteTree $Snapshot ([bool]$MissingOnly) }
    if (-not $MissingOnly) {
        foreach ($n in $script:Managed) { if ($null -eq $Snapshot -or -not $Snapshot.Values.ContainsKey($n)) { & $script:DeleteValue $n } }
    }
}

function Test-DuoState($Settings, $Snapshot, [string]$MinVersion, [switch]$Exact) {
    # $null when the PC is good, else why not. -Exact: the installed version must be $MinVersion itself (a rollback).
    $installed = Get-DuoInstalled @(& $script:ReadProducts)
    if (-not $installed -or [version]$installed -lt [version]$MinVersion) { return "version '$installed'" }
    if ($Exact -and $installed -ne $MinVersion) { return "version '$installed', expected '$MinVersion'" }
    if (-not (& $script:ProviderRegistered)) { return 'credential provider not registered' }
    $now = & $script:ReadTree
    if ($null -eq $now) { return 'Duo settings key missing' }
    if ($null -ne $Snapshot) {
        foreach ($n in $Snapshot.Values.Keys) { if (-not $now.Values.ContainsKey($n)) { return "value $n missing" } }
        foreach ($s in $Snapshot.Keys.Keys) { if (-not $now.Keys.ContainsKey($s)) { return "subkey $s missing" } }
    }
    if ($null -ne $Settings) {
        foreach ($n in @('IKey', 'SKey', 'Host')) { if (-not $now.Values.ContainsKey($n) -or [string]$now.Values[$n][0] -cne $Settings[$n]) { return "setting $n differs" } }
        foreach ($d in $script:Dwords) { if (-not $now.Values.ContainsKey($d[0]) -or [int]$now.Values[$d[0]][0] -ne $d[1]) { return "setting $($d[0]) differs" } }
    }
    $null
}

function Remove-DuoProducts([string]$Keep) {
    # Removes every Duo product except version $Keep; $true when none of them is left.
    foreach ($p in @(& $script:ReadProducts)) { if ($p.Version -ne $Keep) { [void](Invoke-DuoMsi @('/x', $p.Code, '/qn', '/norestart')) } }
    -not @(@(& $script:ReadProducts) | Where-Object { $_.Version -ne $Keep }).Count
}

function Invoke-DuoWinLogon($Settings) {
    $r = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'failed'; action = ''; before = ''; after = ''; restartPending = $false; error = $null }
    $dir = $null
    $keepDir = $false
    $changed = $false
    $snapshot = $null
    $plan = ''
    try {
        $override = @(@(& $script:PolicyValueNames) | Where-Object { $script:Managed -contains $_ })
        if ($override.Count) { $r.status = 'refused'; $r.error = "Duo policy key sets $($override -join ', ')"; return ($r | ConvertTo-Json -Compress) }
        $products = @(& $script:ReadProducts)
        $r.before = Get-DuoInstalled $products
        $plan = Get-DuoPlan $products
        $r.action = $plan
        if ($plan -eq 'refuse') { $r.status = 'refused'; $r.error = "no pinned rollback build for '$($r.before)'"; return ($r | ConvertTo-Json -Compress) }
        $arch = Get-DuoArch
        $snapshot = & $script:ReadTree
        $dir = & $script:NewWorkDir
        $old = $null
        if ($plan -eq 'upgrade') { $old = Get-DuoMsiFile $script:DuoArchive[$r.before] $arch $dir }  # before anything changes
        if ($plan -ne 'configure') {
            Install-DuoVcRuntime $arch $dir
            $new = Get-DuoMsiFile $script:DuoPin $arch $dir
            $changed = $true
            $code = Invoke-DuoMsi @('/i', ('"' + $new + '"'), '/qn', '/norestart', 'ISADMIN=1')
            if ($script:MsiOk -notcontains [int]$code) { throw "msiexec exit $code" }
            if ([int]$code -ne 0) { $r.restartPending = $true }
            if ($plan -eq 'upgrade') { Restore-DuoValues $snapshot -MissingOnly }
        }
        if ($null -ne $Settings) { $changed = $true; Set-DuoSettings $Settings }
        $min = $script:DuoPin.Version
        if ($plan -eq 'configure') { $min = $r.before }
        $why = Test-DuoState $Settings $snapshot $min
        if ($why) { throw $why }
        if ($null -ne $Settings -and $Settings['Marker']) { & $script:WriteMarker $Settings['Marker'] }
        $r.status = @{ install = 'installed'; upgrade = 'upgraded'; configure = 'configured' }[$plan]
    } catch {
        $r.error = [string]$_.Exception.Message
        if ($changed) {
            try {
                if ($plan -eq 'install') {
                    if (-not (Remove-DuoProducts '')) { throw 'Duo could not be removed again' }
                } elseif ($plan -eq 'upgrade') {
                    if (-not (Remove-DuoProducts $r.before)) { throw 'the new build could not be removed' }
                    if (-not @(@(& $script:ReadProducts) | Where-Object { $_.Version -eq $r.before }).Count) {
                        $code = Invoke-DuoMsi @('/i', ('"' + $old + '"'), '/qn', '/norestart', 'ISADMIN=1')
                        if ($script:MsiOk -notcontains [int]$code) { throw "old build msiexec exit $code" }
                    }
                    Restore-DuoValues $snapshot
                    $back = Test-DuoState $null $snapshot $r.before -Exact
                    if ($back) { throw $back }
                    $r.status = 'rolledBack'
                } else {
                    Restore-DuoValues $snapshot
                }
            } catch {
                # The old build's MSI stays in the SYSTEM-only work folder for a person to finish by hand.
                $keepDir = $true
                $r.error += "; ROLLBACK FAILED ($($_.Exception.Message)): check this PC now; old MSI kept in $dir"
            }
        }
    } finally {
        if ($dir -and -not $keepDir) { & $script:RemoveWorkDir $dir }
    }
    try { $r.after = Get-DuoInstalled @(& $script:ReadProducts) } catch { $r.after = '' }
    $r | ConvertTo-Json -Compress
}

function Invoke-DuoUninstall {
    [void](Remove-DuoProducts '')
    $left = @(& $script:ReadProducts).Count
    if ($left) { return '{"version":"1","status":"failed","error":"Duo is still installed"}' }
    '{"version":"1","status":"uninstalled"}'
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
# An empty pin disables the package: nothing is read or changed.
if ([string]::IsNullOrWhiteSpace($PinVersion)) { exit 0 }
if ($PinVersion -ne $script:DuoPin.Version) { [Console]::Error.WriteLine("PinVersion $PinVersion is not this package's pin $($script:DuoPin.Version)"); exit 1 }
if ($Action -eq 'Uninstall') { $line = Invoke-DuoUninstall; Write-Output $line; if ($line.Contains('"uninstalled"')) { exit 0 }; exit 1 }
if (@('Install', 'Update', 'Repair') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
$line = Invoke-DuoWinLogon -Settings $Settings
Write-Output $line
if ($line -match '"status":"(installed|upgraded|configured)"') { exit 0 }
exit 1
