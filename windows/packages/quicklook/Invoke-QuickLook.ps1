# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. Defaults are copied from
# windows/releases/quicklook.json. The runner downloads this script without that file.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://github.com/QL-Win/QuickLook/releases/download/4.5.0/QuickLook-4.5.0.msi',
    [string]$InstallerSha256 = '130f601eab7c388025351312f949749adebc6429b1042bd2001ac32a17a2748c',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:QuickLookErrorLog = [System.Collections.Generic.List[string]]::new()

function Format-QuickLookVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-QuickLookVersionText {
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

function New-QuickLookPlan {
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

function Get-QuickLookPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-QuickLookPlan -ExitCode 0
    }
    $pin = Convert-QuickLookVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-QuickLookPlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-QuickLookPlan -ExitCode 1
    }

    $installed = Convert-QuickLookVersionText -Text $InstalledVersion
    $marker = Convert-QuickLookVersionText -Text $MarkerVersion
    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-QuickLookPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-QuickLookVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-QuickLookVersion -Version $marker
    }
    $pinText = Format-QuickLookVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-QuickLookPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-QuickLookPlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. Advance the marker and do not log Install.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        return New-QuickLookPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed -or $installed.CompareTo($pin) -le 0) {
            return New-QuickLookPlan -RunInstaller 'install' -Log 'Repair'
        }
        $write = ''
        if ($markerText -cne $installedText) {
            $write = $installedText
        }
        return New-QuickLookPlan -WriteMarker $write
    }

    if ($normalized -eq 'Uninstall') {
        if ($null -eq $installed) {
            if (-not [string]::IsNullOrWhiteSpace($markerText)) {
                return New-QuickLookPlan -ClearMarker $true -Log 'Uninstall'
            }
            return New-QuickLookPlan -ExitCode 0
        }
        return New-QuickLookPlan -UninstallProduct $true -ClearMarker $true -Log 'Uninstall'
    }

    return New-QuickLookPlan -ExitCode 1
}

