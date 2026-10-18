# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. Defaults are copied from
# releases/edge.json. The runner downloads this script without that file.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/bf3e7059-ee35-457f-946e-42963960692d/MicrosoftEdgeEnterpriseX64.msi',
    [string]$InstallerSha256 = '20119979eb1670f670d38c093fd1c61f5a91d880c473f8614825ce9aef35f68a',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:EdgeErrorLog = [System.Collections.Generic.List[string]]::new()

function Format-EdgeVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-EdgeVersionText {
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

function New-EdgePlan {
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

function Get-EdgePlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-EdgePlan -ExitCode 0
    }
    $pin = Convert-EdgeVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-EdgePlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-EdgePlan -ExitCode 1
    }

    $installed = Convert-EdgeVersionText -Text $InstalledVersion
    $marker = Convert-EdgeVersionText -Text $MarkerVersion
    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-EdgePlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-EdgeVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-EdgeVersion -Version $marker
    }
    $pinText = Format-EdgeVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-EdgePlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-EdgePlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        return New-EdgePlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed -or $installed.CompareTo($pin) -le 0) {
            return New-EdgePlan -RunInstaller 'install' -Log 'Repair'
        }
        $write = ''
        if ($markerText -cne $installedText) {
            $write = $installedText
        }
        return New-EdgePlan -WriteMarker $write
    }

    if ($normalized -eq 'Uninstall') {
        if ($null -eq $installed) {
            if (-not [string]::IsNullOrWhiteSpace($markerText)) {
                return New-EdgePlan -ClearMarker $true -Log 'Uninstall'
            }
            return New-EdgePlan -ExitCode 0
        }
        return New-EdgePlan -UninstallProduct $true -ClearMarker $true -Log 'Uninstall'
    }

    return New-EdgePlan -ExitCode 1
}

