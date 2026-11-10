# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/autoelevate.json.
# The runner copies this script alone, so the values are inlined.
# CompanyName, CompanyInitials, LocationName and ElevationMode come in PackageArguments.
# The license key is the LicenseKey argument if it is not empty, else the AE_LICENSE_KEY
# environment variable. The argument is kept in NinjaOne activity history and is on the
# child command line; the environment variable is neither. Either way it is redacted from output.
# MSI property names are from the AESetup.msi Property, AppSearch and CustomAction tables
# and https://support.cyberfox.com/115003703811-System-Agent-Installation
# -Section Evidence is a read-only report.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://autoelevate-installers.s3.us-east-2.amazonaws.com/current/AESetup.msi',
    [string]$InstallerSha256 = '391e21349bdd0053067b7c6528b872ce4f4db522e48f3c546291dce40f596bfa',
    [string]$CancelPath = '',
    [string]$MarkerRoot = '',
    [string]$Section = '',
    [string]$CompanyName = '',
    [string]$CompanyInitials = '',
    [string]$LocationName = '',
    [string]$ElevationMode = '',
    # Owner decision (2026-11-10): the key may arrive as a package argument. This knowingly
    # puts it in NinjaOne activity history and on the child command line. AE_LICENSE_KEY
    # stays supported for callers that want neither. Do not remove this parameter.
    [string]$LicenseKey = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-AutoElevateVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-AutoElevateVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $parsed = [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
    # ProductVersion is 2.11.1959. The file version is 2.11.1959.0. Those are the same build.
    $build = $parsed.Build
    $revision = $parsed.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]::new($parsed.Major, $parsed.Minor, $build, $revision)
}

function New-AutoElevatePlan {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
        Log          = $Log
    }
}

function Get-AutoElevatePlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-AutoElevatePlan -ExitCode 0
    }
    $pin = Convert-AutoElevateVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-AutoElevatePlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-AutoElevatePlan -ExitCode 1
    }

    $installed = Convert-AutoElevateVersionText -Text $InstalledVersion
    $marker = Convert-AutoElevateVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-AutoElevatePlan -ExitCode 0
        }
        if (-not $present) {
            return New-AutoElevatePlan -ClearMarker $true -Log 'Uninstall'
        }
        return New-AutoElevatePlan -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall'
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-AutoElevatePlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-AutoElevateVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-AutoElevateVersion -Version $marker
    }
    $pinText = Format-AutoElevateVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-AutoElevatePlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-AutoElevatePlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. The marker advances and an install is not logged.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-AutoElevatePlan -ExitCode 0
        }
        return New-AutoElevatePlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-AutoElevatePlan -RunInstaller 'install' -Log 'Repair'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-AutoElevatePlan -ExitCode 0
            }
            return New-AutoElevatePlan -WriteMarker $write
        }
        return New-AutoElevatePlan -RunInstaller 'install' -Log 'Repair'
    }

    return New-AutoElevatePlan -ExitCode 1
}

$script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
$script:AutoElevateReport = [ordered]@{ Package = 'autoelevate' }
$script:AutoElevateSecret = ''

function Select-AutoElevateKey {
    param([string]$Argument)
    if (-not [string]::IsNullOrWhiteSpace($Argument)) { return [string]$Argument }
    return [string]$env:AE_LICENSE_KEY
}

function ConvertTo-AutoElevateRedacted {
    param([string]$Text)
    $out = [regex]::Replace([string]$Text, '(?i)(LICENSE_KEY=)("[^"]*"|\S*)', '$1"[redacted]"')
    if (-not [string]::IsNullOrEmpty($script:AutoElevateSecret)) {
        $out = $out.Replace($script:AutoElevateSecret, '[redacted]')
    }
    return $out
}

