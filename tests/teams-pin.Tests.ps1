$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'scripts/pin-teams.ps1'
$recordPath = Join-Path $repoRoot 'releases/teams.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'pin-teams.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if (-not (Get-Command Get-TeamsPinHash -ErrorAction SilentlyContinue)) {
    Fail 'Get-TeamsPinHash was not defined'
}
if (-not (Get-Command Test-TeamsPinRecord -ErrorAction SilentlyContinue)) {
    Fail 'Test-TeamsPinRecord was not defined'
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('teams-pin-' + [guid]::NewGuid().ToString('n'))
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllBytes($temp, $utf8.GetBytes('teams-pin'))
try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $expected = ([System.BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes('teams-pin')))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $actual = Get-TeamsPinHash -Path $temp
    if ([string]$actual -cne $expected) {
        Fail "Get-TeamsPinHash '$actual' expected '$expected'"
    }
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

$short = [pscustomobject]@{
    name                 = 'Microsoft Teams'
    arch                 = 'x64'
    bootstrapperSourceUrl = 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409'
    bootstrapperFile     = 'teamsbootstrapper.exe'
    bootstrapperSha256   = 'abc'
    bootstrapperSize     = 1
    msixSourceUrl        = 'https://go.microsoft.com/fwlink/?linkid=2196106'
    msixFile             = 'MSTeams-x64.msix'
    msixSha256           = '1bd28e184c0ec8572a8674560cd3f00e7cef002fe4471ccb9198f50d57391993'
    msixSize             = 1
    blobBase             = 'https://relianpub.blob.core.windows.net/pub/sec/'
}
if (Test-TeamsPinRecord -Record $short) {
    Fail 'a short hash was accepted'
}

$missing = [pscustomobject]@{
    name                 = 'Microsoft Teams'
    arch                 = 'x64'
    bootstrapperSourceUrl = 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409'
    bootstrapperFile     = 'teamsbootstrapper.exe'
    bootstrapperSha256   = 'c9d1c68b1f9048e6d04bc4313a4036f91c255df0988c4d876f687b5c1140440d'
    bootstrapperSize     = 1
    msixSourceUrl        = 'https://go.microsoft.com/fwlink/?linkid=2196106'
    msixFile             = 'MSTeams-x64.msix'
    msixSize             = 1
    blobBase             = 'https://relianpub.blob.core.windows.net/pub/sec/'
}
if (Test-TeamsPinRecord -Record $missing) {
    Fail 'a record missing msixSha256 was accepted'
}

if (-not (Test-Path -LiteralPath $recordPath)) {
    Fail 'releases/teams.json does not exist'
}
$record = Get-Content -LiteralPath $recordPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not (Test-TeamsPinRecord -Record $record)) {
    Fail 'releases/teams.json failed Test-TeamsPinRecord'
}

Write-Output 'teams-pin tests passed'
exit 0
