# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl, InstallerSha256, and SetupSha256 are the pin in
# windows/releases/microsoft-365.json. The runner copies this script alone, so the
# values and configuration.xml are inlined. setup.exe downloads the Office
# payloads at install time. Those payloads are not pinned.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20326-20112.exe',
    [string]$InstallerSha256 = 'fbb64358fd4168acd52ee4efe47ffd032b6231dfb415ae2dce61b0e58ba67f86',
    [string]$SetupSha256 = '50facf295f357d8230b4d50678536148e32f34b4ac33387269d5a72c93ff810a',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Microsoft365ErrorLog = [System.Collections.Generic.List[string]]::new()
$script:Microsoft365ArchiveName = 'officedeploymenttool_20326-20112.exe'

function Format-Microsoft365Version {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-Microsoft365VersionText {
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

function New-Microsoft365Plan {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
    }
}

function Get-Microsoft365Plan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-Microsoft365Plan -ExitCode 0
    }
    $pin = Convert-Microsoft365VersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-Microsoft365Plan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-Microsoft365Plan -ExitCode 1
    }

    $installed = Convert-Microsoft365VersionText -Text $InstalledVersion
    $marker = Convert-Microsoft365VersionText -Text $MarkerVersion

    # Uninstall does not compare versions. A non-empty install string is present.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-Microsoft365Plan -ExitCode 0
        }
        if (-not $present) {
            return New-Microsoft365Plan -ClearMarker $true
        }
        return New-Microsoft365Plan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-Microsoft365Plan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-Microsoft365Version -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-Microsoft365Version -Version $marker
    }
    $pinText = Format-Microsoft365Version -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-Microsoft365Plan -RunInstaller 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-Microsoft365Plan -RunInstaller 'install'
        }
        $write = ''
        if ($compared -gt 0) {
            # Vendor-newer stays installed. Record that version and do not run setup.
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-Microsoft365Plan -ExitCode 0
        }
        return New-Microsoft365Plan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-Microsoft365Plan -RunInstaller 'install'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-Microsoft365Plan -ExitCode 0
            }
            return New-Microsoft365Plan -WriteMarker $write
        }
        return New-Microsoft365Plan -RunInstaller 'install'
    }

    return New-Microsoft365Plan -ExitCode 1
}

