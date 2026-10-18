$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/notepadpp/Invoke-Notepadpp.ps1'
$releasePath = Join-Path $repoRoot 'releases/notepadpp.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Notepadpp.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/notepadpp.json does not exist'
}

$scriptText = [System.IO.File]::ReadAllText($scriptPath)
if ($scriptText -match '\[Parameter\(Mandatory\)\]' -or $scriptText -match 'Mandatory\s*=\s*\$true') {
    Fail 'a parameter is Mandatory'
}
if ($scriptText -match 'Ninja-Property') {
    Fail 'package calls Ninja'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Get-NotepadppPlan',
        'Invoke-NotepadppAction',
        'Save-NotepadppPayload',
        'Get-NotepadppInstallArgumentList',
        'Get-NotepadppUninstallArgumentList',
        'Get-NotepadppUninstallExe',
        'Test-NotepadppDownloadIsTransient',
        'Test-NotepadppPlaceholderHash',
        'Get-NotepadppHelpText',
        'Invoke-NotepadppEntry'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8.1/npp.8.9.8.1.Installer.x64.exe'
$pinnedSha = '26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da'
if ([string]$release.sourceUrl -cne $pinnedUrl) {
    Fail "source URL '$($release.sourceUrl)'"
}
if ([string]$release.sha256 -cne $pinnedSha) {
    Fail 'sha256 does not match the downloaded installer'
}
if ([int64]$release.size -ne 6963432) {
    Fail "size $($release.size)"
}
if ([string]$release.version -cne '8.9.8.1') {
    Fail "version '$($release.version)'"
}
if ([string]$release.arch -cne 'x64' -or [string]$release.file -cne 'npp.8.9.8.1.Installer.x64.exe') {
    Fail 'release arch or file name'
}
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match releases/notepadpp.json'
}
$script:PinnedSha = [string]$release.sha256
if (Test-NotepadppPlaceholderHash -Sha256 $script:PinnedSha) {
    Fail 'pinned sha256 was treated as a placeholder'
}
if (-not (Test-NotepadppPlaceholderHash -Sha256 $script:PinnedSha.ToUpperInvariant())) {
    Fail 'uppercase pin was accepted'
}
if (-not (Test-NotepadppPlaceholderHash -Sha256 ('a' * 64))) {
    Fail '64 identical characters were accepted'
}
if ($scriptText -notlike "*$pinnedUrl*" -or $scriptText -notlike "*$pinnedSha*") {
    Fail 'installer URL or sha256 is not inlined'
}

$builtinVersion = & $script:GetInstalledNotepadppVersion
$builtinUninstall = & $script:GetNotepadppUninstallPath
if ($builtinVersion -isnot [string] -or $builtinUninstall -isnot [string]) {
    Fail 'registry hooks did not return strings'
}

