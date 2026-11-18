$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/pdf-xchange/Invoke-PdfXchange.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/pdf-xchange.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-PdfXchange.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/pdf-xchange.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-PdfXchangePlan',
        'Invoke-PdfXchangeAction',
        'Save-PdfXchangePayload',
        'Get-PdfXchangeMsiArgumentList',
        'Test-PdfXchangeDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://downloads.pdf-xchange.com/11.1.2.0/ProV11.x64.msi'
$pinnedSha = '1d6b02f35cd50c65029dbc780f1755f2a72700805faa553097784d77c5de3fb1'
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded MSI'
}
if ([int64]$release.size -ne 453607424) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '11.1.2.0') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'ProV11.x64.msi') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/pdf-xchange.json'
}
if (-not (Test-PdfXchangePinHash -Sha256 $pinnedSha)) {
    Fail 'pinned sha256 is not a lowercase pin'
}
if (Test-PdfXchangePinHash -Sha256 $pinnedSha.ToUpperInvariant()) {
    Fail 'uppercase pin was accepted'
}
if ((Test-PdfXchangePinHash -Sha256 ('0' * 64)) -or (Test-PdfXchangePinHash -Sha256 ('a' * 64)) -or (Test-PdfXchangePinHash -Sha256 ('f' * 64))) {
    Fail 'placeholder pin was accepted'
}
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($scriptText -match 'Ninja-Property-Get|Ninja-Property-Set|NinjaOne') {
    Fail 'script calls Ninja'
}
if ($scriptText -match 'Mandatory\s*=') {
    Fail 'a parameter is Mandatory'
}

