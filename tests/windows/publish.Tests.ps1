$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$publisher = Join-Path $repoRoot 'scripts/publish-relian-packs.ps1'
$readmePath = Join-Path $repoRoot 'README.md'
$pinPath = Join-Path $repoRoot 'windows/releases/psadt.json'
$brandRoot = Join-Path $repoRoot 'windows/brand/relian'
$blobBase = 'https://relianpub.blob.core.windows.net/pub/sec/'
$knownToolkitSha = '80b45fb8e518ee98774e16e44599d470e4069a0695a6a359022f954edaa83360'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-OracleBrandZip {
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
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $OutZip) {
        Remove-Item -LiteralPath $OutZip -Force
    }
    $archive = [System.IO.Compression.ZipFile]::Open($OutZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($pair in $pairs) {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $pair.Source, $pair.Name)
        }
    } finally {
        $archive.Dispose()
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

function Assert-BrandZipBytes {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$SourceRoot
    )
    $expected = @(
        'Config/config.psd1'
        'Assets/AppIcon.png'
        'Assets/AppIcon.Dark.png'
        'Strings/en.psd1'
    )
    $names = @(Get-ZipEntryNames -ZipPath $ZipPath)
    if ($names.Count -ne $expected.Count) {
        Fail "brand zip entry count $($names.Count)"
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($names[$i] -cne $expected[$i]) {
            Fail "brand zip entry $i '$($names[$i])' expected '$($expected[$i])'"
        }
        $packed = Read-ZipEntryBytes -ZipPath $ZipPath -Name $expected[$i]
        $source = [System.IO.File]::ReadAllBytes((Join-Path $SourceRoot $expected[$i]))
        if ($packed.Length -ne $source.Length) {
            Fail "brand zip $($expected[$i]) length $($packed.Length) expected $($source.Length)"
        }
        for ($b = 0; $b -lt $source.Length; $b++) {
            if ($packed[$b] -ne $source[$b]) {
                Fail "brand zip $($expected[$i]) byte $b differs"
            }
        }
    }
}

function Write-ToolkitRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][int64]$Size,
        [Parameter(Mandatory)][string]$Url,
        [string]$Version = '4.1.8',
        [string]$Name = 'PSAppDeployToolkit'
    )
    $payload = [ordered]@{
        name = $Name
        version = $Version
        file = $FileName
        url = $Url
        sha256 = $Sha
        size = $Size
    }
    $json = ($payload | ConvertTo-Json -Compress) + "`n"
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Reset-AzRecorder {
    param([hashtable]$Existing)
    $script:azCalls = [System.Collections.Generic.List[object]]::new()
    $script:existingBlobs = $Existing
    $script:InvokeAz = {
        param([Parameter(Mandatory)][string[]]$ArgumentList)
        $copy = [string[]]::new($ArgumentList.Count)
        [array]::Copy($ArgumentList, $copy, $ArgumentList.Count)
        [void]$script:azCalls.Add($copy)
        $isExists = $false
        foreach ($token in $copy) {
            if ($token -ceq 'exists') {
                $isExists = $true
            }
        }
        if (-not $isExists) {
            return ''
        }
        $blobName = ''
        for ($i = 0; $i -lt $copy.Count; $i++) {
            if ($copy[$i] -ceq '-n' -and ($i + 1) -lt $copy.Count) {
                $blobName = $copy[$i + 1]
            }
        }
        if ($script:existingBlobs.ContainsKey($blobName)) {
            return 'true'
        }
        return 'false'
    }
}

function Get-ArgValue {
    param(
        [Parameter(Mandatory)][string[]]$List,
        [Parameter(Mandatory)][string]$Name
    )
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i] -ceq $Name) {
            if (($i + 1) -ge $List.Count) {
                Fail "missing value after $Name"
            }
            return [string]$List[$i + 1]
        }
    }
    Fail "missing argument $Name"
}

