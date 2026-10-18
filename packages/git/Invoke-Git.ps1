# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/git.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe',
    [string]$InstallerSha256 = '52188f917b378f00c70ec136bcf090005f30d44fbc4eba0bce759cc6592d60f6',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-GitVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-GitVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $trimmed = $Text.Trim()
    # DisplayVersion is 2.56.0.2. The release tag is 2.56.0.windows.2. Same build.
    if ($trimmed -match '^(\d+)\.(\d+)\.(\d+)\.windows\.(\d+)$') {
        $trimmed = '{0}.{1}.{2}.{3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]
    }
    try {
        return [version]$trimmed
    } catch {
        return 'invalid'
    }
}

function New-GitPlan {
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

function Get-GitPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-GitPlan -ExitCode 0
    }
    $pin = Convert-GitVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-GitPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-GitPlan -ExitCode 1
    }

    $installed = Convert-GitVersionText -Text $InstalledVersion
    $marker = Convert-GitVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-GitPlan -ExitCode 0
        }
        if (-not $present) {
            return New-GitPlan -ClearMarker $true -Log 'Uninstall'
        }
        return New-GitPlan -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall'
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-GitPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-GitVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-GitVersion -Version $marker
    }
    $pinText = Format-GitVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-GitPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-GitPlan -RunInstaller 'install' -Log 'Install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. Advance the marker and do not log an install.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-GitPlan -ExitCode 0
        }
        return New-GitPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-GitPlan -RunInstaller 'install' -Log 'Repair'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-GitPlan -ExitCode 0
            }
            return New-GitPlan -WriteMarker $write
        }
        return New-GitPlan -RunInstaller 'install' -Log 'Repair'
    }

    return New-GitPlan -ExitCode 1
}

$script:GitErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-GitError {
    param([string]$Message)
    if ($null -eq $script:GitErrorLog) {
        $script:GitErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:GitErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-GitUrlHasUserInfo {
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

function Test-GitCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-GitHttpStatus {
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

function Test-GitTransientTransport {
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

function Test-GitDownloadIsTransient {
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
    $status = Get-GitHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-GitTransientTransport -Exception $exception)
}

function Save-GitPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-GitUrlHasUserInfo -Url $Url) {
        Add-GitError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-GitCancelled -CancelPath $CancelPath) {
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
                Add-GitError -Message "hash mismatch for $Label"
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
            $status = Get-GitHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-GitDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-GitError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-GitError -Message "download wrote no file for $Label"
            } else {
                Add-GitError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-GitCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-GitCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-GitError -Message "download failed for $Label"
    return 1
}

function Get-GitMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Get-GitLogPath {
    param([string]$Root)
    return Join-Path $Root 'toolkit.log'
}

function Read-GitMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-GitMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-GitMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-GitMarkerPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $Version, $utf8)
}

function Add-GitLogLine {
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
    $path = Get-GitLogPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($path, ($Line + "`n"), $utf8)
}

function Remove-GitMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-GitMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-GitDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\git'
}

function Get-GitPropertyText {
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

function Get-GitUninstallExe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $quoted = [regex]::Match($Text, '"([^"]+)"')
    if ($quoted.Success) {
        return $quoted.Groups[1].Value
    }
    $token = ($Text.Trim() -split '\s+', 2)[0]
    if ([string]::IsNullOrWhiteSpace($token)) {
        return ''
    }
    return $token
}

function Find-GitRegistryProduct {
    $best = $null
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
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
            $displayName = (Get-GitPropertyText -Object $props -Name 'DisplayName').Trim()
            $publisher = (Get-GitPropertyText -Object $props -Name 'Publisher').Trim()
            if ($displayName -ne 'Git' -or $publisher -ne 'The Git Development Community') {
                continue
            }
            $versionText = (Get-GitPropertyText -Object $props -Name 'DisplayVersion').Trim()
            $quiet = Get-GitPropertyText -Object $props -Name 'QuietUninstallString'
            $uninstall = Get-GitPropertyText -Object $props -Name 'UninstallString'
            $exe = Get-GitUninstallExe -Text $quiet
            if ([string]::IsNullOrWhiteSpace($exe)) {
                $exe = Get-GitUninstallExe -Text $uninstall
            }
            $parsed = Convert-GitVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-GitVersion -Version $parsed
            }
            $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
            $hasExe = -not [string]::IsNullOrWhiteSpace($exe)
            if ($hasVersion -and $hasExe) {
                return [pscustomobject]@{ Version = $formatted; UninstallPath = $exe }
            }
            if ($null -eq $best -and ($hasVersion -or $hasExe)) {
                $best = [pscustomobject]@{ Version = $formatted; UninstallPath = $exe }
            }
        }
    }
    if ($null -ne $best) {
        return $best
    }
    # Written by the installer. Used only when the uninstall key has no version.
    $versionKeys = @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows'
    )
    foreach ($versionKey in $versionKeys) {
        if (-not (Test-Path -LiteralPath $versionKey)) {
            continue
        }
        try {
            $versionProps = Get-ItemProperty -LiteralPath $versionKey -ErrorAction Stop
            $current = (Get-GitPropertyText -Object $versionProps -Name 'CurrentVersion').Trim()
            $parsedCurrent = Convert-GitVersionText -Text $current
            if ($parsedCurrent -is [version]) {
                return [pscustomobject]@{
                    Version       = (Format-GitVersion -Version $parsedCurrent)
                    UninstallPath = ''
                }
            }
        } catch {
            continue
        }
    }
    return [pscustomobject]@{ Version = ''; UninstallPath = '' }
}

