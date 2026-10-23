# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# Driver URLs and hashes are the pin in windows/releases/printer-tcp.json.
# The runner copies this script alone, so the values are inlined.
# The stock runner does not pass a queue name or address. Empty values exit 0.
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$CancelPath = '',
    [string]$MarkerRoot = '',
    [string]$PrinterName = '',
    [string]$PrinterAddress = '',
    [string]$PrinterModel = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Two models are fixed in this script. A release file cannot add a third.
$script:PrinterTcpKonicaReferer = 'https://onyxweb.mykonicaminolta.com/OneStopProductSupport?appMode=Public&target=Drivers'
$script:PrinterTcpModels = @(
    [pscustomobject]@{
        Id           = 'BrotherHlL2370Dw'
        DriverName   = 'Brother HL-L2370DW series'
        SourceUrl    = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2019/08/498d2e8b-35d3-4e32-b214-b33facc5756c_461156f49788809b4b143a833e7b6aeedc2822f1.cab'
        File         = '498d2e8b-35d3-4e32-b214-b33facc5756c_461156f49788809b4b143a833e7b6aeedc2822f1.cab'
        Sha256       = '725cd890e7c7ba08f85b14c86256fad6d7606eb8b582f957eab0659b98b2c0e8'
        Size         = [int64]19139543
        Version      = '1.6.0.0'
        Inf          = 'BROHL17A.INF'
        Catalog      = 'BROHL17A.CAT'
        Stage        = 'Cab'
        Referer      = ''
        OuterSubject = 'Microsoft'
    }
    [pscustomobject]@{
        Id           = 'KonicaUniversalPcl'
        DriverName   = 'KONICA MINOLTA Universal PCL'
        SourceUrl    = 'https://cscsupportftp.mykonicaminolta.com/DownloadFile/Download.ashx?fileversionid=43620&productid=1801'
        File         = 'KM_UPD_pcl6_win64_v391203eit100_WHQL_efigs_ja_sc_tc_ko_inst.exe'
        Sha256       = '30cf9b9bd9a1517ab835efe6200a7aa2b5c4850e58fdffe220297ff0501c6e71'
        Size         = [int64]32858888
        Version      = '3.9.1203.500'
        Inf          = 'KOUWNJ1_.inf'
        Catalog      = 'KOUWNJ1_.CAT'
        Stage        = 'SevenZipSfx'
        Referer      = $script:PrinterTcpKonicaReferer
        OuterSubject = 'KONICA MINOLTA'
    }
)

function Get-PrinterTcpModels {
    return ,$script:PrinterTcpModels
}

function Get-PrinterTcpModel {
    param([string]$Id)
    foreach ($model in $script:PrinterTcpModels) {
        if ($model.Id -ceq $Id) {
            return $model
        }
    }
    return $null
}

function Get-PrinterTcpField {
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

function New-PrinterTcpPlan {
    param(
        $ExitCode = $null,
        [bool]$EnsureDriver = $false,
        [bool]$CreatePort = $false,
        [bool]$CreateQueue = $false,
        [bool]$UpdateQueue = $false,
        [string]$PreviousDriver = '',
        [string]$PreviousPort = '',
        [bool]$RemoveQueue = $false,
        [bool]$RemovePort = $false,
        [string]$RemovePortName = '',
        [bool]$WriteMarker = $false,
        [bool]$ClearMarker = $false
    )
    # ExitCode stays null when the caller still has to perform the plan.
    return [pscustomobject]@{
        ExitCode       = $ExitCode
        EnsureDriver   = $EnsureDriver
        CreatePort     = $CreatePort
        CreateQueue    = $CreateQueue
        UpdateQueue    = $UpdateQueue
        PreviousDriver = $PreviousDriver
        PreviousPort   = $PreviousPort
        RemoveQueue    = $RemoveQueue
        RemovePort     = $RemovePort
        RemovePortName = $RemovePortName
        WriteMarker    = $WriteMarker
        ClearMarker    = $ClearMarker
    }
}

function Test-PrinterTcpQueueName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) {
        return $false
    }
    if ($Name.Length -lt 1 -or $Name.Length -gt 220) {
        return $false
    }
    # A trimmed value that differs is rejected. The name is not rewritten.
    if ($Name.Trim() -cne $Name) {
        return $false
    }
    $forbidden = @(
        [char]9, [char]13, [char]10, [char]'|', [char]'\', [char]'/',
        [char]':', [char]'*', [char]'?', [char]'"', [char]'<', [char]'>'
    )
    foreach ($ch in $Name.ToCharArray()) {
        if ($forbidden -contains $ch) {
            return $false
        }
    }
    return $true
}

function Test-PrinterTcpIpv4 {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }
    # Split on '.' so the address is not parsed as a regex pattern.
    $parts = $Address.Split('.')
    if (@($parts).Count -ne 4) {
        return $false
    }
    foreach ($part in $parts) {
        if (-not [regex]::IsMatch([string]$part, '^(0|[1-9][0-9]{0,2})$')) {
            return $false
        }
        $number = 0
        if (-not [int]::TryParse([string]$part, [ref]$number)) {
            return $false
        }
        if ($number -lt 0 -or $number -gt 255) {
            return $false
        }
    }
    return $true
}

function Test-PrinterTcpUrlHasUserInfo {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        if (-not $uri.IsAbsoluteUri) {
            return $false
        }
        return -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

function Test-PrinterTcpUrlIsHttps {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        if (-not $uri.IsAbsoluteUri) {
            return $false
        }
        return $uri.Scheme -eq 'https'
    } catch {
        return $false
    }
}

function Test-PrinterTcpRemovablePortName {
    param([string]$PortName)
    return $PortName -match '^IP_(\d{1,3}\.){3}\d{1,3}$'
}

function Get-PrinterTcpPortSettings {
    param([string]$Address)
    return [pscustomobject]@{
        Name               = 'IP_' + $Address
        PrinterHostAddress = $Address
        PortNumber         = 9100
        SnmpEnabled        = $false
    }
}

