$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wazuh/Invoke-Wazuh.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @('Invoke-WazuhEnrollAction', 'Get-WazuhEnrollSettings')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$pin = '4.14.9'
$floor = '4.14.3'
$manager = 'manager.example.invalid'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:GoodBytes = $utf8.GetBytes('wazuh-enroll-payload')
$sha = [System.Security.Cryptography.SHA256]::Create()
$script:GoodSha = ([System.BitConverter]::ToString($sha.ComputeHash($script:GoodBytes))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()
# Generated per run, so no literal secret is committed.
$script:Secret = 'sentinel-' + [guid]::NewGuid().ToString('n')
# Synthetic host name, generated so no device name is committed.
$script:HostName = 'H' + [guid]::NewGuid().ToString('n').Substring(0, 10)

function Reset-EnrollCase {
    param(
        [string]$Installed = '',
        [string]$Service = 'Running',
        [int64]$Keys = 0
    )
    $env:RELIAN_WAZUH_MANAGER = $manager
    $env:RELIAN_WAZUH_GROUP = 'tenant_group'
    $env:RELIAN_WAZUH_PREFIX = 'tenantexample'
    $env:RELIAN_WAZUH_AUTHD_PASS = $script:Secret
    $env:COMPUTERNAME = $script:HostName
    $script:InstalledVersion = $Installed
    $script:ServiceStatus = $Service
    $script:KeysLength = $Keys
    $script:DownloadCount = 0
    $script:MsiCalls = [System.Collections.Generic.List[object]]::new()
    $script:AuthdWrites = [System.Collections.Generic.List[string]]::new()
    $script:ServiceStarts = [System.Collections.Generic.List[bool]]::new()
    $script:WazuhErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:DownloadBytes = $script:GoodBytes
    $script:RetryDelay = { param($Seconds) }
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $script:DownloadBytes)
    }
    $script:GetInstalledWazuhVersion = { return [string]$script:InstalledVersion }
    $script:GetWazuhServiceStatus = { return [string]$script:ServiceStatus }
    $script:GetClientKeysLength = { return [int64]$script:KeysLength }
    $script:InvokeMsiExec = {
        param($Mode, $InstallerPath, $ProductCode, [string[]]$Properties = @())
        $script:MsiCalls.Add([pscustomobject]@{
                Mode       = [string]$Mode
                Arguments  = @(Get-WazuhMsiArgumentList -Mode $Mode -InstallerPath $InstallerPath -ProductCode $ProductCode -Properties $Properties)
                Properties = @($Properties)
                Inherited  = [string]$env:RELIAN_WAZUH_AUTHD_PASS
            })
        return 0
    }
    $script:WriteAuthdPass = {
        param($Value)
        $script:AuthdWrites.Add([string]$Value)
    }
    $script:StartWazuhService = {
        param([bool]$Restart)
        $script:ServiceStarts.Add($Restart)
    }
}

function Invoke-EnrollCase {
    param(
        [string]$Action = 'Install',
        [string]$Floor = $floor,
        [string]$Sha256 = $script:GoodSha,
        [string]$Url = 'https://example.invalid/wazuh.msi'
    )
    # Every stream is captured so a leak through output, warning or host shows up.
    $script:LastOutput = (Invoke-WazuhEnrollAction -Action $Action -PinVersion $pin -FloorVersion $Floor -InstallerUrl $Url -InstallerSha256 $Sha256 -CancelPath '' *>&1 | Out-String)
    $code = [int](($script:LastOutput.Trim() -split "`n")[-1])
    return $code
}

function Assert-NoSecretLeak {
    param([string]$Label)
    $texts = @($script:LastOutput) + @($script:WazuhErrorLog)
    foreach ($call in $script:MsiCalls) {
        $texts += @($call.Arguments)
        if ($call.Inherited -ne '') {
            Fail "$Label msiexec inherited the enrollment secret"
        }
    }
    foreach ($text in $texts) {
        if ([string]$text -and ([string]$text).Contains($script:Secret)) {
            Fail "$Label leaked the enrollment secret"
        }
    }
    if ([string]$env:RELIAN_WAZUH_AUTHD_PASS -ne '') {
        Fail "$Label left the enrollment secret in the environment"
    }
}

