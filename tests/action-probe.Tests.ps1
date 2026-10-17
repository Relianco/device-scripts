$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $repoRoot 'packages/action-probe/Invoke-ActionProbe.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:roots = [System.Collections.Generic.List[string]]::new()

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-WorkRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-probe-' + [guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Path $path)
    [void]$script:roots.Add($path)
    return $path
}

function Write-Exact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-Exact {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $snap = @{}
    foreach ($name in @('marker.txt', 'sentinel.txt', 'toolkit.log')) {
        $snap[$name] = Read-Exact -Path (Join-Path $Root $name)
    }
    return $snap
}

function Assert-Snapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][string]$Label
    )
    $after = Get-TreeSnapshot -Root $Root
    foreach ($name in @($Before.Keys)) {
        if ($Before[$name] -cne $after[$name]) {
            Fail "$Label changed $name from [$($Before[$name])] to [$($after[$name])]"
        }
    }
}

function Assert-Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = Read-Exact -Path $Path
    if ($actual -cne $Expected) {
        Fail "$Label was [$actual] expected [$Expected]"
    }
}

function Assert-Absent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if (Test-Path -LiteralPath $Path) {
        Fail "$Label exists at $Path"
    }
}

function Invoke-Action {
    param(
        [Parameter(Mandatory)][string]$ActionName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pin,
        [Parameter(Mandatory)][string]$Root
    )
    $result = @(Invoke-ProbeAction -Action $ActionName -PinVersion $Pin -MarkerRoot $Root)
    if ($result.Count -ne 1) {
        Fail "$ActionName pin $Pin emitted $($result.Count) objects"
    }
    return [int]$result[0]
}

function Invoke-ExitMap {
    param([Parameter(Mandatory)][int]$ToolkitExit)
    $result = @(Convert-ProbeExit -ToolkitExit $ToolkitExit)
    if ($result.Count -ne 1) {
        Fail "Convert-ProbeExit $ToolkitExit emitted $($result.Count) objects"
    }
    return [int]$result[0]
}

function Assert-Installed {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Pin,
        [Parameter(Mandatory)][string]$Log,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-Text -Path (Join-Path $Root 'marker.txt') -Expected ($Pin + "`n") -Label "$Label marker"
    Assert-Text -Path (Join-Path $Root 'sentinel.txt') -Expected 'ok' -Label "$Label sentinel"
    Assert-Text -Path (Join-Path $Root 'toolkit.log') -Expected $Log -Label "$Label log"
}

if (-not (Test-Path -LiteralPath $probe)) {
    Fail "missing $probe"
}

$source = [System.IO.File]::ReadAllText($probe)

function Assert-SourceHas {
    param([Parameter(Mandatory)][string]$Needle)
    if ($source.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        Fail "source missing $Needle"
    }
}

Assert-SourceHas -Needle "$([char]36)PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
Assert-SourceHas -Needle '8c3c366b-8606-4576-9f2d-4051144f7ca2'
Assert-SourceHas -Needle "ModuleVersion = '4.1.8'"
Assert-SourceHas -Needle "AppVendor = 'Relian'"
Assert-SourceHas -Needle "AppName = 'Action Probe'"
Assert-SourceHas -Needle 'AppVersion = $PinVersion'
Assert-SourceHas -Needle 'AppProcessesToClose = @()'
Assert-SourceHas -Needle 'RequireAdmin = $true'
Assert-SourceHas -Needle "DeployAppScriptVersion = '4.1.8'"
Assert-SourceHas -Needle 'Open-ADTSession'
Assert-SourceHas -Needle 'Close-ADTSession'
Assert-SourceHas -Needle '& "$($adtSession.DeploymentType)-ADTDeployment"'
Assert-SourceHas -Needle 'function Install-ADTDeployment'
Assert-SourceHas -Needle 'function Uninstall-ADTDeployment'
Assert-SourceHas -Needle 'function Repair-ADTDeployment'
Assert-SourceHas -Needle 'function Convert-ProbeExit'
Assert-SourceHas -Needle 'function Invoke-ProbeAction'

