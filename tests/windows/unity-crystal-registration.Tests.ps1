$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $PSScriptRoot '../../windows/packages/unity/Invoke-UnityCrystalRegistration.ps1')
function Assert($b,$m){if(-not $b){throw $m}}
function Reject([scriptblock]$b){try{& $b;throw 'DID NOT REJECT'}catch{if($_.Exception.Message -eq 'DID NOT REJECT'){throw}}}
# Azure AD SID is intentionally not S-1-5-21; exact identity, not prefix, binds the hive.
$ctx=[pscustomobject]@{Account='DOMAIN\example';Sid='S-1-12-1-1-2-3-4';Loaded=$true;Special=$false;ProfileCount=1;HiveLoaded=$true}
Assert-CrContext $ctx 'S-1-12-1-1-2-3-4' 'DOMAIN\example'
Reject {Assert-CrContext $ctx 'S-1-12-1-1-2-3-5' 'DOMAIN\example'}
Reject {Assert-CrContext $ctx $ctx.Sid 'DOMAIN\other'}
foreach($field in @('Loaded','HiveLoaded')){$ctx.$field=$false;Reject {Assert-CrContext $ctx $ctx.Sid $ctx.Account};$ctx.$field=$true}
$ctx.Special=$true;Reject {Assert-CrContext $ctx $ctx.Sid $ctx.Account};$ctx.Special=$false
$ctx.ProfileCount=2;Reject {Assert-CrContext $ctx $ctx.Sid $ctx.Account};$ctx.ProfileCount=1
$r=[pscustomobject]@{Root='1';Key='SOFTWARE\SAP BusinessObjects\Crystal Reports for .NET Framework 4.0\Installer';Name='BusinessObjects';Value='1';Component='Registry.C42BE088.E7B6.472F.8D7A.6E4578DB48FF'}
Assert-CrRow $r
foreach($field in @('Root','Key','Name','Value','Component')){$old=$r.$field;$r.$field='wrong';Reject {Assert-CrRow $r};$r.$field=$old}
$r.Value='#1';Reject {Assert-CrRow $r};$r.Value='[PROPERTY]';Reject {Assert-CrRow $r};$r.Value='1'
Assert ((Get-CrDecision @([pscustomobject]@{View='Registry32';Present=$false;Kind=$null;Value=$null},[pscustomobject]@{View='Registry64';Present=$false;Kind=$null;Value=$null})) -eq 'create') 'absent row may be created'
$states=@([pscustomobject]@{View='Registry32';Present=$true;Kind='String';Value='1'},[pscustomobject]@{View='Registry64';Present=$true;Kind='String';Value='1'})
Assert ((Get-CrDecision $states) -eq 'compliant') 'correct registration is no-op'
$states[0].Kind='DWord';Reject {Get-CrDecision $states};$states[0].Kind='String'
$states[0].Value='other';Reject {Get-CrDecision $states};$states[0].Value='1'
Reject {Get-CrDecision @($states[0])}
$states[1].Present=$false;Reject {Get-CrDecision $states};$states[1].Present=$true

Write-Output 'PASS exact user mapping, vendor row/type, absent-only/no-overwrite guards'

# Releasing one native object must not prevent releasing the rest or removing the MSI.
$script:released=[Collections.Generic.List[string]]::new()
$script:CrReleaseComObject={param($Object) $script:released.Add([string]$Object);if($Object -eq 'bad-db'){throw 'release failed'}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('unity-test-'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($temp)
$staged=Join-Path $temp 'source.msi';[IO.File]::WriteAllText($staged,'test')
$backup=Join-Path $temp 'registration-backup.json';[IO.File]::WriteAllText($backup,'retained')
try {
    Close-CrResources -Database 'bad-db' -Installer 'installer' -Source $staged -Work $temp
    Assert (($script:released -join ',') -ceq 'bad-db,installer') 'COM release proceeds despite an earlier release error'
    Assert (-not (Test-Path -LiteralPath $staged) -and (Test-Path -LiteralPath $backup)) 'staging is removed but ownership backup is retained'
    Remove-Item -LiteralPath $backup
    Close-CrResources -Source '' -Work $temp
    Assert (-not (Test-Path -LiteralPath $temp)) 'empty report staging directory is removed'
} finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
# The MSI reader closes/releases its view and fetched record on column-read failure.
$script:released.Clear()
$record=[pscustomobject]@{Tag='record'}
$record|Add-Member ScriptMethod StringData {param($index) throw 'column read failed'}
$view=[pscustomobject]@{Tag='view';Closed=$false;Record=$record}
$view|Add-Member ScriptMethod Execute {}
$view|Add-Member ScriptMethod Fetch {return $this.Record}
$view|Add-Member ScriptMethod Close {$this.Closed=$true}
$db=[pscustomobject]@{View=$view}
$db|Add-Member ScriptMethod OpenView {param($query) return $this.View}
$script:CrReleaseComObject={param($Object) $script:released.Add($Object.Tag)}
Reject {Read-CrRows $db 'SELECT something' @('Field')}
Assert ($view.Closed -and ($script:released -join ',') -ceq 'record,view') 'MSI record and view released on read failure'
Write-Output 'PASS MSI COM and staging cleanup on failure; backup retained'

# Unsupported operations and an empty pin cannot even inspect the live Windows host.
$script:contextCalls=0
function Get-CrContext { $script:contextCalls++; return $ctx }
Assert ((Invoke-CrRegistration -PinVersion '').Status -ceq 'disabled') 'empty pin disables report and apply'
Reject {Invoke-CrRegistration -DeploymentType Uninstall -Action Install -PinVersion '1.0.0'}
Reject {Invoke-CrRegistration -Action Uninstall -PinVersion '1.0.0'}
Reject {Invoke-CrRegistration -Action Install -PinVersion '2.0.0'}
Assert ($script:contextCalls -eq 0) 'invalid invocation must stop before inspecting host'
Write-Output 'PASS package invocation guards'
