$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wireguard-network-guard/Invoke-WireGuardNetworkGuard.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/wireguard-network-guard.json'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { Fail $Label }
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

function Assert-Like {
    param([string]$Actual, [string]$Pattern, [string]$Label)
    if ($Actual -notlike $Pattern) { Fail "$Label was [$Actual] expected like [$Pattern]" }
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Pattern, [string]$Label)
    $threw = $false
    $msg = ''
    try {
        & $Block
    } catch {
        $threw = $true
        $msg = $_.Exception.Message
    }
    if (-not $threw) { Fail "$Label did not throw" }
    if ($Pattern -and $msg -notlike $Pattern) { Fail "$Label threw [$msg] expected like [$Pattern]" }
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail "missing package script $scriptPath"
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# 1. MAC normalization and gateway rule parsing.
Assert-Same (ConvertTo-WgCanonicalMac -Mac '00:53:00:11:22:33') '00-53-00-11-22-33' 'colon MAC normalized'
Assert-Same (ConvertTo-WgCanonicalMac -Mac '00-53-00-11-22-33') '00-53-00-11-22-33' 'dash MAC normalized'
Assert-Same (ConvertTo-WgCanonicalMac -Mac '0053.0011.2233') '00-53-00-11-22-33' 'cisco dot MAC normalized'
Assert-Same (ConvertTo-WgCanonicalMac -Mac '005300112233') '00-53-00-11-22-33' 'bare hex MAC normalized'
Assert-Same (ConvertTo-WgCanonicalMac -Mac '00:00:00:00:00:00') $null 'all-zero MAC rejected'
Assert-Same (ConvertTo-WgCanonicalMac -Mac 'ff:ff:ff:ff:ff:ff') $null 'broadcast MAC rejected'
Assert-Same (ConvertTo-WgCanonicalMac -Mac 'not-a-mac') $null 'invalid MAC rejected'

$xmlAmp = New-WgTaskXml -ScriptPath 'C:\ProgramData\Relian & Co\Invoke-WireGuardNetworkGuard.ps1' -InstallRoot 'C:\ProgramData\Relian & Co'
Assert-Like $xmlAmp '*Relian &amp; Co*' 'ampersand escaped once in Task XML'
Assert-True ($xmlAmp -notlike '*&amp;amp;*') 'ampersand is not double-escaped in Task XML'
Assert-Like $xmlAmp '*-InstallRoot*' 'InstallRoot included in Task XML arguments'

# Task settings. Priority 7 (BelowNormal) starved powershell.exe on a CPU-saturated test PC (2026-11-27: start
# 53 s or stuck past 90 s, Check stuck past 90 s; at Normal 1.6-2.9 s and 9.8 s), and with Queue every later trigger
# waited behind the starved run. Priority 4 is Normal (taskschd PriorityType). A 15-minute repeating trigger catches a
# run that failed or an event that never came.
$taskDoc = [xml](New-WgTaskXml -ScriptPath 'C:\ProgramData\Relian\WireGuardNetworkGuard\Invoke-WireGuardNetworkGuard.ps1' -InstallRoot 'C:\ProgramData\Relian\WireGuardNetworkGuard')
$tns = New-Object System.Xml.XmlNamespaceManager($taskDoc.NameTable)
$tns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
Assert-Same $taskDoc.SelectSingleNode('//t:Settings/t:Priority', $tns).InnerText '4' 'task runs at Normal priority (4)'
Assert-Same $taskDoc.SelectSingleNode('//t:Settings/t:ExecutionTimeLimit', $tns).InnerText 'PT5M' 'task time limit is 5 minutes'
Assert-Same $taskDoc.SelectSingleNode('//t:Settings/t:MultipleInstancesPolicy', $tns).InnerText 'Queue' 'queued triggers still run after the current one'
Assert-Same $taskDoc.SelectSingleNode('//t:Triggers/t:TimeTrigger/t:Repetition/t:Interval', $tns).InnerText 'PT15M' 'backstop trigger repeats every 15 minutes'
Assert-True ($null -eq $taskDoc.SelectSingleNode('//t:Triggers/t:TimeTrigger/t:Repetition/t:Duration', $tns)) 'backstop repeats indefinitely (no Duration)'
Assert-Same @($taskDoc.SelectNodes('//t:Triggers/t:EventTrigger', $tns)).Count 2 'network and wake event triggers kept'
Assert-True ($null -ne $taskDoc.SelectSingleNode('//t:Triggers/t:BootTrigger', $tns)) 'boot trigger kept'

# Inline IP=MAC and shared TrustedGatewayMacs parsing.
$rulesInline = @(ConvertFrom-WgGatewayRules -TrustedGateways '192.0.2.1=00:11:22:33:44:55,198.51.100.1=00-11-22-33-44-55|00-11-22-33-44-56')
Assert-Same $rulesInline.Count 2 'two inline gateway rules parsed'
Assert-Same $rulesInline[0].ip '192.0.2.1' 'rule 0 IP'
Assert-Same ($rulesInline[0].macs -join ',') '00-11-22-33-44-55' 'rule 0 MAC'
Assert-Same $rulesInline[1].ip '198.51.100.1' 'rule 1 IP'
Assert-Same ($rulesInline[1].macs -join ',') '00-11-22-33-44-55,00-11-22-33-44-56' 'rule 1 multi-MAC'

$rulesShared = @(ConvertFrom-WgGatewayRules -TrustedGateways '192.0.2.1,198.51.100.1' -TrustedGatewayMacs '00:11:22:33:44:55')
Assert-Same $rulesShared.Count 2 'two shared-MAC gateway rules parsed'
Assert-Same ($rulesShared[0].macs -join ',') '00-11-22-33-44-55' 'shared MAC applied to rule 0'
Assert-Same ($rulesShared[1].macs -join ',') '00-11-22-33-44-55' 'shared MAC applied to rule 1'

# Gateway without MAC is refused unless AllowGatewayIpOnly is true.
Assert-Throws {
    ConvertFrom-WgGatewayRules -TrustedGateways '192.0.2.1' -TrustedGatewayMacs '' -AllowGatewayIpOnly:$false
} '*requires a trusted MAC*' 'IP-only gateway refused by default'

$rulesIpOnly = @(ConvertFrom-WgGatewayRules -TrustedGateways '192.0.2.1' -TrustedGatewayMacs '' -AllowGatewayIpOnly:$true)
Assert-Same $rulesIpOnly.Count 1 'IP-only gateway allowed when explicitly enabled'
Assert-Same $rulesIpOnly[0].macs.Count 0 'IP-only gateway has empty MAC list'

# Unsafe / non-unicast gateway IPs and non-WireGuard service patterns are refused.
Assert-Throws {
    ConvertFrom-WgGatewayRules -TrustedGateways '127.0.0.1=00-11-22-33-44-55'
} '*invalid gateway IPv4*' 'loopback gateway rejected'

Assert-Throws {
    Get-WgOptions -Action 'Install' -TrustedGateways '192.0.2.1=00-11-22-33-44-55' -TunnelPattern 'WinDefend*'
} '*TunnelPattern*' 'non-WireGuard service pattern rejected'

Assert-Throws {
    Get-WgOptions -Action 'Install' -TrustedGateways '' -TrustDomainAuthenticated 'false'
} '*trusted network*' 'Install without any trusted network criteria rejected'

# 2. Fake environment for end-to-end Install, Evaluate (office vs remote vs stale ARP vs airplane mode), and Uninstall.
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wg-guard-test-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force

try {
    $fakeSourceScript = Join-Path $tmpRoot 'Invoke-WireGuardNetworkGuard.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $fakeSourceScript -Force
    $installRoot = Join-Path $tmpRoot 'ProgramData\Relian\WireGuardNetworkGuard'

    function Reset-WgFake {
        $script:fakeGateways = @()
        $script:fakeNeighbors = @{}
        $script:fakeProbed = [System.Collections.Generic.List[string]]::new()
        $script:fakeAfterProbeNeighbors = @{}
        $script:fakeServices = @(
            [pscustomobject]@{ Name = 'WireGuardTunnel$client_00001'; Status = 'Running'; StartType = 'Automatic' }
            [pscustomobject]@{ Name = 'WireGuardTunnel$disabled_00002'; Status = 'Stopped'; StartType = 'Disabled' }
        )
        $script:fakeTasks = @{}
        $script:serviceCalls = [System.Collections.Generic.List[string]]::new()
        $script:taskCalls = [System.Collections.Generic.List[string]]::new()

        $script:WgGetPhysicalGateways = {
            return $script:fakeGateways
        }
        $script:WgGetNeighbor = {
            param([int]$InterfaceIndex, [string]$IPAddress)
            $key = "$InterfaceIndex|$IPAddress"
            if ($script:fakeNeighbors.ContainsKey($key)) {
                return $script:fakeNeighbors[$key]
            }
            return $null
        }
        $script:WgProbeGateway = {
            param([int]$InterfaceIndex, [string]$IPAddress)
            $key = "$InterfaceIndex|$IPAddress"
            [void]$script:fakeProbed.Add($key)
            if ($script:fakeAfterProbeNeighbors.ContainsKey($key)) {
                $script:fakeNeighbors[$key] = $script:fakeAfterProbeNeighbors[$key]
            }
        }
        $script:WgWaitNeighbor = {
            param([int]$Milliseconds = 150)
        }
        $script:WgGetServices = {
            return $script:fakeServices
        }
        $script:WgStopService = {
            param([string]$Name)
            [void]$script:serviceCalls.Add("stop $Name")
            foreach ($svc in $script:fakeServices) {
                if ($svc.Name -eq $Name) { $svc.Status = 'Stopped' }
            }
        }
        $script:WgStartService = {
            param([string]$Name)
            [void]$script:serviceCalls.Add("start $Name")
            foreach ($svc in $script:fakeServices) {
                if ($svc.Name -eq $Name) { $svc.Status = 'Running' }
            }
        }
        $script:WgRegisterTask = {
            param([string]$TaskName, [string]$Xml)
            [void]$script:taskCalls.Add("register $TaskName")
            $script:fakeTasks[$TaskName] = $Xml
        }
        $script:WgUnregisterTask = {
            param([string]$TaskName)
            [void]$script:taskCalls.Add("unregister $TaskName")
            [void]$script:fakeTasks.Remove($TaskName)
        }
        $script:WgTestTaskPresent = {
            param([string]$TaskName)
            return $script:fakeTasks.ContainsKey($TaskName)
        }
        $script:WgHardenDirectoryAcl = {
            param([string]$Path)
        }
        $script:WgUntrustedDirectory = {
            param([string]$Path, [switch]$OwnerOnly)
        }
        $script:dirCalls = [System.Collections.Generic.List[string]]::new()
        $script:WgNewLockedDirectory = {
            param([string]$Path)
            [void]$script:dirCalls.Add($Path)
            $null = New-Item -ItemType Directory -Path $Path -Force
        }
    }

    # Case A: Install while on the office Wi-Fi VLAN (gateway 192.0.2.25, MAC 00-11-22-33-44-55).
    Reset-WgFake
    $script:fakeGateways = @(
        [pscustomobject]@{
            InterfaceIndex = 12
            InterfaceAlias = 'Wi-Fi'
            InterfaceDescription = 'Intel(R) Wi-Fi 6E AX211'
            GatewayIp = '192.0.2.25'
            NetworkCategory = 'Private'
            DnsSuffix = 'office.example.invalid'
        }
    )
    $script:fakeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Reachable'
        LinkLayerAddress = '00-11-22-33-44-55'
    }

    $optsInstall = Get-WgOptions -Action 'Install' `
        -TrustedGateways '192.0.2.25,192.0.2.1' `
        -TrustedGatewayMacs '00:11:22:33:44:55' `
        -InstallRoot $installRoot `
        -SourceScriptPath $fakeSourceScript

    $resInstall = Invoke-WgRun -Options $optsInstall
    Assert-Same $resInstall.exitCode 0 'Install on office network exits 0'
    Assert-Same $resInstall.record.mode 'install' 'Install mode recorded'
    Assert-True $resInstall.record.onTrustedNetwork 'Install detected trusted office network'
    Assert-Same ($resInstall.record.stoppedServices -join ',') 'WireGuardTunnel$client_00001' 'Running tunnel service stopped on office network'
    Assert-Same ($script:serviceCalls -join ',') 'stop WireGuardTunnel$client_00001' 'Stop-Service called once'
    Assert-Same ($script:taskCalls -join ',') 'register Relian-WireGuardNetworkGuard' 'Scheduled task registered'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'config.json')) 'config.json written'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Invoke-WireGuardNetworkGuard.ps1')) 'local script copy written'
    Assert-Like $script:fakeTasks['Relian-WireGuardNetworkGuard'] '*Microsoft-Windows-NetworkProfile/Operational*' 'Task XML subscribes to NetworkProfile events'
    Assert-Like $script:fakeTasks['Relian-WireGuardNetworkGuard'] '*EventID=10000 or EventID=10001*' 'Task XML triggers on Event ID 10000 and 10001'

    # Case B: Laptop roams to an external network (home/hotel Wi-Fi that happens to use the SAME gateway IP 192.0.2.25,
    # and the Windows ARP cache still has a Stale entry for 00-11-22-33-44-55 until probed!).
    $script:serviceCalls.Clear()
    $script:fakeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Stale'
        LinkLayerAddress = '00-11-22-33-44-55'
    }
    $script:fakeAfterProbeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Reachable'
        LinkLayerAddress = 'AA-BB-CC-DD-EE-FF'
    }

    $optsEval = Get-WgOptions -Action 'Evaluate' -InstallRoot $installRoot -SourceScriptPath $fakeSourceScript
    $resEvalRemote = Invoke-WgRun -Options $optsEval
    Assert-Same $resEvalRemote.exitCode 0 'Evaluate on remote network exits 0'
    Assert-Same ($script:fakeProbed -join ',') '12|192.0.2.25' 'Stale neighbor entry was actively re-probed'
    Assert-Same $resEvalRemote.record.onTrustedNetwork $false 'Stale office MAC rejected after probe revealed home router MAC'
    Assert-Same ($resEvalRemote.record.startedServices -join ',') 'WireGuardTunnel$client_00001' 'Stopped tunnel service restarted when remote'
    Assert-Same ($script:serviceCalls -join ',') 'start WireGuardTunnel$client_00001' 'Disabled tunnel service was not started'

    # Case C: Laptop is in airplane mode / between networks (no physical gateway). Tunnel service is not churned.
    $script:serviceCalls.Clear()
    foreach ($svc in $script:fakeServices) {
        if ($svc.Name -eq 'WireGuardTunnel$client_00001') { $svc.Status = 'Stopped' }
    }
    $script:fakeGateways = @()
    $resNoNet = Invoke-WgRun -Options $optsEval
    Assert-Same $resNoNet.exitCode 0 'Evaluate with no network exits 0'
    Assert-Same $resNoNet.record.onTrustedNetwork $false 'Disconnected is not trusted network'
    Assert-Same $script:serviceCalls.Count 0 'No service started while physical network is disconnected'

    # Case D: Laptop docks on office wired VLAN (192.0.2.1, neighbor Incomplete until probed).
    $script:fakeGateways = @(
        [pscustomobject]@{
            InterfaceIndex = 7
            InterfaceAlias = 'Ethernet'
            InterfaceDescription = 'Realtek USB GbE Family Controller'
            GatewayIp = '192.0.2.1'
            NetworkCategory = 'DomainAuthenticated'
            DnsSuffix = 'office.example.invalid'
        }
    )
    foreach ($svc in $script:fakeServices) {
        if ($svc.Name -eq 'WireGuardTunnel$client_00001') { $svc.Status = 'Running' }
    }
    $script:fakeNeighbors['7|192.0.2.1'] = [pscustomobject]@{
        State = 'Incomplete'
        LinkLayerAddress = ''
    }
    $script:fakeAfterProbeNeighbors['7|192.0.2.1'] = [pscustomobject]@{
        State = 'Reachable'
        LinkLayerAddress = '00-11-22-33-44-55'
    }
    $resDocked = Invoke-WgRun -Options $optsEval
    Assert-Same $resDocked.exitCode 0 'Evaluate on docked Ethernet exits 0'
    Assert-True $resDocked.record.onTrustedNetwork 'Incomplete ARP resolved after probe and matched trusted gateway'
    Assert-Same ($resDocked.record.stoppedServices -join ',') 'WireGuardTunnel$client_00001' 'Tunnel stopped on docked office Ethernet'

    # Case E: Uninstall removes task, restarts the tunnel service that the guard stopped, and cleans InstallRoot.
    $script:serviceCalls.Clear()
    $script:taskCalls.Clear()
    $optsUninstall = Get-WgOptions -Action 'Uninstall' -InstallRoot $installRoot -SourceScriptPath $fakeSourceScript
    $resUninstall = Invoke-WgRun -Options $optsUninstall
    Assert-Same $resUninstall.exitCode 0 'Uninstall exits 0'
    Assert-Same $resUninstall.record.mode 'uninstall' 'Uninstall mode recorded'
    Assert-Same ($script:taskCalls -join ',') 'unregister Relian-WireGuardNetworkGuard' 'Scheduled task unregistered'
    Assert-Same ($script:serviceCalls -join ',') 'start WireGuardTunnel$client_00001' 'Uninstall restarted tunnel service stopped by guard'
    Assert-Same (Test-Path -LiteralPath $installRoot) $false 'InstallRoot removed on Uninstall'

    # Case F: Second Uninstall (or pre-Install step of Reinstall) when not installed exits 0 cleanly.
    $script:serviceCalls.Clear()
    $script:taskCalls.Clear()
    $resUninstallAgain = Invoke-WgRun -Options $optsUninstall
    Assert-Same $resUninstallAgain.exitCode 0 'Idempotent Uninstall exits 0 when already absent'
    Assert-Same $script:serviceCalls.Count 0 'Second Uninstall touches no services'

    # Case G: Check mode is strictly read-only (does not stop services, register tasks, or write files).
    Reset-WgFake
    $script:fakeGateways = @(
        [pscustomobject]@{
            InterfaceIndex = 12
            InterfaceAlias = 'Wi-Fi'
            InterfaceDescription = 'Intel(R) Wi-Fi 6E AX211'
            GatewayIp = '192.0.2.25'
            NetworkCategory = 'Private'
            DnsSuffix = 'office.example.invalid'
        }
    )
    $script:fakeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Reachable'
        LinkLayerAddress = '00-11-22-33-44-55'
    }
    $optsCheck = Get-WgOptions -Action 'Check' `
        -TrustedGateways '192.0.2.25=00-11-22-33-44-55' `
        -InstallRoot $installRoot `
        -SourceScriptPath $fakeSourceScript
    $resCheck = Invoke-WgRun -Options $optsCheck
    Assert-Same $resCheck.exitCode 0 'Check mode exits 0'
    Assert-Same $resCheck.record.mode 'check' 'Check mode recorded'
    Assert-True $resCheck.record.onTrustedNetwork 'Check mode detected trusted network'
    Assert-Same ($resCheck.record.stoppedServices -join ',') 'WireGuardTunnel$client_00001' 'Check mode reports service that would be stopped'
    Assert-Same $script:serviceCalls.Count 0 'Check mode does not stop or start services'
    Assert-Same $script:taskCalls.Count 0 'Check mode does not touch scheduled tasks'
    Assert-Same (Test-Path -LiteralPath $installRoot) $false 'Check mode does not create InstallRoot'

    # Case H: DomainAuthenticated + TrustedDnsSuffixes matching.
    Reset-WgFake
    $script:fakeGateways = @(
        [pscustomobject]@{
            InterfaceIndex = 9
            InterfaceAlias = 'Ethernet'
            InterfaceDescription = 'Intel Ethernet'
            GatewayIp = '198.51.100.1'
            NetworkCategory = 'DomainAuthenticated'
            DnsSuffix = 'other.example.invalid'
        }
    )
    $optsDomain = Get-WgOptions -Action 'Check' `
        -TrustDomainAuthenticated 'true' `
        -TrustedDnsSuffixes 'office.example.invalid' `
        -InstallRoot $installRoot `
        -SourceScriptPath $fakeSourceScript
    $resWrongSuffix = Invoke-WgRun -Options $optsDomain
    Assert-Same $resWrongSuffix.record.onTrustedNetwork $false 'DomainAuthenticated with wrong DNS suffix is not trusted'

    $script:fakeGateways[0].DnsSuffix = 'office.example.invalid'
    $resRightSuffix = Invoke-WgRun -Options $optsDomain
    Assert-True $resRightSuffix.record.onTrustedNetwork 'DomainAuthenticated with matching DNS suffix is trusted'

    # DeploymentType Check/Evaluate without -Action selects Check/Evaluate mode rather than Install.
    $optsDeployTypeCheck = Get-WgOptions -DeploymentType 'Check' `
        -TrustedGateways '192.0.2.25=00-11-22-33-44-55' `
        -InstallRoot $installRoot `
        -SourceScriptPath $fakeSourceScript
    Assert-Same $optsDeployTypeCheck.mode 'check' 'DeploymentType Check selects check mode when Action is omitted'

    # Unconfirmed Delay/Probe neighbor state after probe is rejected.
    Reset-WgFake
    $script:fakeGateways = @(
        [pscustomobject]@{
            InterfaceIndex = 12
            InterfaceAlias = 'Wi-Fi'
            InterfaceDescription = 'Intel(R) Wi-Fi 6E AX211'
            GatewayIp = '192.0.2.25'
            NetworkCategory = 'Private'
            DnsSuffix = 'office.example.invalid'
        }
    )
    $script:fakeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Stale'
        LinkLayerAddress = '00-11-22-33-44-55'
    }
    $script:fakeAfterProbeNeighbors['12|192.0.2.25'] = [pscustomobject]@{
        State = 'Delay'
        LinkLayerAddress = '00-11-22-33-44-55'
    }
    $resDelay = Invoke-WgRun -Options $optsDeployTypeCheck
    Assert-Same $resDelay.record.onTrustedNetwork $false 'Neighbor remaining in Delay state after probe is not trusted'

    # Case H2: an install folder that someone else made (a user can create folders under ProgramData) is set aside, never
    # re-permissioned in place: a handle opened before the ACL change keeps its rights, so its maker could later swap the
    # script the SYSTEM task runs. The new folder is created fresh.
    Reset-WgFake
    $plantedRoot = Join-Path $tmpRoot 'PlantedRoot'
    $null = New-Item -ItemType Directory -Path $plantedRoot -Force
    Set-Content -LiteralPath (Join-Path $plantedRoot 'planted.txt') -Value 'x'
    $script:WgUntrustedDirectory = {
        param([string]$Path, [switch]$OwnerOnly)
        if (Test-Path -LiteralPath (Join-Path $Path 'planted.txt')) { return "$Path is owned by S-1-5-21-1-2-3-1001" }
    }
    $optsPlanted = Get-WgOptions -Action 'Install' -TrustedGateways '192.0.2.25=00-11-22-33-44-55' -InstallRoot $plantedRoot -SourceScriptPath $fakeSourceScript
    $resPlanted = Invoke-WgRun -Options $optsPlanted
    Assert-Same $resPlanted.exitCode 0 'Install over a foreign folder exits 0'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $plantedRoot 'planted.txt'))) 'foreign folder is not reused'
    $aside = @(Get-ChildItem -LiteralPath $tmpRoot -Directory | Where-Object { $_.Name -like 'PlantedRoot.old-*' })
    Assert-Same $aside.Count 1 'foreign folder set aside once'
    Assert-True (Test-Path -LiteralPath (Join-Path $aside[0].FullName 'planted.txt')) 'set-aside folder keeps its content for review'
    Assert-True (Test-Path -LiteralPath (Join-Path $plantedRoot 'config.json')) 'config.json written to the fresh folder'
    # Born locked (SYSTEM and Administrators only), never created open and hardened afterwards: a handle opened in that
    # window would keep its rights.
    Assert-Same ($script:dirCalls -join ',') $plantedRoot 'fresh folder created through the locked-creation seam'

    # Case H3: someone recreates the folder between the move and New-Item. Its owner is not SYSTEM or Administrators, and
    # an owner cannot be forged, so Install refuses it before hardening and writes nothing into it.
    Reset-WgFake
    $racedRoot = Join-Path $tmpRoot 'RacedRoot'
    $null = New-Item -ItemType Directory -Path $racedRoot -Force
    $script:WgUntrustedDirectory = {
        param([string]$Path, [switch]$OwnerOnly)
        return "$Path is owned by S-1-5-21-1-2-3-1001"
    }
    $optsRaced = Get-WgOptions -Action 'Install' -TrustedGateways '192.0.2.25=00-11-22-33-44-55' -InstallRoot $racedRoot -SourceScriptPath $fakeSourceScript
    $racedThrew = $false
    try { $resRaced = Invoke-WgRun -Options $optsRaced } catch { $racedThrew = $true }
    Assert-True $racedThrew 'Install refuses a folder whose owner is still foreign after the move'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $racedRoot 'config.json'))) 'nothing written into a foreign folder'
    Assert-Same $script:taskCalls.Count 0 'no task registered for a foreign folder'

    # Case I: Real child process execution of Uninstall on an empty InstallRoot with RELIAN_DEPLOY_TEST unset emits valid JSON on stdout and exits 0.
    Remove-Item Env:\RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
    try {
        $childOut = & pwsh -NoProfile -File $scriptPath -Action Uninstall -InstallRoot (Join-Path $tmpRoot 'NonExistentRoot') 2>&1
        Assert-Same $LASTEXITCODE 0 'Child process Uninstall exits 0'
    } finally {
        $env:RELIAN_DEPLOY_TEST = '1'
    }
    $lastLine = [string](@($childOut) | Select-Object -Last 1)
    $parsedChild = $lastLine | ConvertFrom-Json
    Assert-Same $parsedChild.mode 'uninstall' 'Child process emitted uninstall JSON'
    Assert-Same $parsedChild.verdict 'uninstalled: nothing was installed' 'Child process verdict'
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. Release metadata JSON and runbook documentation exist and are valid.
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail "missing release metadata $releasePath"
}
$releaseJson = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
Assert-Same $releaseJson.kind 'service-guard' 'release metadata kind'
Assert-Same $releaseJson.installsSoftware $false 'release metadata installsSoftware'

$runbookPath = Join-Path $repoRoot 'docs/wireguard-network-guard.md'
Assert-True (Test-Path -LiteralPath $runbookPath) 'docs/wireguard-network-guard.md exists'
$readmeContent = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
Assert-Like $readmeContent '*docs/wireguard-network-guard.md*' 'README links to docs/wireguard-network-guard.md'
