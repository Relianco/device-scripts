$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/browser-extension/Invoke-BrowserExtension.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-BrowserExtension.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-BrowserExtensionPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-BrowserExtensionPlan was not defined'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    $names = @('ExitCode', 'WriteEntry', 'RemoveEntry', 'ClearMarker', 'WriteMarker', 'PolicyValue')
    foreach ($name in $names) {
        if ($Plan.PSObject.Properties.Name -notcontains $name) {
            Fail "$Label missing property $name"
        }
    }
    $exit = $Plan.ExitCode
    $wantExit = $Expect.ExitCode
    $exitSame = ($null -eq $exit -and $null -eq $wantExit) -or ($null -ne $exit -and $null -ne $wantExit -and [int]$exit -eq [int]$wantExit)
    if (-not $exitSame) {
        Fail "$Label ExitCode '$exit' expected '$wantExit'"
    }
    foreach ($name in @('WriteEntry', 'RemoveEntry', 'ClearMarker', 'WriteMarker')) {
        if ([bool]$Plan.$name -ne [bool]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
    $actualValue = [string]$Plan.PolicyValue
    $wantValue = [string]$Expect.PolicyValue
    if ($actualValue -cne $wantValue) {
        Fail "$Label PolicyValue '$actualValue' expected '$wantValue'"
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [bool]$WriteEntry = $false,
        [bool]$RemoveEntry = $false,
        [bool]$ClearMarker = $false,
        [bool]$WriteMarker = $false,
        [string]$PolicyValue = ''
    )
    return @{
        ExitCode    = $ExitCode
        WriteEntry  = $WriteEntry
        RemoveEntry = $RemoveEntry
        ClearMarker = $ClearMarker
        WriteMarker = $WriteMarker
        PolicyValue = $PolicyValue
    }
}

$chromeId = 'a' * 32
$otherId = 'b' * 32
$firefoxId = 'example@example.invalid'
$firefoxGuid = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'
$chromePin = 'chrome-' + $chromeId
$edgePin = 'edge-' + $chromeId
$bravePin = 'brave-' + $chromeId
$firefoxPin = 'firefox-' + $firefoxId
$firefoxGuidPin = 'firefox-' + $firefoxGuid
$chromeValue = $chromeId + ';https://clients2.google.com/service/update2/crx'
$edgeValue = $chromeId + ';https://edge.microsoft.com/extensionwebstorebase/v1/crx'
$braveValue = $chromeId + ';https://clients2.google.com/service/update2/crx'
$firefoxUrl = 'https://addons.mozilla.org/firefox/downloads/latest/' + $firefoxId + '/latest.xpi'
$firefoxGuidUrl = 'https://addons.mozilla.org/firefox/downloads/latest/' + $firefoxGuid + '/latest.xpi'
$none = New-Expect
$rejected = New-Expect -ExitCode 1

function Get-Plan {
    param(
        [string]$Action,
        [string]$Pin,
        [string]$BrowserName,
        [string]$Id,
        [string]$Url = '',
        [bool]$EntryPresent = $false,
        [bool]$MarkerPresent = $false
    )
    return Get-BrowserExtensionPlan -Action $Action -PinVersion $Pin -Browser $BrowserName -ExtensionId $Id -ExtensionUrl $Url -EntryPresent $EntryPresent -MarkerPresent $MarkerPresent
}

$emptyRows = @(
    @{ Label = 'empty pin'; Pin = '' }
    @{ Label = 'whitespace pin'; Pin = '   ' }
)
foreach ($row in $emptyRows) {
    $plan = Get-Plan -Action 'Install' -Pin $row.Pin -BrowserName '' -Id ''
    Assert-Plan -Plan $plan -Expect (New-Expect -ExitCode 0) -Label $row.Label
}

$reinstall = Get-Plan -Action 'Reinstall' -Pin $chromePin -BrowserName 'Chrome' -Id $chromeId -EntryPresent $true -MarkerPresent $true
Assert-Plan -Plan $reinstall -Expect $rejected -Label 'Reinstall'

$unknown = Get-Plan -Action 'Install' -Pin $chromePin -BrowserName 'Opera' -Id $chromeId
Assert-Plan -Plan $unknown -Expect $rejected -Label 'unknown browser'

$badIds = @(
    @{ Label = 'short chromium id'; BrowserName = 'Chrome'; Id = 'aaaa' }
    @{ Label = 'chromium id outside a through p'; BrowserName = 'Edge'; Id = ('q' * 32) }
    @{ Label = 'uppercase chromium id'; BrowserName = 'Brave'; Id = ('A' * 32) }
    @{ Label = 'chromium id too long'; BrowserName = 'Chrome'; Id = ('a' * 33) }
    @{ Label = 'firefox id without a host'; BrowserName = 'Firefox'; Id = 'not-an-id' }
    @{ Label = 'firefox guid without braces'; BrowserName = 'Firefox'; Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
)
foreach ($row in $badIds) {
    $plan = Get-Plan -Action 'Install' -Pin $chromePin -BrowserName $row.BrowserName -Id $row.Id
    Assert-Plan -Plan $plan -Expect $rejected -Label $row.Label
}

$badUrls = @(
    @{ Label = 'non-Mozilla host'; Url = 'https://example.invalid/addon.xpi' }
    @{ Label = 'Mozilla lookalike host'; Url = 'https://addons.mozilla.org.example.invalid/addon.xpi' }
    @{ Label = 'http Mozilla URL'; Url = 'http://addons.mozilla.org/firefox/downloads/latest/example@example.invalid/latest.xpi' }
    @{ Label = 'Mozilla URL with userinfo'; Url = (-join @('https://', 'user', '@', 'addons.mozilla.org/firefox/downloads/latest/example@example.invalid/latest.xpi')) }
    @{ Label = 'Mozilla URL with a query string'; Url = 'https://addons.mozilla.org/firefox/downloads/latest/example@example.invalid/latest.xpi?src=dp' }
)
foreach ($row in $badUrls) {
    $plan = Get-Plan -Action 'Install' -Pin $firefoxPin -BrowserName 'Firefox' -Id $firefoxId -Url $row.Url
    Assert-Plan -Plan $plan -Expect $rejected -Label $row.Label
}

if (-not (Test-BrowserExtensionIdIsSingleSegment -ExtensionId $firefoxId)) {
    Fail 'firefox id was not a single path segment'
}
foreach ($unsafe in @(
        'name/extra@example.invalid',
        'name\extra@example.invalid',
        'name?x=1@example.invalid',
        'a:b@example.invalid'
    )) {
    if (Test-BrowserExtensionIdIsSingleSegment -ExtensionId $unsafe) {
        Fail "unsafe id was accepted as one segment: $unsafe"
    }
    $built = Get-BrowserExtensionFirefoxInstallUrl -ExtensionId $unsafe -ExtensionUrl '' -UpdateUrl 'https://addons.mozilla.org/firefox/downloads/latest/'
    if (-not [string]::IsNullOrWhiteSpace([string]$built)) {
        Fail "unsafe id built an install URL: $unsafe"
    }
}

$builtFirefox = Get-BrowserExtensionFirefoxInstallUrl -ExtensionId $firefoxId -ExtensionUrl '' -UpdateUrl 'https://addons.mozilla.org/firefox/downloads/latest/'
if ($builtFirefox -cne $firefoxUrl) {
    Fail "built firefox URL '$builtFirefox'"
}
$builtUri = [Uri]$builtFirefox
if (-not [string]::IsNullOrEmpty($builtUri.UserInfo) -or $builtUri.Host -cne 'addons.mozilla.org' -or $builtUri.Scheme -cne 'https') {
    Fail 'built firefox URL was not an https addons.mozilla.org URL without userinfo'
}

$browserRows = @(
    @{ BrowserName = 'Chrome'; Value = $chromeValue; Id = $chromeId; Url = 'https://evil.example/crx' }
    @{ BrowserName = 'Edge'; Value = $edgeValue; Id = $chromeId; Url = '' }
    @{ BrowserName = 'Brave'; Value = $braveValue; Id = $chromeId; Url = '' }
    @{ BrowserName = 'Firefox'; Value = $firefoxUrl; Id = $firefoxId; Url = '' }
    @{ BrowserName = 'Firefox'; Value = $firefoxUrl; Id = $firefoxId; Url = $firefoxUrl }
    @{ BrowserName = 'Firefox'; Value = $firefoxGuidUrl; Id = $firefoxGuid; Url = '' }
)
foreach ($row in $browserRows) {
    $expect = New-Expect -WriteEntry $true -WriteMarker $true -PolicyValue $row.Value
    $pin = $row.BrowserName.ToLowerInvariant() + '-' + $row.Id
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-Plan -Action $action -Pin $pin -BrowserName $row.BrowserName -Id $row.Id -Url $row.Url -EntryPresent $true -MarkerPresent $true
        Assert-Plan -Plan $plan -Expect $expect -Label "$action $($row.BrowserName) $($row.Id)"
    }
}

$repairMissing = Get-Plan -Action 'Repair' -Pin $chromePin -BrowserName 'Chrome' -Id $chromeId -EntryPresent $false -MarkerPresent $false
Assert-Plan -Plan $repairMissing -Expect (New-Expect -WriteEntry $true -WriteMarker $true -PolicyValue $chromeValue) -Label 'Repair missing'

$repairPresent = Get-Plan -Action 'Repair' -Pin $chromePin -BrowserName 'Chrome' -Id $chromeId -EntryPresent $true -MarkerPresent $true
Assert-Plan -Plan $repairPresent -Expect (New-Expect -ExitCode 0) -Label 'Repair present'

$repairMarker = Get-Plan -Action 'Repair' -Pin $edgePin -BrowserName 'Edge' -Id $chromeId -EntryPresent $true -MarkerPresent $false
Assert-Plan -Plan $repairMarker -Expect (New-Expect -WriteMarker $true) -Label 'Repair marker only'

$uninstallRows = @(
    @{ Label = 'Uninstall entry and marker'; Entry = $true; Marker = $true; Expect = (New-Expect -RemoveEntry $true -ClearMarker $true) }
    @{ Label = 'Uninstall entry only'; Entry = $true; Marker = $false; Expect = (New-Expect -RemoveEntry $true -ClearMarker $true) }
    @{ Label = 'Uninstall marker only'; Entry = $false; Marker = $true; Expect = (New-Expect -ClearMarker $true) }
    @{ Label = 'Uninstall nothing'; Entry = $false; Marker = $false; Expect = (New-Expect -ExitCode 0) }
)
foreach ($row in $uninstallRows) {
    $plan = Get-Plan -Action 'Uninstall' -Pin $chromePin -BrowserName 'Chrome' -Id $chromeId -EntryPresent $row.Entry -MarkerPresent $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknownAction = Get-Plan -Action 'Hold' -Pin $chromePin -BrowserName 'Chrome' -Id $chromeId
Assert-Plan -Plan $unknownAction -Expect $rejected -Label 'unknown action'

$pinOnly = @(
    @{ Label = 'chrome pin'; Pin = $chromePin; Value = $chromeValue }
    @{ Label = 'edge pin'; Pin = $edgePin; Value = $edgeValue }
    @{ Label = 'brave pin'; Pin = $bravePin; Value = $braveValue }
    @{ Label = 'firefox email pin'; Pin = $firefoxPin; Value = $firefoxUrl }
    @{ Label = 'firefox guid pin'; Pin = $firefoxGuidPin; Value = $firefoxGuidUrl }
)
foreach ($row in $pinOnly) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-BrowserExtensionPlan -Action $action -PinVersion $row.Pin -EntryPresent $false -MarkerPresent $false
        $expect = New-Expect -WriteEntry $true -WriteMarker $true -PolicyValue $row.Value
        Assert-Plan -Plan $plan -Expect $expect -Label "$action $($row.Label)"
    }
}

