$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/virtio-guest-tools/Invoke-VirtioGuestTools.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/virtio-guest-tools.json'

function Assert($ok, [string]$message) { if (-not $ok) { [Console]::Error.WriteLine("FAIL $message"); exit 1 } }

foreach ($path in @($scriptPath, $releasePath)) { Assert (Test-Path -LiteralPath $path) "$path does not exist" }

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Pin record and inlined defaults agree; each MSI is a content-addressed copy of the vendor file.
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
Assert ($DriverUrl -ceq [string]$release.drivers.url -and $DriverSha256 -ceq [string]$release.drivers.sha256) 'driver defaults do not match the release file'
Assert ($AgentUrl -ceq [string]$release.agent.url -and $AgentSha256 -ceq [string]$release.agent.sha256 -and $AgentVersion -ceq [string]$release.agent.version) 'agent defaults do not match the release file'
foreach ($pin in @($release.drivers, $release.agent)) {
    $stem = ([string]$pin.file) -replace '\.msi$', ''
    Assert ([string]$pin.url -ceq ('https://relianpub.blob.core.windows.net/pub/sec/' + $stem + '-' + [string]$pin.version + '-' + [string]$pin.sha256 + '.msi')) "$($pin.file) URL is not the content-addressed blob of the pin"
    Assert (([string]$pin.sourceUrl).StartsWith('https://fedorapeople.org/') -and ([string]$pin.sourceUrl).EndsWith('/' + [string]$pin.file)) "$($pin.file) sourceUrl is not the vendor file"
    Assert ((Test-VgPinHash ([string]$pin.sha256)) -and [int64]$pin.size -gt 0) "$($pin.file) pin hash or size"
}
Assert ([string]$release.drivers.sourceUrl -match ('/virtio-win-' + [regex]::Escape([string]$release.drivers.version) + '-\d+/')) 'driver sourceUrl is not the archive of the pinned version'
Assert ([string]$release.agent.sourceUrl -match ('/qemu-ga-win-' + [regex]::Escape([string]$release.agent.version) + '-')) 'agent sourceUrl is not the archive of the pinned version'
Assert ((Test-VgPinHash $DriverSha256) -and -not (Test-VgPinHash ('0' * 64)) -and -not (Test-VgPinHash 'ABC')) 'pin hash check'

# PCI hardware IDs are built here: public vendor and device numbers, not a real machine's identifiers.
function Pci([string]$Vendor, [string]$Device) { 'PCI\VEN_' + $Vendor + '&DEV_' + $Device }
# A locally administered MAC and documentation addresses (RFC 5737): no real machine.
$mac = '02-00-00-00-00-01'
function Nic([string]$Alias = 'Ethernet', [bool]$Dhcp = $true, [object[]]$Addresses = @(), [object[]]$Gateways = @(), [string[]]$StaticDns = @()) {
    [pscustomobject]@{ Mac = $mac; Alias = $Alias; Dhcp = $Dhcp; Addresses = $Addresses; Gateways = $Gateways; Dns = $StaticDns; StaticDns = $StaticDns }
}
$idle = @('"C:\Program Files\Comet\backup-tool.exe" delegate-server', '"C:\Program Files\Comet\backup-tool.exe" elevator-server', '"C:\Program Files\Comet\backup-tool.exe" stream 12')
$stable = "Writer name: 'System Writer'`n   State: [1] Stable`n   Last error: No error`nWriter name: 'SqlServerWriter'`n   State: [8] Failed`n"

