$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $repoRoot 'windows/brand/build-relian-pack.ps1'
$blackSrc = Join-Path $repoRoot 'windows/brand/logos/relian-logo-black.svg'
$whiteSrc = Join-Path $repoRoot 'windows/brand/logos/relian-logo-white.svg'
$expectedBlackSha256 = 'c521b7fefcef44f9d9eec85a0cade62ebe3701224fbff4ec54904618d27c9d12'
$expectedEntries = @(
    'Config/config.psd1'
    'Assets/AppIcon.png'
    'Assets/AppIcon.Dark.png'
    'Strings/en.psd1'
)

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Invoke-PwshFile {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Script)
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        [void]$proc.WaitForExit()
        return @{
            ExitCode = $proc.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

function Get-ZipEntryNames {
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName })
    } finally {
        $archive.Dispose()
    }
}

function Read-ZipEntryBytes {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Name
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry($Name)
        if ($null -eq $entry) {
            Fail "zip missing $Name"
        }
        $stream = $entry.Open()
        try {
            $buffer = [System.IO.MemoryStream]::new()
            try {
                $stream.CopyTo($buffer)
                return $buffer.ToArray()
            } finally {
                $buffer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-PngIhdrSize {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ($Bytes.Length -lt 24) {
        Fail 'PNG shorter than IHDR'
    }
    $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($i = 0; $i -lt $signature.Length; $i++) {
        if ($Bytes[$i] -ne $signature[$i]) {
            Fail 'PNG signature mismatch'
        }
    }
    $chunk = [System.Text.Encoding]::ASCII.GetString($Bytes, 12, 4)
    if ($chunk -ne 'IHDR') {
        Fail "PNG chunk is $chunk"
    }
    $widthBytes = [byte[]]::new(4)
    $heightBytes = [byte[]]::new(4)
    [Array]::Copy($Bytes, 16, $widthBytes, 0, 4)
    [Array]::Copy($Bytes, 20, $heightBytes, 0, 4)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($widthBytes)
        [Array]::Reverse($heightBytes)
    }
    return @{
        Width = [BitConverter]::ToUInt32($widthBytes, 0)
        Height = [BitConverter]::ToUInt32($heightBytes, 0)
    }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-brand-pack-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $black = Join-Path $temp 'black.svg'
    $white = Join-Path $temp 'white.svg'
    [System.IO.File]::Copy($blackSrc, $black)
    [System.IO.File]::Copy($whiteSrc, $white)
    $dest = Join-Path $temp 'relian'
    $zip = Join-Path $temp 'relian-brand.zip'

    $good = Invoke-PwshFile -Script $build -Arguments @(
        '-BlackSvg', $black,
        '-WhiteSvg', $white,
        '-Destination', $dest,
        '-OutZip', $zip
    )
    if ($good.ExitCode -ne 0) {
        Fail "build exited $($good.ExitCode) stdout=[$($good.Stdout)] stderr=[$($good.Stderr)]"
    }
    $shaLine = $good.Stdout.Trim()
    $shaPattern = '^sha256 [0-9a-f]{64} ' + [regex]::Escape($zip) + '$'
    if ($shaLine -notmatch $shaPattern) {
        Fail "expected one sha256 line, got [$shaLine]"
    }
    if (-not (Test-Path -LiteralPath $zip)) {
        Fail "zip was not written: $zip"
    }

    $names = @(Get-ZipEntryNames -ZipPath $zip)
    $sortedActual = @($names | Sort-Object)
    $sortedExpected = @($expectedEntries | Sort-Object)
    if ($sortedActual.Count -ne $sortedExpected.Count) {
        Fail "expected $($sortedExpected.Count) entries, got $($sortedActual.Count): $($sortedActual -join ', ')"
    }
    for ($i = 0; $i -lt $sortedExpected.Count; $i++) {
        if ($sortedActual[$i] -cne $sortedExpected[$i]) {
            Fail "entry mismatch: $($sortedActual -join ', ')"
        }
    }

    foreach ($pngName in @('Assets/AppIcon.png', 'Assets/AppIcon.Dark.png')) {
        $png = Read-ZipEntryBytes -ZipPath $zip -Name $pngName
        $size = Get-PngIhdrSize -Bytes $png
        if ($size.Width -ne 256 -or $size.Height -ne 256) {
            Fail "$pngName is $($size.Width)x$($size.Height)"
        }
    }

    $configText = [System.Text.Encoding]::UTF8.GetString((Read-ZipEntryBytes -ZipPath $zip -Name 'Config/config.psd1'))
    foreach ($needle in @('Relian', 'AppIcon.Dark.png', 'Fluent')) {
        if (-not $configText.Contains($needle)) {
            Fail "config.psd1 missing $needle"
        }
    }
    if ($configText.Contains('FluentAccentColor')) {
        Fail 'config.psd1 contains FluentAccentColor'
    }

    $badBlack = Join-Path $temp 'black-bad.svg'
    $badBytes = [System.IO.File]::ReadAllBytes($black)
    $badBytes[$badBytes.Length - 1] = [byte](([int]$badBytes[$badBytes.Length - 1] + 1) % 256)
    [System.IO.File]::WriteAllBytes($badBlack, $badBytes)
    $badDest = Join-Path $temp 'bad-dest'
    $badZip = Join-Path $temp 'should-not-exist.zip'
    $bad = Invoke-PwshFile -Script $build -Arguments @(
        '-BlackSvg', $badBlack,
        '-WhiteSvg', $white,
        '-Destination', $badDest,
        '-OutZip', $badZip
    )
    if ($bad.ExitCode -ne 1) {
        Fail "mismatch exited $($bad.ExitCode) stdout=[$($bad.Stdout)] stderr=[$($bad.Stderr)]"
    }
    if (Test-Path -LiteralPath $badZip) {
        Fail 'zip written after hash mismatch'
    }
    $actualBad = (Get-FileHash -Algorithm SHA256 -LiteralPath $badBlack).Hash
    $combined = $bad.Stdout + $bad.Stderr
    if ($combined.IndexOf($badBlack, [System.StringComparison]::Ordinal) -lt 0) {
        Fail 'mismatch output missing svg path'
    }
    if ($combined.IndexOf($expectedBlackSha256, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Fail 'mismatch output missing expected digest'
    }
    if ($combined.IndexOf($actualBad, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Fail 'mismatch output missing actual digest'
    }
    if ($combined.Contains('<?xml') -or $combined.Contains('sodipodi:docname')) {
        Fail 'mismatch output printed SVG contents'
    }

    Write-Output 'brand-pack tests passed'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}

exit 0
