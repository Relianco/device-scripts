$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/microsoft-365/Invoke-Microsoft365.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/microsoft-365.json'
$configPath = Join-Path $repoRoot 'windows/packages/microsoft-365/configuration.xml'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Microsoft365.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/microsoft-365.json does not exist'
}
if (-not (Test-Path -LiteralPath $configPath)) {
    Fail 'configuration.xml does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-Microsoft365Plan',
        'Invoke-Microsoft365Action',
        'Save-Microsoft365Payload',
        'Get-Microsoft365SetupArgumentList',
        'Get-Microsoft365ExtractArgumentList',
        'Get-Microsoft365InstallConfiguration',
        'Get-Microsoft365RemoveConfiguration',
        'Test-Microsoft365DownloadIsTransient',
        'Test-Microsoft365PinHash',
        'Test-Microsoft365SetupPath'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20326-20112.exe'
$pinnedSha = 'fbb64358fd4168acd52ee4efe47ffd032b6231dfb415ae2dce61b0e58ba67f86'
$pinnedSetupSha = '50facf295f357d8230b4d50678536148e32f34b4ac33387269d5a72c93ff810a'
if ([string]$release.name -cne 'Microsoft 365 Apps') {
    Fail "name '$($release.name)'"
}
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded Office Deployment Tool'
}
if ([int64]$release.size -ne 3522096) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '16.0.20326.20112') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'officedeploymenttool_20326-20112.exe') {
    Fail 'release arch or file name'
}
if ([string]$release.setupFile -cne 'setup.exe') {
    Fail "setup file '$($release.setupFile)'"
}
if ([string]$release.setupSha256 -cne $pinnedSetupSha) {
    Fail 'setup.exe sha256 does not match the extracted bytes'
}
if ([int64]$release.setupSize -ne 7194464) {
    Fail "setup.exe size $($release.setupSize)"
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256 -or $SetupSha256 -cne [string]$release.setupSha256) {
    Fail 'script defaults do not match windows/releases/microsoft-365.json'
}
if (-not (Test-Microsoft365PinHash -Sha256 $pinnedSha) -or -not (Test-Microsoft365PinHash -Sha256 $pinnedSetupSha)) {
    Fail 'pinned Office Deployment Tool hash was rejected'
}
foreach ($placeholder in @('placeholder', ('0' * 64), ('f' * 64), ('deadbeef' * 8))) {
    if (Test-Microsoft365PinHash -Sha256 $placeholder) {
        Fail 'a placeholder hash was accepted'
    }
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($scriptText -match 'Ninja-Property') {
    Fail 'package calls Ninja'
}
if ($scriptText -match '(?:[A-Z0-9]{5}-){4}[A-Z0-9]{5}') {
    Fail 'package contains a product key'
}

$builtinVersion = & $script:GetInstalledMicrosoft365Version
if ($builtinVersion -isnot [string]) {
    Fail 'registry hook did not return a string'
}

$installText = (Get-Microsoft365InstallConfiguration).Trim()
$fileText = ([System.IO.File]::ReadAllText($configPath)).Trim()
if ($fileText -cne $installText) {
    Fail 'configuration.xml does not match the script'
}
if (-not (Test-Microsoft365InstallConfiguration -Text $installText)) {
    Fail 'install configuration was rejected'
}
$removeText = (Get-Microsoft365RemoveConfiguration).Trim()
if (-not (Test-Microsoft365RemoveConfiguration -Text $removeText)) {
    Fail 'remove configuration was rejected'
}
if ($removeText -match 'Windows' -or $installText -match 'Windows' -or $installText -match 'Tenant' -or $installText -match 'PIDKEY') {
    Fail 'configuration names Windows, a tenant, or a product key'
}

$installXml = [xml]$installText
$add = $installXml.SelectSingleNode('/Configuration/Add')
if ($null -eq $add -or $add.GetAttribute('OfficeClientEdition') -cne '64' -or $add.GetAttribute('Channel') -cne 'Current' -or $add.GetAttribute('MigrateArch') -cne 'TRUE') {
    Fail 'install add element is not 64-bit Current'
}
$product = $add.SelectSingleNode('Product')
if ($null -eq $product -or $product.GetAttribute('ID') -cne 'O365ProPlusRetail') {
    Fail 'install product is not Microsoft 365 Apps for enterprise'
}
$languages = $product.SelectNodes('Language')
if ($null -eq $languages -or $languages.Count -ne 3) {
    Fail 'install languages'
}
if ($languages.Item(0).GetAttribute('ID') -cne 'MatchOS' -or $languages.Item(0).GetAttribute('Fallback') -cne 'en-us') {
    Fail 'MatchOS language'
}
if ($languages.Item(1).GetAttribute('ID') -cne 'MatchInstalled' -or $languages.Item(2).GetAttribute('ID') -cne 'MatchPreviousMSI') {
    Fail 'installed language ids'
}
$excludes = $product.SelectNodes('ExcludeApp')
$excludeIds = @()
if ($null -ne $excludes) {
    foreach ($node in $excludes) {
        $excludeIds += $node.GetAttribute('ID')
    }
}
$excludeText = $excludeIds -join ','
if ($excludeText -cne 'Groove,Lync,Publisher') {
    Fail "exclude apps '$excludeText'"
}
if ($null -ne $installXml.SelectSingleNode('/Configuration/Remove')) {
    Fail 'install configuration removes a product'
}
if ($null -eq $installXml.SelectSingleNode('/Configuration/RemoveMSI')) {
    Fail 'install configuration is missing RemoveMSI'
}
$display = $installXml.SelectSingleNode('/Configuration/Display')
if ($null -eq $display -or $display.GetAttribute('Level') -cne 'None' -or $display.GetAttribute('AcceptEULA') -cne 'TRUE' -or -not [string]::IsNullOrEmpty($display.GetAttribute('Name'))) {
    Fail 'install display element'
}
$updates = $installXml.SelectSingleNode('/Configuration/Updates')
if ($null -eq $updates -or $updates.GetAttribute('Enabled') -cne 'TRUE') {
    Fail 'install updates element'
}
$expectedProps = @{
    SharedComputerLicensing = '0'
    DeviceBasedLicensing    = '0'
    FORCEAPPSHUTDOWN        = 'FALSE'
    SCLCacheOverride        = '0'
    AUTOACTIVATE            = '1'
}
$props = $installXml.SelectNodes('/Configuration/Property')
if ($null -eq $props -or $props.Count -ne 5) {
    Fail 'install property count'
}
foreach ($prop in $props) {
    $propName = $prop.GetAttribute('Name')
    $propValue = $prop.GetAttribute('Value')
    if (-not $expectedProps.ContainsKey($propName) -or $expectedProps[$propName] -cne $propValue) {
        Fail "install property $propName"
    }
}

$removeXml = [xml]$removeText
$remove = $removeXml.SelectSingleNode('/Configuration/Remove')
if ($null -eq $remove -or $remove.GetAttribute('All') -cne 'FALSE') {
    Fail 'uninstall Remove All is not FALSE'
}
$removeProduct = $remove.SelectSingleNode('Product')
if ($null -eq $removeProduct -or $removeProduct.GetAttribute('ID') -cne 'O365ProPlusRetail' -or $remove.SelectNodes('Product').Count -ne 1) {
    Fail 'uninstall product is not only Microsoft 365 Apps'
}
if ($null -ne $removeXml.SelectSingleNode('/Configuration/Add')) {
    Fail 'uninstall configuration installs a product'
}

if (Test-Microsoft365SetupPath -SetupPath 'C:\Windows\System32\setup.exe') {
    Fail 'Windows setup.exe was accepted'
}
if (Test-Microsoft365SetupPath -SetupPath 'C:\Windows\SysWOW64\setup.exe') {
    Fail 'SysWOW64 setup.exe was accepted'
}
if (-not (Test-Microsoft365SetupPath -SetupPath 'C:\cache\extract\setup.exe')) {
    Fail 'extracted setup.exe was rejected'
}
if (Test-Microsoft365SetupPath -SetupPath 'C:\cache\extract\notepad.exe') {
    Fail 'a non-setup file was accepted'
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
        $plan = Get-Microsoft365Plan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-Microsoft365Plan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-Microsoft365Plan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
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
    $plan = Get-Microsoft365Plan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
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
    $plan = Get-Microsoft365Plan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-Microsoft365Plan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = Get-Microsoft365SetupArgumentList -Mode 'install' -ConfigPath 'C:\cache\configuration.xml'
if ($null -eq $installArgs -or $installArgs.Count -ne 2 -or
    $installArgs[0] -cne '/configure' -or $installArgs[1] -cne '"C:\cache\configuration.xml"') {
    Fail "install arguments $($installArgs -join ' ')"
}
$removeArgs = Get-Microsoft365SetupArgumentList -Mode 'uninstall' -ConfigPath 'C:\cache\remove.xml'
if ($null -eq $removeArgs -or $removeArgs.Count -ne 2 -or
    $removeArgs[0] -cne '/configure' -or $removeArgs[1] -cne '"C:\cache\remove.xml"') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-Microsoft365SetupArgumentList -Mode 'uninstall' -ConfigPath '')) {
    Fail 'uninstall without a configuration built arguments'
}
if ($null -ne (Get-Microsoft365SetupArgumentList -Mode 'nope' -ConfigPath 'C:\cache\configuration.xml')) {
    Fail 'unknown mode built arguments'
}
$extractArgs = Get-Microsoft365ExtractArgumentList -Destination 'C:\cache\extract'
if ($null -eq $extractArgs -or $extractArgs.Count -ne 3 -or
    $extractArgs[0] -cne '/extract:"C:\cache\extract"' -or
    $extractArgs[1] -cne '/norestart' -or $extractArgs[2] -cne '/quiet') {
    Fail "extract arguments $($extractArgs -join ' ')"
}
if ($null -ne (Get-Microsoft365ExtractArgumentList -Destination '')) {
    Fail 'empty extract destination built arguments'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodArchiveBytes = $utf8.GetBytes('office-deployment-tool')
$script:GoodSetupBytes = $utf8.GetBytes('setup-exe')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodArchiveSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodArchiveBytes))).Replace('-', '').ToLowerInvariant()
    $script:GoodSetupSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodSetupBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

