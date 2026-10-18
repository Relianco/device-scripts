# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# Chromium forcelist values use that browser's fixed update URL. The caller
# cannot choose the update host. Firefox force_installed needs an install URL
# on addons.mozilla.org. This package does not download the extension.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Browser,
    [string]$ExtensionId,
    [string]$ExtensionUrl,
    [string]$CancelPath = '',
    [string]$MarkerRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-BrowserExtensionBrowsers {
    return @(
        [pscustomobject]@{
            Name      = 'Chrome'
            Kind      = 'Chromium'
            Policy    = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
            UpdateUrl = 'https://clients2.google.com/service/update2/crx'
        }
        [pscustomobject]@{
            Name      = 'Edge'
            Kind      = 'Chromium'
            Policy    = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
            UpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
        }
        [pscustomobject]@{
            Name      = 'Brave'
            Kind      = 'Chromium'
            Policy    = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist'
            UpdateUrl = 'https://clients2.google.com/service/update2/crx'
        }
        [pscustomobject]@{
            Name      = 'Firefox'
            Kind      = 'Firefox'
            Policy    = 'policies.json'
            UpdateUrl = 'https://addons.mozilla.org/firefox/downloads/latest/'
        }
    )
}

function Get-BrowserExtensionBrowser {
    param([string]$Name)
    foreach ($browser in @(Get-BrowserExtensionBrowsers)) {
        if ($browser.Name -eq $Name) {
            return $browser
        }
    }
    return $null
}

