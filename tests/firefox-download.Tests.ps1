$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/firefox/Invoke-Firefox.ps1'
$pinPath = Join-Path $repoRoot 'releases/firefox.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Firefox.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $pinPath)) {
    Fail 'releases/firefox.json does not exist'
}

$pin = Get-Content -LiteralPath $pinPath -Raw -Encoding utf8 | ConvertFrom-Json
$expectedUrl = 'https://archive.mozilla.org/pub/firefox/releases/158.0/win64/en-US/Firefox%20Setup%20158.0.msi'
$expectedSha = 'f1c8fae86653ecae39f47c909bfec04033598dd5f9229577f8114ebc2b48176f'
if ([string]$pin.version -cne '158.0') {
    Fail "json version $($pin.version)"
}
if ([string]$pin.productVersion -cne '158.0.0.0') {
    Fail "json productVersion $($pin.productVersion)"
}
if ([string]$pin.sourceUrl -cne $expectedUrl) {
    Fail 'json sourceUrl is not the 158.0 win64 en-US MSI'
}
if ([string]$pin.sourceUrl -match 'latest') {
    Fail 'json sourceUrl is a latest redirect'
}
if ([string]$pin.sha256 -cne $expectedSha) {
    Fail 'json sha256 does not match the hashed MSI'
}
if ([int64]$pin.size -ne 95043584) {
    Fail "json size $($pin.size)"
}
if ([string]$pin.arch -cne 'win64' -or [string]$pin.locale -cne 'en-US') {
    Fail 'json arch or locale is wrong'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-FirefoxPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-FirefoxPayload was not defined'
}
if ($InstallerUrl -cne $expectedUrl) {
    Fail 'InstallerUrl default does not match releases/firefox.json'
}
if ($InstallerSha256 -cne $expectedSha) {
    Fail 'InstallerSha256 default does not match releases/firefox.json'
}
if ($null -eq $script:DownloadFile -or $null -eq $script:RetryDelay -or $null -eq $script:StartInstaller) {
    Fail 'download hooks were not defined'
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

function New-FirefoxUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/firefox.msi')
}

class FirefoxFakeHttpException : System.Exception {
    [object]$Response
    FirefoxFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('firefox-payload')
$goodSha = Get-Sha $good
$plainUrl = 'https://example.invalid/firefox.msi'
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:InstallerModes = [System.Collections.Generic.List[string]]::new()
$script:FirefoxErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:Sleeps.Clear()
    $script:InstallerModes.Clear()
    $script:FirefoxErrorLog.Clear()
    $script:InstalledNow = ''
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:GetInstalledVersion = { return [string]$script:InstalledNow }
    $script:GetUninstallTarget = { return 'helper.exe' }
    $script:RetryDelay = {
        param($Seconds)
        $script:Sleeps.Add([int]$Seconds)
    }
    $script:StartInstaller = {
        param($Mode, $TargetPath)
        $script:InstallerModes.Add([string]$Mode)
        return 0
    }
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
    Fail "matching hash returned $code"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
$logged = $script:FirefoxErrorLog -join "`n"
if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}
if ($logged -like '*https://*') {
    Fail 'mismatch error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$code = Save-FirefoxPayload -Url (New-FirefoxUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo returned $code after $($script:DownloadCount) downloads"
}
if (($script:FirefoxErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Hooks
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 '' -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "empty hash returned $code after $($script:DownloadCount) downloads"
}

foreach ($status in @(408, 429, 500, 502, 503, 504)) {
    if (-not (Test-FirefoxDownloadIsTransient -ErrorRecord ([FirefoxFakeHttpException]::new($status)))) {
        Fail "HTTP $status on Response.StatusCode was not retried"
    }
}
foreach ($status in @(400, 401, 403, 404, 409)) {
    if (Test-FirefoxDownloadIsTransient -ErrorRecord ([FirefoxFakeHttpException]::new($status))) {
        Fail "HTTP $status on Response.StatusCode was retried"
    }
}
if (-not (Test-FirefoxDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
    Fail 'timeout was not retried'
}
if (-not (Test-FirefoxDownloadIsTransient -ErrorRecord ([System.Net.Sockets.SocketException]::new()))) {
    Fail 'socket failure was not retried'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
}
if (($script:FirefoxErrorLog -join "`n") -like '*https://*') {
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
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 0 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
    Fail "503 then success returned $code sleeps $($script:Sleeps -join ',')"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
if ($code -ne 1 -or $script:DownloadCount -ne 3) {
    Fail "three 503s returned $code after $($script:DownloadCount) attempts"
}
if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
    Fail "three 503s slept $($script:Sleeps -join ',')"
}
if (($script:FirefoxErrorLog -join "`n") -like '*https://*') {
    Fail '503 error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer'
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130) {
    Fail "cancel before the second attempt returned $code"
}

Reset-Hooks
$cancelFile = Join-Path $root 'cancel.flag'
New-Item -ItemType File -Path $cancelFile -Force | Out-Null
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$code = Save-FirefoxPayload -Url $plainUrl -Destination $dest -Sha256 $goodSha -Label 'installer' -CancelPath $cancelFile
if ($code -ne 130 -or $script:DownloadCount -ne 0) {
    Fail "CancelPath returned $code after $($script:DownloadCount) downloads"
}
Remove-Item -LiteralPath $cancelFile -Force

function Invoke-Install {
    param(
        [string]$Url,
        [string]$Sha,
        [string]$Cancel = ''
    )
    return [int](Invoke-FirefoxAction -Action 'Install' -PinVersion '158.0' -InstallerUrl $Url -InstallerSha256 $Sha -CancelPath $Cancel -MarkerRoot $root)
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$userinfoCode = Invoke-Install -Url (New-FirefoxUserInfoUrl) -Sha $goodSha
if ($userinfoCode -ne 1 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0) {
    Fail "userinfo action returned $userinfoCode downloads $($script:DownloadCount) installer $($script:InstallerModes.Count)"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$mismatchCode = Invoke-Install -Url $plainUrl -Sha $goodSha
if ($mismatchCode -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or $script:InstallerModes.Count -ne 0) {
    Fail "mismatch action returned $mismatchCode downloads $($script:DownloadCount) installer $($script:InstallerModes.Count)"
}

Reset-Hooks
New-Item -ItemType File -Path $cancelFile -Force | Out-Null
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$cancelCode = Invoke-Install -Url $plainUrl -Sha $goodSha -Cancel $cancelFile
if ($cancelCode -ne 130 -or $script:DownloadCount -ne 0 -or $script:InstallerModes.Count -ne 0) {
    Fail "cancel action returned $cancelCode downloads $($script:DownloadCount) installer $($script:InstallerModes.Count)"
}

Remove-Item -LiteralPath $root -Recurse -Force
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
Write-Output 'firefox-download tests passed'
exit 0
