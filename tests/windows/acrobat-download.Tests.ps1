$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/acrobat/Invoke-Acrobat.ps1'
$recordPath = Join-Path $repoRoot 'windows/releases/acrobat.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'assertion failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Acrobat.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Save-AcrobatPayload -ErrorAction SilentlyContinue)) {
    Fail 'Save-AcrobatPayload was not defined'
}

$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if ([string]$InstallerUrl -cne [string]$record.installerUrl -or [string]$InstallerSha256 -cne [string]$record.installerSha256) {
    Fail 'download defaults do not match windows/releases/acrobat.json'
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

function New-AcrobatUserInfoUrl {
    return -join @('https://', 'user', '@', 'example.invalid/acrobat.zip')
}

class AcrobatFakeHttpException : System.Exception {
    [object]$Response
    AcrobatFakeHttpException([int]$Status) : base('status') {
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('acrobat-download-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$dest = Join-Path $root 'payload.bin'
$good = $utf8.GetBytes('acrobat-payload')
$goodSha = Get-Sha $good
$script:DownloadCount = 0
$script:SetupCount = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:AcrobatErrorLog = [System.Collections.Generic.List[string]]::new()
$script:SeenUrls = [System.Collections.Generic.List[string]]::new()

function Reset-Hooks {
    $script:DownloadCount = 0
    $script:SetupCount = 0
    $script:Sleeps.Clear()
    $script:AcrobatErrorLog.Clear()
    $script:SeenUrls.Clear()
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:StartAcrobatSetup = {
        param($SetupPath)
        $script:SetupCount++
        return 0
    }
    $script:ExpandAcrobatArchive = { param($ZipPath, $Destination) }
    $script:ResolveAcrobatSetup = { param($ExtractRoot) return 'C:\Acrobat\setup.exe' }
    $script:ReadAcrobatInstalledVersion = { return '' }
}

$script:RetryDelay = {
    param($Seconds)
    $script:Sleeps.Add([int]$Seconds)
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $script:SeenUrls.Add([string]$Url)
    [System.IO.File]::WriteAllBytes($Destination, $good)
}
$code = [int](Save-AcrobatPayload -Url $InstallerUrl -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
    Fail "matching hash returned $code"
}

foreach ($edition in @('Standard', 'Pro')) {
    Reset-Hooks
    $markerRoot = Join-Path $root $edition
    $code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition $edition -InstalledVersion '' -MarkerText '' -InstallerUrl $InstallerUrl -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $markerRoot -Products @())
    if ($code -ne 0 -or $script:DownloadCount -ne 1 -or $script:SeenUrls.Count -ne 1 -or [string]$script:SeenUrls[0] -cne [string]$record.installerUrl) {
        Fail "$edition download returned $code url '$($script:SeenUrls -join ',')'"
    }
}
if ([string](Get-AcrobatInstallerUrlForEdition -Edition 'Standard' -InstallerUrl $InstallerUrl) -cne [string](Get-AcrobatInstallerUrlForEdition -Edition 'Pro' -InstallerUrl $InstallerUrl)) {
    Fail 'Standard and Pro did not accept the same pinned URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    [System.IO.File]::WriteAllBytes($Destination, $utf8.GetBytes('other'))
}
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 1 -or (Test-Path -LiteralPath $dest) -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "mismatch returned $code after $($script:DownloadCount) downloads and $($script:Sleeps.Count) sleeps"
}
if (($script:AcrobatErrorLog -join "`n") -like '*https://*') {
    Fail 'mismatch error included a URL'
}

Reset-Hooks
$code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition 'Pro' -InstalledVersion '' -MarkerText '' -InstallerUrl 'https://example.invalid/acrobat.zip' -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root -Products @())
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0 -or $script:SetupCount -ne 0) {
    Fail "mismatch action returned $code downloads $($script:DownloadCount) setup $($script:SetupCount) sleeps $($script:Sleeps.Count)"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
}
$code = [int](Save-AcrobatPayload -Url (New-AcrobatUserInfoUrl) -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 1 -or $script:DownloadCount -ne 0) {
    Fail "userinfo returned $code after $($script:DownloadCount) downloads"
}
if (($script:AcrobatErrorLog -join "`n") -like '*https://*') {
    Fail 'userinfo error included a URL'
}

