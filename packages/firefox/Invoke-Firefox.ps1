# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://archive.mozilla.org/pub/firefox/releases/158.0/win64/en-US/Firefox%20Setup%20158.0.msi',
    [string]$InstallerSha256 = 'f1c8fae86653ecae39f47c909bfec04033598dd5f9229577f8114ebc2b48176f',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-FirefoxVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $token = ($Text.Trim() -split '\s+', 2)[0]
    if ($token.Length -gt 3 -and $token.EndsWith('esr', [System.StringComparison]::OrdinalIgnoreCase)) {
        $token = $token.Substring(0, $token.Length - 3)
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'invalid'
    }
    try {
        return [version]$token
    } catch {
        return 'invalid'
    }
}

function Format-FirefoxVersion {
    param([version]$Version)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([string]$Version.Major)
    $parts.Add([string]$Version.Minor)
    if ($Version.Build -ge 0) {
        $parts.Add([string]$Version.Build)
    }
    if ($Version.Revision -ge 0) {
        $parts.Add([string]$Version.Revision)
    }
    return ($parts.ToArray() -join '.')
}

function Get-FirefoxNormalizedVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]::new($Version.Major, $Version.Minor, $build, $revision)
}

function Compare-FirefoxVersion {
    param(
        [version]$Left,
        [version]$Right
    )
    $leftNormalized = Get-FirefoxNormalizedVersion -Version $Left
    $rightNormalized = Get-FirefoxNormalizedVersion -Version $Right
    return $leftNormalized.CompareTo($rightNormalized)
}

function New-FirefoxPlan {
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

function Get-FirefoxKeepInstalledPlan {
    param(
        [version]$Installed,
        [string]$MarkerVersion
    )
    $installedText = Format-FirefoxVersion -Version $Installed
    $marker = Convert-FirefoxVersionText -Text $MarkerVersion
    if ($marker -is [version] -and (Compare-FirefoxVersion -Left $marker -Right $Installed) -eq 0) {
        return New-FirefoxPlan -ExitCode 0
    }
    return New-FirefoxPlan -WriteMarker $installedText
}

function Get-FirefoxMatchedPlan {
    param(
        [version]$Pin,
        [string]$MarkerVersion
    )
    $pinText = Format-FirefoxVersion -Version $Pin
    $marker = Convert-FirefoxVersionText -Text $MarkerVersion
    if ($marker -is [version] -and (Compare-FirefoxVersion -Left $marker -Right $Pin) -eq 0) {
        return New-FirefoxPlan -ExitCode 0
    }
    return New-FirefoxPlan -WriteMarker $pinText
}

function Get-FirefoxPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-FirefoxPlan -ExitCode 0
    }
    $pin = Convert-FirefoxVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-FirefoxPlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-FirefoxPlan -ExitCode 1
    }

    $installed = Convert-FirefoxVersionText -Text $InstalledVersion
    if ($installed -eq 'invalid') {
        return New-FirefoxPlan -ExitCode 1
    }
    $marker = Convert-FirefoxVersionText -Text $MarkerVersion
    if ($Action -ne 'Uninstall' -and $marker -eq 'invalid') {
        return New-FirefoxPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-FirefoxPlan -RunInstaller 'install'
        }
        $compared = Compare-FirefoxVersion -Left $installed -Right $pin
        if ($compared -lt 0) {
            return New-FirefoxPlan -RunInstaller 'install'
        }
        if ($compared -gt 0) {
            return Get-FirefoxKeepInstalledPlan -Installed $installed -MarkerVersion $MarkerVersion
        }
        return Get-FirefoxMatchedPlan -Pin $pin -MarkerVersion $MarkerVersion
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-FirefoxPlan -RunInstaller 'install'
        }
        $compared = Compare-FirefoxVersion -Left $installed -Right $pin
        if ($compared -gt 0) {
            return Get-FirefoxKeepInstalledPlan -Installed $installed -MarkerVersion $MarkerVersion
        }
        return New-FirefoxPlan -RunInstaller 'repair'
    }

    if ($normalized -eq 'Uninstall') {
        if ($null -eq $installed) {
            if (-not [string]::IsNullOrWhiteSpace($MarkerVersion)) {
                return New-FirefoxPlan -ClearMarker $true
            }
            return New-FirefoxPlan -ExitCode 0
        }
        return New-FirefoxPlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    return New-FirefoxPlan -ExitCode 1
}

