$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/user-check/Invoke-UserCheck.ps1'
$releasePath = Join-Path $repoRoot 'releases/user-check.json'
$fixtureCode = 'k7m2'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        [Console]::Error.WriteLine('FAIL missing failure message')
        exit 1
    }
    $safe = [regex]::Replace($Message, '(?i)(/home|/Users|[A-Za-z]:\\Users)\\[^\s\]]+', 'USER')
    [Console]::Error.WriteLine("FAIL $safe")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Fail 'Assert-Same missing label'
    }
    if ($Actual -ne $Expected) {
        Fail "$Label was [$Actual] expected [$Expected]"
    }
}

function Assert-True {
    param($Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Fail 'Assert-True missing label'
    }
    if (-not $Value) {
        Fail $Label
    }
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail "missing $scriptPath"
}

$source = [System.IO.File]::ReadAllText($scriptPath)

function Assert-SourceHas {
    param([string]$Needle)
    if ([string]::IsNullOrWhiteSpace($Needle)) {
        Fail 'Assert-SourceHas missing needle'
    }
    if ($source.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        Fail "source missing $Needle"
    }
}

Assert-SourceHas -Needle 'https://login.microsoftonline.com/'
Assert-SourceHas -Needle '-RequestInput'
Assert-SourceHas -Needle "-ButtonLeftText 'Confirm'"
Assert-SourceHas -Needle "-ButtonRightText 'Cancel'"
Assert-SourceHas -Needle "-ButtonLeftText 'Open'"
Assert-SourceHas -Needle '-NoExitOnTimeout'
Assert-SourceHas -Needle '-Timeout 600'
Assert-SourceHas -Needle "`$subtitle = 'Identity check'"
Assert-SourceHas -Needle '-Subtitle $subtitle'
Assert-SourceHas -Needle 'FluentAccentColor = 0xFF000000'
Assert-SourceHas -Needle 'DefaultTimeout = 600'
Assert-SourceHas -Needle 'var lightText'
Assert-SourceHas -Needle 'WhitenBlackButtons'
Assert-SourceHas -Needle '8c3c366b-8606-4576-9f2d-4051144f7ca2'
Assert-SourceHas -Needle "ModuleVersion = '4.1.8'"
Assert-SourceHas -Needle "-DeployMode 'Interactive'"
Assert-SourceHas -Needle 'Start-Process -FilePath (Get-UserCheckSignInUrl)'
Assert-SourceHas -Needle 'Nobody answered the identity check. Nothing was installed.'

if ($source.Contains('using System.Windows.Shapes')) {
    Fail 'theme helper imports System.Windows.Shapes'
}
if ($source -match 'ninjarmm|NinjaOne|Ninja-Property-') {
    Fail 'package references Ninja'
}
if ($source -match 'https://login\.microsoftonline\.com/[^\s'']*[?&]') {
    Fail 'sign-in url has a query string'
}
if ($source -match 'Write-Output[^\r\n]*\$PinVersion' -or $source -match 'WriteLine\([^\r\n]*\$PinVersion') {
    Fail 'script prints PinVersion'
}

$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
$guardAt = $source.IndexOf($guardNeedle, [System.StringComparison]::Ordinal)
$importAt = $source.IndexOf('Import-Module', [System.StringComparison]::Ordinal)
$themeAt = $source.IndexOf('function Install-UserCheckDialogTheme', [System.StringComparison]::Ordinal)
if ($themeAt -lt 0 -or $guardAt -lt 0 -or $importAt -lt 0 -or $themeAt -gt $guardAt -or $guardAt -gt $importAt) {
    Fail 'dot-source guard does not sit after the theme helper and before Import-Module'
}

$pageGuardAt = $source.IndexOf('Sign-in page was not opened.', [System.StringComparison]::Ordinal)
$startAt = $source.IndexOf('Start-Process -FilePath (Get-UserCheckSignInUrl)', [System.StringComparison]::Ordinal)
$pageOpenAt = $source.IndexOf('Microsoft sign-in page opened.', [System.StringComparison]::Ordinal)
if ($pageGuardAt -lt 0 -or $startAt -lt 0 -or $pageOpenAt -lt 0 -or $pageGuardAt -gt $startAt -or $startAt -gt $pageOpenAt) {
    Fail 'the sign-in page can open before Open is chosen'
}
$pageParse = '$parsed = Get-UserCheckPromptResult -Result $prompt'
$pageParseAt = $source.IndexOf($pageParse, [System.StringComparison]::Ordinal)
$openGuard = "if (`$parsed.TimedOut -or `$parsed.Button -ne 'Open')"
$openGuardAt = $source.IndexOf($openGuard, [System.StringComparison]::Ordinal)
if ($pageParseAt -lt 0 -or $openGuardAt -lt 0 -or $pageParseAt -gt $openGuardAt -or $openGuardAt -gt $startAt) {
    Fail 'Cancel, Confirm, or a timeout can open the sign-in page'
}

