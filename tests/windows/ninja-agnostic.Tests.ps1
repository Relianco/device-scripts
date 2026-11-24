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

# ninja-reset removes and reinstalls the NinjaOne agent itself: it may name the agent (NinjaRMMAgent) and the
# pinned installer on the public resources CDN. ad-evidence only names the agent service as the default remote
# "sc.exe query" target. autoelevate may read its key and name fields (LicenseKeyField, CompanyNameField,
# LocationNameField) with Ninja-Property-Get, so the key never goes on a command line (owner, 2026-11-24); it writes none.
# Every other pattern (CLI, fields, API, deploy token) still applies.
function Test-NinjaCoupled {
    param([string]$Rel, [string]$Line)
    $allowed = if ($Rel -eq 'windows/packages/autoelevate/Invoke-AutoElevate.ps1') {
        # Only the one read in Read-AutoElevateNinjaField; any other Ninja-Property-Get line still fails.
        [regex]::new('\A\s*return \(\[string\]\(Ninja-Property-Get \$Field\)\)\.Trim\(\)\s*\z')
    } elseif ($Rel.StartsWith('windows/read/ad-evidence/') -or $Rel -eq 'windows/releases/ad-evidence.json') {
        [regex]::new('NinjaRMMAgent', 'IgnoreCase')
    } elseif ($Rel.StartsWith('windows/packages/ninja-reset/') -or $Rel -eq 'windows/releases/ninja-reset.json') {
        [regex]::new('NinjaRMMAgent|https://resources\.ninjarmm\.com/Agent/[0-9a-z]+/NinjaOneAgent-x86\.msi', 'IgnoreCase')
    } else { $null }
    $text = if ($allowed) { $allowed.Replace($Line, '') } else { $Line }
    return $regex.IsMatch($text)
}

# Self-check of the exceptions: each allows only its own text, in its own files.
$ae = 'windows/packages/autoelevate/Invoke-AutoElevate.ps1'
if (Test-NinjaCoupled $ae '        return ([string](Ninja-Property-Get $Field)).Trim()') { Fail 'autoelevate may read its key field' }
foreach ($line in @('Ninja-Property-Set autoelevateLicenseKey x', '$v | Ninja-Property-Set-Piped f', '& ninjarmm-cli get f', 'Ninja-Property-Get f; Ninja-Property-Set g h', '$x = Ninja-Property-Get someOtherField', 'return ([string](Ninja-Property-Get $Field)).Trim(); Ninja-Property-Set a b')) {
    if (-not (Test-NinjaCoupled $ae $line)) { Fail "autoelevate exception lets through [$line]" }
}
if (-not (Test-NinjaCoupled 'windows/packages/7-zip/Invoke-7Zip.ps1' 'Ninja-Property-Get f')) { Fail 'another package may read a field' }

$found = @()
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        if (Test-NinjaCoupled $rel $line) { $found += "${rel}: $($line.Trim())" }
    }
}
if ($found.Count) { Fail ("NinjaOne coupling in packages:`n" + ($found -join "`n")) }

Write-Output 'ninja-agnostic tests passed'
