$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Section RemoveInstallLog deletes the verbose msiexec log the vendor's NinjaOne script writes
# (C:\AEInstallLog.log, it holds the licence key) and nothing else. Real files in a temp folder.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/autoelevate/Invoke-AutoElevate.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

if ($script:AutoElevateInstallLogPath -cne 'C:\AEInstallLog.log') { Fail "the log path is not the vendor script's: $script:AutoElevateInstallLogPath" }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('autoelevate-log-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $log = Join-Path $root 'AEInstallLog.log'
    $other = Join-Path $root 'keep.log'
    Set-Content -LiteralPath $log -Value 'Property(S): LICENSE_KEY = x'
    Set-Content -LiteralPath $other -Value 'keep'
    $script:AutoElevateInstallLogPath = $log

    $r = Remove-AutoElevateInstallLog
    if ($r.InstallLog -cne 'removed') { Fail "present log: $($r.InstallLog)" }
    if (Test-Path -LiteralPath $log) { Fail 'the log is still there' }
    if (-not (Test-Path -LiteralPath $other)) { Fail 'another file was removed' }

    $r = Remove-AutoElevateInstallLog
    if ($r.InstallLog -cne 'absent') { Fail "absent log: $($r.InstallLog)" }

    # A folder at that path is not the log: left alone and reported.
    New-Item -ItemType Directory -Path $log | Out-Null
    $r = Remove-AutoElevateInstallLog
    if ($r.InstallLog -cne 'not a file' -or -not (Test-Path -LiteralPath $log)) { Fail "folder at the log path: $($r.InstallLog)" }

    # Wired as a Section: the script reports InstallLog and exits 0 (no such file here).
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST'
    $out = (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath -DeploymentType Install -Action Install -PinVersion 2.11.1959 -Section RemoveInstallLog 2>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($code -ne 0 -or $out -notmatch '"InstallLog":"absent"') { Fail "Section RemoveInstallLog (exit $code): $out" }
} finally {
    $env:RELIAN_DEPLOY_TEST = '1'
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'autoelevate-install-log tests passed'
exit 0
