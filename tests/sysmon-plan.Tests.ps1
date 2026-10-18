$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/sysmon/Invoke-Sysmon.ps1'
$releasePath = Join-Path $repoRoot 'releases/sysmon.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Sysmon.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/sysmon.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-SysmonPlan',
        'Invoke-SysmonAction',
        'Save-SysmonPayload',
        'Get-SysmonArgumentList',
        'Convert-SysmonImagePath',
        'Test-SysmonDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://download.sysinternals.com/files/Sysmon.zip'
$pinnedSha = '00ecf1b46aec99299d3ae0bca79dc621458bd014b20b509d7c5c8e8c8611aa54'
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded zip'
}
if ([int64]$release.size -ne 2938038) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '15.22') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'Sysmon.zip') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match releases/sysmon.json'
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
foreach ($banned in @('Ninja-Property', 'sig=', 'SharedAccessSignature', '/home/', 'C:\Users')) {
    if ($scriptText.Contains($banned)) {
        Fail "script contains $banned"
    }
}
if ($script:SysmonConfigText -notlike '*schemaversion="4.91"*' -or $script:SysmonConfigText -notlike '*SHA256*') {
    Fail 'config is not the minimal public schema'
}
foreach ($banned in @('Ninja', '/home/', 'C:\Users', 'sig=')) {
    if ($script:SysmonConfigText.Contains($banned)) {
        Fail "config contains $banned"
    }
}

