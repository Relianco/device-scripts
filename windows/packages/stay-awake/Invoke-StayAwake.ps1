<#
.SYNOPSIS
    Keeps a Windows device awake on AC power for a maintenance window, then puts its sleep settings back,
    for the Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    A device woken by Wake-on-LAN with nobody signed in goes back to sleep after the "unattended sleep"
    timeout (often 2 minutes), which can cut a repair in half. This package holds it awake and restores it.

    Mode (a PackageArguments string; default Report):
      Report   read-only. Prints the active power scheme and the AC and DC values of the sleep-after
               (STANDBYIDLE) and unattended-sleep (UNATTENDSLEEP) timeouts, in seconds, and whether a
               saved file exists.
      Hold     reads the current values and saves them to C:\ProgramData\Relian\stay-awake\saved.json,
               then sets both AC timeouts to 0 (never) on the active scheme and re-applies the scheme.
               If saved.json already exists, it is kept as is (it holds the values from before the first
               Hold), so a repeated Hold never saves 0 as the "original". DC values are not changed.
      Restore  puts the saved AC values back on the saved scheme, re-applies it, reads them back and
               deletes saved.json only when the read-back matches. No saved file: nothing to restore, exit 0.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name
    value. Uninstall means Restore. An empty PinVersion is the off switch. All values go through
    powercfg.exe; the saved file holds only a scheme GUID and four integers, and every value read back from
    it is validated before use, since a non-admin can create files under ProgramData.

    The result is one line of compact JSON, printed last on stdout. Exit 1 when powercfg fails, a value
    cannot be read, the saved file is invalid, or a read-back does not match. No reboot, no RMM field.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. No external module dependencies.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = ''
)

$ProgressPreference = 'SilentlyContinue'

$script:SaSettings = @('STANDBYIDLE', 'UNATTENDSLEEP')
$script:SaGuidPattern = '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
$script:SaDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\stay-awake'
$script:SaFile = Join-Path $script:SaDir 'saved.json'

