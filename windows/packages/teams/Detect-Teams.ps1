# Intune runs this file with no arguments.
# Exit 0 when an Appx package named MSTeams exists for all users. Exit 1 otherwise.
# -AllUsers is used only when that parameter exists.
# A missing package is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RelianTeamsPropertyText {
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

function Test-RelianTeamsCommandHasAllUsers {
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

function Test-RelianTeamsInstalled {
    param($Packages)
    $items = @()
    if ($null -ne $Packages) {
        $items = @($Packages)
    }
    foreach ($package in $items) {
        if ($null -eq $package) {
            continue
        }
        # One unreadable package must not hide another package that matches.
        $matched = $false
        try {
            $name = (Get-RelianTeamsPropertyText -Object $package -Name 'Name').Trim()
            if ($name -ceq 'MSTeams') {
                $matched = $true
            }
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianTeamsAppxPackages {
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
                return @(Get-AppxPackage -Name 'MSTeams' -AllUsers -ErrorAction Stop)
            }
            return @(Get-AppxPackage -Name 'MSTeams' -ErrorAction Stop)
        }
    }
    $useAllUsers = Test-RelianTeamsCommandHasAllUsers -Command $Command
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

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $packages = @(Get-RelianTeamsAppxPackages)
    $present = [bool](Test-RelianTeamsInstalled -Packages $packages)
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Microsoft Teams'
    exit 0
}
exit 1
