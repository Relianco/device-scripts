# Intune runs this file with no arguments. The packager replaces the action id
# placeholder before upload. A leftover placeholder is not installed.
# This file does not write registry keys. A missing key or value is not installed.
# Intune treats stderr as not installed, so a missing key must not throw.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-RelianApplyActionUnresolvedToken {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    return [regex]::IsMatch($Text, '__[A-Z0-9_]+__')
}

function Get-RelianApplyActionCatalog {
    param([string]$ActionId)
    # Callers wrap this output in @(). Do not return it with a unary comma.
    switch ($ActionId) {
        'avd-logon-timeouts' {
            [pscustomobject]@{ DisplayName = 'Relian AVD logon timeouts'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'AppReadinessPreShellTimeoutMs'; Value = 30000 }
            [pscustomobject]@{ DisplayName = 'Relian AVD logon timeouts'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'FirstLogonTimeout'; Value = 30 }
            [pscustomobject]@{ DisplayName = 'Relian AVD logon timeouts'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DelayedDesktopSwitchTimeout'; Value = 30 }
            [pscustomobject]@{ DisplayName = 'Relian AVD logon timeouts'; Path = 'SOFTWARE\FSLogix\Apps'; Name = 'CleanupInvalidSessions'; Value = 1 }
        }
        'azure-ad-sso-zone' {
            [pscustomobject]@{ DisplayName = 'Relian Azure AD SSO zone'; Path = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\microsoftazuread-sso.com\autologon'; Name = 'https'; Value = 1 }
        }
        'cloud-kerberos-ticket' {
            [pscustomobject]@{ DisplayName = 'Relian cloud Kerberos ticket'; Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters'; Name = 'CloudKerberosTicketRetrievalEnabled'; Value = 1 }
        }
        'edge-startup-boost-off' {
            [pscustomobject]@{ DisplayName = 'Relian Edge startup boost off'; Path = 'SOFTWARE\Policies\Microsoft\Edge'; Name = 'StartupBoostEnabled'; Value = 0 }
        }
        'fast-startup-off' {
            [pscustomobject]@{ DisplayName = 'Relian fast startup off'; Path = 'SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Value = 0 }
        }
        'fslogix-cleanup-invalid-sessions' {
            [pscustomobject]@{ DisplayName = 'Relian FSLogix cleanup invalid sessions'; Path = 'SOFTWARE\FSLogix\Apps'; Name = 'CleanupInvalidSessions'; Value = 1 }
        }
        'fslogix-no-roam-recycle-bin' {
            [pscustomobject]@{ DisplayName = 'Relian FSLogix roam recycle bin off'; Path = 'SOFTWARE\FSLogix\Profiles'; Name = 'RoamRecycleBin'; Value = 0 }
        }
        'long-paths' {
            [pscustomobject]@{ DisplayName = 'Relian long paths'; Path = 'SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 1 }
        }
        'mapped-drive-reconnect' {
            [pscustomobject]@{ DisplayName = 'Relian mapped drive reconnect'; Path = 'SYSTEM\CurrentControlSet\Control\NetworkProvider'; Name = 'RestoreConnection'; Value = 1 }
        }
        'onedrive-dehydrate-team-sites' {
            [pscustomobject]@{ DisplayName = 'Relian OneDrive dehydrate team sites'; Path = 'SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'DehydrateSyncedTeamSites'; Value = 1 }
        }
        'teams-avd-media' {
            [pscustomobject]@{ DisplayName = 'Relian Teams AVD media'; Path = 'SOFTWARE\Microsoft\Teams'; Name = 'IsWVDEnvironment'; Value = 1 }
        }
    }
}

function Get-RelianApplyActionDisplayName {
    param([string]$ActionId)
    $rows = @(Get-RelianApplyActionCatalog -ActionId $ActionId)
    if ($rows.Count -lt 1) {
        return ''
    }
    return [string]($rows[0].DisplayName)
}

function Get-RelianApplyActionRequirements {
    param([string]$ActionId)
    # Callers wrap this output in @(). Do not return it with a unary comma.
    foreach ($row in @(Get-RelianApplyActionCatalog -ActionId $ActionId)) {
        [pscustomobject]@{
            Path  = [string]$row.Path
            Name  = [string]$row.Name
            Value = $row.Value
        }
    }
}

function Test-RelianApplyActionDword {
    param(
        $Actual,
        $Expected
    )
    if ($null -eq $Actual -or $null -eq $Expected) {
        return $false
    }
    if ($Actual -is [bool] -or $Actual -is [string] -or $Actual -is [double] -or $Actual -is [float] -or $Actual -is [decimal]) {
        return $false
    }
    $whole = $Actual -is [byte] -or $Actual -is [int16] -or $Actual -is [int] -or $Actual -is [long] -or $Actual -is [uint16] -or $Actual -is [uint32] -or $Actual -is [uint64]
    if (-not $whole) {
        return $false
    }
    try {
        return ([int64]$Actual) -eq ([int64]$Expected)
    } catch {
        return $false
    }
}

function Get-RelianApplyActionEntryField {
    param(
        $Entry,
        [string]$Field
    )
    if ($null -eq $Entry) {
        return $null
    }
    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($key in @($Entry.Keys)) {
            if ([string]::Equals([string]$key, $Field, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Entry[$key]
            }
        }
        return $null
    }
    foreach ($property in @($Entry.PSObject.Properties)) {
        if ([string]::Equals([string]$property.Name, $Field, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }
    return $null
}

function Get-RelianApplyActionViewValue {
    param(
        [string]$Path,
        [string]$Name,
        $Registry
    )
    foreach ($entry in @($Registry)) {
        if ($null -eq $entry) {
            continue
        }
        $entryPath = Get-RelianApplyActionEntryField -Entry $entry -Field 'Path'
        $entryName = Get-RelianApplyActionEntryField -Entry $entry -Field 'Name'
        if ([string]::IsNullOrWhiteSpace([string]$entryPath) -or [string]::IsNullOrWhiteSpace([string]$entryName)) {
            continue
        }
        $pathMatches = [string]::Equals([string]$entryPath, $Path, [System.StringComparison]::OrdinalIgnoreCase)
        $nameMatches = [string]::Equals([string]$entryName, $Name, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $pathMatches -or -not $nameMatches) {
            continue
        }
        return (Get-RelianApplyActionEntryField -Entry $entry -Field 'Value')
    }
    return $null
}

function Get-RelianApplyActionLiveValue {
    param(
        [string]$Path,
        [string]$Name
    )
    # A missing key or value is not installed. The error must not become stderr.
    try {
        $relative = $Path.Trim('\')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains(':') -or $relative.Contains('/')) {
            return $null
        }
        $full = 'HKLM:\' + $relative
        if (-not (Test-Path -LiteralPath $full -ErrorAction Stop)) {
            return $null
        }
        $item = Get-ItemProperty -LiteralPath $full -ErrorAction Stop
        if ($null -eq $item) {
            return $null
        }
        foreach ($property in @($item.PSObject.Properties)) {
            if ([string]::Equals([string]$property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $property.Value
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-RelianApplyActionValue {
    param(
        [string]$Path,
        [string]$Name,
        $Registry
    )
    try {
        # A null view reads HKLM. An injected view uses the action path, without a hive.
        if ($null -eq $Registry) {
            return (Get-RelianApplyActionLiveValue -Path $Path -Name $Name)
        }
        return (Get-RelianApplyActionViewValue -Path $Path -Name $Name -Registry $Registry)
    } catch {
        return $null
    }
}

function Test-RelianApplyActionInstalled {
    param(
        [string]$ActionId,
        $Registry
    )
    if (Test-RelianApplyActionUnresolvedToken -Text $ActionId) {
        return $false
    }
    $requirements = @(Get-RelianApplyActionRequirements -ActionId $ActionId)
    if ($requirements.Count -lt 1) {
        return $false
    }
    foreach ($requirement in $requirements) {
        if ($requirement -is [System.Array]) {
            return $false
        }
        $actual = Get-RelianApplyActionValue -Path ([string]$requirement.Path) -Name ([string]$requirement.Name) -Registry $Registry
        if (-not (Test-RelianApplyActionDword -Actual $actual -Expected $requirement.Value)) {
            return $false
        }
    }
    return $true
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$script:RelianApplyActionId = '__ACTION_ID__'

$definition = ''
try {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        exit 1
    }
    $definition = [System.IO.File]::ReadAllText($PSCommandPath)
} catch {
    exit 1
}
if (Test-RelianApplyActionUnresolvedToken -Text $definition) {
    exit 1
}

$actionId = [string]$script:RelianApplyActionId
$displayName = [string](Get-RelianApplyActionDisplayName -ActionId $actionId)
if ([string]::IsNullOrWhiteSpace($displayName)) {
    exit 1
}

$installed = $false
try {
    $installed = [bool](Test-RelianApplyActionInstalled -ActionId $actionId)
} catch {
    $installed = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($installed) {
    Write-Output $displayName
    exit 0
}
exit 1
