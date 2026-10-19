# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/vlc.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://get.videolan.org/vlc/3.0.24/win64/vlc-3.0.24-win64.exe',
    [string]$InstallerSha256 = 'd711e1e1fe52052748c39080c7dce63f6b7e4c315efedf1774a3f1957b782ff3',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-VlcVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-VlcVersionText {
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

function New-VlcPlan {
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

function Get-VlcPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-VlcPlan -ExitCode 0
    }
    $pin = Convert-VlcVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-VlcPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-VlcPlan -ExitCode 1
    }

    $installed = Convert-VlcVersionText -Text $InstalledVersion
    $marker = Convert-VlcVersionText -Text $MarkerVersion

    # Uninstall does not compare versions. Invoke-VlcAction refuses an empty hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-VlcPlan -ExitCode 0
        }
        if (-not $present) {
            return New-VlcPlan -ClearMarker $true
        }
        return New-VlcPlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-VlcPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-VlcVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-VlcVersion -Version $marker
    }
    $pinText = Format-VlcVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-VlcPlan -RunInstaller 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-VlcPlan -RunInstaller 'install'
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
            return New-VlcPlan -ExitCode 0
        }
        return New-VlcPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-VlcPlan -RunInstaller 'install'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            # Vendor-newer stays installed. Advance the marker and do not log an install.
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-VlcPlan -ExitCode 0
            }
            return New-VlcPlan -WriteMarker $write
        }
        return New-VlcPlan -RunInstaller 'install'
    }

    return New-VlcPlan -ExitCode 1
}

