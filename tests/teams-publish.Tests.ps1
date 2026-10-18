$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts/publish-teams.ps1'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'publish-teams.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-TeamsBlobName -ErrorAction SilentlyContinue)) {
    Fail 'Get-TeamsBlobName was not defined'
}

$bootName = Get-TeamsBlobName -Kind bootstrapper -Sha256 'c9d1c68b1f9048e6d04bc4313a4036f91c255df0988c4d876f687b5c1140440d'
$msixName = Get-TeamsBlobName -Kind msix -Sha256 '1bd28e184c0ec8572a8674560cd3f00e7cef002fe4471ccb9198f50d57391993'
if ($bootName -cne 'teamsbootstrapper-c9d1c68b1f9048e6d04bc4313a4036f91c255df0988c4d876f687b5c1140440d.exe') {
    Fail "bootstrapper blob name '$bootName'"
}
if ($msixName -cne 'MSTeams-x64-1bd28e184c0ec8572a8674560cd3f00e7cef002fe4471ccb9198f50d57391993.msix') {
    Fail "msix blob name '$msixName'"
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('teams-publish-' + [guid]::NewGuid().ToString('n'))
$cache = Join-Path $root 'cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$bootBytes = $utf8.GetBytes('teams-boot')
$msixBytes = $utf8.GetBytes('teams-msix')
[System.IO.File]::WriteAllBytes((Join-Path $cache 'teamsbootstrapper.exe'), $bootBytes)
[System.IO.File]::WriteAllBytes((Join-Path $cache 'MSTeams-x64.msix'), $msixBytes)

function Get-Sha {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$bootSha = Get-Sha $bootBytes
$msixSha = Get-Sha $msixBytes
$recordPath = Join-Path $root 'teams.json'
$record = [ordered]@{
    name                  = 'Microsoft Teams'
    arch                  = 'x64'
    bootstrapperSourceUrl = 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409'
    bootstrapperFile      = 'teamsbootstrapper.exe'
    bootstrapperSha256    = $bootSha
    bootstrapperSize      = $bootBytes.Length
    msixSourceUrl         = 'https://go.microsoft.com/fwlink/?linkid=2196106'
    msixFile              = 'MSTeams-x64.msix'
    msixSha256            = $msixSha
    msixSize              = $msixBytes.Length
    blobBase              = 'https://relianpub.blob.core.windows.net/pub/sec/'
}
$record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8

$calls = [System.Collections.Generic.List[object]]::new()
$script:InvokeAz = {
    param([string[]]$ArgumentList)
    $calls.Add(@($ArgumentList))
    throw 'InvokeAz must not run during a dry run'
}

$dry = Publish-TeamsBlobs -RecordPath $recordPath -CacheRoot $cache | Out-String
if ($calls.Count -ne 0) {
    Fail 'dry run called InvokeAz'
}
$base = 'https://relianpub.blob.core.windows.net/pub/sec/'
$expectBoot = $base + (Get-TeamsBlobName -Kind bootstrapper -Sha256 $bootSha)
$expectMsix = $base + (Get-TeamsBlobName -Kind msix -Sha256 $msixSha)
if ($dry -notlike "*$expectBoot*") {
    Fail "dry run missed $expectBoot"
}
if ($dry -notlike "*$expectMsix*") {
    Fail "dry run missed $expectMsix"
}

$calls.Clear()
$script:ExistsCount = 0
$script:InvokeAz = {
    param([string[]]$ArgumentList)
    $calls.Add(@($ArgumentList))
    $flat = $ArgumentList -join ' '
    if ($flat -match '\bexists\b') {
        $script:ExistsCount++
        if ($script:ExistsCount -eq 1) { return 'false' }
        return 'true'
    }
    return ''
}

Publish-TeamsBlobs -RecordPath $recordPath -CacheRoot $cache -Publish | Out-Null
$uploads = @($calls | Where-Object { ($_ -join ' ') -match '\bupload\b' })
if ($uploads.Count -ne 1) {
    Fail "expected one upload, saw $($uploads.Count)"
}
$upload = @($uploads[0])
$blobName = Get-TeamsBlobName -Kind bootstrapper -Sha256 $bootSha
foreach ($needle in @('--auth-mode', 'login', 'relianpub', 'pub', ('sec/' + $blobName))) {
    if ($upload -notcontains $needle) {
        Fail "upload arguments missing $needle"
    }
}

$calls.Clear()
$script:InvokeAz = {
    param([string[]]$ArgumentList)
    $calls.Add(@($ArgumentList))
    throw 'InvokeAz must not run after a hash mismatch'
}
[System.IO.File]::WriteAllBytes((Join-Path $cache 'teamsbootstrapper.exe'), $utf8.GetBytes('tampered'))
$threw = $false
try {
    Publish-TeamsBlobs -RecordPath $recordPath -CacheRoot $cache -Publish | Out-Null
} catch {
    $threw = $true
}
if (-not $threw) {
    Fail 'hash mismatch did not throw'
}
if ($calls.Count -ne 0) {
    Fail 'hash mismatch called InvokeAz'
}

Remove-Item -LiteralPath $root -Recurse -Force
Write-Output 'teams-publish tests passed'
exit 0
