# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/wau.json.
# The runner copies this script alone, so the values are inlined.
# Winget-AutoUpdate (WAU) runs winget as SYSTEM from a scheduled task. This package pins WAU,
# turns its self-update off, and runs it in allow-list mode with the list read from ListUrl.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$ListUrl = '',
    [string]$UpdatesAtTime = '12:00:00',
    [string]$AvdUpdatesAtTime = '02:00:00',
    [string]$InstallerUrl = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi',
    [string]$InstallerSha256 = 'f5ab2303fdf82fbfcb2248cca4f96479fe17d74584a528b0f86b3dbe9f9e9718',
    [string]$CancelPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WauUpgradeCode = '{BDDEA607-F4AF-4229-8610-16E3B6455FDC}'
# Intune's default return code for "retry later". Used when winget is missing.
$script:WauRetryExitCode = 1618

function Format-WauVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-WauVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return [version](Format-WauVersion -Version ([version]($Text.Trim())))
    } catch {
        return 'invalid'
    }
}

# Only a ring folder under Relian's public WAU container. No userinfo, query, port or other host.
function Test-WauListUrl {
    param([string]$Url)
    if ([string]::IsNullOrEmpty($Url)) {
        return $false
    }
    return $Url -cmatch '\Ahttps://relianpub\.blob\.core\.windows\.net/pub/wau/[a-z0-9][a-z0-9-]{0,31}/?\z'
}

function Test-WauTimeText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    return $Text -cmatch '\A([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\z'
}

# Windows Enterprise multi-session (AVD) reports EditionID ServerRdsh.
function Test-WauMultiSession {
    param([string]$EditionId)
    return $EditionId -ceq 'ServerRdsh'
}

# The MSI properties, in the order they go on the msiexec command line.
function Get-WauMsiProperties {
    param(
        [bool]$MultiSession,
        [string]$ListUrl,
        [string]$UpdatesAtTime,
        [string]$AvdUpdatesAtTime
    )
    $atLogon = '1'
    $time = $UpdatesAtTime
    $delay = '02:00'
    if ($MultiSession) {
        # Every user logon on a multi-session host would start a run.
        $atLogon = '0'
        $time = $AvdUpdatesAtTime
        $delay = '00:30'
    }
    $props = [ordered]@{}
    # WAU's self-update installs GitHub's latest WAU.msi as SYSTEM with no hash check. Relian bumps the pin.
    $props['DISABLEWAUAUTOUPDATE'] = '1'
    $props['USEWHITELIST'] = '1'
    $props['LISTPATH'] = $ListUrl
    $props['UPDATESINTERVAL'] = 'Daily'
    $props['UPDATESATTIME'] = $time
    $props['UPDATESATTIMEDELAY'] = $delay
    $props['UPDATESATLOGON'] = $atLogon
    # Intune skips user-context work on multi-session. Everything runs as SYSTEM.
    $props['USERCONTEXT'] = '0'
    $props['NOTIFICATIONLEVEL'] = 'None'
    $props['DONOTRUNONMETERED'] = '1'
    $props['MAXLOGFILES'] = '7'
    $props['MAXLOGSIZE'] = '1048576'
    $props['RUN_WAU'] = 'NO'
    return $props
}

# Registry values the MSI writes from the properties above, as WAU reads them back.
function Get-WauExpectedConfig {
    param($Properties)
    return [ordered]@{
        WAU_DisableAutoUpdate = $Properties['DISABLEWAUAUTOUPDATE']
        WAU_UseWhiteList      = $Properties['USEWHITELIST']
        WAU_ListPath          = $Properties['LISTPATH']
        WAU_UpdatesInterval   = $Properties['UPDATESINTERVAL']
        WAU_UpdatesAtTime     = $Properties['UPDATESATTIME']
        WAU_UpdatesTimeDelay  = $Properties['UPDATESATTIMEDELAY']
        WAU_UpdatesAtLogon    = $Properties['UPDATESATLOGON']
        WAU_UserContext       = $Properties['USERCONTEXT']
        WAU_NotificationLevel = $Properties['NOTIFICATIONLEVEL']
    }
}

