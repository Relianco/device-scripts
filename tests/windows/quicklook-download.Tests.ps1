$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/quicklook/Invoke-QuickLook.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-QuickLook.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-QuickLookPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-QuickLookPayload was not defined'
}
if (-not (Get-Command Test-QuickLookSha256Text -ErrorAction SilentlyContinue)) {
    Fail 'Test-QuickLookSha256Text was not defined'
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

function New-QuickLookUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/QuickLook-4.5.0.msi')
}

class QuickLookFakeHttpException : System.Exception {
    [object]$Response
    QuickLookFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('quicklook-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'QuickLook-4.5.0.msi'
$good = $utf8.GetBytes('quicklook-payload')
$goodSha = Get-Sha $good
$plainUrl = 'https://example.invalid/QuickLook-4.5.0.msi'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:InstallerCalls = 0
$script:QuickLookErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:InstallerCalls = 0
    $script:Sleeps.Clear()
    $script:QuickLookErrorLog.Clear()
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
}

$script:RetryDelay = {
    param($Seconds)
    $script:Sleeps.Add([int]$Seconds)
}
$script:StartMsiexec = {
    param([string[]]$ArgumentList)
    $script:InstallerCalls++
    return 0
}
$script:ReadInstalledVersion = { return '4.5.0.0' }
$script:ListMsiProducts = { return @() }

if (-not (Test-QuickLookSha256Text -Sha256 $InstallerSha256)) {
    Fail 'the pinned hash was rejected'
}
foreach ($bad in @($goodSha.ToUpperInvariant(), ('0' * 64), ('a' * 64), ('f' * 63), 'not-a-hash')) {
    if (Test-QuickLookSha256Text -Sha256 $bad) {
        Fail "invalid hash was accepted: $bad"
    }
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
    Fail "matching hash returned $code"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
$logged = $script:QuickLookErrorLog -join "`n"
if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}
if ($logged -like '*https://*') {
    Fail 'mismatch error included a URL'
}

Reset-Hooks
$marker = Join-Path $root 'action-marker'
New-Item -ItemType Directory -Path $marker -Force | Out-Null
$code = Invoke-QuickLookAction -Action 'Install' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl $plainUrl -InstallerSha256 $goodSha -InstallerPath $dest
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "mismatch action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if (Test-Path -LiteralPath (Join-Path $marker 'marker.txt')) {
    Fail 'mismatch action wrote a marker'
}