# -1 means the request is valid and the caller should keep going.
# 0 disables the package. 1 rejects the request.
function Get-PrinterTcpValidationCode {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$PrinterName,
        [string]$PrinterAddress,
        [string]$PrinterModel,
        [string]$SourceUrl
    )
    # An empty pin, queue, address, or model disables the package.
    # Do not download or change the marker. A bad pin cannot exit 1 first.
    if ([string]::IsNullOrWhiteSpace($PrinterName) -or
        [string]::IsNullOrWhiteSpace($PrinterAddress) -or
        [string]::IsNullOrWhiteSpace($PrinterModel) -or
        [string]::IsNullOrWhiteSpace($PinVersion)) {
        return 0
    }
    $model = Get-PrinterTcpModel -Id $PrinterModel
    if ($null -eq $model) {
        return 1
    }
    # An empty hash disables every action, including Uninstall and Reinstall.
    # This is before the URL is read, so userinfo cannot exit 1 first.
    if ([string]::IsNullOrWhiteSpace([string]$model.Sha256)) {
        return 0
    }
    if (-not (Test-PrinterTcpQueueName -Name $PrinterName)) {
        return 1
    }
    if (-not (Test-PrinterTcpIpv4 -Address $PrinterAddress)) {
        return 1
    }
    # Uninstall does not download. A userinfo URL does not block it.
    if ($Action -ne 'Uninstall') {
        $url = $SourceUrl
        if ([string]::IsNullOrWhiteSpace($url)) {
            $url = [string]$model.SourceUrl
        }
        if (Test-PrinterTcpUrlHasUserInfo -Url $url) {
            return 1
        }
        if (-not (Test-PrinterTcpUrlIsHttps -Url $url)) {
            return 1
        }
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return 1
    }
    if ($Action -ne 'Install' -and $Action -ne 'Update' -and $Action -ne 'Repair' -and $Action -ne 'Uninstall') {
        return 1
    }
    return -1
}

