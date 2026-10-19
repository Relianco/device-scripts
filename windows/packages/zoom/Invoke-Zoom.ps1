# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/zoom.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://cdn.zoom.us/prod/7.2.1.48556/x64/ZoomInstallerFull.msi',
    [string]$InstallerSha256 = 'b0dac9fa5237d2e18144ca723644460e7cc26675e5d3db0f89fdfe47ad8c429b',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-ZoomVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-ZoomVersionText {
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

function New-ZoomPlan {
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

function Get-ZoomPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-ZoomPlan -ExitCode 0
    }
    $pin = Convert-ZoomVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-ZoomPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-ZoomPlan -ExitCode 1
    }

    $installed = Convert-ZoomVersionText -Text $InstalledVersion
    $marker = Convert-ZoomVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-ZoomPlan -ExitCode 0
        }
        if (-not $present) {
            return New-ZoomPlan -ClearMarker $true
        }
        return New-ZoomPlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-ZoomPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-ZoomVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-ZoomVersion -Version $marker
    }
    $pinText = Format-ZoomVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-ZoomPlan -RunInstaller 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-ZoomPlan -RunInstaller 'install'
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
            return New-ZoomPlan -ExitCode 0
        }
        return New-ZoomPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-ZoomPlan -RunInstaller 'install'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-ZoomPlan -ExitCode 0
            }
            return New-ZoomPlan -WriteMarker $write
        }
        return New-ZoomPlan -RunInstaller 'install'
    }

    return New-ZoomPlan -ExitCode 1
}

$script:ZoomErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-ZoomError {
    param([string]$Message)
    if ($null -eq $script:ZoomErrorLog) {
        $script:ZoomErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:ZoomErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-ZoomUrlHasUserInfo {
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

function Test-ZoomCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-ZoomHttpStatus {
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

function Test-ZoomSocketIsRetryable {
    param($Exception)
    # SocketException() keeps the last native error. Only connection and DNS codes are retried.
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    $code = [int]$Exception.SocketErrorCode
    $retryable = @(
        [int][System.Net.Sockets.SocketError]::ConnectionAborted,
        [int][System.Net.Sockets.SocketError]::ConnectionRefused,
        [int][System.Net.Sockets.SocketError]::ConnectionReset,
        [int][System.Net.Sockets.SocketError]::HostDown,
        [int][System.Net.Sockets.SocketError]::HostNotFound,
        [int][System.Net.Sockets.SocketError]::HostUnreachable,
        [int][System.Net.Sockets.SocketError]::NetworkDown,
        [int][System.Net.Sockets.SocketError]::NetworkReset,
        [int][System.Net.Sockets.SocketError]::NetworkUnreachable,
        [int][System.Net.Sockets.SocketError]::NoData,
        [int][System.Net.Sockets.SocketError]::NoRecovery,
        [int][System.Net.Sockets.SocketError]::TimedOut,
        [int][System.Net.Sockets.SocketError]::TryAgain
    )
    return $retryable -contains $code
}

function Test-ZoomTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # Cancellation is not a timeout. A timeout is a TimeoutException, including one nested inside TaskCanceledException.
        if ($current -is [System.TimeoutException] -or (Test-ZoomSocketIsRetryable -Exception $current)) {
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

function Test-ZoomDownloadIsTransient {
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
    $status = Get-ZoomHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-ZoomTransientTransport -Exception $exception)
}

function Save-ZoomPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-ZoomUrlHasUserInfo -Url $Url) {
        Add-ZoomError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-ZoomCancelled -CancelPath $CancelPath) {
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
                Add-ZoomError -Message "hash mismatch for $Label"
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
            $status = Get-ZoomHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-ZoomDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-ZoomError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-ZoomError -Message "download wrote no file for $Label"
            } else {
                Add-ZoomError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-ZoomCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-ZoomCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-ZoomError -Message "download failed for $Label"
    return 1
}

function Get-ZoomMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-ZoomMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-ZoomMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-ZoomMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-ZoomMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-ZoomMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-ZoomMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-ZoomDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\zoom'
}

function Get-ZoomPropertyText {
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

function Get-ZoomProductCodeText {
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

function Test-ZoomClientDisplayName {
    param([string]$DisplayName)
    # The client only. A plugin, Rooms, or another Zoom product stays installed.
    if ([string]::IsNullOrWhiteSpace($DisplayName) -or $DisplayName -like '*Plugin*') {
        return $false
    }
    return $DisplayName -eq 'Zoom Workplace (64-bit)'
}

function Find-ZoomRegistryProduct {
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
            $displayName = (Get-ZoomPropertyText -Object $props -Name 'DisplayName').Trim()
            if (-not (Test-ZoomClientDisplayName -DisplayName $displayName)) {
                continue
            }
            $versionText = (Get-ZoomPropertyText -Object $props -Name 'DisplayVersion').Trim()
            $uninstallText = (Get-ZoomPropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-ZoomPropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-ZoomProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $parsed = Convert-ZoomVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-ZoomVersion -Version $parsed
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

function Get-ZoomRegistryProduct {
    try {
        return Find-ZoomRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-ZoomMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode
    )
    # Quiet msiexec only. No SSO host and no conference password.
    # Uninstall passes this product code, not a plugin product.
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }
        return @('/x', $ProductCode, '/qn', '/norestart')
    }
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        return $null
    }
    return @('/i', $InstallerPath, '/qn', '/norestart')
}

function Test-ZoomMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-ZoomMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledZoomVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-ZoomVersionText -Text $afterText
    $pin = Convert-ZoomVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-ZoomVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-ZoomVersion -Version $pin
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

$script:GetInstalledZoomVersion = {
    return [string](Get-ZoomRegistryProduct).Version
}

$script:GetZoomProductCode = {
    return [string](Get-ZoomRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode)
    $argumentList = Get-ZoomMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode
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

function Invoke-ZoomAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-ZoomDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledZoomVersion)
    } catch {
        Add-ZoomError -Message 'could not read the installed Zoom version'
        return 1
    }
    $marker = Read-ZoomMarkerVersion -Root $MarkerRoot
    $plan = Get-ZoomPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-ZoomCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-ZoomError -Message 'missing hash for installer'
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-zoom-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'ZoomInstallerFull.msi'
            $downloaded = [int](Save-ZoomPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-ZoomCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeMsiExec -Mode 'install' -InstallerPath $installerPath -ProductCode ''
            if ($null -eq $result -or -not (Test-ZoomMsiSucceeded -Code ([int]$result))) {
                Add-ZoomError -Message 'installer failed'
                return 1
            }
            $write = Get-ZoomMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-ZoomError -Message 'installer succeeded without a version'
                return 1
            }
            Write-ZoomMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-ZoomCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:GetZoomProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-ZoomError -Message 'missing product code for uninstall'
                return 1
            }
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            if ($null -eq $result -or -not (Test-ZoomMsiSucceeded -Code ([int]$result))) {
                Add-ZoomError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-ZoomMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-ZoomMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-ZoomError -Message 'could not remove the installer cache'
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
    $zoomExit = [int](Invoke-ZoomAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $zoomExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'zoom package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