function Get-BrowserExtensionFirefoxPolicyPath {
    $root = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    return ($root.TrimEnd('\', '/') + '\Mozilla Firefox\distribution\policies.json')
}

function Test-BrowserExtensionChromiumId {
    param([string]$ExtensionId)
    return [regex]::IsMatch([string]$ExtensionId, '^[a-p]{32}$')
}

function Test-BrowserExtensionFirefoxId {
    param([string]$ExtensionId)
    $email = '^[A-Za-z0-9._+-]+@[A-Za-z0-9][A-Za-z0-9.-]*$'
    $guid = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
    if ([regex]::IsMatch([string]$ExtensionId, $email)) {
        return $true
    }
    if ([regex]::IsMatch([string]$ExtensionId, $guid)) {
        return $true
    }
    return $false
}

function Test-BrowserExtensionId {
    param(
        [string]$Browser,
        [string]$ExtensionId
    )
    $info = Get-BrowserExtensionBrowser -Name $Browser
    if ($null -eq $info) {
        return $false
    }
    if ($info.Kind -eq 'Chromium') {
        return [bool](Test-BrowserExtensionChromiumId -ExtensionId $ExtensionId)
    }
    return [bool](Test-BrowserExtensionFirefoxId -ExtensionId $ExtensionId)
}

function Test-BrowserExtensionIdHasUserInfo {
    param([string]$ExtensionId)
    if ([string]$ExtensionId -like '*://*') {
        return $true
    }
    return [regex]::IsMatch([string]$ExtensionId, '^[^@:/\\?]*:[^@:/\\?]*@')
}

function Test-BrowserExtensionIdIsSingleSegment {
    param([string]$ExtensionId)
    if ([string]::IsNullOrWhiteSpace($ExtensionId)) {
        return $false
    }
    if ($ExtensionId.Contains('/') -or $ExtensionId.Contains('\') -or $ExtensionId.Contains('?')) {
        return $false
    }
    if (Test-BrowserExtensionIdHasUserInfo -ExtensionId $ExtensionId) {
        return $false
    }
    return $true
}

function Test-BrowserExtensionMozillaUrl {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
    } catch {
        return $false
    }
    if (-not $uri.IsAbsoluteUri) {
        return $false
    }
    if (-not $uri.Scheme.Equals('https', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not $uri.Host.Equals('addons.mozilla.org', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $false
    }
    return $true
}

function Get-BrowserExtensionFirefoxInstallUrl {
    param(
        [string]$ExtensionId,
        [string]$ExtensionUrl,
        [string]$UpdateUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($ExtensionUrl)) {
        $trimmed = $ExtensionUrl.Trim()
        if (-not (Test-BrowserExtensionMozillaUrl -Url $trimmed)) {
            return $null
        }
        return $trimmed
    }
    if (-not (Test-BrowserExtensionIdIsSingleSegment -ExtensionId $ExtensionId)) {
        return $null
    }
    $base = [string]$UpdateUrl
    if (-not $base.EndsWith('/')) {
        $base += '/'
    }
    $built = $base + $ExtensionId + '/latest.xpi'
    if (-not (Test-BrowserExtensionMozillaUrl -Url $built)) {
        return $null
    }
    return $built
}

function Get-BrowserExtensionPolicyValue {
    param(
        [string]$Browser,
        [string]$ExtensionId,
        [string]$ExtensionUrl
    )
    $info = Get-BrowserExtensionBrowser -Name $Browser
    if ($null -eq $info) {
        return $null
    }
    if ($info.Kind -eq 'Chromium') {
        if (-not (Test-BrowserExtensionChromiumId -ExtensionId $ExtensionId)) {
            return $null
        }
        return ($ExtensionId + ';' + $info.UpdateUrl)
    }
    if (-not (Test-BrowserExtensionFirefoxId -ExtensionId $ExtensionId)) {
        return $null
    }
    return Get-BrowserExtensionFirefoxInstallUrl -ExtensionId $ExtensionId -ExtensionUrl $ExtensionUrl -UpdateUrl $info.UpdateUrl
}

function New-BrowserExtensionPlan {
    param(
        $ExitCode = $null,
        [bool]$WriteEntry = $false,
        [bool]$RemoveEntry = $false,
        [bool]$ClearMarker = $false,
        [bool]$WriteMarker = $false,
        [string]$PolicyValue = ''
    )
    return [pscustomobject]@{
        ExitCode    = $ExitCode
        WriteEntry  = $WriteEntry
        RemoveEntry = $RemoveEntry
        ClearMarker = $ClearMarker
        WriteMarker = $WriteMarker
        PolicyValue = $PolicyValue
    }
}

function Get-BrowserExtensionPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$Browser,
        [string]$ExtensionId,
        [string]$ExtensionUrl,
        [bool]$EntryPresent,
        [bool]$MarkerPresent
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-BrowserExtensionPlan -ExitCode 0
    }
    if ($Action -eq 'Reinstall') {
        return New-BrowserExtensionPlan -ExitCode 1
    }

    $info = Get-BrowserExtensionBrowser -Name $Browser
    if ($null -eq $info) {
        return New-BrowserExtensionPlan -ExitCode 1
    }
    if (-not (Test-BrowserExtensionId -Browser $info.Name -ExtensionId $ExtensionId)) {
        return New-BrowserExtensionPlan -ExitCode 1
    }
    if ($info.Kind -eq 'Firefox' -and -not [string]::IsNullOrWhiteSpace($ExtensionUrl)) {
        if (-not (Test-BrowserExtensionMozillaUrl -Url $ExtensionUrl.Trim())) {
            return New-BrowserExtensionPlan -ExitCode 1
        }
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    if ($normalized -eq 'Uninstall') {
        if (-not $EntryPresent -and -not $MarkerPresent) {
            return New-BrowserExtensionPlan -ExitCode 0
        }
        return New-BrowserExtensionPlan -RemoveEntry $EntryPresent -ClearMarker $true
    }

    $policyValue = Get-BrowserExtensionPolicyValue -Browser $info.Name -ExtensionId $ExtensionId -ExtensionUrl $ExtensionUrl
    if ([string]::IsNullOrWhiteSpace($policyValue)) {
        return New-BrowserExtensionPlan -ExitCode 1
    }

    if ($normalized -eq 'Install') {
        return New-BrowserExtensionPlan -WriteEntry $true -WriteMarker $true -PolicyValue $policyValue
    }
    if ($normalized -eq 'Repair') {
        if ($EntryPresent) {
            if ($MarkerPresent) {
                return New-BrowserExtensionPlan -ExitCode 0
            }
            return New-BrowserExtensionPlan -WriteMarker $true
        }
        return New-BrowserExtensionPlan -WriteEntry $true -WriteMarker $true -PolicyValue $policyValue
    }
    return New-BrowserExtensionPlan -ExitCode 1
}

function New-BrowserExtensionPolicyStore {
    return [pscustomobject]@{
        Chrome             = [System.Collections.Generic.List[object]]::new()
        Edge               = [System.Collections.Generic.List[object]]::new()
        Brave              = [System.Collections.Generic.List[object]]::new()
        FirefoxSettings    = [ordered]@{}
        FirefoxPolicies    = [ordered]@{}
        FirefoxPolicyFile  = ''
        UseRegistry        = $false
    }
}

function Get-BrowserExtensionMarkerPath {
    param(
        [string]$Root,
        [string]$Browser,
        [string]$ExtensionId
    )
    $browserRoot = Join-Path $Root $Browser
    $idRoot = Join-Path $browserRoot $ExtensionId
    return (Join-Path $idRoot 'marker.txt')
}

function Write-BrowserExtensionMarker {
    param(
        [string]$Path,
        [string]$PinVersion
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $PinVersion.Trim(), $utf8)
}

function Clear-BrowserExtensionMarker {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Test-BrowserExtensionCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function Get-BrowserExtensionNextValueName {
    param($Items)
    $max = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        $parsed = 0
        if ([int]::TryParse([string]$item.Name, [ref]$parsed) -and $parsed -gt $max) {
            $max = $parsed
        }
    }
    return [string]($max + 1)
}

function Set-BrowserExtensionForcelistEntry {
    param(
        $Items,
        [string]$ExtensionId,
        [string]$PolicyValue
    )
    $prefix = $ExtensionId + ';'
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        if (([string]$item.Data).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            if ([string]$item.Data -cne $PolicyValue) {
                $item.Data = $PolicyValue
                return $true
            }
            return $false
        }
    }
    $Items.Add([pscustomobject]@{
            Name = (Get-BrowserExtensionNextValueName -Items $Items)
            Data = $PolicyValue
        })
    return $true
}

function Remove-BrowserExtensionForcelistEntry {
    param(
        $Items,
        [string]$ExtensionId
    )
    $prefix = $ExtensionId + ';'
    $kept = [System.Collections.Generic.List[object]]::new()
    $removed = $false
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        if (([string]$item.Data).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $removed = $true
            continue
        }
        $kept.Add($item)
    }
    if ($removed) {
        $Items.Clear()
        foreach ($item in @($kept)) {
            $Items.Add($item)
        }
    }
    return $removed
}

function Test-BrowserExtensionForcelistExact {
    param(
        $Items,
        [string]$PolicyValue
    )
    foreach ($item in @($Items)) {
        if ($null -ne $item -and ([string]$item.Data -ceq $PolicyValue)) {
            return $true
        }
    }
    return $false
}

function Test-BrowserExtensionForcelistListed {
    param(
        $Items,
        [string]$ExtensionId
    )
    $prefix = $ExtensionId + ';'
    foreach ($item in @($Items)) {
        if ($null -ne $item -and ([string]$item.Data).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function ConvertTo-BrowserExtensionData {
    param($Value)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string] -or $Value -is [ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $copy[[string]$key] = ConvertTo-BrowserExtensionData -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $copy[$prop.Name] = ConvertTo-BrowserExtensionData -Value $prop.Value
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $list.Add((ConvertTo-BrowserExtensionData -Value $item))
        }
        return $list.ToArray()
    }
    return $Value
}

function Import-BrowserExtensionFirefoxPolicy {
    param(
        $Store,
        [string]$Path
    )
    $Store.FirefoxSettings = [ordered]@{}
    $Store.FirefoxPolicies = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $true
    }
    try {
        $doc = $raw | ConvertFrom-Json
    } catch {
        return $false
    }
    $data = ConvertTo-BrowserExtensionData -Value $doc
    if ($data -isnot [System.Collections.IDictionary]) {
        return $false
    }
    if (-not $data.Contains('policies')) {
        return $true
    }
    $policies = $data['policies']
    if ($policies -isnot [System.Collections.IDictionary]) {
        return $false
    }
    foreach ($key in @($policies.Keys)) {
        if ($key -eq 'ExtensionSettings') {
            continue
        }
        $Store.FirefoxPolicies[$key] = $policies[$key]
    }
    if ($policies.Contains('ExtensionSettings')) {
        $settings = $policies['ExtensionSettings']
        if ($null -eq $settings) {
            return $true
        }
        if ($settings -isnot [System.Collections.IDictionary]) {
            return $false
        }
        foreach ($id in @($settings.Keys)) {
            $Store.FirefoxSettings[$id] = $settings[$id]
        }
    }
    return $true
}

function Export-BrowserExtensionFirefoxPolicy {
    param(
        $Store,
        [string]$Path
    )
    $policies = [ordered]@{}
    foreach ($key in @($Store.FirefoxPolicies.Keys)) {
        $policies[$key] = $Store.FirefoxPolicies[$key]
    }
    $policies['ExtensionSettings'] = $Store.FirefoxSettings
    $root = [ordered]@{ policies = $policies }
    $json = $root | ConvertTo-Json -Depth 30
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Set-BrowserExtensionFirefoxEntry {
    param(
        $Store,
        [string]$ExtensionId,
        [string]$InstallUrl
    )
    if (-not $Store.FirefoxSettings.Contains($ExtensionId)) {
        $Store.FirefoxSettings[$ExtensionId] = [ordered]@{
            installation_mode = 'force_installed'
            install_url       = $InstallUrl
        }
        return $true
    }
    $current = $Store.FirefoxSettings[$ExtensionId]
    if ($current -isnot [System.Collections.IDictionary]) {
        $Store.FirefoxSettings[$ExtensionId] = [ordered]@{
            installation_mode = 'force_installed'
            install_url       = $InstallUrl
        }
        return $true
    }
    $changed = $false
    if ([string]$current['installation_mode'] -cne 'force_installed') {
        $current['installation_mode'] = 'force_installed'
        $changed = $true
    }
    if ([string]$current['install_url'] -cne $InstallUrl) {
        $current['install_url'] = $InstallUrl
        $changed = $true
    }
    return $changed
}

function Remove-BrowserExtensionFirefoxEntry {
    param(
        $Store,
        [string]$ExtensionId
    )
    if (-not $Store.FirefoxSettings.Contains($ExtensionId)) {
        return $false
    }
    [void]$Store.FirefoxSettings.Remove($ExtensionId)
    return $true
}

function Test-BrowserExtensionFirefoxExact {
    param(
        $Store,
        [string]$ExtensionId,
        [string]$InstallUrl
    )
    if (-not $Store.FirefoxSettings.Contains($ExtensionId)) {
        return $false
    }
    $current = $Store.FirefoxSettings[$ExtensionId]
    if ($current -isnot [System.Collections.IDictionary]) {
        return $false
    }
    return ([string]$current['installation_mode'] -ceq 'force_installed' -and [string]$current['install_url'] -ceq $InstallUrl)
}

function Get-BrowserExtensionForcelistEdits {
    param(
        $Before,
        $After
    )
    $beforeMap = @{}
    foreach ($item in @($Before)) {
        if ($null -eq $item) {
            continue
        }
        $beforeMap[[string]$item.Name] = [string]$item.Data
    }
    $afterMap = @{}
    foreach ($item in @($After)) {
        if ($null -eq $item) {
            continue
        }
        $afterMap[[string]$item.Name] = [string]$item.Data
    }
    $set = [System.Collections.Generic.List[object]]::new()
    $remove = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($afterMap.Keys)) {
        if (-not $beforeMap.ContainsKey($name) -or ($beforeMap[$name] -cne $afterMap[$name])) {
            $set.Add([pscustomobject]@{ Name = [string]$name; Data = [string]$afterMap[$name] })
        }
    }
    foreach ($name in @($beforeMap.Keys)) {
        if (-not $afterMap.ContainsKey($name)) {
            $remove.Add([string]$name)
        }
    }
    return [pscustomobject]@{
        Set    = $set
        Remove = $remove
    }
}

function Read-BrowserExtensionForcelist {
    param([string]$PolicyPath)
    $items = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $PolicyPath)) {
        return $items
    }
    $key = Get-Item -LiteralPath $PolicyPath
    foreach ($name in @($key.GetValueNames())) {
        if ([string]::IsNullOrEmpty([string]$name)) {
            continue
        }
        $items.Add([pscustomobject]@{
                Name = [string]$name
                Data = [string]$key.GetValue($name)
            })
    }
    return $items
}

