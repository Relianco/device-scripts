# Offline tests for the WAU mods that Invoke-Wau.ps1 writes (mods\_WAU-mods.ps1 and the per-app -preinstall mods it makes).
# Owner rule 2026-11-25: app updates only after hours, only while the PC is not in use, and never close a running app.
# Boundaries faked: the clock (-Now) and the process list (a Get-Process function, which the mods resolve before the cmdlet).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wau/Invoke-Wau.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# The fake install sits two levels inside a sandbox, so a file that escapes mods\ is still found and removed.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-mods-' + [guid]::NewGuid().ToString('n'))
$root = Join-Path (Join-Path $sandbox 'a') 'install'
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # The real writer, into a fake install folder.
    & $script:SetWauMods -InstallLocation $root
    $mods = Join-Path $root 'mods'
    $gate = Join-Path $mods '_WAU-mods.ps1'
    if (-not (Test-Path -LiteralPath $gate)) { Fail 'mods\_WAU-mods.ps1 was not written' }
    Set-Content -LiteralPath (Join-Path $root 'included_apps.txt') -Value @('VideoLAN.VLC', '7zip.7zip', 'Microsoft.VCRedist.2015+.x64', 'Some.UnknownApp') -Encoding ascii

    $global:WauFakeProcs = @()
    function Get-Process { return $global:WauFakeProcs }
    function P([string]$Name, [int]$Session) { [pscustomobject]@{ ProcessName = $Name; SessionId = $Session } }

    # As WAU's Test-WAUMods runs it: output as text, an Abort is a JSON object with Action Abort.
    function Invoke-Gate([string]$At) {
        $out = & $gate -Now ([datetime]::ParseExact($At, 'yyyy-MM-dd HH:mm', $null)) 2>&1 | Out-String
        $json = [regex]::Match($out, '\{.*\}').Value
        if ($json) { return ($json | ConvertFrom-Json).Action }
        return 'Continue'
    }
    # As WAU's Update-App reads a -preinstall mod: $false skips the app.
    function Test-Skipped([string]$Id) {
        $pre = Join-Path $mods "$Id-preinstall.ps1"
        if (-not (Test-Path -LiteralPath $pre)) { Fail "no preinstall mod for $Id" }
        return ((& $pre) -eq $false)
    }

    # A missed 01:00 run that starts when the PC comes back in the morning does nothing.
    foreach ($t in @('2026-11-26 05:00', '2026-11-26 08:00', '2026-11-26 13:30', '2026-11-26 23:59')) {
        $global:WauFakeProcs = @()
        if ((Invoke-Gate $t) -cne 'Abort') { Fail "a run at $t was not stopped" }
    }
    foreach ($t in @('2026-11-26 00:00', '2026-11-26 01:00', '2026-11-26 03:00', '2026-11-26 04:59')) {
        $global:WauFakeProcs = @()
        if ((Invoke-Gate $t) -cne 'Continue') { Fail "an idle run at $t was stopped" }
    }

    # Idle PC, nobody signed in: every app updates.
    $global:WauFakeProcs = @((P 'svchost' 0))
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Continue') { Fail 'idle PC was stopped' }
    foreach ($id in @('VideoLAN.VLC', '7zip.7zip', 'Microsoft.VCRedist.2015+.x64', 'Some.UnknownApp')) {
        if (Test-Skipped $id) { Fail "$id was skipped on an idle PC" }
    }

    # Someone signed in and not locked: the PC is in use, the whole run stops.
    $global:WauFakeProcs = @((P 'explorer' 1))
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Abort') { Fail 'a run went ahead while a session was in use' }

    # Signed in but locked, VLC left open: VLC is skipped (not closed), 7-Zip still updates.
    $global:WauFakeProcs = @((P 'explorer' 1), (P 'LogonUI' 1), (P 'vlc' 1))
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Continue') { Fail 'a locked PC was stopped' }
    if (-not (Test-Skipped 'VideoLAN.VLC')) { Fail 'a running VLC was not skipped' }
    if (Test-Skipped '7zip.7zip') { Fail '7-Zip was skipped while it was not running' }
    # The 7-Zip command line counts as 7-Zip running.
    $global:WauFakeProcs = @((P 'explorer' 1), (P 'LogonUI' 1), (P '7z' 1))
    if (-not (Test-Skipped '7zip.7zip')) { Fail '7-Zip updated while 7z.exe was running' }
    $global:WauFakeProcs = @((P 'explorer' 1), (P 'LogonUI' 1), (P 'vlc' 1))
    # An app with no known process names waits for a night with nobody signed in.
    if (-not (Test-Skipped 'Some.UnknownApp')) { Fail 'an unmapped app updated while someone was signed in' }
    # A signed-in session without Explorer (RemoteApp, a crashed shell) still holds unmapped apps back.
    $global:WauFakeProcs = @((P 'csrss' 1), (P 'winlogon' 1), (P 'LogonUI' 1), (P 'dwm' 1), (P 'sihost' 1))
    if (-not (Test-Skipped 'Some.UnknownApp')) { Fail 'an unmapped app updated while a session without Explorer was signed in' }
    # The sign-in screen alone (no one signed in) does not.
    $global:WauFakeProcs = @((P 'svchost' 0), (P 'csrss' 1), (P 'winlogon' 1), (P 'LogonUI' 1), (P 'dwm' 1), (P 'fontdrvhost' 1))
    if (Test-Skipped 'Some.UnknownApp') { Fail 'an unmapped app was held back by the sign-in screen alone' }
    $global:WauFakeProcs = @((P 'explorer' 1), (P 'LogonUI' 1), (P 'vlc' 1))
    # Shared runtimes have no process of their own: they wait for a night with nobody signed in.
    if (-not (Test-Skipped 'Microsoft.VCRedist.2015+.x64')) { Fail 'the VC++ runtime updated while someone was signed in' }

    # Two sessions, one locked and one not: in use.
    $global:WauFakeProcs = @((P 'explorer' 1), (P 'LogonUI' 1), (P 'explorer' 2))
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Abort') { Fail 'an unlocked second session was ignored' }

    # A per-app check that cannot be written stops the run (WAU would otherwise update that app unguarded).
    $blocker = Join-Path $mods 'VideoLAN.VLC-preinstall.ps1'
    Remove-Item -LiteralPath $blocker -Force
    New-Item -ItemType Directory -Path $blocker | Out-Null
    $global:WauFakeProcs = @()
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Abort') { Fail 'a run went ahead although a per-app check could not be written' }
    Remove-Item -LiteralPath $blocker -Recurse -Force

    # A list line that is not a winget id stops the run before any file is named after it.
    Set-Content -LiteralPath (Join-Path $root 'included_apps.txt') -Value @('VideoLAN.VLC', '..\..\evil', '../../evil') -Encoding ascii
    $global:WauFakeProcs = @()
    if ((Invoke-Gate '2026-11-26 01:20') -cne 'Abort') { Fail 'a bad list line was accepted' }
    if (@(Get-ChildItem -LiteralPath $sandbox -Recurse -Filter '*evil*').Count -ne 0) { Fail 'a file was named after a bad list line' }

    # The mods never ask WAU for a restart.
    $text = Get-Content -LiteralPath $gate -Raw
    if ($text -match 'Reboot' -or $text -match 'Restart-Computer' -or $text -match 'shutdown') { Fail 'the mods mention a restart' }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'wau-mods tests passed'
exit 0
