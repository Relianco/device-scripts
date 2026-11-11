$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Upgrade (service stop), fresh-install registration, key redaction and Section Evidence.
# Mocks only. No network, no service, no msiexec.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/autoelevate/Invoke-AutoElevate.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @('Get-AutoElevateRegistrationProperties', 'Stop-AutoElevateServices', 'Get-AutoElevateEvidence', 'ConvertTo-AutoElevateRedacted')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$scriptParams = @((Get-Command $scriptPath).Parameters.Keys)
foreach ($name in @('Section', 'CompanyName', 'CompanyInitials', 'LocationName', 'ElevationMode', 'LicenseKey')) {
    if ($scriptParams -notcontains $name) {
        Fail "script has no parameter $name"
    }
}

# A fake key. Built at run time so the repo holds no key-shaped literal.
$script:Key = -join @('TESTKEY', '0123456789', 'ABCDEF')
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('autoelevate-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
$script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()
$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('autoelevate-upgrade-' + [guid]::NewGuid().ToString('n'))
$script:MarkerRoot = Join-Path $script:Root 'marker'

function Reset-Case {
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:MsiArgs = $null
    $script:AutoElevateErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:InstalledVersion = '2.8.2'
    $script:AfterVersion = '2.11.1959'
    $script:Registered = $true
    $script:ServiceState = @{ AutoElevateAgent = 'Running'; AEDelayedStartService = 'Running' }
    $script:StopIgnored = @()
    $script:StartAfterInstall = 'Running'
    if (Test-Path -LiteralPath $script:MarkerRoot) {
        Remove-Item -LiteralPath $script:MarkerRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:MarkerRoot -Force | Out-Null
    $script:RetryDelay = { param($Seconds) }
    $script:ServiceWait = { param($Seconds) $script:Calls.Add('wait') }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:Calls.Add('download')
        [System.IO.File]::WriteAllBytes($Destination, $script:GoodBytes)
    }
    $script:GetInstalledAutoElevateVersion = { return [string]$script:InstalledVersion }
    $script:GetAutoElevateProductCode = { return '{11111111-2222-3333-4444-555555555555}' }
    $script:GetAutoElevateRegistration = {
        $values = [ordered]@{}
        if ($script:Registered) {
            $values.CompanyName = 'Example Company'
            $values.LocationName = 'Main Office'
        }
        return [pscustomobject]@{ Values = $values; HasLicenseKey = [bool]$script:Registered; HasSettings = [bool]$script:Registered }
    }
    $script:GetAutoElevateService = {
        param($Name)
        if (-not $script:ServiceState.ContainsKey($Name)) { return $null }
        return [pscustomobject]@{ Name = $Name; Status = $script:ServiceState[$Name]; StartType = 'Auto'; CanStop = $false; ProcessId = 4242; Recovery = 'restart, restart, restart' }
    }
    $script:StopAutoElevateService = {
        param($Name)
        $script:Calls.Add("stop $Name")
        if ($script:StopIgnored -notcontains $Name) { $script:ServiceState[$Name] = 'Stopped' }
    }
    $script:StartAutoElevateService = {
        param($Name)
        $script:Calls.Add("start $Name")
        $script:ServiceState[$Name] = 'Running'
    }
    $script:InvokeMsiExec = {
        param($Mode, $ArgumentList)
        $script:Calls.Add("msiexec $Mode")
        $script:MsiArgs = @($ArgumentList)
        $script:InstalledVersion = $script:AfterVersion
        if ($script:ServiceState.ContainsKey('AutoElevateAgent') -or $Mode -eq 'install') {
            $script:ServiceState['AutoElevateAgent'] = $script:StartAfterInstall
        }
        return 0
    }
}

function Invoke-Case {
    param([string]$Action = 'Install', [string]$LicenseKey = '', [string]$CompanyName = '', [string]$CompanyInitials = '', [string]$LocationName = '', [string]$ElevationMode = '')
    return [int](Invoke-AutoElevateAction -DeploymentType 'Install' -Action $Action -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot -LicenseKey $LicenseKey -CompanyName $CompanyName -CompanyInitials $CompanyInitials -LocationName $LocationName -ElevationMode $ElevationMode)
}

function Get-AllText {
    $report = ConvertTo-Json -InputObject $script:AutoElevateReport -Depth 6 -Compress
    $logs = ''
    foreach ($file in @(Get-ChildItem -LiteralPath $script:MarkerRoot -File -ErrorAction SilentlyContinue)) {
        $logs += [System.IO.File]::ReadAllText($file.FullName)
    }
    return ($script:AutoElevateErrorLog -join "`n") + "`n" + $report + "`n" + $logs
}

try {
    # 1. Upgrade: both services stop before msiexec, no key needed, registration kept.
    Reset-Case
    $code = Invoke-Case
    if ($code -ne 0) { Fail "upgrade exit $code errors $($script:AutoElevateErrorLog -join '; ')" }
    $msiAt = $script:Calls.IndexOf('msiexec install')
    $stopAt = $script:Calls.IndexOf('stop AutoElevateAgent')
    $stopDelayedAt = $script:Calls.IndexOf('stop AEDelayedStartService')
    if ($stopAt -lt 0 -or $stopDelayedAt -lt 0 -or $msiAt -lt $stopAt -or $msiAt -lt $stopDelayedAt) {
        Fail "upgrade order: $($script:Calls -join ', ')"
    }
    if (($script:MsiArgs -join ' ') -match 'LICENSE_KEY|COMPANY_NAME|LOCATION_NAME') {
        Fail "upgrade passed registration properties: $($script:MsiArgs -join ' ')"
    }
    # The MSI loads the stored key into LICENSE_KEY_REG, so no verbose log on an upgrade either.
    if (($script:MsiArgs -join ' ') -match '/l') {
        Fail 'upgrade wrote an msiexec log'
    }
    if ([string]$script:AutoElevateReport.Service -cne 'Running' -or [string]$script:AutoElevateReport.Version -cne '2.11.1959.0') {
        Fail "upgrade report: $(ConvertTo-Json -InputObject $script:AutoElevateReport -Compress)"
    }

    # 2. A service that will not stop: report why, exit 1, msiexec not run, stopped ones restarted.
    Reset-Case
    $script:StopIgnored = @('AutoElevateAgent')
    $code = Invoke-Case
    if ($code -ne 1) { Fail "stop failure exit $code" }
    if ($script:Calls -contains 'msiexec install') { Fail 'stop failure ran msiexec' }
    $waits = @($script:Calls | Where-Object { $_ -eq 'wait' }).Count
    if ($waits -lt 1 -or $waits -gt 120) { Fail "stop failure waited $waits times" }
    $err = $script:AutoElevateErrorLog -join "`n"
    foreach ($part in @('AutoElevateAgent', 'Running', 'Auto', '4242', 'restart')) {
        if ($err -notlike "*$part*") { Fail "stop failure error lacks $part : $err" }
    }
    if ($script:Calls -notcontains 'start AEDelayedStartService') { Fail 'stop failure left the stopped service down' }

    # 3. Fresh install without a key refuses before any download.
    Reset-Case
    $script:InstalledVersion = ''
    $script:Registered = $false
    $script:ServiceState = @{}
    $code = Invoke-Case -CompanyName 'Example Company' -LocationName 'Main Office'
    if ($code -ne 1) { Fail "fresh without key exit $code" }
    if ($script:Calls -contains 'download') { Fail 'fresh without key downloaded' }
    if (($script:AutoElevateErrorLog -join ' ') -notlike '*AE_LICENSE_KEY*') { Fail 'fresh without key did not name AE_LICENSE_KEY' }

    # 4. Installed but not registered takes the fresh path too.
    Reset-Case
    $script:Registered = $false
    $code = Invoke-Case
    if ($code -ne 1 -or $script:Calls -contains 'download') { Fail "unregistered upgrade without key exit $code" }

    # 5. Fresh install with key: properties passed, key redacted everywhere, no msiexec log.
    Reset-Case
    $script:InstalledVersion = ''
    $script:Registered = $false
    $script:ServiceState = @{}
    $code = Invoke-Case -LicenseKey $script:Key -CompanyName 'Example Co, Inc.' -CompanyInitials 'EC' -LocationName 'Main Office' -ElevationMode 'live'
    if ($code -ne 0) { Fail "fresh with key exit $code errors $($script:AutoElevateErrorLog -join '; ')" }
    $joined = $script:MsiArgs -join ' '
    foreach ($want in @("LICENSE_KEY=`"$($script:Key)`"", 'COMPANY_NAME="Example Co, Inc."', 'COMPANY_INITIALS="EC"', 'LOCATION_NAME="Main Office"', 'ELEVATION_MODE="live"')) {
        if (-not $joined.Contains($want)) { Fail "fresh args lack $want" }
    }
    if ($joined -match '/l\*v') { Fail 'fresh install with a key wrote an msiexec log' }
    $text = Get-AllText
    if ($text.Contains($script:Key)) { Fail 'key appeared in output, report or logs' }
    if (-not ([string]$script:AutoElevateReport.MsiCommand).Contains('LICENSE_KEY="[redacted]"')) { Fail "report command not redacted: $($script:AutoElevateReport.MsiCommand)" }

    # 6. Key leak through a failing msiexec is redacted too.
    Reset-Case
    $script:Registered = $false
    $script:InvokeMsiExec = { param($Mode, $ArgumentList) $script:Calls.Add('msiexec'); return 1603 }
    $code = Invoke-Case -LicenseKey $script:Key -CompanyName 'Example Company' -LocationName 'Main Office'
    if ($code -ne 1) { Fail "msiexec 1603 exit $code" }
    if ((Get-AllText).Contains($script:Key)) { Fail 'key appeared after msiexec failure' }
    if ($script:Calls -notcontains 'start AutoElevateAgent') { Fail 'msiexec failure did not restart the agent' }

    # 7. Validation: bad values exit 1 before download, the value is not echoed.
    $bad = @(
        @{ LicenseKey = $script:Key; CompanyName = 'Bad"Name'; LocationName = 'Main' },
        @{ LicenseKey = $script:Key; CompanyName = ('x' * 101); LocationName = 'Main' },
        @{ LicenseKey = $script:Key; CompanyName = 'Example'; LocationName = 'Main;del' },
        @{ LicenseKey = $script:Key; CompanyName = 'Example'; LocationName = 'Main'; CompanyInitials = 'TOOLONGX' },
        @{ LicenseKey = $script:Key; CompanyName = 'Example'; LocationName = 'Main'; ElevationMode = 'Live' },
        @{ LicenseKey = $script:Key; CompanyName = 'Example'; LocationName = 'Main'; ElevationMode = 'off' },
        @{ LicenseKey = ($script:Key + '" X="1'); CompanyName = 'Example'; LocationName = 'Main' },
        @{ LicenseKey = $script:Key; CompanyName = 'Example' },
        @{ CompanyName = 'Example'; LocationName = 'Main'; ElevationMode = 'live' }
    )
    foreach ($case in $bad) {
        Reset-Case
        $script:InstalledVersion = ''
        $script:Registered = $false
        $code = Invoke-Case @case
        $label = ($case.Keys | Sort-Object | ForEach-Object { "$_" }) -join ','
        if ($code -ne 1 -or $script:Calls -contains 'download') { Fail "validation [$label] exit $code" }
        if ((Get-AllText).Contains($script:Key)) { Fail "validation [$label] echoed the key" }
    }
    foreach ($mode in @('audit', 'live', 'policy')) {
        $ok = Get-AutoElevateRegistrationProperties -LicenseKey $script:Key -CompanyName 'Example' -CompanyInitials '' -LocationName 'Main' -ElevationMode $mode -Registered $false
        if ($null -ne $ok.ExitCode) { Fail "ElevationMode $mode refused" }
    }

    # 8. After install: service not running or version below the pin exits 1.
    Reset-Case
    $script:StartAfterInstall = 'Stopped'
    $script:StartAutoElevateService = { param($Name) $script:Calls.Add("start $Name") }
    $code = Invoke-Case
    if ($code -ne 1 -or [string]$script:AutoElevateReport.Service -cne 'Stopped') { Fail "service down after install exit $code" }
    Reset-Case
    $script:AfterVersion = '2.8.2'
    $code = Invoke-Case
    if ($code -ne 1) { Fail "version below pin after install exit $code" }

    # 8b. Key precedence: a non-empty LicenseKey argument wins, else AE_LICENSE_KEY.
    $envKey = 'ENVKEY-0000-ENVKEY'
    $env:AE_LICENSE_KEY = $envKey
    try {
        if ((Select-AutoElevateKey -Argument $script:Key) -cne $script:Key) { Fail 'argument key did not win over the environment' }
        if ((Select-AutoElevateKey -Argument '') -cne $envKey) { Fail 'empty argument did not fall back to the environment' }
        if ((Select-AutoElevateKey -Argument '  ') -cne $envKey) { Fail 'blank argument did not fall back to the environment' }
    } finally {
        Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    }
    if ((Select-AutoElevateKey -Argument '') -cne '') { Fail 'no argument and no environment did not give an empty key' }
    # The argument key reaches the msiexec plan, and is redacted from the printed text.
    Reset-Case
    $code = Invoke-Case -LicenseKey (Select-AutoElevateKey -Argument $script:Key) -CompanyName 'Example Co' -LocationName 'Main Office'
    if ($code -ne 0) { Fail "install with an argument key exit $code" }
    if (-not ($script:Calls -join ' ').Contains('msiexec install')) { Fail 'argument key install did not run msiexec' }
    if ((Get-AllText).Contains($script:Key)) { Fail 'argument key appeared in output, report or logs' }

    # 9. Redaction helper.
    $red = ConvertTo-AutoElevateRedacted -Text "/i x.msi LICENSE_KEY=`"$($script:Key)`" COMPANY_NAME=`"A`""
    if ($red.Contains($script:Key) -or $red -notlike '*COMPANY_NAME="A"*') { Fail "redaction: $red" }

    # 10. Evidence is read-only and never returns the key.
    Reset-Case
    $script:GetAutoElevateRegistration = {
        return [pscustomobject]@{ Values = [ordered]@{ CompanyName = 'Example Company'; CompanyInitials = 'EC'; LocationName = 'Main Office'; InstallationDirectory = 'C:\Program Files (x86)\AutoElevate\' }; HasLicenseKey = $true; HasSettings = $true }
    }
    $script:GetAutoElevateMsiEvents = { return @([pscustomobject]@{ TimeCreated = '2026-11-09T10:00:00Z'; Id = 11921; Message = "Error 1921 LICENSE_KEY=$($script:Key)" }) }
    $script:GetAutoElevateProcesses = { return @('AEAlert') }
    $evidence = Get-AutoElevateEvidence
    $json = ConvertTo-Json -InputObject $evidence -Depth 6 -Compress
    if ($script:Calls.Count -ne 0) { Fail "evidence changed something: $($script:Calls -join ', ')" }
    if ($json.Contains($script:Key)) { Fail 'evidence leaked the key' }
    foreach ($want in @('"Version":"2.8.2.0"', 'Example Company', 'Main Office', '"LicenseKey":"present"', '"Registered":true', 'AutoElevateAgent', '11921', 'AEAlert')) {
        if (-not $json.Contains($want)) { Fail "evidence lacks $want : $json" }
    }

    # 11. Paths with spaces stay one argument once Start-Process joins the array.
    $spaced = 'C:\Windows\Temp\dir with space\AESetup.msi'
    $props = @("LICENSE_KEY=`"$($script:Key)`"", 'COMPANY_NAME="Example Company"')
    $flat = (Get-AutoElevateMsiArgumentList -Mode 'install' -InstallerPath $spaced -ProductCode '' -Properties $props) -join ' '
    if (-not $flat.StartsWith("/i `"$spaced`" /quiet /norestart")) { Fail "spaced installer path: $flat" }
    if ((ConvertTo-AutoElevateRedacted -Text $flat).Contains($script:Key)) { Fail 'flattened arguments kept the key after redaction' }

    # 14. msiexec throwing after the stop still restores the services, on install and uninstall.
    foreach ($action in @('Install', 'Uninstall')) {
        Reset-Case
        $script:InvokeMsiExec = { param($Mode, $ArgumentList) $script:Calls.Add("msiexec $Mode"); throw 'start failed' }
        $code = [int](Invoke-AutoElevateAction -DeploymentType $action -Action $action -PinVersion '2.11.1959' -InstallerUrl 'https://example.invalid/AESetup.msi' -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot)
        if ($code -ne 1) { Fail "$action msiexec throw exit $code" }
        foreach ($name in @('AEDelayedStartService', 'AutoElevateAgent')) {
            if ($script:Calls -notcontains "start $name" -or $script:ServiceState[$name] -ne 'Running') { Fail "$action msiexec throw left $name stopped: $($script:Calls -join ', ')" }
        }
    }

    # 12. Userinfo is refused only where the installer is downloaded.
    $userInfoUrl = -join @('https://', 'user', '@', 'example.invalid/AESetup.msi')
    Reset-Case
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Uninstall' -Action 'Uninstall' -PinVersion '2.11.1959' -InstallerUrl $userInfoUrl -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot)
    if ($code -ne 0 -or $script:Calls -notcontains 'msiexec uninstall' -or $script:Calls -contains 'download') { Fail "uninstall with a userinfo URL exit $code calls $($script:Calls -join ', ')" }
    Reset-Case
    $code = [int](Invoke-AutoElevateAction -DeploymentType 'Install' -Action 'Install' -PinVersion '2.11.1959' -InstallerUrl $userInfoUrl -InstallerSha256 $script:GoodSha -CancelPath '' -MarkerRoot $script:MarkerRoot)
    if ($code -ne 1 -or $script:Calls.Count -ne 0) { Fail "install with a userinfo URL exit $code calls $($script:Calls -join ', ')" }

    # 13. The script entry point, as the runner starts it. Uninstall only off Windows, so no agent is touched.
    $pwsh = (Get-Process -Id $PID).Path
    $childRoot = Join-Path $script:Root 'child'
    function Invoke-Child {
        param([string[]]$Arguments)
        $output = & $pwsh -NoProfile -File $scriptPath -DeploymentType Install -PinVersion '2.11.1959' -MarkerRoot $childRoot @Arguments 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($output) -join "`n") }
    }
    $run = Invoke-Child -Arguments @('-Action', 'Install', '-InstallerUrl', $userInfoUrl, '-InstallerSha256', '')
    if ($run.Code -ne 0 -or $run.Text -ne '') { Fail "empty hash with a userinfo URL: exit $($run.Code) [$($run.Text)]" }
    $run = Invoke-Child -Arguments @('-Action', 'Install', '-InstallerUrl', $userInfoUrl, '-Section', 'Evidence')
    if ($run.Code -ne 0 -or $run.Text -notlike '*"Section":"Evidence"*') { Fail "evidence with a userinfo URL: exit $($run.Code) [$($run.Text)]" }
    $env:AE_LICENSE_KEY = $script:Key
    try {
        $run = Invoke-Child -Arguments @('-Action', 'Install', '-Section', 'Evidence')
        if ($run.Code -ne 0 -or $run.Text.Contains($script:Key)) { Fail "evidence with AE_LICENSE_KEY set: exit $($run.Code)" }
    } finally {
        Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    }
    $run = Invoke-Child -Arguments @('-Action', 'Install', '-Section', 'Evidence', '-LicenseKey', $script:Key)
    if ($run.Code -ne 0 -or $run.Text.Contains($script:Key)) { Fail "evidence with a LicenseKey argument: exit $($run.Code)" }
    if (-not $IsWindows) {
        $run = Invoke-Child -Arguments @('-Action', 'Install', '-InstallerUrl', $userInfoUrl, '-LicenseKey', $script:Key, '-CompanyName', 'Example', '-LocationName', 'Main')
        if ($run.Code -ne 1 -or $run.Text.Contains($script:Key)) { Fail "install with a LicenseKey argument leaked or passed: exit $($run.Code) [$($run.Text)]" }
        $run = Invoke-Child -Arguments @('-Action', 'Install', '-InstallerUrl', $userInfoUrl)
        if ($run.Code -ne 1 -or $run.Text -notlike '*userinfo*') { Fail "install with a userinfo URL: exit $($run.Code) [$($run.Text)]" }
        $run = Invoke-Child -Arguments @('-Action', 'Uninstall', '-InstallerUrl', $userInfoUrl)
        if ($run.Code -ne 0) { Fail "uninstall with a userinfo URL: exit $($run.Code) [$($run.Text)]" }
    }
} finally {
    if (Test-Path -LiteralPath $script:Root) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'autoelevate-upgrade tests passed'
exit 0
