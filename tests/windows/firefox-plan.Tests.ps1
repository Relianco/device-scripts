$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/firefox/Invoke-Firefox.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Test-FirefoxParameterMandatory {
    param($Parameter)
    foreach ($attribute in $Parameter.Attributes) {
        if ($attribute.TypeName.Name -ne 'Parameter') {
            continue
        }
        foreach ($named in $attribute.NamedArguments) {
            if ($named.ArgumentName -ne 'Mandatory') {
                continue
            }
            # [Parameter(Mandatory)] omits the value. The AST flag is ExpressionOmitted.
            # ArgumentOmitted is not a property; honor it only when the runtime has it.
            $omitted = $named.ExpressionOmitted
            if ($named.PSObject.Properties.Name -contains 'ArgumentOmitted' -and $named.ArgumentOmitted) {
                $omitted = $true
            }
            if ($omitted) {
                return $true
            }
            $argument = $named.Argument
            if ($null -eq $argument) {
                continue
            }
            $text = [string]$argument.Extent.Text
            if ($text -match '(?i)^\s*\$true\s*$') {
                return $true
            }
            if ($argument -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $value = $argument.Value
                if ($value -is [bool]) {
                    if ($value) { return $true }
                    continue
                }
                if (($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -and ([double]$value) -ne 0) {
                    return $true
                }
            }
        }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Firefox.ps1 does not exist'
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Fail 'Invoke-Firefox.ps1 did not parse'
}
$expectedParams = @('DeploymentType', 'Action', 'PinVersion', 'InstallerUrl', 'InstallerSha256', 'CancelPath', 'MarkerRoot')
$foundParams = @{}
foreach ($parameter in $ast.ParamBlock.Parameters) {
    $name = $parameter.Name.VariablePath.UserPath
    $foundParams[$name] = $true
    if ($parameter.StaticType.FullName -ne 'System.String') {
        Fail "$name is not a plain string"
    }
    if (Test-FirefoxParameterMandatory -Parameter $parameter) {
        Fail "$name is Mandatory"
    }
    foreach ($attribute in $parameter.Attributes) {
        $attributeName = $attribute.TypeName.Name
        if ($attributeName -eq 'ValidateSet' -or $attributeName -eq 'ValidateNotNull') {
            Fail "$name has $attributeName"
        }
    }
}
foreach ($name in $expectedParams) {
    if (-not $foundParams.ContainsKey($name)) {
        Fail "missing parameter $name"
    }
}

function Assert-MandatorySample {
    param(
        [string]$Source,
        [bool]$Expect,
        [string]$Label
    )
    $sampleTokens = $null
    $sampleErrors = $null
    $sampleAst = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$sampleTokens, [ref]$sampleErrors)
    if ($sampleErrors.Count -gt 0 -or $null -eq $sampleAst.ParamBlock -or $sampleAst.ParamBlock.Parameters.Count -lt 1) {
        Fail "could not parse $Label"
    }
    $flagged = Test-FirefoxParameterMandatory -Parameter $sampleAst.ParamBlock.Parameters[0]
    if ($flagged -ne $Expect) {
        if ($Expect) {
            Fail "$Label was accepted"
        }
        Fail "$Label was rejected"
    }
}

Assert-MandatorySample -Source 'param([Parameter(Mandatory)][string]$Name)' -Expect $true -Label 'shorthand Mandatory'
Assert-MandatorySample -Source 'param([Parameter(Mandatory=$true)][string]$Name)' -Expect $true -Label 'explicit Mandatory'
Assert-MandatorySample -Source 'param([Parameter(Mandatory=1)][string]$Name)' -Expect $true -Label 'numeric Mandatory'
Assert-MandatorySample -Source 'param([Parameter(Mandatory=$false)][string]$Name)' -Expect $false -Label 'disabled Mandatory'

$source = [System.IO.File]::ReadAllText($scriptPath)
if ($source -match 'Stop-Process') {
    Fail 'package stops a process'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-FirefoxPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-FirefoxPlan was not defined'
}
if (-not (Get-Command Invoke-FirefoxAction -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-FirefoxAction was not defined'
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

$none = New-Expect -ExitCode 0
foreach ($action in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
    $plan = Get-FirefoxPlan -Action $action -PinVersion '' -InstalledVersion '159.0' -MarkerVersion '158.0'
    Assert-Plan -Plan $plan -Expect $none -Label "$action empty pin"
    $blank = Get-FirefoxPlan -Action $action -PinVersion '   ' -InstalledVersion '159.0' -MarkerVersion '158.0'
    Assert-Plan -Plan $blank -Expect $none -Label "$action whitespace pin"
}

$badPin = Get-FirefoxPlan -Action 'Install' -PinVersion 'nope' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $badPin -Expect (New-Expect -ExitCode 1) -Label 'unparseable pin'

$reinstall = Get-FirefoxPlan -Action 'Reinstall' -PinVersion '158.0' -InstalledVersion '158.0' -MarkerVersion '158.0'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$unknown = Get-FirefoxPlan -Action 'Nope' -PinVersion '158.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installRows = @(
    @{
        Label = 'missing'
        Pin = '158.0'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'older than pin'
        Pin = '158.0'
        Installed = '157.0'
        Marker = '157.0'
        Expect = (New-Expect -RunInstaller 'install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '158.0'
        Installed = '158.0'
        Marker = ''
        Expect = (New-Expect -WriteMarker '158.0')
    }
    @{
        Label = 'equal pin marker present'
        Pin = '158.0'
        Installed = '158.0'
        Marker = '158.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'product version matches pin'
        Pin = '158.0'
        Installed = '158.0.0.0'
        Marker = ''
        Expect = (New-Expect -WriteMarker '158.0')
    }
    @{
        Label = 'vendor newer'
        Pin = '158.0'
        Installed = '159.0'
        Marker = '158.0'
        Expect = (New-Expect -WriteMarker '159.0')
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = '158.0'
        Installed = '159.0'
        Marker = '159.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'vendor patch newer'
        Pin = '158.0'
        Installed = '158.0.1'
        Marker = '158.0'
        Expect = (New-Expect -WriteMarker '158.0.1')
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-FirefoxPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$repairMissing = Get-FirefoxPlan -Action 'Repair' -PinVersion '158.0' -InstalledVersion '' -MarkerVersion '158.0'
Assert-Plan -Plan $repairMissing -Expect (New-Expect -RunInstaller 'install') -Label 'Repair missing'

$repairEqual = Get-FirefoxPlan -Action 'Repair' -PinVersion '158.0' -InstalledVersion '158.0' -MarkerVersion '158.0'
Assert-Plan -Plan $repairEqual -Expect (New-Expect -RunInstaller 'repair') -Label 'Repair present'

$repairOlder = Get-FirefoxPlan -Action 'Repair' -PinVersion '158.0' -InstalledVersion '157.0' -MarkerVersion '157.0'
Assert-Plan -Plan $repairOlder -Expect (New-Expect -RunInstaller 'repair') -Label 'Repair older'

$repairNewer = Get-FirefoxPlan -Action 'Repair' -PinVersion '158.0' -InstalledVersion '159.0' -MarkerVersion '158.0'
Assert-Plan -Plan $repairNewer -Expect (New-Expect -WriteMarker '159.0') -Label 'Repair vendor newer'

$uninstallInstalled = Get-FirefoxPlan -Action 'Uninstall' -PinVersion '158.0' -InstalledVersion '159.0' -MarkerVersion '159.0'
Assert-Plan -Plan $uninstallInstalled -Expect (New-Expect -RunInstaller 'uninstall' -ClearMarker $true) -Label 'Uninstall installed'

$uninstallMarker = Get-FirefoxPlan -Action 'Uninstall' -PinVersion '158.0' -InstalledVersion '' -MarkerVersion '158.0'
Assert-Plan -Plan $uninstallMarker -Expect (New-Expect -ClearMarker $true) -Label 'Uninstall marker only'

$uninstallNothing = Get-FirefoxPlan -Action 'Uninstall' -PinVersion '158.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $uninstallNothing -Expect (New-Expect -ExitCode 0) -Label 'Uninstall nothing'

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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$good = $utf8.GetBytes('firefox-plan')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:InstallerModes = [System.Collections.Generic.List[string]]::new()
$script:InstalledNow = ''

function Reset-Action {
    param([string]$Installed = '')
    $script:DownloadCount = 0
    $script:InstallerModes.Clear()
    $script:InstalledNow = $Installed
    $script:FirefoxErrorLog = [System.Collections.Generic.List[string]]::new()
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $root -Force | Remove-Item -Recurse -Force
    $script:GetInstalledVersion = { return [string]$script:InstalledNow }
    $script:GetUninstallTarget = { return 'helper.exe' }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $script:RetryDelay = {
        param($Seconds)
        Fail "plan test slept $Seconds"
    }
    $script:StartInstaller = {
        param($Mode, $TargetPath)
        $script:InstallerModes.Add([string]$Mode)
        return 0
    }
}

function Read-Marker {
    $path = Join-Path $root 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Invoke-Action {
    param(
        [string]$ActionName,
        [string]$Pin,
        [string]$Installed
    )
    Reset-Action -Installed $Installed
    return [int](Invoke-FirefoxAction -Action $ActionName -PinVersion $Pin -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
}

Reset-Action -Installed '159.0'
[System.IO.File]::WriteAllText((Join-Path $root 'marker.txt'), '159.0')
$emptyCode = [int](Invoke-FirefoxAction -Action 'Install' -PinVersion '' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
$emptyKept = [int](Invoke-FirefoxAction -Action 'Uninstall' -PinVersion '   ' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($emptyCode -ne 0 -or $emptyKept -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0 -or (Read-Marker) -ne '159.0') {
    Fail "empty pin returned $emptyCode/$emptyKept marker $(Read-Marker) downloads $($script:DownloadCount)"
}

Reset-Action -Installed '158.0'
[System.IO.File]::WriteAllText((Join-Path $root 'marker.txt'), '158.0')
$reinstallCode = [int](Invoke-FirefoxAction -Action 'Reinstall' -PinVersion '158.0' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($reinstallCode -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0 -or (Read-Marker) -ne '158.0') {
    Fail "Reinstall returned $reinstallCode marker $(Read-Marker)"
}

Reset-Action -Installed '159.0'
[System.IO.File]::WriteAllText((Join-Path $root 'marker.txt'), '158.0')
$newerCode = [int](Invoke-FirefoxAction -Action 'Install' -PinVersion '158.0' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($newerCode -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0 -or (Read-Marker) -ne '159.0') {
    Fail "vendor newer returned $newerCode marker $(Read-Marker) downloads $($script:DownloadCount)"
}
$updateNewer = [int](Invoke-FirefoxAction -Action 'Update' -PinVersion '158.0' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($updateNewer -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0 -or (Read-Marker) -ne '159.0') {
    Fail "update vendor newer returned $updateNewer marker $(Read-Marker)"
}

$repairMissingCode = Invoke-Action -ActionName 'Repair' -Pin '158.0' -Installed ''
if ($repairMissingCode -ne 0 -or $script:DownloadCount -ne 1 -or $script:InstallerModes.Count -ne 1 -or $script:InstallerModes[0] -cne 'install' -or (Read-Marker) -ne '158.0') {
    Fail "repair missing returned $repairMissingCode mode $($script:InstallerModes -join ',') marker $(Read-Marker)"
}

$repairPresentCode = Invoke-Action -ActionName 'Repair' -Pin '158.0' -Installed '157.0'
if ($repairPresentCode -ne 0 -or $script:InstallerModes.Count -ne 1 -or $script:InstallerModes[0] -cne 'repair') {
    Fail "repair present returned $repairPresentCode mode $($script:InstallerModes -join ',')"
}

Reset-Action -Installed '159.0'
[System.IO.File]::WriteAllText((Join-Path $root 'marker.txt'), '159.0')
$uninstallCode = [int](Invoke-FirefoxAction -Action 'Uninstall' -PinVersion '158.0' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($uninstallCode -ne 0 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 1 -or $script:InstallerModes[0] -cne 'uninstall' -or (Read-Marker) -ne '') {
    Fail "uninstall returned $uninstallCode marker $(Read-Marker) mode $($script:InstallerModes -join ',')"
}

Reset-Action -Installed '158.0'
[System.IO.File]::WriteAllText((Join-Path $root 'marker.txt'), '158.0')
$script:StartInstaller = {
    param($Mode, $TargetPath)
    $script:InstallerModes.Add([string]$Mode)
    return 1
}
$failedUninstall = [int](Invoke-FirefoxAction -Action 'Uninstall' -PinVersion '158.0' -InstallerUrl 'https://example.invalid/firefox.msi' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root)
if ($failedUninstall -ne 1 -or (Read-Marker) -ne '158.0') {
    Fail "failed uninstall returned $failedUninstall marker $(Read-Marker)"
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'firefox-plan tests passed'
exit 0
