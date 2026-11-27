# Script parameters are not Mandatory: a mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [switch]$Publish,
    [string]$BrandRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/brand/relian'),
    [string]$ToolkitRecord = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/releases/psadt.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ExitCode = 1
$script:BrandZipPath = $null

# One argument per array element. Never a single command string.
$script:InvokeAz = {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $output = & az @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "az exited $LASTEXITCODE"
    }
    return $output
}

function Write-RelianPublishError {
    param([Parameter(Mandatory)][string]$Message)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        return
    }
    [Console]::Error.WriteLine($Message)
}

function Test-RelianPublishUrlHasUserInfo {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    try {
        $uri = [Uri]$Url
    } catch {
        return $false
    }
    if (-not $uri.IsAbsoluteUri) {
        return $false
    }
    return -not [string]::IsNullOrEmpty($uri.UserInfo)
}

function Test-RelianPublishSourceUrl {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    try {
        $uri = [Uri]$Url
    } catch {
        return $false
    }
    if (-not $uri.IsAbsoluteUri) {
        return $false
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $false
    }
    return $uri.Scheme -eq 'https'
}

function Read-RelianToolkitRecord {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'toolkit record missing'
    }
    $record = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    foreach ($key in @('name', 'version', 'file', 'url', 'sha256', 'size')) {
        if ($null -eq $record.PSObject.Properties[$key]) {
            throw "toolkit record missing $key"
        }
    }
    return $record
}

