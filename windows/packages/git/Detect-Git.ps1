# Intune runs this file with no arguments.
# Exit 0 when Git from The Git Development Community is installed at or above the pin.
# DisplayVersion 2.56.0.2 and the release tag 2.56.0.windows.2 are one build.
# HKLM:\SOFTWARE\GitForWindows applies only when no matching uninstall entry has a version or an uninstall program.
# A nonempty DisplayVersion that does not parse blocks that fallback.
# A missing key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianGitVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianGitVersionText {
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

function Get-RelianGitPropertyText {
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

function Get-RelianGitUninstallExe {
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

function Find-RelianGitProduct {
    param(
        $Entries,
        [string]$CurrentVersion = ''
    )
    $best = $null
    $sawInvalidVersion = $false
    $items = @()
    if ($null -ne $Entries) {
        $items = @($Entries)
    }
    foreach ($props in $items) {
        if ($null -eq $props) {
            continue
        }
        $candidate = $null
        $complete = $false
        try {
            $displayName = (Get-RelianGitPropertyText -Object $props -Name 'DisplayName').Trim()
            $publisher = (Get-RelianGitPropertyText -Object $props -Name 'Publisher').Trim()
            if ($displayName -ne 'Git' -or $publisher -ne 'The Git Development Community') {
                $candidate = $null
            } else {
                $versionText = (Get-RelianGitPropertyText -Object $props -Name 'DisplayVersion').Trim()
                $quiet = Get-RelianGitPropertyText -Object $props -Name 'QuietUninstallString'
                $uninstall = Get-RelianGitPropertyText -Object $props -Name 'UninstallString'
                $exe = Get-RelianGitUninstallExe -Text $quiet
                if ([string]::IsNullOrWhiteSpace($exe)) {
                    $exe = Get-RelianGitUninstallExe -Text $uninstall
                }
                $parsed = Convert-RelianGitVersionText -Text $versionText
                $formatted = ''
                if ($parsed -is [version]) {
                    $formatted = Format-RelianGitVersion -Version $parsed
                }
                $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
                # Present text that does not parse is not the same as a missing DisplayVersion.
                if (-not [string]::IsNullOrWhiteSpace($versionText) -and -not $hasVersion) {
                    $sawInvalidVersion = $true
                }
                $hasExe = -not [string]::IsNullOrWhiteSpace($exe)
                if ($hasVersion -or $hasExe) {
                    $candidate = [pscustomobject]@{ Version = $formatted; UninstallPath = $exe }
                    $complete = $hasVersion -and $hasExe
                }
            }
        } catch {
            $candidate = $null
            $complete = $false
        }
        if ($null -eq $candidate) {
            continue
        }
        if ($complete) {
            return $candidate
        }
        if ($null -eq $best) {
            $best = $candidate
        }
    }
    if ($null -ne $best) {
        return $best
    }
    if ($sawInvalidVersion) {
        return [pscustomobject]@{ Version = ''; UninstallPath = '' }
    }
    $parsedCurrent = Convert-RelianGitVersionText -Text $CurrentVersion
    if ($parsedCurrent -is [version]) {
        return [pscustomobject]@{
            Version       = (Format-RelianGitVersion -Version $parsedCurrent)
            UninstallPath = ''
        }
    }
    return [pscustomobject]@{ Version = ''; UninstallPath = '' }
}

function Test-RelianGitInstalled {
    param(
        $Entries,
        [string]$CurrentVersion = '',
        [string]$PinVersion = '2.56.0.2'
    )
    $pin = Convert-RelianGitVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return $false
    }
    $product = Find-RelianGitProduct -Entries $Entries -CurrentVersion $CurrentVersion
    $installed = Convert-RelianGitVersionText -Text ([string]$product.Version)
    if ($installed -isnot [version]) {
        return $false
    }
    $candidate = [version](Format-RelianGitVersion -Version $installed)
    $required = [version](Format-RelianGitVersion -Version $pin)
    return $candidate.CompareTo($required) -ge 0
}

function Get-RelianGitUninstallEntries {
    # A missing uninstall key is not installed. It is not an error.
    $found = @()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($null -eq $key) {
                continue
            }
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $found += $props
        }
    }
    return $found
}

function Get-RelianGitCurrentVersion {
    # Written by the installer. Used only when the uninstall key has no version.
    $versionKey = 'HKLM:\SOFTWARE\GitForWindows'
    if (-not (Test-Path -LiteralPath $versionKey)) {
        return ''
    }
    try {
        $versionProps = Get-ItemProperty -LiteralPath $versionKey -ErrorAction Stop
    } catch {
        return ''
    }
    return (Get-RelianGitPropertyText -Object $versionProps -Name 'CurrentVersion').Trim()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianGitInstalled -Entries (Get-RelianGitUninstallEntries) -CurrentVersion (Get-RelianGitCurrentVersion) -PinVersion '2.56.0.2')
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Git for Windows'
    exit 0
}
exit 1
