$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/hyperv-inventory/Invoke-HyperVInventory.ps1'
Assert (Test-Path -LiteralPath $path) 'script exists'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, uses no syntax newer than Windows PowerShell 5.1, and changes nothing on a VM or the host.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
foreach ($c in $commands) {
    Assert ($c -notmatch '^(Set|New|Remove|Start|Stop|Restart|Suspend|Resume|Save|Checkpoint|Export|Import|Move|Rename|Copy|Restore|Add|Enable|Disable|Update|Clear|Mount|Dismount|Optimize|Resize|Convert|Merge|Repair|Invoke-Cim)-') "read-only: no $c"
}
$text = Get-Content -Raw -LiteralPath $path
Assert ($text -notmatch 'RequestStateChange|Get-NetNeighbor|192\\\.168|10\\\.\d') 'no state change call and no client-specific neighbour regex'

# No Hyper-V module, simulated so a test host with Hyper-V gives the same answer.
function Get-Command { $null }
function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
    switch ($ClassName) {
        'Win32_ComputerSystem' { [pscustomobject]@{ Manufacturer = 'Contoso'; Model = 'Model X1'; TotalPhysicalMemory = 64GB; NumberOfLogicalProcessors = 16 } }
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Microsoft Windows Server 2019 Standard'; Version = '10.0.17763'; FreePhysicalMemory = 8MB } }
        'Msvm_KvpExchangeComponent' { $script:Kvp }
    }
}
$absent = Invoke-HyperVInventory | ConvertFrom-Json
Assert ($absent.status -eq 'hyperVAbsent' -and $absent.message -match 'Hyper-V') 'absent module reported'
Assert ($absent.host.model -eq 'Model X1' -and $absent.host.ramGB -eq 64 -and $absent.host.freeRamGB -eq 8 -and $absent.host.logicalProcessors -eq 16) 'host on absent'
Remove-Item -LiteralPath Function:\Get-Command

