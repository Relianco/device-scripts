<#
.SYNOPSIS
    Relian Storage Health Collector
    Collects SMART data, SSD wear levels, and storage health details.

.DESCRIPTION
    Gathers detailed storage health data via CIM/WMI:
    Per-drive model, serial, interface, media type, SMART status,
    SSD wear level, temperature, power-on hours, partition layout.
    Writes JSON results to the relian_storage_health NinjaOne custom field.

.NOTES
    Requirements: Windows PowerShell 5.1+
    Duration: <10 seconds
    No external module dependencies — uses CIM/WMI only
    Version: 1.0
#>

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

# Get volume/partition details mapped by disk number
function Get-PartitionLayout {
    $layout = @{}

    try {
        $partitions = Get-CimInstance -ClassName Win32_DiskPartition -ErrorAction Stop
        $logicalDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        $partToDisk = Get-CimInstance -ClassName Win32_DiskDriveToDiskPartition -ErrorAction Stop
        $logicalToPartition = Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction Stop

        foreach ($disk in $partToDisk) {
            $diskIndex = if ($disk.Antecedent -match 'DeviceID="([^"]+)"') { $Matches[1] } else { $null }
            $partId = if ($disk.Dependent -match 'DeviceID="([^"]+)"') { $Matches[1] } else { $null }
            if (-not $diskIndex -or -not $partId) { continue }

            $diskNum = if ($diskIndex -match '(\d+)$') { $Matches[1] } else { $diskIndex }

            # Find logical disk(s) for this partition
            foreach ($ltop in $logicalToPartition) {
                $ltopPartId = if ($ltop.Antecedent -match 'DeviceID="([^"]+)"') { $Matches[1] } else { $null }
                $logicalId = if ($ltop.Dependent -match 'DeviceID="([^"]+)"') { $Matches[1] } else { $null }
                if ($ltopPartId -ne $partId -or -not $logicalId) { continue }

                $logDisk = $logicalDisks | Where-Object { $_.DeviceID -eq $logicalId } | Select-Object -First 1
                if (-not $logDisk) { continue }

                $capGB = [math]::Round($logDisk.Size / 1GB, 1)
                $freeGB = [math]::Round($logDisk.FreeSpace / 1GB, 1)

                if (-not $layout.ContainsKey($diskNum)) {
                    $layout[$diskNum] = @()
                }

                $layout[$diskNum] += @{
                    letter     = $logicalId
                    fileSystem = $logDisk.FileSystem
                    capacityGB = $capGB
                    freeGB     = $freeGB
                }
            }
        }
    } catch {
        Write-Status "Partition layout query failed: $_" "WARN"
    }

    return $layout
}

# Get storage reliability counters (SSD wear, temp, power-on hours)
function Get-ReliabilityData {
    $reliabilityMap = @{}

    try {
        $physDisks = Get-PhysicalDisk -ErrorAction Stop
        foreach ($pd in $physDisks) {
            $counter = $null
            try {
                $counter = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction Stop
            } catch {
                # Not available for this drive (VM, USB, older OS)
            }

            $key = "$($pd.DeviceId)"

            $reliabilityMap[$key] = @{
                mediaType       = $pd.MediaType
                healthStatus    = $pd.HealthStatus
                wearPercent     = $null
                temperatureC    = $null
                powerOnHours    = $null
                readErrorsTotal = $null
                writeErrorsTotal = $null
                friendlyName    = $pd.FriendlyName
                serialNumber    = ($pd.SerialNumber -replace '\s+', ' ').Trim()
            }

            if ($counter) {
                if ($null -ne $counter.Wear) {
                    $reliabilityMap[$key].wearPercent = [int]$counter.Wear
                }
                if ($null -ne $counter.Temperature) {
                    $reliabilityMap[$key].temperatureC = [int]$counter.Temperature
                }
                if ($null -ne $counter.PowerOnHours) {
                    $reliabilityMap[$key].powerOnHours = [int]$counter.PowerOnHours
                }
                if ($null -ne $counter.ReadErrorsTotal) {
                    $reliabilityMap[$key].readErrorsTotal = [long]$counter.ReadErrorsTotal
                }
                if ($null -ne $counter.WriteErrorsTotal) {
                    $reliabilityMap[$key].writeErrorsTotal = [long]$counter.WriteErrorsTotal
                }
            }
        }
    } catch {
        Write-Status "Storage reliability query failed (may be unsupported on this OS): $_" "WARN"
    }

    return $reliabilityMap
}

