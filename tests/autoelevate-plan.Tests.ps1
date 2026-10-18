$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/autoelevate/Invoke-AutoElevate.ps1'
$releasePath = Join-Path $repoRoot 'releases/autoelevate.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-AutoElevate.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/autoelevate.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-AutoElevatePlan',
        'Invoke-AutoElevateAction',
        'Save-AutoElevatePayload',
        'Get-AutoElevateMsiArgumentList',
        'Test-AutoElevateDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://autoelevate-installers.s3.us-east-2.amazonaws.com/current/AESetup.msi'
$pinnedSha = '391e21349bdd0053067b7c6528b872ce4f4db522e48f3c546291dce40f596bfa'
if ([string]$release.name -cne 'AutoElevate') {
    Fail "name '$($release.name)'"
}
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded MSI'
}
if ([int64]$release.size -ne 5267456) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '2.11.1959') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x86' -or [string]$release.file -cne 'AESetup.msi') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match releases/autoelevate.json'
}
$packageText = [System.IO.File]::ReadAllText($scriptPath)
foreach ($banned in @('LICENSE_KEY', 'COMPANY_NAME', 'LOCATION_NAME', 'Ninja-Property', 'ELEVATION_MODE', 'BLOCKER_MODE')) {
    if ($packageText.Contains($banned)) {
        Fail "package contains $banned"
    }
}

