# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced. Defaults are copied from windows/releases/adobe-reader.json.
# The runner downloads this script without that file.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/2600222031/AcroRdrDCx642600222031_en_US.exe',
    [string]$InstallerSha256 = '86e98feb3f2afa66656a85cbbc6fb71d6a3217ebf8fdc21f4d1a54d21cb45028',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AdobeReaderErrorLog = [System.Collections.Generic.List[string]]::new()
$script:AdobeReaderInstallerFile = 'AcroRdrDCx642600222031_en_US.exe'

function Format-AdobeReaderVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-AdobeReaderVersionText {
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

function New-AdobeReaderPlan {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [bool]$UninstallProduct = $false,
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return [pscustomobject]@{
        ExitCode         = $ExitCode
        RunInstaller     = $RunInstaller
        UninstallProduct = $UninstallProduct
        WriteMarker      = $WriteMarker
        ClearMarker      = $ClearMarker
        Log              = $Log
    }
}

function Get-AdobeReaderPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-AdobeReaderPlan -ExitCode 0
    }
    $pin = Convert-AdobeReaderVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-AdobeReaderPlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-AdobeReaderPlan -ExitCode 1
    }

    $installed = Convert-AdobeReaderVersionText -Text $InstalledVersion
    $marker = Convert-AdobeReaderVersionText -Text $MarkerVersion
    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-AdobeReaderPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-AdobeReaderVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-AdobeReaderVersion -Version $marker
    }
    $pinText = Format-AdobeReaderVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-AdobeReaderPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-AdobeReaderPlan -RunInstaller 'install' -Log 'Install'
        }
        # A vendor build newer than the pin stays installed. The marker advances and Install is not logged.
        $write = ''
        if ($compared -gt 0) {
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        return New-AdobeReaderPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed -or $installed.CompareTo($pin) -le 0) {
            return New-AdobeReaderPlan -RunInstaller 'install' -Log 'Repair'
        }
        $write = ''
        if ($markerText -cne $installedText) {
            $write = $installedText
        }
        return New-AdobeReaderPlan -WriteMarker $write
    }

    if ($normalized -eq 'Uninstall') {
        if ($null -eq $installed) {
            if (-not [string]::IsNullOrWhiteSpace($markerText)) {
                return New-AdobeReaderPlan -ClearMarker $true -Log 'Uninstall'
            }
            return New-AdobeReaderPlan -ExitCode 0
        }
        return New-AdobeReaderPlan -UninstallProduct $true -ClearMarker $true -Log 'Uninstall'
    }

    return New-AdobeReaderPlan -ExitCode 1
}