function Add-AutoElevateError {
    param([string]$Message)
    if ($null -eq $script:AutoElevateErrorLog) {
        $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $Message = ConvertTo-AutoElevateRedacted -Text $Message
    $script:AutoElevateErrorLog.Add($Message)
    $script:AutoElevateReport['Reason'] = $Message
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-AutoElevateUrlHasUserInfo {
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

function Test-AutoElevateCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-AutoElevateHttpStatus {
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

function Test-AutoElevateTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    # Connection and DNS only. A bare cancellation is not a timeout.
    $socketTransient = @(
        [System.Net.Sockets.SocketError]::ConnectionAborted,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::HostDown,
        [System.Net.Sockets.SocketError]::HostUnreachable,
        [System.Net.Sockets.SocketError]::NetworkDown,
        [System.Net.Sockets.SocketError]::NetworkReset,
        [System.Net.Sockets.SocketError]::NetworkUnreachable,
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::HostNotFound,
        [System.Net.Sockets.SocketError]::NoData,
        [System.Net.Sockets.SocketError]::NoRecovery,
        [System.Net.Sockets.SocketError]::TryAgain
    )
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
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

function Test-AutoElevateDownloadIsTransient {
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
    $status = Get-AutoElevateHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-AutoElevateTransientTransport -Exception $exception)
}

function Save-AutoElevatePayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-AutoElevateUrlHasUserInfo -Url $Url) {
        Add-AutoElevateError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
            return 130
        }
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_
        }
        $exists = Test-Path -LiteralPath $Destination
        if ($null -eq $thrown -and $exists) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
            if (-not $actual.Equals($expected, [System.StringComparison]::Ordinal)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Add-AutoElevateError -Message "hash mismatch for $Label"
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
            $status = Get-AutoElevateHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-AutoElevateDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-AutoElevateError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-AutoElevateError -Message "download wrote no file for $Label"
            } else {
                Add-AutoElevateError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-AutoElevateError -Message "download failed for $Label"
    return 1
}

function Get-AutoElevateMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-AutoElevateMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-AutoElevateMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-AutoElevateMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-AutoElevateMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-AutoElevateMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-AutoElevateMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-AutoElevateLogLine {
    param(
        [string]$Root,
        [string]$Line
    )
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Line)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Join-Path $Root 'toolkit.log'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($path, ($Line.Trim() + "`n"), $utf8)
}

function Get-AutoElevateDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\autoelevate'
}

function Get-AutoElevatePropertyText {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return ''
    }
    $names = @($Object.PSObject.Properties.Name)
    if ($names -notcontains $Name) {
        return ''
    }
    return [string]$Object.$Name
}

function Get-AutoElevateProductCodeText {
    param(
        [string]$KeyName,
        [string]$UninstallText
    )
    $pattern = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    $match = [regex]::Match($UninstallText, $pattern)
    if ($match.Success) {
        return $match.Value
    }
    if ($KeyName -match "^$pattern$") {
        return $KeyName
    }
    return ''
}

function Find-AutoElevateRegistryProduct {
    $best = $null
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $displayName = (Get-AutoElevatePropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -ne 'AutoElevate') {
                continue
            }
            $versionText = (Get-AutoElevatePropertyText -Object $props -Name 'DisplayVersion').Trim()
            $uninstallText = (Get-AutoElevatePropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-AutoElevatePropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-AutoElevateProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $parsed = Convert-AutoElevateVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-AutoElevateVersion -Version $parsed
            }
            $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
            $hasCode = -not [string]::IsNullOrWhiteSpace($code)
            if ($hasVersion -and $hasCode) {
                return [pscustomobject]@{ Version = $formatted; ProductCode = $code }
            }
            if ($null -eq $best -and ($hasVersion -or $hasCode)) {
                $best = [pscustomobject]@{ Version = $formatted; ProductCode = $code }
            }
        }
    }
    if ($null -ne $best) {
        return $best
    }
    return [pscustomobject]@{ Version = ''; ProductCode = '' }
}

function Get-AutoElevateRegistryProduct {
    try {
        return Find-AutoElevateRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-AutoElevateMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode,
        [string[]]$Properties = @()
    )
    # No /l*v: AppSearch loads the stored key into LICENSE_KEY_REG, and the MSI does not
    # hide it, so any verbose log would hold the key. MsiInstaller events and Evidence remain.
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }
        return @('/x', $ProductCode, '/quiet', '/norestart')
    }
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        return $null
    }
    # Start-Process joins the array with spaces, so a path is quoted to stay one argument.
    return @('/i', ('"' + $InstallerPath + '"'), '/quiet', '/norestart') + @($Properties)
}

