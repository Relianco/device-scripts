# Offline tests for windows/packages/wau/Invoke-Wau.ps1. Every hook that would touch the network,
# the registry, msiexec, icacls or the IME log folder is replaced. Runs under pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wau/Invoke-Wau.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/wau.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Wau.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/wau.json does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
. $scriptPath
$realSetImeLogLink = $script:SetImeLogLink
$realRemoveImeLogLink = $script:RemoveImeLogLink

# The pin. The SHA256 is the GitHub release asset digest for v2.12.0 WAU.msi, checked against the downloaded file.
$pinnedUrl = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
$pinnedSha = 'f5ab2303fdf82fbfcb2248cca4f96479fe17d74584a528b0f86b3dbe9f9e9718'
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.sourceUrl -cne $pinnedUrl) { Fail "source URL '$($release.sourceUrl)'" }
if ([string]$release.sha256 -cne $pinnedSha) { Fail 'sha256 does not match the release asset' }
if ([int64]$release.size -ne 1500640) { Fail "size $($release.size)" }
if ([string]$release.version -cne '2.12.0') { Fail "version '$($release.version)'" }
if ([string]$release.upgradeCode -cne '{BDDEA607-F4AF-4229-8610-16E3B6455FDC}') { Fail 'upgrade code' }
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/wau.json'
}
if ($script:WauUpgradeCode -cne [string]$release.upgradeCode) { Fail 'script upgrade code does not match the release' }
if (-not (Test-WauPinHash -Sha256 $pinnedSha)) { Fail 'pinned hash rejected' }
if (Test-WauPinHash -Sha256 $pinnedSha.ToUpperInvariant()) { Fail 'uppercase hash accepted' }
if (Test-WauPinHash -Sha256 ('0' * 64)) { Fail 'placeholder hash accepted' }

# List URL: a ring folder under Relian's container, nothing else.
$ring = 'https://relianpub.blob.core.windows.net/pub/wau/broad/'
foreach ($good in @($ring, 'https://relianpub.blob.core.windows.net/pub/wau/early', 'https://relianpub.blob.core.windows.net/pub/wau/ring-2/')) {
    if (-not (Test-WauListUrl -Url $good)) { Fail "list URL rejected: $good" }
}
$userInfoUrl = -join @('https://', 'user', '@', 'relianpub.blob.core.windows.net/pub/wau/broad/')
$badUrls = @(
    '',
    $userInfoUrl,
    'http://relianpub.blob.core.windows.net/pub/wau/broad/',
    'https://relianpub.blob.core.windows.net.example.invalid/pub/wau/broad/',
    'https://example.invalid/pub/wau/broad/',
    'https://raw.githubusercontent.com/x/y/main/',
    'https://relianpub.blob.core.windows.net/pub/wau/broad/?sv=1',
    'https://relianpub.blob.core.windows.net/pub/wau/',
    'https://relianpub.blob.core.windows.net/pub/wau/../sec/',
    'https://relianpub.blob.core.windows.net/pub/wau/broad/included_apps.txt',
    'https://relianpub.blob.core.windows.net:8443/pub/wau/broad/',
    'https://RELIANPUB.blob.core.windows.net/pub/wau/broad/',
    'https://relianpub.blob.core.windows.net/pub/wau/broad /'
)
foreach ($bad in $badUrls) {
    if (Test-WauListUrl -Url $bad) { Fail "list URL accepted: $bad" }
}
foreach ($t in @('12:00:00', '00:00:00', '23:59:59')) {
    if (-not (Test-WauTimeText -Text $t)) { Fail "time rejected: $t" }
}
foreach ($t in @('', '24:00:00', '12:00', '7:00:00', '12:00:00 ', '12:00:00;x')) {
    if (Test-WauTimeText -Text $t) { Fail "time accepted: $t" }
}
if (-not (Test-WauMultiSession -EditionId 'ServerRdsh')) { Fail 'ServerRdsh is multi-session' }
foreach ($e in @('', 'Professional', 'Enterprise', 'serverrdsh')) {
    if (Test-WauMultiSession -EditionId $e) { Fail "$e is not multi-session" }
}