# A fake VM. Every machine hook is replaced; nothing is installed.
function New-Fake {
    param(
        [string]$Manufacturer = 'QEMU',
        [string[]]$Pnp = @((Pci '1AF4' '1004'), (Pci '1AF4' '1003')),
        [string]$Driver = '',
        [string]$Agent = '',
        [string]$Bundle = '',
        [bool]$Services = ($Agent -ne ''),
        [int]$DriverExit = 0,
        [int]$AgentExit = 0,
        [bool]$AgentStarts = $true,
        [int]$Held = 0,
        [object[]]$Net = @(),
        [object[]]$NetAfter = $null
    )
    $f = [pscustomobject]@{
        Manufacturer = $Manufacturer; Pnp = $Pnp; DriverExit = $DriverExit; AgentExit = $AgentExit; AgentStarts = $AgentStarts; Held = $Held
        Versions = @{ 'Virtio-win-driver-installer' = $Driver; 'QEMU guest agent' = $Agent; 'Virtio-win-guest-tools' = $Bundle }
        Services = @{}; Calls = [System.Collections.Generic.List[string]]::new(); Delays = 0
        Net = $Net; NetAfter = $(if ($null -eq $NetAfter) { $Net } else { $NetAfter }); Processes = $idle; Writers = $stable; VssOption = ''; Modes = @{}; FailIp = ''
    }
    if ($Services) {
        $f.Services['QEMU-GA'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
        $f.Services['QEMU Guest Agent VSS Provider'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' }
    }
    $script:Fake = $f
    $script:VgComputer = { [pscustomobject]@{ Manufacturer = $script:Fake.Manufacturer; Model = 'Standard PC' } }
    $script:VgPnpIds = { $script:Fake.Pnp }
    $script:VgInstalledVersion = { param($Name) [string]$script:Fake.Versions[$Name] }
    $script:VgGetService = { param($Name) $script:Fake.Services[$Name] }
    $script:VgSetStartType = { param($Name, $Type) $script:Fake.Calls.Add("start-type $Name $Type"); $script:Fake.Services[$Name].StartType = $Type }
    $script:VgStartService = {
        param($Name)
        $script:Fake.Calls.Add("start $Name")
        if ($script:Fake.AgentStarts) { $script:Fake.Services[$Name].Status = 'Running' } else { throw 'Cannot start service' }
    }
    $script:VgStopService = { param($Name) $script:Fake.Calls.Add("stop $Name"); $script:Fake.Services[$Name].Status = 'Stopped' }
    # Held: polls during which a service stays marked for delete; -1 is forever.
    $script:VgServiceHeld = { param($Name) $script:Fake.Held -ne 0 }
    $script:VgProcesses = { @($script:Fake.Processes | ForEach-Object { [pscustomobject]@{ Name = 'backup-tool.exe'; CommandLine = $_ } }) }
    $script:VgVssWriters = { $script:Fake.Writers }
    $script:VgGetNet = { $script:Fake.Net }
    $script:VgAddIp = { param($Nic, $Ip, $Prefix, $Dhcp) if ($Ip -eq $script:Fake.FailIp) { throw 'address in use' }; $script:Fake.Calls.Add("ip $($Nic.Alias) $Ip/$Prefix dhcp=$Dhcp") }
    $script:VgAddRoute = { param($Nic, $Prefix, $NextHop) $script:Fake.Calls.Add("route $($Nic.Alias) $Prefix $NextHop") }
    $script:VgSetDns = { param($Nic, [string[]]$Servers) $script:Fake.Calls.Add("dns $($Nic.Alias) $($Servers -join ' ')") }
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); Copy-Item -LiteralPath $script:Payload -Destination $Destination }
    $script:RetryDelay = {
        param($Seconds)
        $script:Fake.Delays++
        if ($script:Fake.Held -gt 0) { $script:Fake.Held-- }
    }
    $script:VgGetVssOption = { $script:Fake.VssOption }
    $script:VgSetVssOption = { param([int]$Value) $script:Fake.Calls.Add("vss-option $Value"); $script:Fake.VssOption = [string]$Value }
    $script:VgRunMsi = {
        param([string[]]$Arguments)
        $which = if ($Arguments[1] -match 'qemu-ga') { 'agent' } else { 'driver' }
        $script:Fake.Calls.Add("msi $which")
        $script:Fake.Modes[$which] = $Arguments[0]
        Assert ($Arguments[2] -ceq '/qn' -and $Arguments[3] -ceq '/norestart' -and $Arguments[4] -ceq '/l*v') "msiexec arguments: $($Arguments -join ' ')"
        if ($which -eq 'driver') {
            if ($script:Fake.DriverExit -notin @(0, 3010, 1641)) { return $script:Fake.DriverExit }
            $script:Fake.Versions['Virtio-win-driver-installer'] = '0.1.302'
            $script:Fake.Net = $script:Fake.NetAfter
            return $script:Fake.DriverExit
        }
        if ($script:Fake.AgentExit -notin @(0, 3010, 1641)) { return $script:Fake.AgentExit }
        $script:Fake.Versions['QEMU guest agent'] = '110.2.3'
        $script:Fake.Services['QEMU-GA'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' }
        $script:Fake.Services['QEMU Guest Agent VSS Provider'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
        $script:Fake.VssOption = ''
        return $script:Fake.AgentExit
    }
    return $f
}

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-vg-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $dir | Out-Null
$script:Payload = Join-Path $dir 'payload.msi'
[System.IO.File]::WriteAllText($script:Payload, 'fake msi')
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:Payload).Hash.ToLowerInvariant()
function Run { param([string]$Action = 'Install', [string]$Pin = '0.1.302', [string]$Sha = $sha, [string]$AgentSha = $sha, [string]$Url = 'https://example.invalid/virtio-win-gt-x64.msi', [string]$AgentUrl = 'https://example.invalid/qemu-ga-x86_64.msi', [string]$AgentPin = '110.2.3', [string]$Vss = '')
    Invoke-VgMain -Action $Action -PinVersion $Pin -DriverUrl $Url -DriverSha256 $Sha -AgentVersion $AgentPin -AgentUrl $AgentUrl -AgentSha256 $AgentSha -CancelPath '' -LogRoot $dir -VssOption $Vss }
function Calls { $script:Fake.Calls -join ',' }
$stopBoth = 'stop QEMU-GA,stop QEMU Guest Agent VSS Provider'

try {
    # Fresh QEMU guest: drivers, then the agent, each its own msiexec; agent set to automatic and started.
    $f = New-Fake
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'installed') "fresh install: $($r.ExitCode) $($r.Result.Status)"
    Assert ((Calls) -ceq 'download,msi driver,download,msi agent,start QEMU-GA') "fresh install calls: $(Calls)"
    Assert ($r.Result.DriverVersion -eq '0.1.302' -and $r.Result.AgentVersion -eq '110.2.3' -and $r.Result.AgentRunning -and -not $r.Result.RebootRequired) 'fresh install result'
    Assert ($f.Modes['driver'] -ceq '/i' -and $f.Modes['agent'] -ceq '/i') 'msiexec /i for both'
    Assert ($f.Services['QEMU Guest Agent VSS Provider'].StartType -eq 'Manual') 'VSS provider not demand-start'

    # Second run is a no-op apart from service checks.
    $f.Calls.Clear()
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'current' -and (Calls) -ceq '') "second run: $($r.Result.Status) $(Calls)"

    # Stale bundle record: the bundle says 0.1.285, the driver MSI is not registered, qemu-ga 109.1.0 is.
    # The bundle record alone never makes the guest current: both steps run, drivers first, agent services stopped first.
    $f = New-Fake -Bundle '0.1.285' -Agent '109.1.0'
    $r = Run -Action 'Update'
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'updated') "stale bundle record: $($r.ExitCode) $($r.Result.Status)"
    Assert ((Calls) -ceq "download,msi driver,download,$stopBoth,msi agent,start QEMU-GA") "stale bundle calls: $(Calls)"
    Assert ($r.Result.BundleVersion -eq '0.1.285' -and $r.Result.DriverPrevious -eq '' -and $r.Result.AgentPrevious -eq '109.1.0') 'stale bundle previous versions'
    # A bundle record at the pin with no driver MSI still runs the driver step.
    $f = New-Fake -Bundle '0.1.302' -Agent '110.2.3'
    $r = Run
    Assert ((Calls) -clike 'download,msi driver,*' -and (Calls) -notmatch 'msi agent') "bundle at pin, driver MSI absent: $(Calls)"

    # Per component: only what is below its pin runs.
    $f = New-Fake -Driver '0.1.302' -Agent '109.1.0'
    $r = Run
    Assert ((Calls) -clike "download,$stopBoth,msi agent,*" -and $r.Result.Status -eq 'updated') "agent only: $(Calls)"
    $f = New-Fake -Driver '0.1.285' -Agent '110.2.3'
    $r = Run
    Assert ((Calls) -clike 'download,msi driver,*' -and (Calls) -notmatch 'stop|msi agent') "driver only: $(Calls)"
    $f = New-Fake -Driver '0.1.302' -Agent '110.2.3'
    $r = Run
    Assert ((Calls) -ceq 'start-type QEMU-GA Automatic,start-type QEMU Guest Agent VSS Provider Manual,start QEMU-GA' -and $r.Result.Status -eq 'current') "service repair calls: $(Calls)"

    # Agent registered at the pin but its service is gone: msiexec repair of the agent only.
    $f = New-Fake -Driver '0.1.302' -Agent '110.2.3' -Services $false
    $r = Run
    Assert ((Calls) -clike 'download,msi agent,*' -and $f.Modes['agent'] -ceq '/famus') "missing agent service repairs: $(Calls) $($f.Modes['agent'])"

    # A qemu-ga failure never touches the drivers: driver step done, agent reported on its own, exit 22.
    $f = New-Fake -Bundle '0.1.285' -Agent '109.1.0' -AgentExit 1603
    $r = Run
    Assert ($r.ExitCode -eq 22 -and $r.Result.Status -eq 'agentInstallFailed' -and $r.Result.AgentExit -eq 1603) "agent failure: $($r.ExitCode) $($r.Result.Status)"
    Assert ($r.Result.DriverVersion -eq '0.1.302' -and $r.Result.DriverExit -eq 0 -and @($f.Calls | Where-Object { $_ -eq 'msi driver' }).Count -eq 1) 'driver MSI untouched by the agent failure'
    Assert ((Calls) -clike '*msi agent,*start QEMU-GA') "old agent restarted after the failure: $(Calls)"

    # Driver failure: exit 1, no agent step.
    $f = New-Fake -Agent '109.1.0' -DriverExit 1603
    $r = Run
    Assert ($r.ExitCode -eq 1 -and $r.Result.DriverExit -eq 1603 -and (Calls) -ceq 'download,msi driver') "driver failure: $(Calls)"

    # A failed driver MSI still restores the network; a failed change does not stop the next one.
    $dnsLost = @((Nic -Alias 'Ethernet 2'))
    $f = New-Fake -Agent '109.1.0' -DriverExit 1603 -Net @((Nic -StaticDns @('192.0.2.53'))) -NetAfter $dnsLost
    $script:VgRunMsi = { param([string[]]$Arguments) $script:Fake.Calls.Add('msi driver'); $script:Fake.Net = $script:Fake.NetAfter; 1603 }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download,msi driver,dns Ethernet 2 192.0.2.53') "restore after a failed driver MSI: $(Calls)"
    $ip = [pscustomobject]@{ Ip = '198.51.100.10'; Prefix = 24; Manual = $true }
    $gw = [pscustomobject]@{ Prefix = '0.0.0.0/0'; NextHop = '198.51.100.1'; Manual = $true }
    $f = New-Fake -Agent '110.2.3' -Net @((Nic -Dhcp $false -Addresses @($ip) -Gateways @($gw) -StaticDns @('192.0.2.53'))) -NetAfter @((Nic -Alias 'Ethernet 2'))
    $f.FailIp = '198.51.100.10'
    $r = Run
    Assert ($r.ExitCode -eq 0 -and (Calls) -clike '*route Ethernet 2 0.0.0.0/0 198.51.100.1,dns Ethernet 2 192.0.2.53*' -and @($r.Result.NetError).Count -eq 1 -and $r.Result.NetError[0] -match 'address in use') "failed address does not stop the rest: $(Calls)"

    # An agent step that throws is reported as 22 and the old agent still runs again.
    $f = New-Fake -Driver '0.1.302' -Agent '109.1.0'
    $script:VgRunMsi = { param([string[]]$Arguments) throw 'msiexec could not start' }
    $r = Run
    Assert ($r.ExitCode -eq 22 -and $r.Result.Reason -match 'could not start' -and (Calls) -clike "*$stopBoth,start-type*start QEMU-GA") "agent step throw: $($r.ExitCode) $(Calls)"

    # A Comet job or a VSS snapshot in progress: refuse with 20 before anything changes.
    $f = New-Fake -Agent '109.1.0'
    $f.Processes = $idle + @('"C:\Program Files\Comet\backup-tool.exe" cmd -Action=backup')
    $r = Run
    Assert ($r.ExitCode -eq 20 -and $r.Result.Status -eq 'backupRunning' -and (Calls) -ceq '') "Comet job: $($r.ExitCode) $(Calls)"
    $f = New-Fake -Agent '109.1.0'
    $f.Processes = @('"C:\Program Files\stream tools\backup-tool.exe" backup --rule 1')
    Assert ((Run).ExitCode -eq 20) 'a path containing stream does not hide a job'
    $f = New-Fake -Agent '109.1.0'
    $f.Writers = "Writer name: 'SqlServerWriter'`n   State: [5] Waiting for completion`n"
    $r = Run
    Assert ($r.ExitCode -eq 20 -and (Calls) -ceq '') "VSS writer mid-snapshot: $($r.ExitCode) $(Calls)"
    # Unreadable writer state fails closed.
    $f = New-Fake -Agent '109.1.0'
    $f.Writers = ''
    Assert ((Run).ExitCode -eq 20) 'empty vssadmin output refuses'
    # A backup that starts during the service wait: no agent MSI, services started again.
    $f = New-Fake -Driver '0.1.302' -Agent '109.1.0' -Held 1
    $script:VgVssWriters = { if ($script:Fake.Delays -gt 0) { 'State: [2] Waiting for freeze' } else { $stable } }
    $r = Run
    Assert ($r.ExitCode -eq 20 -and (Calls) -notmatch 'msi agent' -and (Calls) -clike "*$stopBoth*start QEMU-GA") "backup during the wait: $($r.ExitCode) $(Calls)"
    # Idle Comet helpers and failed or stable writers are not a backup.
    $f = New-Fake -Agent '109.1.0'
    Assert ((Run).ExitCode -eq 0) 'idle Comet and stable writers proceed'
    # Nothing to install: no backup check needed.
    $f = New-Fake -Driver '0.1.302' -Agent '110.2.3'
    $f.Processes = @('"C:\Program Files\Comet\backup-tool.exe" backup')
    Assert ((Run).ExitCode -eq 0) 'current guest ignores a running backup'
    # A backup that starts during the driver step: drivers stay, agent refused with 20, old agent still running.
    $f = New-Fake -Agent '109.1.0'
    $script:VgVssWriters = { if ($script:Fake.Versions['Virtio-win-driver-installer']) { 'State: [3] Waiting for thaw' } else { $stable } }
    $r = Run
    Assert ($r.ExitCode -eq 20 -and $r.Result.DriverVersion -eq '0.1.302' -and (Calls) -notmatch 'msi agent|stop ' -and (Calls) -clike '*start QEMU-GA') "backup after drivers: $($r.ExitCode) $(Calls)"

    # Agent services held (marked for delete): wait 120 s in 5 s polls, then skip the agent MSI with 21.
    $f = New-Fake -Agent '109.1.0' -Held (-1)
    $r = Run
    Assert ($r.ExitCode -eq 21 -and $r.Result.Status -eq 'agentServiceHeld' -and $f.Delays -eq 24) "held service: $($r.ExitCode) $($r.Result.Status) delays $($f.Delays)"
    Assert ((Calls) -notmatch 'msi agent' -and (Calls) -clike '*msi driver*' -and (Calls) -clike '*start QEMU-GA') "held service calls: $(Calls)"
    # Released after two polls: the agent installs.
    $f = New-Fake -Agent '109.1.0' -Held 2
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $f.Delays -eq 2 -and (Calls) -match 'msi agent') "released service: $($r.ExitCode) $(Calls)"

    # Network: hand-set DNS on a DHCP adapter is lost by the new NIC instance and set again, matched by MAC.
    $dns = @('192.0.2.53', '192.0.2.54')
    $f = New-Fake -Agent '110.2.3' -Net @((Nic -StaticDns $dns)) -NetAfter @((Nic -Alias 'Ethernet 2'))
    $r = Run
    Assert ((Calls) -ceq 'download,msi driver,dns Ethernet 2 192.0.2.53 192.0.2.54,start-type QEMU-GA Automatic,start-type QEMU Guest Agent VSS Provider Manual,start QEMU-GA') "DNS re-applied: $(Calls)"
    Assert (@($r.Result.NetReapplied).Count -eq 1 -and $r.Result.NetReapplied[0] -match 'dns') 'DNS re-apply reported'
    $snap = @(Get-Content -LiteralPath $r.Result.NetSnapshot -Raw | ConvertFrom-Json)
    Assert ($r.Result.NetSnapshot.StartsWith($dir) -and [string]$snap[0].Mac -eq $mac -and @($snap[0].StaticDns).Count -eq 2) 'snapshot written as JSON to the log dir'
    # Static address and gateway missing on the new instance: added back; DHCP-assigned ones are left alone.
    $ip = [pscustomobject]@{ Ip = '198.51.100.10'; Prefix = 24; Manual = $true }
    $gw = [pscustomobject]@{ Prefix = '0.0.0.0/0'; NextHop = '198.51.100.1'; Manual = $true }
    $f = New-Fake -Agent '110.2.3' -Net @((Nic -Dhcp $false -Addresses @($ip) -Gateways @($gw) -StaticDns $dns)) -NetAfter @((Nic -Alias 'Ethernet 2' -StaticDns $dns))
    $r = Run
    Assert ((Calls) -clike 'download,msi driver,ip Ethernet 2 198.51.100.10/24 dhcp=False,route Ethernet 2 0.0.0.0/0 198.51.100.1,start*') "static IP re-applied: $(Calls)"
    $dhcpIp = [pscustomobject]@{ Ip = '203.0.113.20'; Prefix = 24; Manual = $false }
    $f = New-Fake -Agent '110.2.3' -Net @((Nic -Addresses @($dhcpIp))) -NetAfter @((Nic))
    $r = Run
    Assert ((Calls) -notmatch 'ip |route |dns ' -and @($r.Result.NetReapplied).Count -eq 0) "DHCP config left alone: $(Calls)"
    # The adapter does not come back: bounded wait, reported, the run goes on.
    $f = New-Fake -Agent '110.2.3' -Net @((Nic -StaticDns $dns)) -NetAfter @()
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $f.Delays -eq 24 -and @($r.Result.NetMissing) -contains $mac) "adapter missing: $($f.Delays)"
    # Agent-only run takes no snapshot.
    $f = New-Fake -Driver '0.1.302' -Agent '109.1.0' -Net @((Nic -StaticDns $dns))
    $r = Run
    Assert (-not $r.Result.Contains('NetSnapshot')) 'no snapshot without a driver step'

    # Reboot requested by an installer is reported, never acted on.
    $f = New-Fake -DriverExit 3010
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.RebootRequired) 'driver exit 3010 is success with RebootRequired'
    $f = New-Fake -Driver '0.1.302' -AgentExit 1641
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.RebootRequired) 'agent exit 1641 is success with RebootRequired'

    # Not a QEMU guest: nothing happens.
    $f = New-Fake -Manufacturer 'Dell Inc.' -Pnp @((Pci '8086' '15BB'))
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'notQemuGuest' -and (Calls) -ceq '') "non-QEMU: $($r.Result.Status) $(Calls)"
    # SMBIOS overridden but VirtIO devices present: still a guest.
    $f = New-Fake -Manufacturer 'Custom' -Pnp @((Pci '1AF4' '1041'))
    Assert ((Run).Result.Status -eq 'installed') 'VirtIO PCI device marks a guest'

    # No virtio-serial channel: the agent cannot start. Installed, exit 0, told why.
    $f = New-Fake -Pnp @((Pci '1AF4' '1004')) -AgentStarts $false
    $r = Run
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'agentChannelMissing' -and -not $r.Result.AgentRunning) "no channel: $($r.ExitCode) $($r.Result.Status)"
    # Channel present but the agent will not start: failure.
    $f = New-Fake -AgentStarts $false
    Assert ((Run).ExitCode -eq 1) 'agent that does not start with a channel exits 1'

    # Refusals before any download.
    $f = New-Fake
    $userinfo = -join @('https://', 'user', '@', 'example.invalid/x.msi')
    Assert ((Run -Action 'Uninstall').ExitCode -eq 1 -and (Calls) -ceq '') 'uninstall refused'
    Assert ((Run -Sha ('1' * 64)).ExitCode -eq 1 -and (Run -AgentSha ('1' * 64)).ExitCode -eq 1 -and (Calls) -ceq '') 'placeholder hash refused'
    Assert ((Run -Url $userinfo).ExitCode -eq 1 -and (Run -AgentUrl $userinfo).ExitCode -eq 1 -and (Calls) -ceq '') 'userinfo URL refused'
    Assert ((Run -Url 'http://example.invalid/x.msi').ExitCode -eq 1 -and (Run -AgentUrl 'http://example.invalid/x.msi').ExitCode -eq 1 -and (Calls) -ceq '') 'plain http refused'
    Assert ((Run -Pin 'abc').ExitCode -eq 1 -and (Run -AgentPin 'abc').ExitCode -eq 1 -and (Calls) -ceq '') 'bad pin refused'
    foreach ($off in @(@{ Pin = '' }, @{ Sha = '' }, @{ AgentSha = '' })) {
        $r = Run @off
        Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'disabled' -and (Calls) -ceq '') "empty $($off.Keys) disables"
    }
    $r = Run -Pin '' -Url $userinfo -Action 'Uninstall'
    Assert ($r.ExitCode -eq 0 -and (Calls) -ceq '') 'empty pin exits 0 before URL and action checks'

    # Hash mismatch: one download, no retry, no install.
    $f = New-Fake
    $r = Run -Sha ('a' * 63 + 'b')
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download') "hash mismatch: $(Calls)"

    # Transient download errors are tried three times; anything else once.
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.WebException]::new('timed out', [System.Net.WebExceptionStatus]::Timeout) }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download,download,download') "transient download retries: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.Http.HttpRequestException]::new('not found', $null, [System.Net.HttpStatusCode]::NotFound) }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download') "404 is not retried: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw [System.Net.Http.HttpRequestException]::new('busy', $null, [System.Net.HttpStatusCode]::ServiceUnavailable) }
    $r = Run
    Assert ((Calls) -ceq 'download,download,download') "503 is retried: $(Calls)"
    $f = New-Fake
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); throw 'network down' }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and (Calls) -ceq 'download' -and $r.Result.DownloadError -match 'network down') "unclassified error is not retried: $(Calls)"
    # A failed agent download leaves the drivers and the old agent in place.
    $f = New-Fake -Agent '109.1.0'
    $script:DownloadFile = { param($Url, $Destination) $script:Fake.Calls.Add('download'); if ($Url -match 'qemu-ga') { throw 'gone' }; Copy-Item -LiteralPath $script:Payload -Destination $Destination }
    $r = Run
    Assert ($r.ExitCode -eq 1 -and $r.Result.DriverVersion -eq '0.1.302' -and (Calls) -notmatch 'stop |msi agent' -and (Calls) -clike '*start QEMU-GA') "agent download failure: $(Calls)"

    # Cancel before download.
    $f = New-Fake
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $r = Run
    $env:RELIAN_DEPLOY_CANCEL = $null
    Assert ($r.ExitCode -eq 130 -and (Calls) -ceq '') 'cancel'

    # Pins above what the MSIs install: fail rather than loop.
    $f = New-Fake
    Assert ((Run -Pin '0.1.400').ExitCode -eq 1) 'drivers still below the pin after install'
    $f = New-Fake
    Assert ((Run -AgentPin '111.0.0').ExitCode -eq 22) 'agent still below the pin after install'

    # VssOption: empty leaves it alone; a value is written after the agent step, also when the MSI reset it.
    $f = New-Fake
    $r = Run
    Assert (-not ((Calls) -match 'vss-option')) 'empty VssOption writes nothing'
    $f = New-Fake
    $r = Run -Vss '5'
    Assert ($r.ExitCode -eq 0 -and $r.Result.VssOption -eq '5' -and (Calls) -clike '*msi agent,start QEMU-GA,vss-option 5') "VssOption 5: $(Calls)"
    $f.Calls.Clear()
    $r = Run -Vss '5'
    Assert ((Calls) -ceq '' -and $r.Result.Status -eq 'current') "VssOption already 5 is a no-op: $(Calls)"
    $f = New-Fake -Driver '0.1.302' -Agent '109.1.0'
    $f.VssOption = '5'
    $r = Run -Vss '5'
    Assert ($r.Result.VssOption -eq '5' -and (Calls) -clike '*msi agent,*vss-option 5') "VssOption set again after the agent MSI reset it: $(Calls)"
    $f = New-Fake
    Assert ((Run -Vss '9').ExitCode -eq 1 -and (Calls) -ceq '') 'bad VssOption refused before download'

    # Version compare is numeric.
    Assert ((Compare-VgVersion '0.1.99' '0.1.302') -lt 0 -and (Compare-VgVersion '0.1.302' '0.1.302') -eq 0) 'numeric version compare'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# Two silent msiexec runs, never the Burn bundle; never restarts; logs.
$text = Get-Content -LiteralPath $scriptPath -Raw
Assert ($text.Contains("'/qn', '/norestart', '/l*v'")) 'msiexec arguments'
Assert ($text -notmatch '(?i)guest-tools\.exe') 'the Burn bundle must not be used'
Assert ($text -notmatch '(?i)Restart-Computer|shutdown(\.exe)?\s+/r') 'the package must not reboot'
Assert ($text -match "-UserAgent 'relian-device-scripts'") 'download must not send a Mozilla User-Agent (fedorapeople bot check)'

Write-Output 'virtio-guest-tools tests passed'
exit 0