if ($source.Contains('DeferTimes')) {
    Fail 'source sets DeferTimes'
}
if ($source.Contains('Ninja-Property-') -or $source.Contains('relian_git_deploy_token')) {
    Fail 'package references Ninja or the git token'
}

$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
$guardAt = $source.IndexOf($guardNeedle, [System.StringComparison]::Ordinal)
$importAt = $source.IndexOf('Import-Module', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $importAt -lt 0 -or $guardAt -gt $importAt) {
    Fail 'module import is not behind the dot-source guard'
}

$welcome = [regex]::Matches($source, 'Show-ADTInstallationWelcome')
$guardedWelcome = [regex]::Matches(
    $source,
    'if \(\$adtSession\.AppProcessesToClose\.Count -gt 0\) \{\s*Show-ADTInstallationWelcome -CloseProcesses \$adtSession\.AppProcessesToClose'
)
if ($welcome.Count -ne 3 -or $guardedWelcome.Count -ne 3) {
    Fail "welcome calls $($welcome.Count) guarded $($guardedWelcome.Count)"
}

foreach ($name in @('Install-ADTDeployment', 'Uninstall-ADTDeployment', 'Repair-ADTDeployment')) {
    $start = $source.IndexOf("function $name", [System.StringComparison]::Ordinal)
    if ($start -lt 0) {
        Fail "missing function $name"
    }
    $next = $source.IndexOf("`nfunction ", $start + 10, [System.StringComparison]::Ordinal)
    if ($next -lt 0) {
        $next = $source.Length
    }
    $body = $source.Substring($start, $next - $start)
    if ($body.IndexOf('Invoke-ProbeAction', [System.StringComparison]::Ordinal) -lt 0) {
        Fail "$name does not call Invoke-ProbeAction"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $probe

if (-not (Get-Command Invoke-ProbeAction -ErrorAction SilentlyContinue)) {
    Fail 'dot-source did not define Invoke-ProbeAction'
}
if (-not (Get-Command Convert-ProbeExit -ErrorAction SilentlyContinue)) {
    Fail 'dot-source did not define Convert-ProbeExit'
}
if (Get-Module -Name PSAppDeployToolkit -ErrorAction SilentlyContinue) {
    Fail 'dot-source imported PSAppDeployToolkit'
}
if (Get-Command Open-ADTSession -ErrorAction SilentlyContinue) {
    Fail 'dot-source exposed Open-ADTSession'
}

$actionSet = @(
    (Get-Command Invoke-ProbeAction).Parameters['Action'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
)
if ($actionSet.Count -ne 1) {
    Fail 'Action ValidateSet missing'
}
foreach ($item in @('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')) {
    if (@($actionSet[0].ValidValues) -notcontains $item) {
        Fail "Action set missing $item"
    }
}

if ((Invoke-ExitMap -ToolkitExit 1602) -ne 1) {
    Fail 'Convert-ProbeExit 1602 did not return 1'
}
if ((Invoke-ExitMap -ToolkitExit 0) -ne 0) {
    Fail 'Convert-ProbeExit 0 did not stay 0'
}
if ((Invoke-ExitMap -ToolkitExit 1) -ne 1) {
    Fail 'Convert-ProbeExit 1 did not stay 1'
}
if ((Invoke-ExitMap -ToolkitExit 60001) -ne 60001) {
    Fail 'Convert-ProbeExit 60001 did not stay 60001'
}

try {
    $savedProgramData = $env:ProgramData
    $savedMarkerRoot = $MarkerRoot
    try {
        $env:ProgramData = Join-Path (New-WorkRoot) 'programdata'
        $MarkerRoot = ''
        $defaultRoot = Get-ProbeMarkerRoot
        $expectedRoot = Join-Path (Join-Path $env:ProgramData 'Relian') 'action-probe'
        if ($defaultRoot -cne $expectedRoot) {
            Fail "default marker root was [$defaultRoot] expected [$expectedRoot]"
        }
        $explicitRoot = Join-Path (New-WorkRoot) 'explicit'
        $MarkerRoot = $explicitRoot
        $overrideRoot = Get-ProbeMarkerRoot
        if ($overrideRoot -cne $explicitRoot) {
            Fail "explicit marker root was [$overrideRoot] expected [$explicitRoot]"
        }
    } finally {
        if ([string]::IsNullOrEmpty($savedProgramData)) {
            Remove-Item -LiteralPath 'Env:ProgramData' -ErrorAction SilentlyContinue
        } else {
            $env:ProgramData = $savedProgramData
        }
        $MarkerRoot = $savedMarkerRoot
    }

    foreach ($badPin in @('', 'not-a-version', '1.2.3.4.5', 'v1.0')) {
        $parent = New-WorkRoot
        $root = Join-Path $parent 'marker'
        $code = Invoke-Action -ActionName 'Install' -Pin $badPin -Root $root
        if ($code -ne 1) {
            Fail "bad pin [$badPin] returned $code"
        }
        Assert-Absent -Path $root -Label "bad pin [$badPin] root"
    }

    $seededParent = New-WorkRoot
    $seeded = Join-Path $seededParent 'marker'
    Write-Exact -Path (Join-Path $seeded 'marker.txt') -Text "9.9.9`n"
    Write-Exact -Path (Join-Path $seeded 'sentinel.txt') -Text 'ok'
    Write-Exact -Path (Join-Path $seeded 'toolkit.log') -Text "Install`n"
    $seededBefore = Get-TreeSnapshot -Root $seeded
    $badSeeded = Invoke-Action -ActionName 'Update' -Pin 'not-a-version' -Root $seeded
    if ($badSeeded -ne 1) {
        Fail "bad pin on existing root returned $badSeeded"
    }
    Assert-Snapshot -Root $seeded -Before $seededBefore -Label 'bad pin existing'

    foreach ($actionName in @('Install', 'Update')) {
        $parent = New-WorkRoot
        $root = Join-Path $parent 'marker'
        $code = Invoke-Action -ActionName $actionName -Pin '1.2.3' -Root $root
        if ($code -ne 0) {
            Fail "$actionName missing returned $code"
        }
        Assert-Installed -Root $root -Pin '1.2.3' -Log "Install`n" -Label "$actionName missing"

        $lowerParent = New-WorkRoot
        $lower = Join-Path $lowerParent 'marker'
        Write-Exact -Path (Join-Path $lower 'marker.txt') -Text "1.0.0`n"
        $lowerCode = Invoke-Action -ActionName $actionName -Pin '1.1.0' -Root $lower
        if ($lowerCode -ne 0) {
            Fail "$actionName lower returned $lowerCode"
        }
        Assert-Installed -Root $lower -Pin '1.1.0' -Log "Install`n" -Label "$actionName lower"

        $sameParent = New-WorkRoot
        $same = Join-Path $sameParent 'marker'
        Write-Exact -Path (Join-Path $same 'marker.txt') -Text "2.0.0`n"
        Write-Exact -Path (Join-Path $same 'sentinel.txt') -Text 'ok'
        Write-Exact -Path (Join-Path $same 'toolkit.log') -Text "Install`n"
        $sameBefore = Get-TreeSnapshot -Root $same
        $sameCode = Invoke-Action -ActionName $actionName -Pin '2.0.0' -Root $same
        if ($sameCode -ne 0) {
            Fail "$actionName same returned $sameCode"
        }
        Assert-Snapshot -Root $same -Before $sameBefore -Label "$actionName same"

        $newerParent = New-WorkRoot
        $newer = Join-Path $newerParent 'marker'
        Write-Exact -Path (Join-Path $newer 'marker.txt') -Text '9.9.9'
        Write-Exact -Path (Join-Path $newer 'sentinel.txt') -Text 'ok'
        $newerBefore = Get-TreeSnapshot -Root $newer
        $newerCode = Invoke-Action -ActionName $actionName -Pin '1.0.0' -Root $newer
        if ($newerCode -ne 0) {
            Fail "$actionName newer returned $newerCode"
        }
        Assert-Snapshot -Root $newer -Before $newerBefore -Label "$actionName newer"

        $newerBareParent = New-WorkRoot
        $newerBare = Join-Path $newerBareParent 'marker'
        Write-Exact -Path (Join-Path $newerBare 'marker.txt') -Text "9.9.9`n"
        $newerBareBefore = Get-TreeSnapshot -Root $newerBare
        $newerBareCode = Invoke-Action -ActionName $actionName -Pin '1.0.0' -Root $newerBare
        if ($newerBareCode -ne 0) {
            Fail "$actionName newer without sentinel returned $newerBareCode"
        }
        Assert-Snapshot -Root $newerBare -Before $newerBareBefore -Label "$actionName newer without sentinel"

        $gapParent = New-WorkRoot
        $gap = Join-Path $gapParent 'marker'
        Write-Exact -Path (Join-Path $gap 'marker.txt') -Text '1.2.3'
        Write-Exact -Path (Join-Path $gap 'toolkit.log') -Text "Install`n"
        $gapCode = Invoke-Action -ActionName $actionName -Pin '1.2.3' -Root $gap
        if ($gapCode -ne 0) {
            Fail "$actionName sentinel gap returned $gapCode"
        }
        Assert-Text -Path (Join-Path $gap 'marker.txt') -Expected '1.2.3' -Label "$actionName sentinel gap marker"
        Assert-Text -Path (Join-Path $gap 'sentinel.txt') -Expected 'ok' -Label "$actionName sentinel gap sentinel"
        Assert-Text -Path (Join-Path $gap 'toolkit.log') -Expected "Install`n" -Label "$actionName sentinel gap log"
    }

    $repairMissingParent = New-WorkRoot
    $repairMissing = Join-Path $repairMissingParent 'marker'
    $repairMissingCode = Invoke-Action -ActionName 'Repair' -Pin '2.0.0' -Root $repairMissing
    if ($repairMissingCode -ne 0) {
        Fail "repair missing returned $repairMissingCode"
    }
    Assert-Installed -Root $repairMissing -Pin '2.0.0' -Log "Install`n" -Label 'repair missing'

    $repairGapParent = New-WorkRoot
    $repairGap = Join-Path $repairGapParent 'marker'
    Write-Exact -Path (Join-Path $repairGap 'marker.txt') -Text '1.2.3'
    $repairGapCode = Invoke-Action -ActionName 'Repair' -Pin '1.2.3' -Root $repairGap
    if ($repairGapCode -ne 0) {
        Fail "repair gap returned $repairGapCode"
    }
    Assert-Text -Path (Join-Path $repairGap 'marker.txt') -Expected '1.2.3' -Label 'repair gap marker'
    Assert-Text -Path (Join-Path $repairGap 'sentinel.txt') -Expected 'ok' -Label 'repair gap sentinel'
    Assert-Text -Path (Join-Path $repairGap 'toolkit.log') -Expected "Repair`n" -Label 'repair gap log'

    $repairSameParent = New-WorkRoot
    $repairSame = Join-Path $repairSameParent 'marker'
    Write-Exact -Path (Join-Path $repairSame 'marker.txt') -Text "4.0.0`n"
    Write-Exact -Path (Join-Path $repairSame 'sentinel.txt') -Text 'ok'
    Write-Exact -Path (Join-Path $repairSame 'toolkit.log') -Text "Install`n"
    $repairSameBefore = Get-TreeSnapshot -Root $repairSame
    $repairSameCode = Invoke-Action -ActionName 'Repair' -Pin '4.0.0' -Root $repairSame
    if ($repairSameCode -ne 0) {
        Fail "repair same returned $repairSameCode"
    }
    Assert-Snapshot -Root $repairSame -Before $repairSameBefore -Label 'repair same'

    foreach ($pair in @(
            @{ Pin = '1.0.1'; Marker = "1.0.0`n"; Sentinel = 'ok' }
            @{ Pin = '1.0.0'; Marker = "2.0.0`n"; Sentinel = $null }
        )) {
        $diffParent = New-WorkRoot
        $diff = Join-Path $diffParent 'marker'
        Write-Exact -Path (Join-Path $diff 'marker.txt') -Text $pair.Marker
        if ($null -ne $pair.Sentinel) {
            Write-Exact -Path (Join-Path $diff 'sentinel.txt') -Text $pair.Sentinel
        }
        Write-Exact -Path (Join-Path $diff 'toolkit.log') -Text "Install`n"
        $diffBefore = Get-TreeSnapshot -Root $diff
        $diffCode = Invoke-Action -ActionName 'Repair' -Pin $pair.Pin -Root $diff
        if ($diffCode -ne 1) {
            Fail "repair differs pin $($pair.Pin) returned $diffCode"
        }
        Assert-Snapshot -Root $diff -Before $diffBefore -Label "repair differs $($pair.Pin)"
    }

    $replaceParent = New-WorkRoot
    $replace = Join-Path $replaceParent 'marker'
    Write-Exact -Path (Join-Path $replace 'marker.txt') -Text '9.9.9'
    Write-Exact -Path (Join-Path $replace 'sentinel.txt') -Text 'ok'
    $replaceBefore = Get-TreeSnapshot -Root $replace
    $updateNewer = Invoke-Action -ActionName 'Update' -Pin '1.0.0' -Root $replace
    if ($updateNewer -ne 0) {
        Fail "update left-in-place returned $updateNewer"
    }
    Assert-Snapshot -Root $replace -Before $replaceBefore -Label 'update left newer marker'
    $reinstall = Invoke-Action -ActionName 'Reinstall' -Pin '1.0.0' -Root $replace
    if ($reinstall -ne 0) {
        Fail "reinstall replace returned $reinstall"
    }
    Assert-Installed -Root $replace -Pin '1.0.0' -Log "Uninstall`nInstall`n" -Label 'reinstall replace'

    $reinstallEmptyParent = New-WorkRoot
    $reinstallEmpty = Join-Path $reinstallEmptyParent 'marker'
    $reinstallEmptyCode = Invoke-Action -ActionName 'Reinstall' -Pin '3.1.0' -Root $reinstallEmpty
    if ($reinstallEmptyCode -ne 0) {
        Fail "reinstall empty returned $reinstallEmptyCode"
    }
    Assert-Installed -Root $reinstallEmpty -Pin '3.1.0' -Log "Uninstall`nInstall`n" -Label 'reinstall empty'

    $reinstallLogParent = New-WorkRoot
    $reinstallLog = Join-Path $reinstallLogParent 'marker'
    Write-Exact -Path (Join-Path $reinstallLog 'marker.txt') -Text "1.0.0`n"
    Write-Exact -Path (Join-Path $reinstallLog 'sentinel.txt') -Text 'ok'
    Write-Exact -Path (Join-Path $reinstallLog 'toolkit.log') -Text "Install`n"
    $reinstallLogCode = Invoke-Action -ActionName 'Reinstall' -Pin '1.4.0' -Root $reinstallLog
    if ($reinstallLogCode -ne 0) {
        Fail "reinstall append returned $reinstallLogCode"
    }
    Assert-Installed -Root $reinstallLog -Pin '1.4.0' -Log "Install`nUninstall`nInstall`n" -Label 'reinstall append'

    foreach ($shape in @('marker', 'sentinel', 'both')) {
        $uninstallParent = New-WorkRoot
        $uninstall = Join-Path $uninstallParent 'marker'
        if ($shape -eq 'marker' -or $shape -eq 'both') {
            Write-Exact -Path (Join-Path $uninstall 'marker.txt') -Text "8.0.0`n"
        }
        if ($shape -eq 'sentinel' -or $shape -eq 'both') {
            Write-Exact -Path (Join-Path $uninstall 'sentinel.txt') -Text 'ok'
        }
        $priorLog = ''
        if ($shape -eq 'both') {
            $priorLog = "Install`n"
            Write-Exact -Path (Join-Path $uninstall 'toolkit.log') -Text $priorLog
        }
        $uninstallCode = Invoke-Action -ActionName 'Uninstall' -Pin '8.0.0' -Root $uninstall
        if ($uninstallCode -ne 0) {
            Fail "uninstall $shape returned $uninstallCode"
        }
        Assert-Absent -Path (Join-Path $uninstall 'marker.txt') -Label "uninstall $shape marker"
        Assert-Absent -Path (Join-Path $uninstall 'sentinel.txt') -Label "uninstall $shape sentinel"
        Assert-Text -Path (Join-Path $uninstall 'toolkit.log') -Expected ($priorLog + "Uninstall`n") -Label "uninstall $shape log"
    }

    $absentParent = New-WorkRoot
    $absent = Join-Path $absentParent 'marker'
    $absentCode = Invoke-Action -ActionName 'Uninstall' -Pin '1.0.0' -Root $absent
    if ($absentCode -ne 0) {
        Fail "uninstall absent returned $absentCode"
    }
    Assert-Absent -Path (Join-Path $absent 'marker.txt') -Label 'uninstall absent marker'
    Assert-Absent -Path (Join-Path $absent 'sentinel.txt') -Label 'uninstall absent sentinel'
    Assert-Absent -Path (Join-Path $absent 'toolkit.log') -Label 'uninstall absent log'

    $packageDir = Split-Path -Parent $probe
    $packageBefore = @(
        Get-ChildItem -LiteralPath $packageDir -Recurse -Force |
            ForEach-Object { $_.FullName } |
            Sort-Object
    )
    $executeParent = New-WorkRoot
    $executeRoot = Join-Path $executeParent 'marker'
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
    $psi.ArgumentList.Add($probe)
    $psi.ArgumentList.Add('-DeploymentType')
    $psi.ArgumentList.Add('Install')
    $psi.ArgumentList.Add('-Action')
    $psi.ArgumentList.Add('Install')
    $psi.ArgumentList.Add('-PinVersion')
    $psi.ArgumentList.Add('1.2.3')
    $psi.ArgumentList.Add('-MarkerRoot')
    $psi.ArgumentList.Add($executeRoot)
    if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_TEST')) {
        [void]$psi.Environment.Remove('RELIAN_DEPLOY_TEST')
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
            Fail 'executed probe timed out'
        }
        [void]$proc.WaitForExit()
        $executedOut = $stdoutTask.Result
        $executedErr = $stderrTask.Result
        if ($proc.ExitCode -eq 0) {
            Fail "executed probe exited 0 stdout [$executedOut] stderr [$executedErr]"
        }
    } finally {
        $proc.Dispose()
    }
    Assert-Absent -Path (Join-Path $executeRoot 'marker.txt') -Label 'executed marker'
    Assert-Absent -Path (Join-Path $executeRoot 'sentinel.txt') -Label 'executed sentinel'
    Assert-Absent -Path (Join-Path $executeRoot 'toolkit.log') -Label 'executed log'
    $packageAfter = @(
        Get-ChildItem -LiteralPath $packageDir -Recurse -Force |
            ForEach-Object { $_.FullName } |
            Sort-Object
    )
    if (($packageBefore -join "`n") -cne ($packageAfter -join "`n")) {
        Fail 'executed probe changed the package directory'
    }

    Write-Output 'action-probe tests passed'
} finally {
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

exit 0
