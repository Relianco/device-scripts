$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/browser-extension/Invoke-BrowserExtension.ps1'
$recordPath = Join-Path $repoRoot 'releases/browser-extension.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    $env:RELIAN_DEPLOY_CANCEL = $null
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-BrowserExtension.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $recordPath)) {
    Fail 'releases/browser-extension.json does not exist'
}

$source = [System.IO.File]::ReadAllText($scriptPath)
if ($source -match '\[Parameter\(Mandatory') {
    Fail 'a parameter is Mandatory'
}
foreach ($name in @('DeploymentType', 'Action', 'PinVersion', 'Browser', 'ExtensionId', 'ExtensionUrl', 'CancelPath', 'MarkerRoot')) {
    if (-not $source.Contains('$' + $name)) {
        Fail "source missing parameter $name"
    }
}
foreach ($banned in @('Invoke-WebRequest', 'Start-BitsTransfer', 'WebClient', 'LastPass', 'lastpass', 'sha256', 'Ninja-Property-', 'relian_git_deploy_token')) {
    if ($source.Contains($banned)) {
        Fail "source contains $banned"
    }
}
$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
$guardAt = $source.IndexOf($guardNeedle, [System.StringComparison]::Ordinal)
$exitAt = $source.LastIndexOf('exit $code', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $guardAt -gt $exitAt) {
    Fail 'dot-source test guard is not before the script exit'
}

$recordText = [System.IO.File]::ReadAllText($recordPath)
foreach ($banned in @('sha256', 'sha1', 'md5', 'hash', 'installer')) {
    if ($recordText.ToLowerInvariant().Contains($banned)) {
        Fail "release record contains $banned"
    }
}
$record = $recordText | ConvertFrom-Json
if ([string]$record.name -cne 'Browser extension') {
    Fail 'release name is not Browser extension'
}
$recordNames = @($record.PSObject.Properties.Name)
foreach ($name in $recordNames) {
    if (@('name', 'browsers') -notcontains $name) {
        Fail "release record has unexpected property $name"
    }
}
if (@($record.browsers).Count -ne 4) {
    Fail 'release record does not list four browsers'
}

$chromeId = 'a' * 32
$otherId = 'b' * 32
$firefoxId = 'example@example.invalid'
$otherFirefoxId = 'other@example.invalid'
$chromeUrl = 'https://clients2.google.com/service/update2/crx'
$edgeUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
$braveUrl = 'https://clients2.google.com/service/update2/crx'
$firefoxBase = 'https://addons.mozilla.org/firefox/downloads/latest/'
$firefoxUrl = $firefoxBase + $firefoxId + '/latest.xpi'
$otherFirefoxUrl = $firefoxBase + $otherFirefoxId + '/latest.xpi'

$expected = @(
    @{
        Name      = 'Chrome'
        Policy    = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
        UpdateUrl = $chromeUrl
        Value     = ($chromeId + ';' + $chromeUrl)
    }
    @{
        Name      = 'Edge'
        Policy    = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
        UpdateUrl = $edgeUrl
        Value     = ($chromeId + ';' + $edgeUrl)
    }
    @{
        Name      = 'Brave'
        Policy    = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist'
        UpdateUrl = $braveUrl
        Value     = ($chromeId + ';' + $braveUrl)
    }
    @{
        Name      = 'Firefox'
        Policy    = 'policies.json'
        UpdateUrl = $firefoxBase
        Value     = $firefoxUrl
    }
)

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($name in @('Get-BrowserExtensionPlan', 'Invoke-BrowserExtensionPolicy', 'New-BrowserExtensionPolicyStore', 'Get-BrowserExtensionBrowsers')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "$name was not defined"
    }
}

