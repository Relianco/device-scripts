# Builds the WDOT zip: WDOT at the commit in windows/releases/wdot.json, plus
# windows/packages/wdot/profile as Configurations/Relian. Prints the sha256
# and the content-addressed blob name. Uploads nothing; README has the az line.
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) ('wdot-build-' + [guid]::NewGuid().ToString('n')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Absolute before any git -C, which would resolve a relative path from its own folder.
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$repoRoot = Split-Path -Parent $PSScriptRoot
$release = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/releases/wdot.json') -Raw | ConvertFrom-Json
$commit = [string]$release.commit
$repoUri = $null
if (-not [Uri]::TryCreate([string]$release.repository, [UriKind]::Absolute, [ref]$repoUri) -or
    $repoUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($repoUri.UserInfo)) {
    [Console]::Error.WriteLine('windows/releases/wdot.json repository must be https with no userinfo')
    exit 1
}
if ($commit -notmatch '^[0-9a-f]{40}$') {
    throw 'windows/releases/wdot.json commit is not a full SHA'
}

$clone = Join-Path $OutDir 'src'
$stage = Join-Path $OutDir 'stage'
$tool = Join-Path $stage 'Windows-Desktop-Optimization-Tool'
[void](New-Item -ItemType Directory -Path $clone, $tool -Force)

& git -c advice.detachedHead=false clone --quiet ([string]$release.repository + '.git') $clone
if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
& git -C $clone checkout --quiet $commit
if ($LASTEXITCODE -ne 0) { throw 'git checkout failed' }
$head = (& git -C $clone rev-parse HEAD).Trim()
if ($head -cne $commit) { throw "checked out $head, not $commit" }

# Tracked files only, at the pinned commit.
$tar = Join-Path $OutDir 'wdot.tar'
& git -C $clone archive --format=tar -o $tar $commit
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
& tar -xf $tar -C $tool
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }

$profileDir = Join-Path $tool 'Configurations/Relian'
[void](New-Item -ItemType Directory -Path $profileDir -Force)
Copy-Item -Path (Join-Path $repoRoot 'windows/packages/wdot/profile/*') -Destination $profileDir

$zip = Join-Path $OutDir 'wdot-relian.zip'
Compress-Archive -Path $tool -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
$name = "wdot-relian-$hash.zip"
Rename-Item -LiteralPath $zip -NewName $name
Write-Output "file   $(Join-Path $OutDir $name)"
Write-Output "sha256 $hash"
Write-Output "size   $((Get-Item -LiteralPath (Join-Path $OutDir $name)).Length)"
Write-Output "blob   rmm/wdot/$name"
