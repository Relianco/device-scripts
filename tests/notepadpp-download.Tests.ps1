$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/notepadpp/Invoke-Notepadpp.ps1'

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

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-NotepadppPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-NotepadppPayload was not defined'
}
if (-not (Get-Command Test-NotepadppPlaceholderHash -ErrorAction SilentlyContinue)) {
    Fail 'Test-NotepadppPlaceholderHash was not defined'
}

$releasePath = Join-Path $repoRoot 'releases/notepadpp.json'
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'releases/notepadpp.json does not exist'
}
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pinnedSha = [string]$release.sha256
if ($pinnedSha -cne '26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da') {
    Fail 'sha256 does not match the downloaded installer'
}
if ($InstallerSha256 -cne $pinnedSha) {
    Fail 'script defaults do not match releases/notepadpp.json'
}
if (Test-NotepadppPlaceholderHash -Sha256 $pinnedSha) {
    Fail 'pinned sha256 was treated as a placeholder'
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

function New-NotepadppUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/npp.exe')
}

class NotepadppFakeHttpException : System.Exception {
    [object]$Response
    NotepadppFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('notepadpp-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('notepadpp-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:NotepadppErrorLog = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:Sleeps.Clear()
    $script:NotepadppErrorLog.Clear()
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
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
        Fail "matching hash returned $code"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
    }
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    $logged = $script:NotepadppErrorLog -join "`n"
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
    $code = Save-NotepadppPayload -Url (New-NotepadppUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:NotepadppErrorLog -join "`n") -like '*https://*') {
        Fail 'userinfo error included a URL'
    }

    Reset-Hooks
    $code = Save-NotepadppPayload -Url (New-NotepadppUserInfoUrl) -Destination $dest -Sha256 '' -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 0) {
        Fail "userinfo with an empty hash returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 '' -Label 'installer'
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "empty hash returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 '   ' -Label 'installer'
    if ($code -ne 0 -or $script:DownloadCount -ne 0) {
        Fail "whitespace hash returned $code after $($script:DownloadCount) downloads"
    }

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
        if (-not (Test-NotepadppPlaceholderHash -Sha256 $row.Hash)) {
            Fail "$($row.Label) was not a placeholder"
        }
        Reset-Hooks
        $script:DownloadFile = {
            param($Url, $Destination)
            $script:DownloadCount++
            [System.IO.File]::WriteAllBytes($Destination, $good)
        }
        $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $row.Hash -Label 'installer'
        if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:Sleeps.Count -ne 0 -or (Test-Path -LiteralPath $dest)) {
            Fail "$($row.Label) returned $code after $($script:DownloadCount) downloads"
        }
        if (($script:NotepadppErrorLog -join "`n") -notlike '*placeholder*') {
            Fail "$($row.Label) error did not name placeholder"
        }
        if (($script:NotepadppErrorLog -join "`n") -like '*https://*') {
            Fail "$($row.Label) error included a URL"
        }
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        [System.IO.File]::WriteAllBytes($Destination, $good)
    }
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $pinnedSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or (Test-Path -LiteralPath $dest)) {
        Fail "pinned sha mismatch returned $code after $($script:DownloadCount) downloads"
    }
    if (($script:NotepadppErrorLog -join "`n") -like '*placeholder*') {
        Fail 'pinned sha256 was refused as a placeholder'
    }

    foreach ($status in @(408, 429, 500, 502, 503, 504)) {
        if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord ([NotepadppFakeHttpException]::new($status)))) {
            Fail "HTTP $status on Response.StatusCode was not retried"
        }
    }
    foreach ($status in @(404, 400, 401)) {
        if (Test-NotepadppDownloadIsTransient -ErrorRecord ([NotepadppFakeHttpException]::new($status))) {
            Fail "HTTP $status on Response.StatusCode was retried"
        }
    }
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord ([System.TimeoutException]::new('timed out')))) {
        Fail 'timeout was not retried'
    }
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord ([System.Threading.Tasks.TaskCanceledException]::new('timed out')))) {
        Fail 'task cancel was not retried'
    }
    $socket = [System.Net.Sockets.SocketException]::new()
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord $socket)) {
        Fail 'socket failure was not retried'
    }
    $wrapped = [System.Exception]::new('wrapped', $socket)
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord $wrapped)) {
        Fail 'wrapped socket failure was not retried'
    }
    $dns = [System.Net.WebException]::new('dns', [System.Net.WebExceptionStatus]::NameResolutionFailure)
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord $dns)) {
        Fail 'DNS failure was not retried'
    }
    if (Test-NotepadppDownloadIsTransient -ErrorRecord ([System.Exception]::new('nope'))) {
        Fail 'a generic failure was retried'
    }
    $secure = [System.Net.Http.HttpRequestException]::new(
        [System.Net.Http.HttpRequestError]::SecureConnectionError,
        'tls',
        $null,
        $null
    )
    if (-not (Test-NotepadppDownloadIsTransient -ErrorRecord $secure)) {
        Fail 'SecureConnectionError was not retried'
    }
    $auth = [System.Net.Http.HttpRequestException]::new(
        [System.Net.Http.HttpRequestError]::UserAuthenticationError,
        'auth',
        $null,
        $null
    )
    if (Test-NotepadppDownloadIsTransient -ErrorRecord $auth) {
        Fail 'UserAuthenticationError was retried'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
    }
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
        Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
    }
    if (($script:NotepadppErrorLog -join "`n") -like '*https://*') {
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
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
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
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 0 -or $script:DownloadCount -ne 2 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
        Fail "socket then success returned $code after $($script:DownloadCount) downloads sleeps $($script:Sleeps -join ',')"
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    if ($code -ne 1 -or $script:DownloadCount -ne 3) {
        Fail "three 503s returned $code after $($script:DownloadCount) attempts"
    }
    if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
        Fail "three 503s slept $($script:Sleeps -join ',')"
    }
    if (($script:NotepadppErrorLog -join "`n") -like '*https://*') {
        Fail '503 error included a URL'
    }

    Reset-Hooks
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:DownloadCount++
        $env:RELIAN_DEPLOY_CANCEL = '1'
        New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
    }
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer'
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if ($code -ne 130 -or $script:DownloadCount -ne 1) {
        Fail "cancel before the second attempt returned $code after $($script:DownloadCount) downloads"
    }

    Reset-Hooks
    $cancel = Join-Path $root 'cancel.flag'
    New-Item -ItemType File -Path $cancel -Force | Out-Null
    $code = Save-NotepadppPayload -Url 'https://example.invalid/npp.exe' -Destination $dest -Sha256 $goodSha -Label 'installer' -CancelPath $cancel
    if ($code -ne 130 -or $script:DownloadCount -ne 0) {
        Fail "cancel path returned $code after $($script:DownloadCount) downloads"
    }
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'notepadpp-download tests passed'
exit 0
