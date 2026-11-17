$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/s1-rebind/Invoke-S1Rebind.ps1')

function Assert($ok, $message) { if (-not $ok) { throw "FAIL $message" } }

$siteKey = 'k' * 16 + 'SITEKEYSECRET'
$url = 'https://usea1-example.sentinelone.net'
$token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ url = $url; site_key = $siteKey } | ConvertTo-Json -Compress)))
$unbound = "server.mgmtServer http://localhost`nserver.site <EMPTY>"
$bound = "server.mgmtServer $url`nserver.site $siteKey"

function Reset {
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:Installs = [Collections.Generic.List[string]]::new()
    $script:Config = $unbound
    $script:BindConfig = $bound
    $script:InstallExit = 0
    # The fake echoes its arguments, as a real error message might.
    $script:SrCtl = { param($c, $a) $script:Calls.Add($a[0]); if ($a[0] -eq 'bind') { $script:Config = $script:BindConfig }
        $text = if ($a[0] -eq 'configure') { $script:Config } else { "ran $($a -join ' ')" }
        @{ Exit = 0; Text = $text } }
    $script:SrFindCtl = { 'C:\Program Files\SentinelOne\Sentinel Agent 24.1.4.257\SentinelCtl.exe' }
    $script:SrSleep = { param($s) }
    $script:Version = '22.3.4.612'
    $script:UpgradeTakes = $false
    $script:Downloads = 0
    $script:Signer = 'CN=SentinelOne Inc., O=SentinelOne Inc., C=US'
    $script:ZipExes = @('C:\w\x\SentinelOneInstaller.exe')
    # An install (-t) replaces the agent when the upgrade takes, or after a clean (-c); the new agent is bound.
    $script:SrRunInstaller = { param($p, $a) $script:Installs.Add($a[0])
        if ($a[0] -eq '-t' -and ($script:UpgradeTakes -or $script:Installs.Contains('-c'))) { $script:Version = '25.1.3.334'; $script:Config = $bound }
        $script:InstallExit }
    $script:SrFileSha256 = { param($p) 'a' * 64 }
    $script:SrAgentVersion = { $script:Version }
    $script:SrSigner = { param($p) $script:Signer }
    $script:SrNewWorkDir = { $script:WorkDir }
    $script:SrDownload = { param($u, $p) $script:Downloads++; Set-Content -LiteralPath $p -Value 'zip' }
    $script:SrExpand = { param($z, $d) $script:ZipExes }
}
function M { Invoke-SrMain -PinVersion '1' -Action Install @args }
function NoSecret($r, $what) {
    $all = $r.Lines -join "`n"
    Assert (-not $all.Contains($token) -and -not $all.Contains($siteKey)) "no token or site key in output: $what"
}

# Empty pin is the off switch.
Reset
$r = Invoke-SrMain -Action Install -SiteToken $token
Assert ($r.ExitCode -eq 0 -and $script:Calls.Count -eq 0) 'empty pin does nothing'

