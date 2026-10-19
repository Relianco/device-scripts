$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/git/Invoke-Git.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/git.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Git.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/git.json does not exist'
}

$scriptText = [System.IO.File]::ReadAllText($scriptPath)
if ($scriptText -match '\[Parameter\(Mandatory\)\]' -or $scriptText -match 'Mandatory\s*=\s*\$true') {
    Fail 'a parameter is Mandatory'
}
if ($scriptText -match 'Ninja-Property') {
    Fail 'package calls Ninja'
}
if ($scriptText -match 'git config' -or $scriptText -match '/o:') {
    Fail 'package changes git config'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

$script:RealDownloadFile = $script:DownloadFile
if ($script:RealDownloadFile -isnot [scriptblock]) {
    Fail 'download hook is not a scriptblock'
}
$downloadText = $script:RealDownloadFile.ToString()
foreach ($needle in @('param($Url, $Destination)', 'Invoke-WebRequest', '-OutFile', '-UseBasicParsing')) {
    if (-not $downloadText.Contains($needle)) {
        Fail "download hook is missing $needle"
    }
}
$script:WebCalls = [System.Collections.Generic.List[object]]::new()
$script:WebThrow = $null

foreach ($command in @(
        'Get-GitPlan',
        'Invoke-GitAction',
        'Save-GitPayload',
        'Get-GitInstallArgumentList',
        'Get-GitUninstallArgumentList',
        'Get-GitUninstallExe',
        'Test-GitDownloadIsTransient'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe'
$pinnedSha = '52188f917b378f00c70ec136bcf090005f30d44fbc4eba0bce759cc6592d60f6'
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded installer'
}
if ([int64]$release.size -ne 66763664) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '2.56.0.2') {
    Fail "version '$($release.version)'"
}
if ([string]$release.name -cne 'Git for Windows') {
    Fail "name '$($release.name)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'Git-2.56.0.2-64-bit.exe') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/git.json'
}

$builtinVersion = & $script:GetInstalledGitVersion
$builtinPath = & $script:GetGitUninstallPath
if ($builtinVersion -isnot [string] -or $builtinPath -isnot [string]) {
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
    @{
        Label = 'windows suffix equals display version'
        Pin = '2.56.0.windows.2'
        Installed = '2.56.0.2'
        Marker = '2.56.0.2'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'windows suffix newer than pin'
        Pin = '2.56.0.windows.1'
        Installed = '2.56.0.windows.2'
        Marker = '2.56.0.1'
        Expect = (New-Expect -WriteMarker '2.56.0.2')
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-GitPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-GitPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$emptyUninstall = Get-GitPlan -Action 'Uninstall' -PinVersion '' -InstalledVersion '2.0.0.0' -MarkerVersion '2.0.0.0'
Assert-Plan -Plan $emptyUninstall -Expect (New-Expect -ExitCode 0) -Label 'Uninstall empty pin'

$reinstall = Get-GitPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
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
    $plan = Get-GitPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
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
    $plan = Get-GitPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-GitPlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = @(Get-GitInstallArgumentList)
$expectedInstall = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS')
if ($installArgs.Count -ne $expectedInstall.Count) {
    Fail "install arguments $($installArgs -join ' ')"
}
for ($i = 0; $i -lt $expectedInstall.Count; $i++) {
    if ($installArgs[$i] -cne $expectedInstall[$i]) {
        Fail "install arguments $($installArgs -join ' ')"
    }
}
$joinedInstall = $installArgs -join ' '
if ($joinedInstall -like '*/o:*' -or $joinedInstall -like '*COMPONENTS*' -or $joinedInstall -like '*git config*') {
    Fail "install arguments change git config: $joinedInstall"
}
$removePath = 'C:\Program Files\Git\unins000.exe'
$removeArgs = @(Get-GitUninstallArgumentList -UninstallPath $removePath)
if ($removeArgs.Count -ne 2 -or $removeArgs[0] -cne '/VERYSILENT' -or $removeArgs[1] -cne '/NORESTART') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-GitUninstallArgumentList -UninstallPath '')) {
    Fail 'uninstall without a program built arguments'
}
$quoted = Get-GitUninstallExe -Text '"C:\Program Files\Git\unins000.exe" /SILENT'
if ($quoted -cne 'C:\Program Files\Git\unins000.exe') {
    Fail "uninstall program '$quoted'"
}
$emptyExe = Get-GitUninstallExe -Text ''
if ($emptyExe -cne '') {
    Fail "empty uninstall text returned '$emptyExe'"
}
$blankExe = Get-GitUninstallExe -Text '   '
if ($blankExe -cne '') {
    Fail "blank uninstall text returned '$blankExe'"
}
$missingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('git-missing-' + [guid]::NewGuid().ToString('n'))
$missingExe = Join-Path $missingRoot 'unins000.exe'
if (Test-Path -LiteralPath $missingExe) {
    Fail 'missing uninstall path already exists'
}
$missingResult = Get-GitUninstallExe -Text ('"' + $missingExe + '" /SILENT')
if ($missingResult -cne $missingExe) {
    Fail "missing uninstall path '$missingResult'"
}
$existingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('git-existing-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $existingRoot -Force | Out-Null
try {
    $existingExe = Join-Path $existingRoot 'unins000.exe'
    [System.IO.File]::WriteAllText($existingExe, 'x')
    $existingResult = Get-GitUninstallExe -Text ('"' + $existingExe + '" /SILENT')
    if ($existingResult -cne $existingExe) {
        Fail "existing uninstall path '$existingResult'"
    }
    if (-not (Test-Path -LiteralPath $existingExe)) {
        Fail 'existing uninstall path is not a file'
    }
} finally {
    Remove-Item -LiteralPath $existingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('git-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-GitUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/Git-2.56.0.2-64-bit.exe')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('git-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:SetupCalls = [System.Collections.Generic.List[object]]::new()

function Reset-GitCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:SetupCalls = [System.Collections.Generic.List[object]]::new()
    $script:GitErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
    $script:UninstallPath = 'C:\Program Files\Git\unins000.exe'
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
    $script:GetInstalledGitVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetGitUninstallPath = {
        return [string]$script:UninstallPath
    }
    $script:InvokeGitSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            $existed = Test-Path -LiteralPath $InstallerPath
        }
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
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
        [string]$InstallerUrl = 'https://example.invalid/Git-2.56.0.2-64-bit.exe',
        [string]$InstallerSha256 = $script:GoodSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-GitAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectSetup,
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
    if ($script:SetupCalls.Count -ne $ExpectSetup) {
        Fail "$Label setup $($script:SetupCalls.Count) expected $ExpectSetup"
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
    if (($script:GitErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

function Assert-Log {
    param(
        [string]$Expected = '',
        [bool]$Absent = $false,
        [string]$Label
    )
    $path = Join-Path $script:MarkerRoot 'toolkit.log'
    $exists = Test-Path -LiteralPath $path
    if ($Absent) {
        if ($exists) {
            $text = [System.IO.File]::ReadAllText($path)
            Fail "$Label logged '$text'"
        }
        return
    }
    if (-not $exists) {
        Fail "$Label did not write a log"
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -cne $Expected) {
        Fail "$Label log '$text' expected '$Expected'"
    }
}

function Reset-WebHook {
    $script:WebCalls = [System.Collections.Generic.List[object]]::new()
    $script:WebThrow = $null
    $script:DownloadFile = $script:RealDownloadFile
}

function Assert-RealCase {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectWeb,
        [int]$ExpectSleeps,
        [int]$ExpectSetup,
        [string]$ExpectMarker = '',
        [bool]$MarkerAbsent = $false,
        [string]$Label
    )
    Assert-Case -Code $Code -ExpectCode $ExpectCode -ExpectDownloads 0 -ExpectSleeps $ExpectSleeps -ExpectSetup $ExpectSetup -ExpectMarker $ExpectMarker -MarkerAbsent $MarkerAbsent -Label $Label
    if ($script:WebCalls.Count -ne $ExpectWeb) {
        Fail "$Label requests $($script:WebCalls.Count) expected $ExpectWeb"
    }
}

# Stands in for the network. The real download hook must call this; CI does not download the installer.
function Invoke-WebRequest {
    param(
        [string]$Uri,
        [string]$OutFile,
        [switch]$UseBasicParsing
    )
    if ($null -eq $script:WebCalls) {
        $script:WebCalls = [System.Collections.Generic.List[object]]::new()
    }
    $script:WebCalls.Add([pscustomobject]@{
            Uri             = [string]$Uri
            OutFile         = [string]$OutFile
            UseBasicParsing = [bool]$UseBasicParsing
        })
    if ($null -ne $script:WebThrow) {
        throw $script:WebThrow
    }
    [System.IO.File]::WriteAllBytes($OutFile, $script:GoodBytes)
}

try {
    Reset-GitCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'
    Assert-Log -Absent $true -Label 'empty pin'

    Reset-GitCase
    Set-Marker '9.0.0.0'
    $script:InstalledVersion = '9.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'Uninstall empty pin'
    Assert-Log -Absent $true -Label 'Uninstall empty pin'

    Reset-GitCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-GitUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:GitErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }
    Assert-Log -Absent $true -Label 'userinfo'

    Reset-GitCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'hash mismatch'
    Assert-Log -Absent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-GitCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
        Assert-Log -Absent $true -Label "$action vendor newer"
    }

    Reset-GitCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerUrl (New-GitUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 1 -MarkerAbsent $true -Label 'uninstall'
    if ($script:SetupCalls[0].Mode -cne 'uninstall' -or $script:SetupCalls[0].UninstallPath -cne $script:UninstallPath) {
        Fail 'uninstall did not pass the uninstall program'
    }
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall'

    Reset-GitCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'uninstall marker only'
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall marker only'

    Reset-GitCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:UninstallPath = ''
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing program'
    Assert-Log -Absent $true -Label 'uninstall missing program'

    Reset-GitCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    if ($script:SetupCalls[0].Mode -cne 'install' -or -not $script:SetupCalls[0].InstallerExisted) {
        Fail 'Repair missing did not run the installer file'
    }
    Assert-Log -Expected "Repair`n" -Label 'Repair missing'

    Reset-GitCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    if ($script:SetupCalls[0].Mode -cne 'install') {
        Fail 'Repair present did not run the installer again'
    }
    Assert-Log -Expected "Repair`n" -Label 'Repair present'

    Reset-GitCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'
    Assert-Log -Absent $true -Label 'Repair vendor newer'

    Reset-GitCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'older install'
    Assert-Log -Expected "Install`n" -Label 'older install'

    Reset-GitCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'
    Assert-Log -Absent $true -Label 'Reinstall'

    Reset-GitCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel env'
    Assert-Log -Absent $true -Label 'cancel env'

    Reset-GitCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-GitCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'
    Assert-Log -Expected "Install`n" -Label 'missing cancel path'

    Reset-GitCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel before setup'
    Assert-Log -Absent $true -Label 'cancel before setup'

    Reset-GitCase
    $script:InstalledVersion = ''
    $script:InvokeGitSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = (Test-Path -LiteralPath $InstallerPath)
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'cancel during setup'
    Assert-Log -Expected "Install`n" -Label 'cancel during setup'

    Reset-GitCase
    $script:InstalledVersion = ''
    $script:InvokeGitSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = $true
            })
        return 1
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -MarkerAbsent $true -Label 'setup failure'
    Assert-Log -Absent $true -Label 'setup failure'

    Reset-GitCase
    $script:InstalledVersion = ''
    foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
        Reset-GitCase
        $script:InstalledVersion = ''
        Set-Marker '9.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0' -InstallerSha256 ''
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label "$action empty hash"
        Assert-Log -Absent $true -Label "$action empty hash"
    }

    Reset-GitCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 '   '
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'whitespace hash'
    Assert-Log -Absent $true -Label 'whitespace hash'

    Reset-GitCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '   '
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Uninstall whitespace hash'
    Assert-Log -Absent $true -Label 'Uninstall whitespace hash'

    Reset-WebHook
    $directDest = Join-Path (Join-Path $script:Root 'direct') 'payload.exe'
    & $script:RealDownloadFile -Url 'https://example.invalid/Git-2.56.0.2-64-bit.exe' -Destination $directDest
    if ($script:WebCalls.Count -ne 1) {
        Fail "real download hook made $($script:WebCalls.Count) requests"
    }
    if ($script:WebCalls[0].Uri -cne 'https://example.invalid/Git-2.56.0.2-64-bit.exe') {
        Fail "real download hook URI '$($script:WebCalls[0].Uri)'"
    }
    if ($script:WebCalls[0].OutFile -cne $directDest) {
        Fail "real download hook outfile '$($script:WebCalls[0].OutFile)'"
    }
    if (-not $script:WebCalls[0].UseBasicParsing) {
        Fail 'real download hook omitted UseBasicParsing'
    }
    if (-not (Test-Path -LiteralPath $directDest)) {
        Fail 'real download hook wrote no file'
    }
    $directBytes = [System.IO.File]::ReadAllBytes($directDest)
    if ($directBytes.Length -ne $script:GoodBytes.Length) {
        Fail "real download hook wrote $($directBytes.Length) bytes"
    }
    for ($i = 0; $i -lt $directBytes.Length; $i++) {
        if ($directBytes[$i] -ne $script:GoodBytes[$i]) {
            Fail 'real download hook wrote unexpected bytes'
        }
    }

    Reset-WebHook
    $script:WebThrow = [System.Net.WebException]::new('protocol', [System.Net.WebExceptionStatus]::ProtocolError)
    $webDest = Join-Path (Join-Path $script:Root 'direct') 'web-exception.exe'
    $sawWeb = $false
    try {
        & $script:RealDownloadFile -Url 'https://example.invalid/Git-2.56.0.2-64-bit.exe' -Destination $webDest
    } catch [System.Net.WebException] {
        $sawWeb = $true
    } catch {
        Fail "real download hook threw $($_.Exception.GetType().FullName)"
    }
    if (-not $sawWeb) {
        Fail 'real download hook swallowed WebException'
    }
    if (Test-Path -LiteralPath $webDest) {
        Fail 'WebException hook wrote a file'
    }
    if ($script:WebCalls.Count -ne 1 -or -not $script:WebCalls[0].UseBasicParsing) {
        Fail "WebException hook made $($script:WebCalls.Count) requests"
    }

    Reset-GitCase
    Reset-WebHook
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-RealCase -Code $code -ExpectCode 0 -ExpectWeb 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'install hook'
    if ($script:WebCalls[0].Uri -cne 'https://example.invalid/Git-2.56.0.2-64-bit.exe' -or -not $script:WebCalls[0].UseBasicParsing) {
        Fail "install hook request '$($script:WebCalls[0].Uri)'"
    }
    if ($script:SetupCalls[0].Mode -cne 'install' -or -not $script:SetupCalls[0].InstallerExisted) {
        Fail 'install hook did not run the downloaded file'
    }
    Assert-Log -Expected "Install`n" -Label 'install hook'

    Reset-GitCase
    Reset-WebHook
    $script:WebThrow = [System.Net.WebException]::new('protocol', [System.Net.WebExceptionStatus]::ProtocolError)
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-RealCase -Code $code -ExpectCode 1 -ExpectWeb 1 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'WebException hook'
    Assert-Log -Absent $true -Label 'WebException hook'

    foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
        Reset-GitCase
        Reset-WebHook
        $script:InstalledVersion = ''
        Set-Marker '9.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0' -InstallerSha256 ''
        Assert-RealCase -Code $code -ExpectCode 0 -ExpectWeb 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label "$action empty hash hook"
        Assert-Log -Absent $true -Label "$action empty hash hook"
    }

    Reset-GitCase
    Reset-WebHook
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:GetInstalledGitVersion = {
        throw 'registry unavailable'
    }
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-RealCase -Code $code -ExpectCode 0 -ExpectWeb 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Uninstall empty hash hook'
    Assert-Log -Absent $true -Label 'Uninstall empty hash hook'

    Reset-GitCase
    Reset-WebHook
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-GitUserInfoUrl)
    Assert-RealCase -Code $code -ExpectCode 1 -ExpectWeb 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'userinfo hook'
    if (($script:GitErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo hook error did not name userinfo'
    }
    Assert-Log -Absent $true -Label 'userinfo hook'

    Reset-GitCase
    Reset-WebHook
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-RealCase -Code $code -ExpectCode 1 -ExpectWeb 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall hook'
    Assert-Log -Absent $true -Label 'Reinstall hook'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'git-plan tests passed'
exit 0