$builtinVersion = & $script:GetInstalledPdfXchangeVersion
$builtinCode = & $script:GetPdfXchangeProductCode
if ($builtinVersion -isnot [string] -or $builtinCode -isnot [string]) {
    Fail 'registry hooks did not return strings'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    foreach ($name in @('ExitCode', 'RunInstaller', 'WriteMarker', 'ClearMarker')) {
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
    foreach ($name in @('RunInstaller', 'WriteMarker')) {
        $actual = [string]$Plan.$name
        $want = [string]$Expect[$name]
        if ($actual -cne $want) {
            Fail "$Label $name '$actual' expected '$want'"
        }
    }
    if ([bool]$Plan.ClearMarker -ne [bool]$Expect.ClearMarker) {
        Fail "$Label ClearMarker '$($Plan.ClearMarker)' expected '$($Expect.ClearMarker)'"
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return @{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
    }
}

$installRows = @(
    @{
        Label = 'empty pin'
        Pin = ''
        Installed = '9.0.0.0'
        Marker = '9.0.0.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'unparseable pin'
        Pin = 'nope'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
    @{
        Label = 'missing app'
        Pin = '2.0.0.0'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'vendor newer than pin'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '2.0.0.0'
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '3.0.0.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'older than pin'
        Pin = '2.0.0.0'
        Installed = '1.0.0.0'
        Marker = '1.0.0.0'
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'unparseable installed version'
        Pin = '2.0.0.0'
        Installed = 'nope'
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
    @{
        Label = 'msi version matches two-part text'
        Pin = '26.04.00.0'
        Installed = '26.04'
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'vendor two-part newer than msi pin'
        Pin = '26.04.00.0'
        Installed = '26.05'
        Marker = '26.4.0.0'
        Expect = (New-Expect -WriteMarker '26.5.0.0')
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-PdfXchangePlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-PdfXchangePlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-PdfXchangePlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'Repair equal'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '2.0.0.0'; Installed = '1.0.0.0'; Marker = '1.0.0.0'
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '2.0.0.0'; Installed = '3.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-PdfXchangePlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall app'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true)
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '2.0.0.0'; Installed = ''; Marker = '2.0.0.0'
        Expect = (New-Expect -ClearMarker $true)
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'Uninstall unparseable version'
        Pin = '2.0.0.0'; Installed = 'nope'; Marker = 'old'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true)
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-PdfXchangePlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-PdfXchangePlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = Get-PdfXchangeMsiArgumentList -Mode 'install' -InstallerPath 'C:\cache\pdfx.msi' -ProductCode ''
if ($null -eq $installArgs -or $installArgs.Count -ne 6 -or
    $installArgs[0] -cne '/i' -or $installArgs[1] -cne '"C:\cache\pdfx.msi"' -or
    $installArgs[2] -cne '/qn' -or $installArgs[3] -cne '/norestart' -or
    $installArgs[4] -cne 'DESKTOP_SHORTCUTS="0"' -or $installArgs[5] -cne 'NOUPDATER="1"') {
    Fail "install arguments $($installArgs -join ' ')"
}
$repairArgs = Get-PdfXchangeMsiArgumentList -Mode 'repair' -InstallerPath 'C:\cache\pdfx.msi' -ProductCode ''
if ($null -eq $repairArgs -or $repairArgs[0] -cne '/i' -or $repairArgs -cnotcontains 'REINSTALL=ALL' -or $repairArgs -cnotcontains 'REINSTALLMODE=vomus') {
    Fail "repair arguments $($repairArgs -join ' ')"
}
if ($installArgs -ccontains 'REINSTALL=ALL') {
    Fail 'plain install must not carry REINSTALL'
}
$spacedArgs = Get-PdfXchangeMsiArgumentList -Mode 'install' -InstallerPath 'C:\Program Files\PDF X\pdfx.msi' -ProductCode ''
if ($null -eq $spacedArgs -or $spacedArgs[1] -cne '"C:\Program Files\PDF X\pdfx.msi"') {
    Fail "spaced installer path was $($spacedArgs -join ' ')"
}
# Acrobat PCs: SET_AS_DEFAULT="0" on install and repair. Others: the list above, unchanged.
foreach ($mode in @('install', 'repair')) {
    $keepArgs = Get-PdfXchangeMsiArgumentList -Mode $mode -InstallerPath 'C:\cache\pdfx.msi' -ProductCode '' -KeepPdfDefault $true
    if ($null -eq $keepArgs -or @($keepArgs | Where-Object { $_ -ceq 'SET_AS_DEFAULT="0"' }).Count -ne 1) {
        Fail "$mode with Acrobat arguments $($keepArgs -join ' ')"
    }
    $plainArgs = Get-PdfXchangeMsiArgumentList -Mode $mode -InstallerPath 'C:\cache\pdfx.msi' -ProductCode ''
    if (@($plainArgs | Where-Object { $_ -like '*SET_AS_DEFAULT*' }).Count -ne 0) {
        Fail "$mode without Acrobat passed SET_AS_DEFAULT"
    }
}
if ($null -eq (Get-PdfXchangeMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode '{11111111-2222-3333-4444-555555555555}' -KeepPdfDefault $true) -or
    (Get-PdfXchangeMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode '{11111111-2222-3333-4444-555555555555}' -KeepPdfDefault $true) -ccontains 'SET_AS_DEFAULT="0"') {
    Fail 'uninstall carried SET_AS_DEFAULT'
}

# Full Acrobat, not Reader. The unified 64-bit name is decided by SCAPackageLevel.
foreach ($row in @(
        @{ Names = @(); Levels = @(); Expect = $false; Label = 'nothing installed' },
        @{ Names = @('Adobe Acrobat Reader DC'); Levels = @('1'); Expect = $false; Label = 'Reader DC 32-bit' },
        @{ Names = @('Adobe Acrobat Reader - English'); Levels = @(); Expect = $false; Label = 'Reader 32-bit' },
        @{ Names = @('Adobe Acrobat (64-bit)'); Levels = @('1'); Expect = $false; Label = 'unified 64-bit in Reader mode' },
        @{ Names = @('Adobe Acrobat (64-bit)'); Levels = @('3'); Expect = $true; Label = 'unified 64-bit in Acrobat mode' },
        @{ Names = @('Adobe Acrobat (64-bit)'); Levels = @(); Expect = $true; Label = 'unified 64-bit with no level' },
        @{ Names = @('Adobe Acrobat DC'); Levels = @('1'); Expect = $true; Label = 'Acrobat DC 32-bit beside 64-bit Reader' },
        @{ Names = @('Adobe Acrobat 2020'); Levels = @(); Expect = $true; Label = 'Acrobat 2020' },
        @{ Names = @('Adobe Acrobat XI Pro'); Levels = @(); Expect = $true; Label = 'Acrobat XI Pro' },
        @{ Names = @('', 'Adobe Creative Cloud', 'PDF-XChange PRO'); Levels = @('', 'x'); Expect = $false; Label = 'other Adobe and PDF apps' },
        @{ Names = @(); Levels = @('2'); Expect = $true; Label = 'level 2 without an uninstall name' }
    )) {
    $got = Test-PdfXchangeFullAcrobat -DisplayNames $row.Names -PackageLevels $row.Levels
    if ($got -isnot [bool] -or $got -ne $row.Expect) {
        Fail "full Acrobat check '$($row.Label)' returned $got"
    }
}

# A registry read error must reach the caller, which then keeps the .pdf default.
# Script-scope functions shadow the cmdlets for this block only.
function Test-Path { param([string]$LiteralPath) return $LiteralPath -like 'HKLM:*' }
function Get-ChildItem {
    [CmdletBinding()]
    param([string]$LiteralPath)
    Write-Error 'Requested registry access is not allowed.'
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    Write-Error 'Requested registry access is not allowed.'
}
$readThrew = $false
try {
    [void](Find-PdfXchangeFullAcrobat)
} catch {
    $readThrew = $true
}
Remove-Item -LiteralPath 'Function:\Test-Path', 'Function:\Get-ChildItem', 'Function:\Get-ItemProperty'
if (-not $readThrew) {
    Fail 'a registry read error in the Acrobat check was swallowed'
}

# A registration value with spaces is one quoted msiexec token.
$regArgs = Get-PdfXchangeMsiArgumentList -Mode 'install' -InstallerPath 'C:\cache\pdfx.msi' -ProductCode '' -Organization 'Example and Partners' -UserMail 'it@example.invalid'
if ($null -eq $regArgs -or $regArgs.Count -ne 8 -or
    $regArgs[6] -cne 'ORGANIZATION="Example and Partners"' -or $regArgs[7] -cne 'USERMAIL="it@example.invalid"') {
    Fail "registration arguments $($regArgs -join ' ')"
}
if (@($regArgs | Where-Object { $_ -like 'KEYDATA*' }).Count -ne 0) {
    Fail 'msiexec arguments carry KEYDATA, which the MSI does not hide from its log'
}

# Licence key shape. A fake key: the real one never enters this repo.
$fakeKey = 'PXP10-' + ('AbCd+/' * 6) + 'Q=='
$wrapped = $fakeKey.Substring(0, 14) + " `r`n " + $fakeKey.Substring(14, 10) + "`t" + $fakeKey.Substring(24)
if ((Get-PdfXchangeKeyData -Text $wrapped) -cne $fakeKey) {
    Fail 'a key wrapped with spaces and line breaks was not joined'
}
foreach ($bad in @('', '   ', '%pdfxchangekey%', ($fakeKey + '"'), ($fakeKey + "'"), ('"' + $fakeKey + '"'), 'PXP10-short', ($fakeKey -replace '^PXP10-', 'PXP10_'), ($fakeKey + ' & calc'))) {
    if ((Get-PdfXchangeKeyData -Text $bad) -cne '') {
        Fail "malformed key was accepted: case $([array]::IndexOf(@('', '   '), $bad))"
    }
}
$vaultArgs = Get-PdfXchangeVaultArgumentList -KeyData $fakeKey
if ($null -eq $vaultArgs -or $vaultArgs.Count -ne 4 -or $vaultArgs[0] -cne '/AddKeyData' -or
    $vaultArgs[1] -cne ('"' + $fakeKey + '"') -or $vaultArgs[2] -cne '/M' -or $vaultArgs[3] -cne '/S') {
    Fail 'XCVault arguments are not /AddKeyData "<key>" /M /S'
}
# Start-Process joins the list with spaces; the joined line must split back to the same key.
$joined = $vaultArgs -join ' '
$split = [regex]::Matches($joined, '"[^"]*"|\S+') | ForEach-Object { $_.Value }
if (@($split).Count -ne 4 -or $split[1].Trim('"') -cne $fakeKey) {
    Fail 'XCVault command line does not round-trip the key as one argument'
}
if ($null -ne (Get-PdfXchangeVaultArgumentList -KeyData '')) {
    Fail 'XCVault arguments were built without a key'
}
foreach ($bad in @('Ex"ample', "Ex`nample", ('x' * 129))) {
    if ($null -ne (Get-PdfXchangeRegistrationText -Text $bad)) {
        Fail 'a registration value with a quote, control character or too long was accepted'
    }
}
if ((Get-PdfXchangeRegistrationText -Text '  Example and Partners ') -cne 'Example and Partners') {
    Fail 'registration value was not trimmed'
}
$removeCode = '{11111111-2222-3333-4444-555555555555}'
$removeArgs = Get-PdfXchangeMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode $removeCode
if ($null -eq $removeArgs -or $removeArgs.Count -ne 4 -or
    $removeArgs[0] -cne '/x' -or $removeArgs[1] -cne $removeCode -or
    $removeArgs[2] -cne '/qn' -or $removeArgs[3] -cne '/norestart') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-PdfXchangeMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode '')) {
    Fail 'uninstall without a product code built arguments'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('pdfx-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-PdfXchangeUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/pdfx.msi')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pdfx-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:MsiCalls = [System.Collections.Generic.List[object]]::new()

function Reset-PdfXchangeCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:MsiCalls = [System.Collections.Generic.List[object]]::new()
    $script:VaultCalls = [System.Collections.Generic.List[string]]::new()
    $script:VaultExit = 0
    $script:PolicyCalls = 0
    $script:CaseKey = $fakeKey
    $script:PdfXchangeErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
    $script:ProductCode = '{11111111-2222-3333-4444-555555555555}'
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:MarkerRoot) {
        Remove-Item -LiteralPath $script:MarkerRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    $script:RetryDelay = {
        param($Seconds)
        $script:Sleeps.Add([int]$Seconds)
    }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $script:GetInstalledPdfXchangeVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetPdfXchangeProductCode = {
        return [string]$script:ProductCode
    }
    $script:InvokeXcVault = {
        param($KeyData)
        $script:VaultCalls.Add([string]$KeyData)
        return $script:VaultExit
    }
    $script:SetPdfXchangePolicy = {
        $script:PolicyCalls++
    }
    $script:PdfXchangeNoteLog = [System.Collections.Generic.List[string]]::new()
    $script:FullAcrobat = $false
    $script:TestFullAcrobat = {
        return $script:FullAcrobat
    }
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode, $Organization, $UserMail, $KeepPdfDefault)
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            $existed = Test-Path -LiteralPath $InstallerPath
        }
        $script:MsiCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                ProductCode      = [string]$ProductCode
                InstallerExisted = [bool]$existed
                KeepPdfDefault   = $KeepPdfDefault
            })
        return 0
    }
}

