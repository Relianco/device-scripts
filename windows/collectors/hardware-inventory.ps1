<#
.SYNOPSIS
    Relian Hardware Inventory Collector
    Collects detailed hardware specs and prints one JSON object.

.DESCRIPTION
    Gathers comprehensive hardware data via WMI/CIM queries:
    CPU, Memory DIMMs, Storage, Motherboard, GPU, Network, Battery.
    Prints one compressed JSON object on the success stream.
    Pass -Section to collect a subset. Omitted or empty means every section.
    A section that was not requested is null.

.PARAMETER Section
    Cpu, Memory, Storage, Motherboard, Gpu, Network, or Battery.
    A value may be repeated. One element may be a comma-separated list.

.NOTES
    Requirements: Windows PowerShell 5.1+
    Duration: <15 seconds
    No external module dependencies — uses WMI/CIM only
    Version: 1.0
#>

# Script parameters are not Mandatory: a mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string[]]$Section
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

function Get-SafeCimInstance {
    param([string]$ClassName, [string]$Namespace = "root\cimv2")
    try {
        return Get-CimInstance -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop
    } catch {
        Write-Status "CIM query for $ClassName failed: $_" "WARN"
        return $null
    }
}

# CPU details
function Get-CpuDetails {
    $cpus = Get-SafeCimInstance -ClassName Win32_Processor
    if (-not $cpus) { return $null }

    $cpu = $cpus | Select-Object -First 1

    $cacheL1 = $null
    $cacheL2 = $null
    $cacheL3 = $null

    $caches = Get-SafeCimInstance -ClassName Win32_CacheMemory
    if ($caches) {
        foreach ($cache in $caches) {
            switch ($cache.Level) {
                3 { if (-not $cacheL1) { $cacheL1 = [int]$cache.MaxCacheSize } }
                4 { if (-not $cacheL2) { $cacheL2 = [int]$cache.MaxCacheSize } }
                5 { if (-not $cacheL3) { $cacheL3 = [int]$cache.MaxCacheSize } }
            }
        }
    }

    return @{
        model        = ($cpu.Name -replace '\s+', ' ').Trim()
        cores        = [int]$cpu.NumberOfCores
        threads      = [int]$cpu.NumberOfLogicalProcessors
        baseClock    = [int]$cpu.MaxClockSpeed
        stepping     = $cpu.Stepping
        revision     = $cpu.Revision
        cacheL1KB    = $cacheL1
        cacheL2KB    = $cacheL2
        cacheL3KB    = $cacheL3
        architecture = $env:PROCESSOR_ARCHITECTURE
        socketDesignation = $cpu.SocketDesignation
    }
}

# Memory DIMMs
function Get-MemoryDetails {
    $dimms = Get-SafeCimInstance -ClassName Win32_PhysicalMemory
    $slots = Get-SafeCimInstance -ClassName Win32_PhysicalMemoryArray

    $dimmList = @()
    if ($dimms) {
        foreach ($dimm in $dimms) {
            $memType = switch ([int]$dimm.SMBIOSMemoryType) {
                20 { "DDR" }
                21 { "DDR2" }
                24 { "DDR3" }
                26 { "DDR4" }
                34 { "DDR5" }
                default { "Unknown ($($dimm.SMBIOSMemoryType))" }
            }

            $dimmList += @{
                capacityGB   = [math]::Round($dimm.Capacity / 1GB, 1)
                speedMHz     = [int]$dimm.ConfiguredClockSpeed
                type         = $memType
                manufacturer = ($dimm.Manufacturer -replace '\s+', ' ').Trim()
                partNumber   = ($dimm.PartNumber -replace '\s+', ' ').Trim()
                slot         = $dimm.DeviceLocator
                formFactor   = $dimm.FormFactor
            }
        }
    }

    $totalSlots = 0
    if ($slots) {
        foreach ($s in $slots) {
            $totalSlots += [int]$s.MemoryDevices
        }
    }

    return @{
        dimms       = $dimmList
        slotsUsed   = $dimmList.Count
        slotsTotal  = $totalSlots
        totalGB     = [math]::Round(($dimmList | ForEach-Object { $_.capacityGB } | Measure-Object -Sum).Sum, 1)
    }
}

