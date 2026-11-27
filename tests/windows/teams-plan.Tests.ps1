$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/teams/Invoke-Teams.ps1'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Teams.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-TeamsPlan -ErrorAction SilentlyContinue)) {
    Fail 'Get-TeamsPlan was not defined'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    $names = @('ExitCode', 'RunBootstrapper', 'RemoveClassic', 'Reregister', 'WriteMarker', 'Log')
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
    foreach ($name in @('RunBootstrapper', 'WriteMarker', 'Log')) {
        $actual = [string]$Plan.$name
        $want = [string]$Expect[$name]
        if ($actual -cne $want) {
            Fail "$Label $name '$actual' expected '$want'"
        }
    }
    foreach ($name in @('RemoveClassic', 'Reregister')) {
        if ([bool]$Plan.$name -ne [bool]$Expect[$name]) {
            Fail "$Label $name '$($Plan.$name)' expected '$($Expect[$name])'"
        }
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunBootstrapper = '',
        [bool]$RemoveClassic = $false,
        [bool]$Reregister = $false,
        [string]$WriteMarker = '',
        [string]$Log = ''
    )
    return @{
        ExitCode        = $ExitCode
        RunBootstrapper = $RunBootstrapper
        RemoveClassic   = $RemoveClassic
        Reregister      = $Reregister
        WriteMarker     = $WriteMarker
        Log             = $Log
    }
}

$none = New-Expect
$installRows = @(
    @{
        Label = 'Install empty pin'
        Pin = ''
        Installed = '9.0.0.0'
        Marker = '9.0.0.0'
        Classic = $true
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'Install unparseable pin'
        Pin = 'nope'
        Installed = ''
        Marker = ''
        Classic = $false
        Expect = (New-Expect -ExitCode 1)
    }
    @{
        Label = 'Install missing app with classic'
        Pin = '2.0.0.0'
        Installed = ''
        Marker = ''
        Classic = $true
        Expect = (New-Expect -RunBootstrapper 'install')
    }
    @{
        Label = 'Install equal pin missing marker'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = ''
        Classic = $false
        Expect = (New-Expect -WriteMarker '2.0.0.0')
    }
    @{
        Label = 'Install vendor newer than pin'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '2.0.0.0'
        Classic = $false
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
    @{
        Label = 'Install older than pin'
        Pin = '2.0.0.0'
        Installed = '1.0.0.0'
        Marker = '1.0.0.0'
        Classic = $false
        Expect = (New-Expect -RunBootstrapper 'install')
    }
    @{
        Label = 'Install equal pin missing marker with classic'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = ''
        Classic = $true
        Expect = (New-Expect -RemoveClassic $true -WriteMarker '2.0.0.0')
    }
    @{
        Label = 'Install equal pin with classic'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = '2.0.0.0'
        Classic = $true
        Expect = (New-Expect -RemoveClassic $true)
    }
    @{
        Label = 'Install vendor newer with classic'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '2.0.0.0'
        Classic = $true
        Expect = (New-Expect -RemoveClassic $true -WriteMarker '3.0.0.0')
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-TeamsPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker -ClassicPresent $row.Classic
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-TeamsPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '' -ClassicPresent $true
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-TeamsPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0' -ClassicPresent $false
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '2.0.0.0'; Installed = ''; Marker = '2.0.0.0'; Classic = $false
        Expect = (New-Expect -ExitCode 1)
    }
    @{
        Label = 'Repair equal with classic'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'; Classic = $true
        Expect = (New-Expect -RemoveClassic $true -Reregister $true -Log 'Repair')
    }
    @{
        Label = 'Repair equal without classic'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'; Classic = $false
        Expect = (New-Expect -Reregister $true -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '2.0.0.0'; Installed = '3.0.0.0'; Marker = '2.0.0.0'; Classic = $false
        Expect = (New-Expect -Reregister $true -WriteMarker '3.0.0.0' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '2.0.0.0'; Installed = '1.0.0.0'; Marker = '1.0.0.0'; Classic = $false
        Expect = (New-Expect -Reregister $true -Log 'Repair')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-TeamsPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker -ClassicPresent $row.Classic
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall app and classic'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'; Classic = $true
        Expect = (New-Expect -RunBootstrapper 'uninstall' -RemoveClassic $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '2.0.0.0'; Installed = ''; Marker = '2.0.0.0'; Classic = $false
        Expect = (New-Expect -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''; Classic = $false
        Expect = (New-Expect -ExitCode 0)
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-TeamsPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker -ClassicPresent $row.Classic
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

Write-Output 'teams-plan tests passed'
exit 0
