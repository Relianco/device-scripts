$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/edge/Invoke-Edge.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/edge.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Edge.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/edge.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
$expectedUrl = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/bf3e7059-ee35-457f-946e-42963960692d/MicrosoftEdgeEnterpriseX64.msi'
$expectedSha = '20119979eb1670f670d38c093fd1c61f5a91d880c473f8614825ce9aef35f68a'
if ([string]$release.name -ne 'Microsoft Edge') { Fail 'release name' }
if ([string]$release.channel -ne 'Stable') { Fail 'release channel' }
if ([string]$release.platform -ne 'Windows') { Fail 'release platform' }
if ([string]$release.arch -ne 'x64') { Fail 'release arch' }
if ([string]$release.version -ne '155.0.4283.62') { Fail 'release version' }
if ([string]$release.file -ne 'MicrosoftEdgeEnterpriseX64.msi') { Fail 'release file' }
if ([string]$release.url -cne $expectedUrl) { Fail 'release url' }
if ([string]$release.sha256 -cne $expectedSha) { Fail 'release sha256' }
if ([int64]$release.size -ne 214589440) { Fail 'release size' }
if ([string]$release.hashAlgorithm -ne 'SHA256') { Fail 'release hash algorithm' }
if ([string]$release.source -ne 'https://edgeupdates.microsoft.com/api/products') { Fail 'release source' }
if ([string]$release.sha256 -notmatch '^[0-9a-f]{64}$') { Fail 'release sha256 is not lowercase hex' }

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Fail 'Invoke-Edge.ps1 did not parse'
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

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-EdgePlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-EdgePlan was not defined'
}
if (-not (Get-Command Invoke-EdgeAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-EdgeAction was not defined'
}
if ($InstallerUrl -cne [string]$release.url) {
    Fail 'InstallerUrl default does not match windows/releases/edge.json'
}
if ($InstallerSha256 -cne [string]$release.sha256) {
    Fail 'InstallerSha256 default does not match windows/releases/edge.json'
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
        Installed = '155.0.4283.80'
        Marker = '155.0.4283.80'
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
        Pin = '155.0.4283.62'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'older than pin'
        Pin = '155.0.4283.62'
        Installed = '155.0.4283.50'
        Marker = '155.0.4283.50'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '155.0.4283.62'
        Installed = '155.0.4283.62'
        Marker = ''
        Expect = (New-Expect -WriteMarker '155.0.4283.62')
    }
    @{
        Label = 'equal pin with marker'
        Pin = '155.0.4283.62'
        Installed = '155.0.4283.62'
        Marker = '155.0.4283.62'
        Expect = (New-Expect)
    }
    @{
        Label = 'vendor newer than pin'
        Pin = '155.0.4283.62'
        Installed = '155.0.4283.80'
        Marker = '155.0.4283.62'
        Expect = (New-Expect -WriteMarker '155.0.4283.80')
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = '155.0.4283.62'
        Installed = '155.0.4283.80'
        Marker = '155.0.4283.80'
        Expect = (New-Expect)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-EdgePlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-EdgePlan -Action 'Install' -PinVersion '   ' -InstalledVersion '155.0.4283.62' -MarkerVersion ''
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-EdgePlan -Action 'Reinstall' -PinVersion '155.0.4283.62' -InstalledVersion '155.0.4283.62' -MarkerVersion '155.0.4283.62'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$unknown = Get-EdgePlan -Action 'Nope' -PinVersion '155.0.4283.62' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '155.0.4283.62'; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair equal'
        Pin = '155.0.4283.62'; Installed = '155.0.4283.62'; Marker = '155.0.4283.62'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '155.0.4283.62'; Installed = '155.0.4283.50'; Marker = '155.0.4283.50'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '155.0.4283.62'; Installed = '155.0.4283.80'; Marker = '155.0.4283.62'
        Expect = (New-Expect -WriteMarker '155.0.4283.80')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-EdgePlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall installed Edge'
        Pin = '155.0.4283.62'; Installed = '155.0.4283.80'; Marker = '155.0.4283.80'
        Expect = (New-Expect -UninstallProduct $true -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '155.0.4283.62'; Installed = ''; Marker = '155.0.4283.62'
        Expect = (New-Expect -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '155.0.4283.62'; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-EdgePlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$edgeCode = '{11111111-2222-3333-4444-555555555555}'
$webviewCode = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$betaCode = '{BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
$products = @(
    [pscustomobject]@{ DisplayName = 'Microsoft Edge WebView2 Runtime'; ProductCode = $webviewCode }
    [pscustomobject]@{ DisplayName = 'Microsoft Edge Beta'; ProductCode = $betaCode }
    [pscustomobject]@{ DisplayName = 'Microsoft Edge'; ProductCode = $edgeCode }
    [pscustomobject]@{ DisplayName = 'Microsoft Edge'; ProductCode = $webviewCode }
)
$selected = @(Get-EdgeMsiProductCode -Products $products)
if ($selected.Count -ne 1 -or $selected[0] -ne $edgeCode) {
    Fail "product selection returned $($selected -join ',')"
}
if (@(Get-EdgeMsiProductCode -Products @([pscustomobject]@{ DisplayName = 'Microsoft Edge WebView2 Runtime'; ProductCode = $webviewCode })).Count -ne 0) {
    Fail 'WebView2 was selected for uninstall'
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$good = $utf8.GetBytes('edge-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:InstallerCalls = 0
$script:MsiexecArgs = [System.Collections.Generic.List[object]]::new()

function Reset-Action {
    param([string]$MarkerText = '')
    $script:DownloadCount = 0
    $script:InstallerCalls = 0
    $script:MsiexecArgs.Clear()
    $script:EdgeErrorLog.Clear()
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:MarkerRoot = Join-Path $root ('marker-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($MarkerText)) {
        [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $MarkerText, $utf8)
    }
    $script:InstallerPath = Join-Path $script:MarkerRoot 'MicrosoftEdgeEnterpriseX64.msi'
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
    $script:ReadInstalledVersion = { return '155.0.4283.62' }
    $script:ListMsiProducts = { return @() }
}

function Get-MarkerText {
    $path = Join-Path $script:MarkerRoot 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

Reset-Action
$code = Invoke-EdgeAction -Action 'Install' -PinVersion '' -InstalledVersion '155.0.4283.80' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "empty pin action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}

Reset-Action -MarkerText '155.0.4283.62'
$code = Invoke-EdgeAction -Action 'Update' -PinVersion '155.0.4283.62' -InstalledVersion '155.0.4283.80' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "vendor-newer action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ((Get-MarkerText) -ne '155.0.4283.80') {
    Fail "vendor-newer marker is '$(Get-MarkerText)'"
}

Reset-Action
$code = Invoke-EdgeAction -Action 'Repair' -PinVersion '155.0.4283.62' -InstalledVersion '' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:InstallerCalls -ne 1) {
    Fail "repair missing returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
$repairArgs = @($script:MsiexecArgs[0])
if ($repairArgs[0] -ne '/i' -or $repairArgs -contains '/x') {
    Fail "repair missing arguments $($repairArgs -join ' ')"
}
if ((Get-MarkerText) -ne '155.0.4283.62') {
    Fail "repair missing marker is '$(Get-MarkerText)'"
}

Reset-Action -MarkerText '155.0.4283.62'
$script:ListMsiProducts = {
    return @(
        [pscustomobject]@{ DisplayName = 'Microsoft Edge WebView2 Runtime'; ProductCode = $webviewCode }
        [pscustomobject]@{ DisplayName = 'Microsoft Edge Beta'; ProductCode = $betaCode }
        [pscustomobject]@{ DisplayName = 'Microsoft Edge'; ProductCode = $edgeCode }
    )
}
$code = Invoke-EdgeAction -Action 'Uninstall' -PinVersion '155.0.4283.62' -InstalledVersion '155.0.4283.62' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
$flat = [System.Collections.Generic.List[string]]::new()
foreach ($call in $script:MsiexecArgs) {
    foreach ($arg in @($call)) {
        $flat.Add([string]$arg)
    }
}
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 1) {
    Fail "uninstall returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ($flat -notcontains $edgeCode -or $flat -contains $webviewCode -or $flat -contains $betaCode) {
    Fail "uninstall arguments $($flat -join ' ')"
}
if ($flat[0] -ne '/x') {
    Fail "uninstall did not use msiexec /x"
}
if (Test-Path -LiteralPath (Join-Path $script:MarkerRoot 'marker.txt')) {
    Fail 'uninstall left the marker'
}

Reset-Action -MarkerText '155.0.4283.62'
$code = Invoke-EdgeAction -Action 'Reinstall' -PinVersion '155.0.4283.62' -InstalledVersion '155.0.4283.62' -MarkerRoot $script:MarkerRoot -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $script:InstallerPath
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "Reinstall action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if ((Get-MarkerText) -ne '155.0.4283.62') {
    Fail 'Reinstall changed the marker'
}

$keptTest = $env:RELIAN_DEPLOY_TEST
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
$processMarker = Join-Path $root 'process-marker'
New-Item -ItemType Directory -Path $processMarker -Force | Out-Null
$processFile = Join-Path $processMarker 'marker.txt'
[System.IO.File]::WriteAllText($processFile, '9.9.9.9', $utf8)
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Reinstall' -PinVersion '155.0.4283.62' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 1) {
    Fail "Reinstall process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -ne '9.9.9.9') {
    Fail 'Reinstall process changed the marker'
}
& pwsh -NoProfile -File $scriptPath -DeploymentType 'Install' -Action 'Install' -PinVersion '' -MarkerRoot $processMarker -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $expectedSha
if ($LASTEXITCODE -ne 0) {
    Fail "empty pin process exited $LASTEXITCODE"
}
if ([System.IO.File]::ReadAllText($processFile) -ne '9.9.9.9') {
    Fail 'empty pin process changed the marker'
}
$env:RELIAN_DEPLOY_TEST = $keptTest

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'edge-plan tests passed'
exit 0
