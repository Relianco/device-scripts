# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/7-zip.json.
# The runner copies this script alone, so the values are inlined.
# The URL is the 64-bit MSI linked from https://www.7-zip.org/download.html.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://github.com/ip7z/7zip/releases/download/26.04/7z2604-x64.msi',
    [string]$InstallerSha256 = '0b01334a418654293513449f61d6bfc99e5196ca371e3c3dc961eda57cd535c6',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-7ZipVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-7ZipVersionText {
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

# 7-Zip prints 26.04. The MSI ProductVersion is 26.04.00.0. Those are one release.
function Convert-7ZipComparableVersion {
    param([version]$Version)
    return [version](Format-7ZipVersion -Version $Version)
}

function New-7ZipPlan {
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

function Get-7ZipPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-7ZipPlan -ExitCode 0
    }
    $pin = Convert-7ZipVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-7ZipPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-7ZipPlan -ExitCode 1
    }

    $installed = Convert-7ZipVersionText -Text $InstalledVersion
    $marker = Convert-7ZipVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-7ZipPlan -ExitCode 0
        }
        if (-not $present) {
            return New-7ZipPlan -ClearMarker $true
        }
        return New-7ZipPlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-7ZipPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-7ZipVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-7ZipVersion -Version $marker
    }
    $pinText = Format-7ZipVersion -Version $pin
    $installedCompare = $null
    if ($null -ne $installed) {
        $installedCompare = Convert-7ZipComparableVersion -Version $installed
    }
    $pinCompare = Convert-7ZipComparableVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-7ZipPlan -RunInstaller 'install'
        }
        $compared = $installedCompare.CompareTo($pinCompare)
        if ($compared -lt 0) {
            return New-7ZipPlan -RunInstaller 'install'
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
            return New-7ZipPlan -ExitCode 0
        }
        return New-7ZipPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-7ZipPlan -RunInstaller 'install'
        }
        if ($installedCompare.CompareTo($pinCompare) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-7ZipPlan -ExitCode 0
            }
            return New-7ZipPlan -WriteMarker $write
        }
        return New-7ZipPlan -RunInstaller 'install'
    }

    return New-7ZipPlan -ExitCode 1
}