function Add-Microsoft365Error {
    param([string]$Message)
    if ($null -eq $script:Microsoft365ErrorLog) {
        $script:Microsoft365ErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:Microsoft365ErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-Microsoft365UrlHasUserInfo {
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

function Test-Microsoft365Cancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-Microsoft365HttpStatus {
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

function Test-Microsoft365TransientTransport {
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

function Test-Microsoft365DownloadIsTransient {
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
    $status = Get-Microsoft365HttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-Microsoft365TransientTransport -Exception $exception)
}

function Test-Microsoft365PinHash {
    param([string]$Sha256)
    $text = ([string]$Sha256).Trim().ToLowerInvariant()
    if ($text -notmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # All zeros, any repeated nibble, and deadbeef are placeholders, not file pins.
    if ($text -match '^(.)\1{63}$' -or $text -eq ('deadbeef' * 8)) {
        return $false
    }
    return $true
}

function Save-Microsoft365Payload {
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
    if (Test-Microsoft365UrlHasUserInfo -Url $Url) {
        Add-Microsoft365Error -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if (-not (Test-Microsoft365PinHash -Sha256 $Sha256)) {
        Add-Microsoft365Error -Message "refusing a placeholder hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
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
                Add-Microsoft365Error -Message "hash mismatch for $Label"
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
            $status = Get-Microsoft365HttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-Microsoft365DownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-Microsoft365Error -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-Microsoft365Error -Message "download wrote no file for $Label"
            } else {
                Add-Microsoft365Error -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-Microsoft365Error -Message "download failed for $Label"
    return 1
}

function Get-Microsoft365MarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-Microsoft365MarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-Microsoft365MarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-Microsoft365Marker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-Microsoft365MarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-Microsoft365Marker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-Microsoft365MarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-Microsoft365DefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\microsoft-365'
}

function Get-Microsoft365PropertyText {
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

function Find-Microsoft365InstalledVersion {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }
        $props = $null
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        } catch {
            continue
        }
        $ids = (Get-Microsoft365PropertyText -Object $props -Name 'ProductReleaseIds')
        $tokens = @($ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tokens -notcontains 'O365ProPlusRetail') {
            continue
        }
        $versionText = (Get-Microsoft365PropertyText -Object $props -Name 'VersionToReport').Trim()
        $parsed = Convert-Microsoft365VersionText -Text $versionText
        if ($parsed -is [version]) {
            return Format-Microsoft365Version -Version $parsed
        }
    }

    # Display names are the enterprise apps this package installs, not Windows.
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
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
            $displayName = (Get-Microsoft365PropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -notlike 'Microsoft 365 Apps for enterprise*') {
                continue
            }
            $versionText = (Get-Microsoft365PropertyText -Object $props -Name 'DisplayVersion').Trim()
            $parsed = Convert-Microsoft365VersionText -Text $versionText
            if ($parsed -is [version]) {
                return Format-Microsoft365Version -Version $parsed
            }
        }
    }
    return ''
}

function Get-Microsoft365InstalledVersion {
    try {
        return [string](Find-Microsoft365InstalledVersion)
    } catch {
        return ''
    }
}

function Get-Microsoft365InstallConfiguration {
    # Microsoft 365 Apps for enterprise, 64-bit, Current channel.
    # No tenant id, no customer display name, and no product key.
    # RemoveMSI removes legacy Windows Installer copies of Office, not Windows.
    $text = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current" MigrateArch="TRUE">
    <Product ID="O365ProPlusRetail">
      <Language ID="MatchOS" Fallback="en-us" />
      <Language ID="MatchInstalled" />
      <Language ID="MatchPreviousMSI" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="Publisher" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Updates Enabled="TRUE" />
  <RemoveMSI />
</Configuration>
'@
    return $text.Replace("`r`n", "`n").Trim()
}

function Get-Microsoft365RemoveConfiguration {
    # Removes only Microsoft 365 Apps for enterprise. All is FALSE so other
    # Click-to-Run products stay. This does not remove Windows.
    $text = @'
<Configuration>
  <Remove All="FALSE">
    <Product ID="O365ProPlusRetail" />
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
</Configuration>
'@
    return $text.Replace("`r`n", "`n").Trim()
}

function Test-Microsoft365InstallConfiguration {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    if ($Text -match 'Tenant' -or $Text -match 'PIDKEY' -or $Text -match 'Configuration ID=') {
        return $false
    }
    if ($Text -match 'ID="Windows"' -or $Text -match '<Remove(\s|/|>)' -or $Text -match 'All="(?i)true"') {
        return $false
    }
    try {
        $xml = [xml]$Text
    } catch {
        return $false
    }
    $add = $xml.SelectSingleNode('/Configuration/Add')
    if ($null -eq $add) {
        return $false
    }
    if ($add.GetAttribute('OfficeClientEdition') -cne '64' -or $add.GetAttribute('Channel') -cne 'Current') {
        return $false
    }
    if ($null -ne $xml.SelectSingleNode('/Configuration/Remove')) {
        return $false
    }
    $products = $add.SelectNodes('Product')
    if ($null -eq $products -or $products.Count -ne 1) {
        return $false
    }
    return $products.Item(0).GetAttribute('ID') -ceq 'O365ProPlusRetail'
}

function Test-Microsoft365RemoveConfiguration {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    if ($Text -match 'Tenant' -or $Text -match 'PIDKEY' -or $Text -match 'Windows') {
        return $false
    }
    if ($Text -match '<Add(\s|/|>)' -or $Text -match 'All="(?i)true"') {
        return $false
    }
    if ($Text -notmatch '<Remove(\s|/|>)' -or $Text -notmatch 'All="FALSE"') {
        return $false
    }
    try {
        $xml = [xml]$Text
    } catch {
        return $false
    }
    if ($null -ne $xml.SelectSingleNode('/Configuration/Add')) {
        return $false
    }
    $remove = $xml.SelectSingleNode('/Configuration/Remove')
    if ($null -eq $remove -or $remove.GetAttribute('All') -cne 'FALSE') {
        return $false
    }
    $products = $remove.SelectNodes('Product')
    if ($null -eq $products -or $products.Count -ne 1) {
        return $false
    }
    return $products.Item(0).GetAttribute('ID') -ceq 'O365ProPlusRetail'
}

function Get-Microsoft365SetupFileName {
    param([string]$SetupPath)
    # Tests run on Linux, where backslash is not a separator.
    $raw = $SetupPath.Replace('/', '\')
    $index = $raw.LastIndexOf('\')
    if ($index -ge 0 -and $index -lt ($raw.Length - 1)) {
        return $raw.Substring($index + 1)
    }
    return $raw
}

function Test-Microsoft365SetupPath {
    param([string]$SetupPath)
    if ([string]::IsNullOrWhiteSpace($SetupPath)) {
        return $false
    }
    $name = Get-Microsoft365SetupFileName -SetupPath $SetupPath
    if (-not $name.Equals('setup.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    # Windows setup.exe lives under the Windows directory. Do not run it.
    $raw = $SetupPath.Replace('/', '\')
    if ($raw -match '(?i)(^|[\\])Windows([\\]|$)') {
        return $false
    }
    return $true
}

function Get-Microsoft365SetupArgumentList {
    param(
        [string]$Mode,
        [string]$ConfigPath
    )
    if ($Mode -ne 'install' -and $Mode -ne 'uninstall') {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $null
    }
    # /configure only. setup.exe downloads Office payloads during install.
    # The quoted path survives Windows PowerShell 5.1 argument joining.
    return @('/configure', ('"{0}"' -f $ConfigPath))
}

function Get-Microsoft365ExtractArgumentList {
    param([string]$Destination)
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        return $null
    }
    return @(
        ('/extract:"{0}"' -f $Destination),
        '/norestart',
        '/quiet'
    )
}

function Test-Microsoft365SetupSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. This package does not restart Windows.
    return $Code -eq 0 -or $Code -eq 3010
}

function Get-Microsoft365MarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledMicrosoft365Version)
    } catch {
        $afterText = ''
    }
    $after = Convert-Microsoft365VersionText -Text $afterText
    $pin = Convert-Microsoft365VersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-Microsoft365Version -Version $after
    }
    if ($pin -is [version]) {
        return Format-Microsoft365Version -Version $pin
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

$script:GetInstalledMicrosoft365Version = {
    return [string](Get-Microsoft365InstalledVersion)
}

# The self-extractor is waited on and never killed.
$script:ExpandOdt = {
    param($ArchivePath, $Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $argumentList = Get-Microsoft365ExtractArgumentList -Destination $Destination
    if ($null -eq $argumentList) {
        return 1
    }
    $process = Start-Process -FilePath $ArchivePath -ArgumentList $argumentList -WorkingDirectory $Destination -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

# setup.exe is waited on and never killed. The path is the extracted file.
$script:InvokeSetup = {
    param($Mode, $SetupPath, $ConfigPath)
    if (-not (Test-Microsoft365SetupPath -SetupPath $SetupPath)) {
        return 1
    }
    $argumentList = Get-Microsoft365SetupArgumentList -Mode $Mode -ConfigPath $ConfigPath
    if ($null -eq $argumentList) {
        return 1
    }
    $process = Start-Process -FilePath $SetupPath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

function Invoke-Microsoft365Action {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$SetupSha256,
        [string]$CancelPath,
        [string]$MarkerRoot
    )

    # An empty pin hash disables every action before registry, download, setup, or marker changes.
    if ([string]::IsNullOrWhiteSpace($InstallerSha256) -or [string]::IsNullOrWhiteSpace($SetupSha256)) {
        return 0
    }

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-Microsoft365DefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledMicrosoft365Version)
    } catch {
        Add-Microsoft365Error -Message 'could not read the installed Microsoft 365 Apps version'
        return 1
    }
    $marker = Read-Microsoft365MarkerVersion -Root $MarkerRoot
    $plan = Get-Microsoft365Plan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install' -or $plan.RunInstaller -eq 'uninstall') {
            $mode = [string]$plan.RunInstaller
            if ($mode -eq 'uninstall') {
                $configText = Get-Microsoft365RemoveConfiguration
                if (-not (Test-Microsoft365RemoveConfiguration -Text $configText)) {
                    Add-Microsoft365Error -Message 'uninstall configuration is not limited to Microsoft 365 Apps'
                    return 1
                }
            } else {
                $configText = Get-Microsoft365InstallConfiguration
                if (-not (Test-Microsoft365InstallConfiguration -Text $configText)) {
                    Add-Microsoft365Error -Message 'install configuration is not Microsoft 365 Apps'
                    return 1
                }
            }
            # An empty hash disables the package, including Uninstall. Do not download.
            # A placeholder is not a pin. Do not download it and do not run setup.
            if ([string]::IsNullOrWhiteSpace($InstallerSha256) -or [string]::IsNullOrWhiteSpace($SetupSha256)) {
                return 0
            }
            if (-not (Test-Microsoft365PinHash -Sha256 $InstallerSha256) -or -not (Test-Microsoft365PinHash -Sha256 $SetupSha256)) {
                Add-Microsoft365Error -Message 'refusing a placeholder hash'
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-microsoft-365-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $archivePath = Join-Path $cache $script:Microsoft365ArchiveName
            $downloaded = [int](Save-Microsoft365Payload -Url $InstallerUrl -Destination $archivePath -Sha256 $InstallerSha256 -Label 'office deployment tool' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
                return 130
            }
            $extractDir = Join-Path $cache 'extract'
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            $extractCode = 1
            try {
                $extractResult = & $script:ExpandOdt -ArchivePath $archivePath -Destination $extractDir
                if ($null -ne $extractResult) {
                    $extractCode = [int]$extractResult
                }
            } catch {
                $extractCode = 1
            }
            if ($extractCode -ne 0) {
                Add-Microsoft365Error -Message 'could not extract setup.exe'
                return 1
            }
            $setupPath = Join-Path $extractDir 'setup.exe'
            if (-not (Test-Path -LiteralPath $setupPath)) {
                Add-Microsoft365Error -Message 'could not extract setup.exe'
                return 1
            }
            if (-not (Test-Microsoft365SetupPath -SetupPath $setupPath)) {
                Add-Microsoft365Error -Message 'refusing to run Windows setup'
                return 1
            }
            $actualSetup = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
            $expectedSetup = $SetupSha256.Trim().ToLowerInvariant()
            if (-not $actualSetup.Equals($expectedSetup, [System.StringComparison]::Ordinal)) {
                Add-Microsoft365Error -Message 'hash mismatch for setup.exe'
                return 1
            }
            if (Test-Microsoft365Cancelled -CancelPath $CancelPath) {
                return 130
            }
            $configPath = Join-Path $cache 'configuration.xml'
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($configPath, ($configText.Trim() + "`n"), $utf8)
            $result = $null
            try {
                $result = & $script:InvokeSetup -Mode $mode -SetupPath $setupPath -ConfigPath $configPath
            } catch {
                Add-Microsoft365Error -Message 'setup.exe failed'
                return 1
            }
            if ($null -eq $result -or -not (Test-Microsoft365SetupSucceeded -Code ([int]$result))) {
                Add-Microsoft365Error -Message 'setup.exe failed'
                return 1
            }
            if ($mode -eq 'install') {
                $write = Get-Microsoft365MarkerAfterInstall -PinVersion $PinVersion
                if ([string]::IsNullOrWhiteSpace($write)) {
                    Add-Microsoft365Error -Message 'setup.exe succeeded without a version'
                    return 1
                }
                Write-Microsoft365Marker -Root $MarkerRoot -Version $write
                return 0
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-Microsoft365Marker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-Microsoft365Marker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-Microsoft365Error -Message 'could not remove the installer cache'
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
    $microsoft365Exit = [int](Invoke-Microsoft365Action -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -SetupSha256 $SetupSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $microsoft365Exit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'microsoft 365 package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