$builtinVersion = & $script:GetInstalledSysmonVersion
$builtinExe = & $script:GetSysmonExePath
if ($builtinVersion -isnot [string] -or $builtinExe -isnot [string]) {
    Fail 'service hooks did not return strings'
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
    @{
        Label = 'two-part product version equals pin'
        Pin = '15.22'
        Installed = '15.22'
        Marker = ''
        Expect = (New-Expect -WriteMarker '15.22.0.0')
    }
    @{
        Label = 'two-part vendor newer'
        Pin = '15.22'
        Installed = '15.23'
        Marker = '15.22'
        Expect = (New-Expect -WriteMarker '15.23.0.0')
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-SysmonPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-SysmonPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-SysmonPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
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
    $plan = Get-SysmonPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
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
    $plan = Get-SysmonPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-SysmonPlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = Get-SysmonArgumentList -Mode 'install' -ConfigPath 'C:\cache\sysmonconfig.xml'
if ($null -eq $installArgs -or $installArgs.Count -ne 3 -or
    $installArgs[0] -cne '-accepteula' -or $installArgs[1] -cne '-i' -or
    $installArgs[2] -cne 'C:\cache\sysmonconfig.xml') {
    Fail "install arguments $($installArgs -join ' ')"
}
if ($null -ne (Get-SysmonArgumentList -Mode 'install' -ConfigPath '')) {
    Fail 'install without a config built arguments'
}
$forceArgs = Get-SysmonArgumentList -Mode 'uninstall' -ConfigPath ''
if ($null -eq $forceArgs -or $forceArgs.Count -ne 2 -or $forceArgs[0] -cne '-u' -or $forceArgs[1] -cne 'force') {
    Fail "uninstall arguments $($forceArgs -join ' ')"
}
$plainArgs = @(Get-SysmonArgumentList -Mode 'uninstall-plain' -ConfigPath '')
if ($plainArgs.Count -ne 1 -or $plainArgs[0] -cne '-u') {
    Fail "plain uninstall arguments $($plainArgs -join ' ')"
}

$savedRoot = $env:SystemRoot
try {
    $env:SystemRoot = 'C:\Windows'
    $imageRows = @(
        @{ In = ''; Out = '' }
        @{ In = '"C:\Windows\Sysmon64.exe"'; Out = 'C:\Windows\Sysmon64.exe' }
        @{ In = '"C:\Windows\Sysmon64.exe" -service'; Out = 'C:\Windows\Sysmon64.exe' }
        @{ In = 'C:\Windows\Sysmon64.exe -service'; Out = 'C:\Windows\Sysmon64.exe' }
        @{ In = '\SystemRoot\Sysmon64.exe'; Out = 'C:\Windows\Sysmon64.exe' }
        @{ In = '%SystemRoot%\Sysmon64.exe'; Out = 'C:\Windows\Sysmon64.exe' }
    )
    foreach ($row in $imageRows) {
        $actual = Convert-SysmonImagePath -ImagePath $row.In
        if ($actual -cne $row.Out) {
            Fail "image path '$($row.In)' became '$actual'"
        }
    }
} finally {
    if ($null -eq $savedRoot) {
        Remove-Item -LiteralPath 'Env:SystemRoot' -ErrorAction SilentlyContinue
    } else {
        $env:SystemRoot = $savedRoot
    }
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('sysmon-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-SysmonUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/Sysmon.zip')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('sysmon-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:SysmonCalls = [System.Collections.Generic.List[object]]::new()

function Reset-SysmonCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:SysmonCalls = [System.Collections.Generic.List[object]]::new()
    $script:SysmonErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
    $script:ExePath = ''
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
    $script:ExpandArchive = {
        param($Path, $Destination)
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        $exe = Join-Path $Destination 'Sysmon64.exe'
        [System.IO.File]::WriteAllBytes($exe, $script:GoodBytes)
    }
    $script:GetInstalledSysmonVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetSysmonExePath = {
        return [string]$script:ExePath
    }
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $exeExisted = $false
        if (-not [string]::IsNullOrWhiteSpace($ExePath)) {
            $exeExisted = Test-Path -LiteralPath $ExePath
        }
        $configExisted = $false
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $configExisted = Test-Path -LiteralPath $ConfigPath
        }
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode           = [string]$Mode
                ExePath        = [string]$ExePath
                ConfigPath     = [string]$ConfigPath
                ExeExisted     = [bool]$exeExisted
                ConfigExisted  = [bool]$configExisted
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
        [string]$InstallerUrl = 'https://example.invalid/Sysmon.zip',
        [string]$InstallerSha256 = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return @(Invoke-SysmonAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
}

function Assert-Case {
    param(
        $Result,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectCalls,
        [string]$ExpectMarker = '',
        [bool]$MarkerAbsent = $false,
        [string]$Label
    )
    $items = @($Result)
    if ($items.Count -ne 1 -or $null -eq $items[0]) {
        Fail "$Label emitted $($items.Count) objects"
    }
    $code = [int]$items[0]
    if ($code -ne $ExpectCode) {
        Fail "$Label exit $code expected $ExpectCode"
    }
    if ($script:DownloadCount -ne $ExpectDownloads) {
        Fail "$Label downloads $($script:DownloadCount) expected $ExpectDownloads"
    }
    if ($script:Sleeps.Count -ne $ExpectSleeps) {
        Fail "$Label sleeps $($script:Sleeps.Count) expected $ExpectSleeps"
    }
    if ($script:SysmonCalls.Count -ne $ExpectCalls) {
        Fail "$Label sysmon calls $($script:SysmonCalls.Count) expected $ExpectCalls"
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
    if (($script:SysmonErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

try {
    Reset-SysmonCase
    Set-Marker '9.0.0.0'
    $result = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-SysmonUserInfoUrl)
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:SysmonErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-SysmonCase
        $script:InstalledVersion = '3.0.0.0'
        $script:ExePath = 'C:\Windows\Sysmon64.exe'
        Set-Marker '2.0.0.0'
        $result = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
        if (($script:SysmonErrorLog -join "`n") -match 'install') {
            Fail "$action vendor newer logged an install"
        }
    }

    Reset-SysmonCase
    $script:InstalledVersion = '15.23'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '15.22'
    $result = Invoke-Case -Action 'Install' -PinVersion '15.22'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '15.23.0.0' -Label 'vendor newer product version'
    if ($script:SysmonErrorLog.Count -ne 0) {
        Fail 'vendor newer product version logged an install'
    }

    Reset-SysmonCase
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '2.0.0.0' -Label 'equal pin writes marker only'

    Reset-SysmonCase
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '2.0.0.0'
    $result = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '' -InstallerUrl (New-SysmonUserInfoUrl)
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 1 -MarkerAbsent $true -Label 'uninstall'
    if ($script:SysmonCalls[0].Mode -cne 'uninstall' -or $script:SysmonCalls[0].ExePath -cne 'C:\Windows\Sysmon64.exe') {
        Fail 'uninstall did not pass the installed executable'
    }

    Reset-SysmonCase
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '2.0.0.0'
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode          = [string]$Mode
                ExePath       = [string]$ExePath
                ConfigPath    = [string]$ConfigPath
                ExeExisted    = $false
                ConfigExisted = $false
            })
        if ($Mode -eq 'uninstall') { return 1 }
        return 0
    }
    $result = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 2 -MarkerAbsent $true -Label 'uninstall force fallback'
    if ($script:SysmonCalls[0].Mode -cne 'uninstall' -or $script:SysmonCalls[1].Mode -cne 'uninstall-plain') {
        Fail 'uninstall fallback order was wrong'
    }

    Reset-SysmonCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $result = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'uninstall marker only'

    Reset-SysmonCase
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = ''
    Set-Marker '2.0.0.0'
    $result = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing executable'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $result = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    if ($script:SysmonCalls[0].Mode -cne 'install' -or -not $script:SysmonCalls[0].ExeExisted -or -not $script:SysmonCalls[0].ConfigExisted) {
        Fail 'Repair missing did not run the extracted executable'
    }
    if ($script:SysmonCalls[0].ConfigPath -notlike '*sysmonconfig.xml') {
        Fail 'Repair missing did not pass the config path'
    }

    Reset-SysmonCase
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '2.0.0.0'
    $result = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 2 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    if ($script:SysmonCalls[0].Mode -cne 'uninstall' -or $script:SysmonCalls[0].ExePath -cne 'C:\Windows\Sysmon64.exe') {
        Fail 'Repair present did not remove the installed executable first'
    }
    if ($script:SysmonCalls[1].Mode -cne 'install' -or -not $script:SysmonCalls[1].ExeExisted) {
        Fail 'Repair present did not install the extracted executable'
    }

    Reset-SysmonCase
    $script:InstalledVersion = '3.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '2.0.0.0'
    $result = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'
    if (($script:SysmonErrorLog -join "`n") -match 'install') {
        Fail 'Repair vendor newer logged an install'
    }

    Reset-SysmonCase
    $script:InstalledVersion = '1.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '1.0.0.0'
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 2 -ExpectMarker '2.0.0.0' -Label 'older install'
    if ($script:SysmonCalls[0].Mode -cne 'uninstall' -or $script:SysmonCalls[1].Mode -cne 'install') {
        Fail 'older install did not remove before install'
    }

    Reset-SysmonCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    $result = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Result $result -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'cancel before sysmon'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode          = [string]$Mode
                ExePath       = [string]$ExePath
                ConfigPath    = [string]$ConfigPath
                ExeExisted    = (Test-Path -LiteralPath $ExePath)
                ConfigExisted = $true
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 1 -ExpectMarker '2.0.0.0' -Label 'cancel during sysmon'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode          = [string]$Mode
                ExePath       = [string]$ExePath
                ConfigPath    = [string]$ConfigPath
                ExeExisted    = $true
                ConfigExisted = $true
            })
        return 3010
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 1 -ExpectMarker '2.0.0.0' -Label 'sysmon 3010'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode          = [string]$Mode
                ExePath       = [string]$ExePath
                ConfigPath    = [string]$ConfigPath
                ExeExisted    = $true
                ConfigExisted = $true
            })
        return 1603
    }
    $result = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 1 -MarkerAbsent $true -Label 'sysmon failure'

    Reset-SysmonCase
    $script:InstalledVersion = '1.0.0.0'
    $script:ExePath = 'C:\Windows\Sysmon64.exe'
    Set-Marker '1.0.0.0'
    $script:InvokeSysmon = {
        param($Mode, $ExePath, $ConfigPath)
        $script:SysmonCalls.Add([pscustomobject]@{
                Mode          = [string]$Mode
                ExePath       = [string]$ExePath
                ConfigPath    = [string]$ConfigPath
                ExeExisted    = $true
                ConfigExisted = $true
            })
        if ($Mode -eq 'install') { return 1603 }
        return 0
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 2 -ExpectMarker '1.0.0.0' -Label 'install failed after removal'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $script:ExpandArchive = {
        param($Path, $Destination)
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
    }
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'archive without Sysmon64.exe'

    Reset-SysmonCase
    $script:InstalledVersion = ''
    $result = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Result $result -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectCalls 0 -MarkerAbsent $true -Label 'missing hash'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$missingCode = 0
& pwsh -NoProfile -File $scriptPath 2>$null | Out-Null
$missingCode = $LASTEXITCODE
if ($missingCode -ne 1) {
    Fail "missing parameters exited $missingCode"
}

$emptyCode = 0
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion '' | Out-Null
$emptyCode = $LASTEXITCODE
if ($emptyCode -ne 0) {
    Fail "empty pin exited $emptyCode"
}

$reinstallCode = 0
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Reinstall' -Action 'Reinstall' -PinVersion '15.22' | Out-Null
$reinstallCode = $LASTEXITCODE
if ($reinstallCode -ne 1) {
    Fail "Reinstall exited $reinstallCode"
}

Write-Output 'sysmon-plan tests passed'
exit 0