function Add-AdobeReaderError {
    param([string]$Message)
    if ($null -eq $script:AdobeReaderErrorLog) {
        $script:AdobeReaderErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:AdobeReaderErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-AdobeReaderUrlHasUserInfo {
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

function Test-AdobeReaderPinHash {
    param([string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) {
        return $false
    }
    $text = $Hash.Trim()
    # A case-insensitive match would accept uppercase hex. A pin is 64 lowercase hex characters.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # 64 identical characters, including 64 zeros and 64 a's, are placeholders.
    if ($text -cmatch '^(.)\1{63}$') {
        return $false
    }
    return $true
}

# Empty pin and empty hash stop before Install, Update, Repair, Reinstall, and Uninstall.
# Returns nothing when the caller should build a plan.
function Get-AdobeReaderPreDispatchCode {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }
    if (Test-AdobeReaderUrlHasUserInfo -Url $InstallerUrl) {
        Add-AdobeReaderError -Message 'refusing a URL that contains userinfo for installer'
        return 1
    }
    if (-not (Test-AdobeReaderPinHash -Hash $InstallerSha256)) {
        Add-AdobeReaderError -Message 'installer hash is not a 64-character lowercase hex pin'
        return 1
    }
    if ($Action -eq 'Reinstall') {
        return 1
    }
}

function Test-AdobeReaderCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-AdobeReaderHttpStatus {
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

function Test-AdobeReaderSocketIsRetryable {
    param($Exception)
    # SocketException() keeps the last native error. Only connection refused and DNS are retried.
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    $code = [int]$Exception.SocketErrorCode
    if ($code -eq [int][System.Net.Sockets.SocketError]::ConnectionRefused) {
        return $true
    }
    if ($code -eq [int][System.Net.Sockets.SocketError]::HostNotFound) {
        return $true
    }
    return $false
}

function Test-AdobeReaderTransientTransport {
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
        # A bare TaskCanceledException is not a timeout. Retry it only when it wraps TimeoutException.
        if ($current -is [System.TimeoutException] -or (Test-AdobeReaderSocketIsRetryable -Exception $current)) {
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

function Test-AdobeReaderDownloadIsTransient {
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
    $status = Get-AdobeReaderHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-AdobeReaderTransientTransport -Exception $exception)
}

function Save-AdobeReaderPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected before any download, including when the hash is empty.
    if (Test-AdobeReaderUrlHasUserInfo -Url $Url) {
        Add-AdobeReaderError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (-not (Test-AdobeReaderPinHash -Hash $Sha256)) {
        Add-AdobeReaderError -Message "hash is not a 64-character lowercase hex pin for $Label"
        return 1
    }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
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
                Add-AdobeReaderError -Message "hash mismatch for $Label"
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
            $status = Get-AdobeReaderHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-AdobeReaderDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-AdobeReaderError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-AdobeReaderError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-AdobeReaderError -Message "download failed for $Label"
    return 1
}

function Test-AdobeReaderPathRooted {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $true
    }
    # Tests run on Linux. A Windows drive path is still a full path.
    return $Path -match '^[A-Za-z]:[\\/]'
}

# Bootstrapper switches documented by Adobe. /msi passes EULA_ACCEPT=YES through.
# https://www.adobe.com/devnet-docs/acrobatetk/tools/DesktopDeployment/cmdline.html
function Get-AdobeReaderInstallArgumentList {
    return @('/sAll', '/rs', '/msi', 'EULA_ACCEPT=YES')
}

# Silent uninstall from the same document: msiexec /x {ProductCode} /qn
function Get-AdobeReaderUninstallArgumentList {
    param([string]$ProductCode)
    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return $null
    }
    $code = $ProductCode.Trim()
    if ($code -cnotmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return $null
    }
    return @('/x', $code, '/qn')
}

function Test-AdobeReaderProcessSuccess {
    param([int]$ExitCode)
    # 3010 means the installer finished and a reboot is still required.
    return $ExitCode -eq 0 -or $ExitCode -eq 3010
}

function Test-AdobeReaderDisplayName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $trimmed = $Name.Trim()
    # Exact Reader, and names that continue from it such as Reader DC. Acrobat itself stays.
    if ($trimmed -ceq 'Adobe Acrobat Reader') {
        return $true
    }
    return $trimmed.StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)
}

function Get-AdobeReaderMsiProductCode {
    param($Products)
    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($product in @($Products)) {
        if ($null -eq $product) {
            continue
        }
        $names = @($product.PSObject.Properties.Name)
        if ($names -notcontains 'DisplayName' -or $names -notcontains 'ProductCode') {
            continue
        }
        if (-not (Test-AdobeReaderDisplayName -Name ([string]$product.DisplayName))) {
            continue
        }
        $code = [string]$product.ProductCode
        if ($code -cnotmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
            continue
        }
        if (-not $codes.Contains($code)) {
            $codes.Add($code)
        }
    }
    return @($codes.ToArray())
}

function Get-AdobeReaderInstalledVersionFromProducts {
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
        if (-not (Test-AdobeReaderDisplayName -Name $name)) {
            continue
        }
        if ($propNames -contains 'DisplayVersion') {
            $versionText = [string]$product.DisplayVersion
        }
        $parsed = Convert-AdobeReaderVersionText -Text $versionText
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
    return Format-AdobeReaderVersion -Version $best
}

function Read-AdobeReaderMarkerVersion {
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

function Write-AdobeReaderMarkerVersion {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Join-Path $Root 'marker.txt'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $Version, $utf8)
}

function Clear-AdobeReaderMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Join-Path $Root 'marker.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-AdobeReaderLogLine {
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

function Get-AdobeReaderProductCodeFromEntry {
    param(
        [string]$KeyName,
        [string]$UninstallString
    )
    $guid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
    if ($KeyName -match "^\{$guid\}$") {
        return $Matches[0]
    }
    if ($UninstallString -match "\{$guid\}") {
        return $Matches[0]
    }
    return ''
}

function Get-AdobeReaderRegistryMsiProduct {
    $results = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        $children = @()
        try {
            if (-not (Test-Path -LiteralPath $root -ErrorAction Stop)) {
                continue
            }
            $children = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)
        } catch {
            continue
        }
        foreach ($key in $children) {
            if ($null -eq $key) {
                continue
            }
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $propNames = @($props.PSObject.Properties.Name)
            $displayName = ''
            $displayVersion = ''
            $uninstall = ''
            $windowsInstaller = 0
            if ($propNames -contains 'DisplayName') {
                $displayName = [string]$props.DisplayName
            }
            if ($propNames -contains 'DisplayVersion') {
                $displayVersion = [string]$props.DisplayVersion
            }
            if ($propNames -contains 'UninstallString') {
                $uninstall = [string]$props.UninstallString
            }
            if ($propNames -contains 'WindowsInstaller' -and $null -ne $props.WindowsInstaller) {
                try {
                    $windowsInstaller = [int]$props.WindowsInstaller
                } catch {
                    $windowsInstaller = 0
                }
            }
            $isMsi = $windowsInstaller -eq 1 -or $uninstall -match '(?i)msiexec(\.exe)?'
            if (-not $isMsi) {
                continue
            }
            $code = Get-AdobeReaderProductCodeFromEntry -KeyName ([string]$key.PSChildName) -UninstallString $uninstall
            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }
            $results.Add([pscustomobject]@{
                    DisplayName    = $displayName
                    DisplayVersion = $displayVersion
                    ProductCode    = $code
                })
        }
    }
    return @($results.ToArray())
}

