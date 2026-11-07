# Import production definitions; all installers/task writes are fixture doubles.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$root=Join-Path $project ('output/maintenance-tools/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'Scripts'))
$launcher=Join-Path $root 'Scripts/LaunchKiosk.ps1'
[IO.File]::WriteAllText($launcher,'# fixture launcher must never execute')
$config=Join-Path $root 'zabbix_agent2.conf'
$toolText=[IO.File]::ReadAllText((Join-Path $project 'OtherTools/KioskMaintenance.ps1'))
$engine=[IO.File]::ReadAllText((Join-Path $project 'KioskThoroughCheck.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($toolText,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$toolFunctions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
. ([scriptblock]::Create(($toolFunctions | ForEach-Object {$_.Extent.Text}) -join "`n"))
$realBackup=(Get-Command Save-KioskMaintenanceTaskBackup).ScriptBlock
$scheduler=New-Object -ComObject Schedule.Service
$scheduler.Connect()
function Assert-Maintenance {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Reset-Maintenance {
    $script:ApplyChanges=$false;$script:admin=$true;$script:answers=[Collections.Generic.Queue[string]]::new();$script:prompts=[Collections.Generic.List[string]]::new()
    $script:users=@([pscustomobject]@{Name='Fixture Kiosk';Enabled=$true;SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-1001')})
    $script:taskList=@();$script:taskXml='';$script:taskWrites=0;$script:taskFailure='';$script:inventoryReads=0;$script:raceTask=$false;$script:raceAt=2
    $script:zabbix=$null;$script:zabbixInstalls=0;$script:zabbixFailure='';$script:osCaption='Microsoft Windows 11 Enterprise'
    $script:setupCalls=0;$script:setupExit=0;$script:missingPackage=$false;$script:packageReads=0;$script:racePackage=$false;$script:raceBytes=$false;$script:missingWinget=$false;$script:missingNmapReadback=$false
    $global:MaintenanceNmapInstalled=$false;$global:MaintenanceWingetExit=0;$global:MaintenanceWingetArgs=@();$script:nmapBadVersion=$false
    [IO.File]::WriteAllText($config,'Hostname=DEVICE-01')
    [IO.File]::WriteAllText((Join-Path $root 'nmap-verified-setup.exe'),'inert installer fixture; never execute')
}
$wingetFixture=Join-Path $root 'winget-fixture.ps1'
[IO.File]::WriteAllText($wingetFixture,@'
$global:MaintenanceWingetArgs=@($args)
$global:MaintenanceNmapInstalled=$true
$global:LASTEXITCODE=$global:MaintenanceWingetExit
'@)
foreach($tool in @('KioskLauncherTask','ZabbixInstaller','NmapInstaller')){
    . (Get-KioskMaintenanceFunctionBlock -Source ($engine+"`nthrow 'The full audit must never execute'") -Tool $tool)
    function Test-KioskMaintenanceAdministrator {$script:admin}
    function Get-ThoroughDeviceHostname {'DEVICE-01'}
    function Read-Host {param($Prompt)
        $script:prompts.Add($Prompt);if(-not $script:answers.Count){throw ('Unexpected prompt: '+$Prompt)}
        $answer=$script:answers.Dequeue()
        if($script:raceBytes -and $answer -eq 'y'){[IO.File]::WriteAllText((Join-Path $root 'nmap-verified-setup.exe'),'changed during confirmation')}
        $answer
    }
    function Get-LocalUser {$script:users}
    function Get-KioskProfilePath {param($UserName) $root}
    function Get-ScheduledTask {
        $script:inventoryReads++
        if($script:raceTask -and $script:inventoryReads -eq $script:raceAt){$script:taskList=@([pscustomobject]@{TaskName='Launch Kiosk';TaskPath='\';State='Ready'});$script:taskXml='concurrent customer task'}
        $script:taskList
    }
    function Export-ScheduledTask {param($TaskName,$TaskPath) Assert-Maintenance ($TaskName -eq 'Launch Kiosk' -and $TaskPath -eq '\') 'Wrong task exported';$script:taskXml}
    function Get-ScheduledTaskInfo {[pscustomobject]@{LastRunTime=[datetime]::new(2026,11,1);LastTaskResult=0}}
    function Register-MissingKioskLaunchTask {param($Context)
        Assert-Maintenance ((Test-CanApply) -and $Context.Ready) 'Unapproved or unverified task mutation'
        $script:taskWrites++
        if($script:taskFailure -eq 'register'){throw 'Fixture task registration failure'}
        $definition=New-KioskLaunchTaskDefinition $scheduler $Context
        $script:taskXml=$definition.XmlText
        if($script:taskFailure -eq 'readback'){$script:taskXml=$script:taskXml.Replace('<Delay>PT5S</Delay>','<Delay>PT30S</Delay>')}
        $script:taskList=@([pscustomobject]@{TaskName='Launch Kiosk';TaskPath='\';State='Ready'})
    }
    function Save-KioskMaintenanceTaskBackup {param($Xml) & $realBackup -Xml $Xml -Folder (Join-Path $root backups)}
    function Get-CimInstance {param($ClassName,$Filter)
        switch($ClassName){'Win32_Service'{$script:zabbix};'Win32_OperatingSystem'{[pscustomobject]@{Caption=$script:osCaption}};default{throw 'Unexpected device query'}}
    }
    function Invoke-ZabbixAgentInstall {param($Hostname)
        Assert-Maintenance ((Test-CanApply) -and $Hostname -ceq 'DEVICE-01') 'Unapproved Zabbix installation/hostname'
        $script:zabbixInstalls++
        if($script:zabbixFailure -eq 'exit'){throw 'Fixture installer exit failure'}
        if($script:zabbixFailure -eq 'missing'){return}
        $script:zabbix=[pscustomobject]@{State='Running';StartMode='Auto';PathName=('zabbix_agent2.exe -c "'+$config+'"')}
        if($script:zabbixFailure -eq 'hostname'){[IO.File]::WriteAllText($config,'Hostname=WRONG')}
    }
    function Get-NmapExecutable {if($global:MaintenanceNmapInstalled -and -not $script:missingNmapReadback){return (Join-Path $root 'nmap.exe')};return $null}
    function Get-NmapVersion {param($Path) if($script:nmapBadVersion){throw 'Fixture version readback failed'};[pscustomobject]@{Version='fixture-version'}}
    function Get-LocalNmapInstaller {param($ScriptDirectory)
        $script:packageReads++
        if($script:missingPackage){throw 'Verified local Nmap package is missing'}
        if($script:racePackage -and $script:packageReads -gt 1){return (Join-Path $root 'changed.exe')}
        Join-Path $root 'nmap-verified-setup.exe'
    }
    function Get-Command {param($Name,$CommandType)
        Assert-Maintenance ($Name -eq 'winget.exe') 'Unexpected executable lookup'
        if($script:missingWinget){throw 'Fixture winget unavailable'}
        [pscustomobject]@{Source=$wingetFixture}
    }
    function Start-Process {param($FilePath,[switch]$Wait,[switch]$PassThru)
        Assert-Maintenance ($FilePath -eq (Join-Path $root 'nmap-verified-setup.exe') -and $Wait) 'Unexpected process launch'
        $script:setupCalls++;$global:MaintenanceNmapInstalled=$true;[pscustomobject]@{ExitCode=$script:setupExit}
    }
    function Rename-Computer {throw 'Windows rename is forbidden'}
    function Restart-Computer {throw 'Computer restart is forbidden'}
    function Start-ScheduledTask {throw 'Task execution is forbidden'}
    function Set-LocalUser {throw 'Account mutations are forbidden'}
    Reset-Maintenance;$script:admin=$false
    $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
    Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:prompts.Count) 'Unelevated tool requested input/mutation'
    Reset-Maintenance;$script:answers.Enqueue('n')
    $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
    Assert-Maintenance ($result.Status -eq 'Skipped' -and $result.ReturnToMenu -and -not $script:taskWrites -and -not $script:zabbixInstalls -and -not $script:setupCalls -and -not $global:MaintenanceNmapInstalled) 'Decline made a change or lost return navigation'
    Reset-Maintenance
    $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root -WhatIf
    Assert-Maintenance ($result.Status -eq 'Skipped' -and -not $script:prompts.Count -and -not $script:ApplyChanges) 'WhatIf requested approval or applied changes'
    Reset-Maintenance;$script:answers.Enqueue('y')
    $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
    Assert-Maintenance ($result.Status -eq 'Pass' -and -not $script:ApplyChanges) ('Confirmed '+$tool+' failed: '+$result.Message)
    if($tool -eq 'NmapInstaller'){
        Assert-Maintenance (($global:MaintenanceWingetArgs -join ' ') -match '^install --id Insecure.Nmap --exact --source winget .*--no-upgrade$') 'Winget selected another package or permitted upgrades'
    }
    $promptCount=$script:prompts.Count
    $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
    Assert-Maintenance ($result.Status -eq 'Pass' -and $script:prompts.Count -eq $promptCount) 'Existing healthy installation/task was changed or prompted'
    switch($tool){
        'KioskLauncherTask' {
            $original=$script:taskXml.Replace('<Delay>PT5S</Delay>','<Delay>PT30S</Delay>');$script:taskXml=$original
            $script:answers.Enqueue('y');$result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Pass' -and $script:taskWrites -eq 2) 'Owned invalid task was not repaired'
            $backups=@(Get-ChildItem -LiteralPath (Join-Path $root backups) -Filter '*.xml' -File)
            Assert-Maintenance ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -ceq $original) 'Original task XML not backed up exactly'
            $script:taskXml=$original;$script:taskFailure='readback';$script:answers.Enqueue('y')
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and $result.Message.Contains('Original task XML backup:')) 'Failed existing-task repair did not retain/report recovery evidence'
            Reset-Maintenance;$script:raceTask=$true;$script:answers.Enqueue('y')
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:taskWrites) 'Concurrent task was overwritten'
            Reset-Maintenance;$script:raceTask=$true;$script:raceAt=3;$script:answers.Enqueue('y')
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:taskWrites -and $script:taskXml -ceq 'concurrent customer task') 'Late task inventory change bypassed the mutation guard'
            foreach($failure in @('register','readback')){
                Reset-Maintenance;$script:taskFailure=$failure;$script:answers.Enqueue('y')
                $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
                Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:ApplyChanges) 'Task registration/readback failure became Pass'
            }
            Reset-Maintenance;$script:users=@();$result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:prompts.Count) 'Missing user/profile was provisioned or prompted'
            Reset-Maintenance;[IO.File]::WriteAllText($launcher,'function { broken')
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:taskWrites -and -not $script:prompts.Count) 'Invalid launcher was scheduled'
            [IO.File]::WriteAllText($launcher,'# fixture launcher must never execute')
        }
        'ZabbixInstaller' {
            foreach($failure in @('exit','missing','hostname')){
                Reset-Maintenance;$script:zabbixFailure=$failure;$script:answers.Enqueue('y')
                $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
                Assert-Maintenance ($result.Status -eq 'Fail' -and $script:zabbixInstalls -eq 1 -and -not $script:ApplyChanges) 'Zabbix exit/service/configuration failure became Pass'
            }
            Reset-Maintenance;$script:zabbix=[pscustomobject]@{State='Stopped';StartMode='Manual';PathName='fixture'}
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:zabbixInstalls -and -not $script:prompts.Count) 'Existing unhealthy Zabbix was reinstalled or claimed healthy'
        }
        'NmapInstaller' {
            Reset-Maintenance;$script:osCaption='Windows 10 Enterprise';$script:answers.Enqueue('y')
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
            Assert-Maintenance ($result.Status -eq 'Pass' -and $script:setupCalls -eq 1 -and -not $global:MaintenanceWingetArgs.Count) 'Windows 10 did not use the verified interactive package'
            foreach($failure in @('package','changed-package','changed-bytes','exit','version','missing-binary','winget','winget-exit')){
                Reset-Maintenance
                if($failure -notlike '*winget*'){$script:osCaption='Windows 10 Enterprise'}
                $script:missingPackage=$failure -eq 'package';$script:racePackage=$failure -eq 'changed-package';$script:setupExit=if($failure -eq 'exit'){1}else{0}
                $script:raceBytes=$failure -eq 'changed-bytes';$script:missingNmapReadback=$failure -eq 'missing-binary'
                $script:nmapBadVersion=$failure -eq 'version';$script:missingWinget=$failure -eq 'winget';$global:MaintenanceWingetExit=if($failure -eq 'winget-exit'){1}else{0}
                $script:answers.Enqueue('y');$result=Invoke-KioskMaintenanceTool -Tool $tool -Root $root
                Assert-Maintenance ($result.Status -eq 'Fail') ('Nmap '+$failure+' failure became Pass')
            }
            Reset-Maintenance;$script:osCaption='Windows 10 Enterprise'
            $result=Invoke-KioskMaintenanceTool -Tool $tool -Root ''
            Assert-Maintenance ($result.Status -eq 'Fail' -and -not $script:prompts.Count -and -not $script:setupCalls) 'CDN Windows 10 attempted an unverified/missing installer'
        }
    }
    Write-Output ('PASS: '+$tool+' isolated execution, privilege/WhatIf/decline guards, idempotence, installation/task verification and failure boundaries.')
}

# Exercise actual local and in-memory dispatch with harmless tool bodies only.
Import-Module (Join-Path $project 'Core/PackageLoader.psm1') -Force
$dispatchRoot=Join-Path $root dispatch
[void][IO.Directory]::CreateDirectory((Join-Path $dispatchRoot OtherTools))
$stub='param($ToolId,[switch]$MenuRun,$ProjectRoot) if(-not $MenuRun){throw "MenuRun missing"}; [pscustomobject]@{Status="Pass";ReturnToMenu=$true;Message=$ToolId}'
[IO.File]::WriteAllText((Join-Path $dispatchRoot 'OtherTools/KioskMaintenance.ps1'),$stub)
$runtime=[IO.File]::ReadAllText((Join-Path $project 'Deployment/MemoryRuntime.ps1'))
. ([scriptblock]::Create($runtime))
$entryFunction=@($toolFunctions|Where-Object Name -EQ 'Invoke-KioskMaintenanceTool')[0]
$entryStub='function Invoke-KioskMaintenanceTool {param($Tool,$Root) [pscustomobject]@{Status="Pass";ReturnToMenu=$true;Message=$Tool}}'
$memoryTool=$toolText.Remove($entryFunction.Extent.StartOffset,$entryFunction.Extent.Text.Length).Insert($entryFunction.Extent.StartOffset,$entryStub)
foreach($tool in @('KioskLauncherTask','ZabbixInstaller','NmapInstaller')){
    $result=Invoke-DeviceManagementOtherTool -RootPath $dispatchRoot -ToolId $tool
    Assert-Maintenance ($result.Status -eq 'Pass' -and $result.Message -ceq $tool -and $result.ReturnToMenu) 'Local tool dispatch selected wrong handler/parameters'
    $bundle=@{Files=@{'DeviceManagement/KioskThoroughCheck.ps1'=$engine};Configurations=@{}}
    $execution=Invoke-DeviceManagementMemoryScript -Code $memoryTool -Bundle $bundle -RuntimeCode $runtime -Parameters @{ToolId=$tool;MenuRun=$true;ProjectRoot='Z:\MustNotRead'}
    Assert-Maintenance ($execution.State -eq 'Completed' -and $execution.Errors.Count -eq 0 -and $execution.Output.Count -eq 1 -and $execution.Output[0].Message -ceq $tool) ('Embedded definitions/entry routing failed: '+($execution.Errors|Out-String))
}
Write-Output 'PASS: local dispatcher and isolated in-memory engine-definition loading for all three maintenance tools; no full Audit/Apply executed.'
