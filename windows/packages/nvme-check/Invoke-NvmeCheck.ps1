<#
.SYNOPSIS
    Read-only NVMe health check for the Relian deploy runner (NinjaOne script 374).
.DESCRIPTION
    Reports each physical disk (model, firmware version, health), the NVMe and
    storage drivers in use, recent disk and storage errors, unexpected shutdowns
    and bug checks from the last 30 days, and the minidump files present. It
    changes nothing, installs nothing and never reboots.
    The result is one line of compact JSON, printed last on stdout.
    Requirements: Windows PowerShell 5.1+, run as SYSTEM.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$disks = @(Get-PhysicalDisk | ForEach-Object {
    [pscustomobject]@{
        model = $_.FriendlyName; firmware = $_.FirmwareVersion; bus = "$($_.BusType)"
        health = "$($_.HealthStatus)"; op = "$($_.OperationalStatus)"; sizeGB = [math]::Round($_.Size / 1GB)
    }
})

$drivers = @(Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $_.DeviceClass -in 'SCSIADAPTER', 'DISKDRIVE', 'HDC' -or $_.DeviceName -match 'NVM|Storage|RST|VMD' } |
    ForEach-Object {
        [pscustomobject]@{
            name = $_.DeviceName; provider = $_.DriverProviderName; version = $_.DriverVersion
            date = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null }
        }
    })

$since = (Get-Date).AddDays(-30)
$events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; StartTime = $since
        ProviderName = 'disk', 'stornvme', 'storahci', 'Microsoft-Windows-Ntfs', 'Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-WER-SystemErrorReporting', 'volmgr'
    } -MaxEvents 400 | Where-Object { $_.Level -le 3 -or $_.Id -in 41, 1001 } |
    Group-Object ProviderName, Id | ForEach-Object {
        $f = $_.Group[0]
        [pscustomobject]@{
            provider = $f.ProviderName; id = $f.Id; count = $_.Count
            last = $_.Group[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')
            msg = ($f.Message -replace '\s+', ' ').Substring(0, [math]::Min(160, $f.Message.Length))
        }
    })

$dumps = @(Get-ChildItem C:\Windows\Minidump\*.dmp, C:\Windows\MEMORY.DMP | ForEach-Object { "$($_.Name) $($_.LastWriteTime.ToString('yyyy-MM-dd'))" })

$result = [pscustomobject]@{
    host = $env:COMPUTERNAME; disks = $disks; drivers = $drivers; events = $events; dumps = $dumps
}
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
exit 0
