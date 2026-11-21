
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Isolated hostname and temporary launcher fixtures. No production client, account, service or registry writes.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
function Assert-FullHost { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Get-CimInstance {
 [CmdletBinding()]param([string]$ClassName,[string[]]$Property)
 Assert-FullHost ($ClassName -eq 'Win32_ComputerSystem' -and $Property -contains 'DNSHostName') 'Hostname detection must query the DNS hostname.'
 $script:hostReads++
 if($script:readFailure){throw 'Fixture CIM unavailable'}
 $script:systems
}
function Read-Host {
 param([string]$Prompt)
 $script:prompts.Add($Prompt)
 if(-not $script:answers.Count){throw ('Unexpected hostname prompt: '+$Prompt)}
 return $script:answers.Dequeue()
}
function Set-HostFixture {
 param([string]$Name='OM-DHK-PAN-KIOSK',[string[]]$Answers=@(''))
 $script:systems=@([pscustomobject]@{Name='OM-DHK-PAN-KIOS';DNSHostName=$Name})
 $script:readFailure=$false
 $script:prompts=[Collections.Generic.List[string]]::new()
 $script:answers=[Collections.Generic.Queue[string]]::new()
 foreach($answer in $Answers){$script:answers.Enqueue($answer)}
}
$script:hostReads=0
$oldEnvironmentName=$env:COMPUTERNAME
$env:COMPUTERNAME='OM-DHK-PAN-KIOS'
try {
 foreach($entry in @(
  @{Path='Installations\KIOSK\Setup-Edge.ps1';Prefix='Kiosk'}
 )) {
  $tokens=$null;$errors=$null
  $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot $entry.Path),[ref]$tokens,[ref]$errors)
  Assert-FullHost ($errors.Count -eq 0) 'Setup parser failure.'
  $names=@(('Get-'+$entry.Prefix+'FullHostname'),('Test-'+$entry.Prefix+'HostName'),('Read-'+$entry.Prefix+'HostName'))
  $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names},$true))
  Assert-FullHost ($functions.Count -eq 3) 'Expected hostname functions are missing.'
  . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`n"))
  $get='Get-'+$entry.Prefix+'FullHostname';$read='Read-'+$entry.Prefix+'HostName'
  foreach($full in @('OM-DHK-PAN-KIOSK','Om-Dhk-Pan-Kiosk',('K'+('A'*62)),'KIOSK-1')) {
   Set-HostFixture -Name $full
   Assert-FullHost ((& $get) -ceq $full) 'Full DNS hostname/case/last characters were changed.'
   Assert-FullHost ((& $read) -ceq $full -and $script:prompts[0] -ceq ('Hostname ['+$full+']')) 'Default hostname prompt did not preserve the full DNS name.'
  }
  foreach($failure in @('unavailable','empty','invalid','missing','multiple')) {
   Set-HostFixture -Answers @('','bad name','MANUAL-FULL-KIOSK')
   switch($failure) {
    'unavailable' {$script:readFailure=$true}
    'empty' {$script:systems=@([pscustomobject]@{DNSHostName=''})}
    'invalid' {$script:systems=@([pscustomobject]@{DNSHostName='bad&hostname'})}
    'missing' {$script:systems=@()}
    'multiple' {$script:systems=@([pscustomobject]@{DNSHostName='FIRST'},[pscustomobject]@{DNSHostName='SECOND'})}
   }
   Assert-FullHost ((& $read) -ceq 'MANUAL-FULL-KIOSK') 'Failed detection did not preserve manual hostname input.'
   Assert-FullHost ($script:prompts.Count -eq 3 -and $script:prompts[0] -ceq 'Hostname') 'Failed detection silently suggested the shortened environment name.'
  }
  Write-Output ('PASS: '+$entry.Path+' full/case/63-character DNS names; manual input and unavailable/invalid/multiple detection.')
 }
 $fixtureRoot=Join-Path $projectRoot ('output\full-hostname\'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($fixtureRoot)
 foreach($client in @('SaaS','Subway')) {
  $file=$client
    Set-KioskTestClient -ClientType $client
  $path=Join-Path $projectRoot 'KioskThoroughCheck.ps1'
  $ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
  $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
  . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`n"))
  Set-HostFixture
  $full=Get-ThoroughDeviceHostname
  Assert-FullHost ($full -ceq 'OM-DHK-PAN-KIOSK') 'Report detection returned the shortened name.'
  $script:ApplyChanges=$false
  $origin=if($client -eq 'SaaS'){'https://kiosk.ordermonkey.com'}else{'https://kiosk.subway.ch'}
  foreach($browser in @('msedge.exe','chrome.exe')) {
   $launcher=Join-Path $fixtureRoot ($client+'-'+$browser+'.ps1')
   $text='Start-Process -FilePath '''+$browser+''' -ArgumentList ''--kiosk "'+$origin+'/#/onboarding/login?restaurantId=R1&kioskId=K1&host='+$full+'" --incognito --disable-pinch'''
   [IO.File]::WriteAllText($launcher,$text,(New-Object Text.UTF8Encoding($false)))
   $before=(Get-FileHash -LiteralPath $launcher).Hash
   $result=Repair-LauncherDetails -Path $launcher
   Assert-FullHost ($result.Status -eq 'Pass' -and $result.LauncherValues['Host Name'] -ceq $full) 'Audit compared the full launcher host against the shortened environment name.'
   Assert-FullHost ((Get-FileHash -LiteralPath $launcher).Hash -ceq $before) 'Audit changed the launcher.'
   [IO.File]::WriteAllText($launcher,$text.Replace($full,'OM-DHK-PAN-KIOS'),(New-Object Text.UTF8Encoding($false)))
   $result=Repair-LauncherDetails -Path $launcher
   Assert-FullHost ($result.Status -eq 'Fail') 'A truncated launcher host was reported as correct.'
  }
  $row=[pscustomobject]@{SectionNumber=2;SectionTitle='Launcher';ItemTitle='Kiosk Launch Architecture';ItemSub='';FoundStateHtml='<div>Fixture</div>';Status='Pass';ActionTaken='';Shortcut='';ExpectedHostName=$full}
  $readsBefore=$script:hostReads
  $snapshot=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -Hostname $full
  Assert-FullHost ($script:hostReads -eq $readsBefore) 'Report rendering re-queried Windows instead of using recorded hostname data.'
  $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
  Assert-FullHost ($html.Contains('OM-DHK-PAN-KIOSK')) 'Report header shortened the hostname.'
  $zabbix=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$zabbixExpectedHostname'},$true))[0]
  & ([scriptblock]::Create($zabbix.Extent.Text+'; $zabbixExpectedHostname')) | ForEach-Object {Assert-FullHost ($_ -ceq $full) 'Monitoring comparison used a shortened hostname.'}
  $recordedRow=[pscustomobject]@{ItemTitle='Kiosk Launch Architecture';SectionTitle='Launcher';Status='Pass'}
  $readsBefore=$script:hostReads
  $comparison=Get-ThoroughReportFindingComparison -Row $recordedRow -Label 'Host name' -Value $full -Requirements @{'Host name'=$full}
  Assert-FullHost ($comparison -eq 'match' -and $script:hostReads -eq $readsBefore) 'Recorded hostname comparison queried Windows or shortened the recorded requirement.'
  Set-HostFixture;$script:readFailure=$true
  Assert-FullHost ((Get-ThoroughDeviceHostname) -ceq 'Not detected') 'Unavailable report detection was silently replaced by a short name.'
  Write-Output ('PASS: '+$client+' full report/launcher/monitoring hostname; Chrome/Edge read-only audit, truncated-name mismatch, honest unavailable detection.')
 }
} finally { $env:COMPUTERNAME=$oldEnvironmentName }
