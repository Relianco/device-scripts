# Script parameters are not Mandatory: a mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. Invoke-RelianRunner is Mandatory.
[CmdletBinding()]
param(
    [string]$PackageUrl,
    [AllowEmptyString()][string]$PackageSha256,
    [string]$ToolkitUrl,
    [AllowEmptyString()][string]$ToolkitSha256,
    [string]$BrandPackUrl,
    [AllowEmptyString()][string]$BrandPackSha256,
    [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
    [string]$Action,
    [string]$PinVersion,
    [AllowEmptyString()][string]$CancelPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-RelianRunnerError {
    param([Parameter(Mandatory)][string]$Message)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        return
    }
    [Console]::Error.WriteLine($Message)
}

function Write-RelianRunnerDetail {
    param(
        [AllowEmptyString()][string]$Message,
        [string[]]$Urls
    )
    $text = [string]$Message
    foreach ($url in @($Urls)) {
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }
        $text = $text.Replace($url, 'a download URL')
    }
    Write-RelianRunnerError $text
}

function Test-RelianUrlHasUserInfo {
    param([Parameter(Mandatory)][string]$Url)
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

function Test-RelianCancelled {
    param([AllowEmptyString()][string]$CancelPath)
    return [bool](& $script:TestCancel -CancelPath $CancelPath)
}

function Get-RelianHttpStatus {
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

function Test-RelianTransientTransport {
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

function Test-RelianDownloadIsTransient {
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
    $status = Get-RelianHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-RelianTransientTransport -Exception $exception)
}

function Invoke-RelianDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$CancelPath
    )

    # Three attempts. Waits are 5s then 20s. The URL is never written to the error text.
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-RelianCancelled -CancelPath $CancelPath) {
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
            return 0
        }
        $status = $null
        $transient = $false
        if ($null -ne $thrown) {
            $status = Get-RelianHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-RelianDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Write-RelianRunnerError "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Write-RelianRunnerError "download wrote no file for $Label"
            } else {
                Write-RelianRunnerError "download failed for $Label"
            }
            return 1
        }
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
        if ($exists) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Write-RelianRunnerError "download failed for $Label"
    return 1
}

function Remove-RelianDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-RelianRunnerError $_.Exception.Message
    }
}

function Invoke-RelianPackageSequence {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$PinVersion,
        [Parameter(Mandatory)][string]$WorkRoot,
        [AllowEmptyString()][string]$CancelPath = ''
    )

    # Reinstall is one uninstall followed by one install. Do not pass Action Reinstall.
    $steps = [System.Collections.Generic.List[object]]::new()
    if ($Action -eq 'Install') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Install' })
    } elseif ($Action -eq 'Update') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Update' })
    } elseif ($Action -eq 'Repair') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Repair'; Action = 'Repair' })
    } elseif ($Action -eq 'Uninstall') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Uninstall'; Action = 'Uninstall' })
    } elseif ($Action -eq 'Reinstall') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Uninstall'; Action = 'Uninstall' })
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Install' })
    } else {
        throw "unsupported action $Action"
    }

    $code = 0
    foreach ($step in $steps) {
        # Checked before the call. A package process that has started is not stopped.
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
        $result = & $script:InvokePackage -ScriptPath $ScriptPath -DeploymentType $step.DeploymentType -Action $step.Action -PinVersion $PinVersion -WorkRoot $WorkRoot
        if ($null -eq $result) {
            return 1
        }
        $code = [int]$result
        # 1602 is a toolkit deferral. Map it to 1 and do not continue.
        if ($code -eq 1602) {
            return 1
        }
        if ($code -ne 0) {
            return $code
        }
    }
    return $code
}

$script:DownloadFile = {
    param($Url, $Destination)
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}

$script:ExpandArchive = {
    param($Path, $Destination)
    Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
}

$script:RelianCancelPath = ''
$script:RetryDelay = {
    param($Seconds)
    # Callers pass 5 then 20. Sleep one second at a time so cancel is visible during the wait.
    $remaining = [int]$Seconds
    while ($remaining -gt 0) {
        if (& $script:TestCancel -CancelPath $script:RelianCancelPath) {
            return
        }
        Start-Sleep -Seconds 1
        $remaining = $remaining - 1
    }
}

