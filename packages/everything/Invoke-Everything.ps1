# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/everything.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://www.voidtools.com/Everything-1.5.0.1423b.x64-Setup.msi',
    [string]$InstallerSha256 = '6c9d71411aa9cfc8e8953e412fbec7f259679ab3ad82bcad40f45f814cac9029',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-EverythingVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-EverythingVersionText {
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

function New-EverythingPlan {
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

function Get-EverythingPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-EverythingPlan -ExitCode 0
    }
    $pin = Convert-EverythingVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-EverythingPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-EverythingPlan -ExitCode 1
    }

    $installed = Convert-EverythingVersionText -Text $InstalledVersion
    $marker = Convert-EverythingVersionText -Text $MarkerVersion

    # Uninstall does not compare versions.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-EverythingPlan -ExitCode 0
        }
        if (-not $present) {
            return New-EverythingPlan -ClearMarker $true -Log 'Uninstall'
        }
        return New-EverythingPlan -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall'
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-EverythingPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-EverythingVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-EverythingVersion -Version $marker
    }
    $pinText = Format-EverythingVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-EverythingPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-EverythingPlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            # A newer vendor build stays installed. Advance the marker and do not log Install.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-EverythingPlan -ExitCode 0
        }
        return New-EverythingPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-EverythingPlan -RunInstaller 'install' -Log 'Repair'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-EverythingPlan -ExitCode 0
            }
            return New-EverythingPlan -WriteMarker $write
        }
        return New-EverythingPlan -RunInstaller 'install' -Log 'Repair'
    }

    return New-EverythingPlan -ExitCode 1
}