function Get-GitRegistryProduct {
    try {
        return Find-GitRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; UninstallPath = '' }
    }
}

# Publisher silent switches only. Option overrides and component lists are omitted,
# so the installer keeps its own defaults, including the system config it writes.
function Get-GitInstallArgumentList {
    return @(
        '/VERYSILENT',
        '/NORESTART',
        '/NOCANCEL',
        '/SP-',
        '/CLOSEAPPLICATIONS',
        '/RESTARTAPPLICATIONS'
    )
}

# Inno uninstaller. /VERYSILENT is the publisher's silent switch. /NORESTART does not reboot.
function Get-GitUninstallArgumentList {
    param([string]$UninstallPath)
    if ([string]::IsNullOrWhiteSpace($UninstallPath)) {
        return $null
    }
    return @('/VERYSILENT', '/NORESTART')
}

function Test-GitSetupSucceeded {
    param([int]$Code)
    # Inno Setup success is 0. /NORESTART keeps a reboot from being required.
    return $Code -eq 0
}

function Get-GitMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledGitVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-GitVersionText -Text $afterText
    $pin = Convert-GitVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-GitVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-GitVersion -Version $pin
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

$script:GetInstalledGitVersion = {
    return [string](Get-GitRegistryProduct).Version
}

$script:GetGitUninstallPath = {
    return [string](Get-GitRegistryProduct).UninstallPath
}

# The installer is only started from this hook. It is waited on and never killed.
$script:InvokeGitSetup = {
    param($Mode, $InstallerPath, $UninstallPath)
    $filePath = ''
    $argumentList = $null
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace([string]$UninstallPath)) {
            return 1
        }
        $filePath = [string]$UninstallPath
        $argumentList = @(Get-GitUninstallArgumentList -UninstallPath $filePath)
    } elseif ($Mode -eq 'install') {
        if ([string]::IsNullOrWhiteSpace([string]$InstallerPath)) {
            return 1
        }
        $filePath = [string]$InstallerPath
        $argumentList = @(Get-GitInstallArgumentList)
    } else {
        return 1
    }
    if ($null -eq $argumentList -or @($argumentList).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$argumentList[0])) {
        return 1
    }
    $process = Start-Process -FilePath $filePath -ArgumentList @($argumentList) -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

function Invoke-GitAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-GitDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledGitVersion)
    } catch {
        Add-GitError -Message 'could not read the installed Git version'
        return 1
    }
    $marker = Read-GitMarkerVersion -Root $MarkerRoot
    $plan = Get-GitPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-GitCancelled -CancelPath $CancelPath) {
        return 130
    }

    $pendingLog = [string]$plan.Log
    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            # An empty hash downloads nothing and does not start setup, including Repair.
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                return 0
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-git-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'Git-2.56.0.2-64-bit.exe'
            $downloaded = [int](Save-GitPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start setup.
            if (Test-GitCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeGitSetup -Mode 'install' -InstallerPath $installerPath -UninstallPath ''
            if ($null -eq $result -or -not (Test-GitSetupSucceeded -Code ([int]$result))) {
                Add-GitError -Message 'installer failed'
                return 1
            }
            $write = Get-GitMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-GitError -Message 'installer succeeded without a version'
                return 1
            }
            Write-GitMarker -Root $MarkerRoot -Version $write
            if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
                Add-GitLogLine -Root $MarkerRoot -Line $pendingLog
            }
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            # Uninstall does not download. An empty hash does not block it.
            if (Test-GitCancelled -CancelPath $CancelPath) {
                return 130
            }
            $uninstallPath = ''
            try {
                $uninstallPath = [string](& $script:GetGitUninstallPath)
            } catch {
                $uninstallPath = ''
            }
            if ([string]::IsNullOrWhiteSpace($uninstallPath)) {
                Add-GitError -Message 'missing uninstall program'
                return 1
            }
            $result = & $script:InvokeGitSetup -Mode 'uninstall' -InstallerPath '' -UninstallPath $uninstallPath
            if ($null -eq $result -or -not (Test-GitSetupSucceeded -Code ([int]$result))) {
                Add-GitError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-GitMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-GitMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
            Add-GitLogLine -Root $MarkerRoot -Line $pendingLog
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
                Add-GitError -Message 'could not remove the installer cache'
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
    $gitExit = [int](Invoke-GitAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $gitExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'git package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
