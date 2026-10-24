# Definitions and disposable files only. Never run a production client script.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$projectRoot=Split-Path $PSScriptRoot -Parent
$output=Join-Path $projectRoot 'output\approved-report-fixes-20261024'
$fixtureRoot=Join-Path $output ('fixtures-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8=[Text.UTF8Encoding]::new($false)
function Assert-Approved {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Decode-Approved {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
function Cells-Approved {
    param([string]$Html,[string]$Title)
    $rows=@([regex]::Matches($Html,'(?is)<tr\b[^>]*>.*?</tr>')|Where-Object {$_.Value.Contains('<div class="device-title">'+$Title+'</div>')})
    Assert-Approved ($rows.Count -le 1) ('Duplicate row '+$Title)
    if($rows.Count){@([regex]::Matches($rows[0].Value,'(?is)<td\b[^>]*>(.*?)</td>')|ForEach-Object {$_.Groups[1].Value})}
}
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Approved ($errors.Count -eq 0) 'Client parse failed'
    $definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    . ([scriptblock]::Create(($definitions|ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine))
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $script:fixtureClient=$client
    $script:root=Join-Path $fixtureRoot $client
    [void][IO.Directory]::CreateDirectory($script:root)
    $script:backupRoot=Join-Path $script:root 'backups'
    $script:realWrite=(Get-Command Write-ThoroughTextChange).ScriptBlock
    function Write-ThoroughTextChange {
        param($Original,[string]$Text,[string]$BackupFolder)
        Assert-Approved ($Original.Path.StartsWith($script:root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Fixture attempted a real configuration write'
        & $script:realWrite -Original $Original -Text $Text -BackupFolder $script:backupRoot
    }
    function Rename-Computer {throw 'Windows computer renaming is outside the approved scope'}
    function Set-LocalUser {throw 'The broad account-update cmdlet must not be called'}
    function New-LocalUser {throw 'Account creation is forbidden'}
    function Enable-LocalUser {throw 'Account enabling is forbidden'}
    function Disable-LocalUser {throw 'Account disabling is forbidden'}
    function Add-LocalGroupMember {throw 'Group changes are forbidden'}
    function Remove-LocalGroupMember {throw 'Group changes are forbidden'}
    function Read-Host {param($Prompt) $script:prompts.Add($Prompt);$script:answers.Dequeue()}

    $script:prompts=[Collections.Generic.List[string]]::new()
    $script:answers=[Collections.Generic.Queue[string]]::new()
    $script:ApplyChanges=$false
    $refused=$false;try{[void](Read-ThoroughFixHostname -SuggestedName 'DEVICE-01')}catch{$refused=$true}
    Assert-Approved ($refused -and -not $script:prompts.Count) 'Audit requested a hostname'
    $script:ApplyChanges=$true
    $script:answers.Enqueue('')
    Assert-Approved ((Read-ThoroughFixHostname -SuggestedName 'DEVICE-01') -ceq 'DEVICE-01') 'Default Windows hostname was not confirmed'
    $script:answers.Enqueue('bad name');$script:answers.Enqueue('BRANCH-02')
    Assert-Approved ((Read-ThoroughFixHostname -SuggestedName 'DEVICE-01') -ceq 'BRANCH-02') 'Invalid hostname was accepted or valid retry was lost'
    Assert-Approved ($script:prompts[0].Contains('DEVICE-01')) 'Current Windows hostname suggestion missing'
    $count=$script:prompts.Count
    Assert-Approved ((Read-ThoroughFixHostname -SuggestedName 'DEVICE-01' -SuppliedName 'EXPLICIT-03') -ceq 'EXPLICIT-03' -and $script:prompts.Count -eq $count) 'Validated explicit hostname handling incorrect'
    foreach($bad in @('bad host','-bad','bad-','x..y','x/../y','";throw 1;#')){
        Assert-Approved (-not (Test-ThoroughHostname $bad)) ('Unsafe hostname accepted: '+$bad)
    }
    Assert-Approved (Test-ThoroughHostname 'DEVICE_01') 'A supported existing Windows hostname was rejected'

    # Exercise the actual two-phase loop with only its component block stubbed.
    $phase=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'inspectOnly'},$true))
    Assert-Approved ($phase.Count -eq 1) 'A unique pre-Apply inspection loop was not found'
    $phaseText=$phase[0].Extent.Text
    $start=$phaseText.IndexOf('# =============================================================')
    $end=$phaseText.IndexOf('# END COMPONENT CHECKS')
    Assert-Approved ($start -ge 0 -and $end -gt $start) 'Component loop boundaries changed'
    $fakeChecks=@'
$calls.Add([bool](Test-CanApply))
$auditRows.Add([pscustomobject]@{SectionNumber=1;SectionTitle='Fixture';ItemTitle='Fixture';Status=$(if(Test-CanApply){'Pass'}else{'Fail'});FoundStateHtml=$(if(Test-CanApply){'After'}else{'Before'});Shortcut='';ActionTaken='Fixture'})
'@
    $phaseCode=$phaseText.Substring(0,$start)+$fakeChecks+[Environment]::NewLine+$phaseText.Substring($end)
    foreach($requested in @($false,$true)){
        $phaseResult=& {
            $applyRequested=$requested;$auditRows=[Collections.Generic.List[psobject]]::new();$beforeApplyRows=@()
            $calls=[Collections.Generic.List[bool]]::new()
            . ([scriptblock]::Create($phaseCode))
            [pscustomobject]@{Calls=$calls.ToArray();Before=$beforeApplyRows;After=$auditRows.ToArray()}
        }
        Assert-Approved ($phaseResult.After.Count -eq 1) 'Inspection and Apply rows were combined'
        if($requested){
            Assert-Approved (($phaseResult.Calls -join ',') -ceq 'False,True' -and $phaseResult.Before[0].FoundStateHtml -ceq 'Before' -and $phaseResult.After[0].FoundStateHtml -ceq 'After') 'Pre-Apply inspection was mutable or the original observations were lost'
        }else{Assert-Approved ($phaseResult.Calls.Count -eq 1 -and -not $phaseResult.Calls[0] -and $phaseResult.Before.Count -eq 0) 'Audit enabled repairs or ran twice'}
    }
    $script:BeforeApplyInspection=$false

    # Use only a fake WinNT entry; test the real, narrowly scoped writer.
    function Open-ThoroughLocalAccount {
        param($UserName)
        Assert-Approved ($UserName -ceq 'FixtureAdmin') 'Another account was targeted'
        $entry=[pscustomobject]@{Pending=$null}
        $entry|Add-Member ScriptMethod InvokeGet {
            param($Name)
            switch($Name){'UserFlags'{$script:rawFlags};'PasswordExpired'{$false};'IsAccountLocked'{$false};default{throw 'Unexpected account property read'}}
        }
        $entry|Add-Member ScriptMethod Put {
            param($Name,$Value)
            Assert-Approved ($Name -ceq 'UserFlags') 'An unapproved account property was written'
            $this.Pending=[int]$Value
        }
        $entry|Add-Member ScriptMethod SetInfo {
            $script:commits++
            if($script:writeFailure){throw 'Fixture denied password flag write'}
            if(-not $script:noEffect){$script:rawFlags=$this.Pending}
        }
        $entry|Add-Member ScriptMethod RefreshCache {param($Properties)}
        return ,$entry
    }
    $account=[pscustomobject]@{Name='FixtureAdmin';Enabled=$true;SID=[pscustomobject]@{Value='FixtureSid'}}
    $adminSids=[Collections.Generic.HashSet[string]]::new();[void]$adminSids.Add('FixtureSid')
    foreach($mode in @($false,$true)){
        foreach($mask in @(0,0x40,0x10000,0x10040)){
            $script:ApplyChanges=$mode;$script:rawFlags=0x220 -bor $mask
            $original=$script:rawFlags;$script:commits=0;$script:noEffect=$false;$script:writeFailure=$false
            $result=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids
            $expected=if($mode){$original -bor 0x10040}else{$original}
            Assert-Approved ($script:rawFlags -eq $expected) 'Password flags not enabled or Audit changed an account'
            Assert-Approved (($script:rawFlags -band (-bnot 0x10040)) -eq ($original -band (-bnot 0x10040))) 'An unrelated account flag changed'
            $writes=if($mode -and $mask -ne 0x10040){1}else{0}
            Assert-Approved ($script:commits -eq $writes) 'Compliant account rewritten or missing update'
            Assert-Approved (($result.Status -eq 'Pass') -eq ($mode -or $mask -eq 0x10040)) 'Account result does not reflect readback'
            [void](Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids)
            Assert-Approved ($script:commits -eq $writes) 'Password flags were not idempotent'
        }
    }
    foreach($failure in @('writeFailure','noEffect')){
        $script:ApplyChanges=$true;$script:rawFlags=0x10220;$script:commits=0
        $script:noEffect=$false;$script:writeFailure=$false
        Set-Variable -Scope Script -Name $failure -Value $true
        $result=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids
        Assert-Approved ($result.Status -eq 'Fail' -and $result.StateHtml.Contains('Password Never Expires:</span> Enabled') -and $result.StateHtml.Contains('User Cannot Change Password:</span> Disabled')) 'Write failure lost known flags or claimed success'
    }
    $script:noEffect=$false;$script:writeFailure=$false;$script:commits=0;$script:rawFlags=0x222
    $disabled=$account|Select-Object *;$disabled.Enabled=$false
    [void](Invoke-ExistingAccountPolicy -Account $disabled -AdministratorSids $adminSids)
    Assert-Approved ($script:commits -eq 0 -and $script:rawFlags -eq 0x222) 'Disabled-account eligibility or status changed'

    # Targeted file edits preserve every byte except the confirmed hostname.
    $script:ApplyChanges=$true
    $origin=if($client -eq 'Subway'){'https://kiosk.subway.ch/#/onboarding/login'}else{'https://kiosk.ordermonkey.com/#/onboarding/login'}
    $url=$origin+'?restaurantId=KEEP%20THIS&kioskId=Kiosk-1&host=OLD-DEVICE&theme=keep'
    $launcherText='$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"'+[Environment]::NewLine+'Start-Process $edge -ArgumentList "--kiosk '+$url+' --edge-kiosk-type=fullscreen --disable-pinch"'+[Environment]::NewLine
    $launcher=Join-Path $script:root 'LaunchKiosk.ps1'
    [IO.File]::WriteAllText($launcher,$launcherText,$utf8)
    $change=Set-KioskLauncherHostname -Path $launcher -Hostname 'DEVICE-01' -BackupFolder $script:backupRoot
    Assert-Approved ($change.Changed -and [IO.File]::ReadAllText($launcher) -ceq $launcherText.Replace('host=OLD-DEVICE','host=DEVICE-01')) 'Launcher edit changed unrelated arguments/query parameters'
    Assert-Approved ([IO.File]::ReadAllText($change.BackupPath) -ceq $launcherText) 'Launcher backup does not match the prior file'
    Assert-Approved (-not (Set-KioskLauncherHostname -Path $launcher -Hostname 'DEVICE-01').Changed) 'Compliant hostname was rewritten'
    $script:ApplyChanges=$false;$before=[IO.File]::ReadAllBytes($launcher)
    $blocked=$false;try{[void](Set-KioskLauncherHostname -Path $launcher -Hostname 'OTHER')}catch{$blocked=$true}
    Assert-Approved ($blocked -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($launcher)) -ceq [Convert]::ToBase64String($before)) 'Audit wrote a launcher'
    $script:ApplyChanges=$true
    $ambiguous=$launcherText+[Environment]::NewLine+'$another = "'+$url+'"'
    [IO.File]::WriteAllText($launcher,$ambiguous,$utf8)
    $blocked=$false;try{[void](Set-KioskLauncherHostname -Path $launcher -Hostname 'OTHER')}catch{$blocked=$true}
    Assert-Approved ($blocked -and [IO.File]::ReadAllText($launcher) -ceq $ambiguous) 'Ambiguous launcher was changed'

    function Get-Service {
        [CmdletBinding()]param($Name)
        Assert-Approved ($Name -eq 'Zabbix Agent 2') 'Another service was accessed'
        $service=[pscustomobject]@{Status='Running'}
        $service|Add-Member ScriptMethod WaitForStatus {param($State,$Timeout)}
        $service
    }
    function Restart-Service {
        [CmdletBinding()]param($Name)
        Assert-Approved ($Name -eq 'Zabbix Agent 2') 'Another service was restarted'
        $script:restarts++
        if($script:restartFailure -eq 1){$script:restartFailure=0;throw 'Fixture restart failed'}
    }
    function Start-Service {throw 'Unexpected service start in running-agent fixtures'}
    $config=Join-Path $script:root 'zabbix_agent2.conf'
    $configText='# Keep this comment'+[Environment]::NewLine+'Hostname=OLD-DEVICE'+[Environment]::NewLine+'Server=192.0.2.10'+[Environment]::NewLine+'ServerActive=192.0.2.11'+[Environment]::NewLine
    $command='"C:\Fixture\zabbix_agent2.exe" -c "'+$config+'"'
    [IO.File]::WriteAllText($config,$configText,$utf8)
    $script:restarts=0;$script:restartFailure=0
    $change=Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-01' -BackupFolder $script:backupRoot
    Assert-Approved ($change.Changed -and $script:restarts -eq 1 -and [IO.File]::ReadAllText($config) -ceq $configText.Replace('Hostname=OLD-DEVICE','Hostname=DEVICE-01')) 'Zabbix hostname edit modified server settings or skipped service activation'
    Assert-Approved (-not (Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-01').Changed -and $script:restarts -eq 1) 'Compliant Zabbix config was rewritten/restarted'
    [IO.File]::WriteAllText($config,$configText.Replace('OLD-DEVICE','device-01'),$utf8)
    $change=Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-01'
    Assert-Approved ($change.Changed -and (Get-ZabbixConfiguredHostname -CommandLine $command) -ceq 'DEVICE-01') 'A case-sensitive Zabbix hostname mismatch was ignored'
    [IO.File]::WriteAllText($config,$configText,$utf8)
    $script:restartFailure=1;$blocked=$false
    try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-02')}catch{$blocked=$true}
    Assert-Approved ($blocked -and [IO.File]::ReadAllText($config) -ceq $configText) 'Failed Zabbix activation did not restore the previous config'
    $duplicate=$configText+'Hostname=ANOTHER'+[Environment]::NewLine
    [IO.File]::WriteAllText($config,$duplicate,$utf8)
    $blocked=$false;try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-02')}catch{$blocked=$true}
    Assert-Approved ($blocked -and [IO.File]::ReadAllText($config) -ceq $duplicate) 'Multiple Zabbix Hostname directives were overwritten'
    $multi=$configText.Replace('OLD-DEVICE','DEVICE-01,OTHER-DEVICE')
    [IO.File]::WriteAllText($config,$multi,$utf8)
    $blocked=$false;try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'DEVICE-01')}catch{$blocked=$true}
    Assert-Approved ($blocked -and [IO.File]::ReadAllText($config) -ceq $multi) 'An existing Zabbix multi-host list was overwritten'

    function New-ApprovedRow {
        param([int]$Section,[string]$Title,[string]$Item,[Collections.IDictionary]$Values,[string]$Status='Fail',[string]$Action='Audit only')
        [pscustomobject]@{SectionNumber=$Section;SectionTitle=$Title;ItemTitle=$Item;ItemSub='Fixture';Shortcut='<code>services.msc</code>';Status=$Status;ActionTaken=$Action;FoundStateHtml=(ConvertTo-ReportDefinitionHtml $Values)}
    }
    $script:ApplyChanges=$false
    $windows=New-ApprovedRow 3 'Core Background Services' 'Windows Update (wuauserv)' ([ordered]@{'Service State'='Stopped';'Startup type'='Manual';'First failure'='Take No Action';'Second failure'='Take No Action';'Subsequent failures'='Take No Action'})
    $launcherRow=New-ApprovedRow 2 'Kiosk Application & Policies' 'Kiosk Launch Architecture' ([ordered]@{'Launcher Path'='C:\Fixture\LaunchKiosk.ps1';'Restaurant ID'='KEEP';'Kiosk ID'='Kiosk-1';'Host name'='OLD-DEVICE';'URL origin'=$(if($client -eq 'Subway'){'https://kiosk.subway.ch'}else{'https://kiosk.ordermonkey.com'})})
    $launcherRow|Add-Member NoteProperty ExpectedHostName 'DEVICE-01'
    $launcherRow.Shortcut='<code>notepad.exe "C:\Fixture\LaunchKiosk.ps1"</code>'
    $agent=New-ApprovedRow 3 'Core Background Services' 'Zabbix Agent 2' ([ordered]@{'Service State'='Running';'Startup type'='Automatic';'First failure'='Restart the service';'Second failure'='Restart the service';'Subsequent failures'='Take No Action';'Host Name'='OLD-DEVICE'})
    $agent|Add-Member NoteProperty ExpectedHostName 'DEVICE-01'
    Assert-Approved ((Get-ThoroughReportFindingComparison -Row $agent -Label 'Host Name' -Value 'device-01' -Requirements @{}) -ceq 'unverified') 'A case-sensitive Zabbix mismatch was green'
    $app=New-ApprovedRow 5 'AppSettings Check' 'WebApp/Shop Print' ([ordered]@{'Provider'='KitchenTicketPrint';'IsKioskPrintingEnabled'='Not configured';'IsEnabled'=$false}) Pass 'Read Only'
    $app.Shortcut='<code>notepad.exe "C:\Fixture\appsettings.json"</code>'
    $audit=New-ThoroughReportSnapshot -Rows @($windows,$launcherRow,$agent,$app) -DisplayMode Audit -Hostname 'DEVICE-01'
    $auditHtml=Decode-Approved $audit
    foreach($name in @('Kiosk Launch Script','Zabbix Agent')){
        $cells=@(Cells-Approved $auditHtml $name)
        Assert-Approved ($cells[3] -match 'finding-unverified[^>]*><span class="kv-label">Host [Nn]ame:</span> OLD-DEVICE') 'Wrong hostname was green or uncolored'
    }
    $appCells=@(Cells-Approved $auditHtml 'WebApp/Shop Print')
    Assert-Approved ($appCells[3] -match 'finding-unverified[^>]*><span class="kv-label">IsKioskPrintingEnabled:</span> Not configured' -and $appCells[3] -notmatch 'finding-mismatch') 'Missing AppSettings values were red'
    Assert-Approved ($appCells[3] -match 'finding-match[^>]*><span class="kv-label">IsEnabled:</span> False') 'False AppSettings value was treated as missing'
    $rowsBefore=@(Get-ThoroughSnapshotObservations $audit)
    $private=$windows|Select-Object *
    $private|Add-Member NoteProperty ConfigurationSnapshot ([pscustomobject]@{ApiKey='DO-NOT-PERSIST-SECRET';Password='DO-NOT-PERSIST-PASSWORD'})
    $safe=@(Copy-ThoroughObservationRows @($private))
    Assert-Approved ((ConvertTo-Json -InputObject $safe -Depth 24) -notmatch 'DO-NOT-PERSIST|ConfigurationSnapshot') 'Observation metadata persisted data outside the rendered fields'
    $private=$windows|Select-Object *
    $private|Add-Member NoteProperty UnrelatedSecret 'DO-NOT-PERSIST-SECRET'
    $privateSnapshot=New-ThoroughReportSnapshot -Rows @($private) -DisplayMode Audit
    Assert-Approved ((ConvertTo-Json -InputObject $privateSnapshot -Depth 24) -notmatch 'DO-NOT-PERSIST|UnrelatedSecret') 'The saved snapshot retained data outside report observations'
    $beforeJson=ConvertTo-Json -InputObject $rowsBefore -Depth 24 -Compress
    $after=@(Copy-ThoroughObservationRows $rowsBefore)
    $after[0].Status='Pass';$after[0].ActionTaken='Startup set to Disabled; readback verified';$after[0].FoundStateHtml=$after[0].FoundStateHtml.Replace('Manual','Disabled')
    foreach($i in @(1,2)){$after[$i].Status='Pass';$after[$i].FoundStateHtml=$after[$i].FoundStateHtml.Replace('OLD-DEVICE','DEVICE-01');$after[$i].ActionTaken=$(if($i -eq 1){'Updated launcher hostname to DEVICE-01; readback verified'}else{'Updated Zabbix hostname to DEVICE-01; service restarted and readback verified'})}
    $fix=New-ThoroughReportSnapshot -Rows $after -BeforeRows $rowsBefore -DisplayMode Fix -AfterApply $true -Hostname 'DEVICE-01'
    $final=New-ThoroughReportSnapshot -Rows $after -DisplayMode Final -AfterApply $true -Hostname 'DEVICE-01'
    $fixHtml=Decode-Approved $fix;$finalHtml=Decode-Approved $final
    $cells=@(Cells-Approved $fixHtml 'Windows Update')
    Assert-Approved ($cells[2].Contains('Startup type:</span> Manual') -and -not $cells[2].Contains('No further fix needed') -and $cells[3].Contains('Startup set to Disabled')) 'Fix Findings replaced the pre-fix problem'
    Assert-Approved ($finalHtml.Contains('Startup type:</span> Disabled')) 'Final lacks post-fix state'
    $cells=@(Cells-Approved $fixHtml 'Kiosk Launch Script')
    Assert-Approved ($cells[2].Contains('Host name:</span> OLD-DEVICE') -and $cells[3].Contains('>Completed</strong>')) 'Launcher before/after outcome lost'
    $cells=@(Cells-Approved $fixHtml 'WebApp/Shop Print')
    Assert-Approved ($cells[3].Contains('Expected values are not configured. Please check manually.')) 'Missing AppSettings Applied warning missing'
    Assert-Approved ((ConvertTo-Json -InputObject $rowsBefore -Depth 24 -Compress) -ceq $beforeJson) 'Rendering mutated baseline observations'
    # The exact earlier HTML format remains usable without structured observations.
    $historical=$audit|Select-Object * -ExcludeProperty Observations
    $historicalRows=@(Get-ThoroughSnapshotObservations $historical)
    $oldFix=New-ThoroughReportSnapshot -Rows $after -BeforeRows $historicalRows -DisplayMode Fix -AfterApply $true
    Assert-Approved ((Decode-Approved $oldFix).Contains('Startup type:</span> Manual')) 'Older saved Audit HTML could not supply original Findings'
    $repeated=New-ApprovedRow 5 'AppSettings Check' 'Payment Configuration' ([ordered]@{'Value'='Not configured'}) Pass
    $repeated.FoundStateHtml+=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Value'='Configured';'Zero'=0;'Flag'=$false}))
    Assert-Approved (Test-ThoroughAppSettingsReview $repeated) 'A later duplicate label masked an earlier missing value'

    # Account Findings remain the original disabled checkbox even if readback fails.
    $good=ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='Administrator';'Account Privilege'='Local Administrator';'Account Status'='Enabled';'Password Never Expires'='Enabled';'User Cannot Change Password'='Enabled'})
    $bad=ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='Admin';'Account Privilege'='Local Administrator';'Account Status'='Enabled';'Password Never Expires'='Enabled';'User Cannot Change Password'='Disabled'})
    $admin=New-ApprovedRow 4 'Security, Network & System Integrity' 'Administrative Accounts' ([ordered]@{})
    $admin.FoundStateHtml=$good+'<hr>'+$bad
    $adminAfter=$admin|Select-Object *
    $adminAfter.FoundStateHtml=$good+'<hr>'+($bad.Replace('Disabled','Enabled'))
    $adminAfter.Status='Pass';$adminAfter.ActionTaken='Enabled User Cannot Change Password; readback verified'
    $adminAfter|Add-Member NoteProperty AccountResults @(
        [pscustomobject]@{AccountName='Administrator';Status='Pass';Action='Requested password settings are enabled; no changes needed';AccountPolicyChanged=$false}
        [pscustomobject]@{AccountName='Admin';Status='Pass';Action='Enabled User Cannot Change Password; readback verified';AccountPolicyChanged=$true}
    )
    $accountFix=New-ThoroughReportSnapshot -Rows @($adminAfter) -BeforeRows @($admin) -DisplayMode Fix -AfterApply $true
    $cells=@(Cells-Approved (Decode-Approved $accountFix) 'Administrative Accounts')
    Assert-Approved ($cells[2].Contains('Account 02') -and -not $cells[2].Contains('Account 01') -and $cells[2].Contains('User Cannot Change Password:</span> Disabled') -and $cells[3].Contains('>Completed</strong>')) 'Account baseline or per-account filter failed'
    $adminAfter.AccountResults[1].Status='Fail';$adminAfter.AccountResults[1].Action='Fixture write rejected. Manual action required.'
    $failedFix=New-ThoroughReportSnapshot -Rows @($adminAfter) -BeforeRows @($admin) -DisplayMode Fix -AfterApply $true
    $cells=@(Cells-Approved (Decode-Approved $failedFix) 'Administrative Accounts')
    Assert-Approved ($cells[2].Contains('Password Never Expires') -eq $false -and $cells[2].Contains('User Cannot Change Password:</span> Disabled') -and -not $cells[2].Contains('Not verified') -and $cells[3].Contains('Fixture write rejected')) 'Account failure overwrote original Findings'

    # Persist one self-contained preview; no production file is changed.
    $adminAfter.AccountResults[1].Status='Pass'
    $adminAfter.AccountResults[1].Action='Enabled User Cannot Change Password; readback verified'
    $previewBefore=@($rowsBefore)+@($admin)
    $previewAfter=@($after)+@($adminAfter)
    $previewAudit=New-ThoroughReportSnapshot -Rows $previewBefore -DisplayMode Audit -Hostname 'DEVICE-01' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -ClientLocation 'Sample branch'
    $previewFix=New-ThoroughReportSnapshot -Rows $previewAfter -BeforeRows $previewBefore -DisplayMode Fix -AfterApply $true -Hostname 'DEVICE-01' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -ClientLocation 'Sample branch'
    $previewFinal=New-ThoroughReportSnapshot -Rows $previewAfter -DisplayMode Final -AfterApply $true -Hostname 'DEVICE-01' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -ClientLocation 'Sample branch'
    foreach($snapshot in @($previewAudit,$previewFix,$previewFinal)){
        $html=Decode-Approved $snapshot
        $html=$html.Replace('<h2>REPORT DETAILS</h2>','<p>Preview only: simulated Apply results. No device settings were changed.</p><h2>REPORT DETAILS</h2>')
        $snapshot.HtmlBase64=[Convert]::ToBase64String($utf8.GetBytes($html))
    }
    $reports=[pscustomobject]@{Audit=$previewAudit;Fix=$previewFix;Final=$previewFinal}
    $state=[pscustomobject]@{Version=1;TestOnly=$true;ClientType=$client;ComputerName='DEVICE-01';BundleId='OMK-240024';CreatedAt=$audit.GeneratedAt;UpdatedAt=$audit.GeneratedAt;LatestMode='Fix';Reports=$reports}
    [IO.File]::WriteAllText((Join-Path $output ($client+'-Approved-Fixes-Preview.html')),(New-ThoroughReportBundleHtml $state),$utf8)

    # Keep the same bundle when an older filename uses the incorrect launcher hostname.
    $reportFolder=Join-Path $script:root 'reports';[void][IO.Directory]::CreateDirectory($reportFolder)
    $legacyPath=Join-Path $reportFolder ('Thorough Check Reports - '+$client+' - OLD-DEVICE.html')
    $desiredPath=Join-Path $reportFolder ('Thorough Check Reports - '+$client+' - DEVICE-01.html')
    [void](Save-ThoroughReportBundle -Path $legacyPath -ClientType $client -ComputerName 'DEVICE-01' -Snapshots @($previewAudit) -PreferredMode Audit)
    $hash=(Get-FileHash -LiteralPath $legacyPath).Hash
    $existing=Find-ThoroughExistingBundle -Path $desiredPath -ClientType $client -ComputerName 'DEVICE-01'
    Assert-Approved ($existing.Path -ceq $legacyPath -and (Get-FileHash -LiteralPath $legacyPath).Hash -ceq $hash) 'Existing Windows identity report was lost, guessed or rewritten during discovery'
    [void](Save-ThoroughReportBundle -Path $existing.Path -ClientType $client -ComputerName 'DEVICE-01' -Snapshots @($previewFix,$previewFinal) -PreferredMode Fix)
    $saved=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($legacyPath))
    Assert-Approved ($saved.Reports.Audit.HtmlBase64 -ceq $previewAudit.HtmlBase64 -and @(Get-ChildItem -LiteralPath $reportFolder -File).Count -eq 1) 'Apply replaced Audit or created a separate report after hostname correction'
    $duplicate=Join-Path $reportFolder ('Thorough Check Reports - '+$client+' - ANOTHER.html')
    [IO.File]::WriteAllBytes($duplicate,[IO.File]::ReadAllBytes($legacyPath))
    $blocked=$false;try{[void](Find-ThoroughExistingBundle -Path $desiredPath -ClientType $client -ComputerName 'DEVICE-01')}catch{$blocked=$true}
    Assert-Approved $blocked 'Ambiguous saved report identity was guessed'
    Write-Output ('PASS: '+$client+' Apply-only hostname input; narrow account flags; targeted launcher/Zabbix edits, backup/rollback; immutable Findings, current Applied/Final; amber AppSettings; historical Audit compatibility.')
}
