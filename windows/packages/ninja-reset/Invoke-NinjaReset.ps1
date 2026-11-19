<#
.SYNOPSIS
    Removes a broken or orphaned NinjaOne agent and installs a fresh one with a location token. Run once per device.

.DESCRIPTION
    For a PC that was deleted in NinjaOne (or whose agent is damaged) and will not re-enrol because the old
    agent's services, folders and registry identity are still on disk. The removal follows NinjaOne's own
    "Uninstall NinjaOne Agent" script (NinjaOne script library; see the README): turn off uninstall prevention,
    run the product's MSI uninstall with WRAPPED_ARGUMENTS="--mode unattended", stop the agent processes, delete
    the NinjaRMMAgent, nmsmanager, lockhart and ncstreamer (Ninja Remote) services, remove the install folder
    (C:\Program Files (x86)\<org>-<location>, from the Location value or the service path), C:\ProgramData\NinjaRMMAgent,
    C:\Program Files\NinjaRemote, the NinjaRMMAgent uninstall and Windows Installer product keys, and the whole
    HKLM\SOFTWARE\WOW6432Node\NinjaRMM LLC key (agent settings and the device identity). Then it installs the
    generic agent MSI with TOKENID.

    The installer is the versioned generic MSI on NinjaOne's resources CDN (the public generic-installer link
    redirects there), pinned by InstallerUrl and InstallerSha256 from windows/releases/ninja-reset.json. It is a
    plain download with no login. An empty InstallerSha256 is the off switch: nothing is downloaded or changed.
    The agent updates itself after install, so an older pinned MSI is fine.

    Report-only by default: it lists what it found and changes nothing. With -Apply true, as SYSTEM:
      1. validates the token, downloads the MSI (3 attempts on a timeout, a connection failure or HTTP 408, 429,
         500, 502, 503, 504) and checks its SHA256 and its NinjaOne Authenticode signer, before anything is
         removed (no token, a failed download or a mismatch = nothing removed, no retry on a mismatch);
      2. removes the leftovers and checks they are gone (a service marked for deletion needs a restart: exit 1);
      3. installs the MSI and waits for the NinjaRMMAgent service;
      4. writes C:\ProgramData\Relian\ninja-reset\done.txt. The detection script looks only for that file,
         so the reset runs once per device.

    The location token is a credential (it enrols devices). It is read from the environment variable
    RELIAN_NINJA_TOKENID, never from the command line, and is removed from the environment once read. It is never
    printed or logged, and there is no MSI log (a verbose MSI log records TOKENID).

    The log is C:\ProgramData\Relian\ninja-reset\ninja-reset.log. The last stdout line is one compact JSON record.
    Uninstall changes nothing and exits 0.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM, 64-bit. No external modules.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Apply = '',
    [string]$InstallerUrl = 'https://resources.ninjarmm.com/Agent/20261116b/NinjaOneAgent-x86.msi',
    [string]$InstallerSha256 = 'ad2f476a9db4208714e6eae73aa4947dcb30c1a220a16e2c5201a07b315c3ce4'
)

$ProgressPreference = 'SilentlyContinue'

$NrAgentName = 'NinjaRMMAgent'
$NrServices = @('NinjaRMMAgent', 'nmsmanager', 'lockhart', 'ncstreamer')
$NrProcesses = @('NinjaRMMAgent', 'NinjaRMMAgentPatcher', 'njbar', 'NinjaRMMProxyProcess64', 'ncstreamer')
$NrRegKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC',
    'HKLM:\SOFTWARE\NinjaRMM LLC',
    'Registry::HKEY_USERS\S-1-5-18\Software\NinjaRMM LLC'
)
$NrTokenPattern = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

function Get-NrDir { Join-Path $env:ProgramData 'Relian\ninja-reset' }

function Write-NrLog {
    param([string]$Message)
    $line = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + ' ' + $Message
    Write-Host $line
    try {
        $dir = Get-NrDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'ninja-reset.log') -Value $line
    } catch { Write-Host "log write failed: $_" }
}