function Add-QuickLookError {
    param([string]$Message)
    if ($null -eq $script:QuickLookErrorLog) {
        $script:QuickLookErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:QuickLookErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-QuickLookUrlHasUserInfo {
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

function Test-QuickLookCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-QuickLookHttpStatus {
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

function Test-QuickLookSocketIsRetryable {
    param($Exception)
    # SocketException() keeps the last native error. Only refused, reset, timeout, and DNS are retried.
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    $code = $Exception.SocketErrorCode
    return $code -eq [System.Net.Sockets.SocketError]::ConnectionRefused -or
        $code -eq [System.Net.Sockets.SocketError]::ConnectionReset -or
        $code -eq [System.Net.Sockets.SocketError]::TimedOut -or
        $code -eq [System.Net.Sockets.SocketError]::HostNotFound
}

function Test-QuickLookTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    # SecureConnectionError is a connection failure and stays retryable.
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # A bare TaskCanceledException is ordinary cancellation. Retry it only when it wraps TimeoutException.
        if ($current -is [System.TimeoutException] -or (Test-QuickLookSocketIsRetryable -Exception $current)) {
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

function Test-QuickLookDownloadIsTransient {
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
    $status = Get-QuickLookHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-QuickLookTransientTransport -Exception $exception)
}

function Test-QuickLookSha256Text {
    param([string]$Sha256)
    $text = ([string]$Sha256).Trim()
    # -cnotmatch is case-sensitive. -notmatch would accept uppercase hex.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # A repeated character is a placeholder, including 64 zeroes and 64 a's.
    if ($text -ceq ($text.Substring(0, 1) * 64)) {
        return $false
    }
    return $true
}

function Save-QuickLookPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-QuickLookUrlHasUserInfo -Url $Url) {
        Add-QuickLookError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (-not (Test-QuickLookSha256Text -Sha256 $Sha256)) {
        Add-QuickLookError -Message "invalid hash for $Label"
        return 1
    }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-QuickLookCancelled -CancelPath $CancelPath) {
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
            if ($actual -cnotmatch ('^{0}$' -f [regex]::Escape($expected))) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Add-QuickLookError -Message "hash mismatch for $Label"
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
            $status = Get-QuickLookHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-QuickLookDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-QuickLookError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-QuickLookError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-QuickLookCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-QuickLookCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-QuickLookError -Message "download failed for $Label"
    return 1
}

function Test-QuickLookPathRooted {
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

function Get-QuickLookInstallArgumentList {
    param([string]$InstallerPath)
    # The MSI path is quoted so a TEMP directory with spaces is one msiexec argument.
    # Per-machine install is ALLUSERS=1. No custom directory and no basic UI.
    $quoted = '"{0}"' -f $InstallerPath
    return @('/i', $quoted, '/qn', '/norestart', 'ALLUSERS=1')
}

function Get-QuickLookUninstallArgumentList {
    param([string]$ProductCode)
    return @('/x', $ProductCode, '/qn', '/norestart', 'ALLUSERS=1')
}

function Get-QuickLookMsiexecCommandLine {
    param([string[]]$ArgumentList)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($ArgumentList)) {
        $parts.Add([string]$part)
    }
    return ($parts.ToArray() -join ' ')
}

function Test-QuickLookMsiexecSuccess {
    param([int]$ExitCode)
    # 3010 means the MSI finished and a reboot is still required.
    return $ExitCode -eq 0 -or $ExitCode -eq 3010
}

function Test-QuickLookMsiDisplayName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name.Trim() -ceq 'QuickLook'
}

function Get-QuickLookMsiProductCode {
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
        if (-not (Test-QuickLookMsiDisplayName -Name ([string]$product.DisplayName))) {
            continue
        }
        $code = [string]$product.ProductCode
        if ($code -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
            continue
        }
        if (-not $codes.Contains($code)) {
            $codes.Add($code)
        }
    }
    return @($codes.ToArray())
}

function Read-QuickLookMarkerVersion {
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

function Write-QuickLookMarkerVersion {
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

function Clear-QuickLookMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Join-Path $Root 'marker.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-QuickLookLogLine {
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

function Get-QuickLookProductCodeFromEntry {
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

function Get-QuickLookRegistryMsiProduct {
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
            $displayVersion = ''
            $windowsInstaller = 0
            if ($propNames -contains 'DisplayName') {
                $displayName = [string]$props.DisplayName
            }
            if ($propNames -contains 'UninstallString') {
                $uninstall = [string]$props.UninstallString
            }
            if ($propNames -contains 'DisplayVersion') {
                $displayVersion = [string]$props.DisplayVersion
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
            $code = Get-QuickLookProductCodeFromEntry -KeyName ([string]$key.PSChildName) -UninstallString $uninstall
            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }
            $results.Add([pscustomobject]@{
                    DisplayName    = $displayName
                    ProductCode    = $code
                    DisplayVersion = $displayVersion
                })
        }
    }
    return @($results.ToArray())
}

function Get-QuickLookInstalledVersion {
    $best = $null
    try {
        $products = @(Get-QuickLookRegistryMsiProduct)
    } catch {
        return ''
    }
    foreach ($product in $products) {
        if ($null -eq $product) {
            continue
        }
        $names = @($product.PSObject.Properties.Name)
        if ($names -notcontains 'DisplayName' -or $names -notcontains 'DisplayVersion') {
            continue
        }
        if (-not (Test-QuickLookMsiDisplayName -Name ([string]$product.DisplayName))) {
            continue
        }
        $parsed = Convert-QuickLookVersionText -Text ([string]$product.DisplayVersion)
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
    return Format-QuickLookVersion -Version $best
}

function Invoke-QuickLookAction {
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

    # An empty hash disables every action, including Uninstall, before dispatch.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }

    $marker = Read-QuickLookMarkerVersion -Root $MarkerRoot
    $plan = Get-QuickLookPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $pendingLog = [string]$plan.Log
    if ($plan.RunInstaller -eq 'install') {
        if (-not (Test-QuickLookPathRooted -Path $InstallerPath)) {
            Add-QuickLookError -Message 'installer path is not a full path'
            return 1
        }
        $saved = [int](Save-QuickLookPayload -Url $InstallerUrl -Destination $InstallerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
        if ($saved -ne 0) {
            return $saved
        }
        if (-not (Test-Path -LiteralPath $InstallerPath)) {
            Add-QuickLookError -Message 'download failed for installer'
            return 1
        }
        if (Test-QuickLookCancelled -CancelPath $CancelPath) {
            return 130
        }
        $installArgs = @(Get-QuickLookInstallArgumentList -InstallerPath $InstallerPath)
        $msiexec = 1
        try {
            $msiexec = [int](& $script:StartMsiexec -ArgumentList $installArgs)
        } catch {
            Add-QuickLookError -Message 'installer failed to start'
            return 1
        }
        if (-not (Test-QuickLookMsiexecSuccess -ExitCode $msiexec)) {
            return 1
        }
        try {
            $InstalledVersion = [string](& $script:ReadInstalledVersion)
        } catch {
            return 1
        }
        $marker = Read-QuickLookMarkerVersion -Root $MarkerRoot
        $reached = Get-QuickLookPlan -Action 'Install' -PinVersion $PinVersion -InstalledVersion $InstalledVersion -MarkerVersion $marker
        if ($null -ne $reached.ExitCode -and [int]$reached.ExitCode -ne 0) {
            return [int]$reached.ExitCode
        }
        if ($reached.RunInstaller -eq 'install') {
            return 1
        }
        $plan = $reached
    }

    if ($plan.UninstallProduct) {
        if (Test-QuickLookCancelled -CancelPath $CancelPath) {
            return 130
        }
        try {
            $products = @(& $script:ListMsiProducts)
        } catch {
            Add-QuickLookError -Message 'QuickLook MSI product was not found'
            return 1
        }
        $codes = @(Get-QuickLookMsiProductCode -Products $products)
        if ($codes.Count -eq 0) {
            Add-QuickLookError -Message 'QuickLook MSI product was not found'
            return 1
        }
        foreach ($productCode in $codes) {
            if (Test-QuickLookCancelled -CancelPath $CancelPath) {
                return 130
            }
            $removeArgs = @(Get-QuickLookUninstallArgumentList -ProductCode $productCode)
            $msiexec = 1
            try {
                $msiexec = [int](& $script:StartMsiexec -ArgumentList $removeArgs)
            } catch {
                Add-QuickLookError -Message 'uninstall failed to start'
                return 1
            }
            if (-not (Test-QuickLookMsiexecSuccess -ExitCode $msiexec)) {
                return 1
            }
        }
    }

    if ($plan.ClearMarker) {
        Clear-QuickLookMarker -Root $MarkerRoot
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        Write-QuickLookMarkerVersion -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
    }
    if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
        Add-QuickLookLogLine -Root $MarkerRoot -Line $pendingLog
    }
    return 0
}

function Test-QuickLookToolkitCancelled {
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
    try {
        return [string](Get-QuickLookInstalledVersion)
    } catch {
        return ''
    }
}

$script:ListMsiProducts = {
    try {
        return @(Get-QuickLookRegistryMsiProduct)
    } catch {
        return @()
    }
}

# msiexec is only started from this hook. It is waited on and never killed.
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
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.Arguments = Get-QuickLookMsiexecCommandLine -ArgumentList $ArgumentList
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        return 1
    }
    $null = $process.WaitForExit()
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

# Empty hash exits before action dispatch, including Uninstall and Reinstall.
if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
    exit 0
}

if ([string]::IsNullOrWhiteSpace($PinVersion) -or $Action -eq 'Reinstall') {
    $decision = Get-QuickLookPlan -Action $Action -PinVersion $PinVersion -InstalledVersion '' -MarkerVersion ''
    exit [int]$decision.ExitCode
}

if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
    $programData = [string]$env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        [Console]::Error.WriteLine('missing parameter MarkerRoot')
        exit 1
    }
    $MarkerRoot = Join-Path (Join-Path $programData 'Relian') 'quicklook'
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
$preview = Get-QuickLookPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerVersion (Read-QuickLookMarkerVersion -Root $MarkerRoot)
if ($null -ne $preview.ExitCode) {
    exit [int]$preview.ExitCode
}

$adtSession = @{
    AppVendor                 = 'Relian'
    AppName                   = 'QuickLook'
    AppVersion                = $PinVersion
    RequireAdmin              = $true
    DeployAppScriptVersion    = '4.1.8'
    DeployAppScriptParameters = $PSBoundParameters
}

$cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-quicklook-' + [guid]::NewGuid().ToString('n'))
$installerPath = Join-Path $cache 'QuickLook-4.5.0.msi'
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
        if (Test-QuickLookToolkitCancelled -Detail $detail) {
            exit 1
        }
        if ($detail -match '://') {
            $detail = 'quicklook package failed'
        }
        [Console]::Error.WriteLine($detail)
        exit 1
    }

    $code = [int](Invoke-QuickLookAction -Action $Action -PinVersion $PinVersion -InstalledVersion $installedNow -MarkerRoot $MarkerRoot -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -InstallerPath $installerPath)
    if ($code -ne 0) {
        exit $code
    }
    Close-ADTSession -ExitCode 0
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    if (Test-QuickLookToolkitCancelled -Detail $detail) {
        exit 1
    }
    if ($detail -match '://') {
        $detail = 'quicklook package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($cache) -and (Test-Path -LiteralPath $cache)) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}
