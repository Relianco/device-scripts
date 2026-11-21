<#
.SYNOPSIS
    Installs or updates the virtio-win drivers and the QEMU guest agent on a QEMU/Proxmox Windows guest.

.DESCRIPTION
    Two hash-pinned MSIs, each its own msiexec run, drivers first: virtio-win-gt-x64.msi (the VirtIO drivers) and
    qemu-ga-x86_64.msi (the guest agent and its VSS provider). The Burn bundle is not used: it rolled back the drivers
    when the agent MSI failed, which left a guest without its network driver.
    Each component is decided on its own MSI record; the bundle's uninstall record is reported, never trusted.
    Before a step it refuses (exit 20) while a Comet backup job or a VSS snapshot runs. Before the agent MSI it stops
    QEMU-GA and the VSS provider and waits up to 120 s until neither runs nor is marked for delete; else it skips
    the agent MSI (exit 21). The drivers stay either way.
    Before the driver MSI it saves each Up adapter's addresses, gateways and DNS to network-<time>.json. A driver
    update can give the NIC a new instance; after it, adapters are matched by MAC and hand-set DNS, static addresses
    and static gateways that went missing are set again.
    Then QEMU-GA is set to Automatic and started, the VSS provider kept from Disabled, and VssOption written.
    On a machine that is not a QEMU guest it prints notQemuGuest, exits 0 and changes nothing.
    It never restarts the machine; RebootRequired reports an installer's 3010 or 1641.
    No Uninstall: removing VirtIO storage drivers can leave the VM unbootable.
    Without the hypervisor's guest-agent channel the run prints agentChannelMissing and exits 0.
    Prints one JSON line. Exit 0 ok, 1 failure, 20 backupRunning, 21 agentServiceHeld, 22 agentInstallFailed,
    130 cancelled.
#>
# Parameters are not Mandatory: a mandatory parameter prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
# The URLs and hashes are the pins in windows/releases/virtio-guest-tools.json: content-addressed copies of the vendor
# files (sourceUrl there). The runner copies this script alone, so the values are inlined. PinVersion is the driver pin.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$DriverUrl = 'https://relianpub.blob.core.windows.net/pub/sec/virtio-win-gt-x64-0.1.302-4f4388468a7ac5286bd1f1924ef02e7281a60a600390a7cfcfd55809efc0889f.msi',
    [string]$DriverSha256 = '4f4388468a7ac5286bd1f1924ef02e7281a60a600390a7cfcfd55809efc0889f',
    [string]$AgentVersion = '110.2.3',
    [string]$AgentUrl = 'https://relianpub.blob.core.windows.net/pub/sec/qemu-ga-x86_64-110.2.3-19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed.msi',
    [string]$AgentSha256 = '19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed',
    [string]$CancelPath = '',
    # Empty leaves the agent's VSS backup type alone. 5 (copy-only) keeps hypervisor backups out of SQL or Comet backup chains.
    [string]$VssOption = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:VgAgent = 'QEMU-GA'
$script:VgVss = 'QEMU Guest Agent VSS Provider'
$script:VgOk = @(0, 3010, 1641)

function Test-VgPinHash([string]$Sha256) {
    # 64 identical nibbles is a placeholder.
    $Sha256 -cmatch '^[0-9a-f]{64}$' -and $Sha256 -cnotmatch '^(.)\1{63}$'
}

function Test-VgUrl([string]$Url) {
    try { $uri = [Uri]$Url } catch { return $false }
    $uri.IsAbsoluteUri -and $uri.Scheme -eq 'https' -and [string]::IsNullOrEmpty($uri.UserInfo) -and $Url -notmatch '^[^/]*//[^/]*@'
}

function Compare-VgVersion([string]$A, [string]$B) { ([version]$A).CompareTo([version]$B) }
function Test-VgAtLeast([string]$Have, [string]$Want) { $Have -match '^\d+(\.\d+){1,3}$' -and (Compare-VgVersion $Have $Want) -ge 0 }

function Test-VgCancelled([string]$CancelPath) {
    $env:RELIAN_DEPLOY_CANCEL -eq '1' -or (-not [string]::IsNullOrWhiteSpace($CancelPath) -and (Test-Path -LiteralPath $CancelPath))
}

