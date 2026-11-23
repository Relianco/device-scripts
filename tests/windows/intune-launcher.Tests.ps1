$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# IME starts Win32 app commands from a 32-bit host. A bare powershell.exe there is the SysWOW64 host:
# System32, HKLM\SOFTWARE and $env:ProgramFiles redirect, and System32\pnputil.exe is missing
# (Sitka Convey Konica, 2026-11-23, 0x80070001). Every package command must start 64-bit PowerShell.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launcher = '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe '

function Get-CommandStrings {
    param($Node, [string]$Path)
    if ($null -eq $Node) { return }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) { Get-CommandStrings -Node $item -Path "$Path[$i]"; $i++ }
        return
    }
    if ($Node -is [pscustomobject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            if ($prop.Name -in @('installCommand', 'uninstallCommand') -and $prop.Value -is [string]) {
                [pscustomobject]@{ Path = "$Path.$($prop.Name)"; Value = [string]$prop.Value }
            } else {
                Get-CommandStrings -Node $prop.Value -Path "$Path.$($prop.Name)"
            }
        }
    }
}

$files = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows/packages') -Recurse -Filter 'intune.json' -File)
if ($files.Count -lt 20) {
    [Console]::Error.WriteLine("FAIL found only $($files.Count) intune.json files")
    exit 1
}
$bad = @()
$seen = 0
foreach ($file in $files) {
    $meta = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($cmd in @(Get-CommandStrings -Node $meta -Path $file.Directory.Name)) {
        $seen++
        if (-not $cmd.Value.StartsWith($launcher, [System.StringComparison]::Ordinal)) {
            $bad += "$($cmd.Path): $($cmd.Value.Split(' ')[0])"
        }
    }
}
if ($seen -lt ($files.Count * 2)) {
    [Console]::Error.WriteLine("FAIL found only $seen commands in $($files.Count) files")
    exit 1
}
if ($bad.Count -gt 0) {
    [Console]::Error.WriteLine("FAIL commands not launched with 64-bit PowerShell: " + ($bad -join '; '))
    exit 1
}
Write-Output "intune-launcher tests passed ($seen commands)"
