# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# Pinned URLs and sha256 values are inlined. The runner copies this script
# alone and passes only DeploymentType, Action, and PinVersion.
# This installs Microsoft.DesktopAppInstaller. It does not install other apps.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-WingetVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-WingetVersionText {
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

function New-WingetPlan {
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

function Get-WingetPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-WingetPlan -ExitCode 0
    }
    $pin = Convert-WingetVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-WingetPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-WingetPlan -ExitCode 1
    }

    $installed = Convert-WingetVersionText -Text $InstalledVersion
    $marker = Convert-WingetVersionText -Text $MarkerVersion

    # Uninstall does not compare versions. An empty hash never reaches this plan.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-WingetPlan -ExitCode 0
        }
        if (-not $present) {
            return New-WingetPlan -ClearMarker $true -Log 'Uninstall'
        }
        return New-WingetPlan -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall'
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-WingetPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-WingetVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-WingetVersion -Version $marker
    }
    $pinText = Format-WingetVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-WingetPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-WingetPlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            # A newer vendor build stays installed. Advance the marker and do not log an install.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-WingetPlan -ExitCode 0
        }
        return New-WingetPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-WingetPlan -RunInstaller 'install' -Log 'Repair'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-WingetPlan -ExitCode 0
            }
            return New-WingetPlan -WriteMarker $write
        }
        return New-WingetPlan -RunInstaller 'install' -Log 'Repair'
    }

    return New-WingetPlan -ExitCode 1
}

function Get-WingetPinnedFiles {
    $files = New-Object System.Collections.Generic.List[object]
    $files.Add([pscustomobject]@{
            Role    = 'package'
            File    = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            Url     = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            Sha256  = '65dea9c01ce08ee7b763366b27c0e651f97db857c11ca9b9c301826c10092f2e'
            Size    = [int64]217276577
            Version = '1.29.380.0'
        })
    $files.Add([pscustomobject]@{
            Role    = 'license'
            File    = 'e53e159d00e04f729cc2180cffd1c02e_License1.xml'
            Url     = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380/e53e159d00e04f729cc2180cffd1c02e_License1.xml'
            Sha256  = 'bcb15118ec47df24e3e6013a7006147c3a15b3a8104ed660fe87c8b4ed01f485'
            Size    = [int64]2686
            Version = '1.29.380.0'
        })
    $files.Add([pscustomobject]@{
            Role    = 'dependencies'
            File    = 'DesktopAppInstaller_Dependencies.zip'
            Url     = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380/DesktopAppInstaller_Dependencies.zip'
            Sha256  = 'ba875afe9d190f61218985ac0292a99d1db710bf93e13c68944ca9d89f0d82d1'
            Size    = [int64]97760717
            Version = '1.29.380.0'
        })
    return $files.ToArray()
}

function Get-WingetDependencyFiles {
    $zipUrl = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380/DesktopAppInstaller_Dependencies.zip'
    $files = New-Object System.Collections.Generic.List[object]
    $files.Add([pscustomobject]@{
            Role    = 'dependency'
            File    = 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
            Path    = 'x64/Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
            Url     = $zipUrl
            Sha256  = '9c17b521f9d690a1f504da5108ed6eec5669eb3a8fd1331eef43e40d84e74283'
            Size    = [int64]896581
            Version = '14.0.33519.0'
        })
    $files.Add([pscustomobject]@{
            Role    = 'dependency'
            File    = 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
            Path    = 'x64/Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
            Url     = $zipUrl
            Sha256  = '077a3d1a5d0622bd3004dca85f5e192d6e98ec79b83d4aa06766759ea6c09c3d'
            Size    = [int64]6757465
            Version = '14.0.33728.0'
        })
    $files.Add([pscustomobject]@{
            Role    = 'dependency'
            File    = 'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
            Path    = 'x64/Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
            Url     = $zipUrl
            Sha256  = 'a31595cc4b5aebc18466ec24e8d4b566fe0fcafb52d833b6d139b8691d0e5177'
            Size    = [int64]25431545
            Version = '8000.616.304.0'
        })
    return $files.ToArray()
}

