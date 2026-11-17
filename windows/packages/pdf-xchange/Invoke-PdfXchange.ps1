# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/pdf-xchange.json.
# intune.json passes only -PinVersion on purpose: the hash is this default, and an empty
# -InstallerSha256 is only the off switch when a caller passes it explicitly.
# The runner copies this script alone, so the values are inlined.
# The URL is the versioned 64-bit PDF-XChange PRO MSI that the winget manifest
# TrackerSoftware.PDF-XChangePRO 11.1.2.0 records. It shares its UpgradeCode with V10,
# so it upgrades a V10 or older V11 install in place and keeps user settings.
# The licence key is never a parameter: parameters are kept in the caller's history.
# It comes only from the PdfXchangeKeyData environment variable, which the caller sets.
# PdfXchangeOrganization and PdfXchangeUserMail are optional registration details.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://downloads.pdf-xchange.com/11.1.2.0/ProV11.x64.msi',
    [string]$InstallerSha256 = '1d6b02f35cd50c65029dbc780f1755f2a72700805faa553097784d77c5de3fb1',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-PdfXchangeVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-PdfXchangeVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
}

# 11.1.2 and 11.1.2.0 are one release.
function Convert-PdfXchangeComparableVersion {
    param([version]$Version)
    return [version](Format-PdfXchangeVersion -Version $Version)
}

function New-PdfXchangePlan {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
    }
}

function Get-PdfXchangePlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-PdfXchangePlan -ExitCode 0
    }
    $pin = Convert-PdfXchangeVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-PdfXchangePlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-PdfXchangePlan -ExitCode 1
    }

    $installed = Convert-PdfXchangeVersionText -Text $InstalledVersion
    $marker = Convert-PdfXchangeVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-PdfXchangePlan -ExitCode 0
        }
        if (-not $present) {
            return New-PdfXchangePlan -ClearMarker $true
        }
        return New-PdfXchangePlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-PdfXchangePlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-PdfXchangeVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-PdfXchangeVersion -Version $marker
    }
    $pinText = Format-PdfXchangeVersion -Version $pin
    $installedCompare = $null
    if ($null -ne $installed) {
        $installedCompare = Convert-PdfXchangeComparableVersion -Version $installed
    }
    $pinCompare = Convert-PdfXchangeComparableVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-PdfXchangePlan -RunInstaller 'install'
        }
        $compared = $installedCompare.CompareTo($pinCompare)
        if ($compared -lt 0) {
            return New-PdfXchangePlan -RunInstaller 'install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. Advance the marker and do not log an install.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-PdfXchangePlan -ExitCode 0
        }
        return New-PdfXchangePlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-PdfXchangePlan -RunInstaller 'install'
        }
        if ($installedCompare.CompareTo($pinCompare) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-PdfXchangePlan -ExitCode 0
            }
            return New-PdfXchangePlan -WriteMarker $write
        }
        if ($installedCompare.CompareTo($pinCompare) -eq 0) {
            # Same version: plain /i is a no-op on an installed product, so force a file reinstall.
            return New-PdfXchangePlan -RunInstaller 'repair'
        }
        return New-PdfXchangePlan -RunInstaller 'install'
    }

    return New-PdfXchangePlan -ExitCode 1
}

