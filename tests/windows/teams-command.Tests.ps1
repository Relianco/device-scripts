$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/teams/Invoke-Teams.ps1'

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

foreach ($name in @('Get-TeamsBootstrapperArgumentList', 'Get-TeamsClassicProductCodes', 'Get-TeamsClassicUserUninstall')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "$name was not defined"
    }
}

$msix = 'C:\Relian\cache\MSTeams-x64.msix'
$install = @(Get-TeamsBootstrapperArgumentList -Mode 'install' -MsixPath $msix)
$expectedInstall = @('-p', '-o', $msix, '--installTMA')
if ($install.Count -ne $expectedInstall.Count) {
    Fail "install argument count $($install.Count)"
}
for ($i = 0; $i -lt $expectedInstall.Count; $i++) {
    if ([string]$install[$i] -cne $expectedInstall[$i]) {
        Fail "install argument $i '$($install[$i])' expected '$($expectedInstall[$i])'"
    }
}
if ($install -contains '-x') {
    Fail 'install arguments contain -x'
}

$uninstall = @(Get-TeamsBootstrapperArgumentList -Mode 'uninstall' -MsixPath $msix)
if ($uninstall.Count -ne 1 -or [string]$uninstall[0] -cne '-x') {
    Fail "uninstall arguments '$($uninstall -join ' ')'"
}
if ($uninstall -contains '-p' -or $uninstall -contains '--installTMA') {
    Fail 'uninstall arguments contain an install flag'
}

$relative = Get-TeamsBootstrapperArgumentList -Mode 'install' -MsixPath 'MSTeams-x64.msix'
if ($null -ne $relative) {
    Fail 'a relative MSIX path was accepted'
}

$codes = @(Get-TeamsClassicProductCodes)
$expectedCodes = @(
    '{731F6BAA-A986-45A4-8936-7C3AAAAA760B}',
    '{39AF0813-FA7B-4860-ADBE-93B9B214B914}'
)
if ($codes.Count -ne 2 -or $codes[0] -cne $expectedCodes[0] -or $codes[1] -cne $expectedCodes[1]) {
    Fail "classic product codes '$($codes -join ' ')'"
}

$user = Get-TeamsClassicUserUninstall
if ([string]$user -cne '-uninstall -s') {
    Fail "classic user uninstall '$user'"
}

Write-Output 'teams-command tests passed'
exit 0
