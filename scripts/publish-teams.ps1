# File parameters are not Mandatory. A mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [switch]$Publish,
    [string]$RecordPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'releases/teams.json'),
    [string]$CacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'releases/cache')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# One argument per array element. Never a single command string.
$script:InvokeAz = {
    param([string[]]$ArgumentList)
    $output = & az @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "az exited $LASTEXITCODE"
    }
    return $output
}

function Get-TeamsBlobName {
    param(
        [string]$Kind,
        [string]$Sha256
    )
    $sha = ([string]$Sha256).Trim().ToLowerInvariant()
    if ($sha -notmatch '^[0-9a-f]{64}$') {
        throw 'sha256 is invalid'
    }
    if ($Kind -eq 'bootstrapper') {
        return "teamsbootstrapper-$sha.exe"
    }
    if ($Kind -eq 'msix') {
        return "MSTeams-x64-$sha.msix"
    }
    throw 'kind is invalid'
}

function Get-TeamsAzText {
    param($Output)
    if ($null -eq $Output) {
        return ''
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Output)) {
        if ($null -eq $item) {
            continue
        }
        [void]$parts.Add([string]$item)
    }
    return ($parts.ToArray() -join "`n").Trim()
}

function Test-TeamsBlobExists {
    param([string]$BlobName)
    $argList = @(
        'storage', 'blob', 'exists',
        '--auth-mode', 'login',
        '--account-name', 'relianpub',
        '-c', 'pub',
        '-n', ('sec/' + $BlobName),
        '--query', 'exists',
        '-o', 'tsv'
    )
    $output = & $script:InvokeAz -ArgumentList $argList
    $text = Get-TeamsAzText $output
    if ($text.Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($text.Equals('false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    throw 'unexpected blob exists result'
}

function Send-TeamsBlob {
    param(
        [string]$BlobName,
        [string]$LocalFile
    )
    $argList = @(
        'storage', 'blob', 'upload',
        '--auth-mode', 'login',
        '--account-name', 'relianpub',
        '-c', 'pub',
        '-n', ('sec/' + $BlobName),
        '-f', $LocalFile,
        '--no-progress',
        '-o', 'none'
    )
    [void](& $script:InvokeAz -ArgumentList $argList)
}

function Publish-TeamsBlobs {
    param(
        [switch]$Publish,
        [string]$RecordPath,
        [string]$CacheRoot
    )
    if (-not (Test-Path -LiteralPath $RecordPath)) {
        throw 'teams record missing'
    }
    $record = [System.IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json
    $base = [string]$record.blobBase
    if (-not $base.EndsWith('/')) {
        $base = $base + '/'
    }
    $bootBlob = Get-TeamsBlobName -Kind bootstrapper -Sha256 ([string]$record.bootstrapperSha256)
    $msixBlob = Get-TeamsBlobName -Kind msix -Sha256 ([string]$record.msixSha256)
    Write-Output ($base + $bootBlob)
    Write-Output ($base + $msixBlob)
    if (-not $Publish) {
        return
    }

    $items = @(
        @{
            File = [string]$record.bootstrapperFile
            Sha  = ([string]$record.bootstrapperSha256).Trim().ToLowerInvariant()
            Size = [int64]$record.bootstrapperSize
            Blob = $bootBlob
        }
        @{
            File = [string]$record.msixFile
            Sha  = ([string]$record.msixSha256).Trim().ToLowerInvariant()
            Size = [int64]$record.msixSize
            Blob = $msixBlob
        }
    )
    foreach ($item in $items) {
        $path = Join-Path $CacheRoot $item.File
        if (-not (Test-Path -LiteralPath $path)) {
            throw "payload missing $($item.File)"
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if (-not $actual.Equals($item.Sha, [System.StringComparison]::Ordinal)) {
            throw "hash mismatch for $($item.File)"
        }
        $actualSize = [int64](Get-Item -LiteralPath $path).Length
        if ($actualSize -ne $item.Size) {
            throw "size mismatch for $($item.File)"
        }
        if (Test-TeamsBlobExists -BlobName $item.Blob) {
            continue
        }
        Send-TeamsBlob -BlobName $item.Blob -LocalFile $path
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$script:ExitCode = 1
try {
    Publish-TeamsBlobs -Publish:$Publish -RecordPath $RecordPath -CacheRoot $CacheRoot
    $script:ExitCode = 0
} catch {
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
