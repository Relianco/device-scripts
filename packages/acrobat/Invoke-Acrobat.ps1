# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Edition,
    [string]$InstallerUrl = 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip',
    [string]$InstallerSha256 = '8fd2b12cf31fb28974a9755c56c79c11600f712324ff42c41ab89dee8b57d1c9',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-AcrobatVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-AcrobatVersionText {
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

function Format-AcrobatMarker {
    param(
        [string]$VersionText,
        [string]$Edition
    )
    return ('{0} {1}' -f $VersionText.Trim(), $Edition)
}

function Test-AcrobatEdition {
    param([string]$Edition)
    return ($Edition -ceq 'Standard' -or $Edition -ceq 'Pro')
}

function New-AcrobatPlan {
    param(
        $ExitCode = $null,
        [bool]$RunInstaller = $false,
        [bool]$Uninstall = $false,
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        Uninstall    = $Uninstall
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
    }
}

# Standard and Pro share one zip. The caller chooses the edition; the bytes do not.
function Get-AcrobatInstallerUrlForEdition {
    param(
        [string]$Edition,
        [string]$InstallerUrl
    )
    if (-not (Test-AcrobatEdition -Edition $Edition)) {
        return $null
    }
    return $InstallerUrl
}

function Get-AcrobatPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$Edition,
        [string]$InstalledVersion,
        [string]$MarkerText
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-AcrobatPlan -ExitCode 0
    }
    if (-not (Test-AcrobatEdition -Edition $Edition)) {
        return New-AcrobatPlan -ExitCode 1
    }
    $pin = Convert-AcrobatVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-AcrobatPlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-AcrobatPlan -ExitCode 1
    }

    $installed = Convert-AcrobatVersionText -Text $InstalledVersion
    if ($installed -eq 'invalid') {
        return New-AcrobatPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $pinText = Format-AcrobatVersion -Version $pin
    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-AcrobatVersion -Version $installed
    }
    $markerNow = ''
    if (-not [string]::IsNullOrWhiteSpace($MarkerText)) {
        $markerNow = $MarkerText.Trim()
    }

    if ($normalized -eq 'Install') {
        # A vendor build newer than the pin stays installed. The marker moves to that version and the edition.
        if ($null -eq $installed -or $installed.CompareTo($pin) -lt 0) {
            $write = Format-AcrobatMarker -VersionText $pinText -Edition $Edition
            return New-AcrobatPlan -RunInstaller $true -WriteMarker $write
        }
        $target = Format-AcrobatMarker -VersionText $installedText -Edition $Edition
        $write = ''
        if ($markerNow -cne $target) {
            $write = $target
        }
        return New-AcrobatPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        # Repair installs when Acrobat is missing and runs setup.exe again when it is present,
        # including when that build is newer than the pin.
        $versionText = $pinText
        if (-not [string]::IsNullOrWhiteSpace($installedText)) {
            $versionText = $installedText
        }
        $write = Format-AcrobatMarker -VersionText $versionText -Edition $Edition
        return New-AcrobatPlan -RunInstaller $true -WriteMarker $write
    }

    if ($normalized -eq 'Uninstall') {
        if ([string]::IsNullOrWhiteSpace($installedText) -and [string]::IsNullOrWhiteSpace($markerNow)) {
            return New-AcrobatPlan -ExitCode 0
        }
        return New-AcrobatPlan -Uninstall $true -ClearMarker $true
    }

    return New-AcrobatPlan -ExitCode 1
}

function Test-AcrobatUninstallTarget {
    param([string]$DisplayName)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        return $false
    }
    $name = $DisplayName.Trim()
    # The exact Reader name is not Acrobat. Names that continue from it, such as Reader DC, stay too.
    if ($name -ceq 'Adobe Acrobat Reader') {
        return $false
    }
    if ($name.StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)) {
        return $false
    }
    return $name.StartsWith('Adobe Acrobat', [System.StringComparison]::Ordinal)
}

function Select-AcrobatUninstallProducts {
    param($Products)
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($product in @($Products)) {
        if ($null -eq $product) {
            continue
        }
        $name = ''
        $propNames = @($product.PSObject.Properties.Name)
        if ($propNames -contains 'DisplayName') {
            $name = [string]$product.DisplayName
        }
        if (Test-AcrobatUninstallTarget -DisplayName $name) {
            $selected.Add($product)
        }
    }
    if ($selected.Count -eq 0) {
        return @()
    }
    return @($selected.ToArray())
}