$script:EverythingErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-EverythingError {
    param([string]$Message)
    if ($null -eq $script:EverythingErrorLog) {
        $script:EverythingErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:EverythingErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-EverythingUrlHasUserInfo {
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

function Test-EverythingCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-EverythingHttpStatus {
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

function Test-EverythingTransientTransport {
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

function Test-EverythingDownloadIsTransient {
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
    $status = Get-EverythingHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-EverythingTransientTransport -Exception $exception)
}

function Save-EverythingPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-EverythingUrlHasUserInfo -Url $Url) {
        Add-EverythingError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-EverythingCancelled -CancelPath $CancelPath) {
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
                Add-EverythingError -Message "hash mismatch for $Label"
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
            $status = Get-EverythingHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-EverythingDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-EverythingError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-EverythingError -Message "download wrote no file for $Label"
            } else {
                Add-EverythingError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-EverythingCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-EverythingCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-EverythingError -Message "download failed for $Label"
    return 1
}

function Get-EverythingMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-EverythingMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-EverythingMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-EverythingMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-EverythingMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-EverythingMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-EverythingMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-EverythingLogLine {
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

function Get-EverythingDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\everything'
}

function Get-EverythingPropertyText {
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

function Get-EverythingProductCodeText {
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

function Test-EverythingProductName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    # The MSI product name includes the build, so a newer build is a different DisplayName.
    return [regex]::IsMatch($Name.Trim(), '^Everything 1\.5\..+ \(x64\)$')
}

function Select-EverythingRegistryProduct {
    param($Entries)
    $best = $null
    foreach ($entry in @($Entries)) {
        $name = (Get-EverythingPropertyText -Object $entry -Name 'DisplayName').Trim()
        if (-not (Test-EverythingProductName -Name $name)) {
            continue
        }
        $publisher = (Get-EverythingPropertyText -Object $entry -Name 'Publisher').Trim()
        if (-not [string]::IsNullOrWhiteSpace($publisher) -and -not $publisher.Equals('voidtools', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $versionText = (Get-EverythingPropertyText -Object $entry -Name 'DisplayVersion').Trim()
        $parsed = Convert-EverythingVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-EverythingVersion -Version $parsed
        }
        $code = (Get-EverythingPropertyText -Object $entry -Name 'ProductCode').Trim()
        $complete = (-not [string]::IsNullOrWhiteSpace($formatted)) -and (-not [string]::IsNullOrWhiteSpace($code))
        $parsedVersion = $null
        if ($parsed -is [version]) {
            $parsedVersion = $parsed
        }
        $candidate = [pscustomobject]@{
            Version      = $formatted
            ProductCode  = $code
            Parsed       = $parsedVersion
            Complete     = [bool]$complete
        }
        if ($null -eq $best) {
            $best = $candidate
            continue
        }
        if ($candidate.Complete -and -not $best.Complete) {
            $best = $candidate
            continue
        }
        if (-not $candidate.Complete -and $best.Complete) {
            continue
        }
        if ($null -ne $candidate.Parsed -and $null -ne $best.Parsed -and $candidate.Parsed.CompareTo($best.Parsed) -gt 0) {
            $best = $candidate
        } elseif ($null -ne $candidate.Parsed -and $null -eq $best.Parsed) {
            $best = $candidate
        }
    }
    if ($null -eq $best) {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
    return [pscustomobject]@{ Version = [string]$best.Version; ProductCode = [string]$best.ProductCode }
}

function Find-EverythingRegistryProduct {
    $entries = [System.Collections.Generic.List[object]]::new()
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
            $displayName = (Get-EverythingPropertyText -Object $props -Name 'DisplayName').Trim()
            $publisher = (Get-EverythingPropertyText -Object $props -Name 'Publisher').Trim()
            $versionText = (Get-EverythingPropertyText -Object $props -Name 'DisplayVersion').Trim()
            $uninstallText = (Get-EverythingPropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-EverythingPropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-EverythingProductCodeText -KeyName $key.PSChildName -UninstallText $uninstallText
            $entries.Add([pscustomobject]@{
                    DisplayName    = $displayName
                    Publisher      = $publisher
                    DisplayVersion = $versionText
                    ProductCode    = $code
                })
        }
    }
    return Select-EverythingRegistryProduct -Entries $entries
}

function Get-EverythingRegistryProduct {
    try {
        return Find-EverythingRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
}

function Get-EverythingMsiArgumentList {
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
    # Start-Process joins this list. Quotes keep a TEMP path that contains spaces as one argument.
    $quotedPath = '"' + $InstallerPath.Replace('"', '""') + '"'
    return @('/i', $quotedPath, '/qn', '/norestart')
}

function Test-EverythingMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-EverythingMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledEverythingVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-EverythingVersionText -Text $afterText
    $pin = Convert-EverythingVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-EverythingVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-EverythingVersion -Version $pin
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

$script:GetInstalledEverythingVersion = {
    return [string](Get-EverythingRegistryProduct).Version
}

$script:GetEverythingProductCode = {
    return [string](Get-EverythingRegistryProduct).ProductCode
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($Mode, $InstallerPath, $ProductCode)
    $argumentList = Get-EverythingMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode
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

function Invoke-EverythingAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    # An empty hash disables the package. Do not read the registry, download, or change the marker.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-EverythingDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledEverythingVersion)
    } catch {
        Add-EverythingError -Message 'could not read the installed Everything version'
        return 1
    }
    $marker = Read-EverythingMarkerVersion -Root $MarkerRoot
    $plan = Get-EverythingPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-EverythingCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-everything-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'Everything-1.5.0.1423b.x64-Setup.msi'
            $downloaded = [int](Save-EverythingPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start msiexec.
            if (Test-EverythingCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeMsiExec -Mode 'install' -InstallerPath $installerPath -ProductCode ''
            if ($null -eq $result -or -not (Test-EverythingMsiSucceeded -Code ([int]$result))) {
                Add-EverythingError -Message 'installer failed'
                return 1
            }
            $write = Get-EverythingMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-EverythingError -Message 'installer succeeded without a version'
                return 1
            }
            Write-EverythingMarker -Root $MarkerRoot -Version $write
            if (-not [string]::IsNullOrWhiteSpace([string]$plan.Log)) {
                Add-EverythingLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
            }
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-EverythingCancelled -CancelPath $CancelPath) {
                return 130
            }
            $productCode = ''
            try {
                $productCode = [string](& $script:GetEverythingProductCode)
            } catch {
                $productCode = ''
            }
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                Add-EverythingError -Message 'missing product code for uninstall'
                return 1
            }
            $result = & $script:InvokeMsiExec -Mode 'uninstall' -InstallerPath '' -ProductCode $productCode
            if ($null -eq $result -or -not (Test-EverythingMsiSucceeded -Code ([int]$result))) {
                Add-EverythingError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-EverythingMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-EverythingMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$plan.Log)) {
            Add-EverythingLogLine -Root $MarkerRoot -Line ([string]$plan.Log)
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
                Add-EverythingError -Message 'could not remove the installer cache'
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
    $everythingExit = [int](Invoke-EverythingAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $everythingExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'everything package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
