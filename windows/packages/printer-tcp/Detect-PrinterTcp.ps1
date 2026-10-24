# Intune runs this file with no arguments.
# Exit 0 only when the queue name, the address, and that model's driver are all present.
# A leftover placeholder is not installed. Intune needs the success line on stdout.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PrinterName = '__PRINTER_NAME__'
$script:PrinterAddress = '__PRINTER_ADDRESS__'
$script:PrinterModel = '__PRINTER_MODEL__'

function Get-RelianPrinterTcpField {
    param(
        $Object,
        [string[]]$Names
    )
    if ($null -eq $Object) {
        return ''
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($Object.Contains($name)) {
                return [string]$Object[$name]
            }
        }
        return ''
    }
    $props = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($props -contains $name) {
            return [string]$Object.$name
        }
    }
    return ''
}

function Get-RelianPrinterTcpDriverName {
    param([string]$ModelId)
    # Model ids are exact, the same way the package looks them up.
    if ($ModelId -ceq 'BrotherHlL2370Dw') {
        return 'Brother HL-L2370DW series'
    }
    if ($ModelId -ceq 'KonicaUniversalPcl') {
        return 'KONICA MINOLTA Universal PCL'
    }
    return ''
}

function Get-RelianPrinterTcpHost {
    param($Printer)
    # A non-blank host wins. Otherwise the port name IP_<address> is the host.
    # That is the same order the package uses for a live queue.
    $hostAddress = [string](Get-RelianPrinterTcpField -Object $Printer -Names @('HostAddress', 'hostAddress', 'PrinterHostAddress'))
    if (-not [string]::IsNullOrWhiteSpace($hostAddress)) {
        return $hostAddress.Trim()
    }
    $portName = [string](Get-RelianPrinterTcpField -Object $Printer -Names @('PortName', 'portName'))
    if ($portName.StartsWith('IP_')) {
        return $portName.Substring(3)
    }
    return ''
}

function Test-RelianPrinterTcpTokenLeft {
    param([string]$Value)
    return [regex]::IsMatch($Value, '__[A-Z0-9_]+__')
}

function Test-RelianPrinterTcpInstalled {
    param(
        $Printers,
        [string]$PrinterName,
        [string]$PrinterAddress,
        [string]$PrinterModel
    )
    $driverName = Get-RelianPrinterTcpDriverName -ModelId $PrinterModel
    if ([string]::IsNullOrWhiteSpace($driverName)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($PrinterName) -or [string]::IsNullOrWhiteSpace($PrinterAddress)) {
        return $false
    }
    foreach ($printer in @($Printers)) {
        if ($null -eq $printer) {
            continue
        }
        $name = [string](Get-RelianPrinterTcpField -Object $printer -Names @('Name', 'name'))
        if (-not [string]::Equals($name, $PrinterName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $driver = [string](Get-RelianPrinterTcpField -Object $printer -Names @('DriverName', 'driverName'))
        if (-not [string]::Equals($driver, $driverName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $liveHost = Get-RelianPrinterTcpHost -Printer $printer
        return [string]::Equals($liveHost, $PrinterAddress, [System.StringComparison]::Ordinal)
    }
    return $false
}

function Get-RelianPrinterTcpLivePrinters {
    # Get-Printer is the live queue list. Do not add, change, or remove a queue.
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to query printers while a test is running'
    }
    if (-not (Get-Command -Name 'Get-Printer' -ErrorAction SilentlyContinue)) {
        return ,@()
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($printer in @(Get-Printer -ErrorAction Stop)) {
        if ($null -eq $printer) {
            continue
        }
        $list.Add([pscustomobject]@{
                Name       = [string]$printer.Name
                DriverName = [string]$printer.DriverName
                PortName   = [string]$printer.PortName
            })
    }
    return ,$list.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

if ((Test-RelianPrinterTcpTokenLeft -Value $script:PrinterName) -or
    (Test-RelianPrinterTcpTokenLeft -Value $script:PrinterAddress) -or
    (Test-RelianPrinterTcpTokenLeft -Value $script:PrinterModel)) {
    exit 1
}

$present = $false
try {
    $present = [bool](Test-RelianPrinterTcpInstalled -Printers @(Get-RelianPrinterTcpLivePrinters) -PrinterName $script:PrinterName -PrinterAddress $script:PrinterAddress -PrinterModel $script:PrinterModel)
} catch {
    $present = $false
}
if ($present) {
    Write-Output 'Relian TCP printer __PRINTER_NAME__'
    exit 0
}
exit 1