$script:DownloadFile = {
    param($Url, $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

function Add-FirefoxError {
    param([string]$Message)
    if ($null -eq $script:FirefoxErrorLog) {
        $script:FirefoxErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:FirefoxErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-FirefoxUrlHasUserInfo {
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

function Test-FirefoxCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-FirefoxHttpStatus {
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

function Test-FirefoxTransientTransport {
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

function Test-FirefoxDownloadIsTransient {
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
    $status = Get-FirefoxHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-FirefoxTransientTransport -Exception $exception)
}

function Save-FirefoxPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    if (Test-FirefoxUrlHasUserInfo -Url $Url) {
        Add-FirefoxError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-FirefoxCancelled -CancelPath $CancelPath) {
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
                Add-FirefoxError -Message "hash mismatch for $Label"
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
            $status = Get-FirefoxHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-FirefoxDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-FirefoxError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-FirefoxError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-FirefoxCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-FirefoxCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-FirefoxError -Message "download failed for $Label"
    return 1
}

function Get-FirefoxMarkerPath {
    param([string]$Root)
    return (Join-Path $Root 'marker.txt')
}

function Read-FirefoxMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-FirefoxMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-FirefoxMarker {
    param(
        [string]$Root,
        [string]$Text
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-FirefoxMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Text)
}

function Remove-FirefoxMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-FirefoxMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Resolve-FirefoxMarkerRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        return $Root
    }
    return (Join-Path (Join-Path $env:ProgramData 'Relian') 'firefox')
}

function Get-FirefoxInstalledVersion {
    $keys = @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }
        $current = ''
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $names = @($props.PSObject.Properties.Name)
            if ($names -contains 'CurrentVersion') {
                $current = [string]$props.CurrentVersion
            }
        } catch {
            continue
        }
        $parsed = Convert-FirefoxVersionText -Text $current
        if ($parsed -is [version]) {
            return (Format-FirefoxVersion -Version $parsed)
        }
    }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $children = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $names = @($props.PSObject.Properties.Name)
            if ($names -notcontains 'DisplayName') {
                continue
            }
            $display = [string]$props.DisplayName
            if ($display -notlike 'Mozilla Firefox*') {
                continue
            }
            if ($names -notcontains 'DisplayVersion') {
                continue
            }
            $parsed = Convert-FirefoxVersionText -Text ([string]$props.DisplayVersion)
            if ($parsed -is [version]) {
                return (Format-FirefoxVersion -Version $parsed)
            }
        }
    }
    return ''
}

function Get-FirefoxHelperPath {
    $keys = @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }
        $current = ''
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $names = @($props.PSObject.Properties.Name)
            if ($names -contains 'CurrentVersion') {
                $current = [string]$props.CurrentVersion
            }
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($current)) {
            continue
        }
        $main = Join-Path $key ($current.Trim() + '\Main')
        if (-not (Test-Path -LiteralPath $main)) {
            continue
        }
        $dir = ''
        try {
            $mainProps = Get-ItemProperty -LiteralPath $main -ErrorAction Stop
            $mainNames = @($mainProps.PSObject.Properties.Name)
            if ($mainNames -contains 'Install Directory') {
                $dir = [string]$mainProps.'Install Directory'
            }
            if ([string]::IsNullOrWhiteSpace($dir) -and $mainNames -contains 'PathToExe') {
                $exe = [string]$mainProps.PathToExe
                if (-not [string]::IsNullOrWhiteSpace($exe)) {
                    $dir = Split-Path -Parent $exe
                }
            }
        } catch {
            $dir = ''
        }
        if ([string]::IsNullOrWhiteSpace($dir)) {
            continue
        }
        $helper = Join-Path (Join-Path $dir 'uninstall') 'helper.exe'
        if (Test-Path -LiteralPath $helper) {
            return $helper
        }
    }

    $fallbacks = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $fallbacks.Add((Join-Path $env:ProgramFiles 'Mozilla Firefox\uninstall\helper.exe'))
    }
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $fallbacks.Add((Join-Path $programFilesX86 'Mozilla Firefox\uninstall\helper.exe'))
    }
    foreach ($helper in $fallbacks) {
        if (Test-Path -LiteralPath $helper) {
            return $helper
        }
    }
    return ''
}

