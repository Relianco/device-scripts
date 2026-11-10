<#
.SYNOPSIS
Read-only evidence for Unity/esiLaw event-log and Crystal prerequisite prompts.
.DESCRIPTION
Run through Invoke-RelianRunner as SYSTEM with Action Install and a nonempty pin.
ExpectedSid and ExpectedAccount must identify the current console user and exactly
one loaded ordinary profile. No username guessing, hive loading, installations,
registry writes, application launches, or assembly execution occur.

Reports the UnityAccounting LOG and source binding separately, the exact HKCU
BusinessObjects row in both registry views, the known Crystal 13.0.24 product,
and up to eight engine assemblies in the two standard GAC roots. This is evidence,
not proof of a prompt-free launch. Other runtime versions can require different
checks. Use the msi-repair package's Section Evidence for installer event history.

Output is one JSON line, at most 8000 UTF-8 bytes. Exit 1 on rejected targets or
incomplete reads; an empty PinVersion disables all reads and exits 0.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType='', [string]$Action='', [string]$PinVersion='',
    [string]$ExpectedSid='', [string]$ExpectedAccount=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:UnityProductCode='{817393F4-AAE9-4217-B3BF-C94D79D20F6B}'
$script:UnityUserKey='SOFTWARE\SAP BusinessObjects\Crystal Reports for .NET Framework 4.0\Installer'

$script:UnityContext={
    param($ExpectedSid)
    $account=[string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if([string]::IsNullOrWhiteSpace($account)){throw 'No console account'}
    $sid=(New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profiles=@(Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSid'" -ErrorAction Stop)
    if($profiles.Count -ne 1){throw 'Profile mapping is not unique'}
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Registry64)
    try{$hive=$base.OpenSubKey($ExpectedSid);$loaded=$null -ne $hive;if($hive){$hive.Dispose()}}finally{$base.Dispose()}
    [pscustomobject]@{Account=$account;Sid=$sid;ProfileCount=$profiles.Count;Loaded=[bool]$profiles[0].Loaded;Special=[bool]$profiles[0].Special;HiveLoaded=$loaded;Profile=[string]$profiles[0].LocalPath}
}
$script:UnityLogEvidence={
    $exists=[Diagnostics.EventLog]::SourceExists('UnityAccounting')
    $binding=if($exists){[Diagnostics.EventLog]::LogNameFromSourceName('UnityAccounting','.')}else{$null}
    [ordered]@{ExpectedLog='UnityAccounting';LogExists=[Diagnostics.EventLog]::Exists('UnityAccounting');SourceExists=$exists;RegisteredLog=$binding;BindingMatches=($exists -and $binding -ieq 'UnityAccounting')}
}
$script:UnityUserEvidence={
    param($Sid)
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,$view)
        try{
            $hive=$base.OpenSubKey($Sid)
            if($null -eq $hive){throw 'Target user hive is no longer loaded'}
            $hive.Dispose()
            $key=$base.OpenSubKey($Sid+'\'+$script:UnityUserKey)
            $row=[ordered]@{View=[string]$view;KeyExists=($null -ne $key);ValueExists=$false;Kind=$null;Value=$null;ExpectedKind='String';ExpectedValue='1';Matches=$false}
            if($null -ne $key){
                try{
                    if($key.GetValueNames() -contains 'BusinessObjects'){
                        $row.ValueExists=$true;$row.Kind=[string]$key.GetValueKind('BusinessObjects')
                        # Only the expected string is needed; arbitrary binary/multi-string data is not exported.
                        if($row.Kind -eq 'String'){
                            $value=[string]$key.GetValue('BusinessObjects',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                            $row.Matches=$value -ceq '1';$row.Value=if($value.Length -le 64){$value}else{'[value longer than 64 characters]'}
                        }
                    }
                }finally{$key.Dispose()}
            }
            $row
        }finally{$base.Dispose()}
    }
}
$script:UnityRuntimeEvidence={
    $products=@(foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try{
            $key=$base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$script:UnityProductCode)
            $row=[ordered]@{View=[string]$view;ProductCode=$script:UnityProductCode;Present=($null -ne $key);Name=$null;Version=$null}
            if($key){try{foreach($pair in @(@('Name','DisplayName'),@('Version','DisplayVersion'))){$text=[string]$key.GetValue($pair[1]);$row[$pair[0]]=$text.Substring(0,[Math]::Min(160,$text.Length))}}finally{$key.Dispose()}}
            $row
        }finally{$base.Dispose()}
    })
    $assemblies=[System.Collections.Generic.List[object]]::new();$truncated=$false
    foreach($relative in @('assembly\GAC_MSIL\CrystalDecisions.CrystalReports.Engine','Microsoft.NET\assembly\GAC_MSIL\CrystalDecisions.CrystalReports.Engine')){
        $root=Join-Path $env:windir $relative
        if(-not [IO.Directory]::Exists($root)){continue}
        # No recursive walk: inspect at most four version directories per standard GAC root.
        if((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'GAC root is a reparse point'}
        $dirs=@(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Select-Object -First 5)
        if($dirs.Count -gt 4){$truncated=$true}
        foreach($dir in @($dirs|Select-Object -First 4)){
            if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'GAC version directory is a reparse point'}
            $path=Join-Path $dir.FullName 'CrystalDecisions.CrystalReports.Engine.dll'
            if(-not [IO.File]::Exists($path)){continue}
            if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'GAC assembly is a reparse point'}
            $name=[Reflection.AssemblyName]::GetAssemblyName($path)
            $assemblies.Add([ordered]@{Name=$name.Name;Version=[string]$name.Version;GacRoot=$relative})
        }
    }
    [ordered]@{Products=$products;GacAssemblies=$assemblies.ToArray();Truncated=$truncated;Note='Product registration and GAC metadata do not prove the application can load the runtime.'}
}

