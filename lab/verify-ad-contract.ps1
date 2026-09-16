# Disposable VM9111 AD contract verification; refuses any other machine or source revision.
# Invoked by NinjaOne Bootstrap352; does not alter the shared bootstrap or existing script entries.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ne 'RELIAN-AD-LAB'){throw 'Wrong guest'}
if((Get-CimInstance Win32_ComputerSystemProduct).UUID -ine '14979622-e4e7-4709-b203-4998f53a3613'){throw 'Wrong lab VM identity'}
if((Get-FileHash 'C:\Lab\Scripts\Edit-ADUser.ps1' -Algorithm SHA256).Hash -ne 'E138152ABE619DE48BADD5C20E302B6AF36D33C90DFF6F1BFD600C88E1119AE6'){throw 'Unexpected Edit-ADUser.ps1 source hash'}
if((Get-FileHash 'C:\Lab\Scripts\Offboard-ADUser.ps1' -Algorithm SHA256).Hash -ne '6FD6270FBE7D04E11676C145DF27F38851CBA2F959F9D8966EC90EA7A61CF79A'){throw 'Unexpected Offboard-ADUser.ps1 source hash'}

Import-Module ActiveDirectory
$domain=Get-ADDomain -Server ad-lab.test
if($domain.DNSRoot -ne 'ad-lab.test'){throw 'Wrong directory'}
$dc=$domain.PDCEmulator;$base=$domain.DistinguishedName
foreach($item in @(@('Managed',$base),@('Child',"OU=Managed,$base"),@('Outside',$base))){
 $dn="OU=$($item[0]),$($item[1])"
 if(-not(Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -Server $dc)){New-ADOrganizationalUnit -Name $item[0] -Path $item[1] -Server $dc}
}
$results=@()
foreach($operation in @('edit','offboard','disable')){
 foreach($scope in @('root','child','outside','missing')){
  $name="rmm1-$operation-$scope"
  $upn="$name@ad-lab.test"
  $path=switch($scope){'child'{"OU=Child,OU=Managed,$base"};'outside'{"OU=Outside,$base"};default{"OU=Managed,$base"}}
  $before=$null
  if($scope -ne 'missing'){
   $password=ConvertTo-SecureString ([guid]::NewGuid().ToString()+'!aA1') -AsPlainText -Force
   New-ADUser -Name $name -SamAccountName ($name.Replace('offboard','off').Substring(0,[Math]::Min(20,$name.Replace('offboard','off').Length))) -UserPrincipalName "$name@ad-lab.test" -Path $path -DisplayName 'Before' -Enabled $true -AccountPassword $password -Server $dc
   $before=Get-ADUser -Filter {UserPrincipalName -eq $upn} -Server $dc -Properties DisplayName,GivenName,Surname,employeeType,pager,info,whenChanged,uSNChanged
  }
  if($scope -ne 'missing' -and $null -eq $before){throw "Missing baseline $upn"}
  $payload=@{upn="$name@ad-lab.test";domain='ad-lab.test';userOu="OU=Managed,$base"}
  if($operation -eq 'edit'){$payload.displayName='After';$payload.givenName='Lab';$payload.surname='Verified';$payload.employeeType='Staff';$payload.pager='123';$payload.notes='Lab contract';$script='Edit-ADUser.ps1'}else{$script='Offboard-ADUser.ps1';$payload.offboardingOptions=@{DeleteUser=($operation -eq 'offboard');DisableSignIn=($operation -eq 'disable')}}
  $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Compress)))
  $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ("C:\Lab\Scripts\"+$script) -userDataJson $encoded 2>&1
  $code=$LASTEXITCODE
  $after=Get-ADUser -Filter {UserPrincipalName -eq $upn} -Server $dc -Properties DisplayName,GivenName,Surname,employeeType,pager,info,whenChanged,uSNChanged
  $allowed=$scope -in @('root','child')
  if($allowed){
   $passed=$code -eq 0
   if($operation -eq 'edit'){$passed=$passed -and $after.DisplayName -eq 'After' -and $after.GivenName -eq 'Lab' -and $after.Surname -eq 'Verified' -and $after.employeeType -eq 'Staff' -and $after.pager -eq '123' -and $after.info -eq 'Lab contract'}
   if($operation -eq 'offboard'){$passed=$passed -and $null -eq $after}
   if($operation -eq 'disable'){$passed=$passed -and $after.Enabled -eq $false}
  }else{
   $passed=$code -ne 0
   if($scope -eq 'outside'){$passed=$passed -and $null -ne $after -and $before.uSNChanged -eq $after.uSNChanged -and $after.Enabled -and $after.DisplayName -eq 'Before'}else{$passed=$passed -and $null -eq $after}
  }
  $results+=[pscustomobject]@{operation=$operation;scope=$scope;passed=[bool]$passed;exitCode=$code;beforeUSN=$before.uSNChanged;afterUSN=$after.uSNChanged;output=($output -join "`n")}
 }
}
$receipt=[pscustomobject]@{at=[DateTime]::UtcNow.ToString('o');hostname=$env:COMPUTERNAME;executionIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;domain=$domain.DNSRoot;server=$dc;scriptHashes=@(Get-FileHash C:\Lab\Scripts\*.ps1 -Algorithm SHA256|Select-Object Path,Hash);tests=$results}
$receipt|ConvertTo-Json -Depth 6|Set-Content C:\Lab\rmm-ad-results.json
$receipt|ConvertTo-Json -Depth 6
if(@($results|Where-Object {-not $_.passed}).Count){exit 1}
