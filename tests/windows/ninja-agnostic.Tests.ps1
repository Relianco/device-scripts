# Packages and jobs are RMM-agnostic: they report through stdout and the exit code only.
# They must not read or write NinjaOne custom fields, call the agent CLI or the NinjaOne API,
# or read the deploy token. collectors/ are the Ninja inventory layer and
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

$roots = @('windows/packages', 'windows/read', 'windows/jobs', 'windows/releases', 'linux/packages', 'macos/packages')
$files = foreach ($r in $roots) {
    $p = Join-Path $repoRoot $r
    if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Recurse -File }
}
if (@($files).Count -lt 10) { Fail "only $(@($files).Count) files scanned" }

$found = @()
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
    # ninja-reset removes and reinstalls the NinjaOne agent itself: it may name the agent (NinjaRMMAgent) and the
    # pinned installer on the public resources CDN. ad-evidence only names the agent service as the default remote
    # "sc.exe query" target. Every other pattern (CLI, fields, API, deploy token) still applies.
    $allowed = if ($rel.StartsWith('windows/read/ad-evidence/') -or $rel -eq 'windows/releases/ad-evidence.json') {
        [regex]::new('NinjaRMMAgent', 'IgnoreCase')
    } elseif ($rel.StartsWith('windows/packages/ninja-reset/') -or $rel -eq 'windows/releases/ninja-reset.json') {
        [regex]::new('NinjaRMMAgent|https://resources\.ninjarmm\.com/Agent/[0-9a-z]+/NinjaOneAgent-x86\.msi', 'IgnoreCase')
    } else { $null }
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        $text = if ($allowed) { $allowed.Replace($line, '') } else { $line }
        if ($regex.IsMatch($text)) { $found += "${rel}: $($line.Trim())" }
    }
}
if ($found.Count) { Fail ("NinjaOne coupling in packages:`n" + ($found -join "`n")) }

Write-Output 'ninja-agnostic tests passed'