# Config is the effective WAU config (install values with policy values on top), as a dictionary.
function Test-WauConfigMatches {
    param(
        $Config,
        $Expected
    )
    if ($null -eq $Config) {
        return $false
    }
    foreach ($name in @($Expected.Keys)) {
        if (-not $Config.Contains($name) -or $null -eq $Config[$name]) {
            return $false
        }
        if (([string]$Config[$name]).Trim() -cne [string]$Expected[$name]) {
            return $false
        }
    }
    return $true
}

function New-WauPlan {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = ''
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
    }
}

# RunInstaller: 'install' (fresh or upgrade), 'reconfigure' (same version, new settings), 'uninstall'.
function Get-WauPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [bool]$ConfigMatches,
        [bool]$WingetPresent
    )
    $pin = Convert-WauVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return New-WauPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-WauPlan -ExitCode 1
    }
    if ($Action -eq 'Uninstall') {
        if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
            return New-WauPlan -ExitCode 0
        }
        return New-WauPlan -RunInstaller 'uninstall'
    }
    if (@('Install', 'Update', 'Repair') -notcontains $Action) {
        return New-WauPlan -ExitCode 1
    }
    $installed = Convert-WauVersionText -Text $InstalledVersion
    if ($null -ne $installed -and $installed -isnot [version]) {
        return New-WauPlan -ExitCode 1
    }
    if ($null -ne $installed) {
        $compared = $installed.CompareTo($pin)
        if ($compared -gt 0) {
            # The pinned MSI blocks a downgrade. A newer WAU is not this package's; bump the pin.
            if ($ConfigMatches) {
                return New-WauPlan -ExitCode 0
            }
            return New-WauPlan -ExitCode 1
        }
        if ($compared -eq 0 -and $ConfigMatches -and $Action -ne 'Repair') {
            return New-WauPlan -ExitCode 0
        }
    }
    # WAU's own prerequisite step downloads winget unpinned when it is missing. Wait for the winget package.
    if (-not $WingetPresent) {
        return New-WauPlan -ExitCode $script:WauRetryExitCode
    }
    if ($null -ne $installed -and $installed.CompareTo($pin) -eq 0) {
        return New-WauPlan -RunInstaller 'reconfigure'
    }
    return New-WauPlan -RunInstaller 'install'
}

function Get-WauMsiArgumentList {
    param(
        [string]$Mode,
        [string]$InstallerPath,
        [string]$ProductCode,
        $Properties
    )
    # msiexec /i installs and /x uninstalls. /qn is no UI. /norestart does not reboot.
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }
        return @('/x', $ProductCode, '/qn', '/norestart')
    }
    if ([string]::IsNullOrWhiteSpace($InstallerPath) -or $null -eq $Properties) {
        return $null
    }
    # Start-Process joins ArgumentList with spaces. Quotes keep a path with spaces as one argument.
    $list = [System.Collections.Generic.List[string]]::new()
    $list.AddRange([string[]]@('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart'))
    foreach ($name in @($Properties.Keys)) {
        $value = [string]$Properties[$name]
        # Every value is validated or fixed. A space or quote would split or break the command line.
        if ($value -match '[\s"]') {
            return $null
        }
        $list.Add(('{0}={1}' -f $name, $value))
    }
    if ($Mode -eq 'reconfigure') {
        # Same version: rewrite every file and the HKLM values, and re-run WAU's task setup.
        $list.Add('REINSTALL=ALL')
        $list.Add('REINSTALLMODE=vamus')
    } elseif ($Mode -ne 'install') {
        return $null
    }
    return $list.ToArray()
}

function Test-WauMsiSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The installer is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

