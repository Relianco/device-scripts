$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/thin-manager/Invoke-ThinManager.ps1'
$releasePath = Join-Path $repoRoot 'releases/thin-manager.json'

function Fail {
    param([string]$Message = 'assertion failed')
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-ThinManager.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/thin-manager.json does not exist'
}

$source = [System.IO.File]::ReadAllText($scriptPath)
if ($source -match '\[Parameter\(Mandatory' -or $source -match 'Mandatory\s*=\s*\$true') {
    Fail 'a parameter is Mandatory'
}
foreach ($banned in @(
        'Ninja-Property-',
        'relian_git_deploy_token',
        'schtasks',
        'LogonTask',
        '/home/',
        'C:\Users\'
    )) {
    if ($source.Contains($banned)) {
        Fail "source contains $banned"
    }
}
if ($source -match 'sha256' -or $source -match '[0-9a-fA-F]{64}') {
    Fail 'source invents an installer hash'
}

$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
$guardAt = $source.IndexOf($guardNeedle, [System.StringComparison]::Ordinal)
$planAt = $source.IndexOf('function Get-ThinManagerPlan', [System.StringComparison]::Ordinal)
$missingAt = $source.IndexOf('missing parameter', [System.StringComparison]::Ordinal)
if ($planAt -lt 0 -or $guardAt -lt 0 -or $missingAt -lt 0 -or $planAt -gt $guardAt -or $guardAt -gt $missingAt) {
    Fail 'dot-source guard is not after the functions and before the parameter check'
}
foreach ($needle in @(
        'RelianThinManager.lnk',
        'C:\Relian\shell.ps1',
        '-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File',
        'Relian Thin Manager',
        'WScript.Shell',
        'PSBoundParameters.ContainsKey'
    )) {
    if (-not $source.Contains($needle)) {
        Fail "source missing $needle"
    }
}