# Empty or malformed tokens are refused before SentinelCtl runs.
foreach ($bad in '', '   ', 'not-base64!', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"url":"https://evil.example.com","site_key":"x"}')),
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{`"url`":`"$url`"}"))) {
    Reset
    $r = M -SiteToken $bad
    Assert ($r.ExitCode -eq 1 -and $script:Calls.Count -eq 0 -and ($r.Lines -join ' ') -match 'refused') "bad token refused: '$bad'"
}

# Only Install binds; the runner's Uninstall action is refused.
Reset
$r = Invoke-SrMain -PinVersion '1' -Action Uninstall -SiteToken $token
Assert ($r.ExitCode -eq 1 -and $script:Calls.Count -eq 0 -and $script:Installs.Count -eq 0) 'runner Uninstall refused'

# Report reads only, needs no token.
Reset
$r = Invoke-SrMain -PinVersion '1' -Section Report
Assert ($r.ExitCode -eq 0 -and -not $script:Calls.Contains('bind') -and ($r.Lines -join ' ') -match 'mgmtServer=http://localhost site=empty') 'report is read only'

# Bind works, verifies, and never prints the token or site key (the fake echoes the token).
Reset
$r = M -SiteToken $token
Assert ($r.ExitCode -eq 0 -and $script:Calls.Contains('bind') -and ($r.Lines -join ' ') -match "mgmtServer=$([regex]::Escape($url)) site=set") 'bind verified'
NoSecret $r 'bind'
Assert (-not ($script:Calls | Where-Object { $_ -match 'unload|disable|unprotect' })) 'never unloads or disables'

# Already bound: nothing changed.
Reset
$script:Config = $bound
$r = M -SiteToken $token
Assert ($r.ExitCode -eq 0 -and -not $script:Calls.Contains('bind')) 'already bound skips bind'

# Bind that does not take: no uninstall without AllowUninstall, even with an installer.
Reset
$script:BindConfig = $unbound
$r = M -SiteToken $token -InstallerPath $PSCommandPath -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'no uninstall without AllowUninstall'
NoSecret $r 'failed bind'

# AllowUninstall without a matching installer hash removes nothing.
Reset
$script:BindConfig = $unbound
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('b' * 64)
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'hash mismatch removes nothing'
Reset
$script:BindConfig = $unbound
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('A' * 64)
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'uppercase hash refused (lowercase hex only)'

# AllowUninstall with a verified installer: the upgrade is tried first; when it does not take, clean then install.
Reset
$script:BindConfig = $unbound
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-t,-c,-t') 'upgrade, then clean then install'
NoSecret $r 'reinstall'

# Clean failure stops before install.
Reset
$script:BindConfig = $unbound
$script:InstallExit = 5
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 1 -and ($script:Installs -join ',') -eq '-t,-c') 'clean failure stops'

# Reinstall: skips bind on a bound agent, downloads the pinned zip, and an upgrade that takes needs no clean.
$script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('s1-rebind-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:WorkDir)
$zipUrl = 'https://resources.example.com/S1/SentinelOneInstaller_windows_64bit.zip'
function Rein { M -SiteToken $token -Reinstall true -InstallerUrl $zipUrl -InstallerSha256 ('a' * 64) @args }
Reset
$script:Config = $bound
$script:UpgradeTakes = $true
$r = Rein
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-t' -and $script:Downloads -eq 1 -and -not $script:Calls.Contains('bind')) 'reinstall upgrades in place'
Assert (($r.Lines -join ' ') -match "agent '22.3.4.612' -> '25.1.3.334'") 'reinstall reports versions'
NoSecret $r 'upgrade'

# Reinstall: a refused upgrade without AllowUninstall leaves the old agent.
Reset
$script:Config = $bound
$r = Rein
Assert ($r.ExitCode -eq 1 -and ($script:Installs -join ',') -eq '-t') 'refused upgrade, no clean without AllowUninstall'

# Reinstall: a refused upgrade with AllowUninstall cleans, installs and ends bound.
Reset
$script:Config = $bound
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-t,-c,-t' -and $script:Version -eq '25.1.3.334') 'refused upgrade, clean and install'
NoSecret $r 'clean and install'

# Reinstall: an upgrade that loses the binding is bound again.
Reset
$script:Config = $bound
$script:UpgradeTakes = $true
$script:SrRunInstaller = { param($p, $a) $script:Installs.Add($a[0]); $script:Version = '25.1.3.334'; $script:Config = $unbound; 0 }
$r = Rein
Assert ($r.ExitCode -eq 0 -and $script:Calls.Contains('bind')) 'lost binding is re-bound'

# Reinstall: a reboot code stops there, with no clean.
Reset
$script:Config = $bound
$script:InstallExit = 103
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-t' -and ($r.Lines -join ' ') -match 'REBOOT NEEDED') 'reboot code stops'

# Reinstall: no agent at all (half removed) installs instead of refusing.
Reset
$script:SrFindCtl = { if ($script:Version -eq '25.1.3.334') { 'C:\Program Files\SentinelOne\Sentinel Agent 25.1.3.334\SentinelCtl.exe' } else { $null } }
$script:Version = ''
$script:UpgradeTakes = $true
$r = Rein
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-t') 'missing agent is installed'
Reset
$script:SrFindCtl = { $null }
$r = M -SiteToken $token -InstallerUrl $zipUrl -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'missing agent without Reinstall is refused'

# Reinstall refusals change nothing: unsigned, wrong zip contents, bad URL, both sources, bad hash.
Reset; $script:Signer = 'CN=Someone Else'
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'unsigned installer refused'
Reset; $script:Signer = ''
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'invalid signature refused'
Reset; $script:ZipExes = @('C:\w\x\a.exe', 'C:\w\x\b.exe')
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'zip with two exes refused'
foreach ($u in 'http://resources.example.com/a.zip', 'https://user@resources.example.com/a.zip', 'https://resources.example.com') {
    Reset
    $r = M -SiteToken $token -Reinstall true -AllowUninstall true -InstallerUrl $u -InstallerSha256 ('a' * 64)
    Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0 -and $script:Downloads -eq 0) "bad url refused: $u"
}
Reset
$r = Rein -InstallerPath $PSCommandPath
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0) 'both InstallerPath and InstallerUrl refused'
Reset; $script:SrFileSha256 = { param($p) 'b' * 64 }
$r = Rein -AllowUninstall true
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 0 -and $script:Downloads -eq 1) 'download hash mismatch refused'
Remove-Item -LiteralPath $script:WorkDir -Recurse -Force

# Redaction catches a token-shaped string that is not the given token.
Assert ((Protect-SrText ('x ' + ('Z' * 40))) -eq 'x [redacted]') 'generic redaction'

Write-Output 's1-rebind tests passed'