function Assert-NoSecretArgs {
    param(
        [Parameter(Mandatory)][string[]]$List,
        [Parameter(Mandatory)][string]$Label
    )
    $banned = @(
        '--connection-string'
        '--account-key'
        '--sas-token'
        'AccountKey'
        'DefaultEndpointsProtocol'
        'SharedAccessSignature'
        'connection string'
    )
    foreach ($arg in $List) {
        foreach ($word in $banned) {
            if ($arg.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Fail "$Label contains $word"
            }
        }
        if ($arg.StartsWith('http://') -or $arg.StartsWith('https://')) {
            Fail "$Label passed a URL to az"
        }
    }
    $auth = [array]::IndexOf($List, '--auth-mode')
    if ($auth -lt 0 -or ($auth + 1) -ge $List.Count -or $List[$auth + 1] -cne 'login') {
        Fail "$Label auth mode is not login"
    }
    if ((Get-ArgValue -List $List -Name '--account-name') -cne 'relianpub') {
        Fail "$Label account is not relianpub"
    }
    if ((Get-ArgValue -List $List -Name '-c') -cne 'pub') {
        Fail "$Label container is not pub"
    }
}

function Assert-ArgList {
    param(
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Actual.Count -ne $Expected.Count) {
        Fail "$Label count $($Actual.Count) expected $($Expected.Count): $($Actual -join ' | ')"
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Actual[$i] -cne $Expected[$i]) {
            Fail "$Label index $i '$($Actual[$i])' expected '$($Expected[$i])'"
        }
    }
}

function Get-ExistsArgs {
    param([Parameter(Mandatory)][string]$BlobName)
    return @(
        'storage', 'blob', 'exists',
        '--auth-mode', 'login',
        '--account-name', 'relianpub',
        '-c', 'pub',
        '-n', "sec/$BlobName",
        '--query', 'exists',
        '-o', 'tsv'
    )
}

function Get-UploadArgs {
    param(
        [Parameter(Mandatory)][string]$BlobName,
        [Parameter(Mandatory)][string]$LocalFile
    )
    return @(
        'storage', 'blob', 'upload',
        '--auth-mode', 'login',
        '--account-name', 'relianpub',
        '-c', 'pub',
        '-n', "sec/$BlobName",
        '-f', $LocalFile,
        '--no-progress',
        '-o', 'none'
    )
}

