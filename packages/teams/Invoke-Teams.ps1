# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$BootstrapperUrl = 'https://relianpub.blob.core.windows.net/pub/sec/teamsbootstrapper-c9d1c68b1f9048e6d04bc4313a4036f91c255df0988c4d876f687b5c1140440d.exe',
    [string]$BootstrapperSha256 = 'c9d1c68b1f9048e6d04bc4313a4036f91c255df0988c4d876f687b5c1140440d',
    [string]$MsixUrl = 'https://relianpub.blob.core.windows.net/pub/sec/MSTeams-x64-1bd28e184c0ec8572a8674560cd3f00e7cef002fe4471ccb9198f50d57391993.msix',
    [string]$MsixSha256 = '1bd28e184c0ec8572a8674560cd3f00e7cef002fe4471ccb9198f50d57391993',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
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

function Test-TeamsDeferralBlock {
    param(
        [string[]]$SessionStates,
        [bool]$CloseProcessRunning,
        [bool]$DeferralAlreadyUsed
    )
    if (-not $CloseProcessRunning -or $DeferralAlreadyUsed) {
        return $false
    }
    $hasDisc = $false
    $hasActive = $false
    foreach ($state in @($SessionStates)) {
        if ($state -eq 'Disc') { $hasDisc = $true }
        if ($state -eq 'Active') { $hasActive = $true }
    }
    return $hasDisc -and -not $hasActive
}

function Get-TeamsCloseList {
    param([string[]]$RunningNames)
    $allowed = @('ms-teams', 'Teams', 'OUTLOOK')
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $allowed) {
        foreach ($running in @($RunningNames)) {
            if ([string]$running -ceq $name) {
                $found.Add($name)
                break
            }
        }
    }
    return @($found.ToArray())
}

function Get-TeamsNotice {
    param([string]$Action)
    if ($Action -eq 'Repair') {
        return 'Teams will close for a repair. You can wait once. The next run will close it and continue.'
    }
    if ($Action -eq 'Uninstall') {
        return 'Teams will close. You can wait once. The next run will close it and continue. This removes the Teams sign-in on this PC.'
    }
    return 'Teams will close for an update. You can wait once. The next run will close it and continue.'
}

function Get-TeamsInstalledVersion {
    $packages = @(Get-AppxPackage -Name 'MSTeams' -AllUsers -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        $parsed = Convert-TeamsVersionText -Text ([string]$package.Version)
        if ($parsed -is [version]) {
            return Format-TeamsVersion -Version $parsed
        }
    }
    return ''
}

function Test-TeamsToolkitCancelled {
    param([string]$Detail)
    return $Detail -match '(^|\D)1602(\D|$)'
}

function Read-TeamsMarkerVersion {
    param([string]$Root)
    $path = Join-Path $Root 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Test-TeamsClassicPresent {
    foreach ($code in @(Get-TeamsClassicProductCodes)) {
        $keys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        )
        foreach ($key in $keys) {
            if (Test-Path -LiteralPath $key) {
                return $true
            }
        }
    }
    return $false
}

