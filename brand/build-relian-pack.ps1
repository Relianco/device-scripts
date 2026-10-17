[CmdletBinding()]
param(
    [string]$BlackSvg = '/home/kverbr/Develop/Relian/web/www-rebased/layers/shared/public/images/logo/relian-logo-black.svg',
    [string]$WhiteSvg = '/home/kverbr/Develop/Relian/web/www-rebased/layers/shared/public/images/logo/relian-logo-white.svg',
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'brand/relian'),
    [string]$OutZip = (Join-Path (Split-Path -Parent $PSScriptRoot) 'brand/out/relian-brand.zip')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RelianFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-RelianSvgHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )
    $actual = Get-RelianFileSha256 -Path $Path
    if (-not $actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        [Console]::Error.WriteLine("$Path $Expected $actual")
        return $false
    }
    return $true
}

function Get-RelianConfigPsd1 {
    $lines = @(
        '@{'
        '    Assets = @{'
        "        Logo = '..\Assets\AppIcon.png'"
        "        LogoDark = '..\Assets\AppIcon.Dark.png'"
        '    }'
        '    Toolkit = @{'
        "        CompanyName = 'Relian'"
        '    }'
        '    UI = @{'
        "        DialogStyle = 'Fluent'"
        '    }'
        '}'
    )
    return ($lines -join "`n")
}

function Get-RelianStringsPsd1 {
    return "@{ DeployNotice = 'Relian needs to update {AppName}. You can defer once. After that, the app will close and then start again.' }"
}

function Write-RelianUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    if (-not $Content.EndsWith("`n")) {
        $Content += "`n"
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Convert-RelianSvgToPng {
    param(
        [Parameter(Mandatory)][string]$Svg,
        [Parameter(Mandatory)][string]$Png
    )
    & rsvg-convert -w 256 -h 256 -o $Png $Svg
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("rsvg-convert failed for $Svg")
        return $false
    }
    return $true
}

function Add-RelianZipEntry {
    param(
        [Parameter(Mandatory)]$Archive,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Name
    )
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Source, $Name)
}

function Build-RelianPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BlackSvg,
        [Parameter(Mandatory)][string]$WhiteSvg,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$OutZip
    )

    $expectedBlackSha256 = 'c521b7fefcef44f9d9eec85a0cade62ebe3701224fbff4ec54904618d27c9d12'
    $expectedWhiteSha256 = '5891af78188b2d1480a2daf9c759d824fa016f625d7d295559cbae920a2217cc'
    $blackOk = Test-RelianSvgHash -Path $BlackSvg -Expected $expectedBlackSha256
    $whiteOk = Test-RelianSvgHash -Path $WhiteSvg -Expected $expectedWhiteSha256
    if (-not $blackOk -or -not $whiteOk) {
        $script:ExitCode = 1
        return
    }

    foreach ($dir in @(
            (Join-Path $Destination 'Assets'),
            (Join-Path $Destination 'Config'),
            (Join-Path $Destination 'Strings')
        )) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $icon = Join-Path $Destination 'Assets/AppIcon.png'
    $iconDark = Join-Path $Destination 'Assets/AppIcon.Dark.png'
    if (-not (Convert-RelianSvgToPng -Svg $BlackSvg -Png $icon)) {
        $script:ExitCode = 1
        return
    }
    if (-not (Convert-RelianSvgToPng -Svg $WhiteSvg -Png $iconDark)) {
        $script:ExitCode = 1
        return
    }

    $configPath = Join-Path $Destination 'Config/config.psd1'
    $stringsPath = Join-Path $Destination 'Strings/en.psd1'
    Write-RelianUtf8 -Path $configPath -Content (Get-RelianConfigPsd1)
    Write-RelianUtf8 -Path $stringsPath -Content (Get-RelianStringsPsd1)

    $zipParent = Split-Path -Parent $OutZip
    if (-not [string]::IsNullOrEmpty($zipParent)) {
        New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $OutZip) {
        Remove-Item -LiteralPath $OutZip -Force
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($OutZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-RelianZipEntry -Archive $archive -Source $configPath -Name 'Config/config.psd1'
        Add-RelianZipEntry -Archive $archive -Source $icon -Name 'Assets/AppIcon.png'
        Add-RelianZipEntry -Archive $archive -Source $iconDark -Name 'Assets/AppIcon.Dark.png'
        Add-RelianZipEntry -Archive $archive -Source $stringsPath -Name 'Strings/en.psd1'
    } finally {
        $archive.Dispose()
    }

    $zipHash = Get-RelianFileSha256 -Path $OutZip
    Write-Output "sha256 $zipHash $OutZip"
    $script:ExitCode = 0
}

# Dot-sourcing under test defines functions and does not build.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$script:ExitCode = 1
try {
    Build-RelianPack -BlackSvg $BlackSvg -WhiteSvg $WhiteSvg -Destination $Destination -OutZip $OutZip
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
