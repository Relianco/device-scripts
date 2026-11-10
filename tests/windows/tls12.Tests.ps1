$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

# Windows PowerShell 5.1 on Server 2016 defaults to explicit TLS 1.0/1.1 (Azure Storage needs 1.2).
# Modern hosts default to SystemDefault (0) and must stay untouched so Windows can negotiate TLS 1.3.
# Each script carries the same one-line guard. Tls12 = 3072, Tls13 = 12288.
$guard = '$tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }'
$ssl3Tls = 192   # Tls (1.0); Ssl3 (48) is rejected by .NET on Linux, the bit test is the same

function Get-Guarded {
    param([string]$Line, [int]$Start)
    [Net.ServicePointManager]::SecurityProtocol = $Start
    Invoke-Expression $Line
    return [int][Net.ServicePointManager]::SecurityProtocol
}

if ((Get-Guarded $guard 0) -ne 0) { Fail 'SystemDefault was changed' }
if ((Get-Guarded $guard (3072 -bor 12288)) -ne (3072 -bor 12288)) { Fail 'Tls12|Tls13 was changed' }
if ((Get-Guarded $guard 3072) -ne 3072) { Fail 'Tls12 was changed' }
if ((Get-Guarded $guard 12288) -ne 12288) { Fail 'Tls13 alone was changed' }
if ((Get-Guarded $guard $ssl3Tls) -ne ($ssl3Tls -bor 3072)) { Fail 'Tls10 did not gain Tls12' }
if ((Get-Guarded $guard 768) -ne (768 -bor 3072)) { Fail 'Tls11 did not gain Tls12' }

# The runner, once dot-sourced, applies the guard to the process.
$env:RELIAN_DEPLOY_TEST = '1'
$runner = Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1'
foreach ($case in @(@(0, 0), @(768, (768 -bor 3072)), @(($ssl3Tls), ($ssl3Tls -bor 3072)))) {
    [Net.ServicePointManager]::SecurityProtocol = $case[0]
    . $runner
    if ([int][Net.ServicePointManager]::SecurityProtocol -ne $case[1]) { Fail "runner: start $($case[0]) gave $([int][Net.ServicePointManager]::SecurityProtocol)" }
}

# A package runs in a child process, which does not inherit the setting.
# Every script that downloads must carry the guard line verbatim.
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows/packages') -Filter '*.ps1' -Recurse)
foreach ($rel in @('windows/runner/Invoke-RelianRunner.ps1', 'windows/runner/Invoke-RelianJob.ps1', 'windows/bootstrap.ps1')) {
    $scripts += Get-Item -LiteralPath (Join-Path $repoRoot $rel)
}
$scripts += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows/jobs') -Filter '*.ps1' -Recurse)
foreach ($file in $scripts) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match 'Invoke-WebRequest|Invoke-RestMethod|HttpWebRequest|WebClient|HttpClient' -and -not $text.Contains($guard)) {
        Fail "$($file.Name) downloads without the Tls12 guard"
    }
    # Any other SecurityProtocol assignment (= Tls12, = 3072, -bor, fully qualified type) is a defect.
    if ($text.Replace($guard, '') -match 'SecurityProtocol\s*=') {
        Fail "$($file.Name) overwrites or ORs SecurityProtocol without the guard"
    }
}

exit 0
