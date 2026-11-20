<#
.SYNOPSIS
    Enroll the Wazuh agent through the Relian runner with the registration password from NinjaOne.

.DESCRIPTION
    Paste this one file into NinjaOne and run it as SYSTEM instead of Invoke-RelianRunner.ps1 for the wazuh
    package. It reads the organization fields wazuhGroup and wazuhRegistrationPassword (type Secure, script
    read), downloads the runner from RunnerUrl, checks RunnerSha256 and runs it as a child with the runner
    arguments you pass. The child inherits four environment variables that the package reads in Enroll mode
    (-PackageArguments with {"Enrollment":"Environment","FloorVersion":"<floor>"}):
    RELIAN_WAZUH_MANAGER, RELIAN_WAZUH_GROUP, RELIAN_WAZUH_PREFIX and RELIAN_WAZUH_AUTHD_PASS. The password is
    never on a command line and never printed. The variables are removed when the runner returns.
    The runner and the package call no NinjaOne API.

    An empty wazuhGroup means the organization is not on Wazuh: exit 0 before the password is read or
    anything is downloaded. A set group with an empty password exits 1. The agent name prefix is
    wazuhGroup without a trailing _group, as in the earlier NinjaOne installer.

.PARAMETER RunnerUrl
    Raw URL of windows/runner/Invoke-RelianRunner.ps1 at a pinned commit.

.PARAMETER RunnerSha256
    SHA256 of that file, lowercase. Empty exits 0 and does nothing.

.PARAMETER WazuhManager
    Manager host name. The package checks its characters.

.NOTES
    Every other argument (-PackageUrl, -PackageSha256, ... -PackageArguments) is passed to the runner as is.
    Do not run with transcript logging on. Requirements: Windows PowerShell 5.1+, run as SYSTEM.