$script:WauErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-WauError {
    param([string]$Message)
    if ($null -eq $script:WauErrorLog) {
        $script:WauErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:WauErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-WauUrlHasUserInfo {
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

function Test-WauCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-WauHttpStatus {
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

function Test-WauSocketIsTransient {
    param($Exception)
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    # Timeout, connection, and DNS only. AddressAlreadyInUse is not retried.
    $code = $Exception.SocketErrorCode
    $retry = @(
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::ConnectionAborted,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::HostNotFound
    )
    return $retry -contains $code
}

function Test-WauTransientTransport {
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
        # A bare TaskCanceledException is not a timeout. Retry only when a TimeoutException is inside it.
        if ($current -is [System.TimeoutException] -or (Test-WauSocketIsTransient -Exception $current)) {
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

function Test-WauDownloadIsTransient {
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
    $status = Get-WauHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-WauTransientTransport -Exception $exception)
}

function Test-WauPinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    # -cnotmatch is case-sensitive, so uppercase hex is not a pin.
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # 64 identical nibbles, including 64 zeros or 64 a's, is a placeholder.
    if ($text -cnotmatch '^(.)\1{63}$') {
        return $true
    }
    return $false
}

function Save-WauPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )
    if (Test-WauUrlHasUserInfo -Url $Url) {
        Add-WauError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if (-not (Test-WauPinHash -Sha256 $Sha256)) {
        Add-WauError -Message "invalid hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-WauCancelled -CancelPath $CancelPath) {
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
                # A mismatch is not retried. The pin or the release asset is wrong.
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Add-WauError -Message "hash mismatch for $Label"
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
            $status = Get-WauHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-WauDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-WauError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-WauError -Message "download wrote no file for $Label"
            } else {
                Add-WauError -Message "download failed for $Label"
            }
            return 1
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
    }
    Add-WauError -Message "download failed for $Label"
    return 1
}

# Reads one HKLM key in the 64-bit view, so a 32-bit host reads what the x64 MSI wrote.
function Read-WauRegistryValues {
    param([string]$SubKey)
    $values = @{}
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return $null
        }
        try {
            foreach ($name in $key.GetValueNames()) {
                $values[$name] = $key.GetValue($name)
            }
        } finally {
            $key.Dispose()
        }
    } finally {
        $base.Dispose()
    }
    return $values
}

# WAU's Get-WAUConfig: install values, then policy values on top.
function Merge-WauConfig {
    param(
        $Installed,
        $Policy
    )
    if ($null -eq $Installed) {
        return $null
    }
    $merged = @{}
    foreach ($name in @($Installed.Keys)) {
        $merged[$name] = $Installed[$name]
    }
    if ($null -ne $Policy) {
        foreach ($name in @($Policy.Keys)) {
            $merged[$name] = $Policy[$name]
        }
    }
    return $merged
}