# Pure: 'report', 'apply' or 'none'. Throws on bad input. An empty PinVersion or InstallerSha256 is the off switch.
function Get-NrMode {
    param([string]$Action, [string]$Apply, [string]$PinVersion = '1.0.0', [string]$InstallerSha256 = ('0' * 64),
          [string]$InstallerUrl = 'https://example.invalid/agent.msi')
    if ([string]::IsNullOrWhiteSpace($PinVersion) -or [string]::IsNullOrEmpty($InstallerSha256)) { return 'none' }
    if ($InstallerSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'InstallerSha256 must be 64 lowercase hex characters.' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall') { return 'none' }
    $u = $null
    if (-not [uri]::TryCreate($InstallerUrl, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -ne 'https' -or $u.UserInfo) {
        throw 'InstallerUrl must be an https URL without user info.'
    }
    if ($Apply -eq '' -or $Apply -eq 'false') { return 'report' }
    if ($Apply -eq 'true') { return 'apply' }
    throw 'Apply must be true or false.'
}

# Pure: a CIPP variable that the tenant lacks stays literal (%ninjatoken%), which fails this.
function Test-NrToken { param([string]$Token) return ($Token -match $NrTokenPattern) }

# Pure: a download failure worth another attempt. Status 0 = no HTTP response (timeout, DNS, connection).
function Test-NrRetryable { param([int]$Status) return ($Status -eq 0 -or @(408, 429, 500, 502, 503, 504) -contains $Status) }

# Pure: the signer must be NinjaOne and the signature valid.
function Test-NrSigner {
    param([string]$Status, [string]$Subject)
    return ($Status -eq 'Valid' -and $Subject -match 'O="?(NinjaOne|NinjaRMM),? LLC')
}

# Pure: an agent folder is deleted only when it is a direct child of a Program Files root (never the root itself).
function Test-NrSafeFolder {
    param([string]$Path, [string[]]$Roots)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\')
    foreach ($r in $Roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $root = $r.TrimEnd('\')
        if ($p.Length -gt $root.Length + 1 -and $p.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and
            $p.Substring($root.Length + 1).IndexOf('\') -lt 0) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- seams (read)
function Get-NrServiceList {
    @(foreach ($n in $NrServices) {
        $s = Get-CimInstance -ClassName Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s) { [pscustomobject]@{ Name = $s.Name; Path = [string]$s.PathName; State = [string]$s.State } }
    })
}

# Uninstall entries (both views) and Windows Installer product keys whose name is NinjaRMMAgent.
function Get-NrProductKeys {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties['DisplayName'] -and $p.DisplayName -eq $NrAgentName) {
                $us = if ($p.PSObject.Properties['UninstallString']) { [string]$p.UninstallString } else { '' }
                $out.Add([pscustomobject]@{ Key = $k.PSPath; Kind = 'uninstall'; ProductCode = $k.PSChildName; UninstallString = $us })
            }
        }
    }
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' -ErrorAction SilentlyContinue)) {
        $ip = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
        if ($ip -and $ip.PSObject.Properties['DisplayName'] -and $ip.DisplayName -eq $NrAgentName) {
            $out.Add([pscustomobject]@{ Key = $k.PSPath; Kind = 'installer'; ProductCode = ''; UninstallString = '' })
        }
    }
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties['ProductName'] -and $p.ProductName -eq $NrAgentName) {
            $out.Add([pscustomobject]@{ Key = $k.PSPath; Kind = 'installer'; ProductCode = ''; UninstallString = '' })
        }
    }
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed' -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -match $NrAgentName) { $out.Add([pscustomobject]@{ Key = $k.PSPath; Kind = 'installer'; ProductCode = ''; UninstallString = '' }) }
    }
    return $out.ToArray()
}

function Get-NrAgentLocation {
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent', 'HKLM:\SOFTWARE\NinjaRMM LLC\NinjaRMMAgent')) {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties['Location'] -and $p.Location) { return ([string]$p.Location).Replace('/', '\') }
    }
    return ''
}