Reset-Hooks
$code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition 'Standard' -InstalledVersion '' -MarkerText '' -InstallerUrl (New-AcrobatUserInfoUrl) -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root -Products @())
if ($code -ne 1 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
    Fail "userinfo action returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$code = [int](Save-AcrobatPayload -Url (New-AcrobatUserInfoUrl) -Destination $dest -Sha256 '' -Label 'installer')
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or (Test-Path -LiteralPath $dest)) {
    Fail "empty hash returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 '   ' -Label 'installer')
if ($code -ne 0 -or $script:DownloadCount -ne 0) {
    Fail "blank hash returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition 'Pro' -InstalledVersion '' -MarkerText '' -InstallerUrl $InstallerUrl -InstallerSha256 '' -CancelPath '' -MarkerRoot $root -Products @())
if ($code -ne 0 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
    Fail "empty hash action returned $code downloads $($script:DownloadCount) setup $($script:SetupCount)"
}

if (-not (Test-AcrobatDownloadIsTransient -ErrorRecord ([AcrobatFakeHttpException]::new(503)))) {
    Fail 'HTTP 503 on Response.StatusCode was not retried'
}
if (Test-AcrobatDownloadIsTransient -ErrorRecord ([AcrobatFakeHttpException]::new(404))) {
    Fail 'HTTP 404 on Response.StatusCode was retried'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 404 -Message 'https://example.invalid/missing'
}
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 1 -or $script:DownloadCount -ne 1 -or $script:Sleeps.Count -ne 0) {
    Fail "404 returned $code after $($script:DownloadCount) attempts and $($script:Sleeps.Count) sleeps"
}
if (($script:AcrobatErrorLog -join "`n") -like '*https://*') {
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
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 0 -or $script:Sleeps.Count -ne 1 -or $script:Sleeps[0] -ne 5) {
    Fail "503 then success returned $code sleeps $($script:Sleeps -join ',')"
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
if ($code -ne 1 -or $script:DownloadCount -ne 3) {
    Fail "three 503s returned $code after $($script:DownloadCount) attempts"
}
if ($script:Sleeps.Count -ne 2 -or $script:Sleeps[0] -ne 5 -or $script:Sleeps[1] -ne 20) {
    Fail "three 503s slept $($script:Sleeps -join ',')"
}
if (($script:AcrobatErrorLog -join "`n") -like '*https://*') {
    Fail '503 error included a URL'
}

Reset-Hooks
$script:DownloadFile = {
    param($Url, $Destination)
    $script:DownloadCount++
    $env:RELIAN_DEPLOY_CANCEL = '1'
    New-HttpFailure -Status 503 -Message 'https://example.invalid/busy'
}
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130 -or $script:SetupCount -ne 0) {
    Fail "cancel before the second attempt returned $code"
}

Reset-Hooks
$env:RELIAN_DEPLOY_CANCEL = '1'
$code = [int](Save-AcrobatPayload -Url 'https://example.invalid/acrobat.zip' -Destination $dest -Sha256 $goodSha -Label 'installer')
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130 -or $script:DownloadCount -ne 0) {
    Fail "cancel before download returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$cancelFile = Join-Path $root 'cancel.flag'
[System.IO.File]::WriteAllText($cancelFile, '1')
$code = [int](Invoke-AcrobatAction -Action 'Install' -PinVersion '1.0.0.0' -Edition 'Pro' -InstalledVersion '' -MarkerText '' -InstallerUrl $InstallerUrl -InstallerSha256 $goodSha -CancelPath $cancelFile -MarkerRoot $root -Products @())
if ($code -ne 130 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
    Fail "CancelPath returned $code after $($script:DownloadCount) downloads"
}

Reset-Hooks
$env:RELIAN_DEPLOY_CANCEL = '1'
$code = [int](Invoke-AcrobatAction -Action 'Update' -PinVersion '1.0.0.0' -Edition 'Standard' -InstalledVersion '' -MarkerText '' -InstallerUrl $InstallerUrl -InstallerSha256 $goodSha -CancelPath '' -MarkerRoot $root -Products @())
Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
if ($code -ne 130 -or $script:DownloadCount -ne 0 -or $script:SetupCount -ne 0) {
    Fail "action cancel returned $code after $($script:DownloadCount) downloads"
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'acrobat-download tests passed'
exit 0
