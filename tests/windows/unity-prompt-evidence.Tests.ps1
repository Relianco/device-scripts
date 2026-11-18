$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $PSScriptRoot '../../windows/packages/unity/Get-UnityPromptEvidence.ps1')
function Assert($ok,$message){if(-not $ok){throw "FAIL $message"}}
$sid='S-1-5-21-111-222-333-1001'
$account='EXAMPLE\User'
$fixtureProfile=Join-Path ([IO.Path]::GetTempPath()) ('unity-evidence-'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($fixtureProfile)
try {
$script:ReadCount=0
$script:Context=[pscustomobject]@{Account=$account;Sid=$sid;ProfileCount=1;Loaded=$true;Special=$false;HiveLoaded=$true;Profile=$fixtureProfile}
$script:UnityContext={param($ExpectedSid) $script:Context}
$script:UnityLogEvidence={ $script:ReadCount++; [ordered]@{LogExists=$false;SourceExists=$true;RegisteredLog='Application';ExpectedLog='UnityAccounting';BindingMatches=$false} }
$script:UnityUserEvidence={param($Sid) $script:ReadCount++; @([ordered]@{View='Registry32';KeyExists=$false;ValueExists=$false;Kind=$null;Value=$null},[ordered]@{View='Registry64';KeyExists=$true;ValueExists=$true;Kind='String';Value='1'})}
$script:UnityRuntimeEvidence={ $script:ReadCount++; [ordered]@{Products=@();GacAssemblies=@();Truncated=$false} }
function Run {Invoke-UnityPromptEvidence -PinVersion '1' -Action Install -ExpectedSid $sid -ExpectedAccount $account @args}
$r=Run
Assert ($r.ExitCode -eq 0 -and $r.Report.Status -eq 'evidence') 'read-only evidence succeeds'
Assert (-not $r.Report.EventLog.LogExists -and $r.Report.EventLog.RegisteredLog -eq 'Application' -and -not $r.Report.EventLog.BindingMatches) 'source existence does not satisfy missing required log'
Assert ($r.Report.UserRegistration.Count -eq 2 -and -not $r.Report.UserRegistration[0].KeyExists -and $r.Report.UserRegistration[1].Kind -eq 'String' -and $r.Report.UserRegistration[1].Value -ceq '1') 'both-view exact row retains type and value'
foreach($field in 'Account','Sid','ProfileCount','Loaded','Special','HiveLoaded','Profile'){
 $saved=$script:Context.$field
 $script:Context.$field=switch($field){'Account'{'EXAMPLE\Other'};'Sid'{'S-1-5-21-111-222-333-1002'};'ProfileCount'{2};'Loaded'{$false};'Special'{$true};'HiveLoaded'{$false};'Profile'{''}}
 $script:ReadCount=0;$r=Run
 Assert ($r.ExitCode -eq 1 -and $script:ReadCount -eq 0) "unsafe target $field refuses all probes"
 $script:Context.$field=$saved
}
$script:ReadCount=0
$r=Invoke-UnityPromptEvidence -Action Install -ExpectedSid $sid -ExpectedAccount $account
Assert ($r.ExitCode -eq 0 -and $r.Report.Status -eq 'disabled' -and $script:ReadCount -eq 0) 'empty pin is disabled'
foreach($bad in @('',"$sid' OR true",'S-1-5-18')){
 $r=Invoke-UnityPromptEvidence -PinVersion 1 -Action Install -ExpectedSid $bad -ExpectedAccount $account
 Assert ($r.ExitCode -eq 1 -and $script:ReadCount -eq 0) 'invalid or system SID rejected before reads'
}
$r=Invoke-UnityPromptEvidence -PinVersion 1 -Action Uninstall -ExpectedSid $sid -ExpectedAccount $account
Assert ($r.ExitCode -eq 1 -and $script:ReadCount -eq 0) 'unsupported action refused'
$script:UnityLogEvidence={throw 'synthetic read failure'}
$r=Run
Assert ($r.ExitCode -eq 1 -and $r.Report.Status -eq 'partial' -and $r.Report.Errors.Count -eq 1 -and $r.Report.UserRegistration.Count -eq 2) 'read failure is partial, not absent, and independent evidence survives'
$json=ConvertTo-UnityEvidenceJson -Report $r.Report
Assert ($json.Length -gt 0 -and $null -ne (ConvertFrom-Json $json) -and $json -notmatch "`n") 'single-line parseable JSON'
$big=[ordered]@{Status='evidence';Runtime=@{GacAssemblies=@(('x'*10000))}}
$json=ConvertTo-UnityEvidenceJson $big
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and $json -match 'outputTooLarge') 'oversized evidence fails explicitly within transport bound'
Write-Output 'unity-prompt-evidence tests passed'
} finally {
    Remove-Item -LiteralPath $fixtureProfile -Recurse -Force
}
