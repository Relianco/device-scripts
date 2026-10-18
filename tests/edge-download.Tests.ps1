$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/edge/Invoke-Edge.ps1'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Edge.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-EdgePayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-EdgePayload was not defined'
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

function New-EdgeUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/MicrosoftEdgeEnterpriseX64.msi')
}

class EdgeFakeHttpException : System.Exception {
    [object]$Response
    EdgeFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'MicrosoftEdgeEnterpriseX64.msi'
$good = $utf8.GetBytes('edge-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:InstallerCalls = 0
$script:EdgeErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:InstallerCalls = 0
    $script:Sleeps.Clear()
    $script:EdgeErrorLog.Clear()
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
$script:ReadInstalledVersion = { return '2.0.0.0' }

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
    Fail "matching hash returned $code"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
$logged = $script:EdgeErrorLog -join "`n"
if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}
if ($logged -like '*https://*') {
    Fail 'mismatch error included a URL'
}

Reset-Hooks
$marker = Join-Path $root 'action-marker'
New-Item -ItemType Directory -Path $marker -Force | Out-Null
$code = Invoke-EdgeAction -Action 'Install' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $dest
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "mismatch action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}
if (Test-Path -LiteralPath (Join-Path $marker 'marker.txt')) {
    Fail 'mismatch action wrote a marker'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$code = Save-EdgePayload -Url (New-EdgeUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo returned $code after $($script:DownloadCount) downloads"
}
if (($script:EdgeErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Hooks
$code = Invoke-EdgeAction -Action 'Install' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl (New-EdgeUserInfoUrl) -InstallerSha256 $goodSha -InstallerPath $dest
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerCalls -ne 0) {
    Fail "userinfo action returned $code after $($script:DownloadCount) downloads and $($script:InstallerCalls) installer calls"
}

Reset-Hooks
foreach ($status in @(408, 429, 500, 502, 503, 504)) {
    if (-not (Test-EdgeDownloadIsTransient -ErrorRecord ([EdgeFakeHttpException]::new($status)))) {
        Fail "HTTP $status on Response.StatusCode was not retried"
    }
}
foreach ($status in @(404, 403, 401)) {
    if (Test-EdgeDownloadIsTransient -ErrorRecord ([EdgeFakeHttpException]::new($status))) {
        Fail "HTTP $status on Response.StatusCode was retried"
    }
}
if (-not (Test-EdgeDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
    Fail 'timeout was not retried'
}
if (-not (Test-EdgeDownloadIsTransient -ErrorRecord ([System.Net.Sockets.SocketException]::new(11001)))) {
    Fail 'DNS socket failure was not retried'
}
$dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
if (-not (Test-EdgeDownloadIsTransient -ErrorRecord $dns)) {
    Fail 'DNS WebException was not retried'
}
$connect = [System.Net.WebException]::new('connect', [System.Net.WebExceptionStatus]::ConnectFailure)
if (-not (Test-EdgeDownloadIsTransient -ErrorRecord $connect)) {
    Fail 'connection WebException was not retried'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 404 -Message 'missing'
}
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
}
if (($script:EdgeErrorLog -join "`n") -like '*https://*') {
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
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
    Fail "503 then success returned $code sleeps $($script:Sleeps -join ',')"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 503 -Message 'busy'
}
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 3) {
    Fail "three 503s returned $code after $($script:DownloadCount) attempts"
}
if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
    Fail "three 503s slept $($script:Sleeps -join ',')"
}
if (($script:EdgeErrorLog -join "`n") -like '*https://*') {
    Fail '503 error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    New-HttpFailure -Status 503 -Message 'busy'
}
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer'
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
$code = Save-EdgePayload -Url 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -Destination $dest -Sha256 $goodSha -Label 'installer' -CancelPath $cancel
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
$code = Invoke-EdgeAction -Action 'Install' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $dest
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
$code = Invoke-EdgeAction -Action 'Install' -PinVersion '2.0.0.0' -InstalledVersion '' -MarkerRoot $marker -InstallerUrl 'https://example.invalid/MicrosoftEdgeEnterpriseX64.msi' -InstallerSha256 $goodSha -InstallerPath $dest
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 0 -or $script:InstallerCalls -ne 1) {
    Fail "cancel during installer returned $code after $($script:InstallerCalls) installer calls"
}
$markerText = ''
$markerFile = Join-Path $marker 'marker.txt'
if (Test-Path -LiteralPath $markerFile) {
    $markerText = [System.IO.File]::ReadAllText($markerFile)
}
if ($markerText -ne '2.0.0.0') {
    Fail "cancel during installer left marker '$markerText'"
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'edge-download tests passed'
exit 0
