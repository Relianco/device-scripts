<#
.SYNOPSIS
    Re-attaches an installed, running SentinelOne Windows agent that lost its management binding
    (server.mgmtServer http://localhost, empty server.site, hourly "Failed to register" events).

.DESCRIPTION
    Run as SYSTEM by the Relian deploy runner. Never stops, unloads or disables the agent, and never
    reboots. Downloads only -InstallerUrl, and only when it is given.
    -Section Report: read only. Prints version, SentinelCtl status and the server.* settings.
    -Action Install (default section): SentinelCtl.exe bind <SiteToken>, then waits up to
      -WaitSeconds for server.mgmtServer to name the token's console and server.site to be set.
      bind is in Windows agents 3.0 and later; it re-reads the console URL from the token.
      Source: https://support.guardz.com/en/articles/14004202 (bind, "Windows 3.0+").
      An in-place upgrade does not re-bind: "If used during an upgrade, it [the token] is ignored."
      Source: https://support.guardz.com/en/articles/10366126
    Installer steps run when bind did not bind, or at once with -Reinstall true (an agent too old for
      its console stays unregistered even when bound; with -Reinstall a missing agent is installed).
      They need -InstallerPath (a local file) or -InstallerUrl (https, downloaded to a SYSTEM-only
      folder; a .zip must hold exactly one .exe), and -InstallerSha256 of that file. The .exe must
      carry a valid Authenticode signature from SentinelOne. Then:
      1. Upgrade in place: -t <token> -q --dont_fail_on_config_preserving_failures. The old agent
         keeps protecting until the new one replaces it. Agents 22.1+ may refuse a local upgrade
         without console approval or a passphrase; a refusal leaves the old agent as it was.
         Exit 100, 103 or 104 means reboot to finish; nothing more is run.
         Source: https://support.guardz.com/en/articles/10088017
      2. Only with -AllowUninstall true, when the upgrade did not take: -c -t <token> (clean; may
         need the passphrase), then -t <token> -q (fresh install). Without it, nothing is removed.
         Source for -c/-t: https://support.guardz.com/en/articles/13750099
      After an upgrade or install the binding is checked and bind runs if it was lost.
    The site token is a base64 JSON object with "url" and "site_key". It is refused unless it
    decodes to an https *.sentinelone.net url and a site_key. Neither the token nor the site key
    is ever printed: every line passes Protect-SrText.
    An empty -PinVersion does nothing and exits 0. Exit 0 when bound (or report), else 1.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = '',
    [string]$SiteToken = '',
    [string]$AllowUninstall = '',
    [string]$InstallerPath = '',
    [string]$InstallerSha256 = '',
    [string]$InstallerUrl = '',
    [string]$Reinstall = '',
    [string]$WaitSeconds = '180'
)

$ErrorActionPreference = 'Stop'