$script:VlcErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-VlcError {
    param([string]$Message)
    if ($null -eq $script:VlcErrorLog) {
        $script:VlcErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:VlcErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-VlcUrlHasUserInfo {
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

function Test-VlcCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-VlcHttpStatus {
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

function Test-VlcCancellationIsTimeout {
    param($Exception)
    # HttpClient reports a timeout as TaskCanceledException. A caller cancel uses the same type.
    if ($Exception -isnot [System.OperationCanceledException]) {
        return $false
    }
    $message = [string]$Exception.Message
    if ($message.IndexOf('timeout', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    if ($message.IndexOf('timed out', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    return $false
}

function Test-VlcTransientTransport {
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
            $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }
        if (Test-VlcCancellationIsTimeout -Exception $current) {
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

function Test-VlcDownloadIsTransient {
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
    $status = Get-VlcHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-VlcTransientTransport -Exception $exception)
}

function Test-VlcSha256Text {
    param([string]$Sha256)
    $text = ([string]$Sha256).Trim()
    # -cnotmatch is case-sensitive. -notmatch would accept uppercase hex.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # A repeated nibble is a placeholder, including 64 zeroes and 64 a's.
    if ($text -ceq ($text.Substring(0, 1) * 64)) {
        return $false
    }
    return $true
}

function Save-VlcPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-VlcUrlHasUserInfo -Url $Url) {
        Add-VlcError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (-not (Test-VlcSha256Text -Sha256 $Sha256)) {
        Add-VlcError -Message "invalid hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-VlcCancelled -CancelPath $CancelPath) {
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
                Add-VlcError -Message "hash mismatch for $Label"
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
            $status = Get-VlcHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-VlcDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-VlcError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-VlcError -Message "download wrote no file for $Label"
            } else {
                Add-VlcError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-VlcCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-VlcCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-VlcError -Message "download failed for $Label"
    return 1
}

function Get-VlcMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-VlcMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-VlcMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-VlcMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-VlcMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-VlcMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-VlcMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-VlcDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\vlc'
}

function Get-VlcPropertyText {
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

function New-VlcProduct {
    param(
        [string]$Version = '',
        [string]$UninstallPath = '',
        [string]$InstallDirectory = ''
    )
    return [pscustomobject]@{
        Version          = $Version
        UninstallPath    = $UninstallPath
        InstallDirectory = $InstallDirectory
    }
}

function Get-VlcParentDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    $trimmed = $Path.Trim().Trim('"')
    $slash = [Math]::Max($trimmed.LastIndexOf('\'), $trimmed.LastIndexOf('/'))
    if ($slash -le 0) {
        return ''
    }
    return $trimmed.Substring(0, $slash).TrimEnd('\', '/')
}

function Get-VlcUninstallPathText {
    param(
        [string]$UninstallText,
        [string]$InstallLocation
    )
    $text = $UninstallText.Trim()
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) {
            return $text.Substring(1, $end - 1)
        }
    }
    $lower = $text.ToLowerInvariant()
    $marker = 'uninstall.exe'
    $at = $lower.IndexOf($marker)
    if ($at -ge 0) {
        return $text.Substring(0, $at + $marker.Length).Trim().Trim('"')
    }
    $location = $InstallLocation.Trim().Trim('"').TrimEnd('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        return $location + '\uninstall.exe'
    }
    return ''
}

function Get-VlcInstallDirectoryText {
    param(
        [string]$InstallLocation,
        [string]$UninstallPath
    )
    $location = $InstallLocation.Trim().Trim('"').TrimEnd('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        return $location
    }
    return Get-VlcParentDirectory -Path $UninstallPath
}

function Find-VlcRegistryProduct {
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
            $displayName = (Get-VlcPropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -ne 'VLC media player') {
                continue
            }
            $versionText = (Get-VlcPropertyText -Object $props -Name 'DisplayVersion').Trim()
            $location = (Get-VlcPropertyText -Object $props -Name 'InstallLocation').Trim()
            $uninstallText = (Get-VlcPropertyText -Object $props -Name 'UninstallString').Trim()
            if ([string]::IsNullOrWhiteSpace($uninstallText)) {
                $uninstallText = (Get-VlcPropertyText -Object $props -Name 'QuietUninstallString').Trim()
            }
            $path = Get-VlcUninstallPathText -UninstallText $uninstallText -InstallLocation $location
            $directory = Get-VlcInstallDirectoryText -InstallLocation $location -UninstallPath $path
            $parsed = Convert-VlcVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-VlcVersion -Version $parsed
            }
            $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
            $hasPath = -not [string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($directory)
            if ($hasVersion -and $hasPath) {
                return New-VlcProduct -Version $formatted -UninstallPath $path -InstallDirectory $directory
            }
            if ($null -eq $best -and ($hasVersion -or $hasPath)) {
                $best = New-VlcProduct -Version $formatted -UninstallPath $path -InstallDirectory $directory
            }
        }
    }
    if ($null -ne $best) {
        return $best
    }
    # Written by the VLC installer when the uninstall key has no version.
    $productKey = 'HKLM:\SOFTWARE\VideoLAN\VLC'
    if (Test-Path -LiteralPath $productKey) {
        try {
            $productProps = Get-ItemProperty -LiteralPath $productKey -ErrorAction Stop
            $productVersion = (Get-VlcPropertyText -Object $productProps -Name 'Version').Trim()
            $productDir = (Get-VlcPropertyText -Object $productProps -Name 'InstallDir').Trim()
            $parsedProduct = Convert-VlcVersionText -Text $productVersion
            $formattedProduct = ''
            if ($parsedProduct -is [version]) {
                $formattedProduct = Format-VlcVersion -Version $parsedProduct
            }
            $productPath = ''
            if (-not [string]::IsNullOrWhiteSpace($productDir)) {
                $productPath = $productDir.TrimEnd('\', '/') + '\uninstall.exe'
            }
            return New-VlcProduct -Version $formattedProduct -UninstallPath $productPath -InstallDirectory (Get-VlcInstallDirectoryText -InstallLocation $productDir -UninstallPath $productPath)
        } catch {
            return New-VlcProduct
        }
    }
    return New-VlcProduct
}

function Get-VlcRegistryProduct {
    try {
        return Find-VlcRegistryProduct
    } catch {
        return New-VlcProduct
    }
}

function Get-VlcInstallerArgumentList {
    param(
        [string]$Mode,
        [string]$InstallDirectory
    )
    # /S is the NSIS silent switch. The 64-bit VLC installer waits on
    # uninstall.exe with /S and _?= last. _?= must not be quoted.
    if ($Mode -eq 'install') {
        # One string. The caller wraps it, so a one-element array is not unwrapped away.
        return '/S'
    }
    if ($Mode -ne 'uninstall') {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
        return $null
    }
    $directory = $InstallDirectory.Trim().Trim('"').TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return $null
    }
    return [string[]]@('/S', ('_?=' + $directory))
}

function Test-VlcInstallerSucceeded {
    param([int]$Code)
    # The NSIS installer returns 0. It does not use MSI 3010.
    return $Code -eq 0
}

function Get-VlcMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledVlcVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-VlcVersionText -Text $afterText
    $pin = Convert-VlcVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-VlcVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-VlcVersion -Version $pin
    }
    return ''
}

$script:DownloadFile = {
    param($Url, $Destination)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to download while a test is running'
    }
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

$script:GetInstalledVlcVersion = {
    return [string](Get-VlcRegistryProduct).Version
}

$script:GetVlcUninstallPath = {
    return [string](Get-VlcRegistryProduct).UninstallPath
}

$script:GetVlcInstallDirectory = {
    return [string](Get-VlcRegistryProduct).InstallDirectory
}

# The installer is only started from this hook. It is waited on and never killed.
# Cancel is checked before this hook.
$script:InvokeInstaller = {
    param($Mode, $TargetPath, $ArgumentList)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to start the installer while a test is running'
    }
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return 1
    }
    $flat = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($ArgumentList)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$part)) {
            $flat.Add([string]$part)
        }
    }
    if ($flat.Count -eq 0) {
        return 1
    }
    # _?= is last and must stay unquoted, so this is one argument string.
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $TargetPath
    $info.Arguments = ($flat.ToArray() -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        return 1
    }
    $null = $process.WaitForExit()
    return [int]$process.ExitCode
}

