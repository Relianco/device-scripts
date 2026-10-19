$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/quicklook/Invoke-QuickLook.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/quicklook.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-QuickLook.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/quicklook.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
$expectedUrl = 'https://github.com/QL-Win/QuickLook/releases/download/4.5.0/QuickLook-4.5.0.msi'
$expectedSha = '130f601eab7c388025351312f949749adebc6429b1042bd2001ac32a17a2748c'
if ([string]$release.name -ne 'QuickLook') { Fail 'release name' }
if ([string]$release.platform -ne 'Windows') { Fail 'release platform' }
if ([string]$release.version -ne '4.5.0.0') { Fail 'release version' }
if ([string]$release.file -ne 'QuickLook-4.5.0.msi') { Fail 'release file' }
if ([string]$release.url -cne $expectedUrl) { Fail 'release url' }
if ([string]$release.url -match 'latest') { Fail 'release url is a latest redirect' }
if ([string]$release.sha256 -cne $expectedSha) { Fail 'release sha256' }
if ([int64]$release.size -ne 94425456) { Fail 'release size' }
if ([string]$release.hashAlgorithm -ne 'SHA256') { Fail 'release hash algorithm' }
if ([string]$release.source -ne 'https://github.com/QL-Win/QuickLook/releases/tag/4.5.0') { Fail 'release source' }
if ([string]$release.sha256 -cnotmatch '^[0-9a-f]{64}$') { Fail 'release sha256 is not lowercase hex' }
if ([string]$release.sha256 -ceq ([string]$release.sha256).Substring(0, 1) * 64) { Fail 'release sha256 is a repeated character' }
if (([string]$release.sha256).ToUpperInvariant() -cnotmatch '^[0-9a-f]{64}$') {
    # Uppercase must fail a case-sensitive check. -cnotmatch on the uppercase text is true.
} else {
    Fail 'uppercase hash matched a case-sensitive lowercase pattern'
}
if (-not (('A' * 64) -cnotmatch '^[0-9a-f]{64}$')) { Fail 'uppercase hex was accepted by -cnotmatch' }
if (-not (('0' * 64) -cnotmatch '^[0-9a-f]{64}$' -eq $false)) { Fail '64 zeroes failed the hex pattern itself' }

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Fail 'Invoke-QuickLook.ps1 did not parse'
}
$wanted = @('DeploymentType', 'Action', 'PinVersion', 'InstallerUrl', 'InstallerSha256', 'CancelPath', 'MarkerRoot')
$found = @{}
foreach ($parameter in $ast.ParamBlock.Parameters) {
    $name = $parameter.Name.VariablePath.UserPath
    $found[$name] = $true
    $typeName = $parameter.StaticType.Name
    if ($typeName -ne 'String') {
        Fail "$name is $typeName, expected String"
    }
    foreach ($attr in $parameter.Attributes) {
        if ($attr.TypeName.Name -ne 'Parameter') {
            continue
        }
        foreach ($named in $attr.NamedArguments) {
            if ($named.ArgumentName -eq 'Mandatory' -and $named.Argument.Extent.Text -match 'true') {
                Fail "$name is Mandatory"
            }
        }
    }
}
foreach ($name in $wanted) {
    if (-not $found.ContainsKey($name)) {
        Fail "missing parameter $name"
    }
}