$script:WingetErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-WingetError {
    param([string]$Message)
    if ($null -eq $script:WingetErrorLog) {
        $script:WingetErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:WingetErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-WingetUrlHasUserInfo {
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

function Test-WingetCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-WingetHttpStatus {
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

function Test-WingetTransientTransport {
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

function Test-WingetDownloadIsTransient {
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
    $status = Get-WingetHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-WingetTransientTransport -Exception $exception)
}

function Save-WingetPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # An empty hash downloads nothing, before userinfo is checked.
    # A non-empty hash still refuses a URL that contains userinfo.
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-WingetUrlHasUserInfo -Url $Url) {
        Add-WingetError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-WingetCancelled -CancelPath $CancelPath) {
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
                Add-WingetError -Message "hash mismatch for $Label"
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
            $status = Get-WingetHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-WingetDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-WingetError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-WingetError -Message "download wrote no file for $Label"
            } else {
                Add-WingetError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-WingetCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-WingetCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-WingetError -Message "download failed for $Label"
    return 1
}

function Get-WingetMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-WingetMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-WingetMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-WingetMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-WingetMarkerPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $Version, $utf8)
}

function Remove-WingetMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-WingetMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-WingetLogLine {
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
    [System.IO.File]::AppendAllText($path, ($Line + "`n"), $utf8)
}

function Get-WingetDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\winget'
}

function Get-WingetFileByRole {
    param(
        $Files,
        [string]$Role
    )
    foreach ($file in @($Files)) {
        if ($null -ne $file -and [string]$file.Role -eq $Role) {
            return $file
        }
    }
    return $null
}

function Test-WingetLeafName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Name.Contains('/') -or $Name.Contains('\') -or $Name.Contains('..')) {
        return $false
    }
    return $true
}

function Test-WingetHashDisabled {
    param(
        $Files,
        $Dependencies
    )
    # An empty hash disables the package. It is not a missing-pin or userinfo error.
    foreach ($role in @('package', 'license', 'dependencies')) {
        $file = Get-WingetFileByRole -Files $Files -Role $role
        if ($null -ne $file -and [string]::IsNullOrWhiteSpace([string]$file.Sha256)) {
            return $true
        }
    }
    foreach ($pin in @($Dependencies)) {
        if ($null -ne $pin -and [string]::IsNullOrWhiteSpace([string]$pin.Sha256)) {
            return $true
        }
    }
    return $false
}

function Test-WingetPinsReady {
    param(
        $Files,
        $Dependencies
    )
    foreach ($role in @('package', 'license', 'dependencies')) {
        $file = Get-WingetFileByRole -Files $Files -Role $role
        if ($null -eq $file) {
            Add-WingetError -Message "missing hash for $role"
            return 1
        }
        if (-not (Test-WingetLeafName -Name ([string]$file.File))) {
            Add-WingetError -Message "missing hash for $role"
            return 1
        }
        if (Test-WingetUrlHasUserInfo -Url ([string]$file.Url)) {
            Add-WingetError -Message "refusing a URL that contains userinfo for $role"
            return 1
        }
        if ([string]::IsNullOrWhiteSpace([string]$file.Sha256)) {
            Add-WingetError -Message "missing hash for $role"
            return 1
        }
    }
    $pins = @($Dependencies)
    if ($pins.Count -eq 0) {
        Add-WingetError -Message 'missing hash for dependency'
        return 1
    }
    $seen = @{}
    foreach ($pin in $pins) {
        $leaf = ''
        if ($null -ne $pin) {
            $leaf = [string]$pin.File
        }
        if (-not (Test-WingetLeafName -Name $leaf)) {
            Add-WingetError -Message 'missing hash for dependency'
            return 1
        }
        if ($seen.ContainsKey($leaf)) {
            Add-WingetError -Message "duplicate dependency $leaf"
            return 1
        }
        $seen[$leaf] = $true
        if ($null -eq $pin -or [string]::IsNullOrWhiteSpace([string]$pin.Sha256)) {
            Add-WingetError -Message "missing hash for $leaf"
            return 1
        }
    }
    return 0
}