function Get-AdobeReaderInstalledVersion {
    return [string](Get-AdobeReaderInstalledVersionFromProducts -Products @(Get-AdobeReaderRegistryMsiProduct))
}

function Get-AdobeReaderMsiexecPath {
    $root = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        return 'msiexec.exe'
    }
    return Join-Path $root 'System32\msiexec.exe'
}

function Invoke-AdobeReaderAction {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerRoot,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath = '',
        [string]$InstallerPath = ''
    )

    $early = @(Get-AdobeReaderPreDispatchCode -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256)
    if ($early.Count -gt 0) {
        return [int]$early[-1]
    }

    $marker = Read-AdobeReaderMarkerVersion -Root $MarkerRoot
    $plan = Get-AdobeReaderPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $pendingLog = [string]$plan.Log
    if ($plan.RunInstaller -eq 'install') {
        if (-not (Test-AdobeReaderPathRooted -Path $InstallerPath)) {
            Add-AdobeReaderError -Message 'installer path is not a full path'
            return 1
        }
        $saved = [int](Save-AdobeReaderPayload -Url $InstallerUrl -Destination $InstallerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
        if ($saved -ne 0) {
            return $saved
        }
        if (-not (Test-Path -LiteralPath $InstallerPath)) {
            Add-AdobeReaderError -Message 'download failed for installer'
            return 1
        }
        if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
            return 130
        }
        $started = 1
        try {
            $started = [int](& $script:StartProcess -FilePath $InstallerPath -ArgumentList @(Get-AdobeReaderInstallArgumentList))
        } catch {
            Add-AdobeReaderError -Message 'installer failed to start'
            return 1
        }
        if (-not (Test-AdobeReaderProcessSuccess -ExitCode $started)) {
            return 1
        }
        try {
            $InstalledVersion = [string](& $script:ReadInstalledVersion)
        } catch {
            return 1
        }
        $marker = Read-AdobeReaderMarkerVersion -Root $MarkerRoot
        $reached = Get-AdobeReaderPlan -Action 'Install' -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
        if ($null -ne $reached.ExitCode -and [int]$reached.ExitCode -ne 0) {
            return [int]$reached.ExitCode
        }
        if ($reached.RunInstaller -eq 'install') {
            return 1
        }
        $plan = $reached
    }

    if ($plan.UninstallProduct) {
        if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
            return 130
        }
        try {
            $products = @(& $script:ListMsiProducts)
        } catch {
            Add-AdobeReaderError -Message 'Reader MSI product was not found'
            return 1
        }
        $codes = @(Get-AdobeReaderMsiProductCode -Products $products)
        if ($codes.Count -eq 0) {
            Add-AdobeReaderError -Message 'Reader MSI product was not found'
            return 1
        }
        $msiexec = Get-AdobeReaderMsiexecPath
        foreach ($productCode in $codes) {
            if (Test-AdobeReaderCancelled -CancelPath $CancelPath) {
                return 130
            }
            $argumentList = Get-AdobeReaderUninstallArgumentList -ProductCode $productCode
            if ($null -eq $argumentList) {
                Add-AdobeReaderError -Message 'Reader MSI product was not found'
                return 1
            }
            $started = 1
            try {
                $started = [int](& $script:StartProcess -FilePath $msiexec -ArgumentList @($argumentList))
            } catch {
                Add-AdobeReaderError -Message 'uninstall failed to start'
                return 1
            }
            if (-not (Test-AdobeReaderProcessSuccess -ExitCode $started)) {
                return 1
            }
        }
    }

    if ($plan.ClearMarker) {
        Clear-AdobeReaderMarker -Root $MarkerRoot
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        Write-AdobeReaderMarkerVersion -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
    }
    if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
        Add-AdobeReaderLogLine -Root $MarkerRoot -Line $pendingLog
    }
    return 0
}

