
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Mock Task Scheduler registration; native COM is used only for in-memory definitions.
# No task is registered, deleted, started, or changed by this fixture.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output/kiosk-launch-task'
$fixtureRoot=Join-Path $outputRoot ('profile-'+[guid]::NewGuid().ToString('N'))
$launcher=Join-Path $fixtureRoot 'Scripts/LaunchKiosk.ps1'
$startup=Join-Path $fixtureRoot 'AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/LaunchKiosk.bat'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($launcher))
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($startup))
[IO.File]::WriteAllText($launcher,'# fixture: never execute this launcher')
[IO.File]::WriteAllText($startup,'@rem fixture: never execute this BAT')
$launcherHash=(Get-FileHash -LiteralPath $launcher).Hash
$startupHash=(Get-FileHash -LiteralPath $startup).Hash
$script:NativeScheduler=New-Object -ComObject Schedule.Service
$script:NativeScheduler.Connect()
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
function Assert-Task {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Reset-TaskFixture {
    $script:Tasks=@();$script:TaskXml='';$script:Calls=0;$script:Writes=0
    $script:TaskMode='normal';$script:ContextMode='normal';$script:ApplyChanges=$false
    $script:FreshAccount=[pscustomobject]@{Name='Fixture Kiosk';Enabled=$true;SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-1001')}
}
function Set-ExistingTask {param([string]$Xml=$script:GoodXml,[string]$Path='\',[string]$State='Ready')
    $script:Tasks=@([pscustomobject]@{TaskName='Launch Kiosk';TaskPath=$Path;State=$State})
    $script:TaskXml=$Xml
}
function New-TaskRow {param($Result)
    [pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Kiosk Launch Task';ItemSub='Type: Missing-only logon task repair';Shortcut=(New-ReportCommand @('taskschd.msc'));FoundStateHtml=$Result.StateHtml;ExpectedHtml=$Result.ExpectedHtml;Status=$Result.Status;ActionTaken=[Net.WebUtility]::HtmlEncode($Result.Action)}
}
$caseCount=0
foreach($name in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $name
    $tokens=$null;$errors=$null
    $path=Join-Path $sourceRoot 'KioskThoroughCheck.ps1'
    $ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Task ($errors.Count -eq 0) 'Source parsing failed'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-Task (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Client source has a BOM'
    [void]([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    $registrationCommands=@((Get-Command Register-MissingKioskLaunchTask).ScriptBlock.Ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    Assert-Task (-not @($registrationCommands|Where-Object {$_ -match 'Unregister-|Start-ScheduledTask|Register-ScheduledTask'}).Count) 'Registration can replace or start an existing task'
    $source=[KioskTestSource]::ReadAllText($path)
    Assert-Task ($source.Contains('Invoke-KioskLaunchTaskCheck -UserName $kioskUser -Account $kioskAccount')) 'The task check is not connected to the selected account'
    function Get-LocalAccount {param($UserName)
        if($script:ContextMode -eq 'account-missing'){return $null}
        $script:FreshAccount
    }
    function Get-KioskProfilePath {param($UserName)
        if($script:ContextMode -eq 'profile-missing'){return ''}
        $fixtureRoot
    }
    function Test-Path {param($LiteralPath,$PathType,$ErrorAction)
        if($script:ContextMode -eq 'script-missing' -and $LiteralPath -eq $launcher){return $false}
        if($script:ContextMode -eq 'exe-missing' -and $LiteralPath -eq (Join-Path $PSHOME 'powershell.exe')){return $false}
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType -ErrorAction Stop
    }
    function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction)
        if($script:ContextMode -eq 'linked-path' -and $LiteralPath -eq $fixtureRoot){return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    }
    function Get-ScheduledTask {param($ErrorAction)
        $script:Calls++
        if($script:TaskMode -eq 'denied' -or ($script:TaskMode -eq 'readback-denied' -and $script:Writes)){throw 'Fixture access denied'}
        if($script:TaskMode -eq 'race-before' -and $script:Calls -eq 2){Set-ExistingTask}
        $script:Tasks
    }
    function Export-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
        Assert-Task ($TaskName -eq 'Launch Kiosk' -and $TaskPath) 'Export targets an unexpected task'
        if($script:TaskMode -eq 'export-denied'){throw 'Fixture export denied'}
        $script:TaskXml
    }
    function Get-ScheduledTaskInfo {param($TaskName,$TaskPath,$ErrorAction)
        Assert-Task ($TaskName -eq 'Launch Kiosk' -and $TaskPath) 'History targets an unexpected task'
        if($script:TaskMode -eq 'never-run'){return [pscustomobject]@{LastRunTime=[datetime]'1999-11-30';NextRunTime=[datetime]'1999-11-30';LastTaskResult=267011}}
        [pscustomobject]@{LastRunTime=[datetime]'2026-11-04T01:20:00';NextRunTime=[datetime]'1899-12-30';LastTaskResult=0}
    }
    function Open-KioskLaunchTaskScheduler {
        # This mock has no method that forwards registration to native COM.
        $root=[pscustomobject]@{}
        $root|Add-Member ScriptMethod RegisterTaskDefinition {
            param($Name,$Definition,$Flags,$User,$Password,$LogonType,$Sddl)
            $script:Writes++
            Assert-Task ($script:ApplyChanges -and $Name -eq 'Launch Kiosk' -and ($Flags -eq 2 -or $Flags -eq 6)) 'Registration is not Apply'
            Assert-Task ($User -eq $script:FreshAccount.SID.Value -and $null -eq $Password -and $LogonType -eq 3 -and $null -eq $Sddl) 'Registration uses an unexpected identity or credential'
            $script:RegisteredXml=$Definition.XmlText
            if($script:TaskMode -eq 'register-failed'){throw 'Fixture registration failed'}
            if($script:TaskMode -eq 'race-during'){Set-ExistingTask ($script:GoodXml.Replace('<RunLevel>LeastPrivilege</RunLevel>','<RunLevel>HighestAvailable</RunLevel>'));throw 'Fixture task already exists'}
            if($script:TaskMode -eq 'readback-missing'){return}
            $xml=$Definition.XmlText
            if($script:TaskMode -eq 'readback-wrong'){$xml=$xml.Replace('<Delay>PT5S</Delay>','<Delay>PT30S</Delay>')}
            if($script:TaskMode -eq 'readback-defaults'){$xml=$xml.Replace('<Enabled>true</Enabled>','').Replace('<RunLevel>LeastPrivilege</RunLevel>','')}
            if($script:TaskMode -eq 'readback-invalid'){$xml='<invalid'}
            Set-ExistingTask $xml
        }
        $service=[pscustomobject]@{Root=$root}
        $service|Add-Member ScriptMethod NewTask {param($Flags) Assert-Task ($Flags -eq 0) 'Unexpected definition flags';$script:NativeScheduler.NewTask(0)}
        $service|Add-Member ScriptMethod GetFolder {param($Path) Assert-Task ($Path -eq '\') 'Unexpected target folder';$this.Root}
        $service
    }
    function Unregister-ScheduledTask {throw 'Task deletion is forbidden'}
    function Start-ScheduledTask {throw 'Task execution is forbidden'}
    function Register-ScheduledTask {throw 'Force/updating registration is forbidden'}
    function Set-LocalUser {throw 'Account writes are forbidden'}
    function Set-Content {throw 'Launcher writes are forbidden'}
    function Start-Process {throw 'Process launch is forbidden'}
    function Get-CimInstance {throw 'Unexpected device query'}
    Reset-TaskFixture
    $account=$script:FreshAccount
    $context=Get-KioskLaunchTaskContext $account.Name $account
    Assert-Task $context.Ready ('Fixture prerequisites failed: '+$context.Reason)
    # Real Task Scheduler XML serialization, with no persisted task.
    $definition=New-KioskLaunchTaskDefinition $script:NativeScheduler $context
    $script:GoodXml=$definition.XmlText
    foreach($expected in @('<LogonType>InteractiveToken</LogonType>','<RunLevel>LeastPrivilege</RunLevel>','<Delay>PT5S</Delay>','<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>','<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>','<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>','<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>','<StartWhenAvailable>true</StartWhenAvailable>')){
        Assert-Task ($script:GoodXml.Contains($expected)) ('Native definition differs: '+$expected)
    }
    Assert-Task ($script:GoodXml.Contains('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;') -or $script:GoodXml.Contains('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "')) 'Hidden launcher arguments are incorrect'
    foreach($apply in @($false,$true)){
        foreach($case in @('healthy','disabled','elevated','system','wrong-user','wrong-trigger-user','wrong-script','wrong-delay','limited-runtime','battery','extra-action','extra-trigger','wrong-folder','multiple','invalid-xml','dtd','unknown-arguments','joined-tokens','export-denied','original-no-directory','omitted-defaults')){
            Reset-TaskFixture;$script:ApplyChanges=$apply
            $xml=$script:GoodXml
            switch($case){
                'disabled' {$xml=$xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')}
                'elevated' {$xml=$xml.Replace('LeastPrivilege','HighestAvailable')}
                'system' {$xml=$xml.Replace($account.SID.Value,'S-1-5-18').Replace('InteractiveToken','ServiceAccount')}
                'wrong-user' {$xml=$xml.Replace($account.SID.Value,'S-1-5-21-111-222-333-1002')}
                'wrong-trigger-user' {$xml=[regex]::Replace($xml,'(?s)(<LogonTrigger>.*?<UserId>).*?(</UserId>)',('$1S-1-5-21-111-222-333-1002$2'))}
                'wrong-script' {$xml=$xml.Replace('LaunchKiosk.ps1','Other.ps1')}
                'wrong-delay' {$xml=$xml.Replace('PT5S','PT30S')}
                'limited-runtime' {$xml=$xml.Replace('PT0S','PT72H')}
                'battery' {$xml=$xml.Replace('<DisallowStartIfOnBatteries>false','<DisallowStartIfOnBatteries>true')}
                'extra-action' {$xml=$xml.Replace('</Actions>','<Exec><Command>other.exe</Command></Exec></Actions>')}
                'extra-trigger' {$xml=$xml.Replace('</Triggers>','<BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>')}
                'invalid-xml' {$xml='<invalid'}
                'dtd' {$xml='<!DOCTYPE Task [<!ENTITY x SYSTEM "file:///C:/secret.txt">]>'+$xml.Substring($xml.IndexOf('<Task '))}
                'unknown-arguments' {$xml=$xml.Replace('-NoProfile','-Token secret-do-not-report -NoProfile')}
                'joined-tokens' {$xml=$xml.Replace('-NoProfile -ExecutionPolicy','-NoProfile"-ExecutionPolicy"')}
                'export-denied' {$script:TaskMode=$case}
                'original-no-directory' {$xml=[regex]::Replace($xml,'<WorkingDirectory>.*?</WorkingDirectory>','')}
                'omitted-defaults' {$xml=$xml.Replace('<Enabled>true</Enabled>','').Replace('<RunLevel>LeastPrivilege</RunLevel>','')}
            }
            Set-ExistingTask $xml
            if($case -eq 'wrong-folder'){$script:Tasks[0].TaskPath='\Other\'}
            if($case -eq 'multiple'){$script:Tasks+=@([pscustomobject]@{TaskName='Launch Kiosk';TaskPath='\Other\';State='Ready'})}
            $beforeXml=$script:TaskXml
            $result=Get-KioskLaunchTaskCheck $account.Name $account
            $pass=$case -in @('healthy','original-no-directory','omitted-defaults')
            if(-not $apply){
                Assert-Task (($result.Status -eq 'Pass') -eq $pass) ('Incorrect existing task status: '+$case+' / '+$result.Action)
                Assert-Task ($script:Writes -eq 0 -and $script:TaskXml -ceq $beforeXml) ('Existing task was changed: '+$case)
            }else{
                if($pass){
                    Assert-Task ($result.Status -eq 'Pass' -and $script:Writes -eq 0) ('Healthy task was rewritten: '+$case)
                }elseif($case -eq 'multiple'){
                    Assert-Task ($result.Status -eq 'Fail' -and $script:Writes -eq 0) ('Multiple tasks were modified: '+$case)
                }elseif($case -eq 'export-denied'){
                    Assert-Task ($result.Status -eq 'Fail' -and $script:Writes -eq 1 -and $result.Action -match 'readback was not verified') ('Unreadable task repair was not disclosed: '+$case)
                }else{
                    Assert-Task ($result.Status -eq 'Remediated' -and $script:Writes -eq 1 -and $result.Action -match 'readback verified') ('Invalid task was not repaired in Apply: '+$case+' / '+$result.Action)
                }
            }
            Assert-Task (-not $result.StateHtml.Contains('secret-do-not-report')) 'Unrecognized command arguments leaked into report'
            $caseCount++
        }
    }
    foreach($case in @('audit','whatif','preflight','account-null','account-missing','sid-changed','disabled-account','unknown-enabled','profile-missing','script-missing','exe-missing','linked-path','denied')){
        Reset-TaskFixture;$script:ApplyChanges=$case -notin @('audit','whatif','preflight')
        $inputAccount=$account
        switch($case){
            'account-null' {$inputAccount=$null}
            'sid-changed' {$script:FreshAccount.SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-1002')}
            'disabled-account' {$script:FreshAccount.Enabled=$false}
            'unknown-enabled' {$script:FreshAccount.PSObject.Properties.Remove('Enabled')}
            'denied' {$script:TaskMode='denied'}
            {$_ -in @('account-missing','profile-missing','script-missing','exe-missing','linked-path')} {$script:ContextMode=$_}
        }
        $result=Get-KioskLaunchTaskCheck $account.Name $inputAccount
        Assert-Task ($result.Status -eq 'Fail' -and $script:Writes -eq 0) ('Unsafe missing-task creation: '+$case+' / '+$result.Action)
        Assert-Task (-not $result.StateHtml.Contains('Interactive</div>')) 'Missing task borrowed desired principal as actual state'
        $caseCount++
    }
    Reset-TaskFixture
    $missing=Get-KioskLaunchTaskCheck $account.Name $account
    Assert-Task ($missing.StateHtml -match 'Task:</span> Missing' -and $missing.StateHtml -match 'Run As:</span> Not configured') 'Audit missing-task evidence is inaccurate'
    $script:ApplyChanges=$true
    $created=Get-KioskLaunchTaskCheck $account.Name $account
    Assert-Task ($created.Status -eq 'Remediated' -and $script:Writes -eq 1 -and $created.Action -match 'readback verified') ('Missing-task Apply failed: '+$created.Action)
    Assert-Task ($created.StateHtml.Contains('Also present (unchanged)') -and $created.Action -match 'both logon launch paths') 'Existing Startup BAT was hidden or removed'
    $again=Get-KioskLaunchTaskCheck $account.Name $account
    Assert-Task ($again.Status -eq 'Pass' -and $script:Writes -eq 1) 'Repeated Apply recreated an existing task'
    $caseCount+=2
    Reset-TaskFixture;$script:ApplyChanges=$true;$script:TaskMode='readback-defaults'
    $defaults=Get-KioskLaunchTaskCheck $account.Name $account
    Assert-Task ($defaults.Status -eq 'Remediated' -and $script:Writes -eq 1 -and $defaults.StateHtml -match 'Task Enabled:</span> Yes' -and $defaults.StateHtml -match 'Trigger:</span> At logon') 'Created task with omitted default XML flags was not verified'
    $script:TaskMode='never-run'
    $history=Get-KioskLaunchTaskHistory $script:Tasks
    Assert-Task ($history['Last Run'] -eq 'Not recorded' -and -not $history.Contains('Next Run')) 'Never-run task displayed a sentinel date as real run history'
    $caseCount+=2
    foreach($case in @('race-before','race-during','register-failed','readback-missing','readback-wrong','readback-invalid','readback-denied')){
        Reset-TaskFixture;$script:ApplyChanges=$true;$script:TaskMode=$case
        $result=Get-KioskLaunchTaskCheck $account.Name $account
        $expected=if($case -eq 'race-before'){'Pass'}else{'Fail'}
        Assert-Task ($result.Status -eq $expected) ('False task creation success: '+$case+' / '+$result.Action)
        Assert-Task ($script:Writes -eq $(if($case -eq 'race-before'){0}else{1})) ('Unexpected registration count: '+$case)
        if($case -eq 'race-during'){Assert-Task ($script:TaskXml.Contains('HighestAvailable')) 'Concurrent task was overwritten'}
        if($case -eq 'readback-denied'){Assert-Task ($result.Action -match 'readback was not verified') 'Unreadable creation readback was not disclosed'}
        $caseCount++
    }
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $identity=[pscustomobject]@{ReportId='OMK-245001';GeneratedAt='04 Nov 2026, 1:20 PM BST';AgentName='Fixture Agent'}
    $before=New-TaskRow $missing;$after=New-TaskRow $created
    foreach($mode in @('Audit','Fix','Final')){
        $snapshot=New-ThoroughReportSnapshot -Rows @($after) -BeforeRows @($before) -AfterApply $true -DisplayMode $mode -AuditSource $identity -DeviceType KIOSK -Hostname 'FIXTURE-PC' -AgentName 'Fixture Agent' -ClientLocation 'Fixture Branch'
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
        if($mode -eq 'Audit'){
            $component=Get-AuditRenderedComponent $html 'Kiosk Launch Task'
            $taskField=@($component.Fields|Where-Object Setting -EQ 'Task Status')[0]
            Assert-Task ($taskField.Found -eq 'Active' -and $taskField.Required -eq 'Active') 'Audit lost task availability or requirement'
        }else{
            $component=Get-SettingRenderedComponent $html 'Kiosk Launch Task'
            $taskField=@($component.Fields|Where-Object Setting -EQ 'Task Status')[0]
            Assert-Task ($taskField.Value -eq 'Active') ('Current task state was lost in '+$mode)
            if($mode -eq 'Fix'){Assert-Task ($taskField.Findings -eq 'Missing') 'Fix lost the before-Apply missing task evidence'}
            Assert-Task (@($component.Fields|Where-Object {$_.Setting -eq 'Target' -and $_.Value -eq $launcher}).Count -eq 1) ('Actual launcher target missing in '+$mode)
        }
        $labels=@('Task Name','Task Status','Target','Trigger Time','Last Run')
        Assert-Task (@($component.Fields|Where-Object Setting -NotIn $labels).Count -eq 0) ('Unexpected task details in '+$mode)
        if($mode -ne 'Fix'){Assert-Task ($component.Fields.Count -eq 5) ('Compact task report must have five fields in '+$mode)}
        $caseCount++
    }
    $healthy=New-TaskRow $again
    $snapshot=New-ThoroughReportSnapshot -Rows @($healthy) -BeforeRows @($healthy) -AfterApply $true -DisplayMode Fix -AuditSource $identity
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    Assert-Task (-not $html.Contains('<div class="device-title">Kiosk Launch Task</div>')) 'Healthy unchanged task appeared in Fix'
    foreach($case in @('pending','readback-denied','readback-wrong')){
        Reset-TaskFixture
        if($case -eq 'pending'){$result=$missing}
        else{$script:ApplyChanges=$true;$script:TaskMode=$case;$result=Get-KioskLaunchTaskCheck $account.Name $account}
        $snapshot=New-ThoroughReportSnapshot -Rows @((New-TaskRow $result)) -BeforeRows @($before) -AfterApply ($case -ne 'pending') -DisplayMode Fix -AuditSource $identity
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        $component=Get-SettingRenderedComponent $html 'Kiosk Launch Task'
        $field=@($component.Fields|Where-Object Setting -EQ 'Target')[0]
        $expected=if($case -eq 'pending'){'Not applied'}elseif($case -eq 'readback-denied'){'Not verified'}else{$launcher}
        Assert-Task ($field.Value -eq $expected) ('Fix fabricated or hid task evidence in '+$case+': '+$field.Value)
        $caseCount++
    }
    # Invoke the real row adapter, then persist only sanitized report observations.
    Reset-TaskFixture;$auditRows=[Collections.Generic.List[object]]::new()
    Invoke-KioskLaunchTaskCheck -UserName $account.Name -Account $account
    Assert-Task ($auditRows.Count -eq 1 -and $auditRows[0].ItemTitle -eq 'Kiosk Launch Task' -and $auditRows[0].ExpectedHtml) 'Main component adapter lost the task row or requirements'
    $copy=@(Copy-ThoroughObservationRows $auditRows.ToArray())
    Assert-Task ($copy[0].ExpectedHtml -ceq $auditRows[0].ExpectedHtml -and $copy[0].FoundStateHtml -ceq $auditRows[0].FoundStateHtml) 'Saved task observations lost definition fields'
    Assert-Task ((Get-FileHash -LiteralPath $launcher).Hash -eq $launcherHash -and (Get-FileHash -LiteralPath $startup).Hash -eq $startupHash) 'Launcher or Startup BAT bytes changed'
    Write-Output ('PASS: '+$client+' native definition, read-only inventory, missing-only Apply, preserved tasks, races, prerequisites, failed readback and Audit/Fix/Final values.')
}
Write-Output ('PASS: '+$caseCount+' kiosk task behavior/report cases; no real task was registered or executed.')