$script:7ZipErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-7ZipError {
    param([string]$Message)
    if ($null -eq $script:7ZipErrorLog) {
        $script:7ZipErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:7ZipErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-7ZipUrlHasUserInfo {
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

function Test-7ZipCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-7ZipHttpStatus {
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

function Test-7ZipSocketIsTransient {
    param($Exception)
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    # ConnectionRefused and HostNotFound only. AddressAlreadyInUse is not retried.
    $code = $Exception.SocketErrorCode
    if ($code -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
        return $true
    }
    if ($code -eq [System.Net.Sockets.SocketError]::HostNotFound) {
        return $true
    }
    return $false
}

function Test-7ZipTransientTransport {
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
        if ($current -is [System.TimeoutException] -or (Test-7ZipSocketIsTransient -Exception $current)) {
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

function Test-7ZipDownloadIsTransient {
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
    $status = Get-7ZipHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-7ZipTransientTransport -Exception $exception)
}

function Test-7ZipPinHash {
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

function Save-7ZipPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-7ZipUrlHasUserInfo -Url $Url) {
        Add-7ZipError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (-not (Test-7ZipPinHash -Sha256 $Sha256)) {
        Add-7ZipError -Message "invalid hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-7ZipCancelled -CancelPath $CancelPath) {
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
                Add-7ZipError -Message "hash mismatch for $Label"
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
            $status = Get-7ZipHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-7ZipDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-7ZipError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-7ZipError -Message "download wrote no file for $Label"
            } else {
                Add-7ZipError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-7ZipCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-7ZipCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-7ZipError -Message "download failed for $Label"
    return 1
}

function Get-7ZipMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-7ZipMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-7ZipMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-7ZipMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-7ZipMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-7ZipMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-7ZipMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-7ZipDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\7-zip'
}

function Get-7ZipPropertyText {
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

function Get-7ZipProductCodeText {
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

function Test-7ZipX64EditionName {
    param([string]$Name)
    # The x64 MSI ProductName is "7-Zip <version> (x64 edition)". The exe installer is not.
    return $Name -match '^7-Zip [0-9]+(\.[0-9]+){1,3} \(x64 edition\)$'
}

function Find-7ZipRegistryProduct {
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
            $displayName = (Get-7ZipPropertyText -Object $props -Name 'DisplayName').Trim()
            if (-not (Test-7ZipX64EditionName -Name $displayName)) {
                continue
            }
            $publisher = (Get-7ZipPropertyText -Object $props -Name 'Publisher').Trim()
            if (-not [string]::IsNullOrWhiteSpace($publisher) -and $publisher -cne 'Igor Pavlov') {
                continue
            }
            $versionText = (Get-7ZipPropertyText -Object $props -Name 'DisplayVersion').Trim()
            if ([string]::IsNullOrWhiteSpace($versionText)) {
                $nameMatch = [regex]::Match($displayName, '^7-Zip ([0-9]+(?:\.[0-9]+){1,3}) \(x64 edition\)$')
                if ($nameMatch.Success) {
                    $versionText = $nameMatch.Groups[1].Value
                }
            }
            $uninstallText = (Get-7ZipPropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-7ZipPropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-7ZipProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $parsed = Convert-7ZipVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-7ZipVersion -Version $parsed
            }
            $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
            $hasCode = -not [string]::IsNullOrWhiteSpace($code)
            $entry = [pscustomobject]@{ Version = $formatted; ProductCode = $code }
            if ($hasVersion -and $hasCode) {
                $candidate = Convert-7ZipComparableVersion -Version $parsed
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

function Get-7ZipRegistryProduct {
    try {
        return Find-7ZipRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-7ZipMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode
    )
    # msiexec /i installs and /x uninstalls. /qn is no UI. /norestart does not reboot.
    # 7-Zip's FAQ documents a silent MSI install with /q.
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
    return @('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart')
}

function Test-7ZipMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-7ZipMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalled7ZipVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-7ZipVersionText -Text $afterText
    $pin = Convert-7ZipVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and (Convert-7ZipComparableVersion -Version $after).CompareTo((Convert-7ZipComparableVersion -Version $pin)) -ge 0) {
        return Format-7ZipVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-7ZipVersion -Version $pin
    }
    return ''
}

$script:DownloadFile = {
    param($Url, $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetInstalled7ZipVersion = {
    return [string](Get-7ZipRegistryProduct).Version
}

$script:Get7ZipProductCode = {
    return [string](Get-7ZipRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode)
    $argumentList = Get-7ZipMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode
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

function Invoke-7ZipAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    # Empty hash disables every action, including Uninstall, before validation or any change.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }
    if (-not (Test-7ZipPinHash -Sha256 $InstallerSha256)) {
        Add-7ZipError -Message 'invalid hash for installer'
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-7ZipDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalled7ZipVersion)
    } catch {
        Add-7ZipError -Message 'could not read the installed 7-Zip version'
        return 1
    }
    $marker = Read-7ZipMarkerVersion -Root $MarkerRoot
    $plan = Get-7ZipPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-7ZipCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-7zip-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache '7z2604-x64.msi'
            $downloaded = [int](Save-7ZipPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-7ZipCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeMsiExec -Mode 'install' -InstallerPath $installerPath -ProductCode ''
            if ($null -eq $result -or -not (Test-7ZipMsiSucceeded -Code ([int]$result))) {
                Add-7ZipError -Message 'installer failed'
                return 1
            }
            $write = Get-7ZipMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-7ZipError -Message 'installer succeeded without a version'
                return 1
            }
            Write-7ZipMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-7ZipCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:Get7ZipProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-7ZipError -Message 'missing product code for uninstall'
                return 1
            }
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            if ($null -eq $result -or -not (Test-7ZipMsiSucceeded -Code ([int]$result))) {
                Add-7ZipError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-7ZipMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-7ZipMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-7ZipError -Message 'could not remove the installer cache'
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
    $sevenZipExit = [int](Invoke-7ZipAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $sevenZipExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = '7-Zip package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
