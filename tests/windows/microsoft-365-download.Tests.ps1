$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/microsoft-365/Invoke-Microsoft365.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Microsoft365.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-Microsoft365Payload -ErrorAction SilentlyContinue)) {
    Fail 'Save-Microsoft365Payload was not defined'
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

function New-Microsoft365UserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/officedeploymenttool.exe')
}

class Microsoft365FakeHttpException : System.Exception {
    [object]$Response
    Microsoft365FakeHttpException([int]$Status) : base('status') {
        $this.Response = [pscustomobject]@{ StatusCode = $Status }
    }
}

class Microsoft365TransportException : System.Exception {
    [string]$HttpRequestError
    Microsoft365TransportException([string]$Kind) : base('transport') {
        $this.HttpRequestError = $Kind
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('office-deployment-tool')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:Microsoft365ErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:Sleeps.Clear()
    $script:Microsoft365ErrorLog.Clear()
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
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
        Fail "matching hash returned $code"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
    }
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    $logged = $script:Microsoft365ErrorLog -join "`n"
    if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
    }
    if ($logged -like '*https://*' -or $logged -notlike '*office deployment tool*') {
        Fail 'mismatch error was not a label-only message'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
    }
    $code = Save-Microsoft365Payload -Url (New-Microsoft365UserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:Microsoft365ErrorLog -join "`n") -like '*https://*') {
        Fail 'userinfo error included a URL'
    }

    Reset-Hooks
    $code = Save-Microsoft365Payload -Url (New-Microsoft365UserInfoUrl) -Destination $dest -Sha256 '' -Label 'office deployment tool'
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "userinfo with an empty hash returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 '' -Label 'office deployment tool'
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "empty hash returned $code after $($script:DownloadCount) downloads"
    }

    foreach ($placeholder in @('placeholder', ('0' * 64), ('f' * 64), ('deadbeef' * 8))) {
        Reset-Hooks
        $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $placeholder -Label 'office deployment tool'
        if ($code -ne 1 -or $script:DownloadCount -ne 0 -or (Test-Path -LiteralPath $dest)) {
            Fail "placeholder hash returned $code after $($script:DownloadCount) downloads"
        }
        if (($script:Microsoft365ErrorLog -join "`n") -notlike '*placeholder*') {
            Fail 'placeholder hash error did not name a placeholder'
        }
    }

    foreach ($status in @(408, 429, 500, 502, 503, 504)) {
        if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord ([Microsoft365FakeHttpException]::new($status)))) {
            Fail "HTTP $status on Response.StatusCode was not retried"
        }
    }
    foreach ($status in @(404, 400, 401)) {
        if (Test-Microsoft365DownloadIsTransient -ErrorRecord ([Microsoft365FakeHttpException]::new($status))) {
            Fail "HTTP $status on Response.StatusCode was retried"
        }
    }
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
        Fail 'timeout was not retried'
    }
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord ([System.Threading.Tasks.TaskCanceledException]::new('timed out')))) {
        Fail 'task cancel was not retried'
    }
    $socket = [System.Net.Sockets.SocketException]::new()
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord $socket)) {
        Fail 'socket failure was not retried'
    }
    $wrapped = [System.Exception]::new('wrapped', $socket)
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord $wrapped)) {
        Fail 'wrapped socket failure was not retried'
    }
    $dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord $dns)) {
        Fail 'DNS failure was not retried'
    }
    if (Test-Microsoft365DownloadIsTransient -ErrorRecord ([System.Exception]::new('nope'))) {
        Fail 'a generic failure was retried'
    }
    if (-not (Test-Microsoft365DownloadIsTransient -ErrorRecord ([Microsoft365TransportException]::new('SecureConnectionError')))) {
        Fail 'SecureConnectionError was not retried'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
    }
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
    }
    if (($script:Microsoft365ErrorLog -join "`n") -like '*https://*') {
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
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
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
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    if ($code -ne 0 -or $script:DownloadCount -ne 2 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
        Fail "socket then success returned $code after $($script:DownloadCount) downloads sleeps $($script:Sleeps -join ',')"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    if ($code -ne 1 -or $script:DownloadCount -ne 3) {
        Fail "three 503s returned $code after $($script:DownloadCount) attempts"
    }
    if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
        Fail "three 503s slept $($script:Sleeps -join ',')"
    }
    if (($script:Microsoft365ErrorLog -join "`n") -like '*https://*') {
        Fail '503 error included a URL'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $env:RELIAN_DEPLOY_CANCEL = '1'
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool'
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if ($code -ne 130 -or $script:DownloadCount -ne 1) {
        Fail "cancel before the second attempt returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $cancel = Join-Path $root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Save-Microsoft365Payload -Url 'https://example.invalid/officedeploymenttool.exe' -Destination $dest -Sha256 $goodSha -Label 'office deployment tool' -CancelPath $cancel
    if ($code -ne 130 -or $script:DownloadCount -ne 0) {
        Fail "cancel path returned $code after $($script:DownloadCount) downloads"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'microsoft-365-download tests passed'
exit 0