$script:PdfXchangeErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-PdfXchangeError {
    param([string]$Message)
    if ($null -eq $script:PdfXchangeErrorLog) {
        $script:PdfXchangeErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:PdfXchangeErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-PdfXchangeUrlHasUserInfo {
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

function Test-PdfXchangeCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-PdfXchangeHttpStatus {
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

function Test-PdfXchangeSocketIsTransient {
    param($Exception)
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    # Timeout, connection, and DNS only. AddressAlreadyInUse is not retried.
    $code = $Exception.SocketErrorCode
    $retry = @(
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::ConnectionAborted,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::HostNotFound
    )
    return $retry -contains $code
}

function Test-PdfXchangeTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    # SecureConnectionError is a connection failure and stays retryable.
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # A bare TaskCanceledException is not a timeout. Retry only when a TimeoutException is inside it.
        if ($current -is [System.TimeoutException] -or (Test-PdfXchangeSocketIsTransient -Exception $current)) {
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

function Test-PdfXchangeDownloadIsTransient {
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
    $status = Get-PdfXchangeHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-PdfXchangeTransientTransport -Exception $exception)
}

function Test-PdfXchangePinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    # -cnotmatch is case-sensitive, so uppercase hex is not a pin.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # 64 identical nibbles, including 64 zeros or 64 a's, is a placeholder.
    if ($text -cnotmatch '^(.)\1{63}$') {
        return $true
    }
    return $false
}

function Save-PdfXchangePayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # An empty hash downloads nothing, even when the URL contains userinfo.
    # A non-empty hash still refuses userinfo before any download.
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-PdfXchangeUrlHasUserInfo -Url $Url) {
        Add-PdfXchangeError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if (-not (Test-PdfXchangePinHash -Sha256 $Sha256)) {
        Add-PdfXchangeError -Message "invalid hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
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
                Add-PdfXchangeError -Message "hash mismatch for $Label"
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
            $status = Get-PdfXchangeHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-PdfXchangeDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-PdfXchangeError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-PdfXchangeError -Message "download wrote no file for $Label"
            } else {
                Add-PdfXchangeError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-PdfXchangeError -Message "download failed for $Label"
    return 1
}

function Get-PdfXchangeMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-PdfXchangeMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-PdfXchangeMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-PdfXchangeMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-PdfXchangeMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-PdfXchangeMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-PdfXchangeMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-PdfXchangeDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\pdf-xchange'
}

function Get-PdfXchangePropertyText {
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

function Get-PdfXchangeProductCodeText {
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

function Test-PdfXchangeX64EditionName {
    param([string]$Name)
    # V10 and V11 PRO MSIs both register the ProductName "PDF-XChange PRO".
    return $Name -ceq 'PDF-XChange PRO'
}

function Test-PdfXchangePublisher {
    param([string]$Publisher)
    # V11 is published by PDF-XChange Co Ltd. V10 and older by Tracker Software. Empty still counts.
    if ([string]::IsNullOrWhiteSpace($Publisher)) {
        return $true
    }
    return $Publisher -match '^(PDF-XChange|Tracker Software)'
}

function Find-PdfXchangeRegistryProduct {
    $complete = $null
    $completeVersion = $null
    $partial = $null
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
            $displayName = (Get-PdfXchangePropertyText -Object $props -Name 'DisplayName').Trim()
            if (-not (Test-PdfXchangeX64EditionName -Name $displayName)) {
                continue
            }
            $publisher = (Get-PdfXchangePropertyText -Object $props -Name 'Publisher').Trim()
            if (-not (Test-PdfXchangePublisher -Publisher $publisher)) {
                continue
            }
            $versionText = (Get-PdfXchangePropertyText -Object $props -Name 'DisplayVersion').Trim()
            $uninstallText = (Get-PdfXchangePropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-PdfXchangePropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-PdfXchangeProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $parsed = Convert-PdfXchangeVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-PdfXchangeVersion -Version $parsed
            }
            $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
            $hasCode = -not [string]::IsNullOrWhiteSpace($code)
            $entry = [pscustomobject]@{ Version = $formatted; ProductCode = $code }
            if ($hasVersion -and $hasCode) {
                $candidate = Convert-PdfXchangeComparableVersion -Version $parsed
                if ($null -eq $complete -or $candidate.CompareTo($completeVersion) -gt 0) {
                    $complete = $entry
                    $completeVersion = $candidate
                }
                continue
            }
            if ($null -eq $partial -and ($hasVersion -or $hasCode)) {
                $partial = $entry
            }
        }
    }
    if ($null -ne $complete) {
        return $complete
    }
    if ($null -ne $partial) {
        return $partial
    }
    return [pscustomobject]@{ Version = ''; ProductCode = '' }
}

function Get-PdfXchangeRegistryProduct {
    try {
        return Find-PdfXchangeRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-PdfXchangeMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode,
        [string]$Organization = '',
        [string]$UserMail = ''
    )
    # msiexec /i installs and /x uninstalls. /qn is no UI. /norestart does not reboot.
    # Property names are from the PDF-XChange V11 SysAdmin manual, Product Specific Properties.
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }
        return @('/x', $ProductCode, '/qn', '/norestart')
    }
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        return $null
    }
    # Start-Process joins ArgumentList with spaces. Quotes keep a path with spaces as one argument.
    # KEYDATA is not passed here: the MSI does not list it in MsiHiddenProperties, so an
    # msiexec log would hold the key. XCVault applies it after the install instead.
    # NOUPDATER=1 leaves out the vendor updater; this package owns the version.
    $list = @('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart', 'DESKTOP_SHORTCUTS="0"', 'NOUPDATER="1"')
    if (-not [string]::IsNullOrWhiteSpace($Organization)) {
        $list += ('ORGANIZATION="{0}"' -f $Organization)
    }
    if (-not [string]::IsNullOrWhiteSpace($UserMail)) {
        $list += ('USERMAIL="{0}"' -f $UserMail)
    }
    if ($Mode -eq 'repair') {
        # Reinstall every feature and overwrite damaged or missing files, registry and shortcuts.
        $list += @('REINSTALL=ALL', 'REINSTALLMODE=vomus')
    }
    return $list
}

