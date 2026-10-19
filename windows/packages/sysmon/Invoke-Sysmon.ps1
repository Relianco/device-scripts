# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/sysmon.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://download.sysinternals.com/files/Sysmon.zip',
    [string]$InstallerSha256 = '00ecf1b46aec99299d3ae0bca79dc621458bd014b20b509d7c5c8e8c8611aa54',
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Quiet process-create logging with SHA256. schemaversion 4.91 matches Sysmon 15.22.
# An empty exclude logs every process create and names no host, user, or client.
$script:SysmonConfigText = @'
<Sysmon schemaversion="4.91">
  <HashAlgorithms>SHA256</HashAlgorithms>
  <EventFiltering>
    <ProcessCreate onmatch="exclude"></ProcessCreate>
  </EventFiltering>
</Sysmon>
'@

function Format-SysmonVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-SysmonVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $parsed = [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
    # ProductVersion is major.minor. Compare it as four parts so 15.22 equals 15.22.0.0.
    $build = $parsed.Build
    $revision = $parsed.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]::new($parsed.Major, $parsed.Minor, $build, $revision)
}

function New-SysmonPlan {
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

function Get-SysmonPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-SysmonPlan -ExitCode 0
    }
    $pin = Convert-SysmonVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-SysmonPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-SysmonPlan -ExitCode 1
    }

    $installed = Convert-SysmonVersionText -Text $InstalledVersion
    $marker = Convert-SysmonVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-SysmonPlan -ExitCode 0
        }
        if (-not $present) {
            return New-SysmonPlan -ClearMarker $true
        }
        return New-SysmonPlan -RunInstaller 'uninstall' -ClearMarker $true
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-SysmonPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-SysmonVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-SysmonVersion -Version $marker
    }
    $pinText = Format-SysmonVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-SysmonPlan -RunInstaller 'install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-SysmonPlan -RunInstaller 'install'
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
            return New-SysmonPlan -ExitCode 0
        }
        return New-SysmonPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-SysmonPlan -RunInstaller 'install'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-SysmonPlan -ExitCode 0
            }
            return New-SysmonPlan -WriteMarker $write
        }
        return New-SysmonPlan -RunInstaller 'install'
    }

    return New-SysmonPlan -ExitCode 1
}

