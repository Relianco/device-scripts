$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The licence never reaches a process command line (Security 4688 and Sysmon event 1 log
# them). It comes as base64 of the .xcvault KeyFile in PdfXchangeKeyFile, is written to a
# folder only SYSTEM and Administrators can open, and XCVault gets only the file path.

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/pdf-xchange/Invoke-PdfXchange.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Fake licence material: the real key and KeyFile never enter this repo.
$fakeKey = 'PXP10-' + ('AbCd+/' * 6) + 'Q=='
$vaultBytes = [System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><Vault><Key>' + $fakeKey + '</Key></Vault>')
$vaultBase64 = [Convert]::ToBase64String($vaultBytes)

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('pdfx-key-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path (Join-Path $root 'PDF-XChange/Vault') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $root 'PDF-XChange/Vault/XCVault.exe'), 'fake')
$env:ProgramFiles = $root
$installerBytes = [System.Text.Encoding]::UTF8.GetBytes('pdfx-installer')
$sha = [System.Security.Cryptography.SHA256]::Create()
$installerSha = ([System.BitConverter]::ToString($sha.ComputeHash($installerBytes))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()

# The process-start boundary: every command line the package would start. When XCVault
# starts, the file named on its command line is read so the test can see what it held.
function Start-Process {
    param([string]$FilePath, [object[]]$ArgumentList, [switch]$Wait, [switch]$PassThru, [string]$WindowStyle)
    $line = @($ArgumentList) -join ' '
    $held = $null
    $exit = 0
    if ((Split-Path -Leaf $FilePath) -ceq 'XCVault.exe') {
        $script:Events.Add('xcvault')
        $path = [string]@($ArgumentList)[1]
        $path = $path.Trim('"')
        $script:KeyFilePath = $path
        if (Test-Path -LiteralPath $path) {
            $held = [System.IO.File]::ReadAllBytes($path)
        }
        $exit = $script:VaultExit
    } else {
        $exit = $script:MsiExit
    }
    $script:Started.Add([pscustomobject]@{ FilePath = $FilePath; Args = @($ArgumentList); Line = $line; Wait = [bool]$Wait; Held = $held })
    return [pscustomobject]@{ ExitCode = $exit }
}

function Reset-KeyCase {
    $script:Started = [System.Collections.Generic.List[object]]::new()
    $script:Events = [System.Collections.Generic.List[string]]::new()
    $script:PdfXchangeErrorLog = [System.Collections.Generic.List[string]]::new()
    $script:PdfXchangeNoteLog = [System.Collections.Generic.List[string]]::new()
    $script:KeyFilePath = ''
    $script:AclPath = ''
    $script:VaultExit = 0
    $script:MsiExit = 0
    $script:Downloads = 0
    $script:DownloadFile = { param($Url, $Destination) $script:Downloads++; [System.IO.File]::WriteAllBytes($Destination, $installerBytes) }
    $script:GetInstalledPdfXchangeVersion = { return '' }
    $script:TestFullAcrobat = { return $false }
    $script:SetPdfXchangePolicy = { }
    # The ACL boundary: record that the folder was restricted while it was still empty.
    $script:ProtectPdfXchangeKeyDirectory = {
        param($Path)
        $script:AclPath = [string]$Path
        $script:Events.Add('acl:' + @(Get-ChildItem -LiteralPath $Path -Force).Count)
    }
    if (Test-Path -LiteralPath $script:Marker) {
        Remove-Item -LiteralPath $script:Marker -Recurse -Force
    }
}

function Invoke-KeyCase {
    param([string]$KeyFileText, [string]$KeyDataText = '')
    return [int](Invoke-PdfXchangeAction -DeploymentType Install -Action Install -PinVersion '2.0.0.0' -InstallerUrl 'https://example.invalid/pdfx.msi' -InstallerSha256 $installerSha -CancelPath '' -MarkerRoot $script:Marker -KeyFileText $KeyFileText -KeyDataText $KeyDataText)
}

function Assert-NoSecretAnywhere {
    param([string]$Label)
    foreach ($start in $script:Started) {
        foreach ($secret in @('AbCd', $fakeKey, $vaultBase64)) {
            if ($start.Line.Contains($secret)) {
                Fail "$Label the licence reached the command line of $(Split-Path -Leaf $start.FilePath)"
            }
        }
    }
    $errors = $script:PdfXchangeErrorLog -join "`n"
    if ($errors.Contains('AbCd') -or $errors.Contains($vaultBase64)) {
        Fail "$Label an error message held the licence"
    }
}

function Test-MarkerWritten {
    return Test-Path -LiteralPath (Join-Path $script:Marker 'marker.txt')
}

$script:Marker = Join-Path $root 'marker'
try {
    # (1) A fresh install with the KeyFile: no command line carries the key.
    Reset-KeyCase
    $code = Invoke-KeyCase -KeyFileText $vaultBase64 -KeyDataText $fakeKey
    if ($code -ne 0 -or -not (Test-MarkerWritten)) {
        Fail "install with KeyFile exit $code, marker $(Test-MarkerWritten)"
    }
    if ($script:Started.Count -ne 2) {
        Fail "expected msiexec and XCVault, saw $($script:Started.Count) process starts"
    }
    Assert-NoSecretAnywhere -Label 'install'
    $vault = $script:Started[1]
    # Vendor syntax: xcvault.exe /AddKeys "<filename>" [/M] [/S] (V11 SysAdmin manual).
    if ($vault.Args.Count -ne 4 -or $vault.Args[0] -cne '/AddKeys' -or $vault.Args[2] -cne '/M' -or $vault.Args[3] -cne '/S' -or
        $vault.Args[1] -notmatch '^"[^"]+[\\/]Personal\.xcvault"$' -or -not $vault.Wait) {
        Fail "XCVault arguments '$($vault.Line)' wait $($vault.Wait)"
    }
    foreach ($start in $script:Started) {
        if (-not $start.Wait) {
            Fail 'a process was started without -Wait'
        }
    }

    # (2) The folder was restricted while empty, the file held the KeyFile bytes, and both are gone.
    if (($script:Events -join ',') -cne 'acl:0,xcvault') {
        Fail "events '$($script:Events -join ',')' expected 'acl:0,xcvault'"
    }
    if ((Split-Path -Parent $script:KeyFilePath) -cne $script:AclPath) {
        Fail 'the key file is not in the restricted folder'
    }
    if ($null -eq $vault.Held -or [Convert]::ToBase64String($vault.Held) -cne $vaultBase64) {
        Fail 'the key file did not hold the KeyFile bytes when XCVault ran'
    }
    if ((Test-Path -LiteralPath $script:KeyFilePath) -or (Test-Path -LiteralPath $script:AclPath)) {
        Fail 'the key file or its folder was left after success'
    }

    # XCVault fails: the run fails with no marker, and the key file is still removed.
    Reset-KeyCase
    $script:VaultExit = 5
    $code = Invoke-KeyCase -KeyFileText $vaultBase64
    if ($code -ne 1 -or (Test-MarkerWritten)) {
        Fail "XCVault failure exit $code, marker $(Test-MarkerWritten)"
    }
    Assert-NoSecretAnywhere -Label 'XCVault failure'
    if ([string]::IsNullOrEmpty($script:KeyFilePath) -or (Test-Path -LiteralPath $script:KeyFilePath) -or (Test-Path -LiteralPath $script:AclPath)) {
        Fail 'the key file or its folder was left after XCVault failed'
    }

    # The folder cannot be restricted: the key is never written and XCVault never runs.
    Reset-KeyCase
    $script:ProtectPdfXchangeKeyDirectory = {
        param($Path)
        $script:AclPath = [string]$Path
        throw 'Set-Acl failed'
    }
    $code = Invoke-KeyCase -KeyFileText $vaultBase64
    if ($code -ne 1 -or (Test-MarkerWritten) -or $script:Started.Count -ne 1) {
        Fail "ACL failure exit $code, starts $($script:Started.Count)"
    }
    if ([string]::IsNullOrEmpty($script:AclPath) -or (Test-Path -LiteralPath $script:AclPath)) {
        Fail 'the unrestricted folder was left after the ACL failed'
    }

    # Only the old PdfXchangeKeyData is set: refuse before any download, naming PdfXchangeKeyFile.
    Reset-KeyCase
    $code = Invoke-KeyCase -KeyFileText '' -KeyDataText $fakeKey
    if ($code -ne 1 -or $script:Downloads -ne 0 -or $script:Started.Count -ne 0 -or (Test-MarkerWritten)) {
        Fail "KeyData only exit $code, downloads $($script:Downloads), starts $($script:Started.Count)"
    }
    if (($script:PdfXchangeErrorLog -join "`n") -notlike '*PdfXchangeKeyFile*') {
        Fail 'KeyData-only refusal does not name PdfXchangeKeyFile'
    }
    Assert-NoSecretAnywhere -Label 'KeyData only'

    # A KeyFile that is missing, not base64, empty or over 64 KB is refused before any download.
    $tooBig = [Convert]::ToBase64String([byte[]]::new(65537))
    $atLimit = [Convert]::ToBase64String([byte[]]::new(65536))
    foreach ($bad in @('', '   ', '%pdfxchangekeyfile%', 'not base64!', '====', $tooBig)) {
        Reset-KeyCase
        $code = Invoke-KeyCase -KeyFileText $bad
        if ($code -ne 1 -or $script:Downloads -ne 0 -or $script:Started.Count -ne 0) {
            Fail "a bad KeyFile (length $($bad.Length)) was accepted: exit $code"
        }
    }
    if ($null -eq (Get-PdfXchangeKeyFileBytes -Text $atLimit)) {
        Fail 'a 64 KB KeyFile was refused'
    }
    $wrapped = $vaultBase64.Substring(0, 20) + "`r`n" + $vaultBase64.Substring(20)
    $decoded = Get-PdfXchangeKeyFileBytes -Text $wrapped
    if ($null -eq $decoded -or [Convert]::ToBase64String($decoded) -cne $vaultBase64) {
        Fail 'a line-wrapped base64 KeyFile was not decoded'
    }

    # The secrets are read once and removed from the environment, so msiexec and XCVault
    # do not inherit them.
    $env:PdfXchangeKeyFile = $vaultBase64
    $env:PdfXchangeKeyData = $fakeKey
    $readFile = Pop-PdfXchangeEnvironmentSecret -Name 'PdfXchangeKeyFile'
    $readData = Pop-PdfXchangeEnvironmentSecret -Name 'PdfXchangeKeyData'
    if ($readFile -cne $vaultBase64 -or $readData -cne $fakeKey) {
        Fail 'the environment secrets were not read back'
    }
    if ($null -ne $env:PdfXchangeKeyFile -or $null -ne $env:PdfXchangeKeyData) {
        Fail 'a licence variable was left in the process environment'
    }
} finally {
    Remove-Item -LiteralPath 'Env:PdfXchangeKeyFile', 'Env:PdfXchangeKeyData' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'pdf-xchange-key-file tests passed'
exit 0
