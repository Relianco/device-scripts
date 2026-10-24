$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-VlcDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-VlcDetectVersionText {
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

function Get-VlcDetectPropertyText {
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

function New-VlcDetectProduct {
    param(
        [string]$Version = '',
        [string]$UninstallPath = '',
        [string]$InstallDirectory = ''
    )
    return [pscustomobject]@{
        Version          = $Version
        UninstallPath    = $UninstallPath
        InstallDirectory = $InstallDirectory
    }
}

function Get-VlcDetectParentDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    $trimmed = $Path.Trim().Trim('"')
    $slash = [Math]::Max($trimmed.LastIndexOf('\'), $trimmed.LastIndexOf('/'))
    if ($slash -le 0) {
        return ''
    }
    return $trimmed.Substring(0, $slash).TrimEnd('\', '/')
}

function Get-VlcDetectUninstallPathText {
    param(
        [string]$UninstallText,
        [string]$InstallLocation
    )
    $text = $UninstallText.Trim()
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) {
            return $text.Substring(1, $end - 1)
        }
    }
    $lower = $text.ToLowerInvariant()
    $marker = 'uninstall.exe'
    $at = $lower.IndexOf($marker)
    if ($at -ge 0) {
        return $text.Substring(0, $at + $marker.Length).Trim().Trim('"')
    }
    $location = $InstallLocation.Trim().Trim('"').TrimEnd('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        return $location + '\uninstall.exe'
    }
    return ''
}

function Get-VlcDetectInstallDirectoryText {
    param(
        [string]$InstallLocation,
        [string]$UninstallPath
    )
    $location = $InstallLocation.Trim().Trim('"').TrimEnd('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        return $location
    }
    return Get-VlcDetectParentDirectory -Path $UninstallPath
}

function Find-VlcDetectUninstallProduct {
    param([object[]]$Entries)
    $best = $null
    if ($null -eq $Entries) {
        return $null
    }
    foreach ($props in @($Entries)) {
        if ($null -eq $props) {
            continue
        }
        $displayName = (Get-VlcDetectPropertyText -Object $props -Name 'DisplayName').Trim()
        if ($displayName -ne 'VLC media player') {
            continue
        }
        $versionText = (Get-VlcDetectPropertyText -Object $props -Name 'DisplayVersion').Trim()
        $location = (Get-VlcDetectPropertyText -Object $props -Name 'InstallLocation').Trim()
        $uninstallText = (Get-VlcDetectPropertyText -Object $props -Name 'UninstallString').Trim()
        if ([string]::IsNullOrWhiteSpace($uninstallText)) {
            $uninstallText = (Get-VlcDetectPropertyText -Object $props -Name 'QuietUninstallString').Trim()
        }
        $path = Get-VlcDetectUninstallPathText -UninstallText $uninstallText -InstallLocation $location
        $directory = Get-VlcDetectInstallDirectoryText -InstallLocation $location -UninstallPath $path
        $parsed = Convert-VlcDetectVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-VlcDetectVersion -Version $parsed
        }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
        $hasPath = -not [string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($directory)
        if ($hasVersion -and $hasPath) {
            return New-VlcDetectProduct -Version $formatted -UninstallPath $path -InstallDirectory $directory
        }
        if ($null -eq $best -and ($hasVersion -or $hasPath)) {
            $best = New-VlcDetectProduct -Version $formatted -UninstallPath $path -InstallDirectory $directory
        }
    }
    return $best
}

function Get-VlcDetectProductFromKey {
    param($Entry)
    try {
        $productVersion = (Get-VlcDetectPropertyText -Object $Entry -Name 'Version').Trim()
        $productDir = (Get-VlcDetectPropertyText -Object $Entry -Name 'InstallDir').Trim()
        $parsedProduct = Convert-VlcDetectVersionText -Text $productVersion
        $formattedProduct = ''
        if ($parsedProduct -is [version]) {
            $formattedProduct = Format-VlcDetectVersion -Version $parsedProduct
        }
        $productPath = ''
        if (-not [string]::IsNullOrWhiteSpace($productDir)) {
            $productPath = $productDir.TrimEnd('\', '/') + '\uninstall.exe'
        }
        $directory = Get-VlcDetectInstallDirectoryText -InstallLocation $productDir -UninstallPath $productPath
        return New-VlcDetectProduct -Version $formattedProduct -UninstallPath $productPath -InstallDirectory $directory
    } catch {
        return New-VlcDetectProduct
    }
}

function Test-VlcDetectVersionAtPin {
    param([string]$VersionText)
    $installed = Convert-VlcDetectVersionText -Text $VersionText
    $pin = Convert-VlcDetectVersionText -Text '3.0.24'
    if ($installed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Test-VlcDetectInstalled {
    param(
        [object[]]$Entries,
        $ProductEntry = $null,
        [switch]$ProductUnreadable
    )
    $found = Find-VlcDetectUninstallProduct -Entries $Entries
    if ($null -eq $found) {
        if ($ProductUnreadable -or $null -eq $ProductEntry) {
            $found = New-VlcDetectProduct
        } else {
            $found = Get-VlcDetectProductFromKey -Entry $ProductEntry
        }
    }
    return Test-VlcDetectVersionAtPin -VersionText ([string]$found.Version)
}

function Get-VlcDetectRegistryState {
    $entries = [System.Collections.Generic.List[object]]::new()
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
            $entries.Add($props)
        }
    }
    $found = Find-VlcDetectUninstallProduct -Entries $entries.ToArray()
    if ($null -ne $found) {
        return $found
    }
    # Written by the VLC installer when the uninstall key has no version.
    $productKey = 'HKLM:\SOFTWARE\VideoLAN\VLC'
    if (-not (Test-Path -LiteralPath $productKey)) {
        return New-VlcDetectProduct
    }
    try {
        $productProps = Get-ItemProperty -LiteralPath $productKey -ErrorAction Stop
    } catch {
        return New-VlcDetectProduct
    }
    return Get-VlcDetectProductFromKey -Entry $productProps
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$detected = $false
try {
    $detectedProduct = Get-VlcDetectRegistryState
    $detected = Test-VlcDetectVersionAtPin -VersionText ([string]$detectedProduct.Version)
} catch {
    $detected = $false
}
if ($detected) {
    Write-Output 'Relian VLC media player'
    exit 0
}
exit 1
