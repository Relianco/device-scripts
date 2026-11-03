$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert($Condition,$Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $root 'windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1')
$script:sensitive=[guid]::NewGuid().ToString('n')
$script:volume=[pscustomobject]@{ConversionStatus=1;ProtectionStatus=1;VolumeType=0;KeyProtector=$script:sensitive}
$script:volume | Add-Member -NotePropertyName ('Recovery' + 'Password') -NotePropertyValue $script:sensitive
$script:queryFails=$false
$script:lockFails=$false
$script:lockResult=[pscustomobject]@{ReturnValue=0;LockStatus=0;KeyProtector=$script:sensitive}
$script:methods=[Collections.Generic.List[string]]::new()
function Get-CimInstance {
    param($ClassName,$Namespace,$Filter,$Property,$OperationTimeoutSec,$ErrorAction)
    Assert ($ClassName -eq 'Win32_EncryptableVolume') 'only encryptable volume provider'
    Assert ($Namespace -eq 'root\CIMV2\Security\MicrosoftVolumeEncryption') 'BitLocker namespace'
    Assert (($Property -join ',') -eq 'ConversionStatus,ProtectionStatus,VolumeType') 'only status properties requested'
    Assert ($Filter -eq "DriveLetter='C:'") 'system volume only'
    Assert ($OperationTimeoutSec -eq 5) 'bounded volume query'
    if ($script:queryFails) { throw [UnauthorizedAccessException]::new($script:sensitive) }
    $script:volume
}
function Invoke-CimMethod {
    param($InputObject,$MethodName,$OperationTimeoutSec,$ErrorAction)
    Assert ($MethodName -eq 'GetLockStatus') 'only read-only lock getter permitted'
    Assert ($OperationTimeoutSec -eq 5) 'bounded lock query'
    $script:methods.Add($MethodName)
    if ($script:lockFails) { throw [UnauthorizedAccessException]::new($script:sensitive) }
    $script:lockResult
}
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.encryptionStatus -eq 'FullyEncrypted' -and $r.protectionStatus -eq 'On' -and $r.lockStatus -eq 'Unlocked' -and $r.volumeType -eq 'OperatingSystem') 'encrypted protected system volume'
Assert (($r.Keys -join ',') -eq 'encryptionStatus,protectionStatus,lockStatus,volumeType') 'strict status output allowlist'
Assert (($r | ConvertTo-Json -Compress) -notmatch [regex]::Escape($script:sensitive)) 'secret-bearing provider properties excluded'
$script:volume.ConversionStatus=0;$script:volume.ProtectionStatus=0;$script:lockResult.LockStatus=1
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.encryptionStatus -eq 'FullyDecrypted' -and $r.protectionStatus -eq 'Off' -and $r.lockStatus -eq 'Locked') 'explicit decrypted/off/locked mapping'
$script:volume.ConversionStatus=4;$script:volume.ProtectionStatus=2;$script:lockResult.ReturnValue=1
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.encryptionStatus -eq 'EncryptionPaused' -and $r.protectionStatus -eq 'Unknown' -and $r.lockStatus -eq 'Unknown') 'paused and unsuccessful lock result are not healthy defaults'
$script:volume.ConversionStatus=$null;$script:volume.ProtectionStatus=99;$script:volume.VolumeType=99;$script:lockFails=$true
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.encryptionStatus -eq 'Unknown' -and $r.protectionStatus -eq 'Unknown' -and $r.lockStatus -eq 'Unknown' -and $r.volumeType -eq 'Unknown') 'missing/unknown/denied values remain unknown'
Assert (($r | ConvertTo-Json -Compress) -notmatch [regex]::Escape($script:sensitive)) 'lock error does not expose exception message'
$script:volume=$null
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.status -eq 'unavailable') 'absent volume is unavailable'
$script:queryFails=$true
$r=Read-DiagnosticBitLocker -SystemDrive 'C:'
Assert ($r.status -eq 'unavailable' -and ($r | ConvertTo-Json -Compress) -notmatch [regex]::Escape($script:sensitive)) 'provider access failure sanitized'
Write-Output 'diagnostic-bitlocker tests passed'