function Add-EdgeError {
    param([string]$Message)
    if ($null -eq $script:EdgeErrorLog) {
        $script:EdgeErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:EdgeErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-EdgeUrlHasUserInfo {
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

function Test-EdgeCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-EdgeHttpStatus {
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

function Test-EdgeTransientTransport {
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

function Test-EdgeDownloadIsTransient {
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
    $status = Get-EdgeHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-EdgeTransientTransport -Exception $exception)
}

function Save-EdgePayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    if (Test-EdgeUrlHasUserInfo -Url $Url) {
        Add-EdgeError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-EdgeCancelled -CancelPath $CancelPath) {
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
                Add-EdgeError -Message "hash mismatch for $Label"
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
            $status = Get-EdgeHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-EdgeDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-EdgeError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-EdgeError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-EdgeCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-EdgeCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-EdgeError -Message "download failed for $Label"
    return 1
}

function Test-EdgePathRooted {
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

function Get-EdgeInstallArgumentList {
    param([string]$InstallerPath)
    return @('/i', $InstallerPath, '/quiet', '/norestart')
}

function Get-EdgeUninstallArgumentList {
    param([string]$ProductCode)
    return @('/x', $ProductCode, '/quiet', '/norestart')
}

function Test-EdgeMsiexecSuccess {
    param([int]$ExitCode)
    # 3010 means the MSI finished and a reboot is still required.
    return $ExitCode -eq 0 -or $ExitCode -eq 3010
}

function Test-EdgeExcludedProductCode {
    param([string]$ProductCode)
    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return $true
    }
    # WebView2's Edge Update app id. Never pass it to msiexec /x.
    $webview = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    return $ProductCode.Trim().Equals($webview, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-EdgeMsiDisplayName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $trimmed = $Name.Trim()
    if ($trimmed -like '*WebView*') {
        return $false
    }
    return $trimmed -eq 'Microsoft Edge'
}

function Get-EdgeMsiProductCode {
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
        if (-not (Test-EdgeMsiDisplayName -Name ([string]$product.DisplayName))) {
            continue
        }
        $code = [string]$product.ProductCode
        if ($code -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
            continue
        }
        if (Test-EdgeExcludedProductCode -ProductCode $code) {
            continue
        }
        if (-not $codes.Contains($code)) {
            $codes.Add($code)
        }
    }
    return @($codes.ToArray())
}

function Read-EdgeMarkerVersion {
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

function Write-EdgeMarkerVersion {
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

function Clear-EdgeMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Join-Path $Root 'marker.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-EdgeLogLine {
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

function Get-EdgeInstalledVersion {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\BLBeacon'
    )
    foreach ($key in $keys) {
        try {
            if (-not (Test-Path -LiteralPath $key -ErrorAction Stop)) {
                continue
            }
            $raw = (Get-ItemProperty -LiteralPath $key -Name 'version' -ErrorAction Stop).version
        } catch {
            continue
        }
        $parsed = Convert-EdgeVersionText -Text ([string]$raw)
        if ($parsed -is [version]) {
            return Format-EdgeVersion -Version $parsed
        }
    }
    return ''
}

function Get-EdgeProductCodeFromEntry {
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

function Get-EdgeRegistryMsiProduct {
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
            $uninstall = ''
            $windowsInstaller = 0
            if ($propNames -contains 'DisplayName') {
                $displayName = [string]$props.DisplayName
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
            $code = Get-EdgeProductCodeFromEntry -KeyName ([string]$key.PSChildName) -UninstallString $uninstall
            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }
            $results.Add([pscustomobject]@{
                    DisplayName = $displayName
                    ProductCode = $code
                })
        }
    }
    return @($results.ToArray())
}

function Invoke-EdgeAction {
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

    $marker = Read-EdgeMarkerVersion -Root $MarkerRoot
    $plan = Get-EdgePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $pendingLog = [string]$plan.Log
    if ($plan.RunInstaller -eq 'install') {
        if (-not (Test-EdgePathRooted -Path $InstallerPath)) {
            Add-EdgeError -Message 'installer path is not a full path'
            return 1
        }
        $saved = [int](Save-EdgePayload -Url $InstallerUrl -Destination $InstallerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
        if ($saved -ne 0) {
            return $saved
        }
        if (-not (Test-Path -LiteralPath $InstallerPath)) {
            Add-EdgeError -Message 'download failed for installer'
            return 1
        }
        if (Test-EdgeCancelled -CancelPath $CancelPath) {
            return 130
        }
        $msiexec = 1
        try {
            $msiexec = [int](& $script:StartMsiexec -ArgumentList @(Get-EdgeInstallArgumentList -InstallerPath $InstallerPath))
        } catch {
            Add-EdgeError -Message 'installer failed to start'
            return 1
        }
        if (-not (Test-EdgeMsiexecSuccess -ExitCode $msiexec)) {
            return 1
        }
        try {
            $InstalledVersion = [string](& $script:ReadInstalledVersion)
        } catch {
            return 1
        }
        $marker = Read-EdgeMarkerVersion -Root $MarkerRoot
        $reached = Get-EdgePlan -Action 'Install' -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
        if ($null -ne $reached.ExitCode -and [int]$reached.ExitCode -ne 0) {
            return [int]$reached.ExitCode
        }
        if ($reached.RunInstaller -eq 'install') {
            return 1
        }
        $plan = $reached
    }

    if ($plan.UninstallProduct) {
        if (Test-EdgeCancelled -CancelPath $CancelPath) {
            return 130
        }
        try {
            $products = @(& $script:ListMsiProducts)
        } catch {
            Add-EdgeError -Message 'Edge MSI product was not found'
            return 1
        }
        $codes = @(Get-EdgeMsiProductCode -Products $products)
        if ($codes.Count -eq 0) {
            Add-EdgeError -Message 'Edge MSI product was not found'
            return 1
        }
        foreach ($productCode in $codes) {
            if (Test-EdgeCancelled -CancelPath $CancelPath) {
                return 130
            }
            $msiexec = 1
            try {
                $msiexec = [int](& $script:StartMsiexec -ArgumentList @(Get-EdgeUninstallArgumentList -ProductCode $productCode))
            } catch {
                Add-EdgeError -Message 'uninstall failed to start'
                return 1
            }
            if (-not (Test-EdgeMsiexecSuccess -ExitCode $msiexec)) {
                return 1
            }
        }
    }

    if ($plan.ClearMarker) {
        Clear-EdgeMarker -Root $MarkerRoot
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        Write-EdgeMarkerVersion -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
    }
    if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
        Add-EdgeLogLine -Root $MarkerRoot -Line $pendingLog
    }
    return 0
}

function Test-EdgeToolkitCancelled {
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
    Get-EdgeInstalledVersion
}

$script:ListMsiProducts = {
    @(Get-EdgeRegistryMsiProduct)
}

$script:StartMsiexec = {
    param([string[]]$ArgumentList)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        throw 'refusing to start msiexec while a test is running'
    }
    $root = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        return 1
    }
    $exe = Join-Path $root 'System32\msiexec.exe'
    $flat = @($ArgumentList | ForEach-Object { [string]$_ })
    $process = Start-Process -FilePath $exe -ArgumentList $flat -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
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

if ([string]::IsNullOrWhiteSpace($PinVersion) -or $Action -eq 'Reinstall') {
    $decision = Get-EdgePlan -Action $Action -PinVersion $PinVersion -InstalledVersion '' -MarkerVersion ''
    exit [int]$decision.ExitCode
}

if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
    $programData = [string]$env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        [Console]::Error.WriteLine('missing parameter MarkerRoot')
        exit 1
    }
    $MarkerRoot = Join-Path (Join-Path $programData 'Relian') 'edge'
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
$preview = Get-EdgePlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerVersion (Read-EdgeMarkerVersion -Root $MarkerRoot)
if ($null -ne $preview.ExitCode) {
    exit [int]$preview.ExitCode
}

$adtSession = @{
    AppVendor                 = 'Relian'
    AppName                   = 'Microsoft Edge'
    AppVersion                = $PinVersion
    RequireAdmin              = $true
    DeployAppScriptVersion    = '4.1.8'
    DeployAppScriptParameters = $PSBoundParameters
}

$cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-edge-' + [guid]::NewGuid().ToString('n'))
$installerPath = Join-Path $cache 'MicrosoftEdgeEnterpriseX64.msi'
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
        if (Test-EdgeToolkitCancelled -Detail $detail) {
            exit 1
        }
        [Console]::Error.WriteLine($detail)
        exit 1
    }

    $code = [int](Invoke-EdgeAction -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerRoot $MarkerRoot -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -InstallerPath $installerPath)
    if ($code -ne 0) {
        exit $code
    }
    Close-ADTSession -ExitCode 0
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    if (Test-EdgeToolkitCancelled -Detail $detail) {
        exit 1
    }
    [Console]::Error.WriteLine($detail)
    exit 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($cache) -and (Test-Path -LiteralPath $cache)) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}