function Confirm-WingetDependencies {
    param(
        [string]$Directory,
        $Pins
    )
    foreach ($pin in @($Pins)) {
        $leaf = [string]$pin.File
        $path = Join-Path $Directory $leaf
        if (-not (Test-Path -LiteralPath $path)) {
            Add-WingetError -Message "dependency was not extracted for $leaf"
            return 1
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        $expected = ([string]$pin.Sha256).Trim().ToLowerInvariant()
        if (-not $actual.Equals($expected, [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Add-WingetError -Message "hash mismatch for $leaf"
            return 1
        }
    }
    return 0
}

function Expand-WingetDependencyArchive {
    param(
        [string]$ZipPath,
        [string]$Destination,
        $Pins
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($pin in @($Pins)) {
            $wanted = ([string]$pin.Path).Replace('\', '/').TrimStart('/')
            $match = $null
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.Replace('\', '/')
                if ($name -eq $wanted) {
                    $match = $entry
                    break
                }
            }
            if ($null -eq $match) {
                throw 'missing dependency entry'
            }
            $target = Join-Path $Destination ([string]$pin.File)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($match, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Get-WingetProvisionArguments {
    param(
        [string]$Mode,
        [string]$PackagePath,
        [string]$LicensePath,
        [string[]]$DependencyPaths
    )
    if ($Mode -eq 'uninstall') {
        return @('-Online', '-PackageName', 'Microsoft.DesktopAppInstaller')
    }
    if ($Mode -ne 'install') {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($PackagePath) -or [string]::IsNullOrWhiteSpace($LicensePath)) {
        return $null
    }
    $deps = New-Object System.Collections.Generic.List[string]
    foreach ($dep in @($DependencyPaths)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dep)) {
            $deps.Add([string]$dep)
        }
    }
    if ($deps.Count -eq 0) {
        return $null
    }
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('-Online')
    $list.Add('-PackagePath')
    $list.Add($PackagePath)
    $list.Add('-LicensePath')
    $list.Add($LicensePath)
    $list.Add('-DependencyPackagePath')
    foreach ($dep in $deps) {
        $list.Add($dep)
    }
    return $list.ToArray()
}

function Test-WingetAppxSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-WingetMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledWingetVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-WingetVersionText -Text $afterText
    $pin = Convert-WingetVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-WingetVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-WingetVersion -Version $pin
    }
    return ''
}

function Find-WingetInstalledVersion {
    $best = $null
    try {
        if (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) {
            $packages = @()
            try {
                $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
            } catch {
                $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
            }
            foreach ($package in $packages) {
                if ($null -eq $package) {
                    continue
                }
                $parsed = Convert-WingetVersionText -Text ([string]$package.Version)
                if ($parsed -is [version]) {
                    if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
                        $best = $parsed
                    }
                }
            }
        }
    } catch {
        $best = $null
    }
    if ($null -eq $best) {
        try {
            $programFiles = [string]$env:ProgramFiles
            if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
                $root = Join-Path $programFiles 'WindowsApps'
                if (Test-Path -LiteralPath $root) {
                    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                        $name = [string]$dir.Name
                        if ($name -notmatch '^Microsoft\.DesktopAppInstaller_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_(x64|x86|arm64)__8wekyb3d8bbwe$') {
                            continue
                        }
                        $parsed = Convert-WingetVersionText -Text $Matches[1]
                        if ($parsed -is [version]) {
                            if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
                                $best = $parsed
                            }
                        }
                    }
                }
            }
        } catch {
            return ''
        }
    }
    if ($null -eq $best) {
        return ''
    }
    return Format-WingetVersion -Version $best
}

function Remove-WingetPackage {
    $found = $false
    if (Get-Command -Name Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' })
        foreach ($item in $provisioned) {
            $found = $true
            Remove-AppxProvisionedPackage -Online -PackageName $item.PackageName -ErrorAction Stop | Out-Null
        }
    }
    if (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) {
        $packages = @()
        try {
            $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
        } catch {
            $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        }
        foreach ($package in $packages) {
            if ($null -eq $package) {
                continue
            }
            $found = $true
            $fullName = [string]$package.PackageFullName
            try {
                Remove-AppxPackage -Package $fullName -AllUsers -ErrorAction Stop
            } catch {
                Remove-AppxPackage -Package $fullName -ErrorAction Stop
            }
        }
    }
    if (-not $found) {
        return 1
    }
    return 0
}

$script:DownloadFile = {
    param($Url, $Destination)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to download while a test is running'
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
    } catch {
        # Windows PowerShell 5.1 needs TLS 1.2. PowerShell 7 already negotiates it.
    }
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetInstalledWingetVersion = {
    return [string](Find-WingetInstalledVersion)
}

$script:ExpandDependencies = {
    param($ZipPath, $Destination, $Pins)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to expand dependencies while a test is running'
    }
    Expand-WingetDependencyArchive -ZipPath $ZipPath -Destination $Destination -Pins $Pins
}

