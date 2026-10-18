# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in releases/notepadpp.json.
# The runner copies this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8.1/npp.8.9.8.1.Installer.x64.exe',
    [string]$InstallerSha256 = '26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da',
    [string]$CancelPath = '',
    [string]$MarkerRoot = '',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-NotepadppVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-NotepadppVersionText {
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

function New-NotepadppPlan {
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

function Get-NotepadppPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion
    )

    # An empty pin disables the package. Do not download or change the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-NotepadppPlan -ExitCode 0
    }
    $pin = Convert-NotepadppVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-NotepadppPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-NotepadppPlan -ExitCode 1
    }

    $installed = Convert-NotepadppVersionText -Text $InstalledVersion
    $marker = Convert-NotepadppVersionText -Text $MarkerVersion

    # Uninstall does not compare versions and does not need the installer hash.
    if ($Action -eq 'Uninstall') {
        $present = -not [string]::IsNullOrWhiteSpace($InstalledVersion)
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $present -and -not $hasMarker) {
            return New-NotepadppPlan -ExitCode 0
        }
        if (-not $present) {
            return New-NotepadppPlan -ClearMarker $true -Log 'Uninstall'
        }
        return New-NotepadppPlan -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall'
    }

    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-NotepadppPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-NotepadppVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-NotepadppVersion -Version $marker
    }
    $pinText = Format-NotepadppVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-NotepadppPlan -RunInstaller 'install' -Log 'Install'
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-NotepadppPlan -RunInstaller 'install' -Log 'Install'
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
            return New-NotepadppPlan -ExitCode 0
        }
        return New-NotepadppPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -eq $installed) {
            return New-NotepadppPlan -RunInstaller 'install' -Log 'Repair'
        }
        if ($installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-NotepadppPlan -ExitCode 0
            }
            return New-NotepadppPlan -WriteMarker $write
        }
        return New-NotepadppPlan -RunInstaller 'install' -Log 'Repair'
    }

    return New-NotepadppPlan -ExitCode 1
}

$script:NotepadppErrorLog = [System.Collections.Generic.List[string]]::new()

function Add-NotepadppError {
    param([string]$Message)
    if ($null -eq $script:NotepadppErrorLog) {
        $script:NotepadppErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:NotepadppErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-NotepadppUrlHasUserInfo {
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

function Test-NotepadppCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-NotepadppHttpStatus {
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

function Test-NotepadppTransientTransport {
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

function Test-NotepadppDownloadIsTransient {
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
    $status = Get-NotepadppHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-NotepadppTransientTransport -Exception $exception)
}

function Test-NotepadppPlaceholderHash {
    param([string]$Sha256)
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return $false
    }
    $candidate = $Sha256.Trim().ToLowerInvariant()
    if ($candidate.Length -ne 64) {
        return $true
    }
    $identical = $true
    $first = [int][char]$candidate[0]
    foreach ($char in $candidate.ToCharArray()) {
        $code = [int]$char
        if ($code -ne $first) {
            $identical = $false
        }
        $isDigit = $code -ge 48 -and $code -le 57
        $isLower = $code -ge 97 -and $code -le 102
        if (-not $isDigit -and -not $isLower) {
            return $true
        }
    }
    return $identical
}

function Save-NotepadppPayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$Label,
        [string]$CancelPath
    )

    # Userinfo is rejected even when the hash is empty. Empty hash downloads nothing.
    # A placeholder, including 64 identical characters, is rejected before any download.
    if (Test-NotepadppUrlHasUserInfo -Url $Url) {
        Add-NotepadppError -Message "refusing a URL that contains userinfo for $Label"
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Sha256)) {
        return 0
    }
    if (Test-NotepadppPlaceholderHash -Sha256 $Sha256) {
        Add-NotepadppError -Message "refusing a placeholder hash for $Label"
        return 1
    }

    $expected = $Sha256.Trim().ToLowerInvariant()
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-NotepadppCancelled -CancelPath $CancelPath) {
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
                Add-NotepadppError -Message "hash mismatch for $Label"
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
            $status = Get-NotepadppHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-NotepadppDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Add-NotepadppError -Message "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Add-NotepadppError -Message "download wrote no file for $Label"
            } else {
                Add-NotepadppError -Message "download failed for $Label"
            }
            return 1
        }
        if (Test-NotepadppCancelled -CancelPath $CancelPath) {
            return 130
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-NotepadppCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Add-NotepadppError -Message "download failed for $Label"
    return 1
}

