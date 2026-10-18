# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/autoelevate.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://autoelevate-installers.s3.us-east-2.amazonaws.com/current/AESetup.msi',
    [string]$InstallerSha256 = '391e21349bdd0053067b7c6528b872ce4f4db522e48f3c546291dce40f596bfa',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
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

function Add-AutoElevateError {
    param([string]$Message)
    if ($null -eq $script:AutoElevateErrorLog) {
        $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:AutoElevateErrorLog.Add($Message)
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
        [string]$ProductCode
    )
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }
        return @('/x', $ProductCode, '/quiet', '/norestart')
    }
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        return $null
    }
    return @('/i', $InstallerPath, '/quiet', '/norestart')
}

function Test-AutoElevateMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-AutoElevateMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledAutoElevateVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-AutoElevateVersionText -Text $afterText
    $pin = Convert-AutoElevateVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-AutoElevateVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-AutoElevateVersion -Version $pin
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

$script:GetInstalledAutoElevateVersion = {
    return [string](Get-AutoElevateRegistryProduct).Version
}

$script:GetAutoElevateProductCode = {
    return [string](Get-AutoElevateRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode)
    $argumentList = Get-AutoElevateMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode
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

function Invoke-AutoElevateAction {
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
        $MarkerRoot = Get-AutoElevateDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledAutoElevateVersion)
    } catch {
        Add-AutoElevateError -Message 'could not read the installed AutoElevate version'
        return 1
    }
    $marker = Read-AutoElevateMarkerVersion -Root $MarkerRoot
    $plan = Get-AutoElevatePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-AutoElevateCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-AutoElevateError -Message 'missing hash for installer'
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
            $result = & $script:InvokeMsiExec -Mode 'install' -InstallerPath $installerPath -ProductCode ''
            if ($null -eq $result -or -not (Test-AutoElevateMsiSucceeded -Code ([int]$result))) {
                Add-AutoElevateError -Message 'installer failed'
                return 1
            }
            $write = Get-AutoElevateMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-AutoElevateError -Message 'installer succeeded without a version'
                return 1
            }
            Write-AutoElevateMarker -Root $MarkerRoot -Version $write
            Add-AutoElevateLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
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
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            if ($null -eq $result -or -not (Test-AutoElevateMsiSucceeded -Code ([int]$result))) {
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

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $autoelevateExit = [int](Invoke-AutoElevateAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $autoelevateExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'autoelevate package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