$script:SetOptimizationKey = {
    $key = 'HKLM:\SOFTWARE\Microsoft\Teams'
    if (-not (Test-Path -LiteralPath $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    $current = $null
    try {
        $current = (Get-ItemProperty -LiteralPath $key -Name 'IsWVDEnvironment' -ErrorAction Stop).IsWVDEnvironment
    } catch {
        $current = $null
    }
    if ([string]$current -ne '1') {
        New-ItemProperty -LiteralPath $key -Name 'IsWVDEnvironment' -PropertyType DWord -Value 1 -Force | Out-Null
    }
    return 0
}

$script:StartBootstrapper = {
    $argumentList = @(Get-TeamsBootstrapperArgumentList -Mode $script:TeamsBootstrapperMode -MsixPath $script:TeamsMsixPath)
    if ($script:TeamsBootstrapperMode -eq 'install' -and -not (Test-TeamsPathRooted -Path $script:TeamsMsixPath)) {
        return 1
    }
    $process = Start-Process -FilePath $script:TeamsBootstrapperPath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

$script:ReregisterTeams = {
    $packages = @(Get-AppxPackage -Name 'MSTeams' -AllUsers -ErrorAction SilentlyContinue)
    if ($packages.Count -eq 0) {
        return 1
    }
    foreach ($package in $packages) {
        $manifest = Join-Path $package.InstallLocation 'AppXManifest.xml'
        Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
    }
    return 0
}

$script:RemoveClassicTeams = {
    foreach ($code in @(Get-TeamsClassicProductCodes)) {
        $uninstallKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        $wowKey = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        if (-not (Test-Path -LiteralPath $uninstallKey) -and -not (Test-Path -LiteralPath $wowKey)) {
            continue
        }
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/x', $code, '/quiet', '/norestart') -Wait -PassThru -WindowStyle Hidden
        if ($null -ne $process -and [int]$process.ExitCode -ne 0) {
            return 1
        }
    }
    $updater = Join-Path $env:LOCALAPPDATA 'Microsoft\Teams\Update.exe'
    if (Test-Path -LiteralPath $updater) {
        $process = Start-Process -FilePath $updater -ArgumentList (Get-TeamsClassicUserUninstall) -Wait -PassThru -WindowStyle Hidden
        if ($null -ne $process -and [int]$process.ExitCode -ne 0) {
            return 1
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
    $MarkerRoot = Join-Path $env:ProgramData 'Relian\teams'
}
if (-not (Test-Path -LiteralPath $MarkerRoot)) {
    New-Item -ItemType Directory -Path $MarkerRoot -Force | Out-Null
}

$runningNames = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
$closeList = @(Get-TeamsCloseList -RunningNames $runningNames)
$sessionStates = [System.Collections.Generic.List[string]]::new()
try {
    $query = & query.exe user 2>$null
    foreach ($line in @($query)) {
        if ($line -match '\sActive\s') { $sessionStates.Add('Active') }
        if ($line -match '\sDisc\s') { $sessionStates.Add('Disc') }
    }
} catch {
    $sessionStates.Clear()
}
if (Test-TeamsDeferralBlock -SessionStates $sessionStates.ToArray() -CloseProcessRunning ($closeList.Count -gt 0) -DeferralAlreadyUsed $false) {
    exit 1
}

$adtSession = @{
    AppVendor                 = 'Relian'
    AppName                   = 'Microsoft Teams'
    AppVersion                = $PinVersion
    AppProcessesToClose       = $closeList
    RequireAdmin              = $true
    DeployAppScriptVersion    = '4.1.8'
    DeployAppScriptParameters = $PSBoundParameters
}

$cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-teams-' + [guid]::NewGuid().ToString('n'))
try {
    try {
        $moduleManifest = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
        if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
            throw "missing PSAppDeployToolkit module at $moduleManifest"
        }
        Import-Module -FullyQualifiedName @{ ModuleName = $moduleManifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
        $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
        $adtSession = Open-ADTSession @adtSession -DeploymentType $DeploymentType -PassThru
        if ($closeList.Count -gt 0) {
            Show-ADTInstallationWelcome -CloseProcesses $closeList -AllowDefer -DeferTimes 1 -ForceWelcomeText (Get-TeamsNotice -Action $Action)
        }
    } catch {
        $detail = [string]$_.Exception.Message
        if (Test-TeamsToolkitCancelled -Detail $detail) {
            exit 1
        }
        [Console]::Error.WriteLine($detail)
        exit 1
    }

    $installed = Get-TeamsInstalledVersion
    $marker = Read-TeamsMarkerVersion -Root $MarkerRoot
    $classic = Test-TeamsClassicPresent
    $plan = Get-TeamsPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker -ClassicPresent $classic
    $opt = & $script:SetOptimizationKey
    if ([int]$opt -ne 0) {
        exit 1
    }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $script:TeamsBootstrapperPath = Join-Path $cache 'teamsbootstrapper.exe'
    $script:TeamsMsixPath = Join-Path $cache 'MSTeams-x64.msix'
    if ($plan.RunBootstrapper -eq 'install') {
        $script:TeamsBootstrapperMode = 'install'
        foreach ($payload in @(
                @{ Url = $BootstrapperUrl; Dest = $script:TeamsBootstrapperPath; Sha = $BootstrapperSha256; Label = 'bootstrapper' }
                @{ Url = $MsixUrl; Dest = $script:TeamsMsixPath; Sha = $MsixSha256; Label = 'msix' }
            )) {
            $downloaded = [int](Save-TeamsPayload -Url $payload.Url -Destination $payload.Dest -Sha256 $payload.Sha -Label $payload.Label -CancelPath $CancelPath)
            if ($downloaded -ne 0) { exit $downloaded }
        }
        $boot = & $script:StartBootstrapper
        if ([int]$boot -ne 0) { exit 1 }
        $installed = Get-TeamsInstalledVersion
        $plan = Get-TeamsPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker -ClassicPresent (Test-TeamsClassicPresent)
    } elseif ($plan.Reregister) {
        $registered = & $script:ReregisterTeams
        if ([int]$registered -ne 0) { exit 1 }
    } elseif ($plan.RunBootstrapper -eq 'uninstall') {
        $script:TeamsBootstrapperMode = 'uninstall'
        $downloaded = [int](Save-TeamsPayload -Url $BootstrapperUrl -Destination $script:TeamsBootstrapperPath -Sha256 $BootstrapperSha256 -Label 'bootstrapper' -CancelPath $CancelPath)
        if ($downloaded -ne 0) { exit $downloaded }
        $boot = & $script:StartBootstrapper
        if ([int]$boot -ne 0) { exit 1 }
    }
    if ($plan.RemoveClassic) {
        $removed = & $script:RemoveClassicTeams
        if ([int]$removed -ne 0) { exit 1 }
    }

    $markerFile = Join-Path $MarkerRoot 'marker.txt'
    $logFile = Join-Path $MarkerRoot 'toolkit.log'
    if ($plan.Log -eq 'Uninstall') {
        if (Test-Path -LiteralPath $markerFile) {
            Remove-Item -LiteralPath $markerFile -Force
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        [System.IO.File]::WriteAllText($markerFile, [string]$plan.WriteMarker)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$plan.Log)) {
        [System.IO.File]::AppendAllText($logFile, ([string]$plan.Log + "`n"))
    }
    Close-ADTSession -ExitCode 0
    exit 0
} catch {
    $detail = [string]$_.Exception.Message
    if (Test-TeamsToolkitCancelled -Detail $detail) {
        exit 1
    }
    [Console]::Error.WriteLine($detail)
    exit 1
} finally {
    if (Test-Path -LiteralPath $cache) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}
