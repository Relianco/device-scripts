$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$pinPath = Join-Path $repoRoot 'releases/psadt.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $pinPath)) {
    Fail "missing $pinPath"
}

$raw = Get-Content -LiteralPath $pinPath -Raw -Encoding utf8
try {
    $pin = $raw | ConvertFrom-Json
} catch {
    Fail "invalid json: $($_.Exception.Message)"
}

$expected = [ordered]@{
    name    = 'PSAppDeployToolkit'
    version = '4.1.8'
    file    = 'PSAppDeployToolkit_ModuleOnly.zip'
    url     = 'https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/4.1.8/PSAppDeployToolkit_ModuleOnly.zip'
    sha256  = '80b45fb8e518ee98774e16e44599d470e4069a0695a6a359022f954edaa83360'
    size    = 8791109
}

$actualNames = @(
    $pin.PSObject.Properties |
        Where-Object { $_.MemberType -eq 'NoteProperty' } |
        ForEach-Object { $_.Name }
)
$expectedNames = @($expected.Keys)

if ($actualNames.Count -ne $expectedNames.Count) {
    Fail "key count $($actualNames.Count) expected $($expectedNames.Count)"
}

foreach ($key in $expectedNames) {
    if ($actualNames -notcontains $key) {
        Fail "missing key $key"
    }
    $actual = $pin.$key
    $want = $expected[$key]
    if ($key -eq 'size') {
        if ([int64]$actual -ne [int64]$want) {
            Fail "size $actual expected $want"
        }
        continue
    }
    if ([string]$actual -cne [string]$want) {
        Fail "$key '$actual' expected '$want'"
    }
}

foreach ($key in $actualNames) {
    if ($expectedNames -notcontains $key) {
        Fail "unexpected key $key"
    }
}

Write-Output 'psadt-pin tests passed'
exit 0
