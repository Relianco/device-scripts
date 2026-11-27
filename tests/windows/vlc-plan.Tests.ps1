$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/vlc/Invoke-Vlc.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/vlc.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Vlc.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/vlc.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-VlcPlan',
        'Invoke-VlcAction',
        'Save-VlcPayload',
        'Get-VlcInstallerArgumentList',
        'Test-VlcInstallerSucceeded',
        'Test-VlcDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://get.videolan.org/vlc/3.0.24/win64/vlc-3.0.24-win64.exe'
$pinnedSha = 'd711e1e1fe52052748c39080c7dce63f6b7e4c315efedf1774a3f1957b782ff3'
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded installer'
}
if ([int64]$release.size -ne 46269360) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '3.0.24') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'vlc-3.0.24-win64.exe') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/vlc.json'
}
if ([string]$release.name -cne 'VLC media player') {
    Fail "name '$($release.name)'"
}
$packageText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($packageText -match 'Ninja-Property') {
    Fail 'package calls Ninja'
}

$builtinVersion = & $script:GetInstalledVlcVersion
$builtinPath = & $script:GetVlcUninstallPath
$builtinDir = & $script:GetVlcInstallDirectory
if ($builtinVersion -isnot [string] -or $builtinPath -isnot [string] -or $builtinDir -isnot [string]) {
    Fail 'registry hooks did not return strings'
}
if (-not (Test-VlcInstallerSucceeded -Code 0) -or (Test-VlcInstallerSucceeded -Code 3010)) {
    Fail 'installer success codes'
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
        Expect = (New-Expect -RunInstaller 'install')
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
        $plan = Get-VlcPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-VlcPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-VlcPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
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
        Expect = (New-Expect -RunInstaller 'install')
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
    $plan = Get-VlcPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
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
    $plan = Get-VlcPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-VlcPlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installDir = 'C:\Program Files\VideoLAN\VLC'
$installArgs = @(Get-VlcInstallerArgumentList -Mode 'install' -InstallDirectory '')
if ($installArgs.Count -ne 1 -or $installArgs[0] -cne '/S') {
    Fail "install arguments $($installArgs -join ' ')"
}
$removeArgs = @(Get-VlcInstallerArgumentList -Mode 'uninstall' -InstallDirectory $installDir)
if ($removeArgs.Count -ne 2 -or $removeArgs[0] -cne '/S' -or $removeArgs[1] -cne ('_?=' + $installDir)) {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-VlcInstallerArgumentList -Mode 'uninstall' -InstallDirectory '')) {
    Fail 'uninstall without a directory built arguments'
}
if ($null -ne (Get-VlcInstallerArgumentList -Mode 'nope' -InstallDirectory $installDir)) {
    Fail 'unknown mode built arguments'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('vlc-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-VlcUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/vlc.exe')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('vlc-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:InstallerCalls = [System.Collections.Generic.List[object]]::new()

function Reset-VlcCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:InstallerCalls = [System.Collections.Generic.List[object]]::new()
    $script:VlcErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
    $script:UninstallPath = 'C:\Program Files\VideoLAN\VLC\uninstall.exe'
    $script:InstallDirectory = 'C:\Program Files\VideoLAN\VLC'
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
    $script:GetInstalledVlcVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetVlcUninstallPath = {
        return [string]$script:UninstallPath
    }
    $script:GetVlcInstallDirectory = {
        return [string]$script:InstallDirectory
    }
    $script:InvokeInstaller = {
        param($Mode, $TargetPath, $ArgumentList)
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
            $existed = Test-Path -LiteralPath $TargetPath
        }
        $script:InstallerCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                TargetPath       = [string]$TargetPath
                Arguments        = @($ArgumentList)
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
        [string]$InstallerUrl = 'https://example.invalid/vlc.exe',
        [string]$InstallerSha256 = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-VlcAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectInstaller,
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
    if ($script:InstallerCalls.Count -ne $ExpectInstaller) {
        Fail "$Label installer $($script:InstallerCalls.Count) expected $ExpectInstaller"
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
    if (($script:VlcErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

try {
    Reset-VlcCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-VlcUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:VlcErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-VlcCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-VlcCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
        if ($script:VlcErrorLog.Count -ne 0) {
            Fail "$action vendor newer logged an install"
        }
        if (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'toolkit.log')) {
            Fail "$action vendor newer logged an install"
        }
    }

    Reset-VlcCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerUrl (New-VlcUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 1 -MarkerAbsent $true -Label 'uninstall'
    $uninstallCall = $script:InstallerCalls[0]
    $uninstallArgs = @($uninstallCall.Arguments)
    if ($uninstallCall.Mode -cne 'uninstall' -or $uninstallCall.TargetPath -cne $script:UninstallPath) {
        Fail 'uninstall did not pass uninstall.exe'
    }
    if ($uninstallArgs.Count -ne 2 -or $uninstallArgs[0] -cne '/S' -or $uninstallArgs[1] -cne ('_?=' + $script:InstallDirectory)) {
        Fail "uninstall switches $($uninstallArgs -join ' ')"
    }

    Reset-VlcCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'uninstall marker only'

    Reset-VlcCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:UninstallPath = ''
    $script:InstallDirectory = ''
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing program'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    $repairCall = $script:InstallerCalls[0]
    $repairArgs = @($repairCall.Arguments)
    if ($repairCall.Mode -cne 'install' -or -not $repairCall.InstallerExisted -or $repairArgs.Count -ne 1 -or $repairArgs[0] -cne '/S') {
        Fail 'Repair missing did not run the installer file with /S'
    }

    Reset-VlcCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    if ($script:InstallerCalls[0].Mode -cne 'install' -or @($script:InstallerCalls[0].Arguments)[0] -cne '/S') {
        Fail 'Repair present did not run the installer again'
    }

    Reset-VlcCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'
    if (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'toolkit.log')) {
        Fail 'Repair vendor newer logged an install'
    }

    Reset-VlcCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'older install'

    Reset-VlcCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'cancel before installer'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $script:InvokeInstaller = {
        param($Mode, $TargetPath, $ArgumentList)
        $script:InstallerCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                TargetPath       = [string]$TargetPath
                Arguments        = @($ArgumentList)
                InstallerExisted = (Test-Path -LiteralPath $TargetPath)
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'cancel during installer'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $script:InvokeInstaller = {
        param($Mode, $TargetPath, $ArgumentList)
        $script:InstallerCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                TargetPath       = [string]$TargetPath
                Arguments        = @($ArgumentList)
                InstallerExisted = $true
            })
        return 1
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -MarkerAbsent $true -Label 'installer failure'

    Reset-VlcCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeInstaller = {
        param($Mode, $TargetPath, $ArgumentList)
        $script:InstallerCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                TargetPath       = [string]$TargetPath
                Arguments        = @($ArgumentList)
                InstallerExisted = $true
            })
        return 2
    }
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectInstaller 1 -ExpectMarker '2.0.0.0' -Label 'repair installer failure'

    foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
        Reset-VlcCase
        $script:InstalledVersion = '2.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0' -InstallerSha256 ''
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '2.0.0.0' -Label "$action empty hash"
    }

    Reset-VlcCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '   '
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -ExpectMarker '2.0.0.0' -Label 'uninstall whitespace hash'

    Reset-VlcCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha.ToUpperInvariant()
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'uppercase hash'

    $placeholders = [System.Collections.Generic.List[string]]::new()
    $placeholders.Add('0' * 64)
    $placeholders.Add('a' * 64)
    foreach ($placeholder in $placeholders) {
        Reset-VlcCase
        $script:InstalledVersion = ''
        $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $placeholder
        Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectInstaller 0 -MarkerAbsent $true -Label 'placeholder hash'
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'vlc-plan tests passed'
exit 0