$script:GetInstalledVersion = {
    try {
        return [string](Get-FirefoxInstalledVersion)
    } catch {
        return ''
    }
}

$script:GetUninstallTarget = {
    try {
        return [string](Get-FirefoxHelperPath)
    } catch {
        return ''
    }
}

# The MSI wraps the full installer and does not register a product, so
# msiexec /x does not remove Firefox. helper.exe /S does.
# Cancel is only checked before this hook. A started installer is not killed.
$script:StartInstaller = {
    param(
        [string]$Mode,
        [string]$TargetPath
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return 1
    }
    if ($Mode -eq 'uninstall') {
        $process = Start-Process -FilePath $TargetPath -ArgumentList @('/S') -Wait -PassThru -WindowStyle Hidden
        if ($null -eq $process) {
            return 1
        }
        return [int]$process.ExitCode
    }
    if ($Mode -ne 'install' -and $Mode -ne 'repair') {
        return 1
    }
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $arguments = '/i "' + $TargetPath + '" /qn /norestart PREVENT_REBOOT_REQUIRED=true'
    $process = Start-Process -FilePath $msiexec -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

function Invoke-FirefoxAction {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        $early = Get-FirefoxPlan -Action $Action -PinVersion $PinVersion -InstalledVersion '' -MarkerVersion ''
        if ($null -ne $early.ExitCode) {
            return [int]$early.ExitCode
        }
    }

    $root = Resolve-FirefoxMarkerRoot -Root $MarkerRoot
    $installed = ''
    if ($null -ne $script:GetInstalledVersion) {
        $installed = [string](& $script:GetInstalledVersion)
    }
    $marker = Read-FirefoxMarkerVersion -Root $root
    $plan = Get-FirefoxPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $pin = Convert-FirefoxVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return 1
    }

    if ($plan.RunInstaller -eq 'install' -or $plan.RunInstaller -eq 'repair') {
        if (Test-FirefoxCancelled -CancelPath $CancelPath) {
            return 130
        }
        $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-firefox-' + [guid]::NewGuid().ToString('n'))
        $installerCode = 1
        try {
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $msiPath = Join-Path $cache 'FirefoxSetup.msi'
            $downloaded = [int](Save-FirefoxPayload -Url $InstallerUrl -Destination $msiPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # An empty hash returns 0 and writes no file. Do not start msiexec.
            if (-not (Test-Path -LiteralPath $msiPath)) {
                return 0
            }
            if (Test-FirefoxCancelled -CancelPath $CancelPath) {
                return 130
            }
            $started = & $script:StartInstaller -Mode $plan.RunInstaller -TargetPath $msiPath
            if ($null -eq $started) {
                return 1
            }
            $installerCode = [int]$started
        } finally {
            if (Test-Path -LiteralPath $cache) {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($installerCode -ne 0 -and $installerCode -ne 3010) {
            return 1
        }
        $markerText = Format-FirefoxVersion -Version $pin
        $installedNow = ''
        if ($null -ne $script:GetInstalledVersion) {
            $installedNow = [string](& $script:GetInstalledVersion)
        }
        $installedParsed = Convert-FirefoxVersionText -Text $installedNow
        if ($installedParsed -is [version] -and (Compare-FirefoxVersion -Left $installedParsed -Right $pin) -gt 0) {
            $markerText = Format-FirefoxVersion -Version $installedParsed
        }
        Write-FirefoxMarker -Root $root -Text $markerText
        return 0
    }

    if ($plan.RunInstaller -eq 'uninstall') {
        if (Test-FirefoxCancelled -CancelPath $CancelPath) {
            return 130
        }
        $target = ''
        if ($null -ne $script:GetUninstallTarget) {
            $target = [string](& $script:GetUninstallTarget)
        }
        $started = & $script:StartInstaller -Mode 'uninstall' -TargetPath $target
        if ($null -eq $started) {
            return 1
        }
        $installerCode = [int]$started
        if ($installerCode -ne 0 -and $installerCode -ne 3010) {
            return 1
        }
        if ($plan.ClearMarker) {
            Remove-FirefoxMarker -Root $root
        }
        return 0
    }

    if ($plan.ClearMarker) {
        Remove-FirefoxMarker -Root $root
        return 0
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        Write-FirefoxMarker -Root $root -Text ([string]$plan.WriteMarker)
    }
    return 0
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
    $code = [int](Invoke-FirefoxAction -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $code
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'firefox package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
