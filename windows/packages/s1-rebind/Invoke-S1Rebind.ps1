<#
.SYNOPSIS
    Re-attaches an installed, running SentinelOne Windows agent that lost its management binding
    (server.mgmtServer http://localhost, empty server.site, hourly "Failed to register" events).

.DESCRIPTION
    Run as SYSTEM by the Relian deploy runner. Downloads nothing. Never stops, unloads or disables
    the agent, and never reboots.
    -Section Report: read only. Prints version, SentinelCtl status and the server.* settings.
    -Action Install (default section): SentinelCtl.exe bind <SiteToken>, then waits up to
      -WaitSeconds for server.mgmtServer to name the token's console and server.site to be set.
      bind is in Windows agents 3.0 and later; it re-reads the console URL from the token.
      Source: https://support.guardz.com/en/articles/14004202 (bind, "Windows 3.0+").
      An in-place upgrade does not re-bind: "If used during an upgrade, it [the token] is ignored."
      Source: https://support.guardz.com/en/articles/10366126
    -AllowUninstall true, -InstallerPath and -InstallerSha256: only when bind did not bind, run the
      local installer with -c (clean) then -t <token> -q (fresh install). Without all three, nothing
      is removed. Source for -c/-t: https://support.guardz.com/en/articles/13750099
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
        [string]$InstallerPath, [string]$InstallerSha256, [string]$WaitSeconds = '180')
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

    $ctl = & $script:SrFindCtl
    if (-not $ctl) { Say 'refused: SentinelCtl.exe not found (agent not installed)'; return Done 1 }
    Say "ctl=$ctl"
    Say ('status: ' + (& $script:SrCtl $ctl @('status')).Text)
    $b = Get-SrBinding $ctl
    Say "before: mgmtServer=$($b.Mgmt) site=$(if ($b.Site) { 'set' } else { 'empty' })"
    if ($report) { return Done 0 }
    if (Test-SrBound $b $tok.Url) { Say 'already bound to the token console; nothing changed'; return Done 0 }

    $r = & $script:SrCtl $ctl @('bind', $SiteToken)
    Say "bind exit $($r.Exit): $($r.Text)"
    $wait = 180; [void][int]::TryParse($WaitSeconds, [ref]$wait)
    for ($t = 0; $t -le $wait; $t += 15) {
        $b = Get-SrBinding $ctl
        if (Test-SrBound $b $tok.Url) { break }
        if ($t -lt $wait) { & $script:SrSleep 15 }
    }
    Say "after bind: mgmtServer=$($b.Mgmt) site=$(if ($b.Site) { 'set' } else { 'empty' })"
    if (Test-SrBound $b $tok.Url) { Say 'bound: agent should register within minutes; check the console'; return Done 0 }

    if ($AllowUninstall -ne 'true') { Say 'not bound; uninstall not allowed (pass AllowUninstall true with InstallerPath and InstallerSha256)'; return Done 1 }
    if (-not $InstallerPath -or -not (Test-Path -LiteralPath $InstallerPath) -or $InstallerSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        (& $script:SrFileSha256 $InstallerPath) -cne $InstallerSha256) {
        Say 'refused: uninstall needs an existing InstallerPath whose SHA256 matches InstallerSha256'; return Done 1
    }
    $c = & $script:SrRunInstaller $InstallerPath @('-c', '-t', $SiteToken)
    Say "clean exit $c"
    if ($c -ne 0) { Say 'clean failed; agent left as it was; install not attempted'; return Done 1 }
    $i = & $script:SrRunInstaller $InstallerPath @('-t', $SiteToken, '-q')
    Say "install exit $i"
    if ($i -ne 0) { Say 'PROTECTION OFF: clean succeeded but install failed; reinstall now'; return Done 1 }
    Say 'reinstalled with the site token; reboot may be needed before it registers'
    Done 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }

try {
    $run = Invoke-SrMain -Action $Action -PinVersion $PinVersion -Section $Section -SiteToken $SiteToken -AllowUninstall $AllowUninstall `
        -InstallerPath $InstallerPath -InstallerSha256 $InstallerSha256 -WaitSeconds $WaitSeconds
} catch {
    $run = @{ ExitCode = 1; Lines = @('error: ' + $_.Exception.GetType().Name) }
}
$run.Lines | ForEach-Object { Write-Output $_ }
exit $run.ExitCode
