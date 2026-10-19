$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/acrobat/Invoke-Acrobat.ps1'
$recordPath = Join-Path $repoRoot 'windows/releases/acrobat.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Acrobat.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $recordPath)) {
    Fail 'windows/releases/acrobat.json does not exist'
}

function Test-AcrobatReleaseHash {
    param([string]$Hash)
    # -match is case-insensitive. A pin is 64 lowercase hex characters, and one repeated nibble is a placeholder.
    if ($Hash -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    if ($Hash -cmatch '^(.)\1{63}$') {
        return $false
    }
    return $true
}

$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$pinnedUrl = 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip'
if ([string]$record.installerUrl -cne $pinnedUrl) {
    Fail 'installer URL is not the Acrobat enterprise zip'
}
$hashText = [string]$record.installerSha256
if (-not (Test-AcrobatReleaseHash -Hash $hashText)) {
    Fail 'installerSha256 is not a 64-character lowercase hex pin'
}
if (Test-AcrobatReleaseHash -Hash ('0' * 64)) {
    Fail '64 zeros were accepted as a pin'
}
if (Test-AcrobatReleaseHash -Hash $hashText.ToUpperInvariant()) {
    Fail 'an uppercase hash was accepted as a pin'
}
if ([int64]$record.installerSize -ne 1699354397) {
    Fail "installerSize '$($record.installerSize)' is not the measured byte size"
}
if ([string]$record.editionNote -notlike '*edition is chosen by the caller because the bytes are the same*') {
    Fail 'edition note does not say the caller chooses the edition'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-AcrobatPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-AcrobatPlan was not defined'
}
if (-not (Get-Command Invoke-AcrobatAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-AcrobatAction was not defined'
}

if ([string]$InstallerUrl -cne [string]$record.installerUrl) {
    Fail 'InstallerUrl default does not match windows/releases/acrobat.json'
}
if ([string]$InstallerSha256 -cne [string]$record.installerSha256) {
    Fail 'InstallerSha256 default does not match windows/releases/acrobat.json'
}

$source = Get-Content -LiteralPath $scriptPath -Raw
if ($source -match 'Mandatory\s*=') {
    Fail 'a parameter is Mandatory'
}
if ($source -match 'Stop-Process') {
    Fail 'the package stops a process'
}
if ($source -match 'ISX_SERIALNUMBER') {
    Fail 'the package contains a serial property'
}
$urlHits = [regex]::Matches($source, [regex]::Escape($pinnedUrl))
if ($urlHits.Count -ne 1) {
    Fail "pinned URL appears $($urlHits.Count) times"
}

$setupArgs = @(Get-AcrobatSetupArgumentList)
$expectedSetup = @('/sAll', '/rs', '/msi', '/qn')
if ($setupArgs.Count -ne $expectedSetup.Count) {
    Fail "setup arguments '$($setupArgs -join ' ')'"
}
for ($i = 0; $i -lt $expectedSetup.Count; $i++) {
    if ([string]$setupArgs[$i] -cne $expectedSetup[$i]) {
        Fail "setup argument $i '$($setupArgs[$i])' expected '$($expectedSetup[$i])'"
    }
}

$productCode = '{AC76BA86-1033-FFFF-7760-0C0F074E4100}'
$uninstallArgs = @(Get-AcrobatUninstallArgumentList -ProductCode $productCode)
if ($uninstallArgs.Count -ne 3 -or $uninstallArgs[0] -cne '/x' -or $uninstallArgs[1] -cne $productCode -or $uninstallArgs[2] -cne '/qn') {
    Fail "uninstall arguments '$($uninstallArgs -join ' ')'"
}
if ($null -ne (Get-AcrobatUninstallArgumentList -ProductCode 'Adobe Acrobat Reader')) {
    Fail 'a display name was accepted as a product code'
}

function Assert-NoWork {
    param($Plan, [string]$Label, $ExitCode)
    $exit = $Plan.ExitCode
    $exitSame = ($null -eq $exit -and $null -eq $ExitCode) -or ($null -ne $exit -and $null -ne $ExitCode -and [int]$exit -eq [int]$ExitCode)
    if (-not $exitSame) {
        Fail "$Label ExitCode '$exit' expected '$ExitCode'"
    }
    if ($Plan.RunInstaller -or $Plan.Uninstall -or $Plan.ClearMarker -or -not [string]::IsNullOrWhiteSpace([string]$Plan.WriteMarker)) {
        Fail "$Label still has work"
    }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('acrobat-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$script:DownloadCount = 0
$script:SetupCount = 0
$script:RemovedNames = [System.Collections.Generic.List[string]]::new()
$script:SeenUrls = [System.Collections.Generic.List[string]]::new()

function Reset-PlanHooks {
    $script:DownloadCount = 0
    $script:SetupCount = 0
    $script:RemovedNames.Clear()
    $script:SeenUrls.Clear()
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:SeenUrls.Add([string]$Url)
    }
    $script:StartAcrobatSetup = {
        param($SetupPath)
        $script:SetupCount++
        return 0
    }
    $script:ExpandAcrobatArchive = { param($ZipPath, $Destination) }
    $script:ResolveAcrobatSetup = { param($ExtractRoot) return 'C:\Acrobat\setup.exe' }
    $script:ReadAcrobatInstalledVersion = { return '' }
    $script:StartAcrobatUninstall = {
        param($ProductCode, $DisplayName)
        $script:RemovedNames.Add([string]$DisplayName)
        return 0
    }
}

Reset-PlanHooks
foreach ($edition in @('Standard', 'Pro')) {
    $url = Get-AcrobatInstallerUrlForEdition -Edition $edition -InstallerUrl $InstallerUrl
    if ([string]$url -cne $pinnedUrl) {
        Fail "$edition URL '$url' is not the pinned zip"
    }
    $plan = Get-AcrobatPlan -Action 'Install' -PinVersion '2.0.0.0' -Edition $edition -InstalledVersion '' -MarkerText ''
    if ($null -ne $plan.ExitCode -or -not $plan.RunInstaller -or [string]$plan.WriteMarker -cne "2.0.0.0 $edition") {
        Fail "$edition install plan did not accept the pin"
    }
    $updated = Get-AcrobatPlan -Action 'Update' -PinVersion '2.0.0.0' -Edition $edition -InstalledVersion '' -MarkerText ''
    if ([bool]$updated.RunInstaller -ne [bool]$plan.RunInstaller -or [string]$updated.WriteMarker -cne [string]$plan.WriteMarker) {
        Fail "$edition update plan differs from install"
    }
}
if ((Get-AcrobatInstallerUrlForEdition -Edition 'Standard' -InstallerUrl $InstallerUrl) -cne (Get-AcrobatInstallerUrlForEdition -Edition 'Pro' -InstallerUrl $InstallerUrl)) {
    Fail 'Standard and Pro resolved different URLs'
}

foreach ($edition in @('', 'Reader', 'standard', 'PRO', 'Acrobat Pro')) {
    $plan = Get-AcrobatPlan -Action 'Install' -PinVersion '1.0.0.0' -Edition $edition -InstalledVersion '' -MarkerText ''
    Assert-NoWork -Plan $plan -ExitCode 1 -Label "bad edition '$edition'"
    Reset-PlanHooks
    $code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition $edition -InstalledVersion '' -MarkerText '' -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath '' -MarkerRoot $root -Products @())
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
        Fail "bad edition '$edition' returned $code after $($script:DownloadCount) downloads"
    }
}

Reset-PlanHooks
foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
    $plan = Get-AcrobatPlan -Action $action -PinVersion '' -Edition 'Pro' -InstalledVersion '9.0.0.0' -MarkerText '9.0.0.0 Pro'
    Assert-NoWork -Plan $plan -ExitCode 0 -Label "$action empty pin"
    $code = [int](Invoke-AcrobatAction -Action $action -PinVersion '   ' -Edition 'Pro' -InstalledVersion '9.0.0.0' -MarkerText '9.0.0.0 Pro' -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath '' -MarkerRoot $root -Products @())
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
        Fail "$action empty pin returned $code after $($script:DownloadCount) downloads"
    }
}