function Get-PrinterTcpMarkerEntry {
    param($MarkerPrinters, [string]$Name)
    foreach ($entry in @($MarkerPrinters)) {
        if ($null -eq $entry) {
            continue
        }
        $entryName = [string](Get-PrinterTcpField -Object $entry -Names @('Name', 'name'))
        if ([string]::Equals($entryName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }
    return $null
}

function Get-PrinterTcpListedPrinter {
    param($ExistingPrinters, [string]$Name)
    foreach ($printer in @($ExistingPrinters)) {
        if ($null -eq $printer) {
            continue
        }
        $printerName = [string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name'))
        if ([string]::Equals($printerName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $printer
        }
    }
    return $null
}

function Get-PrinterTcpLiveHost {
    param($Printer)
    $hostAddress = [string](Get-PrinterTcpField -Object $Printer -Names @('HostAddress', 'hostAddress', 'PrinterHostAddress'))
    if (-not [string]::IsNullOrWhiteSpace($hostAddress)) {
        return $hostAddress.Trim()
    }
    $portName = [string](Get-PrinterTcpField -Object $Printer -Names @('PortName', 'portName'))
    if ($portName.StartsWith('IP_')) {
        return $portName.Substring(3)
    }
    return ''
}

function Test-PrinterTcpPortExists {
    param($Ports, [string]$PortName)
    foreach ($port in @($Ports)) {
        if ($null -eq $port) {
            continue
        }
        $name = [string](Get-PrinterTcpField -Object $port -Names @('Name', 'name'))
        if ([string]::Equals($name, $PortName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-PrinterTcpPortUsedByOther {
    param($ExistingPrinters, [string]$PrinterName, [string]$PortName)
    foreach ($printer in @($ExistingPrinters)) {
        if ($null -eq $printer) {
            continue
        }
        $name = [string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name'))
        if ([string]::Equals($name, $PrinterName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $port = [string](Get-PrinterTcpField -Object $printer -Names @('PortName', 'portName'))
        if ([string]::Equals($port, $PortName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function ConvertTo-PrinterTcpDriverVersion {
    param($Value)
    if ($null -eq $Value -or $Value -is [version]) {
        return $Value
    }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    if ($text.Contains('.')) {
        try {
            return [version]$text
        } catch {
            return $null
        }
    }
    # Get-PrinterDriver.DriverVersion is a uint64 of four 16-bit fields.
    # Windows PowerShell 5.1 has no helper that decodes it.
    $raw = [uint64]0
    if (-not [uint64]::TryParse($text, [ref]$raw) -or $raw -eq 0) {
        return $null
    }
    $major = [int](($raw -shr 48) -band 0xFFFF)
    $minor = [int](($raw -shr 32) -band 0xFFFF)
    $build = [int](($raw -shr 16) -band 0xFFFF)
    $revision = [int]($raw -band 0xFFFF)
    return [version]::new($major, $minor, $build, $revision)
}

function Format-PrinterTcpDriverVersion {
    param($Value)
    $version = ConvertTo-PrinterTcpDriverVersion -Value $Value
    if ($null -eq $version) {
        return ''
    }
    $build = $version.Build
    $revision = $version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $version.Major, $version.Minor, $build, $revision
}

function Test-PrinterTcpSameDriverVersion {
    param($Installed, [string]$Pinned)
    $left = Format-PrinterTcpDriverVersion -Value $Installed
    $right = Format-PrinterTcpDriverVersion -Value $Pinned
    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) {
        return $false
    }
    return [string]::Equals($left, $right, [System.StringComparison]::Ordinal)
}

function Get-PrinterTcpPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$PrinterName,
        [string]$PrinterAddress,
        [string]$PrinterModel,
        [string]$SourceUrl = '',
        $MarkerPrinters = $null,
        $ExistingPrinters = $null,
        $ExistingPorts = $null,
        [bool]$DriverInstalled = $false,
        $InstalledDriverVersion = ''
    )

    $validation = [int](Get-PrinterTcpValidationCode -Action $Action -PinVersion $PinVersion -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel -SourceUrl $SourceUrl)
    if ($validation -ge 0) {
        return New-PrinterTcpPlan -ExitCode $validation
    }

    $model = Get-PrinterTcpModel -Id $PrinterModel
    $driverName = [string]$model.DriverName
    $portName = 'IP_' + $PrinterAddress
    $entry = Get-PrinterTcpMarkerEntry -MarkerPrinters $MarkerPrinters -Name $PrinterName

    if ($Action -eq 'Uninstall') {
        if ($null -eq $entry) {
            return New-PrinterTcpPlan -ExitCode 0
        }
        $printer = Get-PrinterTcpListedPrinter -ExistingPrinters $ExistingPrinters -Name $PrinterName
        $removeQueue = $null -ne $printer
        # The argument can name a different address than the one this queue installed.
        $recordedAddress = [string](Get-PrinterTcpField -Object $entry -Names @('Address', 'address'))
        $removePortName = ''
        if (Test-PrinterTcpIpv4 -Address $recordedAddress) {
            $recordedPort = 'IP_' + $recordedAddress
            $canRemove = (Test-PrinterTcpRemovablePortName -PortName $recordedPort) -and
                (Test-PrinterTcpPortExists -Ports $ExistingPorts -PortName $recordedPort) -and
                -not (Test-PrinterTcpPortUsedByOther -ExistingPrinters $ExistingPrinters -PrinterName $PrinterName -PortName $recordedPort)
            if ($canRemove) {
                $removePortName = $recordedPort
            }
        }
        return New-PrinterTcpPlan -RemoveQueue $removeQueue -RemovePort (-not [string]::IsNullOrWhiteSpace($removePortName)) -RemovePortName $removePortName -ClearMarker $true
    }

    $printer = Get-PrinterTcpListedPrinter -ExistingPrinters $ExistingPrinters -Name $PrinterName
    # A queue this marker does not list is left alone. Do not call Set-Printer.
    if ($null -ne $printer -and $null -eq $entry) {
        return New-PrinterTcpPlan -ExitCode 1
    }

    $versionMatches = $false
    if ($DriverInstalled) {
        $versionMatches = Test-PrinterTcpSameDriverVersion -Installed $InstalledDriverVersion -Pinned ([string]$model.Version)
    }
    $ensure = -not $versionMatches
    if ($Action -eq 'Repair') {
        $ensure = $true
    }
    $createPort = -not (Test-PrinterTcpPortExists -Ports $ExistingPorts -PortName $portName)
    if (-not $createPort) {
        $existingHost = (Get-PrinterTcpPortHost -Ports $ExistingPorts -PortName $portName).Trim()
        # A known host that is not this address belongs to another queue. Do not reuse the port.
        if (-not [string]::IsNullOrWhiteSpace($existingHost) -and
            -not [string]::Equals($existingHost, $PrinterAddress, [System.StringComparison]::Ordinal)) {
            return New-PrinterTcpPlan -ExitCode 1
        }
    }
    if ($null -eq $printer) {
        return New-PrinterTcpPlan -EnsureDriver $ensure -CreatePort $createPort -CreateQueue $true -WriteMarker $true
    }

    $liveDriver = [string](Get-PrinterTcpField -Object $printer -Names @('DriverName', 'driverName'))
    $livePort = [string](Get-PrinterTcpField -Object $printer -Names @('PortName', 'portName'))
    $liveHost = Get-PrinterTcpLiveHost -Printer $printer
    $driverDiffers = -not [string]::Equals($liveDriver, $driverName, [System.StringComparison]::OrdinalIgnoreCase)
    $addressDiffers = -not [string]::Equals($liveHost, $PrinterAddress, [System.StringComparison]::Ordinal)
    $write = $true
    if ($null -ne $entry) {
        $entryAddress = [string](Get-PrinterTcpField -Object $entry -Names @('Address', 'address'))
        $entryModel = [string](Get-PrinterTcpField -Object $entry -Names @('Model', 'model'))
        if ($entryAddress -ceq $PrinterAddress -and $entryModel -ceq $PrinterModel) {
            $write = $false
        }
    }
    if ($driverDiffers -or $addressDiffers) {
        return New-PrinterTcpPlan -EnsureDriver $ensure -CreatePort $createPort -UpdateQueue $true -PreviousDriver $liveDriver -PreviousPort $livePort -WriteMarker $true
    }
    if (-not $ensure -and -not $createPort -and -not $write) {
        return New-PrinterTcpPlan -ExitCode 0
    }
    return New-PrinterTcpPlan -EnsureDriver $ensure -CreatePort $createPort -WriteMarker $write
}

$script:PrinterTcpErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-PrinterTcpError {
    param([string]$Message)
    if ($null -eq $script:PrinterTcpErrorLog) {
        $script:PrinterTcpErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:PrinterTcpErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Add-PrinterTcpUrlProblem {
    param([string]$ModelId)
    $model = Get-PrinterTcpModel -Id $ModelId
    if ($null -eq $model) {
        return
    }
    $url = [string]$model.SourceUrl
    if (Test-PrinterTcpUrlHasUserInfo -Url $url) {
        Add-PrinterTcpError -Message "refusing a URL that contains userinfo for $($model.Id)"
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($url) -and -not (Test-PrinterTcpUrlIsHttps -Url $url)) {
        Add-PrinterTcpError -Message "refusing a URL that is not https for $($model.Id)"
    }
}

function Test-PrinterTcpCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-PrinterTcpHttpStatus {
    param($Exception)
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        $code = $null
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            try {
                $parsed = [int]$current.StatusCode
                if ($parsed -ge 100 -and $parsed -le 599) {
                    $code = $parsed
                }
            } catch {
                $code = $null
            }
        }
        if ($null -eq $code -and $names -contains 'Response' -and $null -ne $current.Response) {
            $response = $current.Response
            $responseNames = @($response.PSObject.Properties.Name)
            if ($responseNames -contains 'StatusCode' -and $null -ne $response.StatusCode) {
                try {
                    $parsed = [int]$response.StatusCode
                    if ($parsed -ge 100 -and $parsed -le 599) {
                        $code = $parsed
                    }
                } catch {
                    $code = $null
                }
            }
        }
        if ($null -ne $code) {
            return $code
        }
        $current = $current.InnerException
    }
    return $null
}

function Test-PrinterTcpTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    # SocketException() keeps the last native error. Only these connection and DNS codes are retried.
    $socketTransient = @(
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::HostNotFound
    )
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # A bare TaskCanceledException is cancellation. A timeout is a TimeoutException, including one nested inside it.
        if ($current -is [System.TimeoutException]) {
            return $true
        }
        if ($current -is [System.Net.Sockets.SocketException] -and $socketTransient -contains $current.SocketErrorCode) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and $webTransient -contains [string]$current.Status) {
            return $true
        }
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'HttpRequestError' -and $null -ne $current.HttpRequestError -and $requestTransient -contains [string]$current.HttpRequestError) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-PrinterTcpDownloadIsTransient {
    param($ErrorRecord)
    $exception = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [System.Exception]) {
        $exception = $ErrorRecord
    }
    if ($null -eq $exception) {
        return $false
    }
    $status = Get-PrinterTcpHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-PrinterTcpTransientTransport -Exception $exception)
}

function Save-PrinterTcpPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath = '',
        [string]$Referer = ''
    )

    # An empty hash downloads nothing, even when the URL contains userinfo.
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-PrinterTcpUrlHasUserInfo -Url $Url) {
        Add-PrinterTcpError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if (-not (Test-PrinterTcpUrlIsHttps -Url $Url)) {
        Add-PrinterTcpError -Message "refusing a URL that is not https for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-PrinterTcpCancelled -CancelPath $CancelPath) {
            return 130
        }
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination -Referer $Referer)
        } catch {
            $thrown = $_
        }
        $exists = Test-Path -LiteralPath $Destination
        if ($null -eq $thrown -and $exists) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
            if (-not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Add-PrinterTcpError -Message "hash mismatch for $Label"
                return 1
            }
            return 0
        }
        if ($exists) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        $status = $null
        $transient = $false
        if ($null -ne $thrown) {
            $status = Get-PrinterTcpHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-PrinterTcpDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-PrinterTcpError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-PrinterTcpError -Message "download wrote no file for $Label"
            } else {
                Add-PrinterTcpError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-PrinterTcpCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-PrinterTcpCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-PrinterTcpError -Message "download failed for $Label"
    return 1
}

function Get-PrinterTcpDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\printer-tcp'
}

function Get-PrinterTcpMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.json'
}

function ConvertTo-PrinterTcpJsonString {
    param([string]$Text)
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Read-PrinterTcpMarkerPrinters {
    param([string]$Root)
    $empty = [pscustomobject]@{ Ok = $true; Printers = @() }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $empty
    }
    $path = Get-PrinterTcpMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return $empty
    }
    try {
        $text = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $empty
        }
        $parsed = $text | ConvertFrom-Json
        $raw = $null
        if ($null -ne $parsed -and @($parsed.PSObject.Properties.Name) -contains 'printers') {
            $raw = $parsed.printers
        }
        $clean = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $raw) {
            foreach ($item in @($raw)) {
                if ($null -eq $item) {
                    continue
                }
                $clean.Add($item)
            }
        }
        return [pscustomobject]@{ Ok = $true; Printers = $clean.ToArray() }
    } catch {
        return [pscustomobject]@{ Ok = $false; Printers = @() }
    }
}

