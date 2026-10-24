# Intune runs this file with no arguments.
# Exit 0 when the winget client, Microsoft.DesktopAppInstaller, is at or above the pin.
# Appx is read first. -AllUsers is used only when that parameter exists.
# A WindowsApps directory is used only when Appx has no version.
# This does not detect other apps. A missing package is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianWingetVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianWingetVersionText {
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

function Get-RelianWingetPropertyText {
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
    $value = $Object.$Name
    if ($null -eq $value) {
        return ''
    }
    return [string]$value
}

function Test-RelianWingetCommandHasAllUsers {
    param($Command)
    if ($null -eq $Command) {
        return $false
    }
    $parameters = $null
    try {
        $parameters = $Command.Parameters
    } catch {
        return $false
    }
    if ($null -eq $parameters) {
        return $false
    }
    foreach ($key in @($parameters.Keys)) {
        if ([string]$key -eq 'AllUsers') {
            return $true
        }
    }
    return $false
}

function Get-RelianWingetDirectoryVersion {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
    if ($Name -notmatch '^Microsoft\.DesktopAppInstaller_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_(x64|x86|arm64)__8wekyb3d8bbwe$') {
        return $null
    }
    $parsed = Convert-RelianWingetVersionText -Text ([string]$Matches[1])
    if ($parsed -is [version]) {
        return $parsed
    }
    return $null
}

function Find-RelianWingetInstalledVersion {
    param(
        $Packages,
        $DirectoryNames
    )
    $best = $null
    $packageItems = @()
    if ($null -ne $Packages) {
        $packageItems = @($Packages)
    }
    foreach ($package in $packageItems) {
        if ($null -eq $package) {
            continue
        }
        $parsed = $null
        try {
            $name = (Get-RelianWingetPropertyText -Object $package -Name 'Name').Trim()
            if ($name -ne 'Microsoft.DesktopAppInstaller') {
                continue
            }
            $parsed = Convert-RelianWingetVersionText -Text (Get-RelianWingetPropertyText -Object $package -Name 'Version')
        } catch {
            $parsed = $null
        }
        if ($parsed -is [version]) {
            if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
                $best = $parsed
            }
        }
    }
    # Appx wins when it has a version. Directories apply only when it does not.
    if ($null -eq $best) {
        $directoryItems = @()
        if ($null -ne $DirectoryNames) {
            $directoryItems = @($DirectoryNames)
        }
        foreach ($directoryName in $directoryItems) {
            if ($null -eq $directoryName) {
                continue
            }
            $parsed = $null
            try {
                $parsed = Get-RelianWingetDirectoryVersion -Name ([string]$directoryName)
            } catch {
                $parsed = $null
            }
            if ($parsed -is [version]) {
                if ($null -eq $best -or $parsed.CompareTo($best) -gt 0) {
                    $best = $parsed
                }
            }
        }
    }
    if ($null -eq $best) {
        return ''
    }
    return Format-RelianWingetVersion -Version $best
}

function Test-RelianWingetInstalled {
    param(
        $Packages,
        $DirectoryNames,
        [string]$PinVersion = '1.29.380.0'
    )
    $pin = Convert-RelianWingetVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return $false
    }
    $installed = Convert-RelianWingetVersionText -Text (Find-RelianWingetInstalledVersion -Packages $Packages -DirectoryNames $DirectoryNames)
    if ($installed -isnot [version]) {
        return $false
    }
    $candidate = [version](Format-RelianWingetVersion -Version $installed)
    $required = [version](Format-RelianWingetVersion -Version $pin)
    return $candidate.CompareTo($required) -ge 0
}

function Get-RelianWingetAppxPackages {
    param(
        $Command,
        $InvokePackage
    )
    # A missing Appx command is not installed. It is not an error.
    $commandBound = $PSBoundParameters.ContainsKey('Command')
    if (-not $commandBound) {
        try {
            $Command = Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue
        } catch {
            return @()
        }
    }
    if ($null -eq $Command) {
        return @()
    }
    $invokeBound = $PSBoundParameters.ContainsKey('InvokePackage')
    if ($invokeBound -and $null -eq $InvokePackage) {
        return @()
    }
    if (-not $invokeBound) {
        $InvokePackage = {
            param([bool]$AllUsers)
            if ($AllUsers) {
                return @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
            }
            return @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        }
    }
    $useAllUsers = Test-RelianWingetCommandHasAllUsers -Command $Command
    if ($useAllUsers) {
        try {
            return @(& $InvokePackage $true)
        } catch {
            # -AllUsers exists but was refused. Ask for the current user.
        }
    }
    try {
        return @(& $InvokePackage $false)
    } catch {
        return @()
    }
}

function Get-RelianWingetWindowsAppsDirectoryNames {
    # A missing WindowsApps directory is not installed. It is not an error.
    try {
        $programFiles = [string]$env:ProgramFiles
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            return @()
        }
        $root = Join-Path $programFiles 'WindowsApps'
        if (-not (Test-Path -LiteralPath $root)) {
            return @()
        }
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($null -eq $dir) {
                continue
            }
            $names.Add([string]$dir.Name)
        }
        return $names.ToArray()
    } catch {
        return @()
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $packages = @(Get-RelianWingetAppxPackages)
    $directories = @(Get-RelianWingetWindowsAppsDirectoryNames)
    $present = [bool](Test-RelianWingetInstalled -Packages $packages -DirectoryNames $directories -PinVersion '1.29.380.0')
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Windows Package Manager'
    exit 0
}
exit 1