# Mocked Hyper-V host.
function New-Kvp($Pairs) { @($Pairs.Keys | ForEach-Object { "<INSTANCE CLASSNAME=""Msvm_KvpExchangeDataItem""><PROPERTY NAME=""Data"" TYPE=""string""><VALUE>$($Pairs[$_])</VALUE></PROPERTY><PROPERTY NAME=""Name"" TYPE=""string""><VALUE>$_</VALUE></PROPERTY></INSTANCE>" }) }
function New-Vm($Name, $Id, $Notes = '') {
    [pscustomobject]@{ Name = $Name; Id = [guid]$Id; VMId = [guid]$Id; State = 'Running'; Generation = 2; Version = '9.0'; ProcessorCount = 4
        MemoryStartup = 8GB; MemoryAssigned = 6GB; DynamicMemoryEnabled = $true; Uptime = [timespan]::FromHours(36); AutomaticStartAction = 'StartIfRunning'; Notes = $Notes }
}
$id1 = '11111111-1111-1111-1111-111111111111'; $id2 = '22222222-2222-2222-2222-222222222222'
$script:Vms = @((New-Vm 'DC01' $id1 ('n' * 500)), (New-Vm 'APP01' $id2))
$script:Kvp = @([pscustomobject]@{ SystemName = $id1; GuestIntrinsicExchangeItems = (New-Kvp ([ordered]@{ OSName = 'Windows Server 2019 Standard'; OSVersion = '10.0.17763'; FullyQualifiedDomainName = 'dc01.example.com'; ProcessorArchitecture = '9' })) })
function Get-VM { $script:Vms }
function Get-VMHardDiskDrive { param($VM) [pscustomobject]@{ Path = "D:\VMs\$($VM.Name).vhdx" } }
function Get-VHD { param($Path, $ErrorAction) [pscustomobject]@{ Size = 100GB; FileSize = 40GB; VhdType = 'Dynamic' } }
function Get-VMNetworkAdapter { param($VM) [pscustomobject]@{ Name = 'Network Adapter'; SwitchName = 'External'; MacAddress = '00155D000001'; IPAddresses = @('192.0.2.10', 'fe80::1') } }
function Get-VMNetworkAdapterVlan { param($VMNetworkAdapter, $ErrorAction) [pscustomobject]@{ OperationMode = 'Access'; AccessVlanId = 20 } }
function Get-VMIntegrationService { param($VM) @([pscustomobject]@{ Name = 'Heartbeat'; Enabled = $true; PrimaryStatusDescription = 'OK' }, [pscustomobject]@{ Name = 'Guest Service Interface'; Enabled = $false; PrimaryStatusDescription = '' }) }
function Get-VMSwitch { [pscustomobject]@{ Name = 'External'; SwitchType = 'External'; NetAdapterInterfaceDescription = 'Contoso 1GbE #2'; AllowManagementOS = $true } }
function Get-NetAdapter { [pscustomobject]@{ Name = 'Ethernet 2'; InterfaceDescription = 'Contoso 1GbE #2'; Status = 'Up'; LinkSpeed = '1 Gbps' } }
function Get-NetIPAddress { param($AddressFamily) @([pscustomobject]@{ InterfaceAlias = 'vEthernet (External)'; IPAddress = '192.0.2.5'; PrefixLength = 24; PrefixOrigin = 'Manual' }, [pscustomobject]@{ InterfaceAlias = 'Loopback Pseudo-Interface 1'; IPAddress = '127.0.0.1'; PrefixLength = 8; PrefixOrigin = 'WellKnown' }) }
function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'DHCPServer'; Status = 'Running' } }
function Get-DhcpServerv4Scope { param($ErrorAction) @([pscustomobject]@{ ScopeId = '192.0.2.0'; State = 'Active' }, [pscustomobject]@{ ScopeId = '198.51.100.0'; State = 'Inactive' }) }
function Get-DhcpServerv4Lease { param($ScopeId, $ErrorAction) if ($ScopeId -eq '192.0.2.0') { 1..3 | ForEach-Object { [pscustomobject]@{ IPAddress = "192.0.2.$_" } } } }

$r = Invoke-HyperVInventory | ConvertFrom-Json
Assert ($r.status -eq 'collected' -and $r.vmCount -eq 2 -and $r.offset -eq 0 -and $null -eq $r.nextOffset -and -not $r.truncated) 'status and paging'
Assert ($r.host.model -eq 'Model X1' -and $r.host.os -match '2019') 'host'
$v = @($r.vms | Where-Object { $_.name -eq 'DC01' })[0]
Assert ($r.vms[0].name -eq 'APP01') 'VMs sorted by name'
Assert ($v.name -eq 'DC01' -and $v.state -eq 'Running' -and $v.generation -eq 2 -and $v.version -eq '9.0' -and $v.vcpu -eq 4) 'vm basics'
Assert ($v.memStartupGB -eq 8 -and $v.memAssignedGB -eq 6 -and $v.dynamicMemory -and $v.uptimeDays -eq 1.5 -and $v.autoStart -eq 'StartIfRunning') 'vm memory and start'
Assert ($v.notes.Length -le 110 -and $v.notes -match 'clipped') 'notes truncated'
Assert ($v.disks[0].name -eq 'DC01.vhdx' -and $v.disks[0].maxGB -eq 100 -and $v.disks[0].fileGB -eq 40 -and $v.disks[0].type -eq 'Dynamic') 'disks'
Assert ($v.nics[0].switch -eq 'External' -and $v.nics[0].mac -eq '00155D000001' -and $v.nics[0].vlan -eq 'Access:20' -and ($v.nics[0].ips -join ',') -eq '192.0.2.10,fe80::1') 'vm nics'
Assert ($v.guest.OSName -match '2019' -and $v.guest.OSVersion -eq '10.0.17763' -and $v.guest.FullyQualifiedDomainName -eq 'dc01.example.com' -and -not $v.guest.PSObject.Properties['ProcessorArchitecture']) 'guest kvp'
Assert (@($v.integration).Count -eq 1 -and $v.integration[0] -eq 'Heartbeat:OK') 'enabled integration services only'
Assert ($null -eq $r.vms[0].guest) 'no kvp, no guest'
Assert ($r.switches[0].name -eq 'External' -and $r.switches[0].type -eq 'External' -and $r.switches[0].allowManagementOS) 'switches'
Assert ($r.hostNics[0].linkSpeed -eq '1 Gbps') 'host nics'
Assert (@($r.ipv4).Count -eq 1 -and $r.ipv4[0].ip -eq '192.0.2.5' -and $r.ipv4[0].prefix -eq 24) 'ipv4 without loopback'
Assert ($r.dhcp.state -eq 'Running' -and $r.dhcp.scopes -eq 2 -and $r.dhcp.leases -eq 3) 'dhcp counts'