$script:DownloadFile = {
    param($Url, $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetWauConfig = {
    $installed = Read-WauRegistryValues -SubKey 'SOFTWARE\Romanitho\Winget-AutoUpdate'
    $policy = Read-WauRegistryValues -SubKey 'SOFTWARE\Policies\Romanitho\Winget-AutoUpdate'
    return Merge-WauConfig -Installed $installed -Policy $policy
}

$script:GetEditionId = {
    $values = Read-WauRegistryValues -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($null -eq $values -or -not $values.ContainsKey('EditionID')) {
        return ''
    }
    return [string]$values['EditionID']
}

# The same path WAU's Get-WingetCmd uses for the SYSTEM context. ProgramW6432 is right from a 32-bit host.
$script:TestWingetPresent = {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    $pattern = Join-Path $programFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe'
    return [bool](@(Get-Item -Path $pattern -ErrorAction SilentlyContinue).Count -gt 0)
}

$script:GetWauProductCodes = {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    return @($installer.RelatedProducts($script:WauUpgradeCode))
}

# The MSI copies a Mods folder and an included/excluded list from its working directory, and the
# mods run as SYSTEM. The cache is SYSTEM and Administrators only, so no user can place them there.
$script:ProtectDirectory = {
    param($Path)
    $icacls = 'icacls.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    }
    & $icacls $Path '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    return $LASTEXITCODE
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($ArgumentList, $WorkingDirectory)
    $exe = 'msiexec.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

# The link's own attributes, not its target's, so a link to a missing log is still found. Missing is $null.
function Get-WauLinkAttributes {
    param([string]$Path)
    try {
        return [System.IO.File]::GetAttributes($Path)
    } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

# WAU 2.12.0 no longer makes the IME log link its README describes. Intune "Collect diagnostics"
# takes the IME Logs folder, so the package links WAU's log there.
$script:SetImeLogLink = {
    param($InstallLocation)
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        return 'skipped'
    }
    $imeLogs = Join-Path $programData 'Microsoft\IntuneManagementExtension\Logs'
    if (-not (Test-Path -LiteralPath $imeLogs)) {
        return 'skipped'
    }
    $link = Join-Path $imeLogs 'WAU-updates.log'
    $target = Join-Path $InstallLocation 'logs\updates.log'
    $existing = Get-WauLinkAttributes -Path $link
    if ($null -ne $existing) {
        if (-not ($existing -band [System.IO.FileAttributes]::ReparsePoint)) {
            # A real file of that name is someone's log. Leave it.
            return 'skipped'
        }
        [System.IO.File]::Delete($link)
    }
    # WAU makes its log on its first run, after install (RUN_WAU=NO). Windows PowerShell 5.1's
    # New-Item refuses a link to a missing target; mklink does not.
    $cmd = 'cmd.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    }
    & $cmd /d /c mklink $link $target | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "mklink exited $LASTEXITCODE"
    }
    return 'linked'
}

$script:RemoveImeLogLink = {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        return
    }
    $link = Join-Path $programData 'Microsoft\IntuneManagementExtension\Logs\WAU-updates.log'
    # After msiexec /x the link points at nothing.
    $existing = Get-WauLinkAttributes -Path $link
    if ($null -ne $existing -and ($existing -band [System.IO.FileAttributes]::ReparsePoint)) {
        [System.IO.File]::Delete($link)
    }
}

function Get-WauInstalledVersion {
    param($Config)
    if ($null -eq $Config -or -not $Config.ContainsKey('ProductVersion') -or $null -eq $Config['ProductVersion']) {
        return ''
    }
    return ([string]$Config['ProductVersion']).Trim()
}

function Invoke-WauAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$ListUrl,
        [string]$UpdatesAtTime,
        [string]$AvdUpdatesAtTime,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath
    )

    # Empty hash disables every action, including Uninstall, before validation or any change.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }
    if (-not (Test-WauPinHash -Sha256 $InstallerSha256)) {
        Add-WauError -Message 'invalid hash for installer'
        return 1
    }
    if ($Action -ne 'Uninstall') {
        if (Test-WauUrlHasUserInfo -Url $InstallerUrl) {
            Add-WauError -Message 'refusing a URL that contains userinfo for installer'
            return 1
        }
        if (Test-WauUrlHasUserInfo -Url $ListUrl) {
            Add-WauError -Message 'refusing a URL that contains userinfo for the list'
            return 1
        }
        if (-not (Test-WauListUrl -Url $ListUrl)) {
            Add-WauError -Message 'ListUrl must be a ring folder under https://relianpub.blob.core.windows.net/pub/wau/'
            return 1
        }
        if (-not (Test-WauTimeText -Text $UpdatesAtTime) -or -not (Test-WauTimeText -Text $AvdUpdatesAtTime)) {
            Add-WauError -Message 'update times must be HH:mm:ss'
            return 1
        }
    }

    $config = $null
    try {
        $config = & $script:GetWauConfig
    } catch {
        Add-WauError -Message 'could not read the WAU config'
        return 1
    }
    $installed = Get-WauInstalledVersion -Config $config

    $properties = $null
    $expected = $null
    $configMatches = $false
    $wingetPresent = $false
    if ($Action -ne 'Uninstall') {
        $edition = ''
        try {
            $edition = [string](& $script:GetEditionId)
        } catch {
            Add-WauError -Message 'could not read the Windows edition'
            return 1
        }
        $properties = Get-WauMsiProperties -MultiSession (Test-WauMultiSession -EditionId $edition) -ListUrl $ListUrl -UpdatesAtTime $UpdatesAtTime -AvdUpdatesAtTime $AvdUpdatesAtTime
        $expected = Get-WauExpectedConfig -Properties $properties
        $configMatches = [bool](Test-WauConfigMatches -Config $config -Expected $expected)
        try {
            $wingetPresent = [bool](& $script:TestWingetPresent)
        } catch {
            $wingetPresent = $false
        }
    }

    $plan = Get-WauPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -ConfigMatches $configMatches -WingetPresent $wingetPresent
    if ($null -ne $plan.ExitCode) {
        if ([int]$plan.ExitCode -eq $script:WauRetryExitCode) {
            Add-WauError -Message 'winget is not installed yet; retry after the winget package'
        } elseif ([int]$plan.ExitCode -ne 0) {
            Add-WauError -Message 'no plan for this action and installed version'
        }
        return [int]$plan.ExitCode
    }
    if (Test-WauCancelled -CancelPath $CancelPath) {
        return 130
    }

    if ($plan.RunInstaller -eq 'uninstall') {
        $codes = @()
        try {
            $codes = @(& $script:GetWauProductCodes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        } catch {
            $codes = @()
        }
        if ($codes.Count -eq 0) {
            Add-WauError -Message 'missing product code for uninstall'
            return 1
        }
        foreach ($code in $codes) {
            $argumentList = Get-WauMsiArgumentList -Mode 'uninstall' -ProductCode ([string]$code)
            $result = & $script:InvokeMsiExec -ArgumentList $argumentList -WorkingDirectory ([System.IO.Path]::GetTempPath())
            if ($null -eq $result -or -not (Test-WauMsiSucceeded -Code ([int]$result))) {
                Add-WauError -Message 'uninstall failed'
                return 1
            }
        }
        try {
            & $script:RemoveImeLogLink
        } catch {
            Add-WauError -Message 'could not remove the IME log link'
        }
        return 0
    }

    $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-wau-' + [guid]::NewGuid().ToString('n'))
    try {
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $protected = & $script:ProtectDirectory -Path $cache
        if ([int]$protected -ne 0) {
            Add-WauError -Message 'could not restrict the installer cache'
            return 1
        }
        $installerPath = Join-Path $cache 'WAU.msi'
        $downloaded = [int](Save-WauPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
        if ($downloaded -ne 0) {
            return $downloaded
        }
        # A cancel after the file is verified must not start msiexec.
        if (Test-WauCancelled -CancelPath $CancelPath) {
            return 130
        }
        $argumentList = Get-WauMsiArgumentList -Mode $plan.RunInstaller -InstallerPath $installerPath -Properties $properties
        if ($null -eq $argumentList) {
            Add-WauError -Message 'could not build the installer command line'
            return 1
        }
        $result = & $script:InvokeMsiExec -ArgumentList $argumentList -WorkingDirectory $cache
        if ($null -eq $result -or -not (Test-WauMsiSucceeded -Code ([int]$result))) {
            Add-WauError -Message "installer failed with exit code $result"
            return 1
        }
        $after = $null
        try {
            $after = & $script:GetWauConfig
        } catch {
            $after = $null
        }
        $afterVersion = Convert-WauVersionText -Text (Get-WauInstalledVersion -Config $after)
        $pin = Convert-WauVersionText -Text $PinVersion
        if ($afterVersion -isnot [version] -or $afterVersion.CompareTo($pin) -lt 0) {
            Add-WauError -Message 'installer succeeded but WAU is not at the pin'
            return 1
        }
        if (-not (Test-WauConfigMatches -Config $after -Expected $expected)) {
            # A WAU policy under HKLM\SOFTWARE\Policies overrides what the MSI wrote.
            Add-WauError -Message 'installer succeeded but the WAU config does not match (check WAU policies)'
            return 1
        }
        try {
            $location = ''
            if ($after.ContainsKey('InstallLocation')) {
                $location = [string]$after['InstallLocation']
            }
            if (-not [string]::IsNullOrWhiteSpace($location)) {
                [void](& $script:SetImeLogLink -InstallLocation $location)
            }
        } catch {
            # The log link is for diagnostics. WAU runs without it.
            Add-WauError -Message 'could not link the WAU log into the IME log folder'
        }
        return 0
    } finally {
        # A locked cache file must not turn a finished install into a failure.
        try {
            if (Test-Path -LiteralPath $cache) {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
            }
        } catch {
            Add-WauError -Message 'could not remove the installer cache'
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation. The URL is not read.
if ($PSBoundParameters.ContainsKey('InstallerSha256') -and [string]::IsNullOrWhiteSpace($InstallerSha256)) {
    exit 0
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $wauExit = [int](Invoke-WauAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -ListUrl $ListUrl -UpdatesAtTime $UpdatesAtTime -AvdUpdatesAtTime $AvdUpdatesAtTime -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath)
    exit $wauExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'WAU package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