function New-Microsoft365UserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/officedeploymenttool.exe')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:ExpandCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:SetupCalls = [System.Collections.Generic.List[object]]::new()
$script:DownloadedName = ''

function Reset-Microsoft365Case {
    $script:DownloadCount = 0
    $script:ExpandCount = 0
    $script:DownloadedName = ''
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:SetupCalls = [System.Collections.Generic.List[object]]::new()
    $script:Microsoft365ErrorLog = [System.Collections.Generic.List[string]]::new()
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
        $script:DownloadedName = [System.IO.Path]::GetFileName($Destination)
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodArchiveBytes)
    }
    $script:ExpandOdt = {
        param($ArchivePath, $Destination)
        $script:ExpandCount++
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes((Join-Path $Destination 'setup.exe'), $script:GoodSetupBytes)
        return 0
    }
    $script:GetInstalledMicrosoft365Version = {
        return [string]$script:InstalledVersion
    }
    $script:InvokeSetup = {
        param($Mode, $SetupPath, $ConfigPath)
        $text = ''
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
            $text = [System.IO.File]::ReadAllText($ConfigPath)
        }
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($SetupPath)) {
            $existed = Test-Path -LiteralPath $SetupPath
        }
        $script:SetupCalls.Add([pscustomobject]@{
                Mode        = [string]$Mode
                SetupPath   = [string]$SetupPath
                SetupExisted = [bool]$existed
                ConfigText  = [string]$text
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
        [string]$InstallerUrl = 'https://example.invalid/officedeploymenttool.exe',
        [string]$InstallerSha256 = $script:GoodArchiveSha,
        [string]$SetupSha256 = $script:GoodSetupSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-Microsoft365Action -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -SetupSha256 $SetupSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectExpand,
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
    if ($script:ExpandCount -ne $ExpectExpand) {
        Fail "$Label extract $($script:ExpandCount) expected $ExpectExpand"
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
    if (($script:Microsoft365ErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

function Assert-SetupCall {
    param(
        [string]$Mode,
        [string]$Label
    )
    if ($script:SetupCalls.Count -lt 1) {
        Fail "$Label did not run setup.exe"
    }
    $call = $script:SetupCalls[0]
    if ($call.Mode -cne $Mode) {
        Fail "$Label mode '$($call.Mode)' expected '$Mode'"
    }
    if (-not $call.SetupExisted) {
        Fail "$Label setup.exe was missing"
    }
    if ([System.IO.Path]::GetFileName($call.SetupPath) -cne 'setup.exe') {
        Fail "$Label setup path '$($call.SetupPath)'"
    }
    if (-not (Test-Microsoft365SetupPath -SetupPath $call.SetupPath)) {
        Fail "$Label setup path was rejected"
    }
    if ($Mode -eq 'install') {
        if (-not (Test-Microsoft365InstallConfiguration -Text $call.ConfigText)) {
            Fail "$Label did not pass the install configuration"
        }
        if ($call.ConfigText -match '<Remove(\s|/|>)') {
            Fail "$Label install configuration removes a product"
        }
    } else {
        if (-not (Test-Microsoft365RemoveConfiguration -Text $call.ConfigText)) {
            Fail "$Label did not pass the remove configuration"
        }
        if ($call.ConfigText -match 'Windows' -or $call.ConfigText -match 'All="(?i)true"') {
            Fail "$Label remove configuration is too broad"
        }
    }
}

try {
    Reset-Microsoft365Case
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-Microsoft365UserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:Microsoft365ErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:DownloadedName = [System.IO.Path]::GetFileName($Destination)
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-Microsoft365Case
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -MarkerAbsent $true -Label 'uninstall'
    Assert-SetupCall -Mode 'uninstall' -Label 'uninstall'
    if ($script:DownloadedName -cne 'officedeploymenttool_20326-20112.exe') {
        Fail "uninstall downloaded '$($script:DownloadedName)'"
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerUrl (New-Microsoft365UserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall userinfo'

    Reset-Microsoft365Case
    Set-Marker '2.0.0.0'
    $script:GetInstalledMicrosoft365Version = {
        throw 'registry was read'
    }
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '' -SetupSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall empty hashes'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    Assert-SetupCall -Mode 'install' -Label 'Repair missing'
    if ($script:DownloadedName -cne 'officedeploymenttool_20326-20112.exe') {
        Fail "Repair downloaded '$($script:DownloadedName)'"
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    Assert-SetupCall -Mode 'install' -Label 'Repair present'

    Reset-Microsoft365Case
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'

    Reset-Microsoft365Case
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'older install'
    Assert-SetupCall -Mode 'install' -Label 'older install'

    Reset-Microsoft365Case
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel env'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:DownloadedName = [System.IO.Path]::GetFileName($Destination)
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodArchiveBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel before setup'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:InvokeSetup = {
        param($Mode, $SetupPath, $ConfigPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode         = [string]$Mode
                SetupPath    = [string]$SetupPath
                SetupExisted = (Test-Path -LiteralPath $SetupPath)
                ConfigText   = ''
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'cancel during setup'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:InvokeSetup = {
        param($Mode, $SetupPath, $ConfigPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode         = [string]$Mode
                SetupPath    = [string]$SetupPath
                SetupExisted = $true
                ConfigText   = ''
            })
        return 3010
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'setup 3010'

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeSetup = {
        param($Mode, $SetupPath, $ConfigPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode         = [string]$Mode
                SetupPath    = [string]$SetupPath
                SetupExisted = $true
                ConfigText   = ''
            })
        return 1603
    }
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'setup failure'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'missing hash'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -SetupSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'missing setup hash'

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 ('0' * 64)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'placeholder installer hash'
    if (($script:Microsoft365ErrorLog -join "`n") -notlike '*placeholder*') {
        Fail 'placeholder installer hash error did not name a placeholder'
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -SetupSha256 ('deadbeef' * 8)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'placeholder setup hash'
    if (($script:Microsoft365ErrorLog -join "`n") -notlike '*placeholder*') {
        Fail 'placeholder setup hash error did not name a placeholder'
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:ExpandOdt = {
        param($ArchivePath, $Destination)
        $script:ExpandCount++
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes((Join-Path $Destination 'setup.exe'), $utf8.GetBytes('wrong-setup'))
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 0 -MarkerAbsent $true -Label 'setup hash mismatch'
    if (($script:Microsoft365ErrorLog -join "`n") -notlike '*setup.exe*') {
        Fail 'setup hash mismatch did not name setup.exe'
    }

    Reset-Microsoft365Case
    $script:InstalledVersion = ''
    $script:ExpandOdt = {
        param($ArchivePath, $Destination)
        $script:ExpandCount++
        return 1
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectExpand 1 -ExpectSetup 0 -MarkerAbsent $true -Label 'extract failure'

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall empty installer hash'

    Reset-Microsoft365Case
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -SetupSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectExpand 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall empty setup hash'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'microsoft-365-plan tests passed'
exit 0