#>
[CmdletBinding()]
param(
    [string]$RunnerUrl,
    [string]$RunnerSha256,
    [string]$WazuhManager,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RunnerArguments
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$script:EnvNames = @('RELIAN_WAZUH_MANAGER', 'RELIAN_WAZUH_GROUP', 'RELIAN_WAZUH_PREFIX', 'RELIAN_WAZUH_AUTHD_PASS')

# Seams. Tests replace them.
$script:GetField = { param($Name) [string](Ninja-Property-Get $Name) }
$script:NewHandoffDir = {
    $path = Join-Path $env:ProgramData ('Relian\wazuh-enroll-' + [guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Path $path -Force)
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $who = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $security
    return $path
}
$script:DownloadFile = { param($Url, $Destination) Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 }
$script:RetryDelay = { param($Seconds) Start-Sleep -Seconds $Seconds }
$script:RunRunner = {
    param($RunnerFile, $Arguments)
    $hostPath = (Get-Process -Id $PID).Path
    # Out-Host keeps the runner's output out of this function's return value: only the code is returned.
    # No forwarded value carries a double quote: -PackageArguments is base64, the rest are URLs, hashes and words.
    & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RunnerFile @Arguments | Out-Host
    return [int]$LASTEXITCODE
}

# Timeout, connection or DNS failure, or HTTP 408, 429, 500, 502, 503, 504: the runner's retry classes.
function Test-RelianRetryable {
    param($Exception)
    for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
        $resp = $e.PSObject.Properties['Response']
        if ($resp -and $resp.Value) { return @(408, 429, 500, 502, 503, 504) -contains [int]$resp.Value.StatusCode }
        if ($e -is [TimeoutException] -or $e -is [Threading.Tasks.TaskCanceledException] -or $e -is [Net.Sockets.SocketException]) { return $true }
        if ($e -is [Net.WebException] -and @('Timeout', 'NameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed') -contains [string]$e.Status) { return $true }
    }
    return $false
}

function Invoke-RelianWazuhEnroll {
    param([string]$RunnerUrl, [string]$RunnerSha256, [string]$WazuhManager, [string[]]$RunnerArguments)
    # Checked before the off switch, as in the runner: a credential in a URL is already in NinjaOne's history.
    if (@(@($RunnerUrl) + @($RunnerArguments) | Where-Object { $_ -match '\A\s*[a-z][a-z0-9+.-]*:[\\/]{2}[^\\/?#]*@' }).Count) { Write-Host 'refusing a URL that contains userinfo'; return 1 }
    # An empty hash is the off switch, as in the runner: exit 0 before anything is read or downloaded.
    if ([string]::IsNullOrWhiteSpace($RunnerSha256)) { return 0 }
    # An empty forwarded pin is the runner's off switch, but 5.1 drops an empty native argument: honour it here.
    # An omitted pin is not empty: the runner exits 1 with "missing parameter", so it is not an off switch.
    for ($i = 0; $i -lt @($RunnerArguments).Count - 1; $i++) {
        if ($RunnerArguments[$i] -match '\A-(Package|Toolkit|BrandPack)Sha256\z' -and [string]::IsNullOrWhiteSpace($RunnerArguments[$i + 1])) { return 0 }
    }
    # Enroll mode is Install only, and nothing is downloaded for another action.
    $act = @(for ($i = 0; $i -lt @($RunnerArguments).Count - 1; $i++) { if ($RunnerArguments[$i] -ieq '-Action') { $RunnerArguments[$i + 1] } })
    if ($act.Count -ne 1 -or $act[0] -ine 'Install') { Write-Host 'this script runs -Action Install only'; return 1 }
    # 5.1 drops any other empty native argument too, which would shift the runner's parameters.
    if (@($RunnerArguments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { Write-Host 'an empty runner argument would be dropped: leave the parameter out'; return 1 }
    if ($RunnerSha256 -cnotmatch '\A[0-9a-f]{64}\z') { Write-Host 'RunnerSha256 must be 64 lowercase hex characters'; return 1 }
    if ([string]::IsNullOrWhiteSpace($RunnerUrl)) { Write-Host 'RunnerUrl is required'; return 1 }
    if ([string]::IsNullOrWhiteSpace($WazuhManager)) { Write-Host 'WazuhManager is required'; return 1 }

    # Errors name the field only: a cmdlet error could carry the value.
    try { $group = ([string](& $script:GetField 'wazuhGroup')).Trim() } catch { Write-Host 'could not read wazuhGroup'; return 1 }
    if ($group -eq '') { Write-Host 'wazuhGroup is empty: this organization is not on Wazuh'; return 0 }
    try { $authd = [string](& $script:GetField 'wazuhRegistrationPassword') } catch { Write-Host 'could not read wazuhRegistrationPassword'; return 1 }
    # Kept verbatim: edge whitespace may be part of the password. The package refuses one with a line break.
    if ([string]::IsNullOrWhiteSpace($authd)) { Write-Host 'wazuhRegistrationPassword is empty'; return 1 }
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }

    $dir = & $script:NewHandoffDir
    try {
        $runnerFile = Join-Path $dir 'runner.ps1'
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
            try { & $script:DownloadFile $RunnerUrl $runnerFile; $downloaded = $true }
            catch { if ($attempt -eq 3 -or -not (Test-RelianRetryable -Exception $_.Exception)) { break }; & $script:RetryDelay (2 * $attempt) }
        }
        if (-not $downloaded) { Write-Host 'runner download failed'; return 1 }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $runnerFile).Hash -ne $RunnerSha256) { Write-Host 'hash mismatch for runner'; return 1 }
        $env:RELIAN_WAZUH_MANAGER = $WazuhManager.Trim()
        $env:RELIAN_WAZUH_GROUP = $group
        $env:RELIAN_WAZUH_PREFIX = $group -replace '_group\z', ''
        $env:RELIAN_WAZUH_AUTHD_PASS = $authd
        try { return [int](& $script:RunRunner $runnerFile @($RunnerArguments)) } catch { Write-Host 'runner failed to start'; return 1 }
    } finally {
        foreach ($name in $script:EnvNames) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
exit ([int](Invoke-RelianWazuhEnroll -RunnerUrl $RunnerUrl -RunnerSha256 $RunnerSha256 -WazuhManager $WazuhManager -RunnerArguments $RunnerArguments))