function Write-PrinterTcpMarkerPrinters {
    param(
        [string]$Root,
        $Printers
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-PrinterTcpMarkerPath -Root $Root
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($printer in @($Printers)) {
        if ($null -eq $printer) {
            continue
        }
        $name = ConvertTo-PrinterTcpJsonString -Text ([string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name')))
        $address = ConvertTo-PrinterTcpJsonString -Text ([string](Get-PrinterTcpField -Object $printer -Names @('Address', 'address')))
        $modelId = ConvertTo-PrinterTcpJsonString -Text ([string](Get-PrinterTcpField -Object $printer -Names @('Model', 'model')))
        $items.Add(('{"name":"' + $name + '","address":"' + $address + '","model":"' + $modelId + '"}'))
    }
    if ($items.Count -eq 0) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
        return
    }
    $json = '{"printers":[' + ($items -join ',') + ']}'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8)
}

function Write-PrinterTcpMarkerName {
    param(
        [string]$Root,
        [string]$Name,
        [string]$Address,
        [string]$Model
    )
    $read = Read-PrinterTcpMarkerPrinters -Root $Root
    if (-not $read.Ok) {
        throw 'could not read the printer marker'
    }
    $next = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($printer in @($read.Printers)) {
        if ($null -eq $printer) {
            continue
        }
        $existing = [string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name'))
        if ([string]::Equals($existing, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $next.Add([pscustomobject]@{ name = $Name; address = $Address; model = $Model })
            $replaced = $true
            continue
        }
        $next.Add($printer)
    }
    if (-not $replaced) {
        $next.Add([pscustomobject]@{ name = $Name; address = $Address; model = $Model })
    }
    Write-PrinterTcpMarkerPrinters -Root $Root -Printers $next.ToArray()
}

function Remove-PrinterTcpMarkerName {
    param(
        [string]$Root,
        [string]$Name
    )
    $read = Read-PrinterTcpMarkerPrinters -Root $Root
    if (-not $read.Ok) {
        throw 'could not read the printer marker'
    }
    $next = [System.Collections.Generic.List[object]]::new()
    foreach ($printer in @($read.Printers)) {
        if ($null -eq $printer) {
            continue
        }
        $existing = [string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name'))
        if ([string]::Equals($existing, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $next.Add($printer)
    }
    Write-PrinterTcpMarkerPrinters -Root $Root -Printers $next.ToArray()
}

# Return one array object. Callers assign it and count with @($fields).Count.
function Split-PrinterTcpQuotedFields {
    param([string]$Text)
    $fields = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false
    if ($null -eq $Text) {
        $Text = ''
    }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '"') {
            if ($inQuote -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                [void]$current.Append('"')
                $i++
                continue
            }
            $inQuote = -not $inQuote
            continue
        }
        if ($ch -eq ',' -and -not $inQuote) {
            $fields.Add($current.ToString().Trim())
            [void]$current.Clear()
            continue
        }
        [void]$current.Append($ch)
    }
    $fields.Add($current.ToString().Trim())
    return ,$fields.ToArray()
}

function Remove-PrinterTcpInfComment {
    param([string]$Text)
    $builder = [System.Text.StringBuilder]::new()
    $inQuote = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            [void]$builder.Append($ch)
            continue
        }
        if ($ch -eq ';' -and -not $inQuote) {
            break
        }
        [void]$builder.Append($ch)
    }
    return $builder.ToString()
}

function Get-PrinterTcpInfSections {
    param([string]$Text)
    $sections = @{}
    $current = ''
    if ($null -eq $Text) {
        $Text = ''
    }
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($raw in $normalized.Split("`n")) {
        $line = (Remove-PrinterTcpInfComment -Text $raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $current = $line.Substring(1, $line.Length - 2).Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = [System.Collections.Generic.List[object]]::new()
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($current)) {
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            continue
        }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($key.Length -ge 2 -and $key.StartsWith('"') -and $key.EndsWith('"')) {
            $key = $key.Substring(1, $key.Length - 2)
        }
        $sections[$current].Add([pscustomobject]@{
                Key   = $key
                Value = $value
            })
    }
    return $sections
}

function Get-PrinterTcpInfSectionEntries {
    param($Sections, [string]$BaseName)
    $amd = ($BaseName + '.amd64').ToLowerInvariant()
    $plain = $BaseName.ToLowerInvariant()
    if ($Sections.ContainsKey($amd)) {
        return ,$Sections[$amd].ToArray()
    }
    if ($Sections.ContainsKey($plain)) {
        return ,$Sections[$plain].ToArray()
    }
    return ,@()
}

function Test-PrinterTcpPathSegment {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) {
        return $false
    }
    if ($Segment -eq '.' -or $Segment -eq '..' -or $Segment.Contains('..')) {
        return $false
    }
    $forbidden = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
    foreach ($ch in $forbidden) {
        if ($Segment.Contains($ch)) {
            return $false
        }
    }
    return $true
}

# INF disk paths may start with one slash. That slash is not a path segment.
function Get-PrinterTcpInfSubdirectory {
    param([string]$Raw)
    $text = $Raw.Trim()
    if ($text.StartsWith('\\') -or $text.StartsWith('//')) {
        return $text
    }
    if ($text.StartsWith('\') -or $text.StartsWith('/')) {
        $text = $text.Substring(1)
    }
    return $text.Trim()
}

function Get-PrinterTcpCompressedLeaf {
    param([string]$FileName)
    if ([string]::IsNullOrEmpty($FileName)) {
        return ''
    }
    return $FileName.Substring(0, $FileName.Length - 1) + '_'
}

function Resolve-PrinterTcpDriverFile {
    param(
        [string]$Directory,
        [string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) {
        return ''
    }
    $compressed = Get-PrinterTcpCompressedLeaf -FileName $FileName
    $direct = Join-Path $Directory $FileName
    if (Test-Path -LiteralPath $direct) {
        return $direct
    }
    if ($compressed -cne $FileName) {
        $alt = Join-Path $Directory $compressed
        if (Test-Path -LiteralPath $alt) {
            return $alt
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue)) {
        if ([string]::Equals($file.Name, $FileName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $file.FullName
        }
        if ([string]::Equals($file.Name, $compressed, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $file.FullName
        }
    }
    return ''
}

function Move-PrinterTcpOneDriverFile {
    param(
        [string]$Root,
        [string]$FileName,
        [string]$Subdirectory
    )
    if ([string]::IsNullOrWhiteSpace($Subdirectory)) {
        $beside = Resolve-PrinterTcpDriverFile -Directory $Root -FileName $FileName
        return -not [string]::IsNullOrWhiteSpace($beside)
    }
    if (-not (Test-PrinterTcpPathSegment -Segment $Subdirectory)) {
        return $false
    }
    $destDir = Join-Path $Root $Subdirectory
    $existing = Resolve-PrinterTcpDriverFile -Directory $destDir -FileName $FileName
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        return $true
    }
    $source = Resolve-PrinterTcpDriverFile -Directory $Root -FileName $FileName
    if ([string]::IsNullOrWhiteSpace($source)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $dest = Join-Path $destDir (Split-Path -Leaf $source)
    if (Test-Path -LiteralPath $dest) {
        return $true
    }
    try {
        [System.IO.File]::Move($source, $dest)
    } catch {
        return $false
    }
    return $true
}

function Invoke-PrinterTcpInfLayout {
    param([string]$InfPath)
    if ([string]::IsNullOrWhiteSpace($InfPath) -or -not (Test-Path -LiteralPath $InfPath)) {
        return $false
    }
    $text = [System.IO.File]::ReadAllText($InfPath)
    $sections = Get-PrinterTcpInfSections -Text $text
    $names = Get-PrinterTcpInfSectionEntries -Sections $sections -BaseName 'SourceDisksNames'
    $files = Get-PrinterTcpInfSectionEntries -Sections $sections -BaseName 'SourceDisksFiles'
    $diskSubdir = @{}
    foreach ($entry in @($names)) {
        if ($null -eq $entry) {
            continue
        }
        $fields = Split-PrinterTcpQuotedFields -Text ([string]$entry.Value)
        $subdir = ''
        if (@($fields).Count -ge 4) {
            $subdir = Get-PrinterTcpInfSubdirectory -Raw ([string]$fields[3])
        }
        $diskSubdir[[string]$entry.Key] = $subdir
    }
    $root = Split-Path -Parent $InfPath
    foreach ($entry in @($files)) {
        if ($null -eq $entry) {
            continue
        }
        $fileName = [string]$entry.Key
        if (-not (Test-PrinterTcpPathSegment -Segment $fileName)) {
            return $false
        }
        $fields = Split-PrinterTcpQuotedFields -Text ([string]$entry.Value)
        $diskId = ''
        if (@($fields).Count -ge 1) {
            $diskId = [string]$fields[0]
        }
        $subdir = ''
        if ($diskSubdir.ContainsKey($diskId)) {
            $subdir = [string]$diskSubdir[$diskId]
        }
        if (-not (Move-PrinterTcpOneDriverFile -Root $root -FileName $fileName -Subdirectory $subdir)) {
            return $false
        }
    }
    return $true
}

function Test-PrinterTcpCatalogSignature {
    param(
        [string]$Status,
        [string]$Subject,
        [string[]]$ChainStatus = @(),
        [bool]$HasTimestamp = $false
    )
    if ($Status -ceq 'Valid') {
        return $true
    }
    # SignatureStatus has no NotTimeValid member. Expiration is a chain flag.
    # Only an untimestamped WHQL catalog may pass when that is the chain's only failure.
    if ($HasTimestamp) {
        return $false
    }
    if ($Status -cne 'UnknownError' -and $Status -cne 'NotTrusted') {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Subject) -or -not $Subject.Contains('Microsoft Windows Hardware Compatibility Publisher')) {
        return $false
    }
    $sawExpired = $false
    foreach ($flag in @($ChainStatus)) {
        if ([string]::IsNullOrWhiteSpace($flag)) {
            continue
        }
        if ($flag -ceq 'NotTimeNested') {
            continue
        }
        if ($flag -ceq 'NotTimeValid') {
            $sawExpired = $true
            continue
        }
        return $false
    }
    return $sawExpired
}

function Test-PrinterTcpOuterSignature {
    param(
        [string]$ModelId,
        [string]$Status,
        [string]$Subject
    )
    # The outer cab or exe does not have to be the WHQL publisher.
    if ($Status -cne 'Valid') {
        return $false
    }
    $model = Get-PrinterTcpModel -Id $ModelId
    if ($null -eq $model) {
        return $false
    }
    $need = [string]$model.OuterSubject
    if ([string]::IsNullOrWhiteSpace($need)) {
        return $false
    }
    return $Subject.Contains($need)
}

function Test-PrinterTcpExcludedDriverPath {
    param([string]$Path)
    $normalized = $Path.Replace('\', '/')
    foreach ($segment in $normalized.Split('/')) {
        if ([string]::Equals($segment, 'FAX', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ([string]::Equals($segment, 'V4', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ([string]::Equals($segment, 'WebView2', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-PrinterTcpWin64Path {
    param([string]$Path)
    return $Path.Replace('\', '/').IndexOf('Win_x64', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Find-PrinterTcpDriverInf {
    param(
        [string]$Root,
        [string]$InfName
    )
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ''
    }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        if (-not [string]::Equals($file.Name, $InfName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        # Do not install FAX, V4, or WebView2.
        if (Test-PrinterTcpExcludedDriverPath -Path $file.FullName) {
            continue
        }
        $found.Add($file.FullName)
    }
    if ($found.Count -eq 0) {
        return ''
    }
    foreach ($path in $found) {
        if (Test-PrinterTcpWin64Path -Path $path) {
            return $path
        }
    }
    return [string]$found[0]
}

function Find-PrinterTcpCatalogFile {
    param(
        [string]$InfPath,
        [string]$CatalogName
    )
    $dir = Split-Path -Parent $InfPath
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) {
        return ''
    }
    $direct = Join-Path $dir $CatalogName
    if (Test-Path -LiteralPath $direct) {
        return $direct
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        if ([string]::Equals($file.Name, $CatalogName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $file.FullName
        }
    }
    return ''
}

function Get-PrinterTcpQuotedArgument {
    param([string]$Value)
    # Start-Process joins ArgumentList with spaces. Quotes keep one path as one argument.
    return '"{0}"' -f $Value
}

function Get-PrinterTcpPnpUtilArgumentList {
    param([string]$InfPath)
    if ([string]::IsNullOrWhiteSpace($InfPath)) {
        return $null
    }
    if (Test-PrinterTcpExcludedDriverPath -Path $InfPath) {
        return $null
    }
    # add-driver only. Do not pass the switch that installs device nodes.
    return @('/add-driver', (Get-PrinterTcpQuotedArgument -Value $InfPath))
}

function Get-PrinterTcpExpandArgumentList {
    param(
        [string]$CabPath,
        [string]$Destination
    )
    if ([string]::IsNullOrWhiteSpace($CabPath) -or [string]::IsNullOrWhiteSpace($Destination)) {
        return $null
    }
    return @(
        '-F:*',
        (Get-PrinterTcpQuotedArgument -Value $CabPath),
        (Get-PrinterTcpQuotedArgument -Value $Destination)
    )
}

function Find-PrinterTcpStagedInf {
    param(
        [string]$Root,
        [string]$InfName
    )
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($InfName)) {
        return ''
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        return ''
    }
    # Windows PowerShell 5.1 has no EnumerationOptions. SilentlyContinue skips a directory the search cannot read.
    $newestPath = ''
    $newestTime = [datetime]::MinValue
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        if (-not [string]::Equals($file.Name, $InfName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $when = $file.LastWriteTimeUtc
        if ([string]::IsNullOrEmpty($newestPath) -or $when -gt $newestTime) {
            $newestPath = [string]$file.FullName
            $newestTime = $when
        }
    }
    return $newestPath
}

function Get-PrinterTcpSfxArgumentList {
    param([string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return $null
    }
    # -o and the directory are one argument. There is no space after -o.
    $target = $Directory
    if ($Directory.Contains(' ')) {
        $target = '"' + $Directory + '"'
    }
    return @('-y', ('-o' + $target))
}

function Get-PrinterTcpChainStatusNames {
    param($Certificate)
    if ($null -eq $Certificate) {
        return @()
    }
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    [void]$chain.Build($Certificate)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($chain.ChainStatus)) {
        if ($null -eq $entry) {
            continue
        }
        $text = [string]$entry.Status
        if ([string]::IsNullOrWhiteSpace($text) -or $text -ceq 'NoError') {
            continue
        }
        foreach ($part in $text.Split(',')) {
            $name = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $names.Contains($name)) {
                $names.Add($name)
            }
        }
    }
    return ,$names.ToArray()
}

function Get-PrinterTcpSignatureParts {
    param($Signature)
    $chain = @()
    $hasTimestamp = $false
    if ($null -ne $Signature) {
        $props = @($Signature.PSObject.Properties.Name)
        if ($props -contains 'ChainStatus' -and $null -ne $Signature.ChainStatus) {
            foreach ($flag in @($Signature.ChainStatus)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$flag)) {
                    $chain += [string]$flag
                }
            }
        }
        if ($props -contains 'HasTimestamp') {
            $hasTimestamp = [bool]$Signature.HasTimestamp
        }
    }
    return [pscustomobject]@{
        Status       = [string](Get-PrinterTcpField -Object $Signature -Names @('Status', 'status'))
        Subject      = [string](Get-PrinterTcpField -Object $Signature -Names @('Subject', 'subject'))
        ChainStatus  = $chain
        HasTimestamp = $hasTimestamp
    }
}

$script:DownloadFile = {
    param($Url, $Destination, $Referer)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to download while a test is running'
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        # Windows PowerShell 5.1 needs TLS 1.2. PowerShell 7 already negotiates it.
    }
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($Referer)) {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
        return
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -Headers @{ Referer = $Referer }
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetPrinters = {
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to query printers while a test is running'
    }
    if (-not (Get-Command -Name 'Get-Printer' -ErrorAction SilentlyContinue)) {
        throw 'Get-Printer is not available'
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

$script:GetPrinterPorts = {
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to query printer ports while a test is running'
    }
    if (-not (Get-Command -Name 'Get-PrinterPort' -ErrorAction SilentlyContinue)) {
        throw 'Get-PrinterPort is not available'
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($port in @(Get-PrinterPort -ErrorAction Stop)) {
        if ($null -eq $port) {
            continue
        }
        $hostAddress = [string](Get-PrinterTcpField -Object $port -Names @('PrinterHostAddress', 'HostAddress'))
        $list.Add([pscustomobject]@{
                Name        = [string]$port.Name
                HostAddress = $hostAddress
            })
    }
    return ,$list.ToArray()
}

$script:GetInstalledDriverNames = {
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to query printer drivers while a test is running'
    }
    if (-not (Get-Command -Name 'Get-PrinterDriver' -ErrorAction SilentlyContinue)) {
        throw 'Get-PrinterDriver is not available'
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($driver in @(Get-PrinterDriver -ErrorAction Stop)) {
        if ($null -eq $driver) {
            continue
        }
        $version = $null
        $props = @($driver.PSObject.Properties.Name)
        if ($props -contains 'DriverVersion') {
            $version = $driver.DriverVersion
        }
        $list.Add([pscustomobject]@{
                Name          = [string]$driver.Name
                DriverVersion = $version
            })
    }
    return ,$list.ToArray()
}

function Disable-PrinterTcpPortSnmp {
    param([string]$Name)
    $escaped = $Name.Replace("'", "''")
    $filter = "Name='$escaped'"
    $port = Get-CimInstance -ClassName 'Win32_TCPIPPrinterPort' -Filter $filter
    if ($null -eq $port) {
        throw 'tcp printer port was not created'
    }
    # Turn SNMP off without restarting the Print Spooler.
    Set-CimInstance -InputObject $port -Property @{ SNMPEnabled = $false } | Out-Null
}

$script:AddPrinterPort = {
    param($Name, $PrinterHostAddress, $PortNumber, $SnmpEnabled)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to add a printer port while a test is running'
    }
    # Do not pass an SNMP index. That parameter enables SNMP.
    Add-PrinterPort -Name $Name -PrinterHostAddress $PrinterHostAddress -PortNumber ([uint32]$PortNumber)
    if ($SnmpEnabled) {
        return
    }
    try {
        Disable-PrinterTcpPortSnmp -Name $Name
    } catch {
        Remove-PrinterPort -Name $Name -ErrorAction SilentlyContinue
        throw
    }
}

$script:AddPrinter = {
    param($Name, $DriverName, $PortName)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to add a printer while a test is running'
    }
    # The queue is not set as the default printer.
    Add-Printer -Name $Name -DriverName $DriverName -PortName $PortName
}

$script:AddPrinterDriver = {
    param($Name, $InfPath)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to add a printer driver while a test is running'
    }
    if (-not (Get-Command -Name 'Add-PrinterDriver' -ErrorAction SilentlyContinue)) {
        throw 'Add-PrinterDriver is not available'
    }
    # InfPath is the copy in the driver store. The extracted INF is not that path.
    Add-PrinterDriver -Name $Name -InfPath $InfPath
    return 0
}

$script:FindStagedInf = {
    param($InfName)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to search the driver store while a test is running'
    }
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $root = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    }
    return Find-PrinterTcpStagedInf -Root $root -InfName ([string]$InfName)
}

$script:SetPrinter = {
    param($Name, $DriverName, $PortName)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to change a printer while a test is running'
    }
    Set-Printer -Name $Name -DriverName $DriverName -PortName $PortName
}

$script:RemovePrinter = {
    param($Name)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to remove a printer while a test is running'
    }
    Remove-Printer -Name $Name
}

$script:RemovePrinterPort = {
    param($Name)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to remove a printer port while a test is running'
    }
    Remove-PrinterPort -Name $Name
}

$script:GetAuthenticodeSignature = {
    param($Path)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to read a signature while a test is running'
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = ''
    $chainStatus = @()
    $hasTimestamp = $false
    if ($null -ne $sig.SignerCertificate) {
        $subject = [string]$sig.SignerCertificate.Subject
        $chainStatus = @(Get-PrinterTcpChainStatusNames -Certificate $sig.SignerCertificate)
    }
    $sigProps = @($sig.PSObject.Properties.Name)
    if ($sigProps -contains 'TimeStamperCertificate' -and $null -ne $sig.TimeStamperCertificate) {
        $hasTimestamp = $true
    }
    return [pscustomobject]@{
        Status       = [string]$sig.Status
        Subject      = $subject
        ChainStatus  = $chainStatus
        HasTimestamp = $hasTimestamp
    }
}

$script:ExpandCab = {
    param($CabPath, $Destination)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to expand a cabinet while a test is running'
    }
    $exe = 'expand.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot 'System32\expand.exe'
    }
    $argumentList = Get-PrinterTcpExpandArgumentList -CabPath $CabPath -Destination $Destination
    if ($null -eq $argumentList) {
        throw 'missing expand arguments'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process -or [int]$process.ExitCode -ne 0) {
        throw 'cabinet expand failed'
    }
}

$script:ExpandSfx = {
    param($ExePath, $Destination)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to expand an sfx while a test is running'
    }
    $argumentList = Get-PrinterTcpSfxArgumentList -Directory $Destination
    if ($null -eq $argumentList) {
        throw 'missing sfx arguments'
    }
    $process = Start-Process -FilePath $ExePath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process -or [int]$process.ExitCode -ne 0) {
        throw 'sfx expand failed'
    }
}

