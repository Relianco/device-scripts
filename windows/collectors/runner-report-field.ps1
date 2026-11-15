<#
.SYNOPSIS
    Run the Relian runner and store the storage-maintenance ProfileReport JSON in a NinjaOne device custom field.

.DESCRIPTION
    Paste this one file into NinjaOne and run it as SYSTEM instead of Invoke-RelianRunner.ps1. It downloads
    the runner from RunnerUrl, checks RunnerSha256, runs it as a child with the runner arguments you pass,
    and adds -ReportOutputPath. After a run that exited 0 it reads the saved report line, applies the
    guards below and writes it with Ninja-Property-Set. The runner and the packages call no NinjaOne API.

    Guards: field name ^[A-Za-z][A-Za-z0-9]{0,39}$; the file must be fresh (written after this run
    started), a single line of at most 9500 UTF-8 bytes that starts with the schema-v2 marker and has mode
    Report; the handoff directory is SYSTEM and Administrators only and is deleted afterwards. A missing
    cmdlet or a failed write prints one line naming only the field. The runner's exit code is returned
    unchanged and its output is not altered.

.PARAMETER RunnerUrl
    Raw URL of windows/runner/Invoke-RelianRunner.ps1 at a pinned commit.

.PARAMETER RunnerSha256
    SHA256 of that file.

.PARAMETER ReportCustomField
    Device custom field name. Type Multi-line text. Automation Read/Write, API Read-only.

.NOTES
    Every other argument (-PackageUrl, -PackageSha256, ... -PackageArguments) is passed to the runner as is.
    Do not use the runner's empty-hash off switch here: an empty value is dropped before it reaches the runner.
    Requirements: Windows PowerShell 5.1+, run as SYSTEM.
#>
[CmdletBinding()]
param(
    [string]$RunnerUrl,
    [string]$RunnerSha256,
    [string]$ReportCustomField,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RunnerArguments
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$script:ReportMarker = '{"schemaVersion":2,"package":"storage-maintenance",'
$script:ReportMaxBytes = 9500

# Seams. Tests replace them.
$script:NewHandoffDir = {
    $path = Join-Path $env:ProgramData ('Relian\report-' + [guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Path $path -Force)
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $who = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $security
    return $path
}
$script:DownloadFile = { param($Url, $Destination) Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 }
$script:RunRunner = {
    param($RunnerFile, $Arguments)
    $hostPath = (Get-Process -Id $PID).Path
    & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RunnerFile @Arguments
    return [int]$LASTEXITCODE
}
$script:SetCustomField = { param($Name, $Value) Ninja-Property-Set $Name $Value }
$script:TestCustomFieldCmd = { [bool](Get-Command -Name 'Ninja-Property-Set' -ErrorAction SilentlyContinue) }

function Get-RelianReportLine {
    # Returns the report line, or $null. The file is trusted only if fresh, not a link, and well formed.
    param([string]$Path, [datetime]$StartedUtc)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
    if ($item.LastWriteTimeUtc -lt $StartedUtc.AddSeconds(-2)) { return $null }
    if ($item.Length -gt $script:ReportMaxBytes) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
    if ($text -match "[\r\n]" -or -not $text.StartsWith($script:ReportMarker, [StringComparison]::Ordinal)) { return $null }
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $script:ReportMaxBytes) { return $null }
    try { if ((($text | ConvertFrom-Json).mode) -cne 'Report') { return $null } } catch { return $null }
    return $text
}

function Invoke-RelianReportField {
    param([string]$RunnerUrl, [string]$RunnerSha256, [string]$ReportCustomField, [string[]]$RunnerArguments)
    $field = [string]$ReportCustomField
    if ($field -notmatch '\A[A-Za-z][A-Za-z0-9]{0,39}\z') { Write-Output 'invalid ReportCustomField'; return 1 }
    if ($RunnerUrl -match '\A\s*[a-z][a-z0-9+.-]*:[\\/]{2}[^\\/?#]*@') { Write-Output 'refusing a URL that contains userinfo'; return 1 }
    if ([string]::IsNullOrWhiteSpace($RunnerUrl) -or [string]::IsNullOrWhiteSpace($RunnerSha256)) { Write-Output 'RunnerUrl and RunnerSha256 are required'; return 1 }
    if (@($RunnerArguments | Where-Object { $_ -match '\A-ReportOutputPath\z' }).Count) { Write-Output 'ReportOutputPath is set by this script'; return 1 }
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }

    $dir = & $script:NewHandoffDir
    try {
        $runnerFile = Join-Path $dir 'runner.ps1'
        $reportFile = Join-Path $dir 'report.json'
        try { & $script:DownloadFile $RunnerUrl $runnerFile } catch { Write-Output 'runner download failed'; return 1 }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $runnerFile).Hash -ne $RunnerSha256.Trim()) { Write-Output 'hash mismatch for runner'; return 1 }
        $started = [datetime]::UtcNow
        $code = [int](& $script:RunRunner $runnerFile (@($RunnerArguments) + @('-ReportOutputPath', $reportFile)))
        if ($code -ne 0) { return $code }
        $line = Get-RelianReportLine -Path $reportFile -StartedUtc $started
        if ($null -eq $line) { return $code }   # not a report run, or no valid report: nothing to write
        if (-not [bool](& $script:TestCustomFieldCmd)) { Write-Output "report field '$field' not written: custom-field cmdlet not available"; return $code }
        try { & $script:SetCustomField $field $line } catch { Write-Output "report field '$field' not written: write failed"; return $code }
        Write-Output "report written to custom field '$field'"
        return $code
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
exit (Invoke-RelianReportField -RunnerUrl $RunnerUrl -RunnerSha256 $RunnerSha256 -ReportCustomField $ReportCustomField -RunnerArguments $RunnerArguments)