# A failing source is reported, not fatal.
function Get-VMSwitch { throw [InvalidOperationException]::new('switch query failed') }
$r = Invoke-HyperVInventory | ConvertFrom-Json
Assert ($r.status -eq 'collected' -and $r.switches.status -eq 'unavailable' -and $r.switches.error -eq 'InvalidOperationException') 'failure isolated'

# No DHCP role.
function Get-Service { param($Name, $ErrorAction) $null }
$r = Invoke-HyperVInventory | ConvertFrom-Json
Assert ($r.dhcp.state -eq 'notInstalled' -and $null -eq $r.dhcp.scopes) 'dhcp absent'

# Many big VMs: one line under 8,000 UTF-8 bytes, paged by Offset, every VM reached once.
$script:Vms = @(1..40 | ForEach-Object { New-Vm ('VM{0:D2}-' -f $_ + ('é' * 30)) ([guid]::NewGuid()) ('note ' * 40) })
function Get-VMHardDiskDrive { param($VM) 1..4 | ForEach-Object { [pscustomobject]@{ Path = "D:\VMs\$($VM.Name)-disk$_.vhdx" } } }
$seen = @(); $offset = '0'; $pages = 0
do {
    $json = Invoke-HyperVInventory -Offset $offset
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000) "page under cap ($offset)"
    $p = $json | ConvertFrom-Json
    Assert ($p.vmCount -eq 40 -and $p.offset -eq [int]$offset -and @($p.vms).Count -ge 1) "page shape ($offset)"
    if ($pages -gt 0) { Assert ($null -eq $p.PSObject.Properties['switches'] -and $null -eq $p.PSObject.Properties['host']) 'host sections only on the first page' }
    $seen += @($p.vms | ForEach-Object { $_.name })
    $offset = [string]$p.nextOffset; $pages++
} while ($p.nextOffset -and $pages -lt 50)
Assert ($pages -gt 1 -and $seen.Count -eq 40 -and @($seen | Select-Object -Unique).Count -eq 40) 'paging covers every VM once'

# One VM too large for a page on its own: inner lists are trimmed and flagged.
$script:Vms = @(New-Vm 'BIG' ([guid]::NewGuid()))
function Get-VMHardDiskDrive { param($VM) 1..300 | ForEach-Object { [pscustomobject]@{ Path = "D:\VMs\big-disk-$_.vhdx" } } }
$json = Invoke-HyperVInventory
$big = $json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and $big.truncated -and @($big.vms).Count -eq 1 -and $null -eq $big.nextOffset) 'single big VM trimmed, not paged away'

# End to end without Hyper-V (simulated in the child too): the script exits 0 with one JSON line.
Remove-Item Env:\RELIAN_DEPLOY_TEST
$out = & pwsh -NoProfile -Command ('function Get-Command { $null }; & ''' + ($path -replace "'", "''") + "' -Action Install; exit `$LASTEXITCODE")
Assert ($LASTEXITCODE -eq 0 -and (@($out).Count -eq 1) -and (($out | ConvertFrom-Json).status -eq 'hyperVAbsent')) 'clean exit without Hyper-V'
'hyperv-inventory tests passed'