# Licence keys are 'P' + product letters + version digits, a dash, then base64.
# Whitespace is removed: a key copied from an email or PDF arrives wrapped, and the
# vendor says a key with white space in it fails. Anything else unexpected is refused,
# so a quote can never reach a command line. Returns '' when the key is unusable.
function Get-PdfXchangeKeyData {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $key = [regex]::Replace($Text, '\s', '')
    if ($key -cnotmatch '^P[A-Z]{2}[0-9]{1,3}-[A-Za-z0-9+/=]{16,}$') {
        return ''
    }
    return $key
}

# Organization and e-mail are registration details shown in Help > About. They are
# optional. A value with a quote or a control character is refused ($null).
function Get-PdfXchangeRegistrationText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $value = $Text.Trim()
    if ($value.Length -gt 128 -or $value -match '["\p{C}]') {
        return $null
    }
    return $value
}

function Get-PdfXchangeVaultArgumentList {
    param([string]$KeyData)
    if ([string]::IsNullOrWhiteSpace($KeyData)) {
        return $null
    }
    # /M stores the key in HKLM for every user. /S suppresses the result dialog, which
    # would otherwise wait unseen in the SYSTEM session.
    return @('/AddKeyData', ('"{0}"' -f $KeyData), '/M', '/S')
}

function Test-PdfXchangeMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-PdfXchangeMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledPdfXchangeVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-PdfXchangeVersionText -Text $afterText
    $pin = Convert-PdfXchangeVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and (Convert-PdfXchangeComparableVersion -Version $after).CompareTo((Convert-PdfXchangeComparableVersion -Version $pin)) -ge 0) {
        return Format-PdfXchangeVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-PdfXchangeVersion -Version $pin
    }
    return ''
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

$script:GetInstalledPdfXchangeVersion = {
    return [string](Get-PdfXchangeRegistryProduct).Version
}

$script:GetPdfXchangeProductCode = {
    return [string](Get-PdfXchangeRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode, $Organization, $UserMail)
    $argumentList = Get-PdfXchangeMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode -Organization $Organization -UserMail $UserMail
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

# XCVault is only started from this hook. It is waited on and never killed.
$script:InvokeXcVault = {
    param($KeyData)
    $argumentList = Get-PdfXchangeVaultArgumentList -KeyData $KeyData
    if ($null -eq $argumentList) {
        return 1
    }
    $exe = Join-Path $env:ProgramFiles 'PDF-XChange\Vault\XCVault.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return 1
    }
    $process = Start-Process -FilePath $exe -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

# Machine policy from the vendor's ADMX templates (TrackerVault.admx, TrackerUpdater.admx).
# The policy keys kept the "Tracker Software" name in V11.
# b.AutoActivate: a user's first start activates the machine key silently (activation is per user).
# b.Disabled: no vendor update checks; this package owns the version.
$script:SetPdfXchangePolicy = {
    foreach ($item in @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Tracker Software\Vault'; Name = 'b.AutoActivate' },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Tracker Software\Updater\General'; Name = 'b.Disabled' }
        )) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            New-Item -Path $item.Path -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $item.Path -Name $item.Name -PropertyType DWord -Value 1 -Force | Out-Null
    }
}

