# Keeps README.md from going stale. Every package or job folder on every platform must be named in
# that platform's README section, and a bullet that names a package there must name one that exists.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw

$failures = [System.Collections.Generic.List[string]]::new()

# Folders that exist on main, by platform. A job is a .ps1 file under windows/jobs.
$inventory = [ordered]@{
    Windows = @(
        @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows/packages') -Directory | ForEach-Object Name) +
        @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows/jobs') -Filter '*.ps1' -File | ForEach-Object BaseName)
    )
    Linux   = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'linux/packages') -Directory | ForEach-Object Name)
    macOS   = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'macos/packages') -Directory | ForEach-Object Name)
}

# The README text of one platform: from its "## <Platform>" heading to the next "## " heading.
function Get-PlatformSection {
    param([string]$Platform)
    $match = [regex]::Match($readme, "(?ms)^## $Platform\b.*?(?=^## |\z)")
    if (-not $match.Success) {
        $failures.Add("README.md has no '## $Platform' section")
        return ''
    }
    return $match.Value
}

foreach ($platform in $inventory.Keys) {
    $section = Get-PlatformSection -Platform $platform
    $known = @($inventory[$platform])
    foreach ($name in $known) {
        if ($section -notmatch ('`' + [regex]::Escape($name) + '`')) {
            $failures.Add("$platform folder '$name' is not named in the README $platform section")
        }
    }
    # A list item that starts with a backticked name is a package entry.
    foreach ($m in [regex]::Matches($section, '(?m)^- `([a-z0-9][a-z0-9.-]*)`')) {
        $named = $m.Groups[1].Value
        if ($known -notcontains $named) {
            $failures.Add("README $platform section names '$named', which is not a $platform package or job")
        }
    }
}

# An explicit path must exist, wherever it appears.
foreach ($m in [regex]::Matches($readme, '(windows|linux|macos)/(packages|jobs)/([A-Za-z0-9][A-Za-z0-9._-]*)')) {
    $name = $m.Groups[3].Value -replace '\.(ps1|sh|json)$', ''
    $dir = Join-Path $repoRoot ($m.Groups[1].Value + '/' + $m.Groups[2].Value)
    if (-not ((Test-Path -LiteralPath (Join-Path $dir $name)) -or (Test-Path -LiteralPath (Join-Path $dir "$name.ps1")))) {
        $failures.Add("README names '$($m.Value)', which does not exist")
    }
}

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { [Console]::Error.WriteLine("FAIL $f") }
    exit 1
}
Write-Output 'readme-inventory: ok'