$reinstall = Get-AcrobatPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -Edition 'Pro' -InstalledVersion '1.0.0.0' -MarkerText '1.0.0.0 Pro'
Assert-NoWork -Plan $reinstall -ExitCode 1 -Label 'Reinstall'
Reset-PlanHooks
$reinstallCode = [int](Invoke-AcrobatAction -Action 'Reinstall' -PinVersion '1.0.0.0' -Edition 'Standard' -InstalledVersion '1.0.0.0' -MarkerText '1.0.0.0 Standard' -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath '' -MarkerRoot $root -Products @())
if ($reinstallCode -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "Reinstall returned $reinstallCode after $($script:DownloadCount) downloads"
}

foreach ($action in @('Install', 'Update')) {
    foreach ($edition in @('Standard', 'Pro')) {
        $plan = Get-AcrobatPlan -Action $action -PinVersion '2.0.0.0' -Edition $edition -InstalledVersion '3.0.0.0' -MarkerText "2.0.0.0 $edition"
        if ($null -ne $plan.ExitCode -or $plan.RunInstaller -or [string]$plan.WriteMarker -cne "3.0.0.0 $edition") {
            Fail "$action $edition vendor-newer plan marker '$($plan.WriteMarker)' installer $($plan.RunInstaller)"
        }
        Reset-PlanHooks
        $markerRoot = Join-Path $root $edition
        $code = [int](Invoke-AcrobatAction -Action $action -PinVersion '2.0.0.0' -Edition $edition -InstalledVersion '3.0.0.0' -MarkerText "2.0.0.0 $edition" -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath '' -MarkerRoot $markerRoot -Products @())
        $written = ''
        $markerFile = Join-Path $markerRoot 'marker.txt'
        if (Test-Path -LiteralPath $markerFile) {
            $written = ([System.IO.File]::ReadAllText($markerFile)).Trim()
        }
        if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0 -or $written -cne "3.0.0.0 $edition") {
            Fail "$action $edition vendor-newer returned $code marker '$written' downloads $($script:DownloadCount) setup $($script:SetupCount)"
        }
    }
}