# Fresh install: one msiexec with the three enrollment properties, then authd.pass and one restart.
Reset-EnrollCase
$code = Invoke-EnrollCase
if ($code -ne 0) { Fail "fresh install exit $code $($script:WazuhErrorLog -join ';')" }
if ($script:DownloadCount -ne 1 -or $script:MsiCalls.Count -ne 1) { Fail 'fresh install did not download and run msiexec once' }
$wantProps = @("WAZUH_MANAGER=$manager", 'WAZUH_AGENT_GROUP=default,tenant_group', "WAZUH_AGENT_NAME=tenantexample--$($script:HostName)")
if ((@($script:MsiCalls[0].Properties) -join '|') -cne ($wantProps -join '|')) { Fail "fresh install properties $(@($script:MsiCalls[0].Properties) -join '|')" }
$args0 = @($script:MsiCalls[0].Arguments)
if ($args0[0] -cne '/i' -or $args0[2] -cne '/qn' -or $args0[3] -cne '/norestart' -or $args0.Count -ne 7) { Fail 'fresh install argument list' }
if ($script:AuthdWrites.Count -ne 1 -or $script:AuthdWrites[0] -cne $script:Secret) { Fail 'fresh install did not write authd.pass once with the secret' }
if ($script:ServiceStarts.Count -ne 1 -or -not $script:ServiceStarts[0]) { Fail 'fresh install did not restart the service once' }
Assert-NoSecretLeak -Label 'fresh install'

# The secret is written verbatim: edge whitespace is part of it.
Reset-EnrollCase
$env:RELIAN_WAZUH_AUTHD_PASS = " $($script:Secret) "
[void](Invoke-EnrollCase)
if ($script:AuthdWrites.Count -ne 1 -or $script:AuthdWrites[0] -cne " $($script:Secret) ") { Fail 'the secret was not written verbatim' }

# Prefix given with the separator, a group list that names default, and a name that is already prefixed.
Reset-EnrollCase
$env:RELIAN_WAZUH_PREFIX = 'tenantexample--'
$env:RELIAN_WAZUH_GROUP = 'default, tenant_group,extra'
[void](Invoke-EnrollCase)
if ((@($script:MsiCalls[0].Properties) -join '|') -cne "WAZUH_MANAGER=$manager|WAZUH_AGENT_GROUP=default,tenant_group,extra|WAZUH_AGENT_NAME=tenantexample--$($script:HostName)") { Fail 'prefix separator or group list' }
Reset-EnrollCase
$env:COMPUTERNAME = "other--$($script:HostName)"
[void](Invoke-EnrollCase)
if (@($script:MsiCalls[0].Properties)[2] -cne "WAZUH_AGENT_NAME=other--$($script:HostName)") { Fail 'an already prefixed name was prefixed again' }

# Keys exist: no download, no msiexec, no authd.pass, no re-enrollment.
foreach ($installed in @('4.14.3', '4.14.9', '4.15.0')) {
    Reset-EnrollCase -Installed $installed -Keys 120
    $code = Invoke-EnrollCase
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:MsiCalls.Count -ne 0) { Fail "installed $installed with keys ran setup" }
    if ($script:AuthdWrites.Count -ne 0 -or $script:ServiceStarts.Count -ne 0) { Fail "installed $installed with keys touched enrollment" }
}
Reset-EnrollCase -Installed '4.14.9' -Keys 120 -Service 'Stopped'
$code = Invoke-EnrollCase
if ($code -ne 0 -or $script:MsiCalls.Count -ne 0 -or $script:AuthdWrites.Count -ne 0) { Fail 'stopped enrolled agent ran setup' }
if ($script:ServiceStarts.Count -ne 1 -or $script:ServiceStarts[0]) { Fail 'stopped enrolled agent was not started once without restart' }

# No downgrade: newer than the pinned MSI stays, even with empty keys.
Reset-EnrollCase -Installed '4.15.0' -Keys 0
$code = Invoke-EnrollCase
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:MsiCalls.Count -ne 0) { Fail 'a newer agent was reinstalled' }
if ($script:AuthdWrites.Count -ne 1 -or $script:ServiceStarts.Count -ne 1 -or -not $script:ServiceStarts[0]) { Fail 'an unenrolled agent was not restarted with authd.pass' }
Assert-NoSecretLeak -Label 'unenrolled agent'

