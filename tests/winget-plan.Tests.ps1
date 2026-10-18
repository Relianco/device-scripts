$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/winget/Invoke-Winget.ps1'
$releasePath = Join-Path $repoRoot 'releases/winget.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Winget.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/winget.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-WingetPlan',
        'Invoke-WingetAction',
        'Save-WingetPayload',
        'Get-WingetProvisionArguments',
        'Get-WingetPinnedFiles',
        'Get-WingetDependencyFiles',
        'Test-WingetDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($scriptText -match 'releases[/\\]winget\.json') {
    Fail 'script reads releases/winget.json'
}
if ($scriptText -match '(?i)winget(\.exe)?\s+install\s') {
    Fail 'package wraps winget install'
}
if ($scriptText -match '(?m)\[Parameter\(Mandatory') {
    Fail 'a parameter is Mandatory'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.name -cne 'Windows Package Manager') {
    Fail "name '$($release.name)'"
}
if ([string]$release.arch -cne 'x64') {
    Fail "arch '$($release.arch)'"
}
if ([string]$release.version -cne '1.29.380.0') {
    Fail "version '$($release.version)'"
}
if ([string]$release.bundleVersion -cne '2026.917.151.0') {
    Fail "bundleVersion '$($release.bundleVersion)'"
}

function Assert-Pin {
    param(
        $Actual,
        $Expected,
        [string]$Label
    )
    foreach ($name in @('role', 'file', 'url', 'sha256', 'version')) {
        $left = [string]$Actual.$name
        $right = [string]$Expected.$name
        if ($left -cne $right) {
            Fail "$Label $name '$left' expected '$right'"
        }
    }
    if ([int64]$Actual.size -ne [int64]$Expected.Size) {
        Fail "$Label size $($Actual.size) expected $($Expected.Size)"
    }
    if ($scriptText -notlike ('*' + [string]$Expected.Sha256 + '*')) {
        Fail "$Label sha256 is not inlined"
    }
    if ($scriptText -notlike ('*' + [string]$Expected.Url + '*')) {
        Fail "$Label url is not inlined"
    }
}

$pinned = @(Get-WingetPinnedFiles)
$dependencies = @(Get-WingetDependencyFiles)
$recorded = @($release.files)
if ($pinned.Count -ne 3 -or $dependencies.Count -ne 3 -or $recorded.Count -ne 6) {
    Fail "pin counts packages $($pinned.Count) dependencies $($dependencies.Count) recorded $($recorded.Count)"
}
foreach ($pin in ($pinned + $dependencies)) {
    $matches = @($recorded | Where-Object { [string]$_.file -ceq [string]$pin.File })
    if ($matches.Count -ne 1) {
        Fail "recorded file '$($pin.File)' count $($matches.Count)"
    }
    Assert-Pin -Actual $matches[0] -Expected $pin -Label $pin.File
    if ([string]$pin.Role -eq 'dependency') {
        $path = [string]$matches[0].path
        if ($path -cne [string]$pin.Path) {
            Fail "$($pin.File) path '$path' expected '$($pin.Path)'"
        }
    }
}

