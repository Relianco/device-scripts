$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/printer-tcp/Invoke-PrinterTcp.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-PrinterTcp.ps1 does not exist'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($command in @(
        'Split-PrinterTcpQuotedFields',
        'Invoke-PrinterTcpInfLayout'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($scriptText -match '@\(\s*Split-PrinterTcpQuotedFields') {
    Fail 'field split was wrapped in @()'
}

function Assert-FieldCount {
    param($Fields, [int]$Count, [string]$Label)
    if ($Fields -isnot [System.Array]) {
        Fail "$Label was unrolled"
    }
    if (@($Fields).Count -ne $Count) {
        Fail "$Label count $(@($Fields).Count) expected $Count"
    }
}

$one = Split-PrinterTcpQuotedFields -Text 'only'
Assert-FieldCount -Fields $one -Count 1 -Label 'one field'
if ([string]$one[0] -cne 'only') {
    Fail "one field value '$($one[0])'"
}

$brotherDisk = Split-PrinterTcpQuotedFields -Text '%Disk1%,,,"amd64"'
Assert-FieldCount -Fields $brotherDisk -Count 4 -Label 'brother disk'
if ([string]$brotherDisk[0] -cne '%Disk1%' -or [string]$brotherDisk[3] -cne 'amd64') {
    Fail "brother disk fields '$($brotherDisk -join '|')'"
}

$quotedComma = Split-PrinterTcpQuotedFields -Text '"Brother, series",,,"amd64"'
Assert-FieldCount -Fields $quotedComma -Count 4 -Label 'quoted comma'
if ([string]$quotedComma[0] -cne 'Brother, series' -or [string]$quotedComma[3] -cne 'amd64') {
    Fail "quoted comma fields '$($quotedComma -join '|')'"
}

$emptyTail = Split-PrinterTcpQuotedFields -Text '"KONICA MINOLTA Universal PCL",,,'
Assert-FieldCount -Fields $emptyTail -Count 4 -Label 'empty tail'
if (-not [string]::IsNullOrWhiteSpace([string]$emptyTail[3])) {
    Fail "empty tail subdir '$($emptyTail[3])'"
}

