$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/wazuh/Invoke-Wazuh.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        [Console]::Error.WriteLine('FAIL missing message')
        exit 1
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Wazuh.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-WazuhPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-WazuhPayload was not defined'
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
function Get-Sha {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-WazuhUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/wazuh.msi')
}

class WazuhFakeHttpException : System.Exception {
    [object]$Response
    WazuhFakeHttpException([int]$Status) : base('status') {
        $this.Response = [pscustomobject]@{ StatusCode = $Status }
    }
}

function New-HttpFailure {
    param([int]$Status, [string]$Message)
    $exception = [System.Net.Http.HttpRequestException]::new(
        $Message,
        $null,
        [System.Net.HttpStatusCode]$Status
    )
    throw $exception
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('wazuh-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('wazuh-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:WazuhErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:Sleeps.Clear()
    $script:WazuhErrorLog.Clear()
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
}

$script:RetryDelay = {
    param($Seconds)
    $script:Sleeps.Add([int]$Seconds)
}

try {
    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
        Fail "matching hash returned $code"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    $logged = $script:WazuhErrorLog -join "`n"
    if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
    }
    if ($logged -like '*https://*' -or $logged -notlike '*installer*') {
        Fail 'mismatch error was not a label-only message'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
    }
    $code = Save-WazuhPayload -Url (New-WazuhUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:WazuhErrorLog -join "`n") -like '*https://*') {
        Fail 'userinfo error included a URL'
    }

    Reset-Hooks
    $code = Save-WazuhPayload -Url (New-WazuhUserInfoUrl) -Destination $dest -Sha256 '' -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo with an empty hash returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 '' -Label 'installer'
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "empty hash returned $code after $($script:DownloadCount) downloads"
    }

    foreach ($status in @(408, 429, 500, 502, 503, 504)) {
        if (-not (Test-WazuhDownloadIsTransient -ErrorRecord ([WazuhFakeHttpException]::new($status)))) {
            Fail "HTTP $status on Response.StatusCode was not retried"
        }
    }
    foreach ($status in @(404, 400, 401)) {
        if (Test-WazuhDownloadIsTransient -ErrorRecord ([WazuhFakeHttpException]::new($status))) {
            Fail "HTTP $status on Response.StatusCode was retried"
        }
    }
    if (-not (Test-WazuhDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
        Fail 'timeout was not retried'
    }
    if (Test-WazuhDownloadIsTransient -ErrorRecord ([System.Threading.Tasks.TaskCanceledException]::new('timed out'))) {
        Fail 'task cancel was retried'
    }
    $timeoutCancel = [System.Threading.Tasks.TaskCanceledException]::new(
        'canceled',
        [System.TimeoutException]::new('timed out')
    )
    if (-not (Test-WazuhDownloadIsTransient -ErrorRecord $timeoutCancel)) {
        Fail 'timeout cancel was not retried'
    }
    $cts = [System.Threading.CancellationTokenSource]::new()
    try {
        $cts.Cancel()
        $explicit = [System.Threading.Tasks.TaskCanceledException]::new('canceled', $null, $cts.Token)
        if (Test-WazuhDownloadIsTransient -ErrorRecord $explicit) {
            Fail 'caller cancellation was retried'
        }
    } finally {
        $cts.Dispose()
    }
    $wrappedCancel = [System.Exception]::new(
        'wrapped',
        [System.Threading.Tasks.TaskCanceledException]::new('timed out')
    )
    if (Test-WazuhDownloadIsTransient -ErrorRecord $wrappedCancel) {
        Fail 'wrapped task cancel was retried'
    }
    $socket = [System.Net.Sockets.SocketException]::new()
    if (-not (Test-WazuhDownloadIsTransient -ErrorRecord $socket)) {
        Fail 'socket failure was not retried'
    }
    $wrapped = [System.Exception]::new('wrapped', $socket)
    if (-not (Test-WazuhDownloadIsTransient -ErrorRecord $wrapped)) {
        Fail 'wrapped socket failure was not retried'
    }
    $dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
    if (-not (Test-WazuhDownloadIsTransient -ErrorRecord $dns)) {
        Fail 'DNS failure was not retried'
    }
    if (Test-WazuhDownloadIsTransient -ErrorRecord ([System.Exception]::new('nope'))) {
        Fail 'a generic failure was retried'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
    }
    if (($script:WazuhErrorLog -join "`n") -like '*https://*') {
        Fail '404 error included a URL'
    }

    Reset-Hooks
    $script:Attempt = 0
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:Attempt++
        if ($script:Attempt -eq 1) {
            New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
        }
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 0 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
        Fail "503 then success returned $code sleeps $($script:Sleeps -join ',')"
    }

    Reset-Hooks
    $script:Attempt = 0
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $script:Attempt++
        if ($script:Attempt -eq 1) {
            throw [System.Net.Sockets.SocketException]::new()
        }
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 0 -or $script:DownloadCount -ne 2 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
        Fail "socket then success returned $code after $($script:DownloadCount) downloads sleeps $($script:Sleeps -join ',')"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 3) {
        Fail "three 503s returned $code after $($script:DownloadCount) attempts"
    }
    if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
        Fail "three 503s slept $($script:Sleeps -join ',')"
    }
    if (($script:WazuhErrorLog -join "`n") -like '*https://*') {
        Fail '503 error included a URL'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $env:RELIAN_DEPLOY_CANCEL = '1'
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if ($code -ne 130 -or $script:DownloadCount -ne 1) {
        Fail "cancel before the second attempt returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $cancel = Join-Path $root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Save-WazuhPayload -Url 'https://example.invalid/wazuh.msi' -Destination $dest -Sha256 $goodSha -Label 'installer' -CancelPath $cancel
    if ($code -ne 130 -or $script:DownloadCount -ne 0) {
        Fail "cancel path returned $code after $($script:DownloadCount) downloads"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'wazuh-download tests passed'
exit 0