$timeoutAt = $source.IndexOf('Code check timed out.', [System.StringComparison]::Ordinal)
$mismatchAt = $source.IndexOf('Code did not match.', [System.StringComparison]::Ordinal)
$matchedAt = $source.IndexOf('Code matched.', [System.StringComparison]::Ordinal)
if ($timeoutAt -lt 0 -or $mismatchAt -lt 0 -or $matchedAt -lt 0 -or $timeoutAt -gt $mismatchAt -or $mismatchAt -gt $matchedAt) {
    Fail 'a timeout or a mismatch can be reported as a match'
}

if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail "missing $releasePath"
}
$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
Assert-Same -Actual $release.signInUrl -Expected 'https://login.microsoftonline.com/' -Label 'release sign-in url'
Assert-Same -Actual $release.pagePin -Expected 'microsoft-sign-in' -Label 'release page pin'
Assert-Same -Actual $release.installsSoftware -Expected $false -Label 'release installs software'
if ($release.PSObject.Properties.Name -contains 'sha256') {
    Fail 'release file stores an installer hash'
}
$releaseText = [System.IO.File]::ReadAllText($releasePath)
if ($releaseText -match '[?&]') {
    Fail 'release file contains a query string'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue

Assert-Same -Actual (Get-UserCheckMode -PinVersion 'microsoft-sign-in') -Expected 'page' -Label 'page mode'
Assert-Same -Actual (Get-UserCheckMode -PinVersion '  microsoft-sign-in  ') -Expected 'page' -Label 'trimmed page mode'
Assert-Same -Actual (Get-UserCheckMode -PinVersion 'Microsoft-Sign-In') -Expected 'page' -Label 'page mode ignores case'
Assert-Same -Actual (Get-UserCheckMode -PinVersion $fixtureCode) -Expected 'code' -Label 'code mode'
Assert-Same -Actual (Get-UserCheckMode -PinVersion 'abcd') -Expected 'code' -Label 'four character code'
Assert-Same -Actual (Get-UserCheckMode -PinVersion 'abcdefgh') -Expected 'code' -Label 'eight character code'
foreach ($bad in @('', '   ', 'ab', 'abc', 'abcdefghi', '1.0.0', 'ab cd', 'ab-cd', 'code!')) {
    Assert-Same -Actual (Get-UserCheckMode -PinVersion $bad) -Expected 'invalid' -Label "rejected pin [$bad]"
}

Assert-Same -Actual (Get-UserCheckSignInUrl) -Expected 'https://login.microsoftonline.com/' -Label 'sign-in url'
if ((Get-UserCheckSignInUrl) -match '[?&]') {
    Fail 'sign-in url function returned a query string'
}

Assert-True -Value (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Confirm' -Text $fixtureCode) -Label 'exact code matches'
Assert-True -Value (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Confirm' -Text 'K7M2') -Label 'code match ignores case'
Assert-True -Value (Test-UserCheckAnswer -Expected " $fixtureCode " -Button 'Confirm' -Text " $fixtureCode ") -Label 'code match trims'
if (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Confirm' -Text 'k7m3') {
    Fail 'wrong code matched'
}
if (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Cancel' -Text $fixtureCode) {
    Fail 'cancel matched'
}
if (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Timeout' -Text $fixtureCode) {
    Fail 'timeout matched'
}
if (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Confirm' -Text '   ') {
    Fail 'blank text matched'
}
if (Test-UserCheckAnswer -Expected '' -Button 'Confirm' -Text $fixtureCode) {
    Fail 'blank expected code matched'
}
if (Test-UserCheckAnswer -Expected $fixtureCode -Button 'Open' -Text $fixtureCode) {
    Fail 'page button matched a code'
}

function Assert-Prompt {
    param($Result, [string]$Button, [string]$Text, [bool]$TimedOut, [string]$Label)
    $parsed = Get-UserCheckPromptResult -Result $Result
    Assert-Same -Actual $parsed.Button -Expected $Button -Label "$Label button"
    Assert-Same -Actual $parsed.Text -Expected $Text -Label "$Label text"
    Assert-Same -Actual ([bool]$parsed.TimedOut) -Expected $TimedOut -Label "$Label timeout"
}

Assert-Prompt -Result $null -Button '' -Text '' -TimedOut $false -Label 'null prompt'
Assert-Prompt -Result 'Open' -Button 'Open' -Text '' -TimedOut $false -Label 'open string'
Assert-Prompt -Result 'Cancel' -Button 'Cancel' -Text '' -TimedOut $false -Label 'cancel string'
Assert-Prompt -Result 'Timeout' -Button 'Timeout' -Text '' -TimedOut $true -Label 'timeout string'
Assert-Prompt -Result ([pscustomobject]@{ Result = 'Confirm'; Text = $fixtureCode }) -Button 'Confirm' -Text $fixtureCode -TimedOut $false -Label 'input object'
Assert-Prompt -Result ([pscustomobject]@{ Result = 'Timeout'; Text = $null }) -Button 'Timeout' -Text '' -TimedOut $true -Label 'timeout object'
Assert-Prompt -Result ([pscustomobject]@{ Result = 'Confirm'; Text = '   ' }) -Button 'Confirm' -Text '   ' -TimedOut $false -Label 'blank object text'
Assert-Prompt -Result (@{ Result = 'Confirm'; Text = $fixtureCode }) -Button 'Confirm' -Text $fixtureCode -TimedOut $false -Label 'input dictionary'
$json = '{"Result":"Confirm","Text":"' + $fixtureCode + '"}'
Assert-Prompt -Result $json -Button 'Confirm' -Text $fixtureCode -TimedOut $false -Label 'input json'

function Invoke-Package {
    param([string[]]$ArgumentList)
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
    foreach ($arg in $ArgumentList) {
        $psi.ArgumentList.Add($arg)
    }
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
            try { $proc.Kill($true) } catch { $proc.Kill() }
            Fail 'package timed out'
        }
        [void]$proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

function Assert-Run {
    param(
        [string[]]$ArgumentList,
        [int]$ExitCode,
        [string]$StdOutHas,
        [string]$StdErrHas,
        [string[]]$StdOutLacks,
        [string[]]$StdErrLacks,
        [string]$Label
    )
    if ($null -eq $ArgumentList) {
        Fail 'Assert-Run missing argument list'
    }
    if (-not $PSBoundParameters.ContainsKey('ExitCode')) {
        Fail 'Assert-Run missing exit code'
    }
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Fail 'Assert-Run missing label'
    }
    $run = Invoke-Package -ArgumentList $ArgumentList
    if ($run.ExitCode -ne $ExitCode) {
        Fail "$Label exited $($run.ExitCode)"
    }
    if ($StdOutHas -and $run.StdOut -notlike "*$StdOutHas*") {
        Fail "$Label stdout missed [$StdOutHas]"
    }
    if ($StdErrHas -and $run.StdErr -notlike "*$StdErrHas*") {
        Fail "$Label stderr missed [$StdErrHas]"
    }
    foreach ($needle in @($StdOutLacks)) {
        if ($needle -and $run.StdOut.Contains($needle)) {
            Fail "$Label stdout contained [$needle]"
        }
    }
    foreach ($needle in @($StdErrLacks)) {
        if ($needle -and $run.StdErr.Contains($needle)) {
            Fail "$Label stderr contained [$needle]"
        }
    }
}

Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Uninstall', '-PinVersion', $fixtureCode) -ExitCode 0 -StdOutHas 'Nothing to change. Nothing was installed.' -Label 'uninstall'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Repair', '-PinVersion', 'microsoft-sign-in') -ExitCode 0 -StdOutHas 'Nothing to change. Nothing was installed.' -Label 'repair'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Reinstall', '-PinVersion', $fixtureCode) -ExitCode 1 -StdErrHas 'Reinstall is not a user-check action' -Label 'reinstall'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Install') -ExitCode 1 -StdErrHas 'missing parameter PinVersion' -Label 'missing pin'
Assert-Run -ArgumentList @('-Action', 'Install', '-PinVersion', $fixtureCode) -ExitCode 1 -StdErrHas 'missing parameter DeploymentType' -Label 'missing deployment type'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Nope', '-PinVersion', $fixtureCode) -ExitCode 1 -StdErrHas 'Action must be Install, Update, Repair, Reinstall, or Uninstall.' -StdErrLacks $fixtureCode -Label 'unknown action'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Install', '-PinVersion', '1.0.0') -ExitCode 1 -StdErrHas 'PinVersion must be a 4 to 8 character code, or microsoft-sign-in.' -StdOutLacks '1.0.0' -StdErrLacks '1.0.0' -Label 'dotted pin'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Install', '-PinVersion', $fixtureCode) -ExitCode 1 -StdOutHas 'Identity check starting. Nothing will be installed.' -StdOutLacks @($fixtureCode, 'Code matched.') -StdErrLacks $fixtureCode -Label 'code without toolkit'
Assert-Run -ArgumentList @('-DeploymentType', 'Install', '-Action', 'Update', '-PinVersion', 'microsoft-sign-in') -ExitCode 1 -StdOutHas 'Identity check starting. Nothing will be installed.' -StdOutLacks 'Microsoft sign-in page opened.' -Label 'page without toolkit'

Write-Output 'user-check tests passed'