# Appx changes are only started from this hook.
$script:InvokeAppx = {
    param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to change App Installer while a test is running'
    }
    $argumentList = @(Get-WingetProvisionArguments -Mode $Mode -PackagePath $PackagePath -LicensePath $LicensePath -DependencyPaths $DependencyPaths)
    if ($argumentList.Count -eq 0) {
        return 1
    }
    if ($Mode -eq 'uninstall') {
        return [int](Remove-WingetPackage)
    }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($dep in @($DependencyPaths)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dep)) {
            $paths.Add([string]$dep)
        }
    }
    Add-AppxProvisionedPackage -Online -PackagePath $PackagePath -LicensePath $LicensePath -DependencyPackagePath $paths.ToArray() | Out-Null
    return 0
}

function Invoke-WingetAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$CancelPath,
        [string]$MarkerRoot,
        $Files,
        $Dependencies
    )

    if (-not $PSBoundParameters.ContainsKey('Files') -or $null -eq $Files) {
        $Files = @(Get-WingetPinnedFiles)
    }
    if (-not $PSBoundParameters.ContainsKey('Dependencies') -or $null -eq $Dependencies) {
        $Dependencies = @(Get-WingetDependencyFiles)
    }
    # Empty or whitespace hash: success for every action, including Uninstall
    # and Reinstall. Do this before a registry read, download, install,
    # uninstall, or marker change. Do not fail an empty hash for userinfo.
    if (Test-WingetHashDisabled -Files $Files -Dependencies $Dependencies) {
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-WingetDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledWingetVersion)
    } catch {
        Add-WingetError -Message 'could not read the installed Winget version'
        return 1
    }
    $marker = Read-WingetMarkerVersion -Root $MarkerRoot
    $plan = Get-WingetPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-WingetCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            $ready = [int](Test-WingetPinsReady -Files $Files -Dependencies $Dependencies)
            if ($ready -ne 0) {
                return $ready
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-winget-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $saved = @{}
            foreach ($role in @('package', 'license', 'dependencies')) {
                $file = Get-WingetFileByRole -Files $Files -Role $role
                $destination = Join-Path $cache ([string]$file.File)
                $downloaded = [int](Save-WingetPayload -Url ([string]$file.Url) -Destination $destination -Sha256 ([string]$file.Sha256) -Label $role -CancelPath $CancelPath)
                if ($downloaded -ne 0) {
                    return $downloaded
                }
                $saved[$role] = $destination
            }
            # A cancel after the files are verified must not provision the package.
            if (Test-WingetCancelled -CancelPath $CancelPath) {
                return 130
            }
            $depDir = Join-Path $cache 'deps'
            New-Item -ItemType Directory -Path $depDir -Force | Out-Null
            try {
                [void](& $script:ExpandDependencies -ZipPath $saved['dependencies'] -Destination $depDir -Pins $Dependencies)
            } catch {
                Add-WingetError -Message 'could not expand dependencies'
                return 1
            }
            $checked = [int](Confirm-WingetDependencies -Directory $depDir -Pins $Dependencies)
            if ($checked -ne 0) {
                return $checked
            }
            if (Test-WingetCancelled -CancelPath $CancelPath) {
                return 130
            }
            $depPaths = New-Object System.Collections.Generic.List[string]
            foreach ($pin in @($Dependencies)) {
                $depPaths.Add((Join-Path $depDir ([string]$pin.File)))
            }
            $result = $null
            try {
                $result = & $script:InvokeAppx -Mode 'install' -PackagePath $saved['package'] -LicensePath $saved['license'] -DependencyPaths $depPaths.ToArray()
            } catch {
                Add-WingetError -Message 'installer failed'
                return 1
            }
            if ($null -eq $result -or -not (Test-WingetAppxSucceeded -Code ([int]$result))) {
                Add-WingetError -Message 'installer failed'
                return 1
            }
            $write = Get-WingetMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-WingetError -Message 'installer succeeded without a version'
                return 1
            }
            Write-WingetMarker -Root $MarkerRoot -Version $write
            Add-WingetLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-WingetCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = $null
            try {
                $result = & $script:InvokeAppx -Mode 'uninstall' -PackagePath '' -LicensePath '' -DependencyPaths @()
            } catch {
                Add-WingetError -Message 'uninstall failed'
                return 1
            }
            if ($null -eq $result -or -not (Test-WingetAppxSucceeded -Code ([int]$result))) {
                Add-WingetError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-WingetMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-WingetMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$plan.Log)) {
            Add-WingetLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
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
                Add-WingetError -Message 'could not remove the installer cache'
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
    $wingetExit = [int](Invoke-WingetAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $wingetExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'winget package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