$doubled = Split-PrinterTcpQuotedFields -Text '"a""b",c'
Assert-FieldCount -Fields $doubled -Count 2 -Label 'doubled quote'
if ([string]$doubled[0] -cne 'a"b' -or [string]$doubled[1] -cne 'c') {
    Fail "doubled quote fields '$($doubled -join '|')'"
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('printer-tcp-inf-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function New-CaseDir {
    param([string]$Name)
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Write-Inf {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"))
}

function Write-Bytes {
    param([string]$Path, [byte]$Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, [byte[]]@($Value))
}

try {
    $brother = New-CaseDir 'brother'
    $brotherInf = Join-Path $brother 'BROHL17A.INF'
    Write-Inf -Path $brotherInf -Lines @(
        '[SourceDisksNames.x86]'
        '1 = %Disk1%,,,"i386"'
        '2 = %Disk1%,,,'
        ''
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        '2 = %Disk1%,,,'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
        'rootfile.dll = 2'
    )
    Write-Bytes -Path (Join-Path $brother 'amdfile.dll') -Value 1
    Write-Bytes -Path (Join-Path $brother 'rootfile.dll') -Value 2
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $brotherInf)) {
        Fail 'brother layout returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $brother 'amd64/amdfile.dll'))) {
        Fail 'brother disk 1 file was not moved into amd64'
    }
    if (Test-Path -LiteralPath (Join-Path $brother 'amdfile.dll')) {
        Fail 'brother disk 1 file stayed beside the INF'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $brother 'rootfile.dll'))) {
        Fail 'brother disk 2 file was moved'
    }
    if (Test-Path -LiteralPath (Join-Path $brother 'i386')) {
        Fail 'brother x86 subdirectory was used'
    }

    $comma = New-CaseDir 'comma'
    $commaInf = Join-Path $comma 'driver.inf'
    Write-Inf -Path $commaInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = "Brother, series",,,"amd64"'
        ''
        '[SourceDisksFiles.amd64]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $comma 'amdfile.dll') -Value 3
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $commaInf)) {
        Fail 'quoted comma layout returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $comma 'amd64/amdfile.dll'))) {
        Fail 'quoted comma subdirectory was not amd64'
    }

    $leading = New-CaseDir 'leading-slash'
    $leadingInf = Join-Path $leading 'driver.inf'
    Write-Inf -Path $leadingInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"\amd64"'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $leading 'amdfile.dll') -Value 4
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $leadingInf)) {
        Fail 'leading slash layout returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $leading 'amd64/amdfile.dll'))) {
        Fail 'leading slash was not treated as amd64'
    }

    $konica = New-CaseDir 'konica'
    $konicaInf = Join-Path $konica 'KOUWNJ1_.inf'
    Write-Inf -Path $konicaInf -Lines @(
        '[SourceDisksNames]'
        '1 = "KONICA MINOLTA Universal PCL",,,'
        ''
        '[SourceDisksFiles]'
        'kofile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $konica 'kofile.dll') -Value 5
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $konicaInf)) {
        Fail 'konica layout returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $konica 'kofile.dll'))) {
        Fail 'konica empty subdirectory moved the file'
    }
    $konicaDirs = @(Get-ChildItem -LiteralPath $konica -Directory)
    if ($konicaDirs.Count -ne 0) {
        Fail 'konica empty subdirectory created a directory'
    }

    $fallback = New-CaseDir 'fallback'
    $fallbackInf = Join-Path $fallback 'driver.inf'
    Write-Inf -Path $fallbackInf -Lines @(
        '[SourceDisksNames]'
        '1 = "disk",,,amd64'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $fallback 'amdfile.dll') -Value 6
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $fallbackInf)) {
        Fail 'undecorated fallback returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $fallback 'amd64/amdfile.dll'))) {
        Fail 'undecorated section was not used'
    }

    $prefer = New-CaseDir 'prefer-amd64'
    $preferInf = Join-Path $prefer 'driver.inf'
    Write-Inf -Path $preferInf -Lines @(
        '[SourceDisksNames]'
        '1 = "disk",,,wrong'
        ''
        '[SourceDisksNames.amd64]'
        '1 = "disk",,,amd64'
        ''
        '[SourceDisksFiles]'
        'ignored.dll = 1'
        ''
        '[SourceDisksFiles.amd64]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $prefer 'ignored.dll') -Value 7
    Write-Bytes -Path (Join-Path $prefer 'amdfile.dll') -Value 8
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $preferInf)) {
        Fail 'amd64 preference returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $prefer 'amd64/amdfile.dll'))) {
        Fail 'amd64 file section was not used'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $prefer 'ignored.dll'))) {
        Fail 'undecorated file section was used beside amd64'
    }
    if (Test-Path -LiteralPath (Join-Path $prefer 'wrong')) {
        Fail 'undecorated disk path was used'
    }

    $already = New-CaseDir 'already'
    $alreadyInf = Join-Path $already 'driver.inf'
    Write-Inf -Path $alreadyInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $already 'amd64/amdfile.dll') -Value 9
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $alreadyInf)) {
        Fail 'file already in the subdirectory returned false'
    }
    if (Test-Path -LiteralPath (Join-Path $already 'amdfile.dll')) {
        Fail 'file already in the subdirectory was copied beside the INF'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $already 'amd64/amdfile.dll'))) {
        Fail 'file already in the subdirectory was removed'
    }

    $both = New-CaseDir 'both'
    $bothInf = Join-Path $both 'driver.inf'
    Write-Inf -Path $bothInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $both 'amdfile.dll') -Value 10
    Write-Bytes -Path (Join-Path $both 'amd64/amdfile.dll') -Value 11
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $bothInf)) {
        Fail 'file in both places returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $both 'amdfile.dll'))) {
        Fail 'existing subdirectory file caused the root file to move'
    }
    $kept = [System.IO.File]::ReadAllBytes((Join-Path $both 'amd64/amdfile.dll'))
    if ($kept.Length -ne 1 -or $kept[0] -ne 11) {
        Fail 'existing subdirectory file was overwritten'
    }

    $missing = New-CaseDir 'missing'
    $missingInf = Join-Path $missing 'driver.inf'
    Write-Inf -Path $missingInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    if (Invoke-PrinterTcpInfLayout -InfPath $missingInf) {
        Fail 'missing file returned true'
    }

    $missingEmpty = New-CaseDir 'missing-empty'
    $missingEmptyInf = Join-Path $missingEmpty 'driver.inf'
    Write-Inf -Path $missingEmptyInf -Lines @(
        '[SourceDisksNames]'
        '1 = "disk",,,'
        ''
        '[SourceDisksFiles]'
        'kofile.dll = 1'
    )
    if (Invoke-PrinterTcpInfLayout -InfPath $missingEmptyInf) {
        Fail 'missing file beside an empty subdirectory returned true'
    }

    $dots = New-CaseDir 'dots'
    $dotsInf = Join-Path $dots 'driver.inf'
    Write-Inf -Path $dotsInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,..'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $dots 'amdfile.dll') -Value 12
    if (Invoke-PrinterTcpInfLayout -InfPath $dotsInf) {
        Fail 'dotdot subdirectory returned true'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dots 'amdfile.dll'))) {
        Fail 'dotdot subdirectory moved the file'
    }

    $slash = New-CaseDir 'slash'
    $slashInf = Join-Path $slash 'driver.inf'
    Write-Inf -Path $slashInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,amd64\nested'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $slash 'amdfile.dll') -Value 13
    if (Invoke-PrinterTcpInfLayout -InfPath $slashInf) {
        Fail 'slash subdirectory returned true'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $slash 'amdfile.dll'))) {
        Fail 'slash subdirectory moved the file'
    }

    $badName = New-CaseDir 'bad-name'
    $badNameInf = Join-Path $badName 'driver.inf'
    Write-Inf -Path $badNameInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        ''
        '[SourceDisksFiles]'
        '..\amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $badName 'amdfile.dll') -Value 14
    if (Invoke-PrinterTcpInfLayout -InfPath $badNameInf) {
        Fail 'bad file name returned true'
    }

    $compressed = New-CaseDir 'compressed'
    $compressedInf = Join-Path $compressed 'driver.inf'
    Write-Inf -Path $compressedInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        '2 = %Disk1%,,,'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
        'rootfile.chm = 2'
    )
    Write-Bytes -Path (Join-Path $compressed 'amdfile.dl_') -Value 15
    Write-Bytes -Path (Join-Path $compressed 'rootfile.ch_') -Value 16
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $compressedInf)) {
        Fail 'compressed names returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $compressed 'amd64/amdfile.dl_'))) {
        Fail 'compressed disk 1 file was not moved'
    }
    if (Test-Path -LiteralPath (Join-Path $compressed 'amdfile.dl_')) {
        Fail 'compressed disk 1 file stayed beside the INF'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $compressed 'rootfile.ch_'))) {
        Fail 'compressed disk 2 file was moved'
    }

    $compressedThere = New-CaseDir 'compressed-there'
    $compressedThereInf = Join-Path $compressedThere 'driver.inf'
    Write-Inf -Path $compressedThereInf -Lines @(
        '[SourceDisksNames.amd64]'
        '1 = %Disk1%,,,"amd64"'
        ''
        '[SourceDisksFiles]'
        'amdfile.dll = 1'
    )
    Write-Bytes -Path (Join-Path $compressedThere 'amd64/AmdFile.DL_') -Value 17
    if (-not (Invoke-PrinterTcpInfLayout -InfPath $compressedThereInf)) {
        Fail 'compressed file already in the subdirectory returned false'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $compressedThere 'amd64/AmdFile.DL_'))) {
        Fail 'compressed file already in the subdirectory was removed'
    }
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'printer-tcp-inf tests passed'
exit 0
