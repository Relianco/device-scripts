# File parameters are not Mandatory. Dot-sourcing under RELIAN_DEPLOY_TEST
# defines the pin checks and does not download.
[CmdletBinding()]
param(
    [string]$RecordPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/releases/teams.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TeamsPinKeys = @(
    'name', 'arch',
    'bootstrapperSourceUrl', 'bootstrapperFile', 'bootstrapperSha256', 'bootstrapperSize',
    'msixSourceUrl', 'msixFile', 'msixSha256', 'msixSize',
    'blobBase'
)

function Get-TeamsPinHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-TeamsPinRecord {
    param($Record)
    if ($null -eq $Record) {
        return $false
    }
    foreach ($key in $script:TeamsPinKeys) {
        if ($null -eq $Record.PSObject.Properties[$key]) {
            return $false
        }
    }
    if ([string]$Record.name -cne 'Microsoft Teams') {
        return $false
    }
    if ([string]$Record.arch -cne 'x64') {
        return $false
    }
    if ([string]$Record.blobBase -cne 'https://relianpub.blob.core.windows.net/pub/sec/') {
        return $false
    }
    if ([string]$Record.bootstrapperSourceUrl -cne 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409') {
        return $false
    }
    if ([string]$Record.msixSourceUrl -cne 'https://go.microsoft.com/fwlink/?linkid=2196106') {
        return $false
    }
    foreach ($hashName in @('bootstrapperSha256', 'msixSha256')) {
        if ([string]$Record.$hashName -cnotmatch '^[0-9a-f]{64}$') {
            return $false
        }
    }
    foreach ($sizeName in @('bootstrapperSize', 'msixSize')) {
        $sizeText = [string]$Record.$sizeName
        $size = 0L
        if (-not [int64]::TryParse($sizeText, [ref]$size) -or $size -le 0) {
            return $false
        }
    }
    foreach ($fileName in @('bootstrapperFile', 'msixFile')) {
        $file = [string]$Record.$fileName
        if ([string]::IsNullOrWhiteSpace($file) -or $file.Contains('/') -or $file.Contains('\') -or $file.Contains('..')) {
            return $false
        }
    }
    return $true
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$script:ExitCode = 1
try {
    if (-not (Test-Path -LiteralPath $RecordPath)) {
        [Console]::Error.WriteLine('teams pin record missing')
    } else {
        $record = [System.IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json
        if (Test-TeamsPinRecord -Record $record) {
            $script:ExitCode = 0
        } else {
            [Console]::Error.WriteLine('teams pin record is invalid')
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