# Seams. Tests replace them.
$script:SaPowercfg = {
    param([string[]]$Arguments)
    $exe = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $out = @(& $exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Lines = $out; ExitCode = [int]$LASTEXITCODE }
}
$script:SaReadSaved = {
    if (-not (Test-Path -LiteralPath $script:SaFile -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($script:SaFile)
}
$script:SaWriteSaved = {
    param([string]$Json)
    [void][IO.Directory]::CreateDirectory($script:SaDir)
    [IO.File]::WriteAllText($script:SaFile, $Json, (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::ReadAllText($script:SaFile) -cne $Json) { throw 'saved file readback differs' }
}
$script:SaRemoveSaved = { Remove-Item -LiteralPath $script:SaFile -Force -ErrorAction Stop }

# Pure: Report | Hold | Restore | none. Throws on bad input.
function Get-SaMode {
    param([string]$Action, [string]$Mode, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -cnotcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall') { return 'Restore' }
    if ($Mode -eq '') { return 'Report' }
    if (@('Report', 'Hold', 'Restore') -ccontains $Mode) { return $Mode }
    throw 'Mode must be Report, Hold or Restore.'
}

# Pure: the active scheme GUID from `powercfg /getactivescheme` output (language independent).
function Get-SaSchemeFromLines {
    param([string[]]$Lines)
    foreach ($l in @($Lines)) {
        if ($l -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLowerInvariant() }
    }
    throw 'active scheme not found'
}

# Pure: AC and DC values from `powercfg /q <scheme> SUB_SLEEP <setting>` output. The labels are localized,
# so it takes the last two "...: 0x<hex>" lines: powercfg prints the current AC index, then the current DC
# index, after the minimum, maximum and increment lines.
function Get-SaIndexFromLines {
    param([string[]]$Lines)
    $hex = @(@($Lines) | ForEach-Object { if ($_ -match ':\s*0x([0-9a-fA-F]{1,8})\s*\z') { [Convert]::ToUInt32($Matches[1], 16) } })
    if ($hex.Count -lt 2) { throw 'current AC and DC values not found' }
    return [ordered]@{ ac = [long]$hex[$hex.Count - 2]; dc = [long]$hex[$hex.Count - 1] }
}

# Pure: $null when a saved object is a valid record, else a fixed reason.
function Test-SaSaved {
    param($Saved)
    if ($null -eq $Saved) { return 'empty' }
    if ([string]$Saved.scheme -cnotmatch $script:SaGuidPattern) { return 'bad scheme' }
    foreach ($s in $script:SaSettings) {
        $v = $Saved.values.$s
        if ($null -eq $v) { return "missing $s" }
        foreach ($k in 'ac', 'dc') {
            $n = 0L
            if (-not [long]::TryParse([string]$v.$k, [ref]$n) -or $n -lt 0 -or $n -gt 4294967295) { return "bad $s $k" }
        }
    }
    return $null
}

function Invoke-SaCfg {
    param([string[]]$Arguments)
    $r = & $script:SaPowercfg $Arguments
    if ($r.ExitCode -ne 0) { throw "powercfg $($Arguments[0]) exit $($r.ExitCode)" }
    return @($r.Lines)
}

function Get-SaCurrent {
    param([string]$Scheme)
    if (-not $Scheme) { $Scheme = Get-SaSchemeFromLines (Invoke-SaCfg @('/getactivescheme')) }
    $values = [ordered]@{}
    foreach ($s in $script:SaSettings) { $values[$s] = Get-SaIndexFromLines (Invoke-SaCfg @('/q', $Scheme, 'SUB_SLEEP', $s)) }
    return [ordered]@{ scheme = $Scheme; values = $values }
}

function Set-SaAc {
    param([string]$Scheme, $AcValues)
    foreach ($s in $script:SaSettings) { [void](Invoke-SaCfg @('/setacvalueindex', $Scheme, 'SUB_SLEEP', $s, [string]$AcValues[$s])) }
    [void](Invoke-SaCfg @('/setactive', $Scheme))
}

function Invoke-SaRun {
    param([string]$Mode)
    $rec = [ordered]@{ mode = $Mode; status = 'error'; scheme = $null; before = $null; after = $null; saved = $false; error = $null; version = '1.0' }
    $code = 1
    try {
        $now = Get-SaCurrent
        $rec.scheme = $now.scheme
        $rec.before = $now.values
        $raw = & $script:SaReadSaved
        $rec.saved = ($null -ne $raw)
        $saved = $null
        if ($null -ne $raw) {
            try { $saved = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $saved = $null }
            $why = Test-SaSaved $saved
            if ($why) { throw "saved file invalid: $why" }
        }
        switch ($Mode) {
            'Report' { $rec.status = 'report' }
            'Hold' {
                if ($null -eq $saved) {
                    & $script:SaWriteSaved ($now | ConvertTo-Json -Depth 4 -Compress)
                    $rec.saved = $true
                }
                Set-SaAc $now.scheme @{ STANDBYIDLE = 0; UNATTENDSLEEP = 0 }
                $after = Get-SaCurrent $now.scheme
                $rec.after = $after.values
                foreach ($s in $script:SaSettings) { if ($after.values[$s].ac -ne 0) { throw "hold readback: $s AC is $($after.values[$s].ac)" } }
                $rec.status = 'held'
            }
            'Restore' {
                if ($null -eq $saved) { $rec.status = 'nothing-saved'; break }
                $want = @{}
                foreach ($s in $script:SaSettings) { $want[$s] = [long]$saved.values.$s.ac }
                $scheme = ([string]$saved.scheme).ToLowerInvariant()
                $rec.scheme = $scheme
                Set-SaAc $scheme $want
                $after = Get-SaCurrent $scheme
                $rec.after = $after.values
                foreach ($s in $script:SaSettings) { if ($after.values[$s].ac -ne $want[$s]) { throw "restore readback: $s AC is $($after.values[$s].ac), want $($want[$s])" } }
                & $script:SaRemoveSaved
                $rec.saved = $false
                $rec.status = 'restored'
            }
        }
        $code = 0
    } catch {
        $rec.error = ("$($_.Exception.Message)" -replace '\s+', ' ').Trim()
        if ($rec.error.Length -gt 200) { $rec.error = $rec.error.Substring(0, 200) }
    }
    return [ordered]@{ record = $rec; exitCode = $code }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $saMode = Get-SaMode -Action $Action -Mode $Mode -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($saMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    $run = Invoke-SaRun -Mode $saMode
    Write-Output ($run.record | ConvertTo-Json -Depth 5 -Compress)
    exit $run.exitCode
}
