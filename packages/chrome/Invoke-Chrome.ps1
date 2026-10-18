# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/chrome.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi',
    [string]$InstallerSha256 = '9b7615c72f17f5ef7fa5cf3c7dbf872cebe9e8ebeae7786bb96b490214efb31c',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-ChromeVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-ChromeVersionText {
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

function New-ChromePlan {
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

function Get-ChromePlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-ChromePlan -ExitCode 0
    }
    $pin = Convert-ChromeVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-ChromePlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-ChromePlan -ExitCode 1
    }

    $installed = Convert-ChromeVersionText -Text $InstalledVersion
    $marker = Convert-ChromeVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-ChromePlan -ExitCode 0
        }
        if (-not $present) {
            return New-ChromePlan -ClearMarker $true
        }
        return New-ChromePlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-ChromePlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-ChromeVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-ChromeVersion -Version $marker
    }
    $pinText = Format-ChromeVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-ChromePlan -RunInstaller 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-ChromePlan -RunInstaller 'install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. Record that version and do not run setup.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-ChromePlan -ExitCode 0
        }
        return New-ChromePlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-ChromePlan -RunInstaller 'install'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-ChromePlan -ExitCode 0
            }
            return New-ChromePlan -WriteMarker $write
        }
        return New-ChromePlan -RunInstaller 'install'
    }

    return New-ChromePlan -ExitCode 1
}

$script:ChromeErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-ChromeError {
    param([string]$Message)
    if ($null -eq $script:ChromeErrorLog) {
        $script:ChromeErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:ChromeErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-ChromeUrlHasUserInfo {
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

function Test-ChromeCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-ChromeHttpStatus {
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

function Test-ChromeTransientTransport {
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
        if ($current -is [System.TimeoutException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.Net.Sockets.SocketException]) {
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

function Test-ChromeDownloadIsTransient {
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
    $status = Get-ChromeHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-ChromeTransientTransport -Exception $exception)
}

function Save-ChromePayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-ChromeUrlHasUserInfo -Url $Url) {
        Add-ChromeError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-ChromeCancelled -CancelPath $CancelPath) {
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
                Add-ChromeError -Message "hash mismatch for $Label"
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
            $status = Get-ChromeHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-ChromeDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-ChromeError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-ChromeError -Message "download wrote no file for $Label"
            } else {
                Add-ChromeError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-ChromeCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-ChromeCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-ChromeError -Message "download failed for $Label"
    return 1
}

function Get-ChromeMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-ChromeMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-ChromeMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-ChromeMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-ChromeMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-ChromeMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-ChromeMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-ChromeDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\chrome'
}

function Get-ChromePropertyText {
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

function Get-ChromeProductCodeText {
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

function Find-ChromeRegistryProduct {
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
            $displayName = (Get-ChromePropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -ne 'Google Chrome') {
                continue
            }
            $versionText = (Get-ChromePropertyText -Object $props -Name 'DisplayVersion').Trim()
            $uninstallText = (Get-ChromePropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-ChromePropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-ChromeProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $parsed = Convert-ChromeVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-ChromeVersion -Version $parsed
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
    # Chrome stable Omaha id. Used only when the uninstall key has no version.
    $updateKey = 'HKLM:\SOFTWARE\Google\Update\ClientState\{8A69D345-D564-463c-AFF1-A69D9E530F96}'
    if (Test-Path -LiteralPath $updateKey) {
        try {
            $updateProps = Get-ItemProperty -LiteralPath $updateKey -ErrorAction Stop
            $updateVersion = (Get-ChromePropertyText -Object $updateProps -Name 'pv').Trim()
            $parsedUpdate = Convert-ChromeVersionText -Text $updateVersion
            if ($parsedUpdate -is [version]) {
                return [pscustomobject]@{
                    Version     = (Format-ChromeVersion -Version $parsedUpdate)
                    ProductCode = ''
                }
            }
        } catch {
            return [pscustomobject]@{ Version = ''; ProductCode = '' }
        }
    }
    return [pscustomobject]@{ Version = ''; ProductCode = '' }
}

function Get-ChromeRegistryProduct {
    try {
        return Find-ChromeRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-ChromeMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode
    )
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

function Test-ChromeMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-ChromeMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledChromeVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-ChromeVersionText -Text $afterText
    $pin = Convert-ChromeVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-ChromeVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-ChromeVersion -Version $pin
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

$script:GetInstalledChromeVersion = {
    return [string](Get-ChromeRegistryProduct).Version
}

$script:GetChromeProductCode = {
    return [string](Get-ChromeRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode)
    $argumentList = Get-ChromeMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode
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

function Invoke-ChromeAction {
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
        $MarkerRoot = Get-ChromeDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledChromeVersion)
    } catch {
        Add-ChromeError -Message 'could not read the installed Chrome version'
        return 1
    }
    $marker = Read-ChromeMarkerVersion -Root $MarkerRoot
    $plan = Get-ChromePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-ChromeCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-ChromeError -Message 'missing hash for installer'
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-chrome-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'googlechromestandaloneenterprise64.msi'
            $downloaded = [int](Save-ChromePayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-ChromeCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeMsiExec -Mode 'install' -InstallerPath $installerPath -ProductCode ''
            if ($null -eq $result -or -not (Test-ChromeMsiSucceeded -Code ([int]$result))) {
                Add-ChromeError -Message 'installer failed'
                return 1
            }
            $write = Get-ChromeMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-ChromeError -Message 'installer succeeded without a version'
                return 1
            }
            Write-ChromeMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-ChromeCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:GetChromeProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-ChromeError -Message 'missing product code for uninstall'
                return 1
            }
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            if ($null -eq $result -or -not (Test-ChromeMsiSucceeded -Code ([int]$result))) {
                Add-ChromeError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-ChromeMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-ChromeMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-ChromeError -Message 'could not remove the installer cache'
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
    $chromeExit = [int](Invoke-ChromeAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $chromeExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'chrome package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
