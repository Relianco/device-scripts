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
    [string]$PinVersion
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
        [Parameter(Mandatory)][string]$WorkRoot
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
        $result = & $script:InvokePackage -ScriptPath $ScriptPath -DeploymentType $step.DeploymentType -Action $step.Action -PinVersion $PinVersion -WorkRoot $WorkRoot
        if ($null -eq $result) {
            return 1
        }
        $code = [int]$result
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
        [Parameter(Mandatory)][string]$PinVersion
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

        [void](& $script:DownloadFile -Url $PackageUrl -Destination $packageFile)
        [void](& $script:DownloadFile -Url $ToolkitUrl -Destination $toolkitFile)
        [void](& $script:DownloadFile -Url $BrandPackUrl -Destination $brandFile)

        $pins = @(
            [pscustomobject]@{ Path = $packageFile; Expected = $PackageSha256; Label = 'package' }
            [pscustomobject]@{ Path = $toolkitFile; Expected = $ToolkitSha256; Label = 'toolkit' }
            [pscustomobject]@{ Path = $brandFile; Expected = $BrandPackSha256; Label = 'brand pack' }
        )
        $verified = $true
        foreach ($pin in $pins) {
            if (-not (Test-Path -LiteralPath $pin.Path)) {
                Write-RelianRunnerError "download wrote no file for $($pin.Label)"
                $verified = $false
                break
            }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $pin.Path).Hash
            if (-not $actual.Equals([string]$pin.Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-RelianRunnerError "hash mismatch for $($pin.Label)"
                $verified = $false
                break
            }
        }

        if ($verified) {
            [void](& $script:ExpandArchive -Path $toolkitFile -Destination $work)
            [void](& $script:ExpandArchive -Path $brandFile -Destination $work)
            $scriptPath = Join-Path $work 'Invoke-Package.ps1'
            [System.IO.File]::Copy($packageFile, $scriptPath, $true)
            $exitCode = [int](Invoke-RelianPackageSequence -ScriptPath $scriptPath -Action $Action -PinVersion $PinVersion -WorkRoot $work)
        }
    } catch {
        Write-RelianRunnerError $_.Exception.Message
        $exitCode = 1
    } finally {
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
    Write-RelianRunnerError $_.Exception.Message
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