function Write-BrowserExtensionForcelistChanges {
    param(
        [string]$PolicyPath,
        $Before,
        $After
    )
    $edits = Get-BrowserExtensionForcelistEdits -Before $Before -After $After
    if ($edits.Set.Count -eq 0 -and $edits.Remove.Count -eq 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $PolicyPath)) {
        if ($edits.Set.Count -eq 0) {
            return
        }
        New-Item -Path $PolicyPath -Force | Out-Null
    }
    foreach ($item in @($edits.Set)) {
        New-ItemProperty -LiteralPath $PolicyPath -Name $item.Name -PropertyType String -Value $item.Data -Force | Out-Null
    }
    foreach ($name in @($edits.Remove)) {
        Remove-ItemProperty -LiteralPath $PolicyPath -Name $name
    }
}

function Invoke-BrowserExtensionPolicy {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$Browser,
        [string]$ExtensionId,
        [string]$ExtensionUrl,
        [string]$CancelPath,
        [string]$MarkerRoot,
        $Store
    )

    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return 0
    }
    if ($null -eq $Store) {
        return 1
    }

    $planArgs = @{
        Action       = $Action
        PinVersion   = $PinVersion
        Browser      = $Browser
        ExtensionId  = $ExtensionId
        ExtensionUrl = $ExtensionUrl
    }
    # Reject a bad id, browser, or URL before reading policy state.
    $preflight = Get-BrowserExtensionPlan @planArgs -EntryPresent $false -MarkerPresent $false
    if ($preflight.ExitCode -eq 1) {
        return 1
    }

    $info = Get-BrowserExtensionBrowser -Name $Browser
    if ($null -eq $info) {
        return 1
    }

    if ($info.Kind -eq 'Firefox' -and -not [string]::IsNullOrWhiteSpace([string]$Store.FirefoxPolicyFile)) {
        $imported = Import-BrowserExtensionFirefoxPolicy -Store $Store -Path ([string]$Store.FirefoxPolicyFile)
        if (-not $imported) {
            return 1
        }
    }

    $items = $null
    $before = $null
    if ($info.Kind -eq 'Chromium') {
        $items = $Store.($info.Name)
        if ($Store.UseRegistry) {
            try {
                $loaded = Read-BrowserExtensionForcelist -PolicyPath $info.Policy
            } catch {
                return 1
            }
            $items.Clear()
            foreach ($item in @($loaded)) {
                $items.Add($item)
            }
        }
        $before = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($items)) {
            $before.Add([pscustomobject]@{ Name = [string]$item.Name; Data = [string]$item.Data })
        }
    }

    $markerPath = ''
    $markerPresent = $false
    if (-not [string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $markerPath = Get-BrowserExtensionMarkerPath -Root $MarkerRoot -Browser $info.Name -ExtensionId $ExtensionId
        $markerPresent = [bool](Test-Path -LiteralPath $markerPath)
    }

    $policyValue = Get-BrowserExtensionPolicyValue -Browser $info.Name -ExtensionId $ExtensionId -ExtensionUrl $ExtensionUrl
    $entryPresent = $false
    if ($Action -eq 'Uninstall') {
        if ($info.Kind -eq 'Firefox') {
            $entryPresent = [bool]$Store.FirefoxSettings.Contains($ExtensionId)
        } else {
            $entryPresent = [bool](Test-BrowserExtensionForcelistListed -Items $items -ExtensionId $ExtensionId)
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$policyValue)) {
        if ($info.Kind -eq 'Firefox') {
            $entryPresent = [bool](Test-BrowserExtensionFirefoxExact -Store $Store -ExtensionId $ExtensionId -InstallUrl $policyValue)
        } else {
            $entryPresent = [bool](Test-BrowserExtensionForcelistExact -Items $items -PolicyValue $policyValue)
        }
    }

    $plan = Get-BrowserExtensionPlan @planArgs -EntryPresent $entryPresent -MarkerPresent $markerPresent
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $willWrite = $plan.WriteEntry -or $plan.RemoveEntry -or $plan.ClearMarker -or $plan.WriteMarker
    if ($willWrite -and (Test-BrowserExtensionCancelled -CancelPath $CancelPath)) {
        return 130
    }

    $policyChanged = $false
    if ($plan.RemoveEntry) {
        if ($info.Kind -eq 'Firefox') {
            if (Remove-BrowserExtensionFirefoxEntry -Store $Store -ExtensionId $ExtensionId) {
                $policyChanged = $true
            }
        } elseif (Remove-BrowserExtensionForcelistEntry -Items $items -ExtensionId $ExtensionId) {
            $policyChanged = $true
        }
    }
    if ($plan.WriteEntry) {
        if ([string]::IsNullOrWhiteSpace([string]$plan.PolicyValue)) {
            return 1
        }
        if ($info.Kind -eq 'Firefox') {
            if (Set-BrowserExtensionFirefoxEntry -Store $Store -ExtensionId $ExtensionId -InstallUrl $plan.PolicyValue) {
                $policyChanged = $true
            }
        } elseif (Set-BrowserExtensionForcelistEntry -Items $items -ExtensionId $ExtensionId -PolicyValue $plan.PolicyValue) {
            $policyChanged = $true
        }
    }

    if ($policyChanged -and $info.Kind -eq 'Firefox' -and -not [string]::IsNullOrWhiteSpace([string]$Store.FirefoxPolicyFile)) {
        Export-BrowserExtensionFirefoxPolicy -Store $Store -Path ([string]$Store.FirefoxPolicyFile)
    }
    if ($policyChanged -and $info.Kind -eq 'Chromium' -and $Store.UseRegistry) {
        try {
            Write-BrowserExtensionForcelistChanges -PolicyPath $info.Policy -Before $before -After $items
        } catch {
            return 1
        }
    }

    if ($plan.ClearMarker) {
        Clear-BrowserExtensionMarker -Path $markerPath
    }
    if ($plan.WriteMarker -and -not [string]::IsNullOrWhiteSpace($markerPath)) {
        Write-BrowserExtensionMarker -Path $markerPath -PinVersion $PinVersion
    }
    return 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    $MarkerRoot = Join-Path $programData 'Relian\browser-extension'
}

$store = New-BrowserExtensionPolicyStore
$store.UseRegistry = $true
$selected = Get-BrowserExtensionBrowser -Name $Browser
if ($null -ne $selected -and $selected.Kind -eq 'Firefox') {
    $store.FirefoxPolicyFile = Get-BrowserExtensionFirefoxPolicyPath
}

$code = [int](Invoke-BrowserExtensionPolicy -Action $Action -PinVersion $PinVersion -Browser $Browser -ExtensionId $ExtensionId -ExtensionUrl $ExtensionUrl -CancelPath $CancelPath -MarkerRoot $MarkerRoot -Store $store)
exit $code