function Invoke-PdfXchangeAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot,
        [string]$KeyText = '',
        [string]$OrganizationText = '',
        [string]$UserMailText = ''
    )

    # Empty hash disables every action, including Uninstall, before validation or any change.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }
    # Empty pin disables the package before the URL is read (the planner repeats this check).
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return 0
    }
    if (-not (Test-PdfXchangePinHash -Sha256 $InstallerSha256)) {
        Add-PdfXchangeError -Message 'invalid hash for installer'
        return 1
    }
    # Uninstall does not download, so it does not read the URL.
    # Install, Update, and Repair reject userinfo before planning, even when no file is needed.
    if ($Action -ne 'Uninstall' -and (Test-PdfXchangeUrlHasUserInfo -Url $InstallerUrl)) {
        Add-PdfXchangeError -Message 'refusing a URL that contains userinfo for installer'
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-PdfXchangeDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledPdfXchangeVersion)
    } catch {
        Add-PdfXchangeError -Message 'could not read the installed PDF-XChange version'
        return 1
    }
    $marker = Read-PdfXchangeMarkerVersion -Root $MarkerRoot
    $plan = Get-PdfXchangePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
        return 130
    }

    $keyData = ''
    $organization = ''
    $userMail = ''
    if ($plan.RunInstaller -in @('install', 'repair')) {
        # Checked before the 450 MB download. The key is never printed.
        $keyData = Get-PdfXchangeKeyData -Text $KeyText
        if ([string]::IsNullOrWhiteSpace($keyData)) {
            Add-PdfXchangeError -Message 'licence key missing or malformed in PdfXchangeKeyData'
            return 1
        }
        $organization = Get-PdfXchangeRegistrationText -Text $OrganizationText
        $userMail = Get-PdfXchangeRegistrationText -Text $UserMailText
        if ($null -eq $organization -or $null -eq $userMail) {
            Add-PdfXchangeError -Message 'organization or e-mail contains a quote or control character'
            return 1
        }
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -in @('install', 'repair')) {
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-pdf-xchange-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'ProV11.x64.msi'
            $downloaded = [int](Save-PdfXchangePayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeMsiExec -Mode $plan.RunInstaller -InstallerPath $installerPath -ProductCode '' -Organization $organization -UserMail $userMail
            if ($null -eq $result -or -not (Test-PdfXchangeMsiSucceeded -Code ([int]$result))) {
                Add-PdfXchangeError -Message 'installer failed'
                return 1
            }
            $vault = & $script:InvokeXcVault -KeyData $keyData
            if ($null -eq $vault -or [int]$vault -ne 0) {
                Add-PdfXchangeError -Message 'XCVault could not add the licence key'
                return 1
            }
            & $script:SetPdfXchangePolicy
            $write = Get-PdfXchangeMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-PdfXchangeError -Message 'installer succeeded without a version'
                return 1
            }
            Write-PdfXchangeMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-PdfXchangeCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:GetPdfXchangeProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-PdfXchangeError -Message 'missing product code for uninstall'
                return 1
            }
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode -Organization '' -UserMail ''
            if ($null -eq $result -or -not (Test-PdfXchangeMsiSucceeded -Code ([int]$result))) {
                Add-PdfXchangeError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-PdfXchangeMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-PdfXchangeMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        return 0
    } finally {
        # A locked cache file must not turn a finished install into a failure.
        if (-not [string]::IsNullOrWhiteSpace($cache)) {
            try {
                if (Test-Path -LiteralPath $cache) {
                    Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
                }
            } catch {
                Add-PdfXchangeError -Message 'could not remove the installer cache'
            }
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation. The URL is not read.
if ($PSBoundParameters.ContainsKey('InstallerSha256') -and [string]::IsNullOrWhiteSpace($InstallerSha256)) {
    exit 0
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $pdfXchangeExit = [int](Invoke-PdfXchangeAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot -KeyText $env:PdfXchangeKeyData -OrganizationText $env:PdfXchangeOrganization -UserMailText $env:PdfXchangeUserMail)
    exit $pdfXchangeExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'PDF-XChange package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
