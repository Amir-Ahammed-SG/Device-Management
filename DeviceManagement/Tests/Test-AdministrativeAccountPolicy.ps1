
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# In-memory ADSI/account fixtures only. Never modify a real account.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
function Assert-AdminPolicy {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($file in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
 $path=Join-Path $projectRoot $file
 $tokens=$null;$errors=$null
 $ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
 Assert-AdminPolicy ($errors.Count -eq 0) 'Source does not parse.'
 $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
 . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`n"))
 function Get-LocalUser {[CmdletBinding()]param() $script:users}
 function Get-LocalAdministratorSidSet { $set=[Collections.Generic.HashSet[string]]::new();[void]$set.Add('ADMIN-SID');return ,$set }
 function Open-ThoroughLocalAccount {
  param([string]$UserName)
  $entry=[pscustomobject]@{Pending=0}
  $entry | Add-Member ScriptMethod InvokeGet {
   param($Name)
   if($Name -eq 'UserFlags'){
    if($script:unreadable -or ($script:readbackFailure -and $script:commits -gt 0)){throw 'Fixture account flags unreadable'}
    return $script:rawFlags
   }
   if($Name -in @('PasswordExpired','IsAccountLocked')){return $false}
   throw 'Unexpected ADSI read'
  }
  $entry | Add-Member ScriptMethod Put {param($Name,$Value) Assert-AdminPolicy ($Name -ceq 'UserFlags') 'Unapproved account property write.';$this.Pending=[int]$Value}
  $entry | Add-Member ScriptMethod SetInfo {
   $script:commits++
   if($script:writeFailure){throw 'Fixture denied account write'}
   if(-not $script:noEffect){$script:rawFlags=$this.Pending}
  }
  $entry | Add-Member ScriptMethod RefreshCache {param($Names)}
  return ,$entry
 }
 function New-LocalUser {throw 'Account creation forbidden'}
 function Enable-LocalUser {throw 'Account enabling forbidden'}
 function Disable-LocalUser {throw 'Account disabling forbidden'}
 function Add-LocalGroupMember {throw 'Group changes forbidden'}
 function Reset-AdminFixture {
  param([bool]$Apply=$false,[bool]$Enabled=$true,[bool]$Never=$true,[bool]$Cannot=$false)
  $script:ApplyChanges=$Apply
  $script:users=@([pscustomobject]@{Name='Administrator';Enabled=$Enabled;SID=[pscustomobject]@{Value='ADMIN-SID'}})
  $script:rawFlags=0x220
  if(-not $Enabled){$script:rawFlags=$script:rawFlags -bor 2}
  if($Never){$script:rawFlags=$script:rawFlags -bor 0x10000}
  if($Cannot){$script:rawFlags=$script:rawFlags -bor 0x40}
  $script:commits=0;$script:unreadable=$false;$script:readbackFailure=$false;$script:noEffect=$false;$script:writeFailure=$false
 }
 foreach($apply in @($false,$true)) {foreach($enabled in @($false,$true)) {foreach($never in @($false,$true)) {foreach($cannot in @($false,$true)) {
  Reset-AdminFixture $apply $enabled $never $cannot
  $before=$script:rawFlags
  $result=Get-AdministrativeAccountCheck
  $expected=if($apply -and $enabled){($before -bor 0x10000) -band (-bnot 0x40)}else{$before}
  Assert-AdminPolicy ($script:rawFlags -eq $expected) 'Administrator Apply changed an unrelated flag or Audit changed account settings.'
  Assert-AdminPolicy (($script:rawFlags -band (-bnot 0x10040)) -eq ($before -band (-bnot 0x10040))) 'An unrelated Administrator flag was changed.'
  $expectedWrites=if($apply -and $enabled -and (-not $never -or $cannot)){1}else{0}
  Assert-AdminPolicy ($script:commits -eq $expectedWrites) 'Administrator changed without a missing required flag.'
  Assert-AdminPolicy (($result.Status -eq 'Pass') -eq ((($expected -band 0x10000) -ne 0) -and ($expected -band 0x40) -eq 0)) 'Administrator compliance did not verify password changes are allowed.'
  Assert-AdminPolicy (-not $result.StateHtml.Contains('User Cannot Change Password') -and -not $result.Action.Contains('User Cannot Change Password')) 'Removed administrative requirement remains in collected state/action.'
  $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='Administrative Accounts';FoundStateHtml=$result.StateHtml})
  Assert-AdminPolicy ($view.ExpectedHtml.Contains('Password Never Expires:</span> Enabled') -and -not ($view.ExpectedHtml+$view.FindingsHtml).Contains('User Cannot Change Password')) 'Administrator report still shows the removed field.'
  [void](Get-AdministrativeAccountCheck)
  Assert-AdminPolicy ($script:commits -eq $expectedWrites) 'Repeated administrative checks rewrote compliant properties.'
 }}}}
 foreach($failure in @('unreadable','readbackFailure','noEffect','writeFailure')) {
  Reset-AdminFixture -Apply $true -Never $true -Cannot $true
  Set-Variable -Scope Script -Name $failure -Value $true
  $result=Get-AdministrativeAccountCheck
  Assert-AdminPolicy ($result.Status -eq 'Fail' -and -not $result.StateHtml.Contains('User Cannot Change Password')) ('Administrator failure was hidden or wrong fields shown: '+$failure)
 }
 Reset-AdminFixture
 $script:users=@()
 $result=Get-AdministrativeAccountCheck
 Assert-AdminPolicy ($result.Status -eq 'Fail' -and -not $result.StateHtml.Contains('User Cannot Change Password')) 'Missing administrator result still requires the removed flag.'
 Reset-AdminFixture -Never $false
 $result=Get-AdministrativeAccountCheck
 $row=[pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Shortcut='';FoundStateHtml=$result.StateHtml;Status=$result.Status;ActionTaken=$result.Action;AccountResults=$result.AccountResults}
 foreach($mode in @('Audit','Fix','Final')) {
  $snapshot=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode $mode -Hostname 'TEST-HOST'
  $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
  Assert-AdminPolicy (-not $html.Contains('User Cannot Change Password') -and $html.Contains('Password Never Expires')) ('Removed flag remains in '+$mode+' report.')
 }
 # A standard kiosk account retains both flags; an administrative shared account follows the administrator policy.
 Reset-AdminFixture -Apply $true -Never $false
 $sids=Get-LocalAdministratorSidSet
 $standard=[pscustomobject]@{Name='SELISE-KIOSK';Enabled=$true;SID=[pscustomobject]@{Value='STANDARD-SID'}}
 $kiosk=Invoke-ExistingAccountPolicy -Account $standard -AdministratorSids $sids -ReportPrivilegeOnly
 Assert-AdminPolicy ($kiosk.Status -eq 'Pass' -and ($script:rawFlags -band 0x10040) -eq 0x10040) 'Kiosk password requirements were weakened.'
 $kioskView=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$kiosk.StateHtml})
 Assert-AdminPolicy ($kioskView.ExpectedHtml.Contains('User Cannot Change Password:</span> Enabled')) 'Kiosk report lost its required flag.'
 Reset-AdminFixture -Apply $true -Never $false -Cannot $true
 $shared=Invoke-ExistingAccountPolicy -Account $script:users[0] -AdministratorSids (Get-LocalAdministratorSidSet) -ReportPrivilegeOnly
 $admin=Get-AdministrativeAccountCheck
 [void](Invoke-ExistingAccountPolicy -Account $script:users[0] -AdministratorSids (Get-LocalAdministratorSidSet) -ReportPrivilegeOnly)
 Assert-AdminPolicy ($shared.Status -eq 'Pass' -and $admin.Status -eq 'Pass' -and ($script:rawFlags -band 0x10040) -eq 0x10000 -and $script:commits -eq 1) 'Shared kiosk/administrator checks re-enabled the restriction or repeated a write.'
 $sharedView=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$shared.StateHtml})
 Assert-AdminPolicy (-not ($sharedView.ExpectedHtml+$sharedView.FindingsHtml).Contains('User Cannot Change Password')) 'Shared administrator report still requires the restriction.'
 Reset-AdminFixture -Apply $true -Never $true -Cannot $true
 $cleared=Get-AdministrativeAccountCheck
 Assert-AdminPolicy ($cleared.Status -eq 'Pass' -and $cleared.Action.Contains('Allowed password changes') -and $script:commits -eq 1) 'An existing restriction was not cleared and read back.'
 $clearRow=[pscustomobject]@{SectionNumber=4;SectionTitle='Security';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Shortcut='';FoundStateHtml=$cleared.StateHtml;Status=$cleared.Status;ActionTaken=$cleared.Action;AccountResults=$cleared.AccountResults}
 $clearSnapshot=New-ThoroughReportSnapshot -Rows @($clearRow) -DisplayMode Fix -AfterApply $true -Hostname 'TEST-HOST'
 $clearHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clearSnapshot.HtmlBase64))
 Assert-AdminPolicy ($clearHtml.Contains('Allowed password changes') -and $clearHtml.Contains('class="setting-current"')) 'Completed permission cleanup was missing or unverified in the Fix report.'
 $standardRecord=$kiosk | Select-Object *
 $standardRecord.Action='Requested password settings are enabled; no changes needed';$standardRecord.AccountPolicyChanged=$false
 $adminRecord=$shared | Select-Object *
 $adminRecord.Action='Requested password settings are enabled; no changes needed';$adminRecord.AccountPolicyChanged=$false
 $mixed=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk';ItemTitle='KIOSK Account';ItemSub='Verified configuration';Shortcut='';FoundStateHtml=($standardRecord.StateHtml+'<hr>'+$adminRecord.StateHtml);Status='Pass';ActionTaken='No changes needed';AccountResults=@($standardRecord,$adminRecord)}
 $mixedFix=New-ThoroughReportSnapshot -Rows @($mixed) -DisplayMode Fix -Hostname 'TEST-HOST'
 $mixedHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mixedFix.HtmlBase64))
 Assert-AdminPolicy ($mixedHtml.Contains('No fixes required.')) 'A healthy mixed administrator/standard kiosk group was reported unverified.'
 $adminRecord.Action='Manual review required. Please inspect this account.'
 $mixedFix=New-ThoroughReportSnapshot -Rows @($mixed) -DisplayMode Fix -Hostname 'TEST-HOST'
 $mixedHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mixedFix.HtmlBase64))
 Assert-AdminPolicy ($mixedHtml.Contains('Administrator') -and $mixedHtml.Contains('finding-unverified') -and -not $mixedHtml.Contains('User Cannot Change Password')) 'A mixed-role administrator warning was hidden or required the removed field.'
 Reset-AdminFixture -Apply $true -Never $true -Cannot $true
 $script:users[0].Name='Admin'
 $script:users[0].SID=[pscustomobject]@{Value='OTHER-SID'}
 $alias=Invoke-ExistingAccountPolicy -Account $script:users[0] -AdministratorSids (Get-LocalAdministratorSidSet) -ReportPrivilegeOnly
 Assert-AdminPolicy ($alias.Status -eq 'Pass' -and ($script:rawFlags -band 0x40) -eq 0) 'The named Admin account did not retain administrative policy priority.'
 Write-Output ('PASS: '+$file+' Administrator-only Password Never Expires, cleared restrictions, preserved unrelated permission bits and shared-role priority, Audit/Apply/disabled/failure/idempotence matrix, all report modes, standard kiosk policy.')
}