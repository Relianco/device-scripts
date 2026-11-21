<#
.SYNOPSIS
    Read-only Hyper-V host inventory for sizing a server or network refresh.
.DESCRIPTION
    Runs through the Relian deploy runner (NinjaOne script 374) or Invoke-RelianReadJob as SYSTEM, Windows
    PowerShell 5.1, on a Hyper-V host. Prints one line of JSON, at most 8,000 UTF-8 bytes.

    Package arguments (base64 JSON in -PackageArguments):
      Offset   first VM of the page (the previous run prints nextOffset); VMs are sorted by name

    host      model, RAM total and free, logical processors, OS
    vms       per VM: state, generation, version, vCPU, startup and assigned memory, dynamic memory, uptime,
              automatic start action, notes (clipped), disks (name, max size, file size, type), network adapters
              (switch, MAC, VLAN, IPs), guest KVP OS name, version and FQDN, enabled integration services
    switches, hostNics (link speed), ipv4, dhcp (DHCP Server role state, scope and lease counts)

    Host sections are on the first page only. A page holds up to 10 VMs and fewer when they do not fit; nextOffset
    is null on the last page. A single VM too large for a page has its longest lists trimmed and "truncated" set.
    Without the Hyper-V PowerShell module it prints status hyperVAbsent and exits 0. Nothing is changed: no VM,
    switch, disk, service or field is touched.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Offset = '0'
)
$ProgressPreference = 'SilentlyContinue'

$script:HviMaxBytes = 8000
$script:HviPageSize = 10
$script:HviKvpNames = @('OSName', 'OSVersion', 'FullyQualifiedDomainName')

function Protect-HviText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 80)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Get-HviError { param($ErrorRecord) return [ordered]@{ status = 'unavailable'; error = $ErrorRecord.Exception.GetType().Name; message = (Protect-HviText ([string]$ErrorRecord.Exception.Message) -Max 160) } }

# Runs one source; a failure is reported in its place, not fatal.
function Invoke-HviStep {
    param($Report, [string]$Key, [scriptblock]$Block, [switch]$AsList)
    try { $v = & $Block; if ($AsList) { $v = @($v) }; $Report[$Key] = $v } catch { $Report[$Key] = Get-HviError $_ }
}

function Get-HviGB { param($Bytes) return [Math]::Round([double]$Bytes / 1GB, 2) }

function Get-HviHost {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [ordered]@{ manufacturer = [string]$cs.Manufacturer; model = [string]$cs.Model; ramGB = (Get-HviGB $cs.TotalPhysicalMemory)
        freeRamGB = (Get-HviGB (1KB * [double]$os.FreePhysicalMemory)); logicalProcessors = [int]$cs.NumberOfLogicalProcessors
        os = [string]$os.Caption; osVersion = [string]$os.Version }
}

# Guest intrinsic KVP items by VM id (Msvm_KvpExchangeComponent.SystemName is the VM GUID).
function Get-HviKvp {
    $map = @{}
    foreach ($c in @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_KvpExchangeComponent)) {
        $guest = [ordered]@{}
        foreach ($item in @($c.GuestIntrinsicExchangeItems)) {
            $x = [xml]$item
            $n = $x.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE")
            $d = $x.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE")
            if ($n -and $d -and $script:HviKvpNames -contains $n.InnerText) { $guest[$n.InnerText] = Protect-HviText $d.InnerText -Max 120 }
        }
        $map[[string]$c.SystemName] = $guest
    }
    return $map
}

function Get-HviVlan {
    param($Adapter)
    $vl = Get-VMNetworkAdapterVlan -VMNetworkAdapter $Adapter
    if (-not $vl) { return $null }
    $mode = [string]$vl.OperationMode
    if ($mode -eq 'Access') { return 'Access:' + $vl.AccessVlanId }
    if ($mode -eq 'Trunk') { return 'Trunk:' + $vl.NativeVlanId + '/' + $vl.AllowedVlanIdListString }
    return $mode
}

function Get-HviVm {
    param($Vm, $Kvp)
    $r = [ordered]@{ name = (Protect-HviText ([string]$Vm.Name)); state = [string]$Vm.State; generation = $Vm.Generation; version = [string]$Vm.Version
        vcpu = $Vm.ProcessorCount; memStartupGB = (Get-HviGB $Vm.MemoryStartup); memAssignedGB = (Get-HviGB $Vm.MemoryAssigned)
        dynamicMemory = [bool]$Vm.DynamicMemoryEnabled; uptimeDays = [Math]::Round($Vm.Uptime.TotalDays, 1); autoStart = [string]$Vm.AutomaticStartAction
        notes = (Protect-HviText ([string]$Vm.Notes) -Max 100); guest = $null }
    Invoke-HviStep $r 'disks' -AsList {
        foreach ($d in @(Get-VMHardDiskDrive -VM $Vm)) {
            if (-not $d.Path) { [ordered]@{ name = 'passthrough'; maxGB = $null; fileGB = $null; type = 'PhysicalDisk' }; continue }
            $vhd = Get-VHD -Path $d.Path -ErrorAction SilentlyContinue
            $row = [ordered]@{ name = (Protect-HviText (Split-Path -Path ([string]$d.Path) -Leaf)); maxGB = $null; fileGB = $null; type = $null }
            if ($vhd) { $row.maxGB = Get-HviGB $vhd.Size; $row.fileGB = Get-HviGB $vhd.FileSize; $row.type = [string]$vhd.VhdType }
            $row
        }
    }
    Invoke-HviStep $r 'nics' -AsList {
        foreach ($n in @(Get-VMNetworkAdapter -VM $Vm)) {
            [ordered]@{ switch = [string]$n.SwitchName; mac = [string]$n.MacAddress; vlan = (Get-HviVlan $n); ips = @($n.IPAddresses | ForEach-Object { [string]$_ }) }
        }
    }
    if ($Kvp -is [hashtable]) { if ($Kvp.ContainsKey([string]$Vm.Id)) { $r.guest = $Kvp[[string]$Vm.Id] } } else { $r.guest = $Kvp }
    Invoke-HviStep $r 'integration' -AsList { Get-VMIntegrationService -VM $Vm | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Name + ':' + $_.PrimaryStatusDescription } }
    return $r
}

function Get-HviDhcp {
    $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $svc) { return [ordered]@{ state = 'notInstalled'; scopes = $null; leases = $null } }
    $r = [ordered]@{ state = [string]$svc.Status; scopes = $null; leases = $null }
    try {
        $scopes = @(Get-DhcpServerv4Scope)
        $r.scopes = $scopes.Count
        $r.leases = 0
        foreach ($s in $scopes) { $r.leases += @(Get-DhcpServerv4Lease -ScopeId $s.ScopeId).Count }
    } catch { $r.error = (Get-HviError $_).error }
    return $r
}

function Find-HviLargestArray {
    param($Value, $Skip)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count -gt 0 -and -not [object]::ReferenceEquals($item, $Skip) -and ($null -eq $best -or $item.Count -gt $best.Count)) { $best = @{ Container = $Value; Key = $k; Count = $item.Count } }
            $inner = Find-HviLargestArray $item $Skip
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) {
            $inner = Find-HviLargestArray $item $Skip
            if ($inner -and ($null -eq $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    }
    return $best
}

# Moves VMs to the next page until the line fits; a single VM that still does not fit loses list entries.
function ConvertTo-HviJson {
    param($Report)
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:HviMaxBytes -and @($Report.vms).Count -gt 1) {
        $Report.vms = @($Report.vms | Select-Object -First (@($Report.vms).Count - 1))
        $Report.nextOffset = $Report.offset + @($Report.vms).Count
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:HviMaxBytes) {
        $Report.truncated = $true
        $largest = Find-HviLargestArray $Report $Report.vms
        if (-not $largest) { throw 'Report metadata exceeds the output budget.' }
        $keep = $largest.Count - [Math]::Max(1, [int][Math]::Ceiling($largest.Count / 8))
        $largest.Container[$largest.Key] = @($largest.Container[$largest.Key] | Select-Object -First $keep)
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

function Invoke-HyperVInventory {
    param([string]$Offset = '0')
    $ErrorActionPreference = 'Stop'
    $start = 0; [void][int]::TryParse($Offset, [ref]$start); $start = [Math]::Max(0, $start)
    $report = [ordered]@{ version = '1'; timestamp = [datetime]::UtcNow.ToString('o'); status = 'collected' }
    if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
        $report.status = 'hyperVAbsent'
        $report.message = 'The Hyper-V PowerShell module is not installed, so this is not a Hyper-V host (or the management tools are missing).'
        Invoke-HviStep $report 'host' { Get-HviHost }
        return ConvertTo-HviJson $report
    }
    if ($start -eq 0) { Invoke-HviStep $report 'host' { Get-HviHost } }
    $all = @(Get-VM | Sort-Object -Property Name)
    $page = @($all | Select-Object -Skip $start -First $script:HviPageSize)
    $kvp = $null
    try { $kvp = Get-HviKvp } catch { $kvp = Get-HviError $_ }
    $report.vmCount = $all.Count
    $report.offset = $start
    $report.nextOffset = $null
    if ($start + $page.Count -lt $all.Count) { $report.nextOffset = $start + $page.Count }
    $report.vms = @($page | ForEach-Object { Get-HviVm $_ $kvp })
    if ($start -eq 0) {
        Invoke-HviStep $report 'switches' -AsList { Get-VMSwitch | ForEach-Object { [ordered]@{ name = [string]$_.Name; type = [string]$_.SwitchType; nic = [string]$_.NetAdapterInterfaceDescription; allowManagementOS = [bool]$_.AllowManagementOS } } }
        Invoke-HviStep $report 'hostNics' -AsList { Get-NetAdapter | ForEach-Object { [ordered]@{ name = [string]$_.Name; description = [string]$_.InterfaceDescription; status = [string]$_.Status; linkSpeed = [string]$_.LinkSpeed } } }
        Invoke-HviStep $report 'ipv4' -AsList { Get-NetIPAddress -AddressFamily IPv4 | Where-Object { [string]$_.InterfaceAlias -notlike 'Loopback*' } | ForEach-Object { [ordered]@{ alias = [string]$_.InterfaceAlias; ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin } } }
        Invoke-HviStep $report 'dhcp' { Get-HviDhcp }
    }
    $report.truncated = $false
    return ConvertTo-HviJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
try { Write-Output (Invoke-HyperVInventory -Offset $Offset); exit 0 }
catch { Write-Output ([ordered]@{ status = 'failed'; error = $_.Exception.GetType().Name; message = (Protect-HviText ([string]$_.Exception.Message) -Max 300) } | ConvertTo-Json -Compress); exit 1 }