function Assert-Plan {
    param(
        $Plan,
        [hashtable]$Expect,
        [string]$Label
    )
    foreach ($name in @('ExitCode', 'RunInstaller', 'WriteMarker', 'ClearMarker', 'Log')) {
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
    if ([bool]$Plan.ClearMarker -ne [bool]$Expect.ClearMarker) {
        Fail "$Label ClearMarker '$($Plan.ClearMarker)' expected '$($Expect.ClearMarker)'"
    }
}

function New-Expect {
    param(
        $ExitCode = $null,
        [string]$RunInstaller = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false,
        [string]$Log = ''
    )
    return @{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        WriteMarker  = $WriteMarker
        ClearMarker  = $ClearMarker
        Log          = $Log
    }
}

$installRows = @(
    @{
        Label = 'empty pin'
        Pin = ''
        Installed = '9.0.0.0'
        Marker = '9.0.0.0'
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
        Pin = '2.0.0.0'
        Installed = ''
        Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'equal pin missing marker'
        Pin = '2.0.0.0'
        Installed = '2.0.0.0'
        Marker = ''
        Expect = (New-Expect -WriteMarker '2.0.0.0')
    }
    @{
        Label = 'vendor newer than pin'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '2.0.0.0'
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
    @{
        Label = 'vendor newer marker already advanced'
        Pin = '2.0.0.0'
        Installed = '3.0.0.0'
        Marker = '3.0.0.0'
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'older than pin'
        Pin = '2.0.0.0'
        Installed = '1.0.0.0'
        Marker = '1.0.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Install')
    }
    @{
        Label = 'unparseable installed version'
        Pin = '2.0.0.0'
        Installed = 'nope'
        Marker = ''
        Expect = (New-Expect -ExitCode 1)
    }
)

foreach ($row in $installRows) {
    foreach ($action in @('Install', 'Update')) {
        $plan = Get-NotepadppPlan -Action $action -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
        Assert-Plan -Plan $plan -Expect $row.Expect -Label "$action $($row.Label)"
    }
}

$whitespace = Get-NotepadppPlan -Action 'Repair' -PinVersion '   ' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $whitespace -Expect (New-Expect -ExitCode 0) -Label 'whitespace pin'

$reinstall = Get-NotepadppPlan -Action 'Reinstall' -PinVersion '1.0.0.0' -InstalledVersion '1.0.0.0' -MarkerVersion '1.0.0.0'
Assert-Plan -Plan $reinstall -Expect (New-Expect -ExitCode 1) -Label 'Reinstall'

$repairRows = @(
    @{
        Label = 'Repair missing app'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair equal'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair older than pin'
        Pin = '2.0.0.0'; Installed = '1.0.0.0'; Marker = '1.0.0.0'
        Expect = (New-Expect -RunInstaller 'install' -Log 'Repair')
    }
    @{
        Label = 'Repair vendor newer'
        Pin = '2.0.0.0'; Installed = '3.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -WriteMarker '3.0.0.0')
    }
)
foreach ($row in $repairRows) {
    $plan = Get-NotepadppPlan -Action 'Repair' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$uninstallRows = @(
    @{
        Label = 'Uninstall app'
        Pin = '2.0.0.0'; Installed = '2.0.0.0'; Marker = '2.0.0.0'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall marker only'
        Pin = '2.0.0.0'; Installed = ''; Marker = '2.0.0.0'
        Expect = (New-Expect -ClearMarker $true -Log 'Uninstall')
    }
    @{
        Label = 'Uninstall nothing'
        Pin = '2.0.0.0'; Installed = ''; Marker = ''
        Expect = (New-Expect -ExitCode 0)
    }
    @{
        Label = 'Uninstall unparseable version'
        Pin = '2.0.0.0'; Installed = 'nope'; Marker = 'old'
        Expect = (New-Expect -RunInstaller 'uninstall' -ClearMarker $true -Log 'Uninstall')
    }
)
foreach ($row in $uninstallRows) {
    $plan = Get-NotepadppPlan -Action 'Uninstall' -PinVersion $row.Pin -InstalledVersion $row.Installed -MarkerVersion $row.Marker
    Assert-Plan -Plan $plan -Expect $row.Expect -Label $row.Label
}

$unknown = Get-NotepadppPlan -Action 'Nope' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerVersion ''
Assert-Plan -Plan $unknown -Expect (New-Expect -ExitCode 1) -Label 'unknown action'

$installArgs = @(Get-NotepadppInstallArgumentList)
if ($installArgs.Count -ne 2 -or $installArgs[0] -cne '/S' -or $installArgs[1] -cne '/noUpdater') {
    Fail "install arguments $($installArgs -join ' ')"
}
foreach ($forbidden in @('/runNppAfterSilentInstall', '/relaunchNppAfterSilentInstall', '/closeRunningNpp')) {
    if ($installArgs -contains $forbidden) {
        Fail "install arguments include $forbidden"
    }
}
$removePath = 'C:\Program Files\Notepad++\uninstall.exe'
$removeArgs = @(Get-NotepadppUninstallArgumentList -UninstallPath $removePath)
if ($removeArgs.Count -ne 1 -or $removeArgs[0] -cne '/S') {
    Fail "uninstall arguments $($removeArgs -join ' ')"
}
if ($null -ne (Get-NotepadppUninstallArgumentList -UninstallPath '')) {
    Fail 'uninstall without a program built arguments'
}
$quoted = Get-NotepadppUninstallExe -Text ('"' + $removePath + '" /S')
if ($quoted -cne $removePath) {
    Fail "quoted uninstall path '$quoted'"
}
if (-not (Test-NotepadppSetupSucceeded -Code 0)) {
    Fail 'setup exit 0 was not success'
}
if (Test-NotepadppSetupSucceeded -Code 3010) {
    Fail 'setup exit 3010 was treated as success'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('notepadpp-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}
if (Test-NotepadppPlaceholderHash -Sha256 $script:GoodSha) {
    Fail 'fixture sha256 was treated as a placeholder'
}

function New-NotepadppUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/npp.exe')
}

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('notepadpp-plan-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:MarkerRoot = Join-Path $script:Root 'marker'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:SetupCalls = [System.Collections.Generic.List[object]]::new()

function Reset-NotepadppCase {
    $script:DownloadCount = 0
    $script:Sleeps = [System.Collections.Generic.List[int]]::new()
    $script:SetupCalls = [System.Collections.Generic.List[object]]::new()
    $script:NotepadppErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = ''
    $script:UninstallPath = 'C:\Program Files\Notepad++\uninstall.exe'
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:MarkerRoot) {
        Remove-Item -LiteralPath $script:MarkerRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    $script:RetryDelay = {
        param($Seconds)
        $script:Sleeps.Add([int]$Seconds)
    }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $script:GetInstalledNotepadppVersion = {
        return [string]$script:InstalledVersion
    }
    $script:GetNotepadppUninstallPath = {
        return [string]$script:UninstallPath
    }
    $script:InvokeNotepadppSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $existed = $false
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            $existed = Test-Path -LiteralPath $InstallerPath
        }
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = [bool]$existed
            })
        return 0
    }
}