$catalog = @(Get-BrowserExtensionBrowsers)
if ($catalog.Count -ne 4) {
    Fail 'catalog does not list four browsers'
}
for ($i = 0; $i -lt $expected.Count; $i++) {
    $want = $expected[$i]
    $have = $catalog[$i]
    $fromRecord = $record.browsers[$i]
    foreach ($pair in @(
            @{ Label = 'catalog name'; Actual = [string]$have.Name; Want = [string]$want.Name }
            @{ Label = 'catalog policy'; Actual = [string]$have.Policy; Want = [string]$want.Policy }
            @{ Label = 'catalog update URL'; Actual = [string]$have.UpdateUrl; Want = [string]$want.UpdateUrl }
            @{ Label = 'record name'; Actual = [string]$fromRecord.name; Want = [string]$want.Name }
            @{ Label = 'record policy'; Actual = [string]$fromRecord.policy; Want = [string]$want.Policy }
            @{ Label = 'record update URL'; Actual = [string]$fromRecord.updateUrl; Want = [string]$want.UpdateUrl }
        )) {
        if ($pair.Actual -cne $pair.Want) {
            Fail "$($want.Name) $($pair.Label) '$($pair.Actual)' expected '$($pair.Want)'"
        }
    }
    if (-not $source.Contains([string]$want.UpdateUrl)) {
        Fail "source missing $($want.Name) update URL"
    }
    if (-not $source.Contains([string]$want.Policy)) {
        Fail "source missing $($want.Name) policy"
    }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('browser-extension-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

function Format-Forcelist {
    param($Items)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        $parts.Add(([string]$item.Name + '=' + [string]$item.Data))
    }
    return ($parts -join '|')
}

function Format-Store {
    param($Store)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('Chrome', 'Edge', 'Brave')) {
        $lines.Add($name + ':' + (Format-Forcelist -Items $Store.$name))
    }
    $ids = @($Store.FirefoxSettings.Keys)
    $firefox = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $ids) {
        $item = $Store.FirefoxSettings[$id]
        $firefox.Add($id + '=' + [string]$item['installation_mode'] + '=' + [string]$item['install_url'])
    }
    $lines.Add('Firefox:' + ($firefox -join '|'))
    return ($lines -join "`n")
}