function Get-NotepadppMarkerPath {
    param([string]$Root)
    return Join-Path $Root 'marker.txt'
}

function Get-NotepadppLogPath {
    param([string]$Root)
    return Join-Path $Root 'toolkit.log'
}

function Read-NotepadppMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-NotepadppMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-NotepadppMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-NotepadppMarkerPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $Version, $utf8)
}

function Add-NotepadppLogLine {
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
    $path = Get-NotepadppLogPath -Root $Root
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($path, ($Line + "`n"), $utf8)
}

function Remove-NotepadppMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-NotepadppMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-NotepadppDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [System.IO.Path]::GetTempPath()
    }
    return Join-Path $programData 'Relian\notepadpp'
}

function Get-NotepadppPropertyText {
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

function Get-NotepadppUninstallExe {
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

function Find-NotepadppRegistryProduct {
    $best = $null
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
            $displayName = (Get-NotepadppPropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -ne 'Notepad++ (64-bit x64)') {
                continue
            }
            $versionText = (Get-NotepadppPropertyText -Object $props -Name 'DisplayVersion').Trim()
            $quiet = Get-NotepadppPropertyText -Object $props -Name 'QuietUninstallString'
            $uninstall = Get-NotepadppPropertyText -Object $props -Name 'UninstallString'
            $exe = Get-NotepadppUninstallExe -Text $quiet
            if ([string]::IsNullOrWhiteSpace($exe)) {
                $exe = Get-NotepadppUninstallExe -Text $uninstall
            }
            $parsed = Convert-NotepadppVersionText -Text $versionText
            $formatted = ''
            if ($parsed -is [version]) {
                $formatted = Format-NotepadppVersion -Version $parsed
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
    return [pscustomobject]@{ Version = ''; UninstallPath = '' }
}

function Get-NotepadppRegistryProduct {
    try {
        return Find-NotepadppRegistryProduct
    } catch {
        return [pscustomobject]@{ Version = ''; UninstallPath = '' }
    }
}

# Publisher silent install is /S. /noUpdater omits WinGUP and Plugins Admin.
# /S is case sensitive. Do not launch Notepad++ after setup.
function Get-NotepadppInstallArgumentList {
    return @('/S', '/noUpdater')
}

# Publisher silent uninstall is uninstall.exe /S.
function Get-NotepadppUninstallArgumentList {
    param([string]$UninstallPath)
    if ([string]::IsNullOrWhiteSpace($UninstallPath)) {
        return $null
    }
    return @('/S')
}

function Test-NotepadppSetupSucceeded {
    param([int]$Code)
    # NSIS silent success is 0. The publisher does not document 3010.
    return $Code -eq 0
}

function Get-NotepadppMarkerAfterInstall {
    param([string]$PinVersion)
    $afterText = ''
    try {
        $afterText = [string](& $script:GetInstalledNotepadppVersion)
    } catch {
        $afterText = ''
    }
    $after = Convert-NotepadppVersionText -Text $afterText
    $pin = Convert-NotepadppVersionText -Text $PinVersion
    if ($after -is [version] -and $pin -is [version] -and $after.CompareTo($pin) -ge 0) {
        return Format-NotepadppVersion -Version $after
    }
    if ($pin -is [version]) {
        return Format-NotepadppVersion -Version $pin
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

$script:GetInstalledNotepadppVersion = {
    return [string](Get-NotepadppRegistryProduct).Version
}

$script:GetNotepadppUninstallPath = {
    return [string](Get-NotepadppRegistryProduct).UninstallPath
}

# The installer is only started from this hook. It is waited on and never killed.
$script:InvokeNotepadppSetup = {
    param($Mode, $InstallerPath, $UninstallPath)
    $filePath = ''
    $argumentList = $null
    if ($Mode -eq 'uninstall') {
        if ([string]::IsNullOrWhiteSpace([string]$UninstallPath)) {
            return 1
        }
        $filePath = [string]$UninstallPath
        $argumentList = @(Get-NotepadppUninstallArgumentList -UninstallPath $filePath)
    } elseif ($Mode -eq 'install') {
        if ([string]::IsNullOrWhiteSpace([string]$InstallerPath)) {
            return 1
        }
        $filePath = [string]$InstallerPath
        $argumentList = @(Get-NotepadppInstallArgumentList)
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

function Invoke-NotepadppAction {
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
        $MarkerRoot = Get-NotepadppDefaultMarkerRoot
    }

    $installed = ''
    try {
        $installed = [string](& $script:GetInstalledNotepadppVersion)
    } catch {
        Add-NotepadppError -Message 'could not read the installed Notepad++ version'
        return 1
    }
    $marker = Read-NotepadppMarkerVersion -Root $MarkerRoot
    $plan = Get-NotepadppPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-NotepadppCancelled -CancelPath $CancelPath) {
        return 130
    }

    $pendingLog = [string]$plan.Log
    $cache = ''
    try {
        if ($plan.RunInstaller -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
                Add-NotepadppError -Message 'missing hash for installer'
                return 1
            }
            $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-notepadpp-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            $installerPath = Join-Path $cache 'npp.8.9.8.1.Installer.x64.exe'
            $downloaded = [int](Save-NotepadppPayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -Label 'installer' -CancelPath $CancelPath)
            if ($downloaded -ne 0) {
                return $downloaded
            }
            # A cancel after the file is verified must not start setup.
            if (Test-NotepadppCancelled -CancelPath $CancelPath) {
                return 130
            }
            $result = & $script:InvokeNotepadppSetup -Mode 'install' -InstallerPath $installerPath -UninstallPath ''
            if ($null -eq $result -or -not (Test-NotepadppSetupSucceeded -Code ([int]$result))) {
                Add-NotepadppError -Message 'installer failed'
                return 1
            }
            $write = Get-NotepadppMarkerAfterInstall -PinVersion $PinVersion
            if ([string]::IsNullOrWhiteSpace($write)) {
                Add-NotepadppError -Message 'installer succeeded without a version'
                return 1
            }
            Write-NotepadppMarker -Root $MarkerRoot -Version $write
            if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
                Add-NotepadppLogLine -Root $MarkerRoot -Line $pendingLog
            }
            return 0
        }

        if ($plan.RunInstaller -eq 'uninstall') {
            if (Test-NotepadppCancelled -CancelPath $CancelPath) {
                return 130
            }
            $uninstallPath = ''
            try {
                $uninstallPath = [string](& $script:GetNotepadppUninstallPath)
            } catch {
                $uninstallPath = ''
            }
            if ([string]::IsNullOrWhiteSpace($uninstallPath)) {
                Add-NotepadppError -Message 'missing uninstall program'
                return 1
            }
            $result = & $script:InvokeNotepadppSetup -Mode 'uninstall' -InstallerPath '' -UninstallPath $uninstallPath
            if ($null -eq $result -or -not (Test-NotepadppSetupSucceeded -Code ([int]$result))) {
                Add-NotepadppError -Message 'uninstall failed'
                return 1
            }
        }

        if ([bool]$plan.ClearMarker) {
            Remove-NotepadppMarker -Root $MarkerRoot
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
            Write-NotepadppMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
        }
        if (-not [string]::IsNullOrWhiteSpace($pendingLog)) {
            Add-NotepadppLogLine -Root $MarkerRoot -Line $pendingLog
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
                Add-NotepadppError -Message 'could not remove the installer cache'
            }
        }
    }
}

function Get-NotepadppHelpText {
    return "Notepad++ package`nActions: Install, Update, Repair, Uninstall.`nReinstall is not supported.`nHelp exits 0 and does not download or run the installer."
}

function Invoke-NotepadppEntry {
    param(
        [switch]$Help,
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$MarkerRoot,
        $Bound
    )

    if ($Help) {
        return [pscustomobject]@{
            ExitCode = 0
            Help     = (Get-NotepadppHelpText)
        }
    }
    foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
        $present = $false
        if ($null -ne $Bound -and $Bound.ContainsKey($name)) {
            $present = $true
        }
        if (-not $present) {
            [Console]::Error.WriteLine("missing parameter $name")
            return [pscustomobject]@{ ExitCode = 1; Help = '' }
        }
    }
    try {
        $notepadppExit = [int](Invoke-NotepadppAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot)
        return [pscustomobject]@{ ExitCode = $notepadppExit; Help = '' }
    } catch {
        $detail = [string]$_.Exception.Message
        if ($detail -match '://') {
            $detail = 'notepad++ package failed'
        }
        [Console]::Error.WriteLine($detail)
        return [pscustomobject]@{ ExitCode = 1; Help = '' }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$entry = Invoke-NotepadppEntry -Help:$Help -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $MarkerRoot -Bound $PSBoundParameters
if (-not [string]::IsNullOrWhiteSpace([string]$entry.Help)) {
    Write-Output ([string]$entry.Help)
}
exit [int]$entry.ExitCode
