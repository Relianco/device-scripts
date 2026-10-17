# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion
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

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}