# Below the floor: in-place upgrade with no enrollment properties; keys kept.
Reset-EnrollCase -Installed '4.14.0' -Keys 120
$code = Invoke-EnrollCase
if ($code -ne 0 -or $script:MsiCalls.Count -ne 1) { Fail 'below floor did not upgrade once' }
if (@($script:MsiCalls[0].Properties).Count -ne 0 -or @($script:MsiCalls[0].Arguments).Count -ne 4) { Fail 'below floor upgrade passed enrollment properties' }
if ($script:AuthdWrites.Count -ne 0) { Fail 'below floor upgrade wrote authd.pass while keys exist' }

# A floor above the pin, a bad installed version, and enroll with another action refuse before any download.
Reset-EnrollCase
if ((Invoke-EnrollCase -Floor '4.15.0') -ne 1 -or $script:DownloadCount -ne 0) { Fail 'a floor above the pin did not refuse' }
Reset-EnrollCase -Installed 'v4'
if ((Invoke-EnrollCase) -ne 1 -or $script:DownloadCount -ne 0) { Fail 'an unparseable installed version did not refuse' }
Reset-EnrollCase
if ((Invoke-EnrollCase -Action 'Uninstall') -ne 1 -or $script:DownloadCount -ne 0) { Fail 'enroll with Uninstall did not refuse' }

# Empty, unsubstituted or malformed settings: exit 1, nothing downloaded, installed or written.
$badCases = @(
    @('RELIAN_WAZUH_MANAGER', '%wazuhmanager%'),
    @('RELIAN_WAZUH_GROUP', '%wazuhgroup%'),
    @('RELIAN_WAZUH_PREFIX', '%wazuhprefix%'),
    @('RELIAN_WAZUH_AUTHD_PASS', '%wazuhauthdpass%'),
    @('RELIAN_WAZUH_MANAGER', ''),
    @('RELIAN_WAZUH_GROUP', '   '),
    @('RELIAN_WAZUH_PREFIX', ''),
    @('RELIAN_WAZUH_AUTHD_PASS', ''),
    @('RELIAN_WAZUH_MANAGER', 'manager.example.invalid WAZUH_AGENT_NAME=x'),
    @('RELIAN_WAZUH_GROUP', 'tenant group'),
    @('RELIAN_WAZUH_PREFIX', 'tenant"x'),
    @('RELIAN_WAZUH_AUTHD_PASS', "two`nlines")
)
foreach ($case in $badCases) {
    foreach ($installed in @('', '4.14.9')) {
        Reset-EnrollCase -Installed $installed
        [Environment]::SetEnvironmentVariable($case[0], $case[1])
        $code = Invoke-EnrollCase
        if ($code -ne 1) { Fail "$($case[0])='$($case[1])' exit $code" }
        if ($script:DownloadCount -ne 0 -or $script:MsiCalls.Count -ne 0 -or $script:AuthdWrites.Count -ne 0 -or $script:ServiceStarts.Count -ne 0) {
            Fail "$($case[0])='$($case[1])' did work before refusing"
        }
        Assert-NoSecretLeak -Label "$($case[0]) refusal"
    }
}
Reset-EnrollCase
$env:COMPUTERNAME = ''
if ((Invoke-EnrollCase) -ne 1 -or $script:DownloadCount -ne 0) { Fail 'an empty COMPUTERNAME did not refuse' }