# Main
try {
    Write-Status "Relian Storage Health v1.0 starting"

    $disks = Get-SafeCimInstance -ClassName Win32_DiskDrive
    $partitionLayout = Get-PartitionLayout
    $reliabilityData = Get-ReliabilityData

    $driveList = @()
    $healthyCount = 0
    $totalDrives = 0

    if ($disks) {
        foreach ($disk in $disks) {
            $totalDrives++

            # Detect interface
            $interface = "Unknown"
            if ($disk.InterfaceType) {
                $interface = $disk.InterfaceType
            }
            if ($disk.Model -match 'NVMe' -or $disk.PNPDeviceID -match 'NVME') {
                $interface = "NVMe"
            }

            # Detect media type from WMI
            $mediaType = "Unknown"
            if ($disk.MediaType -match 'Fixed') {
                $mediaType = "Unknown" # WMI just says "Fixed hard disk media"
            }

            # SMART status from WMI
            $smartStatus = "Unknown"
            try {
                $smartData = Get-CimInstance -Namespace "root\wmi" -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop |
                    Where-Object { $_.InstanceName -match [regex]::Escape($disk.PNPDeviceID.Replace('\', '\\')) } |
                    Select-Object -First 1
                if ($smartData) {
                    $smartStatus = if ($smartData.PredictFailure) { "Warning" } else { "OK" }
                }
            } catch {
                # SMART not available
            }

            # Get capacity and free space from partitions
            $diskNum = if ($disk.DeviceID -match '(\d+)$') { $Matches[1] } else { "0" }
            $partitions = $partitionLayout[$diskNum]
            $capacityGB = [math]::Round($disk.Size / 1GB, 1)
            $freeGB = 0
            $partList = @()

            if ($partitions) {
                foreach ($part in $partitions) {
                    $freeGB += $part.freeGB
                    $partList += $part
                }
            }

            $usagePercent = if ($capacityGB -gt 0) { [math]::Round((($capacityGB - $freeGB) / $capacityGB) * 100) } else { 0 }

            # Merge reliability data (match by serial or friendly name)
            $wearPercent = $null
            $temperatureC = $null
            $powerOnHours = $null
            $readErrors = $null
            $writeErrors = $null
            $reliMediaType = $null

            foreach ($relKey in $reliabilityData.Keys) {
                $rel = $reliabilityData[$relKey]
                $diskSerial = ($disk.SerialNumber -replace '\s+', ' ').Trim()
                if (($rel.serialNumber -and $diskSerial -and $rel.serialNumber -eq $diskSerial) -or
                    ($rel.friendlyName -and $disk.Model -and $rel.friendlyName -match [regex]::Escape($disk.Model))) {
                    $wearPercent = $rel.wearPercent
                    $temperatureC = $rel.temperatureC
                    $powerOnHours = $rel.powerOnHours
                    $readErrors = $rel.readErrorsTotal
                    $writeErrors = $rel.writeErrorsTotal

                    if ($rel.healthStatus -and $rel.healthStatus -ne "Unknown") {
                        if ($rel.healthStatus -eq "Healthy") { $smartStatus = "OK" }
                        elseif ($rel.healthStatus -eq "Warning") { $smartStatus = "Warning" }
                        elseif ($rel.healthStatus -match 'Unhealthy|Degraded') { $smartStatus = "Critical" }
                    }

                    # Get media type from PhysicalDisk (more reliable than WMI)
                    $reliMediaType = $rel.mediaType
                    break
                }
            }

            # Resolve media type
            if ($reliMediaType) {
                if ($reliMediaType -eq 4 -or $reliMediaType -match 'SSD') { $mediaType = "SSD" }
                elseif ($reliMediaType -eq 3 -or $reliMediaType -match 'HDD') { $mediaType = "HDD" }
                elseif ($reliMediaType -eq 0 -or $reliMediaType -match 'Unspecified') { $mediaType = "Unknown" }
                else { $mediaType = [string]$reliMediaType }
            }
            # Fallback: NVMe drives are always SSD
            if ($interface -eq "NVMe" -and $mediaType -eq "Unknown") { $mediaType = "SSD" }

            if ($smartStatus -eq "OK") { $healthyCount++ }

            $driveEntry = @{
                model        = ($disk.Model -replace '\s+', ' ').Trim()
                serial       = ($disk.SerialNumber -replace '\s+', ' ').Trim()
                interface    = $interface
                mediaType    = $mediaType
                capacityGB   = $capacityGB
                freeGB       = $freeGB
                usagePercent = $usagePercent
                smartStatus  = $smartStatus
                wearPercent  = $wearPercent
                temperatureC = $temperatureC
                powerOnHours = $powerOnHours
                partitions   = $partList
            }

            # Only include error counts if available
            if ($null -ne $readErrors) { $driveEntry.readErrors = $readErrors }
            if ($null -ne $writeErrors) { $driveEntry.writeErrors = $writeErrors }

            $driveList += $driveEntry
        }
    }

    $result = @{
        drives         = $driveList
        totalDrives    = $totalDrives
        healthySummary = "$healthyCount/$totalDrives healthy"
        timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        version        = "1.0"
    }

    $json = $result | ConvertTo-Json -Depth 4 -Compress
    Write-Status "Storage health collected: $($json.Length) bytes, $totalDrives drives"

    # Write to NinjaOne custom field
    try {
        Ninja-Property-Set relian_storage_health $json
        Write-Status "Storage health written to relian_storage_health custom field"
    } catch {
        Write-Status "Could not write to custom field: $_" "WARN"
        Write-Host "STORAGE_HEALTH_RESULT:$json"
    }

    Write-Status "Storage health collection complete"

} catch {
    Write-Status "Storage health error: $_" "ERROR"
    Write-Status $_.ScriptStackTrace "ERROR"
    exit 1
}