$builtinVersion = & $script:GetInstalledAutoElevateVersion
$builtinCode = & $script:GetAutoElevateProductCode
if ($builtinVersion -isnot [string] -or $builtinCode -isnot [string]) {
    Fail 'registry hooks did not return strings'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    foreach ($name in @('ExitCode', 'RunInstaller', 'WriteMarker', 'ClearMarker', 'Log')) {
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
    if ([string]$Plan.Log -cne [string]$Expect.Log) {
        Fail "$Label Log '$($Plan.Log)' expected '$($Expect.Log)'"
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return @{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
        Log          = $Log
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
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = ''
        Expect = (New-Expect -WriteMarker '2.0.0.0')
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
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'three-part pin matches file version'
        Pin = '2.11.1959'
        Installed = '2.11.1959.0'
        Marker = '2.11.1959.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'unparseable installed version'
        Pin = '2.0.0.0'
        Installed = 'nope'
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-AutoElevatePlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-AutoElevatePlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-AutoElevatePlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair equal'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '2.0.0.0'; Installed = '1.0.0.0'; Marker = '1.0.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '2.0.0.0'; Installed = '3.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-AutoElevatePlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall app'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '2.0.0.0'; Installed = ''; Marker = '2.0.0.0'
        Expect = (New-Expect -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'Uninstall unparseable version'
        Pin = '2.0.0.0'; Installed = 'nope'; Marker = 'old'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall')
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-AutoElevatePlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-AutoElevatePlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = Get-AutoElevateMsiArgumentList -Mode 'install' -InstallerPath 'C:\cache\autoelevate.msi' -ProductCode ''
if ($null -eq $installArgs -or $installArgs.Count -ne 4 -or
    $installArgs[0] -cne '/i' -or $installArgs[1] -cne 'C:\cache\autoelevate.msi' -or
    $installArgs[2] -cne '/quiet' -or $installArgs[3] -cne '/norestart') {
    Fail "install arguments $($installArgs -join ' ')"
}
$removeCode = '{11111111-2222-3333-4444-555555555555}'
$removeArgs = Get-AutoElevateMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode $removeCode
if ($null -eq $removeArgs -or $removeArgs.Count -ne 4 -or
    $removeArgs[0] -cne '/x' -or $removeArgs[1] -cne $removeCode -or
    $removeArgs[2] -cne '/quiet' -or $removeArgs[3] -cne '/norestart') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-AutoElevateMsiArgumentList -Mode 'uninstall' -InstallerPath '' -ProductCode '')) {
    Fail 'uninstall without a product code built arguments'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('autoelevate-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-AutoElevateUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/AESetup.msi')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('autoelevate-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:MsiCalls = [System.Collections.Generic.List[object]]::new()

function Reset-AutoElevateCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:MsiCalls = [System.Collections.Generic.List[object]]::new()
    $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
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
    $script:GetInstalledAutoElevateVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetAutoElevateProductCode = {
        return [string]$script:ProductCode
    }
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode)
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            $existed = Test-Path -LiteralPath $InstallerPath
        }
        $script:MsiCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                ProductCode      = [string]$ProductCode
                InstallerExisted = [bool]$existed
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
        [string]$InstallerUrl = 'https://example.invalid/AESetup.msi',
        [string]$InstallerSha256 = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-AutoElevateAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
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
    if (($script:AutoElevateErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

function Assert-Log {
    param(
        [string]$Expected,
        [string]$Label
    )
    $path = Join-Path $script:MarkerRoot 'toolkit.log'
    $exists = Test-Path -LiteralPath $path
    if ([string]::IsNullOrEmpty($Expected)) {
        if ($exists) {
            Fail "$Label wrote toolkit.log"
        }
        return
    }
    if (-not $exists) {
        Fail "$Label did not write toolkit.log"
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -cne $Expected) {
        Fail "$Label log '$text' expected '$Expected'"
    }
}

try {
    Reset-AutoElevateCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'
    Assert-Log -Expected '' -Label 'empty pin'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-AutoElevateUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:AutoElevateErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-AutoElevateCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'toolkit.log'), "Repair`n")
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
        $logged = [System.IO.File]::ReadAllText((Join-Path $script:MarkerRoot 'toolkit.log'))
        if ($logged -cne "Repair`n") {
            Fail "$action vendor newer logged an install: '$logged'"
        }
    }

    Reset-AutoElevateCase
    $script:InstalledVersion = '2.11.1959.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.11.1959'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.11.1959.0' -Label 'three-part pin'
    Assert-Log -Expected '' -Label 'three-part pin'

    Reset-AutoElevateCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '' -InstallerUrl (New-AutoElevateUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 1 -MarkerAbsent $true -Label 'uninstall'
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall'
    if ($script:MsiCalls[0].Mode -cne 'uninstall' -or $script:MsiCalls[0].ProductCode -cne $script:ProductCode) {
        Fail 'uninstall did not pass the product code'
    }

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'uninstall marker only'
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall marker only'

    Reset-AutoElevateCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:ProductCode = ''
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing product code'
    Assert-Log -Expected '' -Label 'uninstall missing product code'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    Assert-Log -Expected "Repair`n" -Label 'Repair missing'
    if ($script:MsiCalls[0].Mode -cne 'install' -or -not $script:MsiCalls[0].InstallerExisted) {
        Fail 'Repair missing did not run the installer file'
    }

    Reset-AutoElevateCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    Assert-Log -Expected "Repair`n" -Label 'Repair present'
    if ($script:MsiCalls[0].Mode -cne 'install') {
        Fail 'Repair present did not run the installer again'
    }

    Reset-AutoElevateCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'
    Assert-Log -Expected '' -Label 'Repair vendor newer'

    Reset-AutoElevateCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'older install'
    Assert-Log -Expected "Install`n" -Label 'older install'

    Reset-AutoElevateCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'
    Assert-Log -Expected '' -Label 'Reinstall'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'cancel before msiexec'

    Reset-AutoElevateCase
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

    Reset-AutoElevateCase
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
    Assert-Log -Expected "Install`n" -Label 'msiexec 3010'

    Reset-AutoElevateCase
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
    Assert-Log -Expected '' -Label 'msiexec failure'

    Reset-AutoElevateCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectMsi 0 -MarkerAbsent $true -Label 'missing hash'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'autoelevate-plan tests passed'
exit 0