$builtinVersion = & $script:GetInstalledWingetVersion
if ($builtinVersion -isnot [string]) {
    Fail 'version hook did not return a string'
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
    foreach ($name in @('RunInstaller', 'WriteMarker', 'Log')) {
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
        Label = 'unparseable installed version'
        Pin = '2.0.0.0'
        Installed = 'nope'
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-WingetPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-WingetPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-WingetPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
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
    $plan = Get-WingetPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
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
    $plan = Get-WingetPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-WingetPlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = @(Get-WingetProvisionArguments -Mode 'install' -PackagePath 'C:\cache\app.msixbundle' -LicensePath 'C:\cache\license.xml' -DependencyPaths @('C:\cache\a.appx', 'C:\cache\b.appx'))
if ($installArgs.Count -ne 8 -or
    $installArgs[0] -cne '-Online' -or $installArgs[1] -cne '-PackagePath' -or $installArgs[2] -cne 'C:\cache\app.msixbundle' -or
    $installArgs[3] -cne '-LicensePath' -or $installArgs[4] -cne 'C:\cache\license.xml' -or
    $installArgs[5] -cne '-DependencyPackagePath' -or $installArgs[6] -cne 'C:\cache\a.appx' -or $installArgs[7] -cne 'C:\cache\b.appx') {
    Fail "install arguments $($installArgs -join ' ')"
}
$removeArgs = @(Get-WingetProvisionArguments -Mode 'uninstall' -PackagePath '' -LicensePath '' -DependencyPaths @())
if ($removeArgs.Count -ne 3 -or $removeArgs[0] -cne '-Online' -or $removeArgs[1] -cne '-PackageName' -or $removeArgs[2] -cne 'Microsoft.DesktopAppInstaller') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-WingetProvisionArguments -Mode 'install' -PackagePath 'C:\cache\app.msixbundle' -LicensePath '' -DependencyPaths @('C:\cache\a.appx'))) {
    Fail 'install without a license built arguments'
}
if ($null -ne (Get-WingetProvisionArguments -Mode 'install' -PackagePath 'C:\cache\app.msixbundle' -LicensePath 'C:\cache\license.xml' -DependencyPaths @())) {
    Fail 'install without dependencies built arguments'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('winget-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-WingetUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/winget.msixbundle')
}