$pinUninstall = Get-BrowserExtensionPlan -Action 'Uninstall' -PinVersion $chromePin -EntryPresent $true -MarkerPresent $true
Assert-Plan -Plan $pinUninstall -Expect (New-Expect -RemoveEntry $true -ClearMarker $true) -Label 'pin uninstall'

$explicitWin = Get-Plan -Action 'Install' -Pin ('chrome-' + $otherId) -BrowserName 'Edge' -Id $chromeId -Url 'https://evil.example/crx'
$explicitExpect = New-Expect -WriteEntry $true -WriteMarker $true -PolicyValue $edgeValue
Assert-Plan -Plan $explicitWin -Expect $explicitExpect -Label 'explicit browser and id win'

$versionExplicit = Get-Plan -Action 'Install' -Pin '1.0.0' -BrowserName 'Chrome' -Id $chromeId
$versionExpect = New-Expect -WriteEntry $true -WriteMarker $true -PolicyValue $chromeValue
Assert-Plan -Plan $versionExplicit -Expect $versionExpect -Label 'explicit browser and id with version pin'

$emptyExplicit = Get-Plan -Action 'Install' -Pin '' -BrowserName 'Edge' -Id $chromeId
Assert-Plan -Plan $emptyExplicit -Expect $explicitExpect -Label 'explicit browser and id with empty pin'