$script:InvokePnpUtil = {
    param($InfPath)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to run pnputil while a test is running'
    }
    $argumentList = Get-PrinterTcpPnpUtilArgumentList -InfPath $InfPath
    if ($null -eq $argumentList) {
        return 1
    }
    $exe = 'pnputil.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

function Invoke-PrinterTcpEnsureDriver {
    param(
        $Model,
        [string]$Cache,
        [string]$CancelPath
    )
    $destination = Join-Path $Cache ([string]$Model.File)
    $saved = [int](Save-PrinterTcpPayload -Url ([string]$Model.SourceUrl) -Destination $destination -Sha256 ([string]$Model.Sha256) -Label ([string]$Model.Id) -CancelPath $CancelPath -Referer ([string]$Model.Referer))
    if ($saved -ne 0) {
        return $saved
    }
    if (Test-PrinterTcpCancelled -CancelPath $CancelPath) {
        return 130
    }
    $outer = Get-PrinterTcpSignatureParts -Signature (& $script:GetAuthenticodeSignature -Path $destination)
    if (-not (Test-PrinterTcpOuterSignature -ModelId ([string]$Model.Id) -Status $outer.Status -Subject $outer.Subject)) {
        Add-PrinterTcpError -Message "outer signature rejected for $($Model.Id)"
        return 1
    }
    $extract = Join-Path $Cache 'extract'
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    if ([string]$Model.Stage -ceq 'Cab') {
        [void](& $script:ExpandCab -CabPath $destination -Destination $extract)
    } elseif ([string]$Model.Stage -ceq 'SevenZipSfx') {
        [void](& $script:ExpandSfx -ExePath $destination -Destination $extract)
    } else {
        Add-PrinterTcpError -Message "unknown stage for $($Model.Id)"
        return 1
    }
    $infPath = Find-PrinterTcpDriverInf -Root $extract -InfName ([string]$Model.Inf)
    if ([string]::IsNullOrWhiteSpace($infPath)) {
        Add-PrinterTcpError -Message "driver inf missing for $($Model.Id)"
        return 1
    }
    # Move files into the INF subdirectory before the catalog check.
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $infPath)) {
        Add-PrinterTcpError -Message "driver file layout failed for $($Model.Id)"
        return 1
    }
    $catalog = Find-PrinterTcpCatalogFile -InfPath $infPath -CatalogName ([string]$Model.Catalog)
    if ([string]::IsNullOrWhiteSpace($catalog)) {
        Add-PrinterTcpError -Message "driver catalog missing for $($Model.Id)"
        return 1
    }
    $catalogSig = Get-PrinterTcpSignatureParts -Signature (& $script:GetAuthenticodeSignature -Path $catalog)
    if (-not (Test-PrinterTcpCatalogSignature -Status $catalogSig.Status -Subject $catalogSig.Subject -ChainStatus @($catalogSig.ChainStatus) -HasTimestamp ([bool]$catalogSig.HasTimestamp))) {
        Add-PrinterTcpError -Message "catalog signature rejected for $($Model.Id)"
        return 1
    }
    $argumentList = Get-PrinterTcpPnpUtilArgumentList -InfPath $infPath
    if ($null -eq $argumentList) {
        Add-PrinterTcpError -Message "driver inf rejected for $($Model.Id)"
        return 1
    }
    $pnp = & $script:InvokePnpUtil -InfPath $infPath
    if ($null -eq $pnp -or [int]$pnp -ne 0) {
        Add-PrinterTcpError -Message "pnputil add-driver failed for $($Model.Id)"
        return 1
    }
    $staged = [string](& $script:FindStagedInf -InfName ([string]$Model.Inf))
    if ([string]::IsNullOrWhiteSpace($staged)) {
        Add-PrinterTcpError -Message "staged driver inf missing for $($Model.Id)"
        return 1
    }
    $added = & $script:AddPrinterDriver -Name ([string]$Model.DriverName) -InfPath $staged
    if ($null -eq $added -or [int]$added -ne 0) {
        Add-PrinterTcpError -Message "add-printer driver failed for $($Model.Id)"
        return 1
    }
    return 0
}