function Invoke-UnityPromptEvidence {
    param([string]$PinVersion='', [string]$Action='', [string]$ExpectedSid='', [string]$ExpectedAccount='', [string]$DeploymentType='')
    $report=[ordered]@{Package='unity-prompt-evidence';Status='error';Errors=@()}
    if([string]::IsNullOrWhiteSpace($PinVersion)){$report.Status='disabled';return @{ExitCode=0;Report=$report}}
    if($Action -ne 'Install' -or $DeploymentType -notin @('','Install') -or $ExpectedSid -cnotmatch '\AS-1-(?:5-21(?:-[0-9]+){4}|12-1(?:-[0-9]+){4})\z' -or $ExpectedSid.Length -gt 100 -or [string]::IsNullOrWhiteSpace($ExpectedAccount) -or $ExpectedAccount.Length -gt 256){
        $report.Errors=@('Install requires an explicit ordinary-user ExpectedSid and ExpectedAccount.');return @{ExitCode=1;Report=$report}
    }
    try{
        $context=& $script:UnityContext $ExpectedSid
        if($context.Sid -cne $ExpectedSid -or $context.Account -ine $ExpectedAccount -or $context.ProfileCount -ne 1 -or -not $context.Loaded -or $context.Special -or -not $context.HiveLoaded -or [string]::IsNullOrWhiteSpace($context.Profile)){
            throw 'Target identity mismatch'
        }
        $report.Target=[ordered]@{Sid=$context.Sid;Account=$context.Account;Profile=$context.Profile}
    }catch{$report.Errors=@('Expected console account and exact loaded ordinary profile/hive could not be verified.');return @{ExitCode=1;Report=$report}}
    foreach($section in @('EventLog','UserRegistration','Runtime')){
        try{
            switch($section){
                'EventLog' {$report[$section]=& $script:UnityLogEvidence}
                'UserRegistration' {$report[$section]=@(& $script:UnityUserEvidence $ExpectedSid)}
                'Runtime' {$report[$section]=& $script:UnityRuntimeEvidence}
            }
        }catch{$report[$section]=$null;$report.Errors+=($section+': read failed ('+$_.Exception.GetType().Name+').')}
    }
    $report.Status=if($report.Errors.Count){'partial'}else{'evidence'}
    return @{ExitCode=if($report.Errors.Count){1}else{0};Report=$report}
}
function ConvertTo-UnityEvidenceJson {
    param($Report)
    $json=ConvertTo-Json -InputObject $Report -Depth 6 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8000){return '{"Package":"unity-prompt-evidence","Status":"error","Errors":["outputTooLarge"]}'}
    return $json
}
if($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.'){return}
try{$run=Invoke-UnityPromptEvidence -PinVersion $PinVersion -Action $Action -DeploymentType $DeploymentType -ExpectedSid $ExpectedSid -ExpectedAccount $ExpectedAccount}
catch{$run=@{ExitCode=1;Report=[ordered]@{Package='unity-prompt-evidence';Status='error';Errors=@('Evidence collection failed.')}}}
$json=ConvertTo-UnityEvidenceJson $run.Report
Write-Output $json
if($json -match '"outputTooLarge"'){exit 1}
exit $run.ExitCode