# Hash mismatch aborts: no msiexec, no authd.pass, no service change.
Reset-EnrollCase
$script:DownloadBytes = $utf8.GetBytes('tampered')
$code = Invoke-EnrollCase
if ($code -ne 1 -or $script:MsiCalls.Count -ne 0 -or $script:AuthdWrites.Count -ne 0 -or $script:ServiceStarts.Count -ne 0) { Fail 'hash mismatch did not abort' }
if (-not (($script:WazuhErrorLog -join ';').Contains('hash mismatch'))) { Fail 'hash mismatch was not reported' }
Assert-NoSecretLeak -Label 'hash mismatch'
# A URL with userinfo exits 1 even when no download is needed.
$userInfoUrl = -join @('https://', 'user', '@', 'example.invalid/wazuh.msi')
foreach ($installed in @('', '4.14.9')) {
    Reset-EnrollCase -Installed $installed -Keys 120
    $code = Invoke-EnrollCase -Url $userInfoUrl
    if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:MsiCalls.Count -ne 0 -or $script:ServiceStarts.Count -ne 0) {
        Fail "userinfo URL with installed '$installed' was not refused"
    }
}

# An empty hash is the repo-wide off switch: exit 0 and touch nothing, for every action and state.
foreach ($emptyCase in @(@('Install', '', 0), @('Install', '4.14.9', 0), @('Uninstall', '4.14.9', 0))) {
    Reset-EnrollCase -Installed $emptyCase[1] -Keys $emptyCase[2]
    $code = Invoke-EnrollCase -Action $emptyCase[0] -Sha256 ''
    if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:MsiCalls.Count -ne 0 -or $script:AuthdWrites.Count -ne 0 -or $script:ServiceStarts.Count -ne 0) {
        Fail "empty hash with $($emptyCase[0]) at '$($emptyCase[1])' was not a no-op"
    }
}

# Failures after the install: a missing service, and a start that throws a message carrying the secret.
Reset-EnrollCase -Service ''
if ((Invoke-EnrollCase) -ne 1) { Fail 'a missing service after install did not fail' }
Reset-EnrollCase
$script:StartWazuhService = { param([bool]$Restart) throw "service said $($script:Secret)" }
if ((Invoke-EnrollCase) -ne 1) { Fail 'a failed service start did not fail' }
Assert-NoSecretLeak -Label 'service failure'

# The script file runs end to end and refuses with no secret in stdout or stderr.
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
Reset-EnrollCase
$env:RELIAN_WAZUH_MANAGER = '%wazuhmanager%'
$childOutput = (& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion $pin -FloorVersion $floor -Enroll -InstallerUrl 'https://example.invalid/wazuh.msi' -InstallerSha256 $script:GoodSha 2>&1 | Out-String)
$childExit = $LASTEXITCODE
$env:RELIAN_DEPLOY_TEST = '1'
if ($childExit -ne 1) { Fail "script run exit $childExit" }
if (-not $childOutput.Contains('RELIAN_WAZUH_MANAGER is empty or not substituted')) { Fail 'script run did not name the variable' }
if ($childOutput.Contains($script:Secret)) { Fail 'script run leaked the enrollment secret' }

# The runner passes package arguments as -Name Value pairs and cannot set a switch: -Enrollment Environment is Enroll mode.
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
$childOutput = (& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion $pin -Enrollment Environment -FloorVersion $floor -InstallerUrl 'https://example.invalid/wazuh.msi' -InstallerSha256 $script:GoodSha 2>&1 | Out-String)
$childExit = $LASTEXITCODE
if ($childExit -ne 1 -or -not $childOutput.Contains('RELIAN_WAZUH_MANAGER is empty or not substituted')) { Fail "-Enrollment Environment did not run Enroll mode: $childExit $childOutput" }
if ($childOutput.Contains($script:Secret)) { Fail '-Enrollment run leaked the enrollment secret' }
foreach ($bad in @('environment', 'true', 'x')) {
    $childOutput = (& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion $pin -Enrollment $bad -InstallerUrl 'https://example.invalid/wazuh.msi' -InstallerSha256 $script:GoodSha 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 1 -or -not $childOutput.Contains('Enrollment must be Environment')) { Fail "-Enrollment $bad was not refused: $LASTEXITCODE $childOutput" }
}
$env:RELIAN_DEPLOY_TEST = '1'

$scriptText = [System.IO.File]::ReadAllText($scriptPath)
foreach ($banned in @('Start-Transcript', 'WAZUH_REGISTRATION_')) {
    if ($scriptText.Contains($banned)) { Fail "script contains $banned" }
}

Write-Output 'wazuh-enroll tests passed'
exit 0