# Seams. Tests replace these; the defaults touch the real device.
$script:VgComputer = { Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Manufacturer, Model }
$script:VgPnpIds = { @(Get-CimInstance -ClassName Win32_PnPEntity | ForEach-Object { [string]$_.DeviceID }) }
# Highest DisplayVersion of a Red Hat uninstall entry with this DisplayName ('' when none).
$script:VgInstalledVersion = {
    param([string]$Name)
    $best = ''
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            # The driver MSI and the bundle say 'Red Hat, Inc.', the agent MSI 'RedHat'.
            if ($null -eq $p -or [string]$p.DisplayName -cne $Name -or [string]$p.Publisher -notmatch '^Red ?Hat') { continue }
            $v = [string]$p.DisplayVersion
            if ($v -match '^\d+(\.\d+){1,3}$' -and ($best -eq '' -or (Compare-VgVersion $v $best) -gt 0)) { $best = $v }
        }
    }
    $best
}
$script:VgGetService = {
    param($Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    [pscustomobject]@{ Status = [string]$s.Status; StartType = [string]$s.StartType }
}
$script:VgSetStartType = { param($Name, $Type) Set-Service -Name $Name -StartupType $Type }
$script:VgStartService = { param($Name) Start-Service -Name $Name }
$script:VgStopService = { param($Name) Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
# Held: not stopped, or marked for delete (DeleteFlag), which makes the agent MSI's RegisterCom fail with 1603.
$script:VgServiceHeld = {
    param($Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $false }
    [string]$s.Status -ne 'Stopped' -or [int](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'DeleteFlag' -ErrorAction SilentlyContinue).DeleteFlag -eq 1
}
$script:VgProcesses = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'backup-tool.exe'" | Select-Object Name, CommandLine) }
$script:VgVssWriters = { & (Join-Path $env:SystemRoot 'System32\vssadmin.exe') list writers | Out-String }
# Up adapters. Manual marks what was set by hand: PrefixOrigin Manual, route Protocol NetMgmt. StaticDns is the
# interface's NameServer value, which holds only hand-set servers; Dns is what the adapter uses now.
$script:VgGetNet = {
    foreach ($a in @(Get-NetAdapter | Where-Object { [string]$_.Status -eq 'Up' })) {
        $i = $a.ifIndex
        $ns = foreach ($stack in @('Tcpip', 'Tcpip6')) {
            [string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$stack\Parameters\Interfaces\$($a.InterfaceGuid)" -Name 'NameServer' -ErrorAction SilentlyContinue).NameServer
        }
        [pscustomobject]@{
            Mac = [string]$a.MacAddress
            Alias = [string]$a.Name
            Index = [int]$i
            Dhcp = [string](Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled'
            Addresses = @(Get-NetIPAddress -InterfaceIndex $i -ErrorAction SilentlyContinue | Where-Object { [string]$_.PrefixOrigin -ne 'WellKnown' } |
                ForEach-Object { [pscustomobject]@{ Ip = [string]$_.IPAddress; Prefix = [int]$_.PrefixLength; Manual = [string]$_.PrefixOrigin -eq 'Manual' } })
            Gateways = @(Get-NetRoute -InterfaceIndex $i -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') } |
                ForEach-Object { [pscustomobject]@{ Prefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; Manual = [string]$_.Protocol -eq 'NetMgmt' } })
            Dns = @((Get-DnsClientServerAddress -InterfaceIndex $i -ErrorAction SilentlyContinue).ServerAddresses)
            StaticDns = @($ns -split '[,\s]+' | Where-Object { $_ })
        }
    }
}
# $Nic is the adapter as it is now (its new instance); Index, not the alias, so wildcard characters cannot widen the match.
$script:VgAddIp = {
    param($Nic, $Ip, $Prefix, $Dhcp)
    if (-not $Dhcp -and $Ip -notmatch ':') { Set-NetIPInterface -InterfaceIndex $Nic.Index -AddressFamily IPv4 -Dhcp Disabled }
    New-NetIPAddress -InterfaceIndex $Nic.Index -IPAddress $Ip -PrefixLength $Prefix | Out-Null
}
$script:VgAddRoute = { param($Nic, $Prefix, $NextHop) New-NetRoute -InterfaceIndex $Nic.Index -DestinationPrefix $Prefix -NextHop $NextHop | Out-Null }
$script:VgSetDns = { param($Nic, [string[]]$Servers) Set-DnsClientServerAddress -InterfaceIndex $Nic.Index -ServerAddresses $Servers }
$script:VgVssKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\QEMU Guest Agent VSS Provider'
$script:VgGetVssOption = { [string](Get-ItemProperty -LiteralPath $script:VgVssKey -Name 'VssOption' -ErrorAction SilentlyContinue).VssOption }
$script:VgSetVssOption = { param([int]$Value) Set-ItemProperty -LiteralPath $script:VgVssKey -Name 'VssOption' -Value $Value -Type DWord }
$script:DownloadFile = {
    param($Url, $Destination)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    # fedorapeople's bot check serves an HTML challenge to any User-Agent containing Mozilla, which PS 5.1 sends by default.
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300 -UserAgent 'relian-device-scripts'
}
$script:RetryDelay = { param($Seconds) Start-Sleep -Seconds ([int]$Seconds) }
# msiexec is waited on and never killed.
$script:VgRunMsi = {
    param([string[]]$Arguments)
    [int](Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden).ExitCode
}

# Retry only timeouts, connection and DNS failures, and HTTP 408, 429 and 5xx gateway codes.
function Test-VgTransient($Exception) {
    for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [System.TimeoutException] -or $e -is [System.Net.Sockets.SocketException]) { return $true }
        if ($e -is [System.Net.WebException] -and [string]$e.Status -in @('Timeout', 'ConnectFailure', 'NameResolutionFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'KeepAliveFailure')) { return $true }
        if ($e.PSObject.Properties.Name -contains 'Response' -and $null -ne $e.Response -and $e.Response.PSObject.Properties.Name -contains 'StatusCode') {
            return [int]$e.Response.StatusCode -in @(408, 429, 500, 502, 503, 504)
        }
        if ($e.PSObject.Properties.Name -contains 'StatusCode' -and $null -ne $e.StatusCode) {
            return [int]$e.StatusCode -in @(408, 429, 500, 502, 503, 504)
        }
    }
    return $false
}

# 0 saved and verified, 1 failed. A hash mismatch is not retried.
function Save-VgPayload([string]$Url, [string]$Destination, [string]$Sha256) {
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $script:VgDownloadError = $_.Exception.Message
            if ($null -ne $_.Exception.InnerException) { $script:VgDownloadError += ' | ' + $_.Exception.InnerException.Message }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if (-not (Test-VgTransient $_.Exception)) { return 1 }
            if ($attempt -lt 3) { [void](& $script:RetryDelay -Seconds $delays[$attempt - 1]) }
            continue
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
        if ($actual -ceq $Sha256) { return 0 }
        $script:VgDownloadError = 'hash mismatch'
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        return 1
    }
    return 1
}

# Why a backup is running, or ''. Idle Comet keeps delegate-server, elevator-server and stream helpers running;
# any other backup-tool command line (or an unreadable one) is a job. Writer states 2-5 are a snapshot in progress.
function Get-VgBackupBusy {
    foreach ($p in @(& $script:VgProcesses)) {
        # Match only after the executable token, so a path containing "stream" cannot hide a job.
        $cmd = [string]$p.CommandLine
        $rest = if ($cmd -match '^\s*(?:"[^"]*"|\S+)\s*(.*)$') { $Matches[1] } else { $null }
        if ($null -eq $rest -or $rest -notmatch '(?i)^(cmd\s+)?(-(?!Action=)\w+=\S*\s+)*(-Action=)?(delegate-server|elevator-server|stream)(\s|$)') { return 'a Comet backup job is running' }
    }
    $writers = [string](& $script:VgVssWriters)
    # Fail closed: no output means the VSS state is unknown.
    if ([string]::IsNullOrWhiteSpace($writers)) { return 'VSS writer state is unreadable' }
    if ($writers -match '\[[2-5]\]') { return 'a VSS writer is in a snapshot' }
    ''
}

# Polls every 5 s, 24 times at most (120 s); returns once Test is false or the time is up.
function Wait-Vg([scriptblock]$Test) {
    for ($i = 0; (& $Test) -and $i -lt 24; $i++) { [void](& $script:RetryDelay -Seconds 5) }
}

# The file is hashed again just before msiexec, so a swap after the download check cannot run.
function Invoke-VgMsi([string]$Mode, [string]$Path, [string]$Sha256, [string]$Log) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -cne $Sha256) { throw "$Path changed after its hash check" }
    [int](& $script:VgRunMsi @($Mode, ('"{0}"' -f $Path), '/qn', '/norestart', '/l*v', ('"{0}"' -f $Log)))
}

# Waits for the saved adapters (by MAC), then sets back what was set by hand and is missing.
function Restore-VgNetwork($Saved, $r) {
    for ($i = 0; ; $i++) {
        $now = @(& $script:VgGetNet | Where-Object { $_ })
        $macs = @($now | ForEach-Object { $_.Mac })
        if (@($Saved | Where-Object { $_.Mac -notin $macs }).Count -eq 0 -or $i -ge 24) { break }
        [void](& $script:RetryDelay -Seconds 5)
    }
    $applied = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    # One change per try: a failed address must not stop the gateway or DNS.
    function Apply([string]$What, [scriptblock]$Change) { try { & $Change; $applied.Add($What) } catch { $errors.Add("$What : $($_.Exception.Message)") } }
    foreach ($s in $Saved) {
        $c = @($now | Where-Object { $_.Mac -eq $s.Mac }) | Select-Object -First 1
        if ($null -eq $c) { $missing.Add($s.Mac); continue }
        foreach ($a in @($s.Addresses | Where-Object { $_.Manual })) {
            if ($a.Ip -notin @($c.Addresses | ForEach-Object { $_.Ip })) { Apply "$($c.Alias) ip $($a.Ip)/$($a.Prefix)" { & $script:VgAddIp $c $a.Ip $a.Prefix $s.Dhcp } }
        }
        foreach ($g in @($s.Gateways | Where-Object { $_.Manual })) {
            if ($g.NextHop -notin @($c.Gateways | ForEach-Object { $_.NextHop })) { Apply "$($c.Alias) route $($g.Prefix) $($g.NextHop)" { & $script:VgAddRoute $c $g.Prefix $g.NextHop } }
        }
        if (@($s.StaticDns).Count -gt 0 -and (@($s.StaticDns) -join ',') -ne (@($c.StaticDns) -join ',')) {
            Apply "$($c.Alias) dns $(@($s.StaticDns) -join ' ')" { & $script:VgSetDns $c @($s.StaticDns) }
        }
    }
    $r.NetReapplied = @($applied)
    if ($errors.Count -gt 0) { $r.NetError = @($errors) }
    if ($missing.Count -gt 0) { $r.NetMissing = @($missing) }
}

# Agent step. Returns 0, or the exit code for the run; the drivers are never touched here.
function Invoke-VgAgentStep($r, [string]$Cache, [string]$LogRoot, [string]$Stamp, [string]$AgentUrl, [string]$AgentSha256, [bool]$Repair) {
    $busy = Get-VgBackupBusy
    if ($busy) { $r.AgentStep = 'backupRunning'; $r.AgentReason = $busy; return 20 }
    $msi = Join-Path $Cache 'qemu-ga-x86_64.msi'
    $script:VgDownloadError = ''
    if ((Save-VgPayload -Url $AgentUrl -Destination $msi -Sha256 $AgentSha256) -ne 0) { $r.AgentStep = 'error'; $r.AgentReason = 'agent download failed or hash mismatch'; $r.DownloadError = $script:VgDownloadError; return 1 }
    foreach ($name in @($script:VgAgent, $script:VgVss)) { if ($null -ne (& $script:VgGetService $name)) { & $script:VgStopService $name } }
    Wait-Vg { @(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ }).Count -gt 0 }
    $held = @(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ })
    if ($held.Count -gt 0) { $r.AgentStep = 'agentServiceHeld'; $r.AgentReason = "still running or marked for delete after 120 s: $($held -join ', ')"; return 21 }
    # A backup may have started during the wait.
    $busy = Get-VgBackupBusy
    if ($busy) { $r.AgentStep = 'backupRunning'; $r.AgentReason = $busy; return 20 }
    # /famus reinstalls a registered agent whose service is gone; /i installs or upgrades.
    $code = Invoke-VgMsi -Mode $(if ($Repair) { '/famus' } else { '/i' }) -Path $msi -Sha256 $AgentSha256 -Log (Join-Path $LogRoot "agent-$Stamp.log")
    $r.AgentExit = $code
    if ($code -notin $script:VgOk) { $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = "agent installer failed with $code"; return 22 }
    $r.RebootRequired = $r.RebootRequired -or $code -ne 0
    $r.AgentStep = 'installed'
    return 0
}

