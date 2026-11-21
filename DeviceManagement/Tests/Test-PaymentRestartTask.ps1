
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Fixture task definitions only. Never query or execute real scheduled tasks/services.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$fixtureRoot=Join-Path $projectRoot 'output\task-scheduler\fixtures'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-TaskCheck {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-CompactTaskFields {
    param([string]$Html,[int]$Count=1)
    $labels=@([regex]::Matches($Html,'<span class="kv-label">([^<]+):</span>') | ForEach-Object {$_.Groups[1].Value})
    $expected=@('Task Name','Task Status','Target','Trigger Time','Last Run','Next Run')
    Assert-TaskCheck ($labels.Count -eq 6*$Count) 'The task view did not contain six fields per task.'
    for($index=0;$index -lt $Count;$index++){
        Assert-TaskCheck (($labels[($index*6)..($index*6+5)] -join '|') -ceq ($expected -join '|')) 'Compact task fields have the wrong labels or order.'
    }
}
function New-TaskFixture {
    param([string]$ServiceName='Custom Payment & Gateway',[string]$Command)
    if(-not $Command){$Command='Restart-Service -Name '''+$ServiceName+''' -Force'}
    [pscustomobject]@{
        TaskName='Nightly Payment <Restart> & Check';TaskPath='\Customer Tasks\';State='Ready'
        Settings=[pscustomobject]@{Enabled=$true}
        Actions=@([pscustomobject]@{Execute='powershell.exe';Arguments=('-NoProfile -Command "'+$Command+'"');WorkingDirectory=''})
        Triggers=@([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskDailyTrigger'};Enabled=$true;StartBoundary='2026-01-01T04:15:00';EndBoundary='';DaysInterval=1;Repetition=[pscustomobject]@{Interval='PT6H';Duration='P1D'}})
    }
}
foreach($sourceName in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $sourceName
    $source=Join-Path $sourceRoot 'KioskThoroughCheck.ps1'
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile($source,[ref]$tokens,[ref]$errors)
    Assert-TaskCheck ($errors.Count -eq 0) 'Client source parse failed.'
    $definitions=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $newHelpers=@($definitions | Where-Object Name -match 'Payment.*Task|PaymentRestart')
    $forbidden=@($newHelpers.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(Register|Set|Start|Stop|Enable|Disable|Unregister)-ScheduledTask$|^(Restart|Start|Stop|Set)-Service$|^Invoke-Expression$|^Start-Process$'},$true))
    Assert-TaskCheck ($forbidden.Count -eq 0) 'Task inspection can mutate or execute a task/service.'
    $call=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-PaymentRestartTaskCheck'},$true))
    Assert-TaskCheck ($call.Count -eq 1 -and $call[0].Extent.Text.Contains('$detectedPaymentProvider') -and $call[0].Extent.Text.Contains('$selectedPaymentServiceName')) 'Production check is not connected to selected provider/service discovery.'
    function Get-ScheduledTask {[CmdletBinding()]param()$script:taskReads++;if($script:readDenied){throw 'Fixture enumeration denied'};$script:fixtureTasks}
    function Get-ScheduledTaskInfo {[CmdletBinding()]param($TaskName,$TaskPath)$script:historyReads++;if($script:historyDenied){throw 'Fixture history denied'};[pscustomobject]@{LastRunTime=[datetime]'2026-10-21T04:15:00';NextRunTime=[datetime]'2026-10-22T04:15:00';LastTaskResult=0}}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    function Register-ScheduledTask {throw 'Task creation forbidden'}
    function Set-ScheduledTask {throw 'Task changes forbidden'}
    function Start-ScheduledTask {throw 'Task execution forbidden'}
    function Restart-Service {throw 'Service restart forbidden'}
    function Start-Service {throw 'Service start forbidden'}
    function Stop-Service {throw 'Service stop forbidden'}
    function Read-Host {throw 'Task check must not prompt'}
    $service='Custom Payment & Gateway'
    foreach($mode in @('Audit','Apply','Final')){
        $script:ApplyChanges=$mode -eq 'Apply';$FinalReport=$mode -eq 'Final'
        foreach($provider in @('NETS','NEXIDE',' nEtS ','SIX','PRINT','OTHER','Not detected','')){
            $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:taskReads=0;$script:historyReads=0;$script:readDenied=$false;$script:historyDenied=$false
            $script:fixtureTasks=@(New-TaskFixture $service)
            $snapshot=$script:fixtureTasks | ConvertTo-Json -Depth 12 -Compress
            Invoke-PaymentRestartTaskCheck -PaymentProvider $provider -ServiceName $service
            $required=$provider.Trim().ToUpperInvariant() -in @('NETS','NEXIDE')
            Assert-TaskCheck ($auditRows.Count -eq [int]$required -and $script:taskReads -eq [int]$required) ('Provider gate failed: '+$mode+'/'+$provider)
            if(-not $required){continue}
            $row=$auditRows[0]
            Assert-TaskCheck ($row.Status -eq 'Pass' -and $row.SectionNumber -eq 3 -and $row.ItemTitle -eq 'Payment Service Restart Task') 'Valid restart task failed or used the wrong section.'
            Assert-TaskCheck ($row.FoundStateHtml.Contains('Nightly Payment &lt;Restart&gt; &amp; Check') -and $row.FoundStateHtml.Contains('Custom Payment &amp; Gateway') -and $row.FoundStateHtml.Contains('04:15:00') -and $row.FoundStateHtml.Contains('PT6H')) 'Actual task identity, target or schedule was lost/unsafe.'
            Assert-TaskCheck ($row.FoundStateHtml.Contains('Last Run:') -and $row.FoundStateHtml.Contains('Next Run:') -and $row.FoundStateHtml.Contains('Last Result:')) 'Task history was not collected.'
            $compact=Format-ReportState $row.ItemTitle $row.FoundStateHtml
            Assert-CompactTaskFields $compact
            Assert-TaskCheck ($compact.Contains('Task Status:</span> Active') -and $compact.Contains('Repeats every 6 hours for 1 day') -and $compact.Contains('21 Oct 2026, 4:15 AM') -and $compact.Contains('Nightly Payment &lt;Restart&gt; &amp; Check')) 'Readable task view lost its enabled state, schedule, history or escaped identity.'
            $expectedBefore=[string]$row.ExpectedHtml
            $requirements=Get-ReportRequirement $row
            Assert-CompactTaskFields $requirements
            $requiredFields=Get-ThoroughReportHighlightFields $requirements
            Assert-TaskCheck ($row.Shortcut -match 'taskschd.msc' -and $requiredFields['Task Name'] -ceq 'e.g. Restart PS' -and $requiredFields['Task Status'] -ceq 'Active' -and $requiredFields['Target'] -ceq 'Payment Service' -and $requiredFields['Trigger Time'] -ceq 'time' -and $requiredFields['Last Run'] -ceq 'date & time' -and $requiredFields['Next Run'] -ceq 'date & time') 'Task shortcut or six display requirements are incorrect.'
            Assert-TaskCheck ([string]$row.ExpectedHtml -ceq $expectedBefore -and $row.ExpectedHtml.Contains('Restart Target:</span> Custom Payment &amp; Gateway')) 'Display requirements changed the selected-service verification reference.'
            Assert-TaskCheck ((Get-ThoroughReportFindingComparison $row 'Task Status' 'Active' $requiredFields) -eq 'match' -and (Get-ThoroughReportFindingComparison $row 'Task Status' 'Disabled' $requiredFields) -eq 'mismatch') 'Task status comparison contradicts the observed enabled state.'
            Assert-TaskCheck ((Get-ThoroughReportFindingComparison $row Target $service $requiredFields) -eq 'match' -and (Get-ThoroughReportFindingComparison $row Target WrongService $requiredFields) -eq 'mismatch') 'Generic target wording obscured selected-service verification.'
            foreach($field in @('Task Name','Trigger Time','Last Run','Next Run')){
                Assert-TaskCheck ((Get-ThoroughReportFindingComparison $row $field 'Actual observed value' $requiredFields) -eq 'match') 'A collected task value was not highlighted.'
                Assert-TaskCheck ((Get-ThoroughReportCollectedValueState $row $field 'Actual observed value' $requiredFields) -eq 'collected') 'A task value became an exact name/date/time requirement.'
            }
            $unknownTargetRow=[pscustomobject]@{ItemTitle=$row.ItemTitle;SectionTitle=$row.SectionTitle;Status='Fail'}
            Assert-TaskCheck ((Get-ThoroughReportFindingComparison $unknownTargetRow Target $service $requiredFields) -eq '') 'A target without a verification reference was reported matched.'
            Assert-TaskCheck (($script:fixtureTasks | ConvertTo-Json -Depth 12 -Compress) -ceq $snapshot) 'Task inspection changed a definition.'
        }
        foreach($case in @('missing','disabled','no-trigger','disabled-trigger','expired','elapsed-once','unknown-state','wrong-service','service-prefix','name-only','conditional','comment-only','uninvoked','dynamic','denied','history-denied','multiple','unrelated','unrelated-payment-task','stop-start','start-only','stop-start-stop')){
            $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:fixtureTasks=@(New-TaskFixture $service);$script:taskReads=0;$script:readDenied=$false;$script:historyDenied=$false
            $task=$script:fixtureTasks[0]
            switch($case){
                'missing' {$script:fixtureTasks=@()}
                'disabled' {$task.Settings.Enabled=$false;$task.State='Disabled'}
                'no-trigger' {$task.Triggers=@()}
                'disabled-trigger' {$task.Triggers[0].Enabled=$false}
                'expired' {$task.Triggers[0].EndBoundary='2000-01-01T00:00:00'}
                'elapsed-once' {$task.Triggers[0].CimClass.CimClassName='MSFT_TaskTimeTrigger';$task.Triggers[0].StartBoundary='2000-01-01T00:00:00';$task.Triggers[0].Repetition.Interval=''}
                'unknown-state' {$task.State='Unknown'}
                'wrong-service' {$task.Actions[0].Arguments='-Command "Restart-Service OtherService"'}
                'service-prefix' {$task.Actions[0].Arguments='-Command "Restart-Service ''Custom Payment & Gateway-OLD''"'}
                'name-only' {$task.Actions[0].Arguments='-Command "Write-Host ''No restart action''"'}
                'conditional' {$task.Actions[0].Arguments='-Command "if ($false) {Restart-Service ''Custom Payment & Gateway''}"'}
                'comment-only' {$task.Actions[0].Arguments='-Command "# Restart-Service ''Custom Payment & Gateway''"'}
                'uninvoked' {$task.Actions[0].Arguments='-Command "function Unused {Restart-Service ''Custom Payment & Gateway''}"'}
                'dynamic' {$task.Actions[0].Arguments='-Command "Restart-Service -Name $env:PAYMENT_SERVICE"'}
                'denied' {$script:readDenied=$true}
                'history-denied' {$script:historyDenied=$true}
                'multiple' {$script:fixtureTasks+=New-TaskFixture $service}
                'unrelated' {$task.TaskName='Windows maintenance';$task.Actions[0].Arguments='-Command "Restart-Service OtherService"'}
                'unrelated-payment-task' {$backup=New-TaskFixture $service;$backup.TaskName='Payment Backup';$backup.Actions[0].Arguments='-Command "Write-Host ''Custom Payment & Gateway''"';$script:fixtureTasks+=$backup}
                'stop-start' {$task.Actions=@([pscustomobject]@{Execute='net.exe';Arguments=('stop "'+$service+'"');WorkingDirectory=''},[pscustomobject]@{Execute='net.exe';Arguments=('start "'+$service+'"');WorkingDirectory=''})}
                'start-only' {$task.Actions[0].Arguments='-Command "Start-Service ''Custom Payment & Gateway''"'}
                'stop-start-stop' {$task.Actions[0].Arguments='-Command "Stop-Service ''Custom Payment & Gateway''; Start-Service ''Custom Payment & Gateway''; Stop-Service ''Custom Payment & Gateway''"'}
            }
            Invoke-PaymentRestartTaskCheck -PaymentProvider NETS -ServiceName $service
            Assert-TaskCheck ($auditRows.Count -eq 1) 'An applicable check was silently omitted.'
            $expected=if($case -in @('multiple','stop-start','unrelated-payment-task')){'Pass'}else{'Fail'}
            Assert-TaskCheck ($auditRows[0].Status -eq $expected) ('Wrong task result: '+$sourceName+'/'+$mode+'/'+$case+' => '+$auditRows[0].Status)
            $compact=Format-ReportState $auditRows[0].ItemTitle $auditRows[0].FoundStateHtml
            Assert-CompactTaskFields $compact $(if($case -eq 'multiple'){2}else{1})
            if($case -eq 'disabled'){Assert-TaskCheck ($compact.Contains('Task Status:</span> Disabled')) 'A disabled task was not shown as Disabled.'}
            if($case -in @('missing','denied','unknown-state')){Assert-TaskCheck ($compact.Contains('Task Status:</span> Not verified')) 'Unavailable task state was presented as enabled or disabled.'}
            if($case -eq 'history-denied'){Assert-TaskCheck ($compact.Contains('Last Run:</span> Not verified') -and $compact.Contains('Next Run:</span> Not verified')) 'Unreadable run history was presented as verified.'}
            if($case -eq 'missing'){Assert-TaskCheck ($compact.Contains('Task Name:</span> Not found') -and $compact.Contains('Target:</span> Not verified')) 'Missing tasks fabricated an observed identity or target.'}
            if($case -eq 'multiple'){Assert-TaskCheck ($auditRows[0].FoundStateHtml.Contains('[Task 1]') -and $auditRows[0].FoundStateHtml.Contains('[Task 2]')) 'Multiple task records were lost.'}
            if($case -eq 'multiple'){Assert-TaskCheck ($compact.Contains('[Task 1]') -and $compact.Contains('[Task 2]')) 'Compact task view lost multiple-task grouping.'}
        }
    }
    $script:readDenied=$false;$script:historyDenied=$false
    $scriptPath=Join-Path $fixtureRoot 'Static Restart & Check.ps1'
    $batchPath=Join-Path $fixtureRoot 'Static Restart.cmd'
    [IO.File]::WriteAllText($scriptPath,('$service = '''+$service+''' = ''literal''').Replace(' = ''literal''','')+"`r`n"+'Restart-Service -Name $service -ErrorAction Stop')
    [IO.File]::WriteAllText($batchPath,('@echo off'+"`r`n"+'net stop "'+$service+'"'+"`r`n"+'net start "'+$service+'"'))
    $scriptHash=(Get-FileHash -LiteralPath $scriptPath).Hash;$batchHash=(Get-FileHash -LiteralPath $batchPath).Hash
    foreach($case in @('ps-file','bat-file','cmd-file','cmd-inline','encoded','scriptblock')){
        $task=New-TaskFixture $service
        switch($case){
            'ps-file' {$task.Actions[0].Arguments='-NoProfile -File "'+$scriptPath+'"'}
            'bat-file' {$task.Actions[0].Execute=$batchPath;$task.Actions[0].Arguments=''}
            'cmd-file' {$task.Actions[0].Execute='cmd.exe';$task.Actions[0].Arguments='/d /c "'+$batchPath+'"'}
            'cmd-inline' {$task.Actions[0].Execute='cmd.exe';$task.Actions[0].Arguments='/c "net stop "'+$service+'" && net start "'+$service+'""'}
            'encoded' {$task.Actions[0].Arguments='-EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(('Restart-Service -Name '''+$service+'''')))}
            'scriptblock' {$task.Actions[0].Arguments='-Command "& {Restart-Service -Name '''+$service+'''}"'}
        }
        $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:fixtureTasks=@($task)
        Invoke-PaymentRestartTaskCheck NETS $service
        Assert-TaskCheck ($auditRows[0].Status -eq 'Pass') ('Supported static action failed: '+$case+' '+$auditRows[0].FoundStateHtml)
    }
    Assert-TaskCheck ((Get-FileHash -LiteralPath $scriptPath).Hash -eq $scriptHash -and (Get-FileHash -LiteralPath $batchPath).Hash -eq $batchHash) 'Task scripts were modified.'
    $finalizer=$ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount,$IsFinal)}
    function Start-AuditStep {param($Number,$Name)}
    $outputFolder=Split-Path $fixtureRoot -Parent;$client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $deviceType='KIOSK';$reportKioskId='Kiosk-1';$KioskId=$null;$kioskUser='SELISE-KIOSK';$reportHostname='SAMPLE-KIOSK01';$clientLocation='Sample branch';$runId='TASK-FIXTURE'
    foreach($mode in @('Audit','Apply','Final')){
        $script:ApplyChanges=$mode -eq 'Apply';$FinalReport=$mode -eq 'Final'
        $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:fixtureTasks=@(New-TaskFixture $service)
        Invoke-PaymentRestartTaskCheck NETS $service
        $rowJson=$auditRows.ToArray() | ConvertTo-Json -Depth 8 -Compress
        $reportPath=Join-Path $outputFolder ($client+'-'+$mode+'.html')
        . $render
        $html=[KioskTestSource]::ReadAllText($reportPath)
        if($mode -eq 'Apply'){
            Assert-TaskCheck ($html.Contains('No fixes required.') -and -not $html.Contains('device-title">Payment Service Restart Task</div>')) 'Fix retained an unchanged compliant restart task.'
        }else{
            $view=if($mode -eq 'Audit'){Get-AuditRenderedComponent $html 'Payment Service Restart Task'}else{Get-SettingRenderedComponent $html 'Payment Service Restart Task'}
            Assert-TaskCheck ($view.Count -eq 1) 'Task component was duplicated or omitted.'
            $expected=@('Task Name','Task Status','Target','Trigger Time','Last Run','Next Run')
            Assert-TaskCheck (($view.Fields.Setting -join '|') -ceq ($expected -join '|')) 'Task field order changed.'
            Assert-TaskCheck ($view.Text.Contains('Custom Payment & Gateway') -and $view.Text.Contains('Nightly Payment <Restart> & Check')) 'Task identity or selected-service target was lost.'
            if($mode -eq 'Audit'){
                Assert-TaskCheck ($view.Commands -contains 'taskschd.msc' -and $view.Html -match 'Matches required configuration') 'Audit lost task commands or comparison evidence.'
            }else{
                Assert-TaskCheck (-not $view.Commands.Count -and $view.Html -notmatch 'finding-value finding-') 'Final retained repair commands or semantic highlights.'
            }
        }
        Assert-TaskCheck (($auditRows.ToArray() | ConvertTo-Json -Depth 8 -Compress) -ceq $rowJson) 'Rendering changed task observations.'
    }
    Write-Output ('PASS: '+$sourceName+' provider/mode matrix; enabled/disabled/missing/expired/unknown/ambiguous actions; literal PowerShell/batch/encoded scripts; no task or service mutations.')
}