function Get-NrProgramRoots { @(${env:ProgramFiles(x86)}, $env:ProgramFiles) }

# Folders under Program Files (x86) / Program Files that hold NinjaRMMAgent.exe (the <org>-<location> folders).
function Get-NrAgentExeFolders {
    @(foreach ($r in Get-NrProgramRoots) {
        if ($r) { Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'NinjaRMMAgent.exe') } | ForEach-Object { $_.FullName } }
    })
}

function Test-NrPath { param([string]$Path) return (Test-Path -LiteralPath $Path) }

# ---------------------------------------------------------------- seams (write)
function Invoke-NrProcess {
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSeconds = 900)
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        # Timed out: end it so no MSI transaction is left running under the cleanup.
        try { $p.Kill() } catch { }
        $null = $p.WaitForExit(60000)
        return -1
    }
    return $p.ExitCode
}
function Stop-NrProcesses { foreach ($n in $NrProcesses) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } }
function Remove-NrService {
    param([string]$Name)
    & sc.exe stop $Name | Out-Null
    & sc.exe delete $Name | Out-Null
}
function Remove-NrItem { param([string]$Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
function Save-NrMsi {
    param([string]$Url, [string]$Path)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
}
# The HTTP status of a failed download; 0 for a timeout, connection or DNS failure (worth another attempt);
# -1 for anything else (certificate trust, a bad URL, a local write error), which is not retried.
function Get-NrHttpStatus {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    try { $s = [int]$e.Response.StatusCode; if ($s -gt 0) { return $s } } catch { }
    $network = @('Timeout', 'ConnectFailure', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectionClosed',
                 'ReceiveFailure', 'SendFailure', 'KeepAliveFailure', 'SecureChannelFailure')
    for ($x = $e; $null -ne $x; $x = $x.InnerException) {
        $n = $x.GetType().Name
        if (@('TimeoutException', 'TaskCanceledException', 'SocketException') -contains $n) { return 0 }
        if ($n -eq 'WebException' -and $network -contains [string]$x.Status) { return 0 }
        if ($n -eq 'HttpRequestException' -and $x.PSObject.Properties['HttpRequestError'] -and
            @('NameResolutionError', 'ConnectionError', 'SecureConnectionError') -contains [string]$x.HttpRequestError) { return 0 }
    }
    return -1
}
function Get-NrFileSha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Wait-NrRetry { Start-Sleep -Seconds 15 }
function Get-NrSignature {
    param([string]$Path)
    $s = Get-AuthenticodeSignature -FilePath $Path
    $subject = if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }
    return [pscustomobject]@{ Status = [string]$s.Status; Subject = $subject }
}
function Wait-NrAgentService {
    param([int]$Seconds = 120)
    for ($i = 0; $i -lt $Seconds; $i += 5) {
        $s = Get-Service -Name $NrAgentName -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { return 'Running' }
        Start-Sleep -Seconds 5
    }
    $s = Get-Service -Name $NrAgentName -ErrorAction SilentlyContinue
    if ($s) { return [string]$s.Status } else { return 'absent' }
}
function Set-NrMarker {
    param([string]$Text)
    $dir = Get-NrDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'done.txt') -Value $Text -Encoding UTF8
}