function Invoke-VgMain {
    param([string]$Action, [string]$PinVersion, [string]$DriverUrl, [string]$DriverSha256, [string]$AgentVersion, [string]$AgentUrl, [string]$AgentSha256, [string]$CancelPath, [string]$LogRoot, [string]$VssOption = '')
    $r = [ordered]@{ Package = 'virtio-guest-tools'; Action = $Action; PinVersion = $PinVersion; AgentPinVersion = $AgentVersion; Status = 'error' }
    function Done([int]$Code, [string]$Reason = '') { if ($Reason) { $r.Reason = $Reason }; @{ ExitCode = $Code; Result = $r } }

    # An empty hash or an empty pin disables the package before anything else is checked.
    if ([string]::IsNullOrWhiteSpace($DriverSha256) -or [string]::IsNullOrWhiteSpace($AgentSha256) -or [string]::IsNullOrWhiteSpace($PinVersion)) { $r.Status = 'disabled'; return Done 0 }
    if (-not (Test-VgPinHash $DriverSha256) -or -not (Test-VgPinHash $AgentSha256)) { return Done 1 'invalid installer hash' }
    if (-not (Test-VgUrl $DriverUrl) -or -not (Test-VgUrl $AgentUrl)) { return Done 1 'installer URL must be https with no userinfo' }
    if ($Action -notin @('Install', 'Update', 'Repair')) { return Done 1 "action $Action is not supported" }
    if ($PinVersion -notmatch '^\d+(\.\d+){1,3}$' -or $AgentVersion -notmatch '^\d+(\.\d+){1,3}$') { return Done 1 'invalid pin version' }
    if ($VssOption -notmatch '^[1-5]?$') { return Done 1 'VssOption must be empty or 1-5' }

    $cs = & $script:VgComputer
    $pnp = @(& $script:VgPnpIds)
    $r.Manufacturer = [string]$cs.Manufacturer
    $r.Model = [string]$cs.Model
    # Red Hat VirtIO (1AF4) or QEMU (1B36) PCI devices mark a guest even when SMBIOS is overridden.
    $r.QemuGuest = ("$($cs.Manufacturer) $($cs.Model)" -match '(?i)qemu') -or @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_(1AF4|1B36)&' }).Count -gt 0
    if (-not $r.QemuGuest) { $r.Status = 'notQemuGuest'; return Done 0 }
    # virtio-serial (legacy 1003, modern 1043) carries the guest-agent channel.
    $r.AgentChannel = @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_1AF4&DEV_10(03|43)' }).Count -gt 0

    # Per component. The bundle record can outlive a rolled-back driver MSI, so it is only reported.
    $r.BundleVersion = [string](& $script:VgInstalledVersion 'Virtio-win-guest-tools')
    $r.DriverPrevious = [string](& $script:VgInstalledVersion 'Virtio-win-driver-installer')
    $r.AgentPrevious = [string](& $script:VgInstalledVersion 'QEMU guest agent')
    $needDriver = -not (Test-VgAtLeast $r.DriverPrevious $PinVersion)
    $agentCurrent = Test-VgAtLeast $r.AgentPrevious $AgentVersion
    $needAgent = -not $agentCurrent -or $null -eq (& $script:VgGetService $script:VgAgent)
    $r.RebootRequired = $false
    $agentCode = 0
    if ($needDriver -or $needAgent) {
        if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
        $busy = Get-VgBackupBusy
        if ($busy) { $r.Status = 'backupRunning'; return Done 20 $busy }
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-virtio-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        try {
            if ($needDriver) {
                $msi = Join-Path $cache 'virtio-win-gt-x64.msi'
                $script:VgDownloadError = ''
                if ((Save-VgPayload -Url $DriverUrl -Destination $msi -Sha256 $DriverSha256) -ne 0) { $r.DownloadError = $script:VgDownloadError; return Done 1 'driver download failed or hash mismatch' }
                if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
                $saved = @(& $script:VgGetNet | Where-Object { $_ })
                $r.NetSnapshot = Join-Path $LogRoot "network-$stamp.json"
                Set-Content -LiteralPath $r.NetSnapshot -Value (ConvertTo-Json -InputObject $saved -Depth 5) -Encoding UTF8
                $code = Invoke-VgMsi -Mode '/i' -Path $msi -Sha256 $DriverSha256 -Log (Join-Path $LogRoot "drivers-$stamp.log")
                $r.DriverExit = $code
                # Also after a failed MSI: a half-done driver swap can still have replaced the NIC instance.
                try { Restore-VgNetwork $saved $r } catch { $r.NetError = $_.Exception.Message }
                if ($code -notin $script:VgOk) { return Done 1 "driver installer failed with $code" }
                $r.RebootRequired = $code -ne 0
            }
            if ($needAgent) {
                if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
                # Any throw here still reaches the restart of the agent below.
                try { $agentCode = Invoke-VgAgentStep $r $cache $LogRoot $stamp $AgentUrl $AgentSha256 ($agentCurrent) }
                catch { $agentCode = 22; $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = $_.Exception.Message }
            }
        } finally {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $r.DriverVersion = [string](& $script:VgInstalledVersion 'Virtio-win-driver-installer')
    $r.AgentVersion = [string](& $script:VgInstalledVersion 'QEMU guest agent')
    if (-not (Test-VgAtLeast $r.DriverVersion $PinVersion)) { return Done 1 'drivers are still below the pin' }
    if ($agentCode -eq 0 -and -not (Test-VgAtLeast $r.AgentVersion $AgentVersion)) { $agentCode = 22; $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = 'agent is still below the pin' }

    # Runs after a skipped or failed agent step too: the old agent was stopped and must run again.
    $ga = & $script:VgGetService $script:VgAgent
    if ($null -ne $ga) {
        if ($ga.StartType -ne 'Automatic') { & $script:VgSetStartType $script:VgAgent 'Automatic' }
        $vss = & $script:VgGetService $script:VgVss
        if ($null -ne $vss -and $vss.StartType -eq 'Disabled') { & $script:VgSetStartType $script:VgVss 'Manual' }
        if ($ga.Status -ne 'Running') { try { & $script:VgStartService $script:VgAgent } catch { $r.StartError = $_.Exception.Message } }
        $ga = & $script:VgGetService $script:VgAgent
        $r.AgentStartType = $ga.StartType
    }
    $r.AgentRunning = $null -ne $ga -and $ga.Status -eq 'Running'
    $vss = & $script:VgGetService $script:VgVss
    $r.VssProvider = if ($null -eq $vss) { $null } else { $vss.StartType }
    # Read after the agent MSI, which resets it.
    if ($VssOption -ne '' -and $null -ne $vss -and (& $script:VgGetVssOption) -ne $VssOption) { & $script:VgSetVssOption ([int]$VssOption) }
    $r.VssOption = [string](& $script:VgGetVssOption)

    if ($agentCode -ne 0) { $r.Status = if ($agentCode -eq 1) { 'error' } else { $r.AgentStep }; return Done $agentCode $r.AgentReason }
    if ($null -eq $ga) { return Done 1 "$($script:VgAgent) service is missing after install" }
    if ($VssOption -ne '' -and $null -eq $vss) { return Done 1 'VssOption given but the VSS provider service is missing' }
    $r.Status = if (-not ($needDriver -or $needAgent)) { 'current' } elseif ($r.DriverPrevious -eq '' -and $r.AgentPrevious -eq '') { 'installed' } else { 'updated' }
    if (-not $r.AgentRunning) {
        if ($r.AgentChannel) { $r.Status = 'error'; return Done 1 "$($script:VgAgent) did not start" }
        $r.Status = 'agentChannelMissing'
        $r.Reason = 'no virtio-serial device: enable the guest agent on the hypervisor and power-cycle the VM; the service starts at boot'
    }
    return Done 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation.
foreach ($name in @('DriverSha256', 'AgentSha256')) {
    if ($PSBoundParameters.ContainsKey($name) -and [string]::IsNullOrWhiteSpace($PSBoundParameters[$name])) { exit 0 }
}
foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $logRoot = Join-Path $env:ProgramData 'Relian\virtio-guest-tools'
    $run = Invoke-VgMain -Action $Action -PinVersion $PinVersion -DriverUrl $DriverUrl -DriverSha256 $DriverSha256 -AgentVersion $AgentVersion -AgentUrl $AgentUrl -AgentSha256 $AgentSha256 -CancelPath $CancelPath -LogRoot $logRoot -VssOption $VssOption
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'virtio-guest-tools'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-Json -InputObject $run.Result -Depth 4 -Compress)
exit $run.ExitCode