function Set-Marker {
    param([string]$Version)
    [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $Version)
}

function Invoke-Case {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl = 'https://example.invalid/pdfx.msi',
        [string]$InstallerSha256 = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-PdfXchangeAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot -KeyText $script:CaseKey)
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectMsi,
        [string]$ExpectMarker = '',
        [bool]$MarkerAbsent = $false,
        [string]$Label
    )
    if ($Code -ne $ExpectCode) {
        Fail "$Label exit $Code expected $ExpectCode"
    }
    if ($script:DownloadCount -ne $ExpectDownloads) {
        Fail "$Label downloads $($script:DownloadCount) expected $ExpectDownloads"
    }
    if ($script:Sleeps.Count -ne $ExpectSleeps) {
        Fail "$Label sleeps $($script:Sleeps.Count) expected $ExpectSleeps"
    }
    if ($script:MsiCalls.Count -ne $ExpectMsi) {
        Fail "$Label msiexec $($script:MsiCalls.Count) expected $ExpectMsi"
    }
    $path = Join-Path $script:MarkerRoot 'marker.txt'
    $exists = Test-Path -LiteralPath $path
    if ($MarkerAbsent) {
        if ($exists) {
            Fail "$Label left a marker"
        }
    } else {
        if (-not $exists) {
            Fail "$Label did not write a marker"
        }
        $text = ([System.IO.File]::ReadAllText($path)).Trim()
        if ($text -cne $ExpectMarker) {
            Fail "$Label marker '$text' expected '$ExpectMarker'"
        }
    }
    if (($script:PdfXchangeErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
    if (($script:PdfXchangeErrorLog -join "`n") -like '*AbCd*') {
        Fail "$Label error included the key"
    }
}

try {
    # The licence key is required before any download.
    foreach ($missing in @('', '%pdfxchangekey%')) {
        Reset-PdfXchangeCase
        $script:CaseKey = $missing
        $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'missing key'
        if ($script:VaultCalls.Count -ne 0) {
            Fail 'missing key still ran XCVault'
        }
    }

    # A fresh install adds the joined key with XCVault and sets policy once.
    Reset-PdfXchangeCase
    $script:CaseKey = $wrapped
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'install with key'
    if ($script:VaultCalls.Count -ne 1 -or $script:VaultCalls[0] -cne $fakeKey -or $script:PolicyCalls -ne 1) {
        Fail 'install did not pass the joined key to XCVault once and set policy'
    }

    # An older V10 upgrades in place: one msiexec /i, no uninstall first.
    Reset-PdfXchangeCase
    $script:InstalledVersion = '10.6.0.396'
    $code = Invoke-Case -Action 'Install' -PinVersion '11.1.2.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '11.1.2.0' -Label 'upgrade from V10'
    if ($script:MsiCalls[0].Mode -cne 'install') {
        Fail 'upgrade did not run msiexec /i'
    }

    # A PC with full Adobe Acrobat keeps its .pdf default: msiexec gets SET_AS_DEFAULT="0".
    foreach ($row in @(
            @{ Acrobat = $true; Throws = $false; Action = 'Install'; Installed = '10.6.0.396'; Expect = $true; Note = '*Acrobat found*SET_AS_DEFAULT="0"*' },
            @{ Acrobat = $false; Throws = $false; Action = 'Install'; Installed = '10.6.0.396'; Expect = $false; Note = '*Acrobat not found*' },
            @{ Acrobat = $true; Throws = $false; Action = 'Repair'; Installed = '11.1.2.0'; Expect = $true; Note = '*Acrobat found*' },
            @{ Acrobat = $false; Throws = $true; Action = 'Install'; Installed = ''; Expect = $true; Note = '*Acrobat found*' }
        )) {
        Reset-PdfXchangeCase
        $script:InstalledVersion = $row.Installed
        if ($row.Installed -ceq '11.1.2.0') {
            Set-Marker '11.1.2.0'
        }
        # A separate flag: $true -ceq 'throw' is $true in PowerShell, so a string sentinel
        # would send the detected-Acrobat rows down the throw path.
        $script:FullAcrobat = $row.Acrobat
        $script:AcrobatChecks = 0
        if ($row.Throws) {
            $script:TestFullAcrobat = { $script:AcrobatChecks++; throw 'registry unreadable' }
        } else {
            $script:TestFullAcrobat = { $script:AcrobatChecks++; return $script:FullAcrobat }
        }
        $label = "acrobat $($row.Acrobat) throws $($row.Throws) $($row.Action)"
        $code = Invoke-Case -Action $row.Action -PinVersion '11.1.2.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '11.1.2.0' -Label $label
        if ($script:MsiCalls[0].KeepPdfDefault -isnot [bool] -or $script:MsiCalls[0].KeepPdfDefault -ne $row.Expect) {
            Fail "$label passed KeepPdfDefault '$($script:MsiCalls[0].KeepPdfDefault)'"
        }
        if ($script:AcrobatChecks -ne 1) {
            Fail "$label checked for Acrobat $($script:AcrobatChecks) times"
        }
        if ($script:PdfXchangeNoteLog.Count -ne 1 -or $script:PdfXchangeNoteLog[0] -notlike $row.Note) {
            Fail "$label logged '$($script:PdfXchangeNoteLog -join ' | ')'"
        }
    }

    # No msiexec run, no Acrobat check and no note: an up-to-date PC is left alone.
    Reset-PdfXchangeCase
    $script:InstalledVersion = '11.1.2.0'
    Set-Marker '11.1.2.0'
    $script:TestFullAcrobat = { Fail 'up-to-date install checked for Acrobat' }
    $code = Invoke-Case -Action 'Install' -PinVersion '11.1.2.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '11.1.2.0' -Label 'up to date with Acrobat'
    if ($script:PdfXchangeNoteLog.Count -ne 0) {
        Fail 'up-to-date install logged an Acrobat branch'
    }

    # XCVault failure fails the run, so Intune retries; no marker.
    Reset-PdfXchangeCase
    $script:VaultExit = 5
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -MarkerAbsent $true -Label 'XCVault failed'
    if ($script:PolicyCalls -ne 0) {
        Fail 'policy was set after XCVault failed'
    }

    # Uninstall needs no key.
    Reset-PdfXchangeCase
    $script:CaseKey = ''
    $script:InstalledVersion = '11.1.2.0'
    Set-Marker '11.1.2.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '11.1.2.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 1 -MarkerAbsent $true -Label 'uninstall without key'

    Reset-PdfXchangeCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'

    Reset-PdfXchangeCase
    $code = Invoke-Case -Action 'Install' -PinVersion '' -InstallerUrl (New-PdfXchangeUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'empty pin with userinfo url'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-PdfXchangeUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:PdfXchangeErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-PdfXchangeCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-PdfXchangeUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'vendor newer userinfo'
    if (($script:PdfXchangeErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'vendor newer userinfo error did not name userinfo'
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = '26.05'
    Set-Marker '26.4.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '26.04.00.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '26.5.0.0' -Label 'Install vendor 26.05'

    Reset-PdfXchangeCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerUrl (New-PdfXchangeUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 1 -MarkerAbsent $true -Label 'uninstall'
    if ($script:MsiCalls[0].Mode -cne 'uninstall' -or $script:MsiCalls[0].ProductCode -cne $script:ProductCode) {
        Fail 'uninstall did not pass the product code'
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:GetInstalledPdfXchangeVersion = { throw 'registry failed' }
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '' -InstallerUrl (New-PdfXchangeUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'uninstall empty hash'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'uninstall marker only'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'uninstall marker empty hash'

    Reset-PdfXchangeCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:ProductCode = ''
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing product code'

    Reset-PdfXchangeCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Nope' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'empty hash unknown action'

    Reset-PdfXchangeCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Nope' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'unknown action'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    if ($script:MsiCalls[0].Mode -cne 'install' -or -not $script:MsiCalls[0].InstallerExisted) {
        Fail 'Repair missing did not run the installer file'
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    if ($script:MsiCalls[0].Mode -cne 'repair') {
        Fail 'Repair present did not run msiexec in repair mode'
    }

    Reset-PdfXchangeCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'

    Reset-PdfXchangeCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'older install'

    Reset-PdfXchangeCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel before msiexec'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode)
        $script:MsiCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                ProductCode      = [string]$ProductCode
                InstallerExisted = (Test-Path -LiteralPath $InstallerPath)
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'cancel during msiexec'

    Reset-PdfXchangeCase
    $script:InstalledVersion = ''
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode)
        $script:MsiCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                ProductCode      = [string]$ProductCode
                InstallerExisted = $true
            })
        return 3010
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'msiexec 3010'

    Reset-PdfXchangeCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode)
        $script:MsiCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                ProductCode      = [string]$ProductCode
                InstallerExisted = $true
            })
        return 1603
    }
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'msiexec failure'

    Reset-PdfXchangeCase
    Set-Marker '9.0.0.0'
    $script:InstalledVersion = '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '9.0.0.0' -Label 'empty hash'

    Reset-PdfXchangeCase
    Set-Marker '1.0.0.0'
    $script:InstalledVersion = '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha.ToUpperInvariant()
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '1.0.0.0' -Label 'uppercase hash'
    if (($script:PdfXchangeErrorLog -join "`n") -notlike '*invalid hash*') {
        Fail 'uppercase hash did not report an invalid hash'
    }

    foreach ($placeholder in @('0', 'a', 'f')) {
        Reset-PdfXchangeCase
        Set-Marker '2.0.0.0'
        $script:InstalledVersion = '2.0.0.0'
        $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ($placeholder * 64)
        Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label "placeholder $placeholder"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
$emptyOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion ''
if ($LASTEXITCODE -ne 0) {
    Fail "empty PinVersion process exited $LASTEXITCODE"
}
if ($emptyOutput -match 'install') {
    Fail 'empty PinVersion logged an install'
}

$reinstallOutput = & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Reinstall' -PinVersion '26.04.00.0' 2>&1
if ($LASTEXITCODE -ne 1) {
    Fail "Reinstall process exited $LASTEXITCODE"
}

Write-Output 'pdf-xchange-plan tests passed'
exit 0