# Exact msiexec argument lists.
$msi = 'C:\Temp\relian-wau-x\WAU.msi'
$pcProps = Get-WauMsiProperties -MultiSession $false -ListUrl $ring -UpdatesAtTime '12:00:00' -AvdUpdatesAtTime '02:00:00'
$avdProps = Get-WauMsiProperties -MultiSession $true -ListUrl $ring -UpdatesAtTime '12:00:00' -AvdUpdatesAtTime '02:00:00'
$common = @('DISABLEWAUAUTOUPDATE=1', 'USEWHITELIST=1', "LISTPATH=$ring", 'UPDATESINTERVAL=Daily')
$tail = @('USERCONTEXT=0', 'NOTIFICATIONLEVEL=None', 'DONOTRUNONMETERED=1', 'MAXLOGFILES=7', 'MAXLOGSIZE=1048576', 'RUN_WAU=NO')
$expectedPc = @('/i', ('"' + $msi + '"'), '/qn', '/norestart') + $common + @('UPDATESATTIME=12:00:00', 'UPDATESATTIMEDELAY=02:00', 'UPDATESATLOGON=0') + $tail
$expectedAvd = @('/i', ('"' + $msi + '"'), '/qn', '/norestart') + $common + @('UPDATESATTIME=02:00:00', 'UPDATESATTIMEDELAY=00:30', 'UPDATESATLOGON=0') + $tail
$actualPc = @(Get-WauMsiArgumentList -Mode 'install' -InstallerPath $msi -Properties $pcProps)
$actualAvd = @(Get-WauMsiArgumentList -Mode 'install' -InstallerPath $msi -Properties $avdProps)
if (($actualPc -join '|') -cne ($expectedPc -join '|')) { Fail "PC arguments: $($actualPc -join ' ')" }
if (($actualAvd -join '|') -cne ($expectedAvd -join '|')) { Fail "AVD arguments: $($actualAvd -join ' ')" }
$actualReconfigure = @(Get-WauMsiArgumentList -Mode 'reconfigure' -InstallerPath $msi -Properties $pcProps)
if (($actualReconfigure -join '|') -cne (($expectedPc + @('REINSTALL=ALL', 'REINSTALLMODE=vamus')) -join '|')) { Fail "reconfigure arguments: $($actualReconfigure -join ' ')" }
$actualUninstall = @(Get-WauMsiArgumentList -Mode 'uninstall' -ProductCode '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}')
if (($actualUninstall -join '|') -cne '/x|{FB0EB14E-95AC-45D7-A951-432316FFCBD4}|/qn|/norestart') { Fail "uninstall arguments: $($actualUninstall -join ' ')" }
$spaced = Get-WauMsiProperties -MultiSession $false -ListUrl 'a b' -UpdatesAtTime '12:00:00' -AvdUpdatesAtTime '02:00:00'
if ($null -ne (Get-WauMsiArgumentList -Mode 'install' -InstallerPath $msi -Properties $spaced)) { Fail 'a value with a space reached the command line' }
if ($null -ne (Get-WauMsiArgumentList -Mode 'other' -InstallerPath $msi -Properties $pcProps)) { Fail 'unknown mode built a command line' }