function Get-PrinterTcpPortHost {
    param($Ports, [string]$PortName)
    if ([string]::IsNullOrWhiteSpace($PortName)) {
        return ''
    }
    foreach ($port in @($Ports)) {
        if ($null -eq $port) {
            continue
        }
        $name = [string](Get-PrinterTcpField -Object $port -Names @('Name', 'name'))
        if (-not [string]::Equals($name, $PortName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        return [string](Get-PrinterTcpField -Object $port -Names @('HostAddress', 'hostAddress', 'PrinterHostAddress'))
    }
    return ''
}

function ConvertTo-PrinterTcpPlanPrinters {
    param($Printers, $Ports)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($printer in @($Printers)) {
        if ($null -eq $printer) {
            continue
        }
        $name = [string](Get-PrinterTcpField -Object $printer -Names @('Name', 'name'))
        $driver = [string](Get-PrinterTcpField -Object $printer -Names @('DriverName', 'driverName'))
        $port = [string](Get-PrinterTcpField -Object $printer -Names @('PortName', 'portName'))
        $hostAddress = [string](Get-PrinterTcpField -Object $printer -Names @('HostAddress', 'hostAddress', 'PrinterHostAddress'))
        if ([string]::IsNullOrWhiteSpace($hostAddress)) {
            $hostAddress = Get-PrinterTcpPortHost -Ports $Ports -PortName $port
        }
        $list.Add([pscustomobject]@{
                Name        = $name
                DriverName  = $driver
                PortName    = $port
                HostAddress = $hostAddress
            })
    }
    return ,$list.ToArray()
}

function Invoke-PrinterTcpAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$CancelPath,
        [string]$MarkerRoot,
        [string]$PrinterName,
        [string]$PrinterAddress,
        [string]$PrinterModel
    )

    $validation = [int](Get-PrinterTcpValidationCode -Action $Action -PinVersion $PinVersion -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel -SourceUrl '')
    if ($validation -ge 0) {
        if ($validation -eq 1) {
            Add-PrinterTcpUrlProblem -ModelId $PrinterModel
        }
        return $validation
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-PrinterTcpDefaultMarkerRoot
    }
    $markerRead = Read-PrinterTcpMarkerPrinters -Root $MarkerRoot
    if (-not $markerRead.Ok) {
        Add-PrinterTcpError -Message 'could not read the printer marker'
        return 1
    }

    # Assign the hook result. @() around the call wraps the returned array.
    $livePrinters = & $script:GetPrinters
    $livePorts = & $script:GetPrinterPorts
    $driverNames = & $script:GetInstalledDriverNames
    $model = Get-PrinterTcpModel -Id $PrinterModel
    if ($null -eq $model) {
        return 1
    }
    $driverInstalled = $false
    $installedVersion = $null
    foreach ($driver in @($driverNames)) {
        if ($null -eq $driver) {
            continue
        }
        $name = ''
        $version = $null
        if ($driver -is [string]) {
            $name = [string]$driver
        } else {
            $name = [string](Get-PrinterTcpField -Object $driver -Names @('Name', 'name'))
            $driverProps = @($driver.PSObject.Properties.Name)
            if ($driverProps -contains 'DriverVersion') {
                $version = $driver.DriverVersion
            }
        }
        if ([string]::Equals($name, [string]$model.DriverName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $driverInstalled = $true
            $installedVersion = $version
            break
        }
    }
    $planPrinters = ConvertTo-PrinterTcpPlanPrinters -Printers $livePrinters -Ports $livePorts
    $plan = Get-PrinterTcpPlan -Action $Action -PinVersion $PinVersion -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel -SourceUrl '' -MarkerPrinters $markerRead.Printers -ExistingPrinters $planPrinters -ExistingPorts $livePorts -DriverInstalled $driverInstalled -InstalledDriverVersion $installedVersion
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-PrinterTcpCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    $attemptedUpdate = $false
    $portSettings = Get-PrinterTcpPortSettings -Address $PrinterAddress
    try {
        if ($plan.EnsureDriver) {
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-printer-tcp-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $ensured = [int](Invoke-PrinterTcpEnsureDriver -Model $model -Cache $cache -CancelPath $CancelPath)
            if ($ensured -ne 0) {
                return $ensured
            }
        }
        if ($plan.CreatePort) {
            [void](& $script:AddPrinterPort -Name $portSettings.Name -PrinterHostAddress $portSettings.PrinterHostAddress -PortNumber $portSettings.PortNumber -SnmpEnabled $portSettings.SnmpEnabled)
        }
        if ($plan.RemoveQueue) {
            [void](& $script:RemovePrinter -Name $PrinterName)
        }
        if ($plan.UpdateQueue) {
            $attemptedUpdate = $true
            [void](& $script:SetPrinter -Name $PrinterName -DriverName ([string]$model.DriverName) -PortName $portSettings.Name)
        }
        if ($plan.CreateQueue) {
            [void](& $script:AddPrinter -Name $PrinterName -DriverName ([string]$model.DriverName) -PortName $portSettings.Name)
        }
        if ($plan.RemovePort) {
            [void](& $script:RemovePrinterPort -Name ([string]$plan.RemovePortName))
        }
        if ($plan.ClearMarker) {
            Remove-PrinterTcpMarkerName -Root $MarkerRoot -Name $PrinterName
        } elseif ($plan.WriteMarker) {
            Write-PrinterTcpMarkerName -Root $MarkerRoot -Name $PrinterName -Address $PrinterAddress -Model $PrinterModel
        }
        return 0
    } catch {
        if ($attemptedUpdate) {
            try {
                [void](& $script:SetPrinter -Name $PrinterName -DriverName ([string]$plan.PreviousDriver) -PortName ([string]$plan.PreviousPort))
            } catch {
                Add-PrinterTcpError -Message "could not restore printer $PrinterName"
            }
        }
        $detail = [string]$_.Exception.Message
        if ($detail -match '://') {
            $detail = "printer tcp failed for $PrinterModel"
        }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "printer tcp failed for $PrinterModel"
        }
        Add-PrinterTcpError -Message $detail
        return 1
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($cache)) {
            try {
                if (Test-Path -LiteralPath $cache) {
                    Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
                }
            } catch {
                Add-PrinterTcpError -Message 'could not remove the driver cache'
            }
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $printerTcpExit = [int](Invoke-PrinterTcpAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $MarkerRoot -PrinterName $PrinterName -PrinterAddress $PrinterAddress -PrinterModel $PrinterModel)
    exit $printerTcpExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'printer tcp package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
