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
    $script:SrRunInstaller = { param($p, $a) $script:Installs.Add($a[0]); $script:InstallExit }
    $script:SrFileSha256 = { param($p) 'a' * 64 }
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

# AllowUninstall with a verified installer: clean then install.
Reset
$script:BindConfig = $unbound
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 0 -and ($script:Installs -join ',') -eq '-c,-t') 'clean then install'
NoSecret $r 'reinstall'

# Clean failure stops before install.
Reset
$script:BindConfig = $unbound
$script:InstallExit = 5
$r = M -SiteToken $token -AllowUninstall true -InstallerPath $PSCommandPath -InstallerSha256 ('a' * 64)
Assert ($r.ExitCode -eq 1 -and $script:Installs.Count -eq 1) 'clean failure stops'

# Redaction catches a token-shaped string that is not the given token.
Assert ((Protect-SrText ('x ' + ('Z' * 40))) -eq 'x [redacted]') 'generic redaction'

Write-Output 's1-rebind tests passed'