$script:SysmonErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-SysmonError {
    param([string]$Message)
    if ($null -eq $script:SysmonErrorLog) {
        $script:SysmonErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:SysmonErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-SysmonUrlHasUserInfo {
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

function Test-SysmonCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-SysmonHttpStatus {
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

function Test-SysmonTransientTransport {
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

function Test-SysmonDownloadIsTransient {
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
    $status = Get-SysmonHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-SysmonTransientTransport -Exception $exception)
}

function Save-SysmonPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    if (Test-SysmonUrlHasUserInfo -Url $Url) {
        Add-SysmonError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-SysmonCancelled -CancelPath $CancelPath) {
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
                Add-SysmonError -Message "hash mismatch for $Label"
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
            $status = Get-SysmonHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-SysmonDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-SysmonError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-SysmonError -Message "download wrote no file for $Label"
            } else {
                Add-SysmonError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-SysmonCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-SysmonCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-SysmonError -Message "download failed for $Label"
    return 1
}

function Get-SysmonMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Read-SysmonMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-SysmonMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-SysmonMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-SysmonMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-SysmonMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-SysmonMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-SysmonDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\sysmon'
}

function Convert-SysmonImagePath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        return ''
    }
    $text = $ImagePath.Trim()
    $exe = ''
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) {
            $exe = $text.Substring(1, $end - 1)
        }
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $match = [regex]::Match($text, '(?i)^(?<path>.*?\.exe)\b')
        if ($match.Success) {
            $exe = $match.Groups['path'].Value
        } else {
            $exe = $text
        }
    }
    $exe = $exe.Trim()
    $prefix = ''
    if ($exe.StartsWith('\SystemRoot\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $prefix = '\SystemRoot\'
    } elseif ($exe.StartsWith('%SystemRoot%\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $prefix = '%SystemRoot%\'
    }
    if (-not [string]::IsNullOrEmpty($prefix)) {
        $root = $env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = 'C:\Windows'
        }
        $leaf = $exe.Substring($prefix.Length)
        return ($root.TrimEnd('\') + '\' + $leaf.TrimStart('\'))
    }
    return $exe
}

function Get-SysmonPropertyText {
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

function Get-SysmonInstalledProduct {
    # The service name is the executable name. This package installs Sysmon64.exe.
    try {
        foreach ($name in @('Sysmon64', 'Sysmon')) {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $name
            if (-not (Test-Path -LiteralPath $key)) {
                continue
            }
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            } catch {
                continue
            }
            $exe = Convert-SysmonImagePath -ImagePath (Get-SysmonPropertyText -Object $props -Name 'ImagePath')
            if ([string]::IsNullOrWhiteSpace($exe)) {
                $root = $env:SystemRoot
                if ([string]::IsNullOrWhiteSpace($root)) {
                    $root = 'C:\Windows'
                }
                $exe = $root.TrimEnd('\') + '\' + $name + '.exe'
            }
            $version = ''
            if (Test-Path -LiteralPath $exe) {
                try {
                    $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
                } catch {
                    $version = ''
                }
            }
            return [pscustomobject]@{
                Version = $version.Trim()
                ExePath = $exe
            }
        }
    } catch {
        return [pscustomobject]@{ Version = ''; ExePath = '' }
    }
    return [pscustomobject]@{ Version = ''; ExePath = '' }
}

function Get-SysmonArgumentList {
    param(
        [string]$Mode,
        [string]$ConfigPath
    )
    # -u force is not understood by Sysmon 8. The caller falls back to -u.
    if ($Mode -eq 'uninstall') {
        return @('-u', 'force')
    }
    if ($Mode -eq 'uninstall-plain') {
        return @('-u')
    }
    if ($Mode -eq 'install') {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            return $null
        }
        return @('-accepteula', '-i', $ConfigPath)
    }
    return $null
}

function Test-SysmonCommandSucceeded {
    param([int]$Code)
    # 3010 is success with a reboot pending. The process is not still running.
    return $Code -eq 0 -or $Code -eq 3010
}

function Find-SysmonExecutable {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ''
    }
    $direct = Join-Path $Root 'Sysmon64.exe'
    if (Test-Path -LiteralPath $direct) {
        return $direct
    }
    $found = Get-ChildItem -LiteralPath $Root -Filter 'Sysmon64.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $found) {
        return ''
    }
    return [string]$found.FullName
}

function Write-SysmonConfigFile {
    param([string]$Path)
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $text = $script:SysmonConfigText.Trim() + "`n"
    [System.IO.File]::WriteAllText($Path, $text, $utf8)
}

function Get-SysmonMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledSysmonVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-SysmonVersionText -Text $afterText
    $pin = Convert-SysmonVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-SysmonVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-SysmonVersion -Version $pin
    }
    return ''
}