function New-WingetTestFiles {
    param(
        [string]$PackageUrl = 'https://example.invalid/winget.msixbundle',
        [string]$Sha = $script:GoodSha
    )
    return @(
        [pscustomobject]@{ Role = 'package'; File = 'app.msixbundle'; Url = $PackageUrl; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
        [pscustomobject]@{ Role = 'license'; File = 'license.xml'; Url = 'https://example.invalid/license.xml'; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
        [pscustomobject]@{ Role = 'dependencies'; File = 'deps.zip'; Url = 'https://example.invalid/deps.zip'; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
    )
}

function New-WingetTestDependencies {
    param([string]$Sha = $script:GoodSha)
    return @(
        [pscustomobject]@{ Role = 'dependency'; File = 'a.appx'; Path = 'x64/a.appx'; Url = 'https://example.invalid/deps.zip'; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
        [pscustomobject]@{ Role = 'dependency'; File = 'b.appx'; Path = 'x64/b.appx'; Url = 'https://example.invalid/deps.zip'; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
        [pscustomobject]@{ Role = 'dependency'; File = 'c.appx'; Path = 'x64/c.appx'; Url = 'https://example.invalid/deps.zip'; Sha256 = $Sha; Size = [int64]1; Version = '1.0.0.0' }
    )
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:AppxCalls = [System.Collections.Generic.List[object]]::new()

function Reset-WingetCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:AppxCalls = [System.Collections.Generic.List[object]]::new()
    $script:WingetErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
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
    $script:ExpandDependencies = {
        param($ZipPath, $Destination, $Pins)
        foreach ($pin in @($Pins)) {
            [System.IO.File]::WriteAllBytes((Join-Path $Destination ([string]$pin.File)), $script:GoodBytes)
        }
    }
    $script:GetInstalledWingetVersion = {
        return [string]$script:InstalledVersion
    }
    $script:InvokeAppx = {
        param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
        $existed = $true
        if ($Mode -eq 'install') {
            if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath)) {
                $existed = $false
            }
            if ([string]::IsNullOrWhiteSpace($LicensePath) -or -not (Test-Path -LiteralPath $LicensePath)) {
                $existed = $false
            }
            $deps = @()
            if ($null -ne $DependencyPaths) {
                $deps = @($DependencyPaths)
            }
            if ($deps.Count -ne 3) {
                $existed = $false
            }
            foreach ($dep in $deps) {
                if (-not (Test-Path -LiteralPath ([string]$dep))) {
                    $existed = $false
                }
            }
        }
        $script:AppxCalls.Add([pscustomobject]@{
                Mode    = [string]$Mode
                Existed = [bool]$existed
            })
        return 0
    }
}

function Set-Marker {
    param([string]$Version)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $Version, $utf8NoBom)
}

function Invoke-Case {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$PackageUrl = 'https://example.invalid/winget.msixbundle',
        [string]$Sha = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-WingetAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot -Files (New-WingetTestFiles -PackageUrl $PackageUrl -Sha $Sha) -Dependencies (New-WingetTestDependencies -Sha $Sha))
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectAppx,
        [string]$ExpectMarker = '',
        [bool]$MarkerAbsent = $false,
        [string]$ExpectLog = '',
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
    if ($script:AppxCalls.Count -ne $ExpectAppx) {
        Fail "$Label appx $($script:AppxCalls.Count) expected $ExpectAppx"
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
    $logPath = Join-Path $script:MarkerRoot 'toolkit.log'
    $logExists = Test-Path -LiteralPath $logPath
    if ([string]::IsNullOrWhiteSpace($ExpectLog)) {
        if ($logExists) {
            $logged = [System.IO.File]::ReadAllText($logPath)
            Fail "$Label logged '$logged'"
        }
    } else {
        if (-not $logExists) {
            Fail "$Label did not write a log"
        }
        $logged = [System.IO.File]::ReadAllText($logPath)
        if ($logged -cne ($ExpectLog + "`n")) {
            Fail "$Label log '$logged' expected '$ExpectLog'"
        }
    }
    if (($script:WingetErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

try {
    Reset-WingetCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -PackageUrl (New-WingetUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:WingetErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-WingetCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-WingetCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
    }

    Reset-WingetCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -Sha ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 1 -MarkerAbsent $true -ExpectLog 'Uninstall' -Label 'uninstall'
    if ($script:AppxCalls[0].Mode -cne 'uninstall') {
        Fail 'uninstall did not remove App Installer'
    }

    Reset-WingetCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -Sha ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -ExpectLog 'Uninstall' -Label 'uninstall marker only'

    Reset-WingetCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeAppx = {
        param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
        $script:AppxCalls.Add([pscustomobject]@{
                Mode    = [string]$Mode
                Existed = $false
            })
        return 1
    }
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -Sha ''
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -Label 'uninstall failed'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Repair' -Label 'Repair missing'
    if ($script:AppxCalls[0].Mode -cne 'install' -or -not $script:AppxCalls[0].Existed) {
        Fail 'Repair missing did not provision the package files'
    }

    Reset-WingetCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Repair' -Label 'Repair present'
    if ($script:AppxCalls[0].Mode -cne 'install') {
        Fail 'Repair present did not provision the package again'
    }

    Reset-WingetCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'

    Reset-WingetCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Install' -Label 'older install'

    Reset-WingetCase
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -ExpectMarker '2.0.0.0' -Label 'equal pin writes marker without an install log'

    Reset-WingetCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Install' -Label 'missing cancel path'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        if ($script:DownloadCount -ge 3) {
            $env:RELIAN_DEPLOY_CANCEL = '1'
        }
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'cancel before provision'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $script:InvokeAppx = {
        param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
        $script:AppxCalls.Add([pscustomobject]@{
                Mode    = [string]$Mode
                Existed = $true
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Install' -Label 'cancel during provision'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $script:InvokeAppx = {
        param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
        $script:AppxCalls.Add([pscustomobject]@{
                Mode    = [string]$Mode
                Existed = $true
            })
        return 3010
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -ExpectLog 'Install' -Label 'provision 3010'

    Reset-WingetCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeAppx = {
        param($Mode, $PackagePath, $LicensePath, $DependencyPaths)
        $script:AppxCalls.Add([pscustomobject]@{
                Mode    = [string]$Mode
                Existed = $true
            })
        return 1
    }
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 3 -ExpectSleeps 0 -ExpectAppx 1 -ExpectMarker '2.0.0.0' -Label 'provision failure'

    Reset-WingetCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -Sha ''
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectAppx 0 -MarkerAbsent $true -Label 'missing hash'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'winget-plan tests passed'
exit 0