# Storage drives
function Get-StorageDetails {
    $disks = Get-SafeCimInstance -ClassName Win32_DiskDrive
    $driveList = @()

    if ($disks) {
        foreach ($disk in $disks) {
            $interface = "Unknown"
            if ($disk.InterfaceType) {
                $interface = $disk.InterfaceType
            }
            # Detect NVMe
            if ($disk.Model -match 'NVMe' -or $disk.PNPDeviceID -match 'NVME') {
                $interface = "NVMe"
            }

            $smartStatus = "Unknown"
            try {
                $smartData = Get-CimInstance -Namespace "root\wmi" -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop |
                    Where-Object { $_.InstanceName -match [regex]::Escape($disk.PNPDeviceID.Replace('\', '\\')) } |
                    Select-Object -First 1
                if ($smartData) {
                    $smartStatus = if ($smartData.PredictFailure) { "Warning" } else { "Healthy" }
                }
            } catch {
                # SMART not available for this drive
            }

            $driveList += @{
                model        = ($disk.Model -replace '\s+', ' ').Trim()
                serialNumber = ($disk.SerialNumber -replace '\s+', ' ').Trim()
                capacityGB   = [math]::Round($disk.Size / 1GB, 1)
                interface    = $interface
                mediaType    = $disk.MediaType
                firmware     = $disk.FirmwareRevision
                smartStatus  = $smartStatus
            }
        }
    }

    return $driveList
}

# Motherboard
function Get-MotherboardDetails {
    $board = Get-SafeCimInstance -ClassName Win32_BaseBoard | Select-Object -First 1
    $bios = Get-SafeCimInstance -ClassName Win32_BIOS | Select-Object -First 1

    if (-not $board -and -not $bios) { return $null }

    return @{
        manufacturer  = if ($board) { ($board.Manufacturer -replace '\s+', ' ').Trim() } else { $null }
        model         = if ($board) { ($board.Product -replace '\s+', ' ').Trim() } else { $null }
        biosVersion   = if ($bios) { $bios.SMBIOSBIOSVersion } else { $null }
        biosDate      = if ($bios -and $bios.ReleaseDate) { $bios.ReleaseDate.ToString("yyyy-MM-dd") } else { $null }
        biosVendor    = if ($bios) { ($bios.Manufacturer -replace '\s+', ' ').Trim() } else { $null }
    }
}

# GPU
function Get-GpuDetails {
    $gpus = Get-SafeCimInstance -ClassName Win32_VideoController
    if (-not $gpus) { return @() }

    $gpuList = @()
    foreach ($gpu in $gpus) {
        $vramMB = 0
        if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
            $vramMB = [math]::Round($gpu.AdapterRAM / 1MB)
        }

        $gpuList += @{
            model         = ($gpu.Name -replace '\s+', ' ').Trim()
            vramMB        = $vramMB
            driverVersion = $gpu.DriverVersion
            driverDate    = if ($gpu.DriverDate) { $gpu.DriverDate.ToString("yyyy-MM-dd") } else { $null }
            status        = $gpu.Status
        }
    }

    return $gpuList
}

# Network adapters
function Get-NetworkDetails {
    $adapters = Get-SafeCimInstance -ClassName Win32_NetworkAdapter |
        Where-Object { $_.PhysicalAdapter -eq $true -and $_.NetConnectionID }

    if (-not $adapters) { return @() }

    $adapterList = @()
    foreach ($adapter in $adapters) {
        $adapterType = "Other"
        if ($adapter.Name -match 'Wi-?Fi|Wireless|802\.11') {
            $adapterType = "WiFi"
        } elseif ($adapter.Name -match 'Ethernet|LAN|Realtek|Intel.*I2[0-9]|Broadcom') {
            $adapterType = "Ethernet"
        } elseif ($adapter.Name -match 'Bluetooth') {
            $adapterType = "Bluetooth"
        }

        $speedMbps = 0
        if ($adapter.Speed) {
            $speedMbps = [math]::Round($adapter.Speed / 1000000)
        }

        $adapterList += @{
            name     = $adapter.Name
            type     = $adapterType
            speedMbps = $speedMbps
            macAddress = $adapter.MACAddress
            status    = $adapter.NetConnectionStatus
        }
    }

    return $adapterList
}

# Battery (laptops only)
function Get-BatteryDetails {
    $batteries = Get-SafeCimInstance -ClassName Win32_Battery
    if (-not $batteries) { return $null }

    $battery = $batteries | Select-Object -First 1

    $designCapacity = 0
    $fullChargeCapacity = 0
    $healthPercent = 0

    # Try BatteryStaticData for design capacity
    try {
        $staticData = Get-CimInstance -Namespace "root\wmi" -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
        if ($staticData) {
            $designCapacity = [int]$staticData.DesignedCapacity
        }
    } catch { }

    # Try BatteryFullChargedCapacity
    try {
        $fullData = Get-CimInstance -Namespace "root\wmi" -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
        if ($fullData) {
            $fullChargeCapacity = [int]$fullData.FullChargedCapacity
        }
    } catch { }

    if ($designCapacity -gt 0 -and $fullChargeCapacity -gt 0) {
        $healthPercent = [math]::Round(($fullChargeCapacity / $designCapacity) * 100, 1)
    }

    return @{
        designCapacityMWh     = $designCapacity
        currentCapacityMWh    = $fullChargeCapacity
        healthPercent         = $healthPercent
        status                = $battery.Status
        estimatedChargePercent = [int]$battery.EstimatedChargeRemaining
    }
}

function Get-HardwareSectionSet {
    param([string[]]$Section)

    $allowed = @('Cpu', 'Memory', 'Storage', 'Motherboard', 'Gpu', 'Network', 'Battery')
    $selected = New-Object System.Collections.Generic.List[string]
    $sawToken = $false
    if ($null -ne $Section) {
        foreach ($item in @($Section)) {
            $sawToken = $true
            foreach ($part in ([string]$item).Split(',')) {
                $token = $part.Trim()
                if ($token.Length -eq 0) {
                    throw 'invalid hardware section'
                }
                $canonical = $null
                foreach ($name in $allowed) {
                    if ([string]::Equals($name, $token, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $canonical = $name
                        break
                    }
                }
                if ($null -eq $canonical) {
                    throw 'invalid hardware section'
                }
                if (-not $selected.Contains($canonical)) {
                    [void]$selected.Add($canonical)
                }
            }
        }
    }
    if (-not $sawToken) {
        foreach ($name in $allowed) {
            [void]$selected.Add($name)
        }
    }
    return @($selected.ToArray())
}

function Invoke-HardwareInventory {
    param([string[]]$Section)

    $names = @(Get-HardwareSectionSet -Section $Section)
    $wanted = @{}
    foreach ($name in $names) {
        $wanted[[string]$name] = $true
    }

    Write-Status "Relian Hardware Inventory v1.0 starting"

    $cpu = $null
    $memory = $null
    $storage = $null
    $motherboard = $null
    $gpu = $null
    $network = $null
    $battery = $null

    if ($wanted.ContainsKey('Cpu')) { $cpu = Get-CpuDetails }
    if ($wanted.ContainsKey('Memory')) { $memory = Get-MemoryDetails }
    if ($wanted.ContainsKey('Storage')) { $storage = Get-StorageDetails }
    if ($wanted.ContainsKey('Motherboard')) { $motherboard = Get-MotherboardDetails }
    if ($wanted.ContainsKey('Gpu')) { $gpu = Get-GpuDetails }
    if ($wanted.ContainsKey('Network')) { $network = Get-NetworkDetails }
    if ($wanted.ContainsKey('Battery')) { $battery = Get-BatteryDetails }

    $inventory = @{
        cpu         = $cpu
        memory      = $memory
        storage     = $storage
        motherboard = $motherboard
        gpu         = $gpu
        network     = $network
        battery     = $battery
        timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        version     = "1.0"
    }

    $json = $inventory | ConvertTo-Json -Depth 4 -Compress
    Write-Status "Inventory collected: $($json.Length) bytes"
    Write-Output $json
    Write-Status "Hardware inventory complete"
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    if ($null -eq $Section) {
        Invoke-HardwareInventory
    } else {
        Invoke-HardwareInventory -Section $Section
    }
} catch {
    Write-Status "Inventory error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
