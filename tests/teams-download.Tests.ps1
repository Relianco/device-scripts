$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/teams/Invoke-Teams.ps1'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Teams.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-TeamsPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-TeamsPayload was not defined'
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

function New-TeamsUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/bootstrapper')
}

class TeamsFakeHttpException : System.Exception {
    [object]$Response
    TeamsFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('teams-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('teams-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:TeamsErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:Sleeps.Clear()
    $script:TeamsErrorLog.Clear()
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
}

$script:RetryDelay = {
    param($Seconds)
    $script:Sleeps.Add([int]$Seconds)
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = Save-TeamsPayload -Url 'https://example.invalid/bootstrapper' -Destination $dest -Sha256 $goodSha -Label 'bootstrapper'
if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
    Fail "matching hash returned $code"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = Save-TeamsPayload -Url 'https://example.invalid/bootstrapper' -Destination $dest -Sha256 $goodSha -Label 'bootstrapper'
$logged = $script:TeamsErrorLog -join "`n"
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
$code = Save-TeamsPayload -Url (New-TeamsUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'bootstrapper'
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo returned $code after $($script:DownloadCount) downloads"
}
if (($script:TeamsErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Hooks
$code = Save-TeamsPayload -Url (New-TeamsUserInfoUrl) -Destination $dest -Sha256 '' -Label 'bootstrapper'
if ($code -ne 0 -or $script:DownloadCount -ne 0) {
    Fail "empty hash returned $code after $($script:DownloadCount) downloads"
}
if (-not (Test-TeamsDownloadIsTransient -ErrorRecord ([TeamsFakeHttpException]::new(503)))) {
    Fail 'HTTP 503 on Response.StatusCode was not retried'
}
if (Test-TeamsDownloadIsTransient -ErrorRecord ([TeamsFakeHttpException]::new(404))) {
    Fail 'HTTP 404 on Response.StatusCode was retried'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
}
$code = Save-TeamsPayload -Url 'https://example.invalid/bootstrapper' -Destination $dest -Sha256 $goodSha -Label 'bootstrapper'
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
}
if (($script:TeamsErrorLog -join "`n") -like '*https://*') {
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
$code = Save-TeamsPayload -Url 'https://example.invalid/msix' -Destination $dest -Sha256 $goodSha -Label 'msix'
if ($code -ne 0 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
    Fail "503 then success returned $code sleeps $($script:Sleeps -join ',')"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = Save-TeamsPayload -Url 'https://example.invalid/msix' -Destination $dest -Sha256 $goodSha -Label 'msix'
if ($code -ne 1 -or $script:DownloadCount -ne 3) {
    Fail "three 503s returned $code after $($script:DownloadCount) attempts"
}
if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
    Fail "three 503s slept $($script:Sleeps -join ',')"
}
if (($script:TeamsErrorLog -join "`n") -like '*https://*') {
    Fail '503 error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = Save-TeamsPayload -Url 'https://example.invalid/msix' -Destination $dest -Sha256 $goodSha -Label 'msix'
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130) {
    Fail "cancel before the second attempt returned $code"
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'teams-download tests passed'
exit 0