function Test-AdobeReaderToolkitCancelled {
    param([string]$Detail)
    return $Detail -match '(^|\D)1602(\D|$)'
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
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:ReadInstalledVersion = {
    Get-AdobeReaderInstalledVersion
}

$script:ListMsiProducts = {
    @(Get-AdobeReaderRegistryMsiProduct)
}

$script:StartProcess = {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to start a process while a test is running'
    }
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return 1
    }
    $flat = @($ArgumentList | ForEach-Object { [string]$_ })
    $process = Start-Process -FilePath $FilePath -ArgumentList $flat -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -or $MyInvocation.InvocationName -eq '.') {
    return
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

$earlyExit = @(Get-AdobeReaderPreDispatchCode -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256)
if ($earlyExit.Count -gt 0) {
    exit [int]$earlyExit[-1]
}

if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
    $programData = [string]$env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        [Console]::Error.WriteLine('missing parameter MarkerRoot')
        exit 1
    }
    $MarkerRoot = Join-Path (Join-Path $programData 'Relian') 'adobe-reader'
}
if (-not (Test-Path -LiteralPath $MarkerRoot)) {
    New-Item -ItemType Directory -Path $MarkerRoot -Force | Out-Null
}

$installedNow = ''
try {
    $installedNow = [string](& $script:ReadInstalledVersion)
} catch {
    $installedNow = ''
}
$preview = Get-AdobeReaderPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerVersion (Read-AdobeReaderMarkerVersion -Root $MarkerRoot)
if ($null -ne $preview.ExitCode) {
    exit [int]$preview.ExitCode
}

$adtSession = @{
    AppVendor                 = 'Relian'
    AppName                   = 'Adobe Acrobat Reader'
    AppVersion                = $PinVersion
    RequireAdmin              = $true
    DeployAppScriptVersion    = '4.1.8'
    DeployAppScriptParameters = $PSBoundParameters
}

$cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-adobe-reader-' + [guid]::NewGuid().ToString('n'))
$installerPath = Join-Path $cache $script:AdobeReaderInstallerFile
try {
    try {
        $moduleManifest = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
        if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
            throw "missing PSAppDeployToolkit module at $moduleManifest"
        }
        Import-Module -FullyQualifiedName @{ ModuleName = $moduleManifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
        $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
        $adtSession = Open-ADTSession @adtSession -DeploymentType $DeploymentType -PassThru
    } catch {
        $detail = [string]$_.Exception.Message
        if (Test-AdobeReaderToolkitCancelled -Detail $detail) {
            exit 1
        }
        if ($detail -match '://') {
            $detail = 'adobe reader package failed'
        }
        [Console]::Error.WriteLine($detail)
        exit 1
    }

    $code = [int](Invoke-AdobeReaderAction -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerRoot $MarkerRoot -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -InstallerPath $installerPath)
    if ($code -ne 0) {
        exit $code
    }
    Close-ADTSession -ExitCode 0
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    if (Test-AdobeReaderToolkitCancelled -Detail $detail) {
        exit 1
    }
    if ($detail -match '://') {
        $detail = 'adobe reader package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($cache) -and (Test-Path -LiteralPath $cache)) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}