function Get-RelianPackSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-RelianBrandZip {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$OutZip
    )
    $pairs = @(
        @{ Source = (Join-Path $SourceRoot 'Config/config.psd1'); Name = 'Config/config.psd1' }
        @{ Source = (Join-Path $SourceRoot 'Assets/AppIcon.png'); Name = 'Assets/AppIcon.png' }
        @{ Source = (Join-Path $SourceRoot 'Assets/AppIcon.Dark.png'); Name = 'Assets/AppIcon.Dark.png' }
        @{ Source = (Join-Path $SourceRoot 'Strings/en.psd1'); Name = 'Strings/en.psd1' }
    )
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Source)) {
            throw "missing $($pair.Source)"
        }
    }
    $parent = Split-Path -Parent $OutZip
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    if (Test-Path -LiteralPath $OutZip) {
        Remove-Item -LiteralPath $OutZip -Force
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($OutZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($pair in $pairs) {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $pair.Source, $pair.Name)
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-RelianToolkitBlobName {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sha256
    )
    $safeName = $Name.Trim()
    $safeVersion = $Version.Trim()
    $sha = $Sha256.Trim().ToLowerInvariant()
    if ($safeName -notmatch '^[A-Za-z0-9._-]+$' -or $safeVersion -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'toolkit record name or version is not a blob token'
    }
    if ($sha -notmatch '^[0-9a-f]{64}$') {
        throw 'toolkit record sha256 is invalid'
    }
    return '{0}-{1}-{2}.zip' -f $safeName, $safeVersion, $sha
}

function Resolve-RelianToolkitFile {
    param(
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FileName
    )
    # The pin is not downloaded. Publish reads this file name beside the record.
    if ([string]::IsNullOrWhiteSpace($FileName) -or
        [System.IO.Path]::IsPathRooted($FileName) -or
        $FileName.Contains('/') -or
        $FileName.Contains('\') -or
        $FileName.Contains('..')) {
        throw 'toolkit record file must be a file name'
    }
    return (Join-Path (Split-Path -Parent $RecordPath) $FileName)
}

function Get-RelianAzText {
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

function Test-RelianBlobExists {
    param([Parameter(Mandatory)][string]$BlobName)
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
    $text = Get-RelianAzText $output
    if ($text.Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($text.Equals('false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    throw 'unexpected blob exists result'
}

function Send-RelianBlob {
    param(
        [Parameter(Mandatory)][string]$BlobName,
        [Parameter(Mandatory)][string]$LocalFile
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

function Publish-RelianPacks {
    [CmdletBinding()]
    param(
        [switch]$Publish,
        [string]$BrandRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/brand/relian'),
        [string]$ToolkitRecord = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/releases/psadt.json')
    )

    $script:ExitCode = 1
    if (-not [string]::IsNullOrWhiteSpace($script:BrandZipPath) -and (Test-Path -LiteralPath $script:BrandZipPath)) {
        Remove-Item -LiteralPath $script:BrandZipPath -Force
    }
    $script:BrandZipPath = $null

    try {
        $record = Read-RelianToolkitRecord -Path $ToolkitRecord
        $sourceUrl = [string]$record.url
        if (Test-RelianPublishUrlHasUserInfo -Url $sourceUrl) {
            Write-RelianPublishError 'refusing a URL that contains userinfo'
            return
        }
        if (-not (Test-RelianPublishSourceUrl -Url $sourceUrl)) {
            Write-RelianPublishError 'toolkit record url is invalid'
            return
        }

        $toolkitBlob = Get-RelianToolkitBlobName -Name ([string]$record.name) -Version ([string]$record.version) -Sha256 ([string]$record.sha256)
        $brandZip = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-publish-brand-' + [guid]::NewGuid().ToString('n') + '.zip')
        $script:BrandZipPath = $brandZip
        New-RelianBrandZip -SourceRoot $BrandRoot -OutZip $brandZip
        $brandSha = Get-RelianPackSha256 -Path $brandZip
        $brandBlob = 'relian-brand-{0}.zip' -f $brandSha
        $base = 'https://relianpub.blob.core.windows.net/pub/sec/'
        $toolkitUrl = $base + $toolkitBlob
        $brandUrl = $base + $brandBlob
        Write-Output $toolkitUrl
        Write-Output $brandUrl

        if (-not $Publish) {
            $script:ExitCode = 0
            return
        }

        $toolkitFile = Resolve-RelianToolkitFile -RecordPath $ToolkitRecord -FileName ([string]$record.file)
        if (-not (Test-Path -LiteralPath $toolkitFile)) {
            Write-RelianPublishError 'toolkit file missing'
            return
        }
        $actualSha = Get-RelianPackSha256 -Path $toolkitFile
        $expectedSha = ([string]$record.sha256).Trim().ToLowerInvariant()
        if (-not $actualSha.Equals($expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-RelianPublishError "toolkit hash mismatch expected $expectedSha actual $actualSha"
            return
        }
        $expectedSize = [int64]$record.size
        $actualSize = [int64](Get-Item -LiteralPath $toolkitFile).Length
        if ($actualSize -ne $expectedSize) {
            Write-RelianPublishError "toolkit size mismatch expected $expectedSize actual $actualSize"
            return
        }

        $uploads = @(
            @{ Name = $toolkitBlob; File = $toolkitFile }
            @{ Name = $brandBlob; File = $brandZip }
        )
        foreach ($upload in $uploads) {
            if (Test-RelianBlobExists -BlobName $upload.Name) {
                continue
            }
            Send-RelianBlob -BlobName $upload.Name -LocalFile $upload.File
        }
        $script:ExitCode = 0
    } catch {
        Write-RelianPublishError $_.Exception.Message
        $script:ExitCode = 1
    }
}

# Dot-sourcing under test defines functions and does not publish.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$script:ExitCode = 1
try {
    Publish-RelianPacks -Publish:$Publish -BrandRoot $BrandRoot -ToolkitRecord $ToolkitRecord
} catch {
    Write-RelianPublishError $_.Exception.Message
    $script:ExitCode = 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($script:BrandZipPath) -and (Test-Path -LiteralPath $script:BrandZipPath)) {
        Remove-Item -LiteralPath $script:BrandZipPath -Force
        $script:BrandZipPath = $null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