# Seams: tests replace these. The defaults touch the real machine.
$script:SrFindCtl = {
    foreach ($d in @(Get-ChildItem 'C:\Program Files\SentinelOne' -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $p = Join-Path $d.FullName 'SentinelCtl.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $null
}
$script:SrCtl = {
    param([string]$Ctl, [string[]]$Arguments)
    $text = (& $Ctl @Arguments 2>&1 | Out-String)
    @{ Exit = $LASTEXITCODE; Text = $text }
}
$script:SrRunInstaller = {
    param([string]$Path, [string[]]$Arguments)
    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    [int]$p.ExitCode
}
$script:SrFileSha256 = { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$script:SrSleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
$script:SrNewWorkDir = {
    $d = Join-Path $env:SystemRoot ('Temp\relian-s1-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $d)
    # SYSTEM and Administrators only, before anything is written into it.
    & icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'icacls failed' }
    $d
}
$script:SrDownload = {
    param([string]$Url, [string]$Path)
    # Same TLS line as the sysmon and wazuh packages; the progress bar makes a large download crawl on 5.1.
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600
}
$script:SrExpand = {
    param([string]$Zip, [string]$Dir)
    Expand-Archive -LiteralPath $Zip -DestinationPath $Dir -Force
    @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter '*.exe' | ForEach-Object { $_.FullName })
}
$script:SrSigner = {
    param([string]$Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    if ($s.Status -eq 'Valid' -and $s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }
}
$script:SrAgentVersion = {
    $d = @(Get-ChildItem 'C:\Program Files\SentinelOne' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SentinelCtl.exe') } | Sort-Object LastWriteTime -Descending)
    if ($d) { $d[0].Name -replace '^Sentinel Agent ', '' } else { '' }
}

$script:SrSecrets = @()

# Removes the token, its site key and anything token-shaped, then flattens whitespace.
function Protect-SrText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 400)
    $t = [string]$Text
    foreach ($s in $script:SrSecrets) { if ($s) { $t = $t.Replace($s, '[redacted]') } }
    $t = ($t -replace '[A-Za-z0-9+/=_-]{32,}', '[redacted]') -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '..' }
    $t
}

# Returns @{ Url; SiteKey } or $null. Never throws on bad input.
function Read-SrToken {
    param([AllowEmptyString()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    try {
        $o = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Token.Trim())) | ConvertFrom-Json
    } catch { return $null }
    $url = [string]$o.url
    $key = [string]$o.site_key
    if ($url -notmatch '\Ahttps://[a-z0-9-]+(\.[a-z0-9-]+)*\.sentinelone\.net/?\z' -or [string]::IsNullOrWhiteSpace($key)) { return $null }
    @{ Url = $url.TrimEnd('/'); SiteKey = $key }
}

# server.mgmtServer and whether server.site is set, from SentinelCtl configure.
function Get-SrBinding {
    param([string]$Ctl)
    $r = & $script:SrCtl $Ctl @('configure')
    $mgmt = ''; $site = $false
    foreach ($l in ([string]$r.Text -split "`r?`n")) {
        if ($l -match '^\s*server\.mgmtServer\s+(\S+)') { $mgmt = $Matches[1] }
        if ($l -match '^\s*server\.site\s+(\S+)') { $site = $Matches[1] -ne '<EMPTY>' }
    }
    @{ Mgmt = $mgmt; Site = $site }
}

function Test-SrBound {
    param($Binding, [string]$Url)
    $Binding.Site -and $Binding.Mgmt -match '\Ahttps://' -and (-not $Url -or $Binding.Mgmt.TrimEnd('/') -eq $Url)
}

function Invoke-SrMain {
    param([string]$Action, [string]$PinVersion, [string]$Section, [string]$SiteToken, [string]$AllowUninstall,
        [string]$InstallerPath, [string]$InstallerSha256, [string]$InstallerUrl = '', [string]$Reinstall = '', [string]$WaitSeconds = '180')
    $out = [Collections.Generic.List[string]]::new()
    $script:SrSecrets = @($SiteToken)
    function Say([string]$s) { $out.Add((Protect-SrText $s)) }
    function Done([int]$code) { @{ ExitCode = $code; Lines = $out.ToArray() } }

    if ([string]::IsNullOrWhiteSpace($PinVersion)) { Say 'noPin: nothing done'; return Done 0 }
    $report = $Section -eq 'Report'
    if (-not $report -and $Action -ne 'Install') { Say "refused: action '$Action' (only Install binds; uninstall is -AllowUninstall)"; return Done 1 }
    $tok = $null
    if (-not $report) {
        $tok = Read-SrToken $SiteToken
        if (-not $tok) { Say 'refused: site token is empty or not a SentinelOne site token'; return Done 1 }
        $script:SrSecrets = @($SiteToken, $tok.SiteKey)
    }

    $reinstalling = $Reinstall -eq 'true' -and -not $report
    $ctl = & $script:SrFindCtl
    if ($ctl) {
        Say "ctl=$ctl"
        Say ('status: ' + (& $script:SrCtl $ctl @('status')).Text)
        $b = Get-SrBinding $ctl
        Say "before: mgmtServer=$($b.Mgmt) site=$(if ($b.Site) { 'set' } else { 'empty' })"
    } elseif ($reinstalling) {
        Say 'no SentinelCtl.exe: agent missing or half removed; installing'
    } else { Say 'refused: SentinelCtl.exe not found (agent not installed)'; return Done 1 }
    if ($report) { return Done 0 }

    $wait = 180; [void][int]::TryParse($WaitSeconds, [ref]$wait)
    # Binds when not bound, then waits for the binding. True when bound to the token's console.
    function Bind([string]$Ctl) {
        $b = Get-SrBinding $Ctl
        if (Test-SrBound $b $tok.Url) { Say 'bound to the token console'; return $true }
        $r = & $script:SrCtl $Ctl @('bind', $SiteToken)
        Say "bind exit $($r.Exit): $($r.Text)"
        for ($t = 0; $t -le $wait; $t += 15) {
            $b = Get-SrBinding $Ctl
            if (Test-SrBound $b $tok.Url) { break }
            if ($t -lt $wait) { & $script:SrSleep 15 }
        }
        Say "after bind: mgmtServer=$($b.Mgmt) site=$(if ($b.Site) { 'set' } else { 'empty' })"
        Test-SrBound $b $tok.Url
    }

    if (-not $reinstalling) {
        if (Test-SrBound $b $tok.Url) { Say 'already bound to the token console; nothing changed'; return Done 0 }
        if (Bind $ctl) { Say 'bound: agent should register within minutes; check the console'; return Done 0 }
        if ($AllowUninstall -ne 'true') { Say 'not bound; uninstall not allowed (pass AllowUninstall true, or Reinstall true, with an installer)'; return Done 1 }
    }

    # The installer: a local file or a download, pinned by SHA256 and signed by SentinelOne.
    # An empty InstallerSha256 is not an off switch: PinVersion is. Bind needs no installer, so a run
    # that reaches this point asked for the installer and is refused (exit 1) without one.
    if ($InstallerSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or [bool]$InstallerPath -eq [bool]$InstallerUrl) {
        Say 'refused: give one of InstallerPath or InstallerUrl, and a lowercase hex InstallerSha256; nothing changed'; return Done 1
    }
    $exe = $InstallerPath
    if ($InstallerUrl) {
        if ($InstallerUrl -notmatch '\Ahttps://[^/@\s]+/\S+\z') { Say 'refused: InstallerUrl must be https without userinfo'; return Done 1 }
        $dir = & $script:SrNewWorkDir
        $exe = Join-Path $dir ([IO.Path]::GetFileName(([Uri]$InstallerUrl).AbsolutePath))
        # Three tries for any download error: a wrong file is caught by the hash check below, not here.
        for ($n = 1; $n -le 3; $n++) {
            try { & $script:SrDownload $InstallerUrl $exe; break } catch {
                Say "download try $n failed: $($_.Exception.GetType().Name)"
                if ($n -eq 3) { Say 'refused: download failed; nothing changed'; return Done 1 }
                & $script:SrSleep 10
            }
        }
        Say "downloaded $([IO.Path]::GetFileName($exe))"
    }
    if (-not (Test-Path -LiteralPath $exe) -or (& $script:SrFileSha256 $exe) -cne $InstallerSha256) {
        Say 'refused: installer missing or its SHA256 does not match InstallerSha256; nothing changed'; return Done 1
    }
    if ($exe -match '\.zip\z') {
        $inner = @(& $script:SrExpand $exe (Join-Path (Split-Path $exe) 'x'))
        if ($inner.Count -ne 1) { Say "refused: the zip holds $($inner.Count) .exe files, not one; nothing changed"; return Done 1 }
        $exe = $inner[0]
    }
    if ([string](& $script:SrSigner $exe) -notmatch '\ACN="?SentinelOne\b') { Say 'refused: installer is not validly signed by SentinelOne; nothing changed'; return Done 1 }
    Say "installer $([IO.Path]::GetFileName($exe)) signed by SentinelOne"

    $reboot = @(100, 103, 104)
    $before = [string](& $script:SrAgentVersion)
    $u = & $script:SrRunInstaller $exe @('-t', $SiteToken, '-q', '--dont_fail_on_config_preserving_failures')
    $after = [string](& $script:SrAgentVersion)
    Say "upgrade exit ${u}: agent '$before' -> '$after'"
    if ($reboot -contains $u) { Say "REBOOT NEEDED (exit $u): reboot, then run Section Report"; return Done 0 }
    if (-not ($u -eq 0 -and $after -and $after -ne $before)) {
        if (-not $before) { Say 'install failed and no agent is present; Defender covers; see SC-exit-code.txt in C:\Windows\Temp'; return Done 1 }
        if ($AllowUninstall -ne 'true') { Say 'upgrade did not take; old agent left as it was; clean needs AllowUninstall true'; return Done 1 }
        $c = & $script:SrRunInstaller $exe @('-c', '-t', $SiteToken)
        Say "clean exit $c"
        if ($reboot -contains $c) { Say "PROTECTION OFF until reboot (exit $c): clean done, Defender covers; reboot, then run this again"; return Done 1 }
        if ($c -ne 0) { Say 'clean failed; agent left as it was; install not attempted'; return Done 1 }
        $i = & $script:SrRunInstaller $exe @('-t', $SiteToken, '-q')
        $after = [string](& $script:SrAgentVersion)
        Say "install exit ${i}: agent '$after'"
        if ($reboot -contains $i) { Say "REBOOT NEEDED (exit $i): reboot, then run Section Report"; return Done 0 }
        if ($i -ne 0) { Say 'PROTECTION OFF: clean succeeded but install failed; Defender covers; reinstall now'; return Done 1 }
    }
    $ctl = & $script:SrFindCtl
    if (-not $ctl) { Say 'installer finished but SentinelCtl.exe not found; reboot, then run Section Report'; return Done 1 }
    if (Bind $ctl) { Say "agent $after bound: it should register within minutes; check the console"; return Done 0 }
    Say 'installed but not bound; run again without Reinstall to bind'
    Done 1
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }

try {
    $run = Invoke-SrMain -Action $Action -PinVersion $PinVersion -Section $Section -SiteToken $SiteToken -AllowUninstall $AllowUninstall `
        -InstallerPath $InstallerPath -InstallerSha256 $InstallerSha256 -InstallerUrl $InstallerUrl -Reinstall $Reinstall -WaitSeconds $WaitSeconds
} catch {
    $run = @{ ExitCode = 1; Lines = @('error: ' + $_.Exception.GetType().Name) }
}
$run.Lines | ForEach-Object { Write-Output $_ }
exit $run.ExitCode