function Set-Marker {
    param([string]$Version)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $script:MarkerRoot 'marker.txt'), $Version, $utf8NoBom)
}

function Invoke-Case {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl = 'https://example.invalid/npp.exe',
        [string]$InstallerSha256 = $script:PinnedSha,
        [string]$CancelPath = ''
    )
    return [int](Invoke-NotepadppAction -DeploymentType $Action -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -MarkerRoot $script:MarkerRoot)
}

function Assert-Case {
    param(
        [int]$Code,
        [int]$ExpectCode,
        [int]$ExpectDownloads,
        [int]$ExpectSleeps,
        [int]$ExpectSetup,
        [string]$ExpectMarker = '',
        [bool]$MarkerAbsent = $false,
        [string]$Label
    )
    if ($Code -ne $ExpectCode) {
        Fail "$Label exit $Code expected $ExpectCode"
    }
    if ($script:DownloadCount -ne $ExpectDownloads) {
        Fail "$Label downloads $($script:DownloadCount) expected $ExpectDownloads"
    }
    if ($script:Sleeps.Count -ne $ExpectSleeps) {
        Fail "$Label sleeps $($script:Sleeps.Count) expected $ExpectSleeps"
    }
    if ($script:SetupCalls.Count -ne $ExpectSetup) {
        Fail "$Label setup $($script:SetupCalls.Count) expected $ExpectSetup"
    }
    $path = Join-Path $script:MarkerRoot 'marker.txt'
    $exists = Test-Path -LiteralPath $path
    if ($MarkerAbsent) {
        if ($exists) {
            Fail "$Label left a marker"
        }
    } else {
        if (-not $exists) {
            Fail "$Label did not write a marker"
        }
        $text = ([System.IO.File]::ReadAllText($path)).Trim()
        if ($text -cne $ExpectMarker) {
            Fail "$Label marker '$text' expected '$ExpectMarker'"
        }
    }
    if (($script:NotepadppErrorLog -join "`n") -like '*https://*') {
        Fail "$Label error included a URL"
    }
}