$releaseRaw = [System.IO.File]::ReadAllText($releasePath)
if ($releaseRaw -match 'sha256' -or $releaseRaw -match '[0-9a-fA-F]{64}') {
    Fail 'release json invents a hash'
}
if ($releaseRaw -notmatch 'no installer file') {
    Fail 'release json does not say there is no installer file'
}
$release = $releaseRaw | ConvertFrom-Json
$releaseNames = @($release.PSObject.Properties.Name)
if ($releaseNames -contains 'sha256') {
    Fail 'release json has a sha256 field'
}
if ($null -ne $release.installerFile) {
    Fail 'release json names an installer file'
}
if ([string]$release.startupShortcut -cne 'RelianThinManager.lnk') {
    Fail 'release shortcut name'
}
if ([string]$release.name -cne 'Thin Manager startup') {
    Fail 'release name'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-ThinManagerPlan',
        'Invoke-ThinManagerAction',
        'Get-ThinManagerShortcutSpec',
        'Remove-ThinManagerStartupShortcut',
        'Set-ThinManagerShellLink'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    foreach ($name in @('ExitCode', 'RunShortcut', 'WriteMarker', 'ClearMarker')) {
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
    foreach ($name in @('RunShortcut', 'WriteMarker')) {
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
        [string]$RunShortcut = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return @{
        ExitCode    = $ExitCode
        RunShortcut = $RunShortcut
        WriteMarker = $WriteMarker
        ClearMarker = $ClearMarker
    }
}

$savedSystemRoot = $env:SystemRoot
$savedProgramData = $env:ProgramData
$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-manager-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

function Assert-PlanRow {
    param(
        [string]$Label,
        [string]$ActionName,
        [string]$Pin,
        [string]$Installed,
        [string]$Marker,
        [bool]$Present,
        [hashtable]$Expect
    )
    $plan = Get-ThinManagerPlan -Action $ActionName -PinVersion $Pin -InstalledVersion $Installed -MarkerVersion $Marker -ShortcutPresent $Present
    Assert-Plan -Plan $plan -Expect $Expect -Label $Label
}

try {
    $env:SystemRoot = 'C:\Windows'
    $env:ProgramData = 'C:\ProgramData'

    $startupDefault = Get-ThinManagerDefaultStartupFolder
    if ($startupDefault -cne 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp') {
        Fail "startup folder '$startupDefault'"
    }
    $markerDefault = Get-ThinManagerDefaultMarkerRoot
    if ($markerDefault -cne 'C:\ProgramData\Relian\thin-manager') {
        Fail "marker root '$markerDefault'"
    }

    $spec = Get-ThinManagerShortcutSpec
    $wantTarget = 'C:\Windows\system32\WindowsPowerShell\v1.0\powershell.exe'
    $wantArguments = '-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "C:\Relian\shell.ps1"'
    if ([string]$spec.TargetPath -cne $wantTarget) {
        Fail "target '$($spec.TargetPath)'"
    }
    if ([string]$spec.Arguments -cne $wantArguments) {
        Fail "arguments '$($spec.Arguments)'"
    }
    if ([string]$spec.Description -cne 'Relian Thin Manager') {
        Fail "description '$($spec.Description)'"
    }
    if ([string]$spec.IconLocation -cne $wantTarget) {
        Fail "icon '$($spec.IconLocation)'"
    }

    $link = [pscustomobject]@{
        TargetPath   = ''
        Arguments    = ''
        Description  = ''
        IconLocation = ''
    }
    Set-ThinManagerShellLink -Link $link -Spec $spec
    if ([string]$link.TargetPath -cne $wantTarget -or [string]$link.Arguments -cne $wantArguments -or
        [string]$link.Description -cne 'Relian Thin Manager' -or [string]$link.IconLocation -cne $wantTarget) {
        Fail 'shell link properties were not assigned'
    }
    $withIndex = [pscustomobject]@{
        TargetPath   = $wantTarget
        Arguments    = $wantArguments
        Description  = 'Relian Thin Manager'
        IconLocation = ($wantTarget + ',0')
    }
    if (-not (Test-ThinManagerShortcutMatches -Shortcut $withIndex -Spec $spec)) {
        Fail 'icon index was treated as a different shortcut'
    }

    foreach ($actionName in @('Install', 'Update', 'Repair', 'Uninstall', 'Reinstall')) {
        Assert-PlanRow -Label "$actionName empty pin" -ActionName $actionName -Pin '' -Installed '9.0.0.0' -Marker '9.0.0.0' -Present $true -Expect (New-Expect -ExitCode 0)
        Assert-PlanRow -Label "$actionName whitespace pin" -ActionName $actionName -Pin '   ' -Installed '1.0.0.0' -Marker '1.0.0.0' -Present $true -Expect (New-Expect -ExitCode 0)
    }
    Assert-PlanRow -Label 'invalid pin' -ActionName 'Install' -Pin 'nope' -Installed '' -Marker '' -Present $false -Expect (New-Expect -ExitCode 1)
    Assert-PlanRow -Label 'Reinstall' -ActionName 'Reinstall' -Pin '2.0.0.0' -Installed '2.0.0.0' -Marker '2.0.0.0' -Present $true -Expect (New-Expect -ExitCode 1)
    Assert-PlanRow -Label 'unknown action' -ActionName 'Nope' -Pin '2.0.0.0' -Installed '' -Marker '' -Present $false -Expect (New-Expect -ExitCode 1)

    foreach ($actionName in @('Install', 'Update')) {
        Assert-PlanRow -Label "$actionName missing" -ActionName $actionName -Pin '2.0.0.0' -Installed '' -Marker '' -Present $false -Expect (New-Expect -RunShortcut 'install' -WriteMarker '2.0.0.0')
        Assert-PlanRow -Label "$actionName equal" -ActionName $actionName -Pin '2.0.0.0' -Installed '2.0.0.0' -Marker '2.0.0.0' -Present $true -Expect (New-Expect -ExitCode 0)
        Assert-PlanRow -Label "$actionName older" -ActionName $actionName -Pin '2.0.0.0' -Installed '1.0.0.0' -Marker '1.0.0.0' -Present $true -Expect (New-Expect -RunShortcut 'install' -WriteMarker '2.0.0.0')
        Assert-PlanRow -Label "$actionName newer" -ActionName $actionName -Pin '2.0.0.0' -Installed '3.0.0.0' -Marker '3.0.0.0' -Present $true -Expect (New-Expect -ExitCode 0)
        Assert-PlanRow -Label "$actionName short pin" -ActionName $actionName -Pin '2.0' -Installed '' -Marker '' -Present $false -Expect (New-Expect -RunShortcut 'install' -WriteMarker '2.0.0.0')
        Assert-PlanRow -Label "$actionName bad marker" -ActionName $actionName -Pin '2.0.0.0' -Installed '' -Marker 'nope' -Present $false -Expect (New-Expect -ExitCode 1)
    }
    Assert-PlanRow -Label 'Repair missing' -ActionName 'Repair' -Pin '2.0.0.0' -Installed '' -Marker '' -Present $false -Expect (New-Expect -RunShortcut 'install' -WriteMarker '2.0.0.0')
    Assert-PlanRow -Label 'Repair equal' -ActionName 'Repair' -Pin '2.0.0.0' -Installed '2.0.0.0' -Marker '2.0.0.0' -Present $true -Expect (New-Expect -RunShortcut 'install' -WriteMarker '2.0.0.0')
    Assert-PlanRow -Label 'Repair newer' -ActionName 'Repair' -Pin '2.0.0.0' -Installed '3.0.0.0' -Marker '3.0.0.0' -Present $true -Expect (New-Expect -ExitCode 0)
    Assert-PlanRow -Label 'Uninstall shortcut' -ActionName 'Uninstall' -Pin '2.0.0.0' -Installed 'nope' -Marker 'old' -Present $true -Expect (New-Expect -RunShortcut 'remove' -ClearMarker $true)
    Assert-PlanRow -Label 'Uninstall marker only' -ActionName 'Uninstall' -Pin '2.0.0.0' -Installed '' -Marker '2.0.0.0' -Present $false -Expect (New-Expect -ClearMarker $true)
    Assert-PlanRow -Label 'Uninstall nothing' -ActionName 'Uninstall' -Pin '2.0.0.0' -Installed '' -Marker '' -Present $false -Expect (New-Expect -ExitCode 0)

    $script:Startup = Join-Path $script:Root 'startup'
    $script:Marker = Join-Path $script:Root 'marker'
    $script:Writes = 0
    $script:LastPath = ''
    New-Item -ItemType Directory -Path $script:Startup -Force | Out-Null
    New-Item -ItemType Directory -Path $script:Marker -Force | Out-Null

    function Reset-ThinManagerHooks {
        $script:ThinManagerErrorLog = [System.Collections.Generic.List[string]]::new()
        $script:ReadThinManagerShortcut = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                return $null
            }
            $parsed = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
            return [pscustomobject]@{
                TargetPath   = [string]$parsed.targetPath
                Arguments    = [string]$parsed.arguments
                Description  = [string]$parsed.description
                IconLocation = [string]$parsed.iconLocation
            }
        }
        $script:WriteThinManagerShortcut = {
            param($Path, $Spec)
            if (-not $Path.StartsWith($script:Root, [System.StringComparison]::Ordinal)) {
                throw 'refusing to write outside the test root'
            }
            $script:Writes++
            $script:LastPath = [string]$Path
            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $payload = [ordered]@{
                targetPath   = [string]$Spec.TargetPath
                arguments    = [string]$Spec.Arguments
                description  = [string]$Spec.Description
                iconLocation = [string]$Spec.IconLocation
            }
            $json = ConvertTo-Json -InputObject $payload -Compress
            [System.IO.File]::WriteAllText($Path, $json)
        }
        $script:RemoveThinManagerShortcut = {
            param($Path)
            if (-not $Path.StartsWith($script:Root, [System.StringComparison]::Ordinal)) {
                throw 'refusing to remove outside the test root'
            }
            Remove-ThinManagerStartupShortcut -Path $Path
        }
    }

    function Clear-ThinManagerCase {
        Reset-ThinManagerHooks
        $script:Writes = 0
        $script:LastPath = ''
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:Startup -Force | Remove-Item -Force
        Get-ChildItem -LiteralPath $script:Marker -Force | Remove-Item -Force
    }

    function Invoke-Case {
        param(
            [string]$ActionName,
            [string]$PinVersion,
            [string]$CancelPath = ''
        )
        if ([string]::IsNullOrWhiteSpace($script:Startup) -or [string]::IsNullOrWhiteSpace($script:Marker)) {
            Fail 'test folders are empty'
        }
        return [int](Invoke-ThinManagerAction -DeploymentType $ActionName -Action $ActionName -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $script:Marker -StartupFolder $script:Startup)
    }

    function Read-CaseShortcut {
        $path = Join-Path $script:Startup 'RelianThinManager.lnk'
        if (-not (Test-Path -LiteralPath $path)) {
            return $null
        }
        return (& $script:ReadThinManagerShortcut $path)
    }

    function Read-CaseMarker {
        $path = Join-Path $script:Marker 'marker.txt'
        if (-not (Test-Path -LiteralPath $path)) {
            return $null
        }
        return [System.IO.File]::ReadAllText($path)
    }

    Clear-ThinManagerCase
    $code = Invoke-Case -ActionName 'Install' -PinVersion ''
    if ($code -ne 0 -or $script:Writes -ne 0 -or $null -ne (Read-CaseMarker) -or $null -ne (Read-CaseShortcut)) {
        Fail "empty pin changed the machine exit $code writes $($script:Writes)"
    }

    Clear-ThinManagerCase
    $code = Invoke-Case -ActionName 'Install' -PinVersion '   '
    if ($code -ne 0 -or $script:Writes -ne 0) {
        Fail 'whitespace pin did work'
    }

    Clear-ThinManagerCase
    [System.IO.File]::WriteAllText((Join-Path $script:Marker 'marker.txt'), '9.0.0.0')
    $code = Invoke-Case -ActionName 'Reinstall' -PinVersion '2.0.0.0'
    if ($code -ne 1 -or $script:Writes -ne 0 -or (Read-CaseMarker) -ne '9.0.0.0') {
        Fail "Reinstall changed state exit $code marker [$(Read-CaseMarker)]"
    }

    Clear-ThinManagerCase
    $code = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    $written = Read-CaseShortcut
    if ($code -ne 0 -or $script:Writes -ne 1 -or $null -eq $written) {
        Fail "install exit $code writes $($script:Writes)"
    }
    if ([string]$written.Arguments -cne $wantArguments -or [string]$written.TargetPath -cne $wantTarget -or
        [string]$written.Description -cne 'Relian Thin Manager' -or [string]$written.IconLocation -cne $wantTarget) {
        Fail 'install wrote the wrong shortcut'
    }
    if ((Read-CaseMarker) -cne '2.0.0.0') {
        Fail "install marker [$(Read-CaseMarker)]"
    }
    if (-not $script:LastPath.EndsWith((Join-Path 'startup' 'RelianThinManager.lnk'), [System.StringComparison]::Ordinal)) {
        Fail "install path $($script:LastPath)"
    }
    $again = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    if ($again -ne 0 -or $script:Writes -ne 1) {
        Fail "second install wrote again exit $again writes $($script:Writes)"
    }

    $updated = Invoke-Case -ActionName 'Update' -PinVersion '3.0.0.0'
    if ($updated -ne 0 -or $script:Writes -ne 2 -or (Read-CaseMarker) -cne '3.0.0.0') {
        Fail "update exit $updated writes $($script:Writes) marker [$(Read-CaseMarker)]"
    }
    $kept = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    if ($kept -ne 0 -or $script:Writes -ne 2 -or (Read-CaseMarker) -cne '3.0.0.0') {
        Fail 'lower pin rewrote a newer marker'
    }
    $repairedNewer = Invoke-Case -ActionName 'Repair' -PinVersion '2.0.0.0'
    if ($repairedNewer -ne 0 -or $script:Writes -ne 2) {
        Fail 'Repair rewrote a newer shortcut'
    }

    Clear-ThinManagerCase
    $code = Invoke-Case -ActionName 'Install' -PinVersion '1.0.0.0'
    $repaired = Invoke-Case -ActionName 'Repair' -PinVersion '1.0.0.0'
    if ($code -ne 0 -or $repaired -ne 0 -or $script:Writes -ne 2 -or (Read-CaseMarker) -cne '1.0.0.0') {
        Fail "Repair equal exit $repaired writes $($script:Writes)"
    }

    Clear-ThinManagerCase
    $badPayload = [ordered]@{
        targetPath   = 'C:\Windows\notepad.exe'
        arguments    = 'other'
        description  = 'Other'
        iconLocation = 'C:\Windows\notepad.exe'
    }
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'RelianThinManager.lnk'), (ConvertTo-Json -InputObject $badPayload -Compress))
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'KeepMe.lnk'), 'keep')
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'shell.ps1'), 'do not delete')
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'Relian Thin Manager.lnk'), 'other shortcut')
    [System.IO.File]::WriteAllText((Join-Path $script:Marker 'keep.txt'), 'keep-marker')
    $fixed = Invoke-Case -ActionName 'Install' -PinVersion '2.0'
    $fixedShortcut = Read-CaseShortcut
    if ($fixed -ne 0 -or [string]$fixedShortcut.Arguments -cne $wantArguments -or (Read-CaseMarker) -cne '2.0.0.0') {
        Fail 'install did not replace a mismatched shortcut'
    }
    foreach ($keptName in @('KeepMe.lnk', 'shell.ps1', 'Relian Thin Manager.lnk')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Startup $keptName))) {
            Fail "install removed $keptName"
        }
    }

    $removed = Invoke-Case -ActionName 'Uninstall' -PinVersion '2.0.0.0'
    if ($removed -ne 0) {
        Fail "uninstall exit $removed"
    }
    if (Test-Path -LiteralPath (Join-Path $script:Startup 'RelianThinManager.lnk')) {
        Fail 'uninstall left the startup shortcut'
    }
    if (Test-Path -LiteralPath (Join-Path $script:Marker 'marker.txt')) {
        Fail 'uninstall left the marker'
    }
    foreach ($keptName in @('KeepMe.lnk', 'shell.ps1', 'Relian Thin Manager.lnk')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Startup $keptName))) {
            Fail "uninstall removed $keptName"
        }
    }
    if (([System.IO.File]::ReadAllText((Join-Path $script:Marker 'keep.txt'))) -cne 'keep-marker') {
        Fail 'uninstall removed a marker sibling'
    }
    if (-not (Test-Path -LiteralPath $script:Startup)) {
        Fail 'uninstall removed the startup directory'
    }
    $removedAgain = Invoke-Case -ActionName 'Uninstall' -PinVersion '2.0.0.0'
    if ($removedAgain -ne 0) {
        Fail "second uninstall exit $removedAgain"
    }

    Clear-ThinManagerCase
    [System.IO.File]::WriteAllText((Join-Path $script:Marker 'marker.txt'), 'nope')
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'RelianThinManager.lnk'), 'not-json-but-present')
    $script:ReadThinManagerShortcut = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }
        return [pscustomobject]@{
            TargetPath   = 'C:\Windows\notepad.exe'
            Arguments    = 'other'
            Description  = 'Other'
            IconLocation = 'C:\Windows\notepad.exe'
        }
    }
    $code = Invoke-Case -ActionName 'Uninstall' -PinVersion '2.0.0.0'
    if ($code -ne 0 -or (Test-Path -LiteralPath (Join-Path $script:Startup 'RelianThinManager.lnk')) -or (Test-Path -LiteralPath (Join-Path $script:Marker 'marker.txt'))) {
        Fail 'uninstall did not remove a mismatched shortcut and a bad marker'
    }

    Clear-ThinManagerCase
    [System.IO.File]::WriteAllText((Join-Path $script:Marker 'marker.txt'), 'nope')
    $blocked = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    if ($blocked -ne 1 -or $script:Writes -ne 0 -or (Read-CaseMarker) -ne 'nope') {
        Fail 'invalid marker was overwritten'
    }

    Clear-ThinManagerCase
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $cancelled = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    if ($cancelled -ne 130 -or $script:Writes -ne 0 -or $null -ne (Read-CaseShortcut)) {
        Fail "cancel env exit $cancelled writes $($script:Writes)"
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue

    Clear-ThinManagerCase
    $cancelFlag = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancelFlag -Force | Out-Null
    $cancelled = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0' -CancelPath $cancelFlag
    if ($cancelled -ne 130 -or $null -ne (Read-CaseShortcut)) {
        Fail 'cancel path did not stop the shortcut'
    }
    $missingCancel = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0' -CancelPath (Join-Path $script:Root 'missing-cancel')
    if ($missingCancel -ne 0 -or $null -eq (Read-CaseShortcut)) {
        Fail 'missing cancel path blocked install'
    }

    Clear-ThinManagerCase
    $code = Invoke-Case -ActionName 'Install' -PinVersion '4.0.0.0'
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $noop = Invoke-Case -ActionName 'Install' -PinVersion '4.0.0.0'
    if ($code -ne 0 -or $noop -ne 0 -or (Read-CaseMarker) -cne '4.0.0.0') {
        Fail 'cancel changed an already matching shortcut'
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $cancelledRemove = Invoke-Case -ActionName 'Uninstall' -PinVersion '4.0.0.0'
    if ($cancelledRemove -ne 0 -or $null -ne (Read-CaseShortcut)) {
        Fail 'uninstall after a cleared cancel left the shortcut or failed'
    }

    Clear-ThinManagerCase
    $env:RELIAN_DEPLOY_CANCEL = '1'
    [System.IO.File]::WriteAllText((Join-Path $script:Marker 'marker.txt'), '4.0.0.0')
    $payload = [ordered]@{
        targetPath   = $wantTarget
        arguments    = $wantArguments
        description  = 'Relian Thin Manager'
        iconLocation = $wantTarget
    }
    [System.IO.File]::WriteAllText((Join-Path $script:Startup 'RelianThinManager.lnk'), (ConvertTo-Json -InputObject $payload -Compress))
    $held = Invoke-Case -ActionName 'Uninstall' -PinVersion '4.0.0.0'
    if ($held -ne 130 -or -not (Test-Path -LiteralPath (Join-Path $script:Startup 'RelianThinManager.lnk')) -or (Read-CaseMarker) -cne '4.0.0.0') {
        Fail 'cancel during uninstall removed the shortcut'
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue

    Clear-ThinManagerCase
    $script:WriteThinManagerShortcut = {
        param($Path, $Spec)
        throw 'disk full'
    }
    $failed = Invoke-Case -ActionName 'Install' -PinVersion '2.0.0.0'
    if ($failed -ne 1 -or $null -ne (Read-CaseMarker)) {
        Fail 'failed create wrote a marker'
    }
    if (($script:ThinManagerErrorLog -join "`n") -like '*https://*') {
        Fail 'error included a URL'
    }

    $directory = Join-Path $script:Root 'a-directory'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $threw = $false
    try {
        Remove-ThinManagerStartupShortcut -Path $directory
    } catch {
        $threw = $true
    }
    if (-not $threw -or -not (Test-Path -LiteralPath $directory)) {
        Fail 'directory remove was allowed'
    }

    function Invoke-PackageProcess {
        param(
            [string[]]$Arguments
        )
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $repoRoot
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-NonInteractive')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($scriptPath)
        foreach ($argument in $Arguments) {
            $psi.ArgumentList.Add($argument)
        }
        if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_TEST')) {
            [void]$psi.Environment.Remove('RELIAN_DEPLOY_TEST')
        }
        if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_CANCEL')) {
            [void]$psi.Environment.Remove('RELIAN_DEPLOY_CANCEL')
        }
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(20000)) {
                try {
                    $proc.Kill($true)
                } catch {
                    $proc.Kill()
                }
                Fail 'package process timed out'
            }
            [void]$proc.WaitForExit()
            return [pscustomobject]@{
                ExitCode = [int]$proc.ExitCode
                Stdout   = [string]$stdoutTask.Result
                Stderr   = [string]$stderrTask.Result
            }
        } finally {
            $proc.Dispose()
        }
    }

    $processStartup = Join-Path $script:Root 'process-startup'
    $processMarker = Join-Path $script:Root 'process-marker'
    $missing = Invoke-PackageProcess -Arguments @(
        '-DeploymentType', 'Install',
        '-Action', 'Install',
        '-StartupFolder', $processStartup,
        '-MarkerRoot', $processMarker
    )
    if ($missing.ExitCode -eq 0 -or $missing.Stderr -notlike '*missing parameter PinVersion*') {
        Fail "missing pin exit $($missing.ExitCode) stderr [$($missing.Stderr)]"
    }
    if (Test-Path -LiteralPath (Join-Path $processStartup 'RelianThinManager.lnk')) {
        Fail 'missing pin created a shortcut'
    }

    $disabled = Invoke-PackageProcess -Arguments @(
        '-DeploymentType', 'Install',
        '-Action', 'Install',
        '-PinVersion', '   ',
        '-StartupFolder', $processStartup,
        '-MarkerRoot', $processMarker
    )
    if ($disabled.ExitCode -ne 0) {
        Fail "whitespace pin process exit $($disabled.ExitCode) stderr [$($disabled.Stderr)]"
    }
    if (Test-Path -LiteralPath (Join-Path $processStartup 'RelianThinManager.lnk')) {
        Fail 'whitespace pin process created a shortcut'
    }

    $refused = Invoke-PackageProcess -Arguments @(
        '-DeploymentType', 'Install',
        '-Action', 'Reinstall',
        '-PinVersion', '1.0.0.0',
        '-StartupFolder', $processStartup,
        '-MarkerRoot', $processMarker
    )
    if ($refused.ExitCode -ne 1) {
        Fail "Reinstall process exit $($refused.ExitCode) stderr [$($refused.Stderr)]"
    }
    if (Test-Path -LiteralPath (Join-Path $processStartup 'RelianThinManager.lnk')) {
        Fail 'Reinstall process created a shortcut'
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if ($null -eq $savedSystemRoot) {
        Remove-Item -LiteralPath 'Env:SystemRoot' -ErrorAction SilentlyContinue
    } else {
        $env:SystemRoot = $savedSystemRoot
    }
    if ($null -eq $savedProgramData) {
        Remove-Item -LiteralPath 'Env:ProgramData' -ErrorAction SilentlyContinue
    } else {
        $env:ProgramData = $savedProgramData
    }
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'thin-manager tests passed'
exit 0
