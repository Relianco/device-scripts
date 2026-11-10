# Restore one literal vendor-authored HKCU registry value. Never runs an installer.
[CmdletBinding()]
param([string]$DeploymentType='Install',[string]$Action='Install',[string]$PinVersion='',[string]$ExpectedSid='',[string]$ExpectedAccount='',[string]$Mode='Report')
$ErrorActionPreference='Stop'
$script:CrKey='SOFTWARE\SAP BusinessObjects\Crystal Reports for .NET Framework 4.0\Installer'
$script:CrProduct='{817393F4-AAE9-4217-B3BF-C94D79D20F6B}'
function Assert-CrContext($Context,[string]$Sid,[string]$Account){
 if($Sid -cnotmatch '\AS-\d+(?:-\d+){2,}\z' -or [string]::IsNullOrWhiteSpace($Account) -or $Context.Sid -cne $Sid -or $Context.Account -ine $Account -or $Context.ProfileCount -ne 1 -or -not $Context.Loaded -or $Context.Special -or -not $Context.HiveLoaded){throw 'Expected console user and loaded profile/hive do not match'}
}
function Assert-CrRow($Row){
 if($Row.Root -cne '1' -or $Row.Key -cne $script:CrKey -or $Row.Name -cne 'BusinessObjects' -or $Row.Value -cne '1' -or $Row.Component -cne 'Registry.C42BE088.E7B6.472F.8D7A.6E4578DB48FF'){throw 'Vendor registry row differs from reviewed literal REG_SZ registration'}
}
function Get-CrDecision($States){
 if(@($States).Count -ne 2 -or @($States|Where-Object View -eq Registry32).Count -ne 1 -or @($States|Where-Object View -eq Registry64).Count -ne 1){throw 'Both registry views must be known'}
 foreach($s in $States){if($s.Present -and ($s.Kind -cne 'String' -or $s.Value -isnot [string] -or $s.Value -cne '1')){throw 'Existing value differs; refusing overwrite'}}
 $presentCount=@($States|Where-Object Present).Count
 if($presentCount -eq 2){return 'compliant'}
 if($presentCount -ne 0){throw 'Registry views disagree; refusing change'}
 return 'create'
}
function Get-CrContext {
 $account=[string](Get-CimInstance Win32_ComputerSystem).UserName
 if([string]::IsNullOrWhiteSpace($account)){throw 'No console user'}
 $sid=([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
 $profiles=@(Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid)
 if($profiles.Count -ne 1){throw 'Profile mapping is ambiguous'}
 $h=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Registry32)
 try{$k=$h.OpenSubKey($sid);$loaded=$null -ne $k;if($k){$k.Dispose()}}finally{$h.Dispose()}
 [pscustomobject]@{Account=$account;Sid=$sid;Profile=$profiles[0].LocalPath;ProfileCount=$profiles.Count;Loaded=[bool]$profiles[0].Loaded;Special=[bool]$profiles[0].Special;HiveLoaded=$loaded}
}
function Get-CrTarget([string]$Sid){
 foreach($view in @('Registry32','Registry64')){
  $h=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::$view)
  try{
   $k=$h.OpenSubKey($Sid+'\'+$script:CrKey)
   try{$present=$null -ne $k -and @($k.GetValueNames()) -contains 'BusinessObjects';$kind=$null;$value=$null
    if($present){$kind=[string]$k.GetValueKind('BusinessObjects');$value=$k.GetValue('BusinessObjects',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    [pscustomobject]@{View=$view;KeyExists=($null -ne $k);Present=$present;Kind=$kind;Value=$value}
   }finally{if($k){$k.Dispose()}}
  }finally{$h.Dispose()}
 }
}
# Native objects are kept behind a seam so failure cleanup is tested offline.
$script:CrReleaseComObject = {
    param($Object)
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
    }
}
function Close-CrComObject($Object) {
    if ($null -ne $Object) {
        try { & $script:CrReleaseComObject $Object }
        catch { Write-Warning 'A Windows Installer object could not be released.' }
    }
}
function Close-CrResources {
    param($Database, $Installer, [string]$Source = '', [string]$Work = '')
    Close-CrComObject $Database
    Close-CrComObject $Installer
    if ($Source -and (Test-Path -LiteralPath $Source)) {
        try { Remove-Item -LiteralPath $Source -Force -ErrorAction Stop }
        catch { Write-Warning 'Staged MSI cleanup deferred; registry backup retained.' }
    }
    # Never recurse here: an Apply backup must survive success and partial failure.
    if ($Work -and (Test-Path -LiteralPath $Work)) {
        try {
            if (@(Get-ChildItem -LiteralPath $Work -Force -ErrorAction Stop).Count -eq 0) {
                [IO.Directory]::Delete($Work, $false)
            }
        } catch { Write-Warning 'Staging directory cleanup deferred.' }
    }
}
function Read-CrRows {
    param($Database, [string]$Query, [string[]]$Columns)
    $view = $Database.OpenView($Query)
    try {
        [void]$view.Execute()
        while ($record = $view.Fetch()) {
            try {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $Columns.Count; $i++) {
                    $row[$Columns[$i]] = $record.StringData($i + 1)
                }
                [pscustomobject]$row
            } finally { Close-CrComObject $record }
        }
    } finally {
        try { [void]$view.Close() }
        catch { Write-Warning 'A Windows Installer view could not be closed.' }
        Close-CrComObject $view
    }
}
function Invoke-CrRegistration {
    param(
        [string]$DeploymentType = 'Install',
        [string]$Action = 'Install',
        [string]$PinVersion = '',
        [string]$ExpectedSid = '',
        [string]$ExpectedAccount = '',
        [string]$Mode = 'Report'
    )
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return [ordered]@{ Package = 'unity-crystal-registration'; Status = 'disabled' }
    }
    if ($DeploymentType -ne 'Install' -or $Mode -notin @('Report', 'Apply') -or $Action -ne 'Install' -or $PinVersion -ne '1.0.0') {
        throw 'Unsupported invocation'
    }
    $db = $null; $installer = $null; $source = ''; $work = ''
    try {
        $ctx=Get-CrContext;Assert-CrContext $ctx $ExpectedSid $ExpectedAccount
        # Stage under SYSTEM's restricted temp directory; validate the staged bytes, never execute them.
        $work=Join-Path (Join-Path $env:windir 'SystemTemp') ('cr-user-registration-'+[guid]::NewGuid().ToString('n'))
        [void](New-Item -ItemType Directory -Path $work)
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($identity in @('S-1-5-18','S-1-5-32-544')){$rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($identity)),'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule)}
        Set-Acl -LiteralPath $work -AclObject $acl
        $backAcl=Get-Acl -LiteralPath $work
        if(-not $backAcl.AreAccessRulesProtected){throw 'Backup directory inheritance not protected'}
        foreach($rule in $backAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
         if($rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -or $rule.AccessControlType -ne 'Allow'){throw 'Unexpected backup directory permission'}
        }
        $source=Join-Path $work 'source.msi'
        Copy-Item -LiteralPath (Join-Path $ctx.Profile 'AppData\Local\esiLaw\CR_RT_32b_13024.msi') -Destination $source
        if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne '116283c08b3d6693e7d91b8d1165e373f67dffcb2945189642f2195428bc2ecd'){throw 'MSI hash differs'}
        $sig=Get-AuthenticodeSignature -LiteralPath $source
        if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=SAP SE(?:,|$)'){throw 'MSI signature differs'}
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $db=$installer.OpenDatabase($source,0)
        $rows=@(Read-CrRows $db 'SELECT `Root`, `Key`, `Name`, `Value`, `Component_` FROM `Registry` WHERE `Registry`=''crystalreports.cpp.share.registry_4.0_core_32.Registry109''' @('Root','Key','Name','Value','Component'))
        if($rows.Count -ne 1){throw 'Vendor row not unique'};Assert-CrRow $rows[0]
        $properties=@(Read-CrRows $db 'SELECT `Property`, `Value` FROM `Property` WHERE `Property`=''ProductCode''' @('Name','Value'))
        if($properties.Count -ne 1 -or $properties[0].Value -cne $script:CrProduct){throw 'MSI product differs'}
        if([string]$installer.ProductInfo($script:CrProduct,'VersionString') -cne '13.0.24.2970' -or [int]$installer.FeatureState($script:CrProduct,'CRRuntime') -ne 3){throw 'Matching installed runtime feature is not local'}
        $componentPath=[string]$installer.ComponentPath($script:CrProduct,'{7B572F4C-9BF2-47C7-9B5A-50A09F0CC791}')
        if([string]::IsNullOrWhiteSpace($componentPath)){throw 'Runtime component keypath is not registered'}
        $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
        try{$key=$machine.OpenSubKey('SOFTWARE\SAP BusinessObjects\Crystal Reports for .NET Framework 4.0\Crystal Reports');try{if($null -eq $key -or [string]::IsNullOrWhiteSpace([string]$key.GetValue('Path'))){throw 'Machine runtime registry keypath is absent'}}finally{if($key){$key.Dispose()}}}finally{$machine.Dispose()}
        $before=@(Get-CrTarget $ExpectedSid);$decision=Get-CrDecision $before
        $result=[ordered]@{Package='unity-crystal-registration';Mode=$Mode;Sid=$ExpectedSid;VendorRow=$rows[0];ComponentPath=$componentPath;Before=$before;Status=$decision;Backup=$null}
        if($Mode -eq 'Apply' -and $decision -eq 'create'){
         $again=Get-CrContext;Assert-CrContext $again $ExpectedSid $ExpectedAccount
         $before=@(Get-CrTarget $ExpectedSid);if((Get-CrDecision $before) -ne 'create'){throw 'Target changed before mutation'}
         $backup=Join-Path $work 'registration-backup.json'
         $record=[ordered]@{Version=1;Utc=[datetime]::UtcNow.ToString('o');Sid=$ExpectedSid;Account=$ExpectedAccount;Key=$script:CrKey;Name='BusinessObjects';Kind='String';Value='1';Before=$before;Status='prepared';Ownership='Only the absent BusinessObjects value may be added; no existing value or application setting is changed.'}
         $json=ConvertTo-Json -InputObject $record -Depth 5
         [IO.File]::WriteAllText($backup,$json,[Text.UTF8Encoding]::new($false))
         if([IO.File]::ReadAllText($backup) -cne $json){throw 'Backup verification failed'}
         $h=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Registry32)
         try{
          $u=$h.OpenSubKey($ExpectedSid,$true);if($null -eq $u){throw 'User hive unloaded'}
          try{$k=$u.CreateSubKey($script:CrKey);try{if(@($k.GetValueNames()) -contains 'BusinessObjects'){throw 'Value appeared; refusing overwrite'};$k.SetValue('BusinessObjects',[string]$rows[0].Value,[Microsoft.Win32.RegistryValueKind]::String);$k.Flush()}finally{$k.Dispose()}}finally{$u.Dispose()}
         }finally{$h.Dispose()}
         $after=@(Get-CrTarget $ExpectedSid)
         if((Get-CrDecision $after) -ne 'compliant' -or @($after|Where-Object {$_.Present -and $_.Kind -ceq 'String' -and $_.Value -ceq '1'}).Count -ne 2){throw ('Readback failed; retain backup '+$backup)}
         $record.Status='applied';$record['After']=$after;[IO.File]::WriteAllText($backup,(ConvertTo-Json -InputObject $record -Depth 5),[Text.UTF8Encoding]::new($false))
         $result.Status='applied';$result.Backup=$backup;$result['After']=$after
        }
        return $result
    } finally {
        Close-CrResources -Database $db -Installer $installer -Source $source -Work $work
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
try {
    $report = Invoke-CrRegistration -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -ExpectedSid $ExpectedSid -ExpectedAccount $ExpectedAccount -Mode $Mode
    Write-Output (ConvertTo-Json -InputObject $report -Depth 6 -Compress)
} catch {
    Write-Output (ConvertTo-Json -InputObject ([ordered]@{ Package='unity-crystal-registration'; Status='error'; Reason=$_.Exception.Message }) -Compress)
    exit 1
}