$script:TestCancel = {
    param($CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

# Child process so a package exit does not end a second reinstall call.
# Executable is this host process. Windows PowerShell 5.1 has no pwsh on PATH
# and rejects -WorkingDirectory. The package path is absolute.
$script:InvokePackage = {
    param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot)
    $hostPath = $null
    $current = [System.Diagnostics.Process]::GetCurrentProcess()
    if ($null -ne $current.MainModule) {
        $hostPath = $current.MainModule.FileName
    }
    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        $hostPath = (Get-Process -Id $PID).Path
    }
    & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-RelianRunner {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PackageSha256,
        [Parameter(Mandatory)][string]$ToolkitUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ToolkitSha256,
        [Parameter(Mandatory)][string]$BrandPackUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BrandPackSha256,
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
        [string]$Action,
        [Parameter(Mandatory)][string]$PinVersion,
        [AllowEmptyString()][string]$CancelPath = ''
    )

    foreach ($url in @($PackageUrl, $ToolkitUrl, $BrandPackUrl)) {
        if (Test-RelianUrlHasUserInfo -Url $url) {
            Write-RelianRunnerError 'refusing a URL that contains userinfo'
            return 1
        }
    }

    if ([string]::IsNullOrWhiteSpace($PackageSha256) -or
        [string]::IsNullOrWhiteSpace($ToolkitSha256) -or
        [string]::IsNullOrWhiteSpace($BrandPackSha256)) {
        return 0
    }

    if (Test-RelianCancelled -CancelPath $CancelPath) {
        return 130
    }

    $script:RelianCancelPath = [string]$CancelPath
    $keep = $env:RELIAN_DEPLOY_KEEP_WORK -eq '1'
    $stamp = [guid]::NewGuid().ToString('n')
    $tempRoot = [System.IO.Path]::GetTempPath()
    $stage = Join-Path $tempRoot ('relian-runner-stage-' + $stamp)
    $work = Join-Path $tempRoot ('relian-runner-' + $stamp)
    $exitCode = 1
    try {
        [void](New-Item -ItemType Directory -Path $stage)
        [void](New-Item -ItemType Directory -Path $work)

        $packageFile = Join-Path $stage 'package.ps1'
        $toolkitFile = Join-Path $stage 'toolkit.zip'
        $brandFile = Join-Path $stage 'brand.zip'

        $pins = @(
            [pscustomobject]@{ Url = $PackageUrl; Path = $packageFile; Expected = $PackageSha256; Label = 'package' }
            [pscustomobject]@{ Url = $ToolkitUrl; Path = $toolkitFile; Expected = $ToolkitSha256; Label = 'toolkit' }
            [pscustomobject]@{ Url = $BrandPackUrl; Path = $brandFile; Expected = $BrandPackSha256; Label = 'brand pack' }
        )
        $verified = $true
        foreach ($pin in $pins) {
            $downloadCode = [int](Invoke-RelianDownload -Url $pin.Url -Destination $pin.Path -Label $pin.Label -CancelPath $CancelPath)
            if ($downloadCode -ne 0) {
                $exitCode = $downloadCode
                $verified = $false
                break
            }
            # A hash mismatch is not retried, and the remaining pins are not downloaded.
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $pin.Path).Hash
            if (-not $actual.Equals([string]$pin.Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-RelianRunnerError "hash mismatch for $($pin.Label)"
                $exitCode = 1
                $verified = $false
                break
            }
        }

        if ($verified) {
            [void](& $script:ExpandArchive -Path $toolkitFile -Destination $work)
            [void](& $script:ExpandArchive -Path $brandFile -Destination $work)
            $scriptPath = Join-Path $work 'Invoke-Package.ps1'
            [System.IO.File]::Copy($packageFile, $scriptPath, $true)
            $exitCode = [int](Invoke-RelianPackageSequence -ScriptPath $scriptPath -Action $Action -PinVersion $PinVersion -WorkRoot $work -CancelPath $CancelPath)
        }
    } catch {
        Write-RelianRunnerDetail -Message $_.Exception.Message -Urls @($PackageUrl, $ToolkitUrl, $BrandPackUrl)
        $exitCode = 1
    } finally {
        $script:RelianCancelPath = ''
        Remove-RelianDirectory -Path $stage
        if (-not $keep) {
            Remove-RelianDirectory -Path $work
        }
    }
    return [int]$exitCode
}

# Dot-sourcing under test defines functions and does not download.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$required = @(
    'PackageUrl', 'PackageSha256', 'ToolkitUrl', 'ToolkitSha256',
    'BrandPackUrl', 'BrandPackSha256', 'Action', 'PinVersion'
)
foreach ($name in $required) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        Write-RelianRunnerError "missing parameter $name"
        if ($MyInvocation.InvocationName -ne '.') {
            exit 1
        }
        return
    }
}

$script:ExitCode = 1
try {
    $script:ExitCode = [int](Invoke-RelianRunner @PSBoundParameters)
} catch {
    $urls = @()
    foreach ($secretName in @('PackageUrl', 'ToolkitUrl', 'BrandPackUrl')) {
        if ($PSBoundParameters.ContainsKey($secretName)) {
            $urls += [string]$PSBoundParameters[$secretName]
        }
    }
    Write-RelianRunnerDetail -Message $_.Exception.Message -Urls $urls
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