$kept = Get-AcrobatPlan -Action 'Install' -PinVersion '2.0.0.0' -Edition 'Pro' -InstalledVersion '3.0.0.0' -MarkerText '3.0.0.0 Pro'
if ($null -ne $kept.ExitCode -or $kept.RunInstaller -or -not [string]::IsNullOrWhiteSpace([string]$kept.WriteMarker)) {
    Fail 'vendor-newer marker was rewritten when it already matched'
}

$older = Get-AcrobatPlan -Action 'Install' -PinVersion '2.0.0.0' -Edition 'Pro' -InstalledVersion '1.0.0.0' -MarkerText '1.0.0.0 Pro'
if ($null -ne $older.ExitCode -or -not $older.RunInstaller) {
    Fail 'older than the pin did not run the installer'
}
$repairMissing = Get-AcrobatPlan -Action 'Repair' -PinVersion '2.0.0.0' -Edition 'Standard' -InstalledVersion '' -MarkerText ''
if ($null -ne $repairMissing.ExitCode -or -not $repairMissing.RunInstaller) {
    Fail 'repair did not install when Acrobat was missing'
}
$repairPresent = Get-AcrobatPlan -Action 'Repair' -PinVersion '2.0.0.0' -Edition 'Pro' -InstalledVersion '3.0.0.0' -MarkerText '3.0.0.0 Pro'
if ($null -ne $repairPresent.ExitCode -or -not $repairPresent.RunInstaller -or [string]$repairPresent.WriteMarker -cne '3.0.0.0 Pro') {
    Fail 'repair did not run the installer when Acrobat was present'
}

$names = @(
    'Adobe Acrobat Reader',
    'Adobe Acrobat Reader DC',
    'Adobe Acrobat Reader (64-bit)',
    'Adobe Acrobat',
    'Adobe Acrobat (64-bit)',
    'Adobe Acrobat Pro',
    'Notepad'
)
$products = [System.Collections.Generic.List[object]]::new()
foreach ($name in $names) {
    $products.Add([pscustomobject]@{
            DisplayName    = $name
            DisplayVersion = '24.0.0.0'
            ProductCode    = $productCode
        })
}
$selected = @(Select-AcrobatUninstallProducts -Products $products.ToArray())
$selectedNames = [System.Collections.Generic.List[string]]::new()
foreach ($item in $selected) {
    if ($null -eq $item) { continue }
    $selectedNames.Add([string]$item.DisplayName)
}
foreach ($keptName in @('Adobe Acrobat Reader', 'Adobe Acrobat Reader DC', 'Adobe Acrobat Reader (64-bit)', 'Notepad')) {
    if ($selectedNames -contains $keptName) {
        Fail "uninstall targeted $keptName"
    }
}
foreach ($removedName in @('Adobe Acrobat', 'Adobe Acrobat (64-bit)', 'Adobe Acrobat Pro')) {
    if (-not ($selectedNames -contains $removedName)) {
        Fail "uninstall skipped $removedName"
    }
}

$readerOnly = @([pscustomobject]@{
        DisplayName    = 'Adobe Acrobat Reader'
        DisplayVersion = '24.0.0.0'
        ProductCode    = $productCode
    })
if (-not [string]::IsNullOrWhiteSpace((Get-AcrobatInstalledVersionFromProducts -Products $readerOnly))) {
    Fail 'Reader counted as the installed Acrobat version'
}

Reset-PlanHooks
$uninstallRoot = Join-Path $root 'uninstall'
New-Item -ItemType Directory -Path $uninstallRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $uninstallRoot 'marker.txt'), '2.0.0.0 Pro')
$uninstallCode = [int](Invoke-AcrobatAction -Action 'Uninstall' -PinVersion '2.0.0.0' -Edition 'Pro' -InstalledVersion '2.0.0.0' -MarkerText '2.0.0.0 Pro' -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath '' -MarkerRoot $uninstallRoot -Products $products.ToArray())
if ($uninstallCode -ne 0 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
    Fail "uninstall returned $uninstallCode downloads $($script:DownloadCount) setup $($script:SetupCount)"
}
if ($script:RemovedNames -contains 'Adobe Acrobat Reader' -or $script:RemovedNames -contains 'Adobe Acrobat Reader DC') {
    Fail "uninstall hook targeted $($script:RemovedNames -join ', ')"
}
if (-not ($script:RemovedNames -contains 'Adobe Acrobat (64-bit)')) {
    Fail 'uninstall hook skipped Adobe Acrobat (64-bit)'
}
if (Test-Path -LiteralPath (Join-Path $uninstallRoot 'marker.txt')) {
    Fail 'uninstall left the marker'
}

$nothing = Get-AcrobatPlan -Action 'Uninstall' -PinVersion '2.0.0.0' -Edition 'Pro' -InstalledVersion '' -MarkerText ''
Assert-NoWork -Plan $nothing -ExitCode 0 -Label 'uninstall nothing'

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'acrobat-plan tests passed'
exit 0