# Registry shapes as the MSI writes them: DWORDs come back as Int32.
function New-WauConfig {
    param($Properties, [string]$Version = '2.12.0')
    return @{
        ProductVersion        = $Version
        InstallLocation       = 'C:\Program Files\Winget-AutoUpdate\'
        WAU_DisableAutoUpdate = [int]$Properties['DISABLEWAUAUTOUPDATE']
        WAU_UseWhiteList      = [int]$Properties['USEWHITELIST']
        WAU_ListPath          = $Properties['LISTPATH']
        WAU_UpdatesInterval   = $Properties['UPDATESINTERVAL']
        WAU_UpdatesAtTime     = $Properties['UPDATESATTIME']
        WAU_UpdatesTimeDelay  = $Properties['UPDATESATTIMEDELAY']
        WAU_UpdatesAtLogon    = [int]$Properties['UPDATESATLOGON']
        WAU_UserContext       = [int]$Properties['USERCONTEXT']
        WAU_NotificationLevel = $Properties['NOTIFICATIONLEVEL']
        WAU_MaxLogFiles       = 7
    }
}
$pcExpected = Get-WauExpectedConfig -Properties $pcProps
if (-not (Test-WauConfigMatches -Config (New-WauConfig -Properties $pcProps) -Expected $pcExpected)) { Fail 'matching config rejected' }
foreach ($change in @(
        @('WAU_DisableAutoUpdate', 0), @('WAU_UseWhiteList', 0), @('WAU_UserContext', 1), @('WAU_UpdatesAtLogon', 1),
        @('WAU_ListPath', 'https://relianpub.blob.core.windows.net/pub/wau/early/'), @('WAU_NotificationLevel', 'Full'),
        @('WAU_UpdatesInterval', 'Never'), @('WAU_UpdatesAtTime', '06:00:00')
    )) {
    $c = New-WauConfig -Properties $pcProps
    $c[$change[0]] = $change[1]
    if (Test-WauConfigMatches -Config $c -Expected $pcExpected) { Fail "config with $($change[0])=$($change[1]) matched" }
    $c.Remove($change[0])
    if (Test-WauConfigMatches -Config $c -Expected $pcExpected) { Fail "config without $($change[0]) matched" }
}
$policy = @{ WAU_DisableAutoUpdate = 0 }
if (Test-WauConfigMatches -Config (Merge-WauConfig -Installed (New-WauConfig -Properties $pcProps) -Policy $policy) -Expected $pcExpected) { Fail 'a policy that turns self-update on was ignored' }
if ($null -ne (Merge-WauConfig -Installed $null -Policy $policy)) { Fail 'policy alone made an install' }

# Plan.
function Assert-Plan {
    param([string]$Name, $Plan, $ExitCode, [string]$RunInstaller = '')
    if ($Plan.ExitCode -ne $ExitCode -or [string]$Plan.RunInstaller -cne $RunInstaller) {
        Fail "$Name gave exit '$($Plan.ExitCode)' run '$($Plan.RunInstaller)'"
    }
}
Assert-Plan 'fresh' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '' -ConfigMatches $false -WingetPresent $true) $null 'install'
Assert-Plan 'fresh, no winget' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '' -ConfigMatches $false -WingetPresent $false) 1618
Assert-Plan 'older' (Get-WauPlan -Action 'Update' -PinVersion '2.12.0' -InstalledVersion '2.11.1' -ConfigMatches $true -WingetPresent $true) $null 'install'
Assert-Plan 'at pin, matches' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '2.12.0' -ConfigMatches $true -WingetPresent $false) 0
Assert-Plan 'at pin, differs' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '2.12.0' -ConfigMatches $false -WingetPresent $true) $null 'reconfigure'
Assert-Plan 'repair at pin' (Get-WauPlan -Action 'Repair' -PinVersion '2.12.0' -InstalledVersion '2.12.0' -ConfigMatches $true -WingetPresent $true) $null 'reconfigure'
Assert-Plan 'newer, matches' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '2.13.0' -ConfigMatches $true -WingetPresent $true) 0
Assert-Plan 'newer, differs' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion '2.13.0' -ConfigMatches $false -WingetPresent $true) 1
Assert-Plan 'bad installed' (Get-WauPlan -Action 'Install' -PinVersion '2.12.0' -InstalledVersion 'x.y' -ConfigMatches $false -WingetPresent $true) 1
Assert-Plan 'bad pin' (Get-WauPlan -Action 'Install' -PinVersion 'latest' -InstalledVersion '' -ConfigMatches $false -WingetPresent $true) 1
Assert-Plan 'reinstall' (Get-WauPlan -Action 'Reinstall' -PinVersion '2.12.0' -InstalledVersion '' -ConfigMatches $false -WingetPresent $true) 1
Assert-Plan 'unknown' (Get-WauPlan -Action 'Remove' -PinVersion '2.12.0' -InstalledVersion '' -ConfigMatches $false -WingetPresent $true) 1
Assert-Plan 'uninstall absent' (Get-WauPlan -Action 'Uninstall' -PinVersion '2.12.0' -InstalledVersion '' -ConfigMatches $false -WingetPresent $false) 0
Assert-Plan 'uninstall present' (Get-WauPlan -Action 'Uninstall' -PinVersion '2.12.0' -InstalledVersion '2.12.0' -ConfigMatches $false -WingetPresent $false) $null 'uninstall'