function Invoke-VlcAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    # An empty hash disables every action, including Uninstall. Do not download or run an installer.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-VlcDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledVlcVersion)
    } catch {
        Add-VlcError -Message 'could not read the installed VLC version'
        return 1
    }
    $marker = Read-VlcMarkerVersion -Root $MarkerRoot
    $plan = Get-VlcPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-VlcCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-vlc-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'vlc-3.0.24-win64.exe'
            $downloaded = [int](Save-VlcPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start the installer.
            if (Test-VlcCancelled -CancelPath $CancelPath) {
                return 130
            }
            $argumentList = @(Get-VlcInstallerArgumentList -Mode 'install' -InstallDirectory '')
            $result = & $script:InvokeInstaller -Mode 'install' -TargetPath $installerPath -ArgumentList $argumentList
            if ($null -eq $result -or -not (Test-VlcInstallerSucceeded -Code ([int]$result))) {
                Add-VlcError -Message 'installer failed'
                return 1
            }
            $write = Get-VlcMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-VlcError -Message 'installer succeeded without a version'
                return 1
            }
            Write-VlcMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-VlcCancelled -CancelPath $CancelPath) {
                return 130
            }
            $uninstallPath = ''
            $installDirectory = ''
            try {
                $uninstallPath = [string](& $script:GetVlcUninstallPath)
                $installDirectory = [string](& $script:GetVlcInstallDirectory)
            } catch {
                $uninstallPath = ''
                $installDirectory = ''
            }
            if ([string]::IsNullOrWhiteSpace($uninstallPath) -or [string]::IsNullOrWhiteSpace($installDirectory)) {
                Add-VlcError -Message 'missing uninstall program'
                return 1
            }
            $argumentList = @(Get-VlcInstallerArgumentList -Mode 'uninstall' -InstallDirectory $installDirectory)
            $result = & $script:InvokeInstaller -Mode 'uninstall' -TargetPath $uninstallPath -ArgumentList $argumentList
            if ($null -eq $result -or -not (Test-VlcInstallerSucceeded -Code ([int]$result))) {
                Add-VlcError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-VlcMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-VlcMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-VlcError -Message 'could not remove the installer cache'
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
    $vlcExit = [int](Invoke-VlcAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $vlcExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'vlc package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