Reset-Hooks
foreach ($bad in @($goodSha.ToUpperInvariant(), ('0' * 64), ('a' * 64))) {
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
    }
    $code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $bad -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "invalid hash returned $code after $($script:DownloadCount) downloads"
    }
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$code = Save-QuickLookPayload -Url (New-QuickLookUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo returned $code after $($script:DownloadCount) downloads"
}
if (($script:QuickLookErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Hooks
$code = Save-QuickLookPayload -Url (New-QuickLookUserInfoUrl) -Destination $dest -Sha256 '' -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo with an empty hash returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 '' -Label 'installer'
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or (Test-Path -LiteralPath $dest)) {
    Fail "empty hash returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$code = Invoke-QuickLookAction -Action 'Install' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl (New-QuickLookUserInfoUrl) -InstallerSha256 $goodSha -InstallerPath $dest
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "userinfo action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}

foreach ($status in @(408, 429, 500, 502, 503, 504)) {
    if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord ([QuickLookFakeHttpException]::new($status)))) {
        Fail "HTTP $status on Response.StatusCode was not retried"
    }
}
foreach ($status in @(404, 403, 401)) {
    if (Test-QuickLookDownloadIsTransient -ErrorRecord ([QuickLookFakeHttpException]::new($status))) {
        Fail "HTTP $status on Response.StatusCode was retried"
    }
}
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
    Fail 'timeout was not retried'
}
$timeout = [System.TimeoutException]::new('The operation has timed out.')
$timedOut = [System.Threading.Tasks.TaskCanceledException]::new('canceled', $timeout)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $timedOut)) {
    Fail 'a timeout cancellation was not retried'
}
if (Test-QuickLookDownloadIsTransient -ErrorRecord ([System.Threading.Tasks.TaskCanceledException]::new('timed out'))) {
    Fail 'a bare TaskCanceledException was retried'
}
$connection = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionRefused)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $connection)) {
    Fail 'connection failure was not retried'
}
$wrapped = [System.Exception]::new('wrapped', $connection)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $wrapped)) {
    Fail 'wrapped connection failure was not retried'
}
$dnsSocket = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::HostNotFound)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $dnsSocket)) {
    Fail 'DNS socket failure was not retried'
}
$socketTimeout = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::TimedOut)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $socketTimeout)) {
    Fail 'socket timeout was not retried'
}
$reset = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionReset)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $reset)) {
    Fail 'connection reset was not retried'
}
$unrelated = [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::AddressAlreadyInUse)
if (Test-QuickLookDownloadIsTransient -ErrorRecord $unrelated) {
    Fail 'an unrelated socket error was retried'
}
$bareSocket = [System.Net.Sockets.SocketException]::new()
if (Test-QuickLookDownloadIsTransient -ErrorRecord $bareSocket) {
    Fail 'a parameterless socket error was retried'
}
$dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $dns)) {
    Fail 'DNS WebException was not retried'
}
$connect = [System.Net.WebException]::new('connect', [System.Net.WebExceptionStatus]::ConnectFailure)
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $connect)) {
    Fail 'connection WebException was not retried'
}
$secure = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::SecureConnectionError, 'tls')
if (-not (Test-QuickLookDownloadIsTransient -ErrorRecord $secure)) {
    Fail 'SecureConnectionError was not retried'
}
if (Test-QuickLookDownloadIsTransient -ErrorRecord ([System.Exception]::new('nope'))) {
    Fail 'a generic failure was retried'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 404 -Message 'missing'
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
}
if (($script:QuickLookErrorLog -join "`n") -like '*https://*') {
    Fail '404 error included a URL'
}

Reset-Hooks
$script:Attempt = 0
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $script:Attempt++
    if ($script:Attempt -eq 1) {
        New-HttpFailure -Status 503 -Message 'busy'
    }
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
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
        throw [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionRefused)
    }
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or $script:DownloadCount -ne 2 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
    Fail "socket then success returned $code after $($script:DownloadCount) downloads sleeps $($script:Sleeps -join ',')"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    throw [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::AddressAlreadyInUse)
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "unrelated socket returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 503 -Message 'busy'
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 3) {
    Fail "three 503s returned $code after $($script:DownloadCount) attempts"
}
if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
    Fail "three 503s slept $($script:Sleeps -join ',')"
}
if (($script:QuickLookErrorLog -join "`n") -like '*https://*') {
    Fail '503 error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    New-HttpFailure -Status 503 -Message 'busy'
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "cancel before the second attempt returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}

Reset-Hooks
$cancel = Join-Path $root 'cancel.flag'
New-Item -ItemType File -Path $cancel -Force | Out-Null
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-QuickLookPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer' -CancelPath $cancel
if ($code -ne 130 -or $script:DownloadCount -ne 0) {
    Fail "cancel path returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Invoke-QuickLookAction -Action 'Install' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl $plainUrl -InstallerSha256 $goodSha -InstallerPath $dest
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130 -or $script:InstallerCalls -ne 0) {
    Fail "cancel after download returned $code after $($script:InstallerCalls) installer calls"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$script:StartMsiexec = {
    param([string[]]$ArgumentList)
    $script:InstallerCalls++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    return 0
}
$code = Invoke-QuickLookAction -Action 'Install' -PinVersion '4.5.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl $plainUrl -InstallerSha256 $goodSha -InstallerPath $dest
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 0 -or $script:InstallerCalls -ne 1) {
    Fail "cancel during installer returned $code after $($script:InstallerCalls) installer calls"
}
$markerText = ''
$markerFile = Join-Path $marker 'marker.txt'
if (Test-Path -LiteralPath $markerFile) {
    $markerText = [System.IO.File]::ReadAllText($markerFile)
}
if ($markerText -ne '4.5.0.0') {
    Fail "cancel during installer left marker '$markerText'"
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'quicklook-download tests passed'
exit 0
