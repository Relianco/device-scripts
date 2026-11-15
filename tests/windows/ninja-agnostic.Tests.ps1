# Packages and jobs are RMM-agnostic: they report through stdout and the exit code only.
# They must not read or write NinjaOne custom fields, call the agent CLI or the NinjaOne API,
# or read the deploy token. bootstrap.ps1 and collectors/ are the Ninja inventory layer and
# are not scanned. No network.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Each pattern is a coupling, not a mention: "NinjaOne script 374" in a comment is fine.
$patterns = @(
    'ninjarmm-cli',
    'Ninja-Property-',
    'NinjaRMMAgent',
    'NINJA_DATA_PATH',
    'relian_git_deploy_token',
    'ninjarmm\.com',
    'ninjaone\.com/(api|v2|ws)',
    '"ninjaField"'
)
$regex = [regex]::new(($patterns -join '|'), 'IgnoreCase')

# Self-check: each pattern matches its own sample, and a plain mention does not.
foreach ($sample in @('& $cli get x # ninjarmm-cli.exe', 'Ninja-Property-Set a b', 'C:\ProgramData\NinjaRMMAgent', '${NINJA_DATA_PATH}', 'relian_git_deploy_token', 'https://app.ninjarmm.com/v2/devices', 'https://eu.ninjaone.com/api/v2', '  "ninjaField": "x",')) {
    if (-not $regex.IsMatch($sample)) { Fail "lint misses [$sample]" }
}
if ($regex.IsMatch('Run it through the deploy runner (NinjaOne script 374).')) { Fail 'lint flags a plain NinjaOne mention' }

# One reviewed exception: storage-maintenance may write its ProfileReport JSON to a custom field
# the caller names (ReportCustomField). Only the property setter (Ninja-Property-Set) is allowed there, so reads, options and clears stay flagged; every other
# coupling is still flagged in that file. Not removed: the field write is the requested feature, and README rule 4 names the exception.
$exemptFile = 'windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
$exemptRegex = [regex]::new((($patterns | ForEach-Object { if ($_ -eq 'Ninja-Property-') { 'Ninja-Property-(?!Set\b)' } else { $_ } }) -join '|'), 'IgnoreCase')
if ($exemptRegex.IsMatch('Ninja-Property-Set a b')) { Fail 'exemption must allow the property setter' }
foreach ($s in @('Ninja-Property-Get a', 'Ninja-Property-Options a', 'Ninja-Property-Clear a')) { if (-not $exemptRegex.IsMatch($s)) { Fail "exemption hides [$s]" } }
if (-not $exemptRegex.IsMatch('ninjarmm-cli.exe set a b')) { Fail 'exemption hides ninjarmm-cli' }

$roots = @('windows/packages', 'windows/jobs', 'windows/releases', 'linux/packages', 'macos/packages')
$files = foreach ($r in $roots) {
    $p = Join-Path $repoRoot $r
    if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Recurse -File }
}
if (@($files).Count -lt 10) { Fail "only $(@($files).Count) files scanned" }

$found = @()
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
    $hits = @(Select-String -LiteralPath $file.FullName -Pattern $(if ($rel -eq $exemptFile) { $exemptRegex.ToString() } else { $regex.ToString() }) -AllMatches:$false)
    foreach ($h in $hits) { $found += "${rel}:$($h.LineNumber): $($h.Line.Trim())" }
}
if ($found.Count) { Fail ("NinjaOne coupling in packages:`n" + ($found -join "`n")) }

Write-Output 'ninja-agnostic tests passed'
