. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('output\zabbix-hostname-input\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert-ZabbixInput {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    Set-KioskTestClient $client
    $source=[KioskTestSource]::ReadAllText((Join-Path $root 'KioskThoroughCheck.ps1'))
    $tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-ZabbixInput (-not $errors.Count) 'Expanded source does not parse.'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $toolAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'OtherTools\KioskMaintenance.ps1'),[ref]$tokens,[ref]$errors)
    . ([scriptblock]::Create(($toolAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $folder=Join-Path $fixture $client;[void][IO.Directory]::CreateDirectory($folder)
    $config=Join-Path $folder 'zabbix_agent2.conf';$include=Join-Path $folder 'hostname.conf';$backups=Join-Path $folder 'backups'
    $command='"C:\Fixture\zabbix_agent2.exe" -c "'+$config+'"'
    $prefix="# Preserve server and TLS settings`r`nServer=192.0.2.10`r`nServerActive=192.0.2.11:8013`r`nTLSConnect=psk`r`nTLSPSKIdentity=FIXTURE-IDENTITY`r`n"
    $actualSetter=(Get-Command Set-ZabbixDeviceHostname).ScriptBlock
    function Set-ZabbixDeviceHostname {param($CommandLine,$Hostname,[switch]$OnlyIfMissing) & $actualSetter -CommandLine $CommandLine -Hostname $Hostname -OnlyIfMissing:$OnlyIfMissing -BackupFolder $backups}
    function Read-Host {param($Prompt)
        $script:prompts.Add($Prompt)
        if(-not $script:answers.Count){throw ('Unexpected prompt: '+$Prompt)}
        $answer=$script:answers.Dequeue()
        if($script:race -and $Prompt -like 'Zabbix hostname*'){[IO.File]::WriteAllText($config,$prefix+'Hostname=CONCURRENT-HOST');$script:race=$false}
        if($script:agentRace -and $Prompt -like 'Zabbix hostname*'){
            [IO.File]::WriteAllText($config,$prefix+'Hostname=CONCURRENT-INSTALL')
            $script:agent=[pscustomobject]@{Name='Zabbix Agent 2';State='Running';StartMode='Auto';PathName=$command};$script:agentRace=$false
        }
        $answer
    }
    function Get-Service {[CmdletBinding()]param($Name)
        Assert-ZabbixInput ($Name -eq 'Zabbix Agent 2') 'Another service was queried.'
        $controller=[pscustomobject]@{Status=$script:controllerState};$controller | Add-Member ScriptMethod WaitForStatus {param($State,$Timeout)};$controller
    }
    function Restart-Service {[CmdletBinding()]param($Name)
        Assert-ZabbixInput ($Name -eq 'Zabbix Agent 2') 'Another service was restarted.'
        $script:restarts++
        if($script:restartFailure){$script:restartFailure=$false;throw 'Fixture restart failure'}
    }
    function Start-Service {throw 'Unexpected service start'}
    function Rename-Computer {throw 'Windows must not be renamed'}
    function Reset-ZabbixFixture {param([string]$Text,[switch]$MissingAgent,[string[]]$Answers=@())
        [IO.File]::WriteAllText($config,$Text,[Text.UTF8Encoding]::new($false))
        $script:prompts=New-Object 'Collections.Generic.List[string]';$script:answers=New-Object 'Collections.Generic.Queue[string]'
        foreach($answer in $Answers){$script:answers.Enqueue($answer)}
        $script:restarts=0;$script:restartFailure=$false;$script:race=$false;$script:agentRace=$false;$script:installs=0;$script:controllerState='Running'
        $script:agent=if($MissingAgent){$null}else{[pscustomobject]@{Name='Zabbix Agent 2';State='Running';StartMode='Auto';PathName=$command}}
    }
    foreach($valid in @('MONITOR-01','Branch 12_POS.Kiosk',('Z'*128))){Assert-ZabbixInput (Test-ZabbixMonitoringHostname $valid) 'A valid monitoring hostname was rejected.'}
    foreach($invalid in @('',' ',('Z'*129),'one,two','bad"name',"bad`nname",'Not detected')){Assert-ZabbixInput (-not (Test-ZabbixMonitoringHostname $invalid)) 'An invalid monitoring hostname was accepted.'}
    Reset-ZabbixFixture $prefix;$script:ApplyChanges=$false;$blocked=$false
    try{[void](Read-ZabbixMonitoringHostname -SuggestedName 'WINDOWS-HOST')}catch{$blocked=$true}
    Assert-ZabbixInput ($blocked -and -not $script:prompts.Count) 'Audit requested hostname input.'
    Reset-ZabbixFixture $prefix -Answers @('bad,name','Branch 12_POS.Kiosk');$script:ApplyChanges=$true
    Assert-ZabbixInput ((Read-ZabbixMonitoringHostname -SuggestedName 'WINDOWS-HOST') -ceq 'Branch 12_POS.Kiosk' -and $script:prompts.Count -eq 2) 'Prompt lost custom input or accepted an invalid hostname.'
    Reset-ZabbixFixture $prefix -Answers @('')
    Assert-ZabbixInput ((Read-ZabbixMonitoringHostname -SuggestedName 'WINDOWS-FULL-HOST') -ceq 'WINDOWS-FULL-HOST') 'Enter did not keep the full suggested hostname.'
    Reset-ZabbixFixture $prefix -Answers @('','MANUAL-MONITOR')
    Assert-ZabbixInput ((Read-ZabbixMonitoringHostname -SuggestedName 'Not detected') -ceq 'MANUAL-MONITOR') 'Missing Windows identity prevented manual monitoring input.'
    foreach($kind in @('absent','blank','include')){
        $text=if($kind -eq 'absent'){$prefix}elseif($kind -eq 'blank'){$prefix+"Hostname=  `r`n"}else{$prefix+'Include='+$include+"`r`n"}
        Reset-ZabbixFixture $text
        if($kind -eq 'include'){[IO.File]::WriteAllText($include,"# Keep include`r`nHostname=`r`n")}
        $target=if($kind -eq 'include'){$include}else{$config};$original=[IO.File]::ReadAllText($target)
        $change=Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'Branch 12_POS.Kiosk' -OnlyIfMissing
        Assert-ZabbixInput ($change.Changed -and $script:restarts -eq 1 -and (Get-ZabbixConfiguredHostname $command) -ceq 'Branch 12_POS.Kiosk') 'Missing/blank hostname repair was not activated and verified.'
        Assert-ZabbixInput ([IO.File]::ReadAllText($change.BackupPath) -ceq $original -and [IO.File]::ReadAllText($config).Contains('ServerActive=192.0.2.11:8013')) 'Backup or server settings were changed.'
        if($kind -eq 'include'){Assert-ZabbixInput ([IO.File]::ReadAllText($config) -ceq $text) 'Included hostname repair changed the root configuration.'}
        Assert-ZabbixInput (-not (Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'Branch 12_POS.Kiosk' -OnlyIfMissing).Changed) 'Repeat hostname repair rewrote/restarted the agent.'
    }
    foreach($text in @(($prefix+'Hostname=KEEP-MY-NAME'),($prefix+"Hostname=ONE`r`nHostname=TWO"),($prefix+"Hostname=ONE`r`nHostname="),($prefix+'Hostname=ONE,TWO'),($prefix+'HostnameItem=system.hostname'))){
        Reset-ZabbixFixture $text;$blocked=$false
        try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'NEW-MONITOR' -OnlyIfMissing)}catch{$blocked=$true}
        Assert-ZabbixInput ($blocked -and -not $script:restarts -and [IO.File]::ReadAllText($config) -ceq $text) 'An existing, ambiguous or dynamic hostname was overwritten.'
    }
    Reset-ZabbixFixture $prefix;$script:restartFailure=$true;$blocked=$false
    try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'NEW-MONITOR' -OnlyIfMissing)}catch{$blocked=$true}
    Assert-ZabbixInput ($blocked -and [IO.File]::ReadAllText($config) -ceq $prefix) 'Restart failure did not restore the original configuration.'
    Reset-ZabbixFixture $prefix;$script:controllerState='Stopped';$blocked=$false
    try{[void](Set-ZabbixDeviceHostname -CommandLine $command -Hostname 'NEW-MONITOR' -OnlyIfMissing)}catch{$blocked=$true}
    Assert-ZabbixInput ($blocked -and -not $script:restarts -and [IO.File]::ReadAllText($config) -ceq $prefix) 'Stopped-agent preflight changed the configuration.'
    function Get-ThoroughDeviceHostname {'WINDOWS-FULL-HOST'}
    function Get-AuditService {param($ServiceName) Assert-ZabbixInput ($ServiceName -eq 'Zabbix Agent 2') 'Unexpected audited service';$script:agent}
    function Get-ServiceRecoveryDetails {param($ServiceName) [pscustomobject]@{Verified=$true;First='Restart the service';Second='Restart the service';Subsequent='Take No Action'}}
    function Start-AuditStep {param($Number,$Name)}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    function Invoke-RequiredServiceCheck {param($ServiceName,$ItemTitle,$ItemSub,[switch]$DeferConsole)
        Add-AuditEntry -ItemTitle $ItemTitle -ItemSub $ItemSub -Status $(if($script:agent){'Pass'}else{'Fail'}) -ActionTaken 'Service checked'
        $auditRows[-1] | Add-Member RecoveryDetails $null
    }
    function Add-AuditEntry {param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken)
        $auditRows.Add([pscustomobject]@{ItemTitle=$ItemTitle;ItemSub=$ItemSub;Status=$Status;ActionTaken=$ActionTaken;FoundStateHtml=$FoundStateHtml})
    }
    function Invoke-ZabbixAgentInstall {param($Hostname)
        Assert-ZabbixInput (Test-CanApply) 'Audit installed Zabbix'
        $script:installs++;[IO.File]::WriteAllText($config,$prefix+'Hostname='+$Hostname)
        $script:agent=[pscustomobject]@{Name='Zabbix Agent 2';State='Running';StartMode='Auto';PathName=$command}
    }
    $start=$source.IndexOf("Start-AuditStep 8 'Zabbix Agent 2'");$end=$source.IndexOf('# 3.3 Windows Update Service',$start)
    $block=[scriptblock]::Create($source.Substring($start,$end-$start));$sec3Num=3;$sec3Title='Services'
    foreach($apply in @($false,$true)){
        foreach($kind in @('missing-agent','custom','blank','absent','dynamic','duplicate')){
            $text=switch($kind){'custom'{$prefix+'Hostname=CUSTOM Monitoring_01'};'blank'{$prefix+'Hostname='};'dynamic'{$prefix+'HostnameItem=system.hostname'};'duplicate'{$prefix+"Hostname=ONE`r`nHostname=TWO"};default{$prefix}}
            $needsInput=$apply -and $kind -in @('missing-agent','blank','absent')
            Reset-ZabbixFixture $text -MissingAgent:($kind -eq 'missing-agent') -Answers $(if($needsInput){@('SELECTED-MONITOR')}else{@()})
            $script:ApplyChanges=$apply;$reportHostname='UNCHANGED-REPORT-HOST';$auditRows=New-Object 'Collections.Generic.List[psobject]'
            . $block
            Assert-ZabbixInput ($script:prompts.Count -eq [int]$needsInput -and $reportHostname -ceq 'UNCHANGED-REPORT-HOST') 'Main flow prompted at the wrong time or changed report identity.'
            $healthy=$kind -eq 'custom' -or $needsInput
            Assert-ZabbixInput (($auditRows[-1].Status -eq 'Pass') -eq $healthy) ('Main hostname verification failed: '+$apply+'/'+$kind)
            if($needsInput){Assert-ZabbixInput ((Get-ZabbixConfiguredHostname $command) -ceq 'SELECTED-MONITOR') 'Main flow ignored entered monitoring hostname.'}
            elseif($kind -ne 'missing-agent'){Assert-ZabbixInput ([IO.File]::ReadAllText($config) -ceq $text) 'Main flow overwrote an existing configuration.'}
        }
    }
    function Test-KioskMaintenanceAdministrator {$true}
    function Get-CimInstance {[CmdletBinding()]param($ClassName,$Filter) Assert-ZabbixInput ($ClassName -eq 'Win32_Service') 'Unexpected tool device query';$script:agent}
    foreach($kind in @('install','missing-hostname','existing-custom','dynamic','decline','whatif','race')){
        $text=if($kind -eq 'existing-custom'){$prefix+'Hostname=KEEP-MY-MONITOR'}elseif($kind -eq 'dynamic'){$prefix+'HostnameItem=system.hostname'}else{$prefix}
        $answers=if($kind -eq 'decline'){@('n')}elseif($kind -in @('install','missing-hostname','race')){@('y','TOOL-MONITOR')}else{@()}
        Reset-ZabbixFixture $text -MissingAgent:($kind -eq 'install') -Answers $answers
        $script:race=$kind -eq 'race'
        $result=Invoke-KioskMaintenanceTool -Tool ZabbixInstaller -Root $root -WhatIf:($kind -eq 'whatif')
        $expectedStatus=if($kind -in @('dynamic','race')){'Fail'}elseif($kind -in @('decline','whatif')){'Skipped'}else{'Pass'}
        Assert-ZabbixInput ($result.Status -eq $expectedStatus -and -not $script:ApplyChanges) ('Tool scope/input/result failed: '+$kind+'; '+$result.Message)
        if($kind -in @('install','missing-hostname')){Assert-ZabbixInput ((Get-ZabbixConfiguredHostname $command) -ceq 'TOOL-MONITOR' -and $script:prompts.Count -eq 2) 'Tool did not use the separate monitoring input.'}
        elseif($kind -eq 'race'){Assert-ZabbixInput ((Get-ZabbixConfiguredHostname $command) -ceq 'CONCURRENT-HOST' -and -not $script:restarts) 'Tool overwrote a concurrent hostname.'}
        else{Assert-ZabbixInput ([IO.File]::ReadAllText($config) -ceq $text -and -not $script:restarts -and -not $script:installs) 'Tool changed a preserved, declined, dynamic or WhatIf configuration.'}
    }
    foreach($surface in @('Apply','Tools')){
        Reset-ZabbixFixture $prefix -MissingAgent -Answers $(if($surface -eq 'Tools'){@('y','SELECTED-MONITOR')}else{@('SELECTED-MONITOR')})
        $script:agentRace=$true
        if($surface -eq 'Apply'){$script:ApplyChanges=$true;$auditRows=New-Object 'Collections.Generic.List[psobject]';. $block;Assert-ZabbixInput ($auditRows[-1].Status -eq 'Fail') 'Concurrent installation became Pass'}
        else{$result=Invoke-KioskMaintenanceTool -Tool ZabbixInstaller -Root $root;Assert-ZabbixInput ($result.Status -eq 'Fail') 'Tool concurrent installation became Pass'}
        Assert-ZabbixInput (-not $script:installs -and -not $script:restarts -and (Get-ZabbixConfiguredHostname $command) -ceq 'CONCURRENT-INSTALL') 'Concurrent installation was overwritten.'
    }
    Write-Output ('PASS: '+$client+' separate Zabbix input in Apply/Tools; Audit/WhatIf/decline safety; custom-name preservation; blank/missing/include repair, backup/rollback, validation and concurrent-edit guard.')
}
