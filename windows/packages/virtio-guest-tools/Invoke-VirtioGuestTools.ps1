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
    [string]$VssOption = '',
    # 'true' installs on a guest whose SMBIOS does not say QEMU but that has VirtIO devices.
    [string]$AllowNonQemu = ''
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
# Every uninstall entry in both hives, SystemComponent=1 entries included (the driver MSI is one).
$script:VgUninstallEntries = {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) { Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue }
    }
}
# Highest DisplayVersion of a Red Hat entry with this DisplayName ('' when none). Seen on a 0.1.302 guest:
# 'Virtio-win-driver-installer' and the bundle say 'Red Hat, Inc.', 'QEMU guest agent' says 'RedHat'.
# The entry itself, or $null; its key name (PSChildName) is the MSI ProductCode.
function Get-VgInstalled([string]$Name) {
    $best = $null
    foreach ($p in @(& $script:VgUninstallEntries)) {
        if ($null -eq $p -or [string]$p.DisplayName -cne $Name -or [string]$p.Publisher -notmatch '^Red ?Hat') { continue }
        $v = [string]$p.DisplayVersion
        if ($v -match '^\d+(\.\d+){1,3}$' -and ($null -eq $best -or (Compare-VgVersion $v ([string]$best.DisplayVersion)) -gt 0)) { $best = $p }
    }
    $best
}
function Get-VgInstalledVersion([string]$Name) { $e = Get-VgInstalled $Name; if ($null -eq $e) { '' } else { [string]$e.DisplayVersion } }
# SYSTEM and Administrators only, inheritance off: no local user can read the logs or swap a staged MSI.
$script:VgLockDir = {
    param($Path)
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
$script:VgOwnerSid = { param($Path) (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value }
function New-VgPrivateDir([string]$Path) {
    # A junction planted by a local user would send the ACL change and SYSTEM's writes elsewhere. A folder a local
    # user created first (and so owns) is refused, never re-ACLed: the user could swap our folder through the parent,
    # or keep a WRITE_DAC handle open on the folder itself.
    $check = {
        foreach ($p in @((Split-Path -Path $Path -Parent), $Path)) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if ((Get-Item -LiteralPath $p -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$p is a reparse point" }
            if ((& $script:VgOwnerSid $p) -notin @('S-1-5-18', 'S-1-5-32-544')) { throw "$p is not owned by SYSTEM or Administrators" }
        }
    }
    & $check
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    # Again after the create: a folder slipped in between the check and New-Item is caught here.
    & $check
    & $script:VgLockDir $Path
}
$script:VgGetService = {
    param($Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    [pscustomobject]@{ Status = [string]$s.Status; StartType = [string]$s.StartType }
}
$script:VgSetStartType = { param($Name, $Type) Set-Service -Name $Name -StartupType $Type }
$script:VgStartService = { param($Name) Start-Service -Name $Name }
# Sends the stop and returns: Stop-Service waits on a StopPending service with no limit; Wait-Vg bounds the wait.
$script:VgStopService = { param($Name) $s = Get-Service -Name $Name -ErrorAction SilentlyContinue; if ($null -ne $s -and [string]$s.Status -ne 'Stopped') { $s.Stop() } }
# Held: not stopped, or marked for delete (DeleteFlag), which makes the agent MSI's RegisterCom fail with 1603.
$script:VgServiceHeld = {
    param($Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $false }
    [string]$s.Status -ne 'Stopped' -or [int](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'DeleteFlag' -ErrorAction SilentlyContinue).DeleteFlag -eq 1
}
$script:VgProcesses = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'backup-tool.exe'" | Select-Object Name, CommandLine) }
# '' when vssadmin fails.
$script:VgVssWriters = { $out = & (Join-Path $env:SystemRoot 'System32\vssadmin.exe') list writers | Out-String; if ($LASTEXITCODE -ne 0) { return '' }; $out }
# All adapters, any status. Manual marks what was set by hand: PrefixOrigin Manual, route Protocol NetMgmt.
# StaticDnsV4/V6 are the interface's NameServer values (Tcpip, Tcpip6), which hold only hand-set servers;
# DnsV4/V6 are what the adapter uses now. Category is the network profile, for the report.
$script:VgGetNet = {
    foreach ($a in @(Get-NetAdapter)) {
        $i = $a.ifIndex
        $ns = @(foreach ($stack in @('Tcpip', 'Tcpip6')) {
            ,@(([string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$stack\Parameters\Interfaces\$($a.InterfaceGuid)" -Name 'NameServer' -ErrorAction SilentlyContinue).NameServer -split '[,\s]+') | Where-Object { $_ })
        })
        [pscustomobject]@{
            Mac = [string]$a.MacAddress
            Alias = [string]$a.Name
            Index = [int]$i
            Status = [string]$a.Status
            Category = [string](Get-NetConnectionProfile -InterfaceIndex $i -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory
            Dhcp = [string](Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled'
            # A manual interface metric (AutomaticMetric Disabled), else $null.
            MetricV4 = @(Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { [string]$_.AutomaticMetric -eq 'Disabled' } | ForEach-Object { [int]$_.InterfaceMetric })[0]
            MetricV6 = @(Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { [string]$_.AutomaticMetric -eq 'Disabled' } | ForEach-Object { [int]$_.InterfaceMetric })[0]
            Addresses = @(Get-NetIPAddress -InterfaceIndex $i -ErrorAction SilentlyContinue | Where-Object { [string]$_.PrefixOrigin -ne 'WellKnown' } |
                ForEach-Object { [pscustomobject]@{ Ip = [string]$_.IPAddress; Prefix = [int]$_.PrefixLength; Manual = [string]$_.PrefixOrigin -eq 'Manual'; SkipAsSource = [bool]$_.SkipAsSource } })
            # Persistent routes are the ones set by hand (route -p, New-NetRoute); DHCP and RA routes are not persistent.
            Routes = @(Get-NetRoute -InterfaceIndex $i -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
                ForEach-Object { [pscustomobject]@{ Prefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; Metric = [int]$_.RouteMetric } })
            # Default gateways in use, for the reachability check.
            Gateways = @(Get-NetRoute -InterfaceIndex $i -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') -and $_.NextHop -notin @('0.0.0.0', '::') } | ForEach-Object { [string]$_.NextHop })
            DnsV4 = @((Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            DnsV6 = @((Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses)
            StaticDnsV4 = @($ns[0])
            StaticDnsV6 = @($ns[1])
        }
    }
}
# $Nic is the adapter as it is now (its new instance); Index, not the alias, so wildcard characters cannot widen the match.
$script:VgAddIp = {
    param($Nic, $Ip, $Prefix, $Dhcp, $Skip)
    if (-not $Dhcp -and $Ip -notmatch ':') { Set-NetIPInterface -InterfaceIndex $Nic.Index -AddressFamily IPv4 -Dhcp Disabled }
    New-NetIPAddress -InterfaceIndex $Nic.Index -IPAddress $Ip -PrefixLength $Prefix -SkipAsSource ([bool]$Skip) | Out-Null
}
$script:VgAddRoute = { param($Nic, $Prefix, $NextHop, $Metric) New-NetRoute -InterfaceIndex $Nic.Index -DestinationPrefix $Prefix -NextHop $NextHop -RouteMetric $Metric | Out-Null }
$script:VgSetMetric = { param($Nic, $Family, $Metric) Set-NetIPInterface -InterfaceIndex $Nic.Index -AddressFamily $Family -InterfaceMetric $Metric }
# True when any of three 1 s pings answers.
$script:VgPing = {
    param($Ip)
    $p = [System.Net.NetworkInformation.Ping]::new()
    try { foreach ($n in 1..3) { if ([string]$p.Send($Ip, 1000).Status -eq 'Success') { return $true } }; $false } catch { $false } finally { $p.Dispose() }
}
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

function Test-VgSha([string]$Path, [string]$Sha256) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -ceq $Sha256 }

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
        if (Test-VgSha $Destination $Sha256) { return 0 }
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
    # Fail closed: output with no writer state ([n]) means the VSS state is unknown.
    if ($writers -notmatch '\[\d+\]') { return 'VSS writer state is unreadable' }
    if ($writers -match '\[[2-5]\]') { return 'a VSS writer is in a snapshot' }
    ''
}

# Polls every 5 s, 24 times at most (120 s); returns once Test is false or the time is up.
function Wait-Vg([scriptblock]$Test) {
    for ($i = 0; (& $Test) -and $i -lt 24; $i++) { [void](& $script:RetryDelay -Seconds 5) }
}

function Invoke-VgMsi([string]$Mode, [string]$Path, [string]$Log) {
    [int](& $script:VgRunMsi -Arguments @($Mode, ('"{0}"' -f $Path), '/qn', '/norestart', '/l*v', ('"{0}"' -f $Log)))
}

# A saved adapter is back when its MAC is on one adapter and, if it was Up, that adapter is Up and, if it had a
# DHCP address, has an address again. Manual addresses are the restore's job, so they are not waited for.
function Test-VgNicBack($s, $c) {
    $null -ne $c -and ($s.Status -ne 'Up' -or ($c.Status -eq 'Up' -and (@($s.Addresses | Where-Object { -not $_.Manual }).Count -eq 0 -or @($c.Addresses).Count -gt 0)))
}
function Find-VgNic($Now, [string]$Mac) { $m = @($Now | Where-Object { $_.Mac -eq $Mac }); if ($m.Count -eq 1) { $m[0] } }

# Waits for the saved adapters (by MAC), sets back what was set by hand and is missing, then checks the result.
function Restore-VgNetwork($Saved, $r) {
    for ($i = 0; ; $i++) {
        $now = @(& $script:VgGetNet | Where-Object { $_ })
        if (@($Saved | Where-Object { -not (Test-VgNicBack $_ (Find-VgNic $now $_.Mac)) }).Count -eq 0 -or $i -ge 24) { break }
        [void](& $script:RetryDelay -Seconds 5)
    }
    $applied = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    # One change per try: a failed address must not stop the routes or DNS.
    function Apply([string]$What, [scriptblock]$Change) { try { & $Change; $applied.Add($What) } catch { $errors.Add("$What : $($_.Exception.Message)") } }
    foreach ($s in $Saved) {
        # A MAC shared by more than one adapter (a team, VLAN vNICs) is not guessed at: reported, left alone.
        $c = Find-VgNic $now $s.Mac
        if ($null -eq $c) { $missing.Add($(if (@($now | Where-Object { $_.Mac -eq $s.Mac }).Count -gt 1) { "$($s.Mac) (shared)" } else { $s.Mac })); continue }
        # A manual IPv4 address on a DHCP adapter is not added back: New-NetIPAddress would turn DHCP off.
        foreach ($a in @($s.Addresses | Where-Object { $_.Manual -and ($_.Ip -match ':' -or -not $s.Dhcp) })) {
            if ($a.Ip -notin @($c.Addresses | ForEach-Object { $_.Ip })) { Apply "$($c.Alias) ip $($a.Ip)/$($a.Prefix)" { & $script:VgAddIp $c $a.Ip $a.Prefix $s.Dhcp $a.SkipAsSource } }
        }
        foreach ($rt in @($s.Routes)) {
            if (@($c.Routes | Where-Object { $_.Prefix -eq $rt.Prefix -and $_.NextHop -eq $rt.NextHop }).Count -eq 0) { Apply "$($c.Alias) route $($rt.Prefix) $($rt.NextHop) metric $($rt.Metric)" { & $script:VgAddRoute $c $rt.Prefix $rt.NextHop $rt.Metric } }
        }
        foreach ($v in @('4', '6')) {
            $m = $s."MetricV$v"
            if ($null -ne $m -and $m -ne $c."MetricV$v") { Apply "$($c.Alias) metric IPv$v $m" { & $script:VgSetMetric $c "IPv$v" $m } }
            $want = @($s."StaticDnsV$v")
            if ($want.Count -gt 0 -and ($want -join ',') -ne (@($c."StaticDnsV$v") -join ',')) { Apply "$($c.Alias) dns $($want -join ' ')" { & $script:VgSetDns $c $want } }
        }
    }
    # Final state: each adapter that was Up is Up with its address, and each gateway that answered before still does.
    $final = @(& $script:VgGetNet | Where-Object { $_ })
    foreach ($s in @($Saved | Where-Object { $_.Status -eq 'Up' })) {
        $c = Find-VgNic $final $s.Mac
        if ($null -eq $c) { continue }
        if (-not (Test-VgNicBack $s $c)) { $errors.Add("$($c.Alias) ($($s.Mac)) is $($c.Status) with $(@($c.Addresses).Count) addresses; it was Up"); continue }
        foreach ($a in @($s.Addresses | Where-Object { $_.Manual -and ($_.Ip -match ':' -or -not $s.Dhcp) })) {
            if ($a.Ip -notin @($c.Addresses | ForEach-Object { $_.Ip })) { $errors.Add("$($c.Alias) is missing $($a.Ip)") }
        }
        foreach ($g in @($s.Reachable)) { if (-not (& $script:VgPing $g)) { $errors.Add("$($c.Alias) gateway $g answered before the driver update and is unreachable now") } }
    }
    $r.NetReapplied = @($applied)
    if ($errors.Count -gt 0) { $r.NetError = @($errors) }
    if ($missing.Count -gt 0) { $r.NetMissing = @($missing) }
}


# Agent step. Returns 0, or the exit code for the run; the drivers are never touched here.
# $RepairCode: the installed agent's ProductCode when it is current but its service is gone; '' installs or upgrades.
function Invoke-VgAgentStep($r, [string]$Cache, [string]$LogRoot, [string]$Stamp, [string]$AgentUrl, [string]$AgentSha256, [bool]$Repair, [string]$RepairCode, [string]$CancelPath) {
    # The repair runs from the installed product's cached MSI, which may be newer than the pin.
    if ($Repair -and $RepairCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { $r.AgentStep = 'agentRepairUnavailable'; $r.AgentReason = 'the agent is registered but its service is gone, and its ProductCode is unknown: reinstall it by hand'; return 22 }
    $msi = Join-Path $Cache 'qemu-ga-x86_64.msi'
    $script:VgDownloadError = ''
    if ((Save-VgPayload -Url $AgentUrl -Destination $msi -Sha256 $AgentSha256) -ne 0) { $r.AgentStep = 'error'; $r.AgentReason = 'agent download failed or hash mismatch'; $r.DownloadError = $script:VgDownloadError; return 1 }
    # Checked after the download, right before the services are stopped.
    if (Test-VgCancelled $CancelPath) { $r.AgentStep = 'cancelled'; $r.AgentReason = 'cancelled after the agent download'; return 130 }
    $busy = Get-VgBackupBusy
    if ($busy) { $r.AgentStep = 'backupRunning'; $r.AgentReason = $busy; return 20 }
    foreach ($name in @($script:VgAgent, $script:VgVss)) {
        if ($null -ne (& $script:VgGetService $name)) { try { & $script:VgStopService $name } catch { $r.StopError = "$name : $($_.Exception.Message)" } }
    }
    Wait-Vg { @(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ }).Count -gt 0 }
    $held = @(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ })
    if ($held.Count -gt 0) { $r.AgentStep = 'agentServiceHeld'; $r.AgentReason = "still running or marked for delete after 120 s: $($held -join ', ')"; return 21 }
    # A backup may have started during the wait.
    $busy = Get-VgBackupBusy
    if ($busy) { $r.AgentStep = 'backupRunning'; $r.AgentReason = $busy; return 20 }
    # Hashed again just before msiexec, so a file swapped after the download check never runs.
    if (-not (Test-VgSha $msi $AgentSha256)) { $r.AgentStep = 'error'; $r.AgentReason = 'agent MSI hash mismatch before install'; return 1 }
    # /famus reinstalls the registered agent whose service is gone; /i installs or upgrades.
    $code = if ($Repair) { Invoke-VgMsi -Mode '/famus' -Path $RepairCode -Log (Join-Path $LogRoot "agent-$Stamp.log") } else { Invoke-VgMsi -Mode '/i' -Path $msi -Log (Join-Path $LogRoot "agent-$Stamp.log") }
    $r.AgentExit = $code
    # RemoveExistingProducts runs before InstallInitialize in this MSI, so a failed upgrade can leave no agent at all.
    # Then wait for the old service to clear and run the MSI once more.
    if ($code -notin $script:VgOk -and -not $Repair -and $null -eq (& $script:VgGetService $script:VgAgent)) {
        Wait-Vg { @(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ }).Count -gt 0 }
        if (@(@($script:VgAgent, $script:VgVss) | Where-Object { & $script:VgServiceHeld $_ }).Count -gt 0) {
            $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = "agent installer failed with $code and removed the old agent; its service is still marked for delete: reboot, then run again"; return 22
        }
        if (-not (Test-VgSha $msi $AgentSha256)) { $r.AgentStep = 'error'; $r.AgentReason = 'agent MSI hash mismatch before install'; return 1 }
        $code = Invoke-VgMsi -Mode '/i' -Path $msi -Log (Join-Path $LogRoot "agent-retry-$Stamp.log")
        $r.AgentRetryExit = $code
    }
    if ($code -notin $script:VgOk) { $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = "agent installer failed with $code"; return 22 }
    $r.RebootRequired = $r.RebootRequired -or $code -ne 0
    $r.AgentStep = 'installed'
    return 0
}

function Invoke-VgMain {
    param([string]$Action, [string]$PinVersion, [string]$DriverUrl, [string]$DriverSha256, [string]$AgentVersion, [string]$AgentUrl, [string]$AgentSha256, [string]$CancelPath, [string]$LogRoot, [string]$VssOption = '', [string]$AllowNonQemu = '')
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
    # SMBIOS must say QEMU. VirtIO (1AF4) or QEMU (1B36) PCI devices alone count only with AllowNonQemu=true:
    # other hypervisors and passthrough setups expose them too.
    $virtio = @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_(1AF4|1B36)&' }).Count -gt 0
    $r.QemuGuest = ("$($cs.Manufacturer) $($cs.Model)" -match '(?i)qemu') -or ($AllowNonQemu -eq 'true' -and $virtio)
    if (-not $r.QemuGuest) { $r.Status = 'notQemuGuest'; return Done 0 }
    # virtio-serial (legacy 1003, modern 1043) carries the guest-agent channel.
    $r.AgentChannel = @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_1AF4&DEV_10(03|43)' }).Count -gt 0

    # Per component. The bundle record can outlive a rolled-back driver MSI, so it is only reported.
    $r.BundleVersion = [string](Get-VgInstalledVersion 'Virtio-win-guest-tools')
    $r.DriverPrevious = [string](Get-VgInstalledVersion 'Virtio-win-driver-installer')
    $r.AgentPrevious = [string](Get-VgInstalledVersion 'QEMU guest agent')
    $needDriver = -not (Test-VgAtLeast $r.DriverPrevious $PinVersion)
    $agentCurrent = Test-VgAtLeast $r.AgentPrevious $AgentVersion
    $needAgent = -not $agentCurrent -or $null -eq (& $script:VgGetService $script:VgAgent)
    $agentEntry = Get-VgInstalled 'QEMU guest agent'
    $agentProduct = if ($null -ne $agentEntry -and $agentEntry.PSObject.Properties['PSChildName']) { [string]$agentEntry.PSChildName } else { '' }
    # The agent MSI writes VssOption=1; the value from before is put back unless VssOption is given.
    $vssBefore = [string](& $script:VgGetVssOption)
    if ($vssBefore -notmatch '^[1-5]$') { $vssBefore = '' }
    $r.RebootRequired = $false
    $agentCode = 0
    if ($needDriver -or $needAgent) {
        if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
        $busy = Get-VgBackupBusy
        if ($busy) { $r.Status = 'backupRunning'; return Done 20 $busy }
        New-VgPrivateDir $LogRoot
        # The random part keeps file names in the log folder unpredictable.
        $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('n')
        # Inside the locked log folder, so the download folder is never open to other users, not even briefly.
        $cache = Join-Path $LogRoot ('cache-' + [guid]::NewGuid().ToString('n'))
        New-VgPrivateDir $cache
        try {
            if ($needDriver) {
                $msi = Join-Path $cache 'virtio-win-gt-x64.msi'
                $script:VgDownloadError = ''
                if ((Save-VgPayload -Url $DriverUrl -Destination $msi -Sha256 $DriverSha256) -ne 0) { $r.DownloadError = $script:VgDownloadError; return Done 1 'driver download failed or hash mismatch' }
                if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
                $saved = @(& $script:VgGetNet | Where-Object { $_ })
                # Gateways that answer now must answer after the update; one that never answers ping is not checked.
                foreach ($n in $saved) { $n | Add-Member -NotePropertyName Reachable -NotePropertyValue @(@($n.Gateways) | Where-Object { $n.Status -eq 'Up' -and (& $script:VgPing $_) }) -Force }
                $r.NetSnapshot = Join-Path $LogRoot "network-$stamp.json"
                Set-Content -LiteralPath $r.NetSnapshot -Value (ConvertTo-Json -InputObject $saved -Depth 5) -Encoding UTF8
                # A backup may have started during the download; the driver swap drops the network.
                $busy = Get-VgBackupBusy
                if ($busy) { $r.Status = 'backupRunning'; return Done 20 $busy }
                if (-not (Test-VgSha $msi $DriverSha256)) { return Done 1 'driver MSI hash mismatch before install' }
                $code = Invoke-VgMsi -Mode '/i' -Path $msi -Log (Join-Path $LogRoot "drivers-$stamp.log")
                $r.DriverExit = $code
                # Also after a failed MSI: a half-done driver swap can still have replaced the NIC instance.
                try { Restore-VgNetwork $saved $r } catch { $r.NetError = $_.Exception.Message }
                if ($code -notin $script:VgOk) {
                    $state = if ($r.Contains('NetMissing') -or $r.Contains('NetError')) { 'incomplete' } else { "done, $(@($r.NetReapplied).Count) re-applied" }
                    return Done 1 "driver installer failed with $code; network snapshot $($r.NetSnapshot), restore $state"
                }
                $r.RebootRequired = $code -ne 0
            }
            if ($needAgent) {
                if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
                # Any throw here still reaches the restart of the agent below.
                try { $agentCode = Invoke-VgAgentStep $r $cache $LogRoot $stamp $AgentUrl $AgentSha256 ($agentCurrent) $agentProduct $CancelPath }
                catch { $agentCode = 22; $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = $_.Exception.Message }
            }
        } finally {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    try {
        $r.DriverVersion = [string](Get-VgInstalledVersion 'Virtio-win-driver-installer')
        $r.AgentVersion = [string](Get-VgInstalledVersion 'QEMU guest agent')
        if ($agentCode -eq 0 -and -not (Test-VgAtLeast $r.AgentVersion $AgentVersion)) { $agentCode = 22; $r.AgentStep = 'agentInstallFailed'; $r.AgentReason = 'agent is still below the pin' }
    } finally {
        # Runs after a skipped or failed agent step, and after a throw above: an agent this run stopped must run again.
        $ga = & $script:VgGetService $script:VgAgent
        if ($null -ne $ga) {
            try {
                if ($ga.StartType -ne 'Automatic') { & $script:VgSetStartType $script:VgAgent 'Automatic' }
                $vss = & $script:VgGetService $script:VgVss
                if ($null -ne $vss -and $vss.StartType -eq 'Disabled') { & $script:VgSetStartType $script:VgVss 'Manual' }
            } catch { $r.StartTypeError = $_.Exception.Message }
            if ($ga.Status -ne 'Running') { try { & $script:VgStartService $script:VgAgent } catch { $r.StartError = $_.Exception.Message } }
            $ga = & $script:VgGetService $script:VgAgent
            $r.AgentStartType = $ga.StartType
        }
    }
    $r.AgentRunning = $null -ne $ga -and $ga.Status -eq 'Running'
    $vss = & $script:VgGetService $script:VgVss
    $r.VssProvider = if ($null -eq $vss) { $null } else { $vss.StartType }
    # Read after the agent MSI, which resets it.
    $wantVss = if ($VssOption -ne '') { $VssOption } else { $vssBefore }
    if ($wantVss -ne '' -and $null -ne $vss -and (& $script:VgGetVssOption) -ne $wantVss) { & $script:VgSetVssOption ([int]$wantVss) }
    $r.VssOption = [string](& $script:VgGetVssOption)

    # A guest that lost part of its network config is the worse failure; the snapshot JSON has what to set by hand.
    if ($r.Contains('NetMissing') -or $r.Contains('NetError')) { return Done 1 "network restore incomplete, see $($r.NetSnapshot)" }
    # Checked after the agent restart above, so a stopped agent never stays stopped.
    if (-not (Test-VgAtLeast $r.DriverVersion $PinVersion)) { return Done 1 'drivers are still below the pin' }
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
    $run = Invoke-VgMain -Action $Action -PinVersion $PinVersion -DriverUrl $DriverUrl -DriverSha256 $DriverSha256 -AgentVersion $AgentVersion -AgentUrl $AgentUrl -AgentSha256 $AgentSha256 -CancelPath $CancelPath -LogRoot $logRoot -VssOption $VssOption -AllowNonQemu $AllowNonQemu
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'virtio-guest-tools'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-Json -InputObject $run.Result -Depth 4 -Compress)
exit $run.ExitCode