# Stop order matters: the delayed-start service can start the agent again.
# Both names are in the AESetup.msi ServiceControl table.
$script:AutoElevateServiceNames = @('AEDelayedStartService', 'AutoElevateAgent')
# HKLM\SOFTWARE\AutoElevate (64-bit view) values the MSI reads back on an upgrade.
# LicenseKey and Settings are secret and are reported only as present or absent.
$script:AutoElevateRegistrationValueNames = @('CompanyName', 'CompanyInitials', 'CompanyID', 'LocationName', 'LocationID', 'ElevationMode', 'AutoBlockerMode', 'InstallationDirectory')

function Test-AutoElevateRegistered {
    param($Registration)
    if ($null -eq $Registration -or -not [bool]$Registration.HasLicenseKey) {
        return $false
    }
    $values = $Registration.Values
    return (-not [string]::IsNullOrWhiteSpace([string]$values['CompanyName'])) -and (-not [string]::IsNullOrWhiteSpace([string]$values['LocationName']))
}

function Get-AutoElevateRegistrationProperties {
    param(
        [string]$LicenseKey,
        [string]$CompanyName,
        [string]$CompanyInitials,
        [string]$LocationName,
        [string]$ElevationMode,
        [bool]$Registered
    )
    $refuse = { param($Reason) [pscustomobject]@{ ExitCode = 1; Reason = $Reason; Properties = @() } }
    $given = @(@($LicenseKey, $CompanyName, $CompanyInitials, $LocationName, $ElevationMode) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($given.Count -eq 0) {
        if ($Registered) {
            # The MSI reads the existing registration back from the registry.
            return [pscustomobject]@{ ExitCode = $null; Reason = ''; Properties = @() }
        }
        return & $refuse 'AutoElevate is not registered on this device: pass LicenseKey or set the AE_LICENSE_KEY environment variable, and pass CompanyName and LocationName'
    }
    # Registration values go to the MSI as a set, so a partial set is refused.
    if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
        return & $refuse 'registration needs the LicenseKey argument or the AE_LICENSE_KEY environment variable'
    }
    if ([string]::IsNullOrWhiteSpace($CompanyName) -or [string]::IsNullOrWhiteSpace($LocationName)) {
        return & $refuse 'registration needs CompanyName and LocationName'
    }
    if (-not [regex]::IsMatch($LicenseKey, '\A[A-Za-z0-9._+/=-]{8,256}\z')) {
        return & $refuse 'the license key has characters a license key does not use'
    }
    # Names: letters, digits, space and . , & ' ( ) _ - ; no quote, so the msiexec quoting holds.
    $namePattern = '\A[A-Za-z0-9][A-Za-z0-9 .,&''()_-]{0,99}\z'
    if (-not [regex]::IsMatch($CompanyName, $namePattern)) {
        return & $refuse 'CompanyName must be 1 to 100 letters, digits, spaces or . , & '' ( ) _ -'
    }
    if (-not [regex]::IsMatch($LocationName, $namePattern)) {
        return & $refuse 'LocationName must be 1 to 100 letters, digits, spaces or . , & '' ( ) _ -'
    }
    # The vendor asks for two or three characters; five leaves room for an existing portal value.
    if (-not [string]::IsNullOrEmpty($CompanyInitials) -and -not [regex]::IsMatch($CompanyInitials, '\A[A-Za-z0-9]{2,5}\z')) {
        return & $refuse 'CompanyInitials must be 2 to 5 letters or digits'
    }
    # Lowercase only: the vendor says another case falls back to the default mode.
    if (-not [string]::IsNullOrEmpty($ElevationMode) -and @('audit', 'live', 'policy') -cnotcontains $ElevationMode) {
        return & $refuse 'ElevationMode must be audit, live or policy'
    }
    $properties = @("LICENSE_KEY=`"$LicenseKey`"", "COMPANY_NAME=`"$CompanyName`"")
    if (-not [string]::IsNullOrEmpty($CompanyInitials)) {
        $properties += "COMPANY_INITIALS=`"$CompanyInitials`""
    }
    $properties += "LOCATION_NAME=`"$LocationName`""
    if (-not [string]::IsNullOrEmpty($ElevationMode)) {
        $properties += "ELEVATION_MODE=`"$ElevationMode`""
    }
    return [pscustomobject]@{ ExitCode = $null; Reason = ''; Properties = $properties }
}

function Get-AutoElevateServiceText {
    param($Service)
    if ($null -eq $Service) {
        return 'missing'
    }
    return [string]$Service.Status
}

# Stops each AutoElevate service with a bounded wait. Returns $false and leaves the
# services as they were when one will not stop. Nothing is killed.
function Stop-AutoElevateServices {
    param([int]$TimeoutSeconds = 60)
    $stopped = @()
    foreach ($name in $script:AutoElevateServiceNames) {
        $service = & $script:GetAutoElevateService -Name $name
        if ((Get-AutoElevateServiceText -Service $service) -in @('missing', 'Stopped')) {
            continue
        }
        try {
            [void](& $script:StopAutoElevateService -Name $name)
        } catch {
            # The wait below reports the state.
        }
        for ($waited = 0; $waited -lt $TimeoutSeconds; $waited++) {
            $service = & $script:GetAutoElevateService -Name $name
            if ((Get-AutoElevateServiceText -Service $service) -in @('missing', 'Stopped')) {
                break
            }
            [void](& $script:ServiceWait -Seconds 1)
        }
        $state = Get-AutoElevateServiceText -Service $service
        if ($state -notin @('missing', 'Stopped')) {
            foreach ($back in $stopped) {
                try { [void](& $script:StartAutoElevateService -Name $back) } catch { }
            }
            Add-AutoElevateError -Message ("service $name did not stop in $TimeoutSeconds s: state $state, start $($service.StartType), accepts stop $($service.CanStop), process $($service.ProcessId), recovery $($service.Recovery). msiexec was not run")
            return $false
        }
        $stopped += $name
    }
    return $true
}

# After a failed msiexec, start what the rollback left stopped so UAC brokering returns.
function Restore-AutoElevateServices {
    foreach ($name in @($script:AutoElevateServiceNames)) {
        try {
            $service = & $script:GetAutoElevateService -Name $name
            if ((Get-AutoElevateServiceText -Service $service) -eq 'Stopped') {
                [void](& $script:StartAutoElevateService -Name $name)
            }
        } catch {
            # Best effort. The error already explains the failure.
        }
    }
}

function Wait-AutoElevateAgentRunning {
    param([int]$TimeoutSeconds = 60)
    $started = $false
    $state = 'missing'
    for ($waited = 0; $waited -le $TimeoutSeconds; $waited++) {
        $state = Get-AutoElevateServiceText -Service (& $script:GetAutoElevateService -Name 'AutoElevateAgent')
        if ($state -eq 'Running') {
            return $state
        }
        if ($state -eq 'Stopped' -and -not $started) {
            $started = $true
            try { [void](& $script:StartAutoElevateService -Name 'AutoElevateAgent') } catch { }
        }
        if ($waited -lt $TimeoutSeconds) {
            [void](& $script:ServiceWait -Seconds 1)
        }
    }
    return $state
}

function Invoke-AutoElevateSafe {
    param([scriptblock]$Block, $Fallback)
    try {
        return & $Block
    } catch {
        return $Fallback
    }
}

function Get-AutoElevateEvidence {
    $versionText = [string](Invoke-AutoElevateSafe -Block { & $script:GetInstalledAutoElevateVersion } -Fallback '')
    $parsed = Convert-AutoElevateVersionText -Text $versionText
    $version = ''
    if ($parsed -is [version]) {
        $version = Format-AutoElevateVersion -Version $parsed
    }
    $registration = Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateRegistration } -Fallback $null
    $values = [ordered]@{}
    $hasKey = $false
    $hasSettings = $false
    if ($null -ne $registration) {
        foreach ($name in @($registration.Values.Keys)) {
            $values[$name] = ConvertTo-AutoElevateRedacted -Text ([string]$registration.Values[$name])
        }
        $hasKey = [bool]$registration.HasLicenseKey
        $hasSettings = [bool]$registration.HasSettings
    }
    $values['LicenseKey'] = if ($hasKey) { 'present' } else { 'absent' }
    $values['Settings'] = if ($hasSettings) { 'present' } else { 'absent' }
    $services = foreach ($name in $script:AutoElevateServiceNames) {
        $service = Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateService -Name $name } -Fallback $null
        if ($null -eq $service) {
            [pscustomobject]@{ Name = $name; Status = 'missing' }
        } else {
            $service
        }
    }
    $events = foreach ($event in @(Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateMsiEvents } -Fallback @())) {
        if ($null -eq $event) { continue }
        $message = ConvertTo-AutoElevateRedacted -Text ([string]$event.Message)
        if ($message.Length -gt 400) {
            $message = $message.Substring(0, 400)
        }
        [pscustomobject]@{ TimeCreated = [string]$event.TimeCreated; Id = [int]$event.Id; Message = $message }
    }
    $installPath = ''
    if ($values.Contains('InstallationDirectory')) {
        $installPath = [string]$values['InstallationDirectory']
    }
    return [ordered]@{
        Package      = 'autoelevate'
        Section      = 'Evidence'
        Status       = 'evidence'
        Version      = $version
        ProductCode  = [string](Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateProductCode } -Fallback '')
        InstallPath  = $installPath
        Registered   = (Test-AutoElevateRegistered -Registration $registration)
        Registration = $values
        Services     = @($services)
        Processes    = @(Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateProcesses } -Fallback @())
        MsiEvents    = @($events)
    }
}

function Test-AutoElevateMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-AutoElevateVersionAfterInstall {
    $afterText = [string](Invoke-AutoElevateSafe -Block { & $script:GetInstalledAutoElevateVersion } -Fallback '')
    $after = Convert-AutoElevateVersionText -Text $afterText
    if ($after -is [version]) {
        return $after
    }
    return $null
}

$script:DownloadFile = {
    param($Url, $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetInstalledAutoElevateVersion = {
    return [string](Get-AutoElevateRegistryProduct).Version
}

$script:GetAutoElevateProductCode = {
    return [string](Get-AutoElevateRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $ArgumentList)
    $argumentList = $ArgumentList
    if ($null -eq $argumentList) {
        return 1
    }
    $exe = 'msiexec.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

$script:ServiceWait = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetAutoElevateService = {
    param($Name)
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($null -eq $cim) {
        return $null
    }
    # A restart recovery action runs after a crash, not after a stop request.
    $failure = (& sc.exe qfailure $Name 2>$null) -join ' '
    $actions = @([regex]::Matches($failure, 'RESTART|RUN PROCESS|REBOOT') | ForEach-Object { $_.Value.ToLowerInvariant() })
    $recovery = 'none'
    if ($actions.Count -gt 0) {
        $recovery = $actions -join ', '
    }
    return [pscustomobject]@{
        Name      = $Name
        Status    = [string]$cim.State
        StartType = [string]$cim.StartMode
        CanStop   = [bool]$cim.AcceptStop
        ProcessId = [int]$cim.ProcessId
        Recovery  = $recovery
    }
}

$script:StopAutoElevateService = {
    param($Name)
    [void](& sc.exe stop $Name 2>$null)
}

$script:StartAutoElevateService = {
    param($Name)
    [void](& sc.exe start $Name 2>$null)
}

# Returns non-secret values and presence flags. LicenseKey and Settings never leave this hook.
$script:GetAutoElevateRegistration = {
    $values = [ordered]@{}
    $hasKey = $false
    $hasSettings = $false
    try {
        # The MSI AppSearch reads this key from the 64-bit view (RegLocator type 18).
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $key = $base.OpenSubKey('SOFTWARE\AutoElevate')
            if ($null -ne $key) {
                try {
                    foreach ($name in $script:AutoElevateRegistrationValueNames) {
                        $value = [string]$key.GetValue($name, '')
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $values[$name] = $value.Trim()
                        }
                    }
                    $hasKey = -not [string]::IsNullOrWhiteSpace([string]$key.GetValue('LicenseKey', ''))
                    $hasSettings = -not [string]::IsNullOrWhiteSpace([string]$key.GetValue('Settings', ''))
                } finally {
                    $key.Dispose()
                }
            }
        } finally {
            $base.Dispose()
        }
    } catch {
        # No registry on this host. Reported as not registered.
    }
    return [pscustomobject]@{ Values = $values; HasLicenseKey = $hasKey; HasSettings = $hasSettings }
}

$script:GetAutoElevateMsiEvents = {
    $filter = @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = (Get-Date).AddDays(-30) }
    return @(Get-WinEvent -FilterHashtable $filter -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.Message -like '*AutoElevate*' } |
            Select-Object -First 20 |
            ForEach-Object { [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime().ToString('o'); Id = $_.Id; Message = [string]$_.Message } })
}

# AEAlert and AEUACAgent run in each user session (vendor install guide). They are reported, not stopped.
$script:GetAutoElevateProcesses = {
    return @(Get-Process -Name 'AutoElevateAgent', 'AEAlert', 'AEUACAgent' -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
}

function Invoke-AutoElevateAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot,
        [string]$LicenseKey = '',
        [string]$CompanyName = '',
        [string]$CompanyInitials = '',
        [string]$LocationName = '',
        [string]$ElevationMode = ''
    )

    $script:AutoElevateSecret = [string]$LicenseKey
    $script:AutoElevateReport = [ordered]@{ Package = 'autoelevate'; Action = $Action }
    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-AutoElevateDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledAutoElevateVersion)
    } catch {
        Add-AutoElevateError -Message 'could not read the installed AutoElevate version'
        return 1
    }
    $script:AutoElevateReport['InstalledBefore'] = $installed
    $marker = Read-AutoElevateMarkerVersion -Root $MarkerRoot
    $plan = Get-AutoElevatePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
        return 130
    }
    $present = -not [string]::IsNullOrWhiteSpace($installed)

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-AutoElevateError -Message 'missing hash for installer'
                return 1
            }
            if (Test-AutoElevateUrlHasUserInfo -Url $InstallerUrl) {
                Add-AutoElevateError -Message 'refusing a URL that contains userinfo for installer'
                return 1
            }
            # Decided before the download: a fresh or unregistered device needs the key.
            $registered = Test-AutoElevateRegistered -Registration (Invoke-AutoElevateSafe -Block { & $script:GetAutoElevateRegistration } -Fallback $null)
            $script:AutoElevateReport['Registered'] = $registered
            $registration = Get-AutoElevateRegistrationProperties -LicenseKey $LicenseKey -CompanyName $CompanyName -CompanyInitials $CompanyInitials -LocationName $LocationName -ElevationMode $ElevationMode -Registered $registered
            if ($null -ne $registration.ExitCode) {
                Add-AutoElevateError -Message $registration.Reason
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-autoelevate-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'AESetup.msi'
            $downloaded = [int](Save-AutoElevatePayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
                return 130
            }
            # Error 1921 is the MSI failing to stop the agent. Stop it first, or do not start msiexec.
            if ($present -and -not (Stop-AutoElevateServices)) {
                return 1
            }
            $argumentList = Get-AutoElevateMsiArgumentList -Mode 'install' -InstallerPath $installerPath -ProductCode '' -Properties $registration.Properties
            $script:AutoElevateReport['MsiCommand'] = ConvertTo-AutoElevateRedacted -Text ('msiexec ' + ($argumentList -join ' '))
            # A throw is treated as a failed run, so the stopped services are restored below.
            $result = Invoke-AutoElevateSafe -Block { & $script:InvokeMsiExec -Mode 'install' -ArgumentList $argumentList -InstallerPath $installerPath -ProductCode '' } -Fallback $null
            $script:AutoElevateReport['MsiExitCode'] = $result
            if ($null -eq $result -or -not (Test-AutoElevateMsiSucceeded -Code ([int]$result))) {
                Restore-AutoElevateServices
                Add-AutoElevateError -Message "installer failed (exit code: $result)"
                return 1
            }
            $service = Wait-AutoElevateAgentRunning
            $after = Get-AutoElevateVersionAfterInstall
            $pin = Convert-AutoElevateVersionText -Text $PinVersion
            $script:AutoElevateReport['Service'] = $service
            $script:AutoElevateReport['Version'] = if ($null -eq $after) { '' } else { Format-AutoElevateVersion -Version $after }
            if ($null -eq $after -or $after.CompareTo($pin) -lt 0) {
                Add-AutoElevateError -Message "installed version '$($script:AutoElevateReport['Version'])' is below the pin $PinVersion"
                return 1
            }
            Write-AutoElevateMarker -Root $MarkerRoot -Version (Format-AutoElevateVersion -Version $after)
            Add-AutoElevateLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
            if ($service -ne 'Running') {
                Add-AutoElevateError -Message "service AutoElevateAgent is $service after the install"
                return 1
            }
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:GetAutoElevateProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-AutoElevateError -Message 'missing product code for uninstall'
                return 1
            }
            if (-not (Stop-AutoElevateServices)) {
                return 1
            }
            $argumentList = Get-AutoElevateMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            $result = Invoke-AutoElevateSafe -Block { & $script:InvokeMsiExec -Mode 'uninstall' -ArgumentList $argumentList -InstallerPath '' -ProductCode $productCode } -Fallback $null
            if ($null -eq $result -or -not (Test-AutoElevateMsiSucceeded -Code ([int]$result))) {
                Restore-AutoElevateServices
                Add-AutoElevateError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-AutoElevateMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-AutoElevateMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        Add-AutoElevateLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
        return 0
    } finally {
        # A locked cache file must not turn a finished install into a failure.
        if (-not [string]::IsNullOrWhiteSpace($cache)) {
            try {
                if (Test-Path -LiteralPath $cache) {
                    Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
                }
            } catch {
                Add-AutoElevateError -Message 'could not remove the installer cache'
            }
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation and before the URL is read.
if ($PSBoundParameters.ContainsKey('InstallerSha256') -and [string]::IsNullOrWhiteSpace($InstallerSha256)) {
    exit 0
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

# Read once, then remove from this process so msiexec and anything later does not inherit it.
$autoelevateKey = Select-AutoElevateKey -Argument $LicenseKey
Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
$script:AutoElevateSecret = $autoelevateKey
$autoelevateExit = 1
try {
    # The installer URL is checked for userinfo only where it is downloaded (Invoke-AutoElevateAction).
    if ($Section -eq 'Evidence') {
        $script:AutoElevateReport = Get-AutoElevateEvidence
        $autoelevateExit = 0
    } elseif (-not [string]::IsNullOrEmpty($Section)) {
        Add-AutoElevateError -Message 'unsupported Section'
    } else {
        $autoelevateExit = [int](Invoke-AutoElevateAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot -LicenseKey $autoelevateKey -CompanyName $CompanyName -CompanyInitials $CompanyInitials -LocationName $LocationName -ElevationMode $ElevationMode)
        $script:AutoElevateReport['Status'] = if ($autoelevateExit -eq 0) { 'ok' } else { 'error' }
    }
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'autoelevate package failed'
    }
    Add-AutoElevateError -Message $detail
    $script:AutoElevateReport['Status'] = 'error'
    $autoelevateExit = 1
} finally {
    $autoelevateKey = $null
    $LicenseKey = $null
}
Write-Output (ConvertTo-AutoElevateRedacted -Text (ConvertTo-Json -InputObject $script:AutoElevateReport -Depth 6 -Compress))
exit $autoelevateExit