try {
    $markerRoot = Join-Path $temp 'markers'
    $firefoxFile = Join-Path $temp 'policies.json'
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    function New-CaseStore {
        $store = New-BrowserExtensionPolicyStore
        $store.FirefoxPolicyFile = ''
        $store.UseRegistry = $false
        return $store
    }

    function Add-Forcelist {
        param($Store, [string]$BrowserName, [string]$Name, [string]$Data)
        $Store.$BrowserName.Add([pscustomobject]@{ Name = $Name; Data = $Data })
    }

    function Invoke-Case {
        param(
            $Store,
            [string]$ActionName,
            [string]$Pin,
            [string]$BrowserName,
            [string]$Id,
            [string]$Url = '',
            [string]$Cancel = ''
        )
        return [int](Invoke-BrowserExtensionPolicy -Action $ActionName -PinVersion $Pin -Browser $BrowserName -ExtensionId $Id -ExtensionUrl $Url -CancelPath $Cancel -MarkerRoot $markerRoot -Store $Store)
    }

    for ($browserIndex = 0; $browserIndex -lt $expected.Count; $browserIndex++) {
        $case = $expected[$browserIndex]
        if ([string]$case.Name -eq 'Firefox') {
            continue
        }
        $store = New-CaseStore
        $neighbor = $otherId + ';' + [string]$case.UpdateUrl
        Add-Forcelist -Store $store -BrowserName $case.Name -Name '2' -Data $neighbor
        $beforeOthers = @{}
        foreach ($name in @('Chrome', 'Edge', 'Brave')) {
            if ($name -ne $case.Name) {
                $beforeOthers[$name] = Format-Forcelist -Items $store.$name
            }
        }
        $code = Invoke-Case -Store $store -ActionName 'Install' -Pin '1.2.3' -BrowserName $case.Name -Id $chromeId -Url 'https://evil.example/crx'
        if ($code -ne 0) {
            Fail "$($case.Name) install exited $code"
        }
        $items = @($store.($case.Name))
        if ($items.Count -ne 2) {
            Fail "$($case.Name) forcelist count $($items.Count)"
        }
        $added = @($items | Where-Object { [string]$_.Data -ceq [string]$case.Value })
        if ($added.Count -ne 1) {
            Fail "$($case.Name) policy value '$(Format-Forcelist -Items $items)'"
        }
        $kept = @($items | Where-Object { [string]$_.Name -eq '2' })
        if ($kept.Count -ne 1 -or [string]$kept[0].Data -cne $neighbor) {
            Fail "$($case.Name) rewrote the other forcelist entry"
        }
        foreach ($name in @($beforeOthers.Keys)) {
            $now = Format-Forcelist -Items $store.$name
            if ($now -cne [string]$beforeOthers[$name]) {
                Fail "$($case.Name) install changed $name"
            }
        }
        $marker = Get-BrowserExtensionMarkerPath -Root $markerRoot -Browser $case.Name -ExtensionId $chromeId
        if (-not (Test-Path -LiteralPath $marker)) {
            Fail "$($case.Name) marker was not written"
        }
        $markerText = [System.IO.File]::ReadAllText($marker)
        if ($markerText -cne '1.2.3') {
            Fail "$($case.Name) marker text '$markerText'"
        }
        if ([string]$added[0].Data -like '*evil.example*') {
            Fail "$($case.Name) used the caller update host"
        }
    }

    $firefoxSeed = @{
        policies = @{
            Homepage = @{
                URL    = 'https://example.invalid/'
                Locked = $true
            }
            ExtensionSettings = @{
                $otherFirefoxId = @{
                    installation_mode = 'force_installed'
                    install_url       = $otherFirefoxUrl
                    default_area      = 'menupanel'
                }
            }
        }
    } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($firefoxFile, $firefoxSeed, $utf8)
    $firefoxBefore = [System.IO.File]::ReadAllText($firefoxFile)

    $store = New-CaseStore
    $store.FirefoxPolicyFile = $firefoxFile
    $code = Invoke-Case -Store $store -ActionName 'Update' -Pin '1.2.3' -BrowserName 'Firefox' -Id $firefoxId
    if ($code -ne 0) {
        Fail "Firefox update exited $code"
    }
    $doc = [System.IO.File]::ReadAllText($firefoxFile) | ConvertFrom-Json
    $settings = $doc.policies.ExtensionSettings
    $installed = $settings.PSObject.Properties[$firefoxId]
    if ($null -eq $installed) {
        Fail 'Firefox ExtensionSettings is missing the named id'
    }
    if ([string]$installed.Value.installation_mode -cne 'force_installed') {
        Fail "Firefox installation_mode '$($installed.Value.installation_mode)'"
    }
    if ([string]$installed.Value.install_url -cne $firefoxUrl) {
        Fail "Firefox install_url '$($installed.Value.install_url)'"
    }
    $firefoxUri = [Uri]([string]$installed.Value.install_url)
    if ($firefoxUri.Scheme -cne 'https' -or $firefoxUri.Host -cne 'addons.mozilla.org' -or -not [string]::IsNullOrEmpty($firefoxUri.UserInfo)) {
        Fail 'Firefox policy URL is not https on addons.mozilla.org without userinfo'
    }
    $other = $settings.PSObject.Properties[$otherFirefoxId]
    if ($null -eq $other -or [string]$other.Value.install_url -cne $otherFirefoxUrl -or [string]$other.Value.default_area -cne 'menupanel') {
        Fail 'Firefox update changed the other extension'
    }
    if ([string]$doc.policies.Homepage.URL -cne 'https://example.invalid/' -or $doc.policies.Homepage.Locked -ne $true) {
        Fail 'Firefox update changed another policy'
    }
    if (-not $store.FirefoxSettings.Contains($firefoxId)) {
        Fail 'Firefox memory store is missing the named id'
    }

    $badId = New-CaseStore
    Add-Forcelist -Store $badId -BrowserName 'Chrome' -Name '1' -Data ($otherId + ';' + $chromeUrl)
    $badBefore = Format-Store -Store $badId
    $code = Invoke-Case -Store $badId -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Chrome' -Id ('q' * 32)
    if ($code -ne 1 -or (Format-Store -Store $badId) -cne $badBefore) {
        Fail "bad id exited $code and changed policy"
    }
    $code = Invoke-Case -Store $badId -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Firefox' -Id 'not-an-id'
    if ($code -ne 1 -or (Format-Store -Store $badId) -cne $badBefore) {
        Fail "bad firefox id exited $code and changed policy"
    }

    $badUrlBytes = [System.IO.File]::ReadAllBytes($firefoxFile)
    $badUrl = New-CaseStore
    $badUrl.FirefoxPolicyFile = $firefoxFile
    foreach ($url in @(
            'https://example.invalid/addon.xpi',
            'https://addons.mozilla.org.example.invalid/addon.xpi',
            'http://addons.mozilla.org/firefox/downloads/latest/example@example.invalid/latest.xpi',
            (-join @('https://', 'user', '@', 'addons.mozilla.org/firefox/downloads/latest/example@example.invalid/latest.xpi'))
        )) {
        $code = Invoke-Case -Store $badUrl -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Firefox' -Id $firefoxId -Url $url
        $now = [System.IO.File]::ReadAllBytes($firefoxFile)
        $same = ($now.Length -eq $badUrlBytes.Length)
        if ($same) {
            for ($i = 0; $i -lt $now.Length; $i++) {
                if ($now[$i] -ne $badUrlBytes[$i]) {
                    $same = $false
                    break
                }
            }
        }
        if ($code -ne 1 -or -not $same) {
            Fail "non-Mozilla URL exited $code for $url"
        }
    }

    $uninstall = New-CaseStore
    $uninstall.FirefoxPolicyFile = $firefoxFile
    Add-Forcelist -Store $uninstall -BrowserName 'Chrome' -Name '1' -Data ($chromeId + ';' + $chromeUrl)
    Add-Forcelist -Store $uninstall -BrowserName 'Chrome' -Name '2' -Data ($otherId + ';' + $chromeUrl)
    Add-Forcelist -Store $uninstall -BrowserName 'Edge' -Name '1' -Data ($chromeId + ';' + $edgeUrl)
    $chromeMarker = Get-BrowserExtensionMarkerPath -Root $markerRoot -Browser 'Chrome' -ExtensionId $chromeId
    $edgeMarker = Get-BrowserExtensionMarkerPath -Root $markerRoot -Browser 'Edge' -ExtensionId $chromeId
    $firefoxMarker = Get-BrowserExtensionMarkerPath -Root $markerRoot -Browser 'Firefox' -ExtensionId $firefoxId
    Write-BrowserExtensionMarker -Path $chromeMarker -PinVersion '1.2.3'
    Write-BrowserExtensionMarker -Path $edgeMarker -PinVersion '9.9.9'
    Write-BrowserExtensionMarker -Path $firefoxMarker -PinVersion '1.2.3'
    $code = Invoke-Case -Store $uninstall -ActionName 'Uninstall' -Pin '1.2.3' -BrowserName 'Chrome' -Id $chromeId
    if ($code -ne 0) {
        Fail "uninstall exited $code"
    }
    $chromeItems = @($uninstall.Chrome)
    if ($chromeItems.Count -ne 1 -or [string]$chromeItems[0].Name -cne '2' -or [string]$chromeItems[0].Data -cne ($otherId + ';' + $chromeUrl)) {
        Fail "uninstall chrome list '$(Format-Forcelist -Items $chromeItems)'"
    }
    $edgeItems = @($uninstall.Edge)
    if ($edgeItems.Count -ne 1 -or [string]$edgeItems[0].Data -cne ($chromeId + ';' + $edgeUrl)) {
        Fail 'uninstall removed the Edge entry'
    }
    if (Test-Path -LiteralPath $chromeMarker) {
        Fail 'uninstall left the Chrome marker'
    }
    if (-not (Test-Path -LiteralPath $edgeMarker) -or -not (Test-Path -LiteralPath $firefoxMarker)) {
        Fail 'uninstall cleared a marker for another browser'
    }
    $afterUninstall = [System.IO.File]::ReadAllText($firefoxFile) | ConvertFrom-Json
    if ($null -eq $afterUninstall.policies.ExtensionSettings.PSObject.Properties[$firefoxId]) {
        Fail 'Chrome uninstall removed the Firefox extension'
    }

    $code = Invoke-Case -Store $uninstall -ActionName 'Uninstall' -Pin '1.2.3' -BrowserName 'Firefox' -Id $firefoxId
    if ($code -ne 0) {
        Fail "Firefox uninstall exited $code"
    }
    $afterFirefox = [System.IO.File]::ReadAllText($firefoxFile) | ConvertFrom-Json
    if ($null -ne $afterFirefox.policies.ExtensionSettings.PSObject.Properties[$firefoxId]) {
        Fail 'Firefox uninstall left the named id'
    }
    $keptFirefox = $afterFirefox.policies.ExtensionSettings.PSObject.Properties[$otherFirefoxId]
    if ($null -eq $keptFirefox -or [string]$keptFirefox.Value.install_url -cne $otherFirefoxUrl) {
        Fail 'Firefox uninstall removed the other id'
    }
    if ([string]$afterFirefox.policies.Homepage.URL -cne 'https://example.invalid/') {
        Fail 'Firefox uninstall removed another policy'
    }
    if (Test-Path -LiteralPath $firefoxMarker) {
        Fail 'Firefox uninstall left the marker'
    }
    if (-not (Test-Path -LiteralPath $edgeMarker)) {
        Fail 'Firefox uninstall cleared the Edge marker'
    }

    $emptyStore = New-CaseStore
    Add-Forcelist -Store $emptyStore -BrowserName 'Brave' -Name '1' -Data ($otherId + ';' + $braveUrl)
    $emptyBefore = Format-Store -Store $emptyStore
    $emptyMarkerRoot = Join-Path $temp 'empty-markers'
    foreach ($pin in @('', '   ')) {
        $code = [int](Invoke-BrowserExtensionPolicy -Action 'Install' -PinVersion $pin -Browser 'Brave' -ExtensionId $chromeId -ExtensionUrl '' -CancelPath '' -MarkerRoot $emptyMarkerRoot -Store $emptyStore)
        if ($code -ne 0 -or (Format-Store -Store $emptyStore) -cne $emptyBefore) {
            Fail "empty pin '$pin' exited $code"
        }
        if (Test-Path -LiteralPath $emptyMarkerRoot) {
            Fail "empty pin '$pin' wrote a marker"
        }
    }

    $unknownStore = New-CaseStore
    Add-Forcelist -Store $unknownStore -BrowserName 'Chrome' -Name '1' -Data ($chromeId + ';' + $chromeUrl)
    $unknownBefore = Format-Store -Store $unknownStore
    $code = Invoke-Case -Store $unknownStore -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Opera' -Id $chromeId
    if ($code -ne 1 -or (Format-Store -Store $unknownStore) -cne $unknownBefore) {
        Fail "unknown browser exited $code"
    }

    $cancelStore = New-CaseStore
    Add-Forcelist -Store $cancelStore -BrowserName 'Chrome' -Name '1' -Data ($otherId + ';' + $chromeUrl)
    $cancelBefore = Format-Store -Store $cancelStore
    $previousCancel = $env:RELIAN_DEPLOY_CANCEL
    try {
        $env:RELIAN_DEPLOY_CANCEL = '1'
        $code = Invoke-Case -Store $cancelStore -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Chrome' -Id $chromeId
        if ($code -ne 130 -or (Format-Store -Store $cancelStore) -cne $cancelBefore) {
            Fail "RELIAN_DEPLOY_CANCEL exited $code"
        }
        $cancelMarker = Get-BrowserExtensionMarkerPath -Root $markerRoot -Browser 'Chrome' -ExtensionId $chromeId
        if (Test-Path -LiteralPath $cancelMarker) {
            Fail 'cancel wrote a marker'
        }
    } finally {
        $env:RELIAN_DEPLOY_CANCEL = $previousCancel
    }

    $cancelPath = Join-Path $temp 'cancel.flag'
    [System.IO.File]::WriteAllText($cancelPath, '1', $utf8)
    $code = Invoke-Case -Store $cancelStore -ActionName 'Update' -Pin '1.2.3' -BrowserName 'Edge' -Id $chromeId -Cancel $cancelPath
    if ($code -ne 130 -or (Format-Store -Store $cancelStore) -cne $cancelBefore) {
        Fail "CancelPath exited $code"
    }
    if (@($cancelStore.Edge).Count -ne 0) {
        Fail 'CancelPath wrote the Edge forcelist'
    }

    $repair = New-CaseStore
    Add-Forcelist -Store $repair -BrowserName 'Edge' -Name '4' -Data ($otherId + ';' + $edgeUrl)
    $code = Invoke-Case -Store $repair -ActionName 'Repair' -Pin '1.2.3' -BrowserName 'Edge' -Id $chromeId
    if ($code -ne 0) {
        Fail "repair missing exited $code"
    }
    $repaired = @($repair.Edge | Where-Object { ([string]$_.Data).StartsWith($chromeId + ';', [System.StringComparison]::Ordinal) })
    if ($repaired.Count -ne 1 -or [string]$repaired[0].Data -cne ($chromeId + ';' + $edgeUrl)) {
        Fail 'repair did not write the missing Edge entry'
    }
    $code = Invoke-Case -Store $repair -ActionName 'Repair' -Pin '1.2.3' -BrowserName 'Edge' -Id $chromeId
    $repairedAgain = @($repair.Edge | Where-Object { ([string]$_.Data).StartsWith($chromeId + ';', [System.StringComparison]::Ordinal) })
    if ($code -ne 0 -or $repairedAgain.Count -ne 1) {
        Fail 'repair duplicated an existing entry'
    }
    $neighborKept = @($repair.Edge | Where-Object { [string]$_.Name -eq '4' })
    if ($neighborKept.Count -ne 1) {
        Fail 'repair changed the other Edge entry'
    }

    $reinstall = New-CaseStore
    Add-Forcelist -Store $reinstall -BrowserName 'Brave' -Name '1' -Data ($otherId + ';' + $braveUrl)
    $reinstallBefore = Format-Store -Store $reinstall
    $code = Invoke-Case -Store $reinstall -ActionName 'Reinstall' -Pin '1.2.3' -BrowserName 'Brave' -Id $chromeId
    if ($code -ne 1 -or (Format-Store -Store $reinstall) -cne $reinstallBefore) {
        Fail "reinstall exited $code"
    }

    $beforeEdit = @(
        [pscustomobject]@{ Name = '1'; Data = 'keep' }
        [pscustomobject]@{ Name = '2'; Data = 'drop' }
    )
    $afterEdit = @(
        [pscustomobject]@{ Name = '1'; Data = 'keep' }
        [pscustomobject]@{ Name = '3'; Data = 'add' }
    )
    $edits = Get-BrowserExtensionForcelistEdits -Before $beforeEdit -After $afterEdit
    $setNames = @($edits.Set | ForEach-Object { [string]$_.Name })
    $removeNames = @($edits.Remove)
    if ($setNames.Count -ne 1 -or $setNames[0] -cne '3' -or [string]$edits.Set[0].Data -cne 'add') {
        Fail "forcelist edit set '$( $setNames -join ',')'"
    }
    if ($removeNames.Count -ne 1 -or [string]$removeNames[0] -cne '2') {
        Fail "forcelist edit remove '$( $removeNames -join ',')'"
    }

    $corrupt = Join-Path $temp 'corrupt.json'
    [System.IO.File]::WriteAllText($corrupt, '{', $utf8)
    $corruptStore = New-CaseStore
    $corruptStore.FirefoxPolicyFile = $corrupt
    $code = Invoke-Case -Store $corruptStore -ActionName 'Install' -Pin '1.2.3' -BrowserName 'Firefox' -Id $firefoxId
    if ($code -ne 1 -or [System.IO.File]::ReadAllText($corrupt) -cne '{') {
        Fail "corrupt policies.json exited $code"
    }

    if ($firefoxBefore.Length -eq 0) {
        Fail 'firefox seed was empty'
    }
} finally {
    $env:RELIAN_DEPLOY_CANCEL = $null
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}

Write-Output 'browser-extension-policy tests passed'
exit 0