# End to end with fake hooks.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$payload = $utf8.GetBytes('wau-payload')
$sha = [System.Security.Cryptography.SHA256]::Create()
$payloadSha = ([System.BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()

class WauFakeHttpException : System.Exception {
    [object]$Response
    WauFakeHttpException([int]$Status) : base('status') {
        $this.Response = [pscustomobject]@{ StatusCode = $Status }
    }
}

$script:State = @{}
function Reset-Fakes {
    param($Before, $After, [string]$Edition = 'Professional', [bool]$Winget = $true, [byte[]]$Bytes = $payload, [int]$FailFirst = 0)
    $script:State = @{
        Before = $Before; After = $After; Edition = $Edition; Winget = $Winget; Bytes = $Bytes; FailFirst = $FailFirst
        Downloads = 0; Sleeps = 0; Msi = [System.Collections.Generic.List[object]]::new(); Reads = 0
        Protected = 0; Linked = ''; Modded = ''; ModsFail = $false; Unlinked = 0; Codes = @('{FB0EB14E-95AC-45D7-A951-432316FFCBD4}')
    }
    $script:WauErrorLog.Clear()
}
$script:GetWauConfig = {
    $script:State.Reads++
    if ($script:State.Reads -eq 1) { return $script:State.Before }
    return $script:State.After
}
$script:GetEditionId = { return $script:State.Edition }
$script:TestWingetPresent = { return $script:State.Winget }
$script:GetWauProductCodes = { return $script:State.Codes }
$script:ProtectDirectory = { param($Path) $script:State.Protected++; return 0 }
$script:RetryDelay = { param($Seconds) $script:State.Sleeps++ }
$script:DownloadFile = {
    param($Url, $Destination)
    $script:State.Downloads++
    if ($script:State.Downloads -le $script:State.FailFirst) { throw (New-Object WauFakeHttpException 503) }
    [System.IO.File]::WriteAllBytes($Destination, $script:State.Bytes)
}
$script:InvokeMsiExec = {
    param($ArgumentList, $WorkingDirectory)
    $script:State.Msi.Add([pscustomobject]@{ Args = @($ArgumentList); Dir = $WorkingDirectory })
    return 0
}
$script:SetImeLogLink = { param($InstallLocation) $script:State.Linked = $InstallLocation; return 'linked' }
$script:SetWauMods = { param($InstallLocation) if ($script:State.ModsFail) { throw 'disk' }; $script:State.Modded = $InstallLocation }
$script:RemoveImeLogLink = { $script:State.Unlinked++ }

function Invoke-Install {
    param([string]$Action = 'Install', [string]$List = $ring, [string]$Sha = $payloadSha)
    return [int](Invoke-WauAction -DeploymentType 'Install' -Action $Action -PinVersion '2.12.0' -ListUrl $List -UpdatesAtTime '12:00:00' -AvdUpdatesAtTime '02:00:00' -InstallerUrl $pinnedUrl -InstallerSha256 $Sha -CancelPath '')
}

# Fresh PC install.
Reset-Fakes -Before $null -After (New-WauConfig -Properties $pcProps)
$code = Invoke-Install
if ($code -ne 0) { Fail "fresh install exited $code ($($script:WauErrorLog -join '; '))" }
if ($script:State.Downloads -ne 1 -or $script:State.Msi.Count -ne 1 -or $script:State.Protected -ne 1) { Fail 'fresh install did not download, protect and run msiexec once' }
$run = $script:State.Msi[0]
$runArgs = @($run.Args)
if ($runArgs[0] -cne '/i' -or $runArgs -notcontains 'UPDATESATLOGON=0' -or $runArgs -contains 'REINSTALL=ALL') { Fail "fresh install arguments: $($runArgs -join ' ')" }
if ([string]$run.Dir -notlike '*relian-wau-*' -or $runArgs[1] -cne ('"' + (Join-Path $run.Dir 'WAU.msi') + '"')) { Fail 'msiexec did not run from the protected cache' }
if (Test-Path -LiteralPath $run.Dir) { Fail 'cache was not removed' }
if ($script:State.Linked -cne 'C:\Program Files\Winget-AutoUpdate\') { Fail 'IME log link was not made' }
if ($script:State.Modded -cne 'C:\Program Files\Winget-AutoUpdate\') { Fail 'fresh install did not write the mods' }

# The mods are the running-app guard: no mods, no success.
Reset-Fakes -Before $null -After (New-WauConfig -Properties $pcProps)
$script:State.ModsFail = $true
if ((Invoke-Install) -ne 1) { Fail 'install passed although the mods were not written' }

# AVD host gets the multi-session properties.
Reset-Fakes -Before $null -After (New-WauConfig -Properties $avdProps) -Edition 'ServerRdsh'
if ((Invoke-Install) -ne 0) { Fail "AVD install failed ($($script:WauErrorLog -join '; '))" }
if ((@($script:State.Msi[0].Args) -join '|') -cne ((@('/i', ('"' + (Join-Path $script:State.Msi[0].Dir 'WAU.msi') + '"'), '/qn', '/norestart') + $expectedAvd[4..($expectedAvd.Count - 1)]) -join '|')) { Fail 'AVD install arguments' }

# Already right: nothing downloads.
Reset-Fakes -Before (New-WauConfig -Properties $pcProps) -After $null -Winget $false
if ((Invoke-Install) -ne 0 -or $script:State.Downloads -ne 0 -or $script:State.Msi.Count -ne 0) { Fail 'a matching install was touched' }
# A matching install from before the mods existed gets them, with no download.
if ($script:State.Modded -cne 'C:\Program Files\Winget-AutoUpdate\') { Fail 'a matching install did not get the mods' }

# Same version, other ring: reconfigure.
$early = Get-WauMsiProperties -MultiSession $false -ListUrl 'https://relianpub.blob.core.windows.net/pub/wau/early/' -UpdatesAtTime '12:00:00' -AvdUpdatesAtTime '02:00:00'
Reset-Fakes -Before (New-WauConfig -Properties $early) -After (New-WauConfig -Properties $pcProps)
if ((Invoke-Install) -ne 0 -or @($script:State.Msi[0].Args) -notcontains 'REINSTALL=ALL') { Fail 'ring change did not reconfigure' }

# Missing winget: retryable code, nothing downloads.
Reset-Fakes -Before $null -After $null -Winget $false
$code = Invoke-Install
if ($code -ne 1618 -or $script:State.Downloads -ne 0) { Fail "missing winget exited $code with $($script:State.Downloads) downloads" }

# Hash mismatch: exit 1, one download, no retry, no msiexec.
Reset-Fakes -Before $null -After $null -Bytes ($utf8.GetBytes('tampered'))
$code = Invoke-Install
if ($code -ne 1 -or $script:State.Downloads -ne 1 -or $script:State.Sleeps -ne 0 -or $script:State.Msi.Count -ne 0) { Fail "hash mismatch exited $code after $($script:State.Downloads) downloads" }
if (($script:WauErrorLog -join ';') -notmatch 'hash mismatch') { Fail 'hash mismatch was not reported' }

# A transient 503 is retried; the second download installs.
Reset-Fakes -Before $null -After (New-WauConfig -Properties $pcProps) -FailFirst 1
if ((Invoke-Install) -ne 0 -or $script:State.Downloads -ne 2 -or $script:State.Sleeps -ne 1) { Fail 'transient 503 was not retried once' }

# Bad list URLs: exit 1 before any read or download.
foreach ($bad in @($userInfoUrl, 'https://example.invalid/pub/wau/broad/', '')) {
    Reset-Fakes -Before $null -After $null
    $code = Invoke-Install -List $bad
    if ($code -ne 1 -or $script:State.Downloads -ne 0 -or $script:State.Reads -ne 0) { Fail "list URL '$bad' exited $code" }
}

# A WAU policy that overrides the MSI: msiexec succeeds, the package still fails.
$overridden = New-WauConfig -Properties $pcProps
$overridden['WAU_DisableAutoUpdate'] = 0
Reset-Fakes -Before $null -After $overridden
if ((Invoke-Install) -ne 1) { Fail 'a config that does not match after install passed' }

# msiexec failure.
Reset-Fakes -Before $null -After $null
$saved = $script:InvokeMsiExec
$script:InvokeMsiExec = { param($ArgumentList, $WorkingDirectory) return 1603 }
if ((Invoke-Install) -ne 1) { Fail 'msiexec 1603 passed' }
$script:InvokeMsiExec = $saved

# Empty hash: off switch, nothing read.
Reset-Fakes -Before $null -After $null
if ((Invoke-Install -Sha '') -ne 0 -or $script:State.Reads -ne 0) { Fail 'empty hash did something' }

# Uninstall by the UpgradeCode's product codes, then remove the log link. No list URL needed.
Reset-Fakes -Before (New-WauConfig -Properties $pcProps) -After $null
$code = [int](Invoke-WauAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.12.0' -ListUrl '' -UpdatesAtTime '' -AvdUpdatesAtTime '' -InstallerUrl $pinnedUrl -InstallerSha256 $payloadSha -CancelPath '')
if ($code -ne 0 -or $script:State.Downloads -ne 0 -or $script:State.Msi.Count -ne 1 -or $script:State.Unlinked -ne 1) { Fail "uninstall exited $code" }
if ((@($script:State.Msi[0].Args) -join '|') -cne '/x|{FB0EB14E-95AC-45D7-A951-432316FFCBD4}|/qn|/norestart') { Fail 'uninstall arguments' }
Reset-Fakes -Before $null -After $null
$code = [int](Invoke-WauAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.12.0' -ListUrl '' -UpdatesAtTime '' -AvdUpdatesAtTime '' -InstallerUrl $pinnedUrl -InstallerSha256 $payloadSha -CancelPath '')
if ($code -ne 0 -or $script:State.Msi.Count -ne 0) { Fail 'uninstall of an absent WAU ran msiexec' }

# The real log link hooks, on Windows only (CI runs this under Windows PowerShell 5.1, like Intune).
# The install runs with RUN_WAU=NO, so WAU's log does not exist yet when the link is made.
if ($env:OS -eq 'Windows_NT') {
    $savedProgramData = $env:ProgramData
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-link-' + [guid]::NewGuid().ToString('n'))
    try {
        $imeLogs = Join-Path $root 'Microsoft\IntuneManagementExtension\Logs'
        New-Item -ItemType Directory -Path $imeLogs -Force | Out-Null
        $install = Join-Path $root 'Program Files\Winget-AutoUpdate\'
        $env:ProgramData = $root
        $link = Join-Path $imeLogs 'WAU-updates.log'
        $target = Join-Path $install 'logs\updates.log'
        foreach ($pass in 1, 2) {
            # The second pass is a reconfigure over a link that still points at nothing.
            $result = & $realSetImeLogLink -InstallLocation $install
            if ($result -cne 'linked') { Fail "log link pass $pass returned '$result'" }
            $item = [System.IO.FileInfo]::new($link)
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { Fail "log link pass $pass is not a link" }
        }
        # WAU's first run writes the log; reading it through the link proves the target.
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [System.IO.File]::WriteAllText($target, 'first run')
        if ([System.IO.File]::ReadAllText($link) -cne 'first run') { Fail 'log link does not read the WAU log' }
        # Uninstall removes WAU's folder first, so the link points at nothing again.
        Remove-Item -LiteralPath (Join-Path $root 'Program Files') -Recurse -Force
        & $realRemoveImeLogLink
        if ($null -ne (Get-WauLinkAttributes -Path $link)) { Fail 'uninstall left a link to a missing log' }
        # A real file of that name is left alone.
        [System.IO.File]::WriteAllText($link, 'someone else')
        if ((& $realSetImeLogLink -InstallLocation $install) -cne 'skipped') { Fail 'a real file was replaced' }
        & $realRemoveImeLogLink
        if (-not [System.IO.File]::Exists($link)) { Fail 'uninstall removed a real file' }
    } finally {
        $env:ProgramData = $savedProgramData
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'wau-plan tests passed'
exit 0