function Assert-Log {
    param(
        [string]$Expected = '',
        [bool]$Absent = $false,
        [string]$Label
    )
    $path = Join-Path $script:MarkerRoot 'toolkit.log'
    $exists = Test-Path -LiteralPath $path
    if ($Absent) {
        if ($exists) {
            $text = [System.IO.File]::ReadAllText($path)
            Fail "$Label logged '$text'"
        }
        return
    }
    if (-not $exists) {
        Fail "$Label did not write a log"
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ($text -cne $Expected) {
        Fail "$Label log '$text' expected '$Expected'"
    }
}

function Invoke-NotepadppFile {
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
    foreach ($arg in @($ArgumentList)) {
        $psi.ArgumentList.Add([string]$arg)
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
            try {
                $proc.Kill($true)
            } catch {
                try { $proc.Kill() } catch { }
            }
            Fail 'help process timed out'
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $stdoutTask.Result
            Stderr   = $stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

try {
    Reset-NotepadppCase
    Set-Marker '9.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'empty pin'
    Assert-Log -Absent $true -Label 'empty pin'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerUrl (New-NotepadppUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'userinfo'
    if (($script:NotepadppErrorLog -join "`n") -notlike '*userinfo*') {
        Fail 'userinfo error did not name userinfo'
    }
    Assert-Log -Absent $true -Label 'userinfo'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other-bytes'))
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:PinnedSha
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'hash mismatch'
    Assert-Log -Absent $true -Label 'hash mismatch'

    foreach ($action in @('Install', 'Update')) {
        Reset-NotepadppCase
        $script:InstalledVersion = '3.0.0.0'
        Set-Marker '2.0.0.0'
        $code = Invoke-Case -Action $action -PinVersion '2.0.0.0'
        Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label "$action vendor newer"
        Assert-Log -Absent $true -Label "$action vendor newer"
    }

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerUrl (New-NotepadppUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 1 -MarkerAbsent $true -Label 'uninstall'
    if ($script:SetupCalls[0].Mode -cne 'uninstall' -or $script:SetupCalls[0].UninstallPath -cne $script:UninstallPath) {
        Fail 'uninstall did not pass the uninstall program'
    }
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '' -InstallerUrl (New-NotepadppUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall empty hash'
    Assert-Log -Absent $true -Label 'uninstall empty hash'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:GetInstalledNotepadppVersion = { throw 'registry failed' }
    $script:GetNotepadppUninstallPath = { throw 'registry failed' }
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 '   '
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall whitespace hash'
    Assert-Log -Absent $true -Label 'uninstall whitespace hash'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'uninstall marker only'
    Assert-Log -Expected "Uninstall`n" -Label 'uninstall marker only'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall marker empty hash'
    Assert-Log -Absent $true -Label 'uninstall marker empty hash'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:UninstallPath = ''
    $code = Invoke-Case -Action 'Uninstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'uninstall missing program'
    Assert-Log -Absent $true -Label 'uninstall missing program'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair missing'
    if ($script:SetupCalls[0].Mode -cne 'install' -or -not $script:SetupCalls[0].InstallerExisted) {
        Fail 'Repair missing did not run the installer file'
    }
    Assert-Log -Expected "Repair`n" -Label 'Repair missing'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'Repair present'
    if ($script:SetupCalls[0].Mode -cne 'install') {
        Fail 'Repair present did not run the installer again'
    }
    Assert-Log -Expected "Repair`n" -Label 'Repair present'

    Reset-NotepadppCase
    $script:InstalledVersion = '3.0.0.0'
    Set-Marker '2.0.0.0'
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '3.0.0.0' -Label 'Repair vendor newer'
    Assert-Log -Absent $true -Label 'Repair vendor newer'

    Reset-NotepadppCase
    $script:InstalledVersion = '1.0.0.0'
    Set-Marker '1.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'older install'
    Assert-Log -Expected "Install`n" -Label 'older install'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'equal pin missing marker'
    Assert-Log -Absent $true -Label 'equal pin missing marker'

    Reset-NotepadppCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall'
    Assert-Log -Absent $true -Label 'Reinstall'

    Reset-NotepadppCase
    Set-Marker '2.0.0.0'
    $script:InstalledVersion = '2.0.0.0'
    $code = Invoke-Case -Action 'Reinstall' -PinVersion '2.0.0.0' -InstallerSha256 ''
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '2.0.0.0' -Label 'Reinstall empty hash'
    Assert-Log -Absent $true -Label 'Reinstall empty hash'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $env:RELIAN_DEPLOY_CANCEL = '1'
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0'
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel env'
    Assert-Log -Absent $true -Label 'cancel env'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $cancel = Join-Path $script:Root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -CancelPath $cancel
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel path'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha -CancelPath (Join-Path $script:Root 'missing-cancel')
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'missing cancel path'
    Assert-Log -Expected "Install`n" -Label 'missing cancel path'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
        $env:RELIAN_DEPLOY_CANCEL = '1'
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 130 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'cancel before setup'
    Assert-Log -Absent $true -Label 'cancel before setup'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $script:InvokeNotepadppSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = (Test-Path -LiteralPath $InstallerPath)
            })
        $env:RELIAN_DEPLOY_CANCEL = '1'
        return 0
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'cancel during setup'
    Assert-Log -Expected "Install`n" -Label 'cancel during setup'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $script:InvokeNotepadppSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = $true
            })
        return 1
    }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -MarkerAbsent $true -Label 'setup failure'
    Assert-Log -Absent $true -Label 'setup failure'

    Reset-NotepadppCase
    $script:InstalledVersion = '2.0.0.0'
    Set-Marker '2.0.0.0'
    $script:InvokeNotepadppSetup = {
        param($Mode, $InstallerPath, $UninstallPath)
        $script:SetupCalls.Add([pscustomobject]@{
                Mode             = [string]$Mode
                UninstallPath    = [string]$UninstallPath
                InstallerExisted = $true
            })
        return 5
    }
    $code = Invoke-Case -Action 'Repair' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 1 -ExpectSleeps 0 -ExpectSetup 1 -ExpectMarker '2.0.0.0' -Label 'setup exit 5'
    Assert-Log -Absent $true -Label 'setup exit 5'

    Reset-NotepadppCase
    Set-Marker '9.0.0.0'
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 '' -InstallerUrl (New-NotepadppUserInfoUrl)
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'empty hash install'
    Assert-Log -Absent $true -Label 'empty hash install'

    Reset-NotepadppCase
    Set-Marker '9.0.0.0'
    $script:GetInstalledNotepadppVersion = { throw 'registry failed' }
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 '   '
    Assert-Case -Code $code -ExpectCode 0 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -ExpectMarker '9.0.0.0' -Label 'whitespace hash install'
    Assert-Log -Absent $true -Label 'whitespace hash install'

    Reset-NotepadppCase
    $script:InstalledVersion = ''
    $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $script:GoodSha.ToUpperInvariant()
    Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label 'uppercase hash'
    Assert-Log -Absent $true -Label 'uppercase hash'

    $placeholders = @(
        @{ Label = '64 a'; Hash = ('a' * 64) }
        @{ Label = '64 A'; Hash = ('A' * 64) }
        @{ Label = '64 zero'; Hash = ('0' * 64) }
        @{ Label = '64 f'; Hash = ('f' * 64) }
        @{ Label = '64 F'; Hash = ('F' * 64) }
        @{ Label = '64 g'; Hash = ('g' * 64) }
        @{ Label = 'word'; Hash = 'placeholder' }
        @{ Label = 'short hex'; Hash = ('ab' * 31) }
    )
    foreach ($row in $placeholders) {
        Reset-NotepadppCase
        $script:InstalledVersion = ''
        $code = Invoke-Case -Action 'Install' -PinVersion '2.0.0.0' -InstallerSha256 $row.Hash
        Assert-Case -Code $code -ExpectCode 1 -ExpectDownloads 0 -ExpectSleeps 0 -ExpectSetup 0 -MarkerAbsent $true -Label "placeholder $($row.Label)"
        if (($script:NotepadppErrorLog -join "`n") -notlike '*placeholder*') {
            Fail "placeholder $($row.Label) error did not name placeholder"
        }
        Assert-Log -Absent $true -Label "placeholder $($row.Label)"
    }

    Reset-NotepadppCase
    Set-Marker '9.0.0.0'
    $script:InstalledVersion = ''
    $helpBound = @{
        DeploymentType   = 'Install'
        Action           = 'Install'
        PinVersion       = '8.9.8.1'
        InstallerUrl     = 'https://example.invalid/npp.exe'
        InstallerSha256  = $script:PinnedSha
    }
    $helpEntry = Invoke-NotepadppEntry -Help -DeploymentType 'Install' -Action 'Install' -PinVersion '8.9.8.1' -InstallerUrl 'https://example.invalid/npp.exe' -InstallerSha256 $script:PinnedSha -MarkerRoot $script:MarkerRoot -Bound $helpBound
    if ([int]$helpEntry.ExitCode -ne 0) {
        Fail "help entry exited $($helpEntry.ExitCode)"
    }
    if ([string]$helpEntry.Help -cne (Get-NotepadppHelpText)) {
        Fail 'help entry text did not match'
    }
    if ($script:DownloadCount -ne 0 -or $script:SetupCalls.Count -ne 0) {
        Fail 'help entry downloaded or ran the installer'
    }
    $helpMarker = ([System.IO.File]::ReadAllText((Join-Path $script:MarkerRoot 'marker.txt'))).Trim()
    if ($helpMarker -cne '9.0.0.0') {
        Fail 'help entry changed the marker'
    }

    $helpProc = Invoke-NotepadppFile -ArgumentList @(
        '-Help',
        '-DeploymentType', 'Install',
        '-Action', 'Install',
        '-PinVersion', '8.9.8.1',
        '-InstallerUrl', 'https://example.invalid/npp.exe',
        '-InstallerSha256', $script:PinnedSha
    )
    $helpOut = ([string]$helpProc.Stdout).Replace("`r`n", "`n").Trim()
    $helpErr = ([string]$helpProc.Stderr).Trim()
    if ([int]$helpProc.ExitCode -ne 0) {
        Fail "help exited $($helpProc.ExitCode): $helpErr"
    }
    if ($helpOut -cne (Get-NotepadppHelpText)) {
        Fail "help output '$helpOut'"
    }
    if ($helpErr -like '*download*' -or $helpErr -like '*installer*') {
        Fail "help wrote '$helpErr'"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'notepadpp-plan tests passed'
exit 0
