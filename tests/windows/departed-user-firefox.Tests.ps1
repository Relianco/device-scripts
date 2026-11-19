$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/departed-user-firefox/Invoke-DepartedUserFirefox.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# Get-DuMode
Assert-Same (Get-DuMode -Action 'Install' -Fix '' -User 'a.b') 'report' 'default is report'
Assert-Same (Get-DuMode -Action 'Install' -Fix 'true' -User 'a.b') 'fix' 'fix'
Assert-Same (Get-DuMode -Action 'Uninstall' -Fix 'true' -User 'a.b') 'none' 'uninstall changes nothing'
Assert-Same (Get-DuMode -Action 'Install' -Fix 'true' -User 'a.b' -PinVersion '') 'none' 'empty pin is off'
foreach ($bad in @(@('Install', '', '..\x'), @('Install', '', ''), @('Install', '', '..'), @('Install', 'yes', 'a'), @('Bogus', '', 'a'), @('Install', '', 'a/b'))) {
    $threw = $false
    try { Get-DuMode -Action $bad[0] -Fix $bad[1] -User $bad[2] | Out-Null } catch { $threw = $true }
    if (-not $threw) { Fail "bad input $($bad -join '/') did not throw" }
}

# Fixture: a fake users root with one profile that has a Firefox folder, documents and a Firefox profile.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-du-' + [guid]::NewGuid().ToString('n'))
$prof = Join-Path $root 'gone.user'
foreach ($rel in 'AppData/Local/Mozilla Firefox/browser', 'AppData/Roaming/Mozilla/Firefox/Profiles/p1', 'Documents', 'Desktop') {
    [void](New-Item -ItemType Directory -Path (Join-Path $prof $rel) -Force)
}
Set-Content -LiteralPath (Join-Path $prof 'AppData/Local/Mozilla Firefox/firefox.exe') -Value 'x'
Set-Content -LiteralPath (Join-Path $prof 'AppData/Roaming/Mozilla/Firefox/Profiles/p1/places.sqlite') -Value 'x'
Set-Content -LiteralPath (Join-Path $prof 'Documents/case.docx') -Value 'x'
$ff = Join-Path $prof 'AppData/Local/Mozilla Firefox'

function Get-DuUsersRoot { $root }
$script:disabled = $true; $script:sessions = 0; $script:procs = @(); $script:keys = @()
function Get-DuAccountDisabled { param([string]$User) $script:disabled }
function Get-DuSessionCount { $script:sessions }
function Get-DuProcessPaths { @($script:procs) }
function Get-DuUninstallKeys { @($script:keys) }
function Run-Du { param([switch]$Fix) (Get-DuResult -User 'gone.user' -Fix:$Fix).record }

try {
    # Refusals: each guard alone refuses and nothing is deleted.
    foreach ($case in @(
            @{ n = 'enabled account'; set = { $script:disabled = $false } },
            @{ n = 'unreachable directory'; set = { $script:disabled = $null } },
            @{ n = 'a session exists'; set = { $script:sessions = 1 } },
            @{ n = 'unreadable sessions'; set = { $script:sessions = $null } },
            @{ n = 'process running from the folder'; set = { $script:procs = @((Join-Path $ff 'firefox.exe')) } })) {
        $script:disabled = $true; $script:sessions = 0; $script:procs = @()
        & $case.set
        $why = @(Get-DuRefusals -User 'gone.user' -Profile $prof -Folders @(Get-DuFirefoxFolders -Profile $prof))
        if ($why.Count -eq 0) { Fail "$($case.n) did not refuse" }
        if (-not (Test-Path -LiteralPath $ff)) { Fail "$($case.n) deleted the folder" }
    }
    $script:disabled = $true; $script:sessions = 0; $script:procs = @()

    # A reparse point (symlink standing in for a junction) in the path refuses.
    $realFf = Join-Path $root 'real'
    [void](New-Item -ItemType Directory -Path $realFf -Force)
    $linkProf = Join-Path $root 'link.user'
    [void](New-Item -ItemType Directory -Path (Join-Path $linkProf 'AppData/Local') -Force)
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $linkProf 'AppData/Local/Mozilla Firefox') -Target $realFf)
    $why = @(Get-DuRefusals -User 'link.user' -Profile $linkProf -Folders @(Get-DuFirefoxFolders -Profile $linkProf))
    if (-not ($why -like 'reparse point*')) { Fail 'reparse point did not refuse' }

    # Report mode never deletes and reports the documents outside OneDrive.
    $r = Run-Du
    Assert-Same $r.mode 'report' 'report mode'
    if (-not (Test-Path -LiteralPath $ff)) { Fail 'report mode deleted the folder' }
    Assert-Same $r.report.filesOutsideOneDrive.Documents 1 'one document outside OneDrive'
    Assert-Same @($r.firefoxFolders).Count 1 'firefox folder listed'

    # Fix with every guard satisfied removes only the Firefox folder and its uninstall entry; the profile and documents stay.
    $r = Run-Du -Fix
    Assert-Same @($r.refused).Count 0 'no refusals'
    if (Test-Path -LiteralPath $ff) { Fail 'firefox folder was not removed' }
    if (-not (Test-Path -LiteralPath (Join-Path $prof 'Documents/case.docx'))) { Fail 'a document was deleted' }
    if (-not (Test-Path -LiteralPath (Join-Path $prof 'AppData/Roaming/Mozilla/Firefox/Profiles/p1/places.sqlite'))) { Fail 'the Firefox profile was deleted' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

Write-Host 'PASS departed-user-firefox'