# ---------------------------------------------------------------- logic
# Everything of the old agent that is on disk now. Each item: Kind, Name (what the log shows).
function Get-NrLeftovers {
    $items = [System.Collections.Generic.List[object]]::new()
    $services = @(Get-NrServiceList)
    foreach ($s in $services) { $items.Add([pscustomobject]@{ Kind = 'service'; Name = $s.Name; Path = $s.Path }) }
    $folders = [System.Collections.Generic.List[string]]::new()
    $roots = @(Get-NrProgramRoots)
    $candidates = @(Get-NrAgentExeFolders) + @(Get-NrAgentLocation)
    # The agent service's folder: the Location value can be missing on a damaged install.
    foreach ($s in $services) {
        if ($s.Name -eq $NrAgentName -and $s.Path -match '^\s*"?(.+?\.exe)') { $candidates += $Matches[1].Substring(0, $Matches[1].LastIndexOf('\')) }
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $c = $c.TrimEnd('\')
        if ((Test-NrSafeFolder -Path $c -Roots $roots) -and (Test-NrPath $c) -and -not ($folders -contains $c)) { $folders.Add($c) }
    }
    foreach ($f in @("$env:ProgramData\NinjaRMMAgent", "$env:ProgramFiles\NinjaRemote")) {
        if ((Test-NrPath $f) -and -not ($folders -contains $f)) { $folders.Add($f) }
    }
    foreach ($f in $folders) { $items.Add([pscustomobject]@{ Kind = 'folder'; Name = $f; Path = $f }) }
    foreach ($k in @(Get-NrProductKeys)) { $items.Add([pscustomobject]@{ Kind = $k.Kind; Name = $k.Key; Path = $k.Key; ProductCode = $k.ProductCode; UninstallString = $k.UninstallString }) }
    foreach ($k in $NrRegKeys) { if (Test-NrPath $k) { $items.Add([pscustomobject]@{ Kind = 'registry'; Name = $k; Path = $k }) } }
    return $items.ToArray()
}

function New-NrRecord {
    param([string]$Mode, $Found, $Left, [string]$Agent, [bool]$Changed, [string]$Verdict)
    [ordered]@{
        mode      = $Mode
        found     = @($Found | ForEach-Object { "$($_.Kind): $($_.Name)" })
        left      = @($Left | ForEach-Object { "$($_.Kind): $($_.Name)" })
        agent     = $Agent
        changed   = $Changed
        verdict   = $Verdict
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        version   = '1.0'
    }
}

function Invoke-NrRun {
    param([switch]$Apply, [string]$Token)
    $mode = if ($Apply) { 'apply' } else { 'report' }
    $found = @(Get-NrLeftovers)
    Write-NrLog ("$mode; found $($found.Count): " + (($found | ForEach-Object { "$($_.Kind) $($_.Name)" }) -join '; '))
    if (-not $Apply) {
        $tok = if (Test-NrToken $Token) { 'token ok' } else { 'no valid token' }
        return @{ exitCode = 0; record = (New-NrRecord $mode $found @() '' $false "report only: would remove $($found.Count) item(s) and install the agent ($tok)") }
    }
    if (-not (Test-NrToken $Token)) {
        return @{ exitCode = 1; record = (New-NrRecord $mode $found $found '' $false 'no valid Ninja location token (CIPP variable ninjatoken); nothing changed') }
    }

    # 1. Installer first: a failed download or a bad signature leaves the old state untouched.
    $dir = Get-NrDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $msi = Join-Path $dir ('NinjaOneAgent-{0}.msi' -f [guid]::NewGuid().ToString('N'))
    try {
        $downloadError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try { Save-NrMsi -Url $InstallerUrl -Path $msi; $downloadError = $null; break }
            catch {
                $downloadError = $_.Exception.Message
                $status = Get-NrHttpStatus $_
                Write-NrLog "download attempt $attempt failed (HTTP $status)"
                if (-not (Test-NrRetryable $status) -or $attempt -eq 3) { break }
                Wait-NrRetry
            }
        }
        if ($downloadError) { return @{ exitCode = 1; record = (New-NrRecord $mode $found $found '' $false "MSI download failed, nothing changed: $downloadError") } }
        $hash = Get-NrFileSha256 -Path $msi
        if ($hash -ne $InstallerSha256) {
            return @{ exitCode = 1; record = (New-NrRecord $mode $found $found '' $false "MSI SHA256 $hash is not the pin, nothing changed") }
        }
        $sig = Get-NrSignature -Path $msi
        if (-not (Test-NrSigner -Status $sig.Status -Subject $sig.Subject)) {
            return @{ exitCode = 1; record = (New-NrRecord $mode $found $found '' $false "MSI signature check failed ($($sig.Status) $($sig.Subject)), nothing changed") }
        }

        # 2. Remove the old agent: vendor uninstall first, then whatever it left.
        foreach ($u in @($found | Where-Object { $_.Kind -eq 'uninstall' -and $_.UninstallString -match 'msiexec' -and $_.ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$' })) {
            $exe = @($found | Where-Object { $_.Kind -eq 'folder' } | ForEach-Object { "$($_.Path)\NinjaRMMAgent.exe" } | Where-Object { Test-NrPath $_ }) | Select-Object -First 1
            if ($exe) { Write-NrLog "uninstall prevention off: $(Invoke-NrProcess -FilePath $exe -Arguments '-disableUninstallPrevention NOUI' -TimeoutSeconds 60)" }
            $code = Invoke-NrProcess -FilePath 'msiexec.exe' -Arguments "/x$($u.ProductCode) /qn /norestart WRAPPED_ARGUMENTS=`"--mode unattended`""
            Write-NrLog "msiexec /x $($u.ProductCode) exit $code"
            if ($code -eq -1) {
                return @{ exitCode = 1; record = (New-NrRecord $mode $found @(Get-NrLeftovers) '' $true 'MSI uninstall timed out and was stopped; no cleanup or install done, retry later') }
            }
        }
        Stop-NrProcesses
        foreach ($i in $found) {
            switch ($i.Kind) {
                'service' { Remove-NrService -Name $i.Name; Write-NrLog "service deleted: $($i.Name)" }
            }
        }
        Stop-NrProcesses
        foreach ($i in $found) {
            if ($i.Kind -ne 'service') { Remove-NrItem -Path $i.Path; Write-NrLog "removed $($i.Kind): $($i.Name)" }
        }
        $left = @(Get-NrLeftovers)
        if ($left.Count) {
            return @{ exitCode = 1; record = (New-NrRecord $mode $found $left '' ($found.Count -ne $left.Count) 'leftovers remain (a service marked for deletion needs a restart); agent not installed, retry after a restart') }
        }

        # 3. Fresh agent. No MSI log: it would record TOKENID.
        $code = Invoke-NrProcess -FilePath 'msiexec.exe' -Arguments "/i `"$msi`" TOKENID=$Token /qn /norestart"
        Write-NrLog "msiexec /i generic agent exit $code"
        $agent = Wait-NrAgentService
        if (@(0, 1641, 3010) -notcontains $code -or $agent -ne 'Running') {
            return @{ exitCode = 1; record = (New-NrRecord $mode $found @() $agent ($found.Count -gt 0) "agent install failed: msiexec $code, service $agent") }
        }

        # 4. Done: the marker makes this a one-time reset.
        $verdict = "reset done: removed $($found.Count) item(s), agent $agent"
        Set-NrMarker -Text ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + ' ' + $verdict)
        return @{ exitCode = 0; record = (New-NrRecord $mode $found @() $agent $true $verdict) }
    } finally {
        Remove-NrItem -Path $msi
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $nrMode = Get-NrMode -Action $Action -Apply $Apply -PinVersion $PinVersion -InstallerSha256 $InstallerSha256 -InstallerUrl $InstallerUrl }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($nrMode -eq 'none') { Write-Output 'Nothing to change.'; exit 0 }
    $nrToken = [string]$env:RELIAN_NINJA_TOKENID
    Remove-Item Env:RELIAN_NINJA_TOKENID -ErrorAction SilentlyContinue
    try {
        $run = Invoke-NrRun -Apply:($nrMode -eq 'apply') -Token $nrToken
        Write-NrLog "verdict: $($run.record.verdict)"
        Write-Output ($run.record | ConvertTo-Json -Depth 4 -Compress)
        exit $run.exitCode
    } catch {
        Write-NrLog "error: $_"
        exit 1
    }
}
