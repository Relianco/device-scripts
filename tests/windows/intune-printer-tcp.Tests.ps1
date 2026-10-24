$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/printer-tcp'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-PrinterTcp.ps1'
$setupPath = Join-Path $packageDir 'Invoke-PrinterTcp.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Test-IntuneTextHasIpv4 {
    param([string]$Text)
    $found = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($match in @($found)) {
        if ($null -eq $match) {
            continue
        }
        $parts = $match.Value.Split('.')
        $valid = $true
        foreach ($part in $parts) {
            $number = 0
            $parsed = [int]::TryParse([string]$part, [ref]$number)
            $leadingZero = $part.Length -gt 1 -and $part.StartsWith('0')
            if (-not $parsed -or $leadingZero -or $number -lt 0 -or $number -gt 255) {
                $valid = $false
                break
            }
        }
        if ($valid) {
            return $true
        }
    }
    return $false
}

foreach ($path in @($jsonPath, $detectPath, $setupPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing $path"
    }
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$meta = $jsonText | ConvertFrom-Json
foreach ($field in @(
        'displayName',
        'publisher',
        'setupFile',
        'installCommand',
        'uninstallCommand',
        'detectionScript',
        'detectReplace'
    )) {
    if ($meta.PSObject.Properties.Name -notcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian TCP printer __PRINTER_NAME__') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-PrinterTcp.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-PrinterTcp.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.detectionScript)))) {
    Fail 'detectionScript is not next to intune.json'
}

$tokens = @('__PRINTER_NAME__', '__PRINTER_ADDRESS__', '__PRINTER_MODEL__')
$replace = @($meta.detectReplace)
if ($replace.Count -ne $tokens.Count) {
    Fail 'detectReplace count'
}
for ($i = 0; $i -lt $tokens.Count; $i++) {
    if ([string]$replace[$i] -cne $tokens[$i]) {
        Fail "detectReplace[$i] '$($replace[$i])'"
    }
    if ($tokens[$i] -notmatch '^__[A-Z0-9_]+__$') {
        Fail "token shape $($tokens[$i])"
    }
}

$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrinterTcp.ps1 -DeploymentType Install -Action Install -PinVersion pinned -PrinterName "{env:RELIAN_PRINTER_NAME}" -PrinterAddress "{env:RELIAN_PRINTER_ADDRESS}" -PrinterModel "{env:RELIAN_PRINTER_MODEL}"'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrinterTcp.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion pinned -PrinterName "{env:RELIAN_PRINTER_NAME}" -PrinterAddress "{env:RELIAN_PRINTER_ADDRESS}" -PrinterModel "{env:RELIAN_PRINTER_MODEL}"'
$install = [string]$meta.installCommand
$uninstall = [string]$meta.uninstallCommand
if ($install -cne $expectedInstall) {
    Fail "installCommand '$install'"
}
if ($uninstall -cne $expectedUninstall) {
    Fail "uninstallCommand '$uninstall'"
}
foreach ($command in @($install, $uninstall)) {
    if (-not $command.Contains('powershell.exe')) {
        Fail 'command does not use powershell.exe'
    }
    if ($command.Contains('pwsh')) {
        Fail 'command uses pwsh'
    }
    if (-not $command.Contains('-PinVersion pinned')) {
        Fail 'command pin is not pinned'
    }
    foreach ($piece in @(
            '{env:RELIAN_PRINTER_NAME}',
            '{env:RELIAN_PRINTER_ADDRESS}',
            '{env:RELIAN_PRINTER_MODEL}',
            '-PrinterName',
            '-PrinterAddress',
            '-PrinterModel'
        )) {
        if (-not $command.Contains($piece)) {
            Fail "command is missing $piece"
        }
    }
}
if (-not $install.Contains('-Action Install') -or -not $install.Contains('-DeploymentType Install')) {
    Fail 'install command action'
}
if (-not $uninstall.Contains('-Action Uninstall') -or -not $uninstall.Contains('-DeploymentType Uninstall')) {
    Fail 'uninstall command action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
foreach ($token in $tokens) {
    if (-not $detectText.Contains($token)) {
        Fail "detection script is missing $token"
    }
}
foreach ($line in @(
        '$script:PrinterName = ''__PRINTER_NAME__''',
        '$script:PrinterAddress = ''__PRINTER_ADDRESS__''',
        '$script:PrinterModel = ''__PRINTER_MODEL__'''
    )) {
    if (-not $detectText.Contains($line)) {
        Fail "detection script is missing $line"
    }
}
if ($detectText.Contains('Invoke-PrinterTcp.ps1')) {
    Fail 'detection script names the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Add-Printer') -or $detectText.Contains('Set-Printer') -or $detectText.Contains('Remove-Printer')) {
    Fail 'detection script changes a printer'
}
if (-not $detectText.Contains('Get-Printer')) {
    Fail 'detection script does not list printers with Get-Printer'
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf('exit ', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$successLine = "Write-Output 'Relian TCP printer __PRINTER_NAME__'"
$successAt = $detectText.IndexOf($successLine, [System.StringComparison]::Ordinal)
$successExit = $detectText.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successAt -lt 0 -or $successExit -lt $successAt) {
    Fail 'success line is missing'
}
if (([regex]::Matches($detectText, 'Write-Output')).Count -ne 1) {
    Fail 'detection script writes more than the success line'
}
$afterSuccess = $detectText.Substring($successExit)
if ($afterSuccess.Contains('Write-Output') -or $afterSuccess.Contains('Write-Error') -or $afterSuccess.Contains('[Console]::Error')) {
    Fail 'detection failure path writes output'
}

$sampleAddress = (@(192, 0, 2, 10) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
$homeMarker = '/' + 'home' + '/'
foreach ($file in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-PrinterTcp.ps1' },
        @{ Text = $testText; Label = 'intune-printer-tcp.Tests.ps1' }
    )) {
    if (Test-IntuneTextHasIpv4 -Text $file.Text) {
        Fail "$($file.Label) contains an IPv4 address"
    }
    if ($file.Text.Contains($homeMarker)) {
        Fail "$($file.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-RelianPrinterTcpInstalled -ErrorAction SilentlyContinue)) {
    Fail 'Test-RelianPrinterTcpInstalled was not defined'
}

function New-PrinterTcpDetectPrinter {
    param(
        [string]$Name,
        [string]$DriverName,
        [string]$HostAddress = '',
        [string]$PortName = ''
    )
    return [pscustomobject]@{
        Name        = $Name
        DriverName  = $DriverName
        HostAddress = $HostAddress
        PortName    = $PortName
    }
}

$queueName = 'Front Desk'
$queueAddress = (@(192, 0, 2, 10) -join '.')
$otherAddress = (@(192, 0, 2, 11) -join '.')
$brotherDriver = 'Brother HL-L2370DW series'
$konicaDriver = 'KONICA MINOLTA Universal PCL'

$brother = New-PrinterTcpDetectPrinter -Name $queueName -DriverName $brotherDriver -HostAddress $queueAddress
if (-not (Test-RelianPrinterTcpInstalled -Printers @($brother) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'BrotherHlL2370Dw')) {
    Fail 'BrotherHlL2370Dw with matching name, address, and driver was absent'
}

$brotherCase = New-PrinterTcpDetectPrinter -Name $queueName.ToLowerInvariant() -DriverName $brotherDriver.ToLowerInvariant() -HostAddress $queueAddress
if (-not (Test-RelianPrinterTcpInstalled -Printers @($brotherCase) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'BrotherHlL2370Dw')) {
    Fail 'queue name comparison was not ordinal ignore case'
}

$brotherPort = New-PrinterTcpDetectPrinter -Name $queueName -DriverName $brotherDriver -PortName ('IP_' + $queueAddress)
if (-not (Test-RelianPrinterTcpInstalled -Printers @($brotherPort) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'BrotherHlL2370Dw')) {
    Fail 'IP_ port address was absent'
}

$konica = New-PrinterTcpDetectPrinter -Name $queueName -DriverName $konicaDriver -HostAddress $queueAddress
if (-not (Test-RelianPrinterTcpInstalled -Printers @($konica) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'KonicaUniversalPcl')) {
    Fail 'KonicaUniversalPcl with KONICA MINOLTA Universal PCL was absent'
}

$wrongDriver = New-PrinterTcpDetectPrinter -Name $queueName -DriverName 'Other Driver' -HostAddress $queueAddress
if (Test-RelianPrinterTcpInstalled -Printers @($wrongDriver) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'BrotherHlL2370Dw') {
    Fail 'a different driver for that model was present'
}

$wrongAddress = New-PrinterTcpDetectPrinter -Name $queueName -DriverName $brotherDriver -HostAddress $otherAddress
if (Test-RelianPrinterTcpInstalled -Printers @($wrongAddress) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'BrotherHlL2370Dw') {
    Fail 'a different address was present'
}

$unknown = New-PrinterTcpDetectPrinter -Name $queueName -DriverName $brotherDriver -HostAddress $queueAddress
if (Test-RelianPrinterTcpInstalled -Printers @($unknown) -PrinterName $queueName -PrinterAddress $queueAddress -PrinterModel 'OtherModel') {
    Fail 'an unknown model was present'
}