$source = [System.IO.File]::ReadAllText($scriptPath)
if ($source -match 'INSTALLFOLDER') { Fail 'package sets INSTALLFOLDER' }
if ($source -match '/qb') { Fail 'package passes /qb' }
if ($source -match 'Stop-Process') { Fail 'package stops a process' }

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-QuickLookPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-QuickLookPlan was not defined'
}
if (-not (Get-Command Invoke-QuickLookAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-QuickLookAction was not defined'
}
if ($InstallerUrl -cne [string]$release.url) {
    Fail 'InstallerUrl default does not match windows/releases/quicklook.json'
}
if ($InstallerSha256 -cne [string]$release.sha256) {
    Fail 'InstallerSha256 default does not match windows/releases/quicklook.json'
}
if (-not (Test-QuickLookSha256Text -Sha256 $InstallerSha256)) {
    Fail 'script hash default was rejected'
}
if (Test-QuickLookSha256Text -Sha256 $InstallerSha256.ToUpperInvariant()) {
    Fail 'uppercase hash was accepted'
}
if (Test-QuickLookSha256Text -Sha256 ('0' * 64)) {
    Fail '64 zeroes were accepted'
}

$builtinVersion = & $script:ReadInstalledVersion
if ($builtinVersion -isnot [string]) {
    Fail 'registry hook did not return a string'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    $names = @('ExitCode', 'RunInstaller', 'UninstallProduct', 'WriteMarker', 'ClearMarker', 'Log')
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
    foreach ($name in @('RunInstaller', 'WriteMarker', 'Log')) {
        $actual = [string]$Plan.$name
        $want = [string]$Expect[$name]
        if ($actual -cne $want) {
            Fail "$Label $name '$actual' expected '$want'"
        }
    }
    foreach ($name in @('UninstallProduct', 'ClearMarker')) {
        if ([bool]$Plan.$name -ne [bool]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [bool]$UninstallProduct = $false,
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return @{
        ExitCode         = $ExitCode
        RunInstaller     = $RunInstaller
        UninstallProduct = $UninstallProduct
        WriteMarker      = $WriteMarker
        ClearMarker      = $ClearMarker
        Log              = $Log
    }
}

$installRows = @(
    @{
        Label = 'empty pin'
        Pin = ''
        Installed = '4.6.0.0'
        Marker = '4.6.0.0'
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
        Pin = '4.5.0.0'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'older than pin'
        Pin = '4.5.0.0'
        Installed = '4.4.0.0'
        Marker = '4.4.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '4.5.0.0'
        Installed = '4.5.0.0'
        Marker = ''
        Expect = (New-Expect -WriteMarker '4.5.0.0')
    }
    @{
        Label = 'equal pin with marker'
        Pin = '4.5.0.0'
        Installed = '4.5.0.0'
        Marker = '4.5.0.0'
        Expect = (New-Expect)
    }
    @{
        Label = 'vendor newer than pin'
        Pin = '4.5.0.0'
        Installed = '4.6.0.0'
        Marker = '4.5.0.0'
        Expect = (New-Expect -WriteMarker '4.6.0.0')
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = '4.5.0.0'
        Installed = '4.6.0.0'
        Marker = '4.6.0.0'
        Expect = (New-Expect)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-QuickLookPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-QuickLookPlan -Action 'Install' -PinVersion '   ' -InstalledVersion '4.5.0.0' -MarkerVersion ''
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-QuickLookPlan -Action 'Reinstall' -PinVersion '4.5.0.0' -InstalledVersion '4.5.0.0' -MarkerVersion '4.5.0.0'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$unknown = Get-QuickLookPlan -Action 'Nope' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '4.5.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair equal'
        Pin = '4.5.0.0'; Installed = '4.5.0.0'; Marker = '4.5.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '4.5.0.0'; Installed = '4.4.0.0'; Marker = '4.4.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '4.5.0.0'; Installed = '4.6.0.0'; Marker = '4.5.0.0'
        Expect = (New-Expect -WriteMarker '4.6.0.0')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-QuickLookPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall installed QuickLook'
        Pin = '4.5.0.0'; Installed = '4.6.0.0'; Marker = '4.6.0.0'
        Expect = (New-Expect -UninstallProduct $true -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '4.5.0.0'; Installed = ''; Marker = '4.5.0.0'
        Expect = (New-Expect -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '4.5.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-QuickLookPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$quickLookCode = '{6B6946D5-D3E9-48F9-AA6C-70133B09D730}'
$pluginCode = '{11111111-2222-3333-4444-555555555555}'
$otherCode = '{BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
$products = @(
    [pscustomobject]@{ DisplayName = 'QuickLook Plugin'; ProductCode = $pluginCode }
    [pscustomobject]@{ DisplayName = 'Something Else'; ProductCode = $otherCode }
    [pscustomobject]@{ DisplayName = 'QuickLook'; ProductCode = $quickLookCode }
    [pscustomobject]@{ DisplayName = 'QuickLook'; ProductCode = 'not-a-guid' }
)
$selected = @(Get-QuickLookMsiProductCode -Products $products)
if ($selected.Count -ne 1 -or $selected[0] -ne $quickLookCode) {
    Fail "product selection returned $($selected -join ',')"
}
if (@(Get-QuickLookMsiProductCode -Products @([pscustomobject]@{ DisplayName = 'QuickLook Plugin'; ProductCode = $pluginCode })).Count -ne 0) {
    Fail 'a plugin was selected for uninstall'
}

$spaced = 'C:\Program Files\Temp\QuickLook-4.5.0.msi'
$installArgs = @(Get-QuickLookInstallArgumentList -InstallerPath $spaced)
$installLine = Get-QuickLookMsiexecCommandLine -ArgumentList $installArgs
$expectedInstall = '/i "' + $spaced + '" /qn /norestart ALLUSERS=1'
if ($installLine -cne $expectedInstall) {
    Fail "install command '$installLine'"
}
if ($installArgs.Count -ne 5 -or $installArgs[1] -cne ('"' + $spaced + '"')) {
    Fail 'spaced MSI path was not one quoted argument'
}
if ($installLine -match '/qb' -or $installLine -match 'INSTALLFOLDER' -or $installLine -match '/quiet') {
    Fail 'install command used a forbidden switch'
}
$removeArgs = @(Get-QuickLookUninstallArgumentList -ProductCode $quickLookCode)
$removeLine = Get-QuickLookMsiexecCommandLine -ArgumentList $removeArgs
if ($removeLine -cne ('/x ' + $quickLookCode + ' /qn /norestart ALLUSERS=1')) {
    Fail "uninstall command '$removeLine'"
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
function Get-Sha {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('quicklook-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$good = $utf8.GetBytes('quicklook-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:InstallerCalls = 0
$script:MsiexecArgs = [System.Collections.Generic.List[object]]::new()

function Reset-Action {
    param([string]$MarkerText = '')
    $script:DownloadCount = 0
    $script:InstallerCalls = 0
    $script:MsiexecArgs.Clear()
    $script:QuickLookErrorLog.Clear()
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:MarkerRoot = Join-Path $root ('marker-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($MarkerText)) {
        [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $MarkerText, $utf8)
    }
    $spaceDir = Join-Path $script:MarkerRoot 'temp dir'
    New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null
    $script:InstallerPath = Join-Path $spaceDir 'QuickLook-4.5.0.msi'
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $script:RetryDelay = {
        param($Seconds)
        $script:Sleeps.Add([int]$Seconds)
    }
    $script:StartMsiexec = {
        param([string[]]$ArgumentList)
        $script:InstallerCalls++
        $script:MsiexecArgs.Add(@($ArgumentList))
        return 0
    }
    $script:ReadInstalledVersion = { return '4.5.0.0' }
    $script:ListMsiProducts = { return @() }
}

function Get-MarkerText {
    $path = Join-Path $script:MarkerRoot 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

function Get-LogText {
    $path = Join-Path $script:MarkerRoot 'toolkit.log'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

Reset-Action
$code = Invoke-QuickLookAction -Action 'Install' -PinVersion '' -InstalledVersion '4.6.0.0' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "empty pin action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}

Reset-Action -MarkerText '4.5.0.0'
$code = Invoke-QuickLookAction -Action 'Update' -PinVersion '4.5.0.0' -InstalledVersion '4.6.0.0' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "vendor-newer action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ((Get-MarkerText) -ne '4.6.0.0') {
    Fail "vendor-newer marker is '$(Get-MarkerText)'"
}
if ((Get-LogText) -like '*Install*') {
    Fail 'vendor-newer logged Install'
}

Reset-Action
$code = Invoke-QuickLookAction -Action 'Repair' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:InstallerCalls -ne 1) {
    Fail "repair missing returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
$repairArgs = @($script:MsiexecArgs[0])
$repairLine = Get-QuickLookMsiexecCommandLine -ArgumentList $repairArgs
if ($repairArgs[0] -ne '/i' -or $repairArgs -contains '/x') {
    Fail "repair missing arguments $($repairArgs -join ' ')"
}
if ($repairArgs[1] -cne ('"' + $script:InstallerPath + '"')) {
    Fail "repair did not quote the MSI path '$($repairArgs[1])'"
}
if ($repairLine -notlike '*ALLUSERS=1*' -or $repairLine -notlike '*/qn*' -or $repairLine -notlike '*/norestart*') {
    Fail "repair command '$repairLine'"
}
if ($repairLine -match '/qb' -or $repairLine -match 'INSTALLFOLDER') {
    Fail "repair command used a forbidden switch '$repairLine'"
}
if ((Get-MarkerText) -ne '4.5.0.0') {
    Fail "repair missing marker is '$(Get-MarkerText)'"
}
if ((Get-LogText).Trim() -cne 'Repair') {
    Fail "repair log is '$(Get-LogText)'"
}

Reset-Action -MarkerText '4.5.0.0'
$script:ListMsiProducts = {
    return @(
        [pscustomobject]@{ DisplayName = 'QuickLook Plugin'; ProductCode = $pluginCode }
        [pscustomobject]@{ DisplayName = 'Something Else'; ProductCode = $otherCode }
        [pscustomobject]@{ DisplayName = 'QuickLook'; ProductCode = $quickLookCode }
    )
}
$code = Invoke-QuickLookAction -Action 'Uninstall' -PinVersion '4.5.0.0' -InstalledVersion '4.5.0.0' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
$flat = [System.Collections.Generic.List[string]]::new()
foreach ($call in $script:MsiexecArgs) {
    foreach ($arg in @($call)) {
        $flat.Add([string]$arg)
    }
}
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 1) {
    Fail "uninstall returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ($flat -notcontains $quickLookCode -or $flat -contains $pluginCode -or $flat -contains $otherCode) {
    Fail "uninstall arguments $($flat -join ' ')"
}
if ($flat[0] -ne '/x') {
    Fail 'uninstall did not use msiexec /x'
}
if ($flat -notcontains '/qn' -or $flat -notcontains '/norestart' -or $flat -notcontains 'ALLUSERS=1') {
    Fail "uninstall arguments $($flat -join ' ')"
}
if (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'marker.txt')) {
    Fail 'uninstall left the marker'
}
if ((Get-LogText).Trim() -cne 'Uninstall') {
    Fail "uninstall log is '$(Get-LogText)'"
}

Reset-Action -MarkerText '4.5.0.0'
$code = Invoke-QuickLookAction -Action 'Reinstall' -PinVersion '4.5.0.0' -InstalledVersion '4.5.0.0' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "Reinstall action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ((Get-MarkerText) -ne '4.5.0.0') {
    Fail 'Reinstall changed the marker'
}

foreach ($emptyAction in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
    Reset-Action -MarkerText '4.5.0.0'
    $script:ReadInstalledVersion = { Fail "empty hash dispatched $emptyAction" }
    $script:ListMsiProducts = { Fail "empty hash dispatched $emptyAction" }
    $script:DownloadFile = { Fail "empty hash downloaded during $emptyAction" }
    $script:StartMsiexec = { Fail "empty hash started msiexec during $emptyAction" }
    $code = Invoke-QuickLookAction -Action $emptyAction -PinVersion '4.5.0.0' -InstalledVersion '4.5.0.0' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 '' -InstallerPath $script:InstallerPath
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
        Fail "empty hash $emptyAction returned $code"
    }
    if ((Get-MarkerText) -ne '4.5.0.0') {
        Fail "empty hash $emptyAction changed the marker"
    }
}

$keptTest = $env:RELIAN_DEPLOY_TEST
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
$processMarker = Join-Path $root 'process-marker'
New-Item -ItemType Directory -Path $processMarker -Force | Out-Null
$processFile = Join-Path $processMarker 'marker.txt'
[System.IO.File]::WriteAllText($processFile, '9.9.9.9', $utf8)
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Reinstall' -PinVersion '4.5.0.0' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 1) {
    Fail "Reinstall process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -ne '9.9.9.9') {
    Fail 'Reinstall process changed the marker'
}
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion '' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 0) {
    Fail "empty pin process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -ne '9.9.9.9') {
    Fail 'empty pin process changed the marker'
}
foreach ($processAction in @('Install', 'Uninstall', 'Reinstall')) {
    & pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action $processAction -PinVersion '4.5.0.0' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/QuickLook-4.5.0.msi' -InstallerSha256 ''
    if ($LASTEXITCODE -ne 0) {
        Fail "empty hash $processAction process exited $LASTEXITCODE"
    }
    if ([System.IO.File]::ReadAllText($processFile) -ne '9.9.9.9') {
        Fail "empty hash $processAction process changed the marker"
    }
}
$env:RELIAN_DEPLOY_TEST = $keptTest

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'quicklook-plan tests passed'
exit 0