function Get-AcrobatInstalledVersionFromProducts {
    param($Products)
    $best = $null
    foreach ($product in @($Products)) {
        if ($null -eq $product) {
            continue
        }
        $propNames = @($product.PSObject.Properties.Name)
        $name = ''
        $versionText = ''
        if ($propNames -contains 'DisplayName') {
            $name = [string]$product.DisplayName
        }
        if (-not (Test-AcrobatUninstallTarget -DisplayName $name)) {
            continue
        }
        if ($propNames -contains 'DisplayVersion') {
            $versionText = [string]$product.DisplayVersion
        }
        $parsed = Convert-AcrobatVersionText -Text $versionText
        if ($parsed -isnot [version]) {
            continue
        }
        if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
            $best = $parsed
        }
    }
    if ($null -eq $best) {
        return ''
    }
    return Format-AcrobatVersion -Version $best
}

# Adobe Acrobat Desktop command line (Setup.exe bootstrapper):
# /sAll silent, /rs suppress reboot, /msi passes /qn (no UI) through to msiexec.
# https://www.adobe.com/devnet-docs/acrobatetk/tools/DesktopDeployment/cmdline.html
function Get-AcrobatSetupArgumentList {
    return @('/sAll', '/rs', '/msi', '/qn')
}

# Silent uninstall from the same document: msiexec /x {ProductCode} /qn
function Get-AcrobatUninstallArgumentList {
    param([string]$ProductCode)
    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return $null
    }
    $code = $ProductCode.Trim()
    if ($code -notmatch '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
        return $null
    }
    return @('/x', $code, '/qn')
}

function Add-AcrobatError {
    param([string]$Message)
    if ($null -eq $script:AcrobatErrorLog) {
        $script:AcrobatErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:AcrobatErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-AcrobatUrlHasUserInfo {
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

function Test-AcrobatCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-AcrobatHttpStatus {
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

function Test-AcrobatTransientTransport {
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

function Test-AcrobatDownloadIsTransient {
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
    $status = Get-AcrobatHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-AcrobatTransientTransport -Exception $exception)
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

function Save-AcrobatPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # An empty hash is success and does not download. Userinfo is still refused when a hash is present.
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-AcrobatUrlHasUserInfo -Url $Url) {
        Add-AcrobatError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-AcrobatCancelled -CancelPath $CancelPath) {
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
                Add-AcrobatError -Message "hash mismatch for $Label"
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
            $status = Get-AcrobatHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-AcrobatDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-AcrobatError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-AcrobatError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-AcrobatCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-AcrobatCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-AcrobatError -Message "download failed for $Label"
    return 1
}

function Read-AcrobatMarkerText {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Join-Path $Root 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-AcrobatMarker {
    param(
        [string]$Root,
        [string]$Text
    )
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Text)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Join-Path $Root 'marker.txt'
    [System.IO.File]::WriteAllText($path, $Text.Trim())
}

function Clear-AcrobatMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Join-Path $Root 'marker.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-AcrobatRegistryProducts {
    $found = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $children = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        foreach ($item in $children) {
            if ($null -eq $item) {
                continue
            }
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction Stop
            } catch {
                $props = $null
            }
            if ($null -eq $props) {
                continue
            }
            $displayName = ''
            $displayVersion = ''
            $propNames = @($props.PSObject.Properties.Name)
            if ($propNames -contains 'DisplayName') {
                $displayName = [string]$props.DisplayName
            }
            if ($propNames -contains 'DisplayVersion') {
                $displayVersion = [string]$props.DisplayVersion
            }
            $found.Add([pscustomobject]@{
                    DisplayName    = $displayName
                    DisplayVersion = $displayVersion
                    ProductCode    = [string]$item.PSChildName
                })
        }
    }
    if ($found.Count -eq 0) {
        return @()
    }
    return @($found.ToArray())
}

$script:ReadAcrobatProducts = {
    return @(Get-AcrobatRegistryProducts)
}

$script:ReadAcrobatInstalledVersion = {
    $products = @(& $script:ReadAcrobatProducts)
    return (Get-AcrobatInstalledVersionFromProducts -Products $products)
}

$script:ExpandAcrobatArchive = {
    param($ZipPath, $Destination)
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

$script:ResolveAcrobatSetup = {
    param($ExtractRoot)
    if ([string]::IsNullOrWhiteSpace($ExtractRoot) -or -not (Test-Path -LiteralPath $ExtractRoot)) {
        return ''
    }
    $found = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'setup.exe' })
    if ($found.Count -eq 0 -or $null -eq $found[0]) {
        return ''
    }
    return [string]$found[0].FullName
}

