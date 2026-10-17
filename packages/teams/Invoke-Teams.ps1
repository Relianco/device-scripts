# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-TeamsVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-TeamsVersionText {
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

function New-TeamsPlan {
    param(
        $ExitCode = $null,
        [string]$RunBootstrapper = '',
        [bool]$RemoveClassic = $false,
        [bool]$Reregister = $false,
        [string]$WriteMarker = '',
        [string]$Log = ''
    )
    return [pscustomobject]@{
        ExitCode        = $ExitCode
        RunBootstrapper = $RunBootstrapper
        RemoveClassic   = $RemoveClassic
        Reregister      = $Reregister
        WriteMarker     = $WriteMarker
        Log             = $Log
    }
}

function Get-TeamsPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion,
        [bool]$ClassicPresent
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-TeamsPlan -ExitCode 0
    }
    $pin = Convert-TeamsVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-TeamsPlan -ExitCode 1
    }
    if ($Action -eq 'Reinstall') {
        return New-TeamsPlan -ExitCode 1
    }

    $installed = Convert-TeamsVersionText -Text $InstalledVersion
    $marker = Convert-TeamsVersionText -Text $MarkerVersion
    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-TeamsPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-TeamsVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-TeamsVersion -Version $marker
    }
    $pinText = Format-TeamsVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-TeamsPlan -RunBootstrapper 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-TeamsPlan -RunBootstrapper 'install'
        }
        $write = ''
        if ($compared -gt 0) {
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        return New-TeamsPlan -RemoveClassic:$ClassicPresent -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-TeamsPlan -ExitCode 1
        }
        $write = ''
        if ($installed.CompareTo($pin) -gt 0 -and $markerText -cne $installedText) {
            $write = $installedText
        }
        return New-TeamsPlan -RemoveClassic:$ClassicPresent -Reregister $true -WriteMarker $write -Log 'Repair'
    }

    if ($normalized -eq 'Uninstall') {
        if ($null -eq $installed) {
            if (-not [string]::IsNullOrWhiteSpace($markerText)) {
                return New-TeamsPlan -Log 'Uninstall'
            }
            return New-TeamsPlan -ExitCode 0
        }
        return New-TeamsPlan -RunBootstrapper 'uninstall' -RemoveClassic:$ClassicPresent -Log 'Uninstall'
    }

    return New-TeamsPlan -ExitCode 1
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

function Add-TeamsError {
    param([string]$Message)
    if ($null -eq $script:TeamsErrorLog) {
        $script:TeamsErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:TeamsErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-TeamsUrlHasUserInfo {
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

function Test-TeamsCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-TeamsHttpStatus {
    param($Exception)
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            try {
                $parsed = [int]$current.StatusCode
                if ($parsed -ge 100 -and $parsed -le 599) {
                    return $parsed
                }
            } catch {
                $parsed = $null
            }
        }
        $current = $current.InnerException
    }
    return $null
}

function Test-TeamsTransientTransport {
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

function Test-TeamsDownloadIsTransient {
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
    $status = Get-TeamsHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-TeamsTransientTransport -Exception $exception)
}

function Save-TeamsPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-TeamsUrlHasUserInfo -Url $Url) {
        Add-TeamsError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-TeamsCancelled -CancelPath $CancelPath) {
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
                Add-TeamsError -Message "hash mismatch for $Label"
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
            $status = Get-TeamsHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-TeamsDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-TeamsError -Message "download failed with HTTP $status for $Label"
            } else {
                Add-TeamsError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-TeamsCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-TeamsCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-TeamsError -Message "download failed for $Label"
    return 1
}

function Test-TeamsPathRooted {
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

function Get-TeamsBootstrapperArgumentList {
    param(
        [string]$Mode,
        [string]$MsixPath
    )
    if ($Mode -eq 'uninstall') {
        return @('-x')
    }
    if ($Mode -ne 'install') {
        return $null
    }
    if (-not (Test-TeamsPathRooted -Path $MsixPath)) {
        return $null
    }
    return @('-p', '-o', $MsixPath, '--installTMA')
}

function Get-TeamsClassicProductCodes {
    return @(
        '{731F6BAA-A986-45A4-8936-7C3AAAAA760B}',
        '{39AF0813-FA7B-4860-ADBE-93B9B214B914}'
    )
}

function Get-TeamsClassicUserUninstall {
    return '-uninstall -s'
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}