function Invoke-PublisherFile {
    param([Parameter(Mandatory)][string]$Script)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = '/usr/bin/pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Script)
    # Dry-run entry. Do not pass -Publish. PATH has no az, so a mistaken call cannot reach the real CLI.
    if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_TEST')) {
        [void]$psi.Environment.Remove('RELIAN_DEPLOY_TEST')
    }
    $psi.Environment['PATH'] = '/usr/bin:/bin'
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(60000)) {
            try {
                $proc.Kill($true)
            } catch {
                $proc.Kill()
            }
            Fail 'publisher dry-run timed out'
        }
        return @{
            ExitCode = $proc.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

function Assert-Readme {
    if (-not (Test-Path -LiteralPath $readmePath)) {
        Fail "missing $readmePath"
    }
    $text = [System.IO.File]::ReadAllText($readmePath)
    if (-not $text.StartsWith("# device-scripts`n")) {
        Fail 'README title changed'
    }
    $description = 'NinjaOne installs software by pasting `windows/runner/Invoke-RelianRunner.ps1`. That file is the installer. `windows/bootstrap.ps1` loads an inventory collector. It is not the installer.'
    if (-not $text.Contains($description)) {
        Fail 'README description removed'
    }
    $sectionAt = $text.IndexOf("## Deploy runner")
    if ($sectionAt -lt 0) {
        Fail 'Deploy runner section missing'
    }
    $section = $text.Substring($sectionAt)
    $needles = @(
        'windows/runner/Invoke-RelianRunner.ps1'
        'PackageSha256'
        'ToolkitSha256'
        'BrandPackSha256'
        'An empty pin exits 0'
        'three download attempts'
        'A bad hash is not retried'
        '130'
        'https://relianpub.blob.core.windows.net/pub/sec/'
        'bootstrap.ps1 remains the collector loader'
    )
    $cursor = 0
    foreach ($needle in $needles) {
        $found = $section.IndexOf($needle, $cursor, [System.StringComparison]::Ordinal)
        if ($found -lt 0) {
            Fail "README missing '$needle'"
        }
        $cursor = $found + $needle.Length
    }
}

if (-not (Test-Path -LiteralPath $publisher)) {
    Fail "missing $publisher"
}

$publisherText = [System.IO.File]::ReadAllText($publisher)
$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
if (-not $publisherText.Contains($guardNeedle)) {
    Fail 'dot-source guard missing'
}
foreach ($banned in @(
        'Ninja-Property-Get',
        'Ninja-Property-Set',
        'relian_git_deploy_token',
        '--account-key',
        '--connection-string',
        'Invoke-WebRequest',
        'Invoke-RestMethod',
        'WebClient',
        'HttpClient',
        'curl '
    )) {
    if ($publisherText.Contains($banned)) {
        Fail "publisher contains $banned"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $publisher

if (-not (Get-Command Publish-RelianPacks -ErrorAction SilentlyContinue)) {
    Fail 'Publish-RelianPacks was not defined'
}
if (-not ($script:InvokeAz -is [scriptblock])) {
    Fail 'InvokeAz is not a scriptblock'
}

Reset-AzRecorder -Existing @{}

$oracleZip = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-publish-oracle-' + [guid]::NewGuid().ToString('n') + '.zip')
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-publish-test-' + [guid]::NewGuid().ToString('n'))
try {
    New-OracleBrandZip -SourceRoot $brandRoot -OutZip $oracleZip
    $brandSha = Get-Sha256Hex -Path $oracleZip
    Assert-BrandZipBytes -ZipPath $oracleZip -SourceRoot $brandRoot

    $pin = Get-Content -LiteralPath $pinPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$pin.sha256 -cne $knownToolkitSha) {
        Fail 'pin sha256 drifted'
    }
    $toolkitBlob = '{0}-{1}-{2}.zip' -f [string]$pin.name, [string]$pin.version, $knownToolkitSha
    $brandBlob = 'relian-brand-{0}.zip' -f $brandSha
    $expectedToolkitUrl = $blobBase + $toolkitBlob
    $expectedBrandUrl = $blobBase + $brandBlob

    $dry = @(Publish-RelianPacks)
    if ($script:azCalls.Count -ne 0) {
        Fail "dry run called az $($script:azCalls.Count) times"
    }
    if ([int]$script:ExitCode -ne 0) {
        Fail "dry run exit $($script:ExitCode)"
    }
    if ($dry.Count -ne 2) {
        Fail "dry run printed $($dry.Count) lines"
    }
    if ([string]$dry[0] -cne $expectedToolkitUrl) {
        Fail "toolkit URL '$($dry[0])' expected '$expectedToolkitUrl'"
    }
    if ([string]$dry[1] -cne $expectedBrandUrl) {
        Fail "brand URL '$($dry[1])' expected '$expectedBrandUrl'"
    }

    $entry = Invoke-PublisherFile -Script $publisher
    if ($entry.ExitCode -ne 0) {
        Fail "entry dry-run exited $($entry.ExitCode) stdout=[$($entry.Stdout)] stderr=[$($entry.Stderr)]"
    }
    if ($entry.Stderr.Trim() -ne '') {
        Fail "entry dry-run stderr [$($entry.Stderr)]"
    }
    $entryLines = @($entry.Stdout -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($entryLines.Count -ne 2 -or $entryLines[0] -cne $expectedToolkitUrl -or $entryLines[1] -cne $expectedBrandUrl) {
        Fail "entry dry-run stdout [$($entry.Stdout)]"
    }

    [void](New-Item -ItemType Directory -Path $temp)
    $altSha = ('ab' * 32)
    $altVersion = '9.9.9'
    $altRecord = Join-Path $temp 'psadt.json'
    Write-ToolkitRecord -Path $altRecord -FileName 'module.zip' -Sha $altSha -Size 1 -Url 'https://example.invalid/module.zip' -Version $altVersion
    Reset-AzRecorder -Existing @{}
    $alt = @(Publish-RelianPacks -ToolkitRecord $altRecord -BrandRoot $brandRoot)
    if ($script:azCalls.Count -ne 0) {
        Fail 'alternate dry run called az'
    }
    if ([int]$script:ExitCode -ne 0 -or $alt.Count -ne 2) {
        Fail "alternate dry run exit $($script:ExitCode) lines $($alt.Count)"
    }
    $altToolkitUrl = $blobBase + ('PSAppDeployToolkit-{0}-{1}.zip' -f $altVersion, $altSha)
    if ([string]$alt[0] -cne $altToolkitUrl) {
        Fail "alternate toolkit URL '$($alt[0])'"
    }
    if ([string]$alt[1] -cne $expectedBrandUrl) {
        Fail "alternate brand URL '$($alt[1])'"
    }

    $userRecord = Join-Path $temp 'userinfo.json'
    $userInfoUrl = -join @('https://', 'user', '@', 'example.invalid/module.zip')
    Write-ToolkitRecord -Path $userRecord -FileName 'module.zip' -Sha $altSha -Size 1 -Url $userInfoUrl
    Reset-AzRecorder -Existing @{}
    $userOut = @(Publish-RelianPacks -ToolkitRecord $userRecord -BrandRoot $brandRoot)
    if ($script:azCalls.Count -ne 0) {
        Fail 'userinfo called az'
    }
    if ([int]$script:ExitCode -ne 1) {
        Fail "userinfo exit $($script:ExitCode)"
    }
    if ($userOut.Count -ne 0) {
        Fail 'userinfo printed URLs'
    }

    $fixtureName = 'module.zip'
    $fixturePath = Join-Path $temp $fixtureName
    $fixtureBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('toolkit-fixture')
    [System.IO.File]::WriteAllBytes($fixturePath, $fixtureBytes)
    $fixtureSha = Get-Sha256Hex -Path $fixturePath
    $fixtureRecord = Join-Path $temp 'fixture.json'
    Write-ToolkitRecord -Path $fixtureRecord -FileName $fixtureName -Sha $fixtureSha -Size $fixtureBytes.Length -Url 'https://example.invalid/module.zip' -Version '4.1.8'
    $fixtureToolkitBlob = 'PSAppDeployToolkit-4.1.8-{0}.zip' -f $fixtureSha
    $fixtureBrandBlob = $brandBlob

    Reset-AzRecorder -Existing @{}
    $published = @(Publish-RelianPacks -Publish -ToolkitRecord $fixtureRecord -BrandRoot $brandRoot)
    if ([int]$script:ExitCode -ne 0) {
        Fail "publish exit $($script:ExitCode)"
    }
    if ($published.Count -ne 2 -or [string]$published[1] -cne ($blobBase + $fixtureBrandBlob)) {
        Fail "publish URLs $($published -join ' ')"
    }
    if ($script:azCalls.Count -ne 4) {
        Fail "publish az calls $($script:azCalls.Count)"
    }
    Assert-ArgList -Actual $script:azCalls[0] -Expected (Get-ExistsArgs -BlobName $fixtureToolkitBlob) -Label 'toolkit exists'
    $toolkitUpload = [string[]]$script:azCalls[1]
    Assert-NoSecretArgs -List $toolkitUpload -Label 'toolkit upload'
    Assert-ArgList -Actual $toolkitUpload -Expected (Get-UploadArgs -BlobName $fixtureToolkitBlob -LocalFile $fixturePath) -Label 'toolkit upload'
    Assert-ArgList -Actual $script:azCalls[2] -Expected (Get-ExistsArgs -BlobName $fixtureBrandBlob) -Label 'brand exists'
    $brandUpload = [string[]]$script:azCalls[3]
    Assert-NoSecretArgs -List $brandUpload -Label 'brand upload'
    $uploadedBrand = Get-ArgValue -List $brandUpload -Name '-f'
    if (-not (Test-Path -LiteralPath $uploadedBrand)) {
        Fail "uploaded brand zip missing $uploadedBrand"
    }
    if ((Get-Sha256Hex -Path $uploadedBrand) -cne $brandSha) {
        Fail 'uploaded brand zip hash does not match the oracle'
    }
    Assert-BrandZipBytes -ZipPath $uploadedBrand -SourceRoot $brandRoot
    Assert-ArgList -Actual $brandUpload -Expected (Get-UploadArgs -BlobName $fixtureBrandBlob -LocalFile $uploadedBrand) -Label 'brand upload'
    foreach ($call in @($script:azCalls)) {
        Assert-NoSecretArgs -List ([string[]]$call) -Label 'az call'
    }

    Reset-AzRecorder -Existing @{ ("sec/$fixtureToolkitBlob") = $true }
    $skippedToolkit = @(Publish-RelianPacks -Publish -ToolkitRecord $fixtureRecord -BrandRoot $brandRoot)
    if ([int]$script:ExitCode -ne 0 -or $skippedToolkit.Count -ne 2) {
        Fail "skip toolkit exit $($script:ExitCode)"
    }
    if ($script:azCalls.Count -ne 3) {
        Fail "skip toolkit az calls $($script:azCalls.Count)"
    }
    Assert-ArgList -Actual $script:azCalls[0] -Expected (Get-ExistsArgs -BlobName $fixtureToolkitBlob) -Label 'skip toolkit exists'
    if ([string]$script:azCalls[1][2] -cne 'exists') {
        Fail 'skip toolkit uploaded the toolkit'
    }
    Assert-ArgList -Actual $script:azCalls[1] -Expected (Get-ExistsArgs -BlobName $fixtureBrandBlob) -Label 'skip toolkit brand exists'
    if ([string]$script:azCalls[2][2] -cne 'upload') {
        Fail 'skip toolkit did not upload the brand'
    }
    Assert-NoSecretArgs -List ([string[]]$script:azCalls[2]) -Label 'skip toolkit brand upload'

    Reset-AzRecorder -Existing @{
        ("sec/$fixtureToolkitBlob") = $true
        ("sec/$fixtureBrandBlob") = $true
    }
    [void]@(Publish-RelianPacks -Publish -ToolkitRecord $fixtureRecord -BrandRoot $brandRoot)
    if ([int]$script:ExitCode -ne 0) {
        Fail "skip both exit $($script:ExitCode)"
    }
    if ($script:azCalls.Count -ne 2) {
        Fail "skip both az calls $($script:azCalls.Count)"
    }
    if ([string]$script:azCalls[0][2] -cne 'exists' -or [string]$script:azCalls[1][2] -cne 'exists') {
        Fail 'skip both uploaded'
    }

    $badRecord = Join-Path $temp 'bad-hash.json'
    Write-ToolkitRecord -Path $badRecord -FileName $fixtureName -Sha $altSha -Size $fixtureBytes.Length -Url 'https://example.invalid/module.zip'
    Reset-AzRecorder -Existing @{}
    [void]@(Publish-RelianPacks -Publish -ToolkitRecord $badRecord -BrandRoot $brandRoot)
    if ([int]$script:ExitCode -ne 1) {
        Fail "bad hash exit $($script:ExitCode)"
    }
    if ($script:azCalls.Count -ne 0) {
        Fail 'bad hash called az'
    }

    $missingRecord = Join-Path $temp 'missing.json'
    Write-ToolkitRecord -Path $missingRecord -FileName 'absent.zip' -Sha $fixtureSha -Size 1 -Url 'https://example.invalid/absent.zip'
    Reset-AzRecorder -Existing @{}
    [void]@(Publish-RelianPacks -Publish -ToolkitRecord $missingRecord -BrandRoot $brandRoot)
    if ([int]$script:ExitCode -ne 1 -or $script:azCalls.Count -ne 0) {
        Fail "missing toolkit exit $($script:ExitCode) calls $($script:azCalls.Count)"
    }

    Assert-Readme
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oracleZip) {
        Remove-Item -LiteralPath $oracleZip -Force
    }
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
    $sweepRoot = [System.IO.Path]::GetTempPath()
    foreach ($left in @(Get-ChildItem -LiteralPath $sweepRoot -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'relian-publish-brand-*' })) {
        Remove-Item -LiteralPath $left.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'publish tests passed'
exit 0