$rejectedPins = @(
    @{ Label = 'version pin'; Pin = '1.0.0'; BrowserName = ''; Id = '' }
    @{ Label = 'uppercase browser pin'; Pin = ('Chrome-' + $chromeId); BrowserName = ''; Id = '' }
    @{ Label = 'pin with a space'; Pin = ('chrome- ' + $chromeId); BrowserName = ''; Id = '' }
    @{ Label = 'pin with a query string'; Pin = ($chromePin + '?hl=en'); BrowserName = ''; Id = '' }
    @{ Label = 'store URL with a query string'; Pin = ('https://chromewebstore.google.com/detail/name/' + $chromeId + '?hl=en'); BrowserName = ''; Id = '' }
    @{ Label = 'unknown browser pin'; Pin = ('opera-' + $chromeId); BrowserName = ''; Id = '' }
)
foreach ($row in $rejectedPins) {
    $plan = Get-Plan -Action 'Install' -Pin $row.Pin -BrowserName $row.BrowserName -Id $row.Id
    Assert-Plan -Plan $plan -Expect $rejected -Label $row.Label
}

$emptyWithoutTarget = Get-BrowserExtensionPlan -Action 'Install' -PinVersion '' -EntryPresent $true -MarkerPresent $true
Assert-Plan -Plan $emptyWithoutTarget -Expect (New-Expect -ExitCode 0) -Label 'empty pin without browser'

if ($none.WriteEntry -or $none.PolicyValue -ne '') {
    Fail 'empty expectation was not empty'
}

Write-Output 'browser-extension-plan tests passed'
exit 0
