$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$windowsRoot = Join-Path $PSScriptRoot 'windows'
$tests = @(Get-ChildItem -LiteralPath $windowsRoot -Filter '*.Tests.ps1' -Recurse | Sort-Object -Property FullName)
if ($tests.Count -eq 0) {
    [Console]::Error.WriteLine('No tests found')
    exit 1
}

$failed = $false
foreach ($test in $tests) {
    & pwsh -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("$($test.Name) exited $LASTEXITCODE")
        $failed = $true
    }
}

if ($failed) {
    exit 1
}

exit 0