function Invoke-SysmonRemoval {
    param(
        [string]$ExePath,
        [string]$CancelPath
    )
    if (Test-SysmonCancelled -CancelPath $CancelPath) {
        return 130
    }
    $code = & $script:InvokeSysmon -Mode 'uninstall' -ExePath $ExePath -ConfigPath ''
    if ($null -ne $code -and (Test-SysmonCommandSucceeded -Code ([int]$code))) {
        return 0
    }
    $plain = & $script:InvokeSysmon -Mode 'uninstall-plain' -ExePath $ExePath -ConfigPath ''
    if ($null -ne $plain -and (Test-SysmonCommandSucceeded -Code ([int]$plain))) {
        return 0
    }
    return 1
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

$script:ExpandArchive = {
    param($Path, $Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
}

$script:GetInstalledSysmonVersion = {
    return [string](Get-SysmonInstalledProduct).Version
}

$script:GetSysmonExePath = {
    return [string](Get-SysmonInstalledProduct).ExePath
}

# Sysmon is only started from this hook. It is waited on and never killed.
# Windows PowerShell 5.1 joins an argument array and splits it again.
$script:InvokeSysmon = {
    param($Mode, $ExePath, $ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        return 1
    }
    $arguments = Get-SysmonArgumentList -Mode $Mode -ConfigPath $ConfigPath
    if ($null -eq $arguments) {
        return 1
    }
    $startArgs = $arguments
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $quoted = [System.Collections.Generic.List[string]]::new()
        foreach ($arg in $arguments) {
            if ($arg -match '[\s"]') {
                $quoted.Add('"' + ($arg -replace '"', '\"') + '"')
            } else {
                $quoted.Add($arg)
            }
        }
        $startArgs = $quoted -join ' '
    }
    try {
        $process = Start-Process -FilePath $ExePath -ArgumentList $startArgs -Wait -PassThru -WindowStyle Hidden
    } catch {
        return 1
    }
    if ($null -eq $process) {
        return 1
    }
    return [int]$process.ExitCode
}

function Invoke-SysmonAction {
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
        $MarkerRoot = Get-SysmonDefaultMarkerRoot
    }

    $installed = ''
    $exePath = ''
    try {
        $installed = [string](& $script:GetInstalledSysmonVersion)
        $exePath = [string](& $script:GetSysmonExePath)
    } catch {
        Add-SysmonError -Message 'could not read the installed Sysmon version'
        return 1
    }
    $marker = Read-SysmonMarkerVersion -Root $MarkerRoot
    $plan = Get-SysmonPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-SysmonCancelled -CancelPath $CancelPath) {
        return 130
    }

    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-SysmonError -Message 'missing hash for installer'
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-sysmon-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $zipPath = Join-Path $cache 'Sysmon.zip'
            $downloaded = [int](Save-SysmonPayload -Url $InstallerUrl -Destination $zipPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start Sysmon.
            if (Test-SysmonCancelled -CancelPath $CancelPath) {
                return 130
            }
            $extractRoot = Join-Path $cache 'extract'
            New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
            try {
                [void](& $script:ExpandArchive -Path $zipPath -Destination $extractRoot)
            } catch {
                Add-SysmonError -Message 'could not expand the archive'
                return 1
            }
            $extractedExe = Find-SysmonExecutable -Root $extractRoot
            if ([string]::IsNullOrWhiteSpace($extractedExe)) {
                Add-SysmonError -Message 'extracted archive has no Sysmon64.exe'
                return 1
            }
            $configPath = Join-Path $cache 'sysmonconfig.xml'
            Write-SysmonConfigFile -Path $configPath
            if (Test-SysmonCancelled -CancelPath $CancelPath) {
                return 130
            }
            # -i fails while the service is already registered, so remove it first.
            $needsRemoval = -not [string]::IsNullOrWhiteSpace($installed) -or -not [string]::IsNullOrWhiteSpace($exePath)
            if ($needsRemoval) {
                $removeExe = $exePath
                if ([string]::IsNullOrWhiteSpace($removeExe)) {
                    $removeExe = $extractedExe
                }
                $removed = [int](Invoke-SysmonRemoval -ExePath $removeExe -CancelPath $CancelPath)
                if ($removed -eq 130) {
                    return 130
                }
                if ($removed -ne 0) {
                    Add-SysmonError -Message 'uninstall failed'
                    return 1
                }
            }
            $result = & $script:InvokeSysmon -Mode 'install' -ExePath $extractedExe -ConfigPath $configPath
            if ($null -eq $result -or -not (Test-SysmonCommandSucceeded -Code ([int]$result))) {
                Add-SysmonError -Message 'installer failed'
                return 1
            }
            $write = Get-SysmonMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-SysmonError -Message 'installer succeeded without a version'
                return 1
            }
            Write-SysmonMarker -Root $MarkerRoot -Version $write
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-SysmonCancelled -CancelPath $CancelPath) {
                return 130
            }
            if ([string]::IsNullOrWhiteSpace($exePath)) {
                Add-SysmonError -Message 'missing executable for uninstall'
                return 1
            }
            $removed = [int](Invoke-SysmonRemoval -ExePath $exePath -CancelPath $CancelPath)
            if ($removed -eq 130) {
                return 130
            }
            if ($removed -ne 0) {
                Add-SysmonError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-SysmonMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-SysmonMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
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
                Add-SysmonError -Message 'could not remove the installer cache'
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
    $sysmonExit = [int](Invoke-SysmonAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
    exit $sysmonExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'sysmon package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