$script:StartAcrobatSetup = {
    param($SetupPath)
    if ([string]::IsNullOrWhiteSpace($SetupPath)) {
        return 1
    }
    $argumentList = @(Get-AcrobatSetupArgumentList)
    $process = Start-Process -FilePath $SetupPath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

$script:StartAcrobatUninstall = {
    param($ProductCode, $DisplayName)
    $argumentList = @(Get-AcrobatUninstallArgumentList -ProductCode $ProductCode)
    if ($argumentList.Count -eq 0 -or $null -eq $argumentList[0]) {
        return 1
    }
    $msiexec = 'msiexec.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    }
    $process = Start-Process -FilePath $msiexec -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    $code = [int]$process.ExitCode
    # 3010 is Windows Installer success with a reboot request. /rs does not apply to msiexec.
    if ($code -eq 0 -or $code -eq 3010) {
        return 0
    }
    return 1
}

function Get-AcrobatMarkerToWrite {
    param(
        $Plan,
        [string]$Edition
    )
    if (-not $Plan.RunInstaller -and -not [string]::IsNullOrWhiteSpace([string]$Plan.WriteMarker)) {
        return [string]$Plan.WriteMarker
    }
    if ($Plan.RunInstaller) {
        $fresh = ''
        try {
            $fresh = [string](& $script:ReadAcrobatInstalledVersion)
        } catch {
            $fresh = ''
        }
        $parsed = Convert-AcrobatVersionText -Text $fresh
        if ($parsed -is [version]) {
            return (Format-AcrobatMarker -VersionText (Format-AcrobatVersion -Version $parsed) -Edition $Edition)
        }
        return [string]$Plan.WriteMarker
    }
    return [string]$Plan.WriteMarker
}

function Invoke-AcrobatAction {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$Edition,
        [string]$InstalledVersion,
        [string]$MarkerText,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot,
        $Products
    )

    $plan = Get-AcrobatPlan -Action $Action -PinVersion $PinVersion -Edition $Edition -InstalledVersion $InstalledVersion -MarkerText $MarkerText
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    if ($plan.RunInstaller) {
        if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
            return 0
        }
        if (Test-AcrobatCancelled -CancelPath $CancelPath) {
            return 130
        }
        $pinnedUrl = [string](Get-AcrobatInstallerUrlForEdition -Edition $Edition -InstallerUrl $InstallerUrl)
        if ([string]::IsNullOrWhiteSpace($pinnedUrl)) {
            return 1
        }
        $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-acrobat-' + [guid]::NewGuid().ToString('n'))
        try {
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $zipPath = Join-Path $cache 'Acrobat_DC_Web_x64_WWMUI.zip'
            $extract = Join-Path $cache 'extract'
            $downloaded = [int](Save-AcrobatPayload -Url $pinnedUrl -Destination $zipPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            [void](& $script:ExpandAcrobatArchive -ZipPath $zipPath -Destination $extract)
            $setupPath = [string](& $script:ResolveAcrobatSetup -ExtractRoot $extract)
            if ([string]::IsNullOrWhiteSpace($setupPath)) {
                Add-AcrobatError -Message 'setup.exe was not in the installer archive'
                return 1
            }
            # Cancel does not stop setup.exe once it has started.
            $setupCode = [int](& $script:StartAcrobatSetup -SetupPath $setupPath)
            if ($setupCode -ne 0) {
                return 1
            }
        } finally {
            if (Test-Path -LiteralPath $cache) {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($plan.Uninstall) {
        $targets = @(Select-AcrobatUninstallProducts -Products $Products)
        foreach ($target in $targets) {
            if ($null -eq $target) {
                continue
            }
            $codeText = ''
            $displayName = ''
            $propNames = @($target.PSObject.Properties.Name)
            if ($propNames -contains 'ProductCode') {
                $codeText = [string]$target.ProductCode
            }
            if ($propNames -contains 'DisplayName') {
                $displayName = [string]$target.DisplayName
            }
            $removed = [int](& $script:StartAcrobatUninstall -ProductCode $codeText -DisplayName $displayName)
            if ($removed -ne 0) {
                return 1
            }
        }
    }

    if ($plan.ClearMarker) {
        Clear-AcrobatMarker -Root $MarkerRoot
    } else {
        $marker = [string](Get-AcrobatMarkerToWrite -Plan $plan -Edition $Edition)
        if (-not [string]::IsNullOrWhiteSpace($marker)) {
            Write-AcrobatMarker -Root $MarkerRoot -Text $marker
        }
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

if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    $MarkerRoot = Join-Path $programData 'Relian\acrobat'
}
if (-not (Test-Path -LiteralPath $MarkerRoot)) {
    New-Item -ItemType Directory -Path $MarkerRoot -Force | Out-Null
}

try {
    $products = @(& $script:ReadAcrobatProducts)
    $installed = Get-AcrobatInstalledVersionFromProducts -Products $products
    $markerText = Read-AcrobatMarkerText -Root $MarkerRoot
    $code = [int](Invoke-AcrobatAction -Action $Action -PinVersion $PinVersion -Edition $Edition -InstalledVersion $installed -MarkerText $markerText -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot -Products $products)
    exit $code
} catch {
    $detail = [string]$_.Exception.Message
    Add-AcrobatError -Message $detail
    exit 1
}
