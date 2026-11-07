# In-memory fixtures only: never start real device checks or installers.
[CmdletBinding()]
param([string]$ReleaseId='20261022-not-verified-amber-01')
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')

$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$entryPath=Join-Path $projectRoot ('output\releases\'+$ReleaseId+'\Start-DeviceManagement.ps1')
$entry=[KioskTestSource]::ReadAllText($entryPath)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($entry,[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw ($errors | Out-String)}
$resourceNode=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$resources'},$true))
if ($resourceNode.Count -ne 1) {throw 'Expected one embedded resource map.'}
$resourceAst=[Management.Automation.Language.Parser]::ParseInput($resourceNode[0].Right.Extent.Text,[ref]$tokens,[ref]$errors)
$resources=$resourceAst.EndBlock.Statements[0].PipelineElements[0].Expression.SafeGetValue()
$bundle=@{Files=@{};Configurations=@{}}
foreach ($name in $resources.Keys) {$bundle.Files[$name]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($resources[$name].Data))}
foreach ($name in @('Clients','Operations','PaymentPackages','KioskClients')) {
    $configAst=[Management.Automation.Language.Parser]::ParseInput($bundle.Files['DeviceManagement/Config/'+$name+'.psd1'],[ref]$tokens,[ref]$errors)
    $bundle.Configurations[$name]=$configAst.EndBlock.Statements[0].PipelineElements[0].Expression.SafeGetValue()
}
$runtime=$bundle.Files['Deployment/MemoryRuntime.ps1']
. ([scriptblock]::Create($runtime))
function Assert-Memory {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('DeviceManagement-MemoryTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$previousRoot=$env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT
$previousScenario=$env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO
$env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT=$fixtureRoot
$log=Join-Path $fixtureRoot 'calls.jsonl'
$fixture=@'
[CmdletBinding()]
param([string]$ClientType,[switch]$Apply,[switch]$AuditOnly,[switch]$FinalReport,[string]$DeviceType,[switch]$ArchitectureRun,[string]$ArchitectureResultPath,[string]$ClientLocation,[string]$AgentName)
$script:FixtureCount++
[IO.File]::AppendAllText((Join-Path $env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT 'calls.jsonl'),(([pscustomobject]@{Client=$ClientType;Apply=[bool]$Apply;Audit=[bool]$AuditOnly;Final=[bool]$FinalReport;Device=$DeviceType;Architecture=[bool]$ArchitectureRun;CompletionFile=$ArchitectureResultPath;Branch=$ClientLocation;Agent=$AgentName;Count=$script:FixtureCount;PID=$PID} | ConvertTo-Json -Compress)+[Environment]::NewLine))
$global:LASTEXITCODE=12345
if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -eq 'throw') {throw 'Fixture refused to start.'}
if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -eq 'incomplete') {return}
$report=$null
if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -in @('report','failed-report','missing-file','wrong-folder')) {
    $report=Join-Path $env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT (('exact-'+$ClientType+'-')+[guid]::NewGuid().ToString('N')+'.html')
    if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -eq 'wrong-folder') {$report=Join-Path (Join-Path $env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT 'other') 'wrong.html';[void][IO.Directory]::CreateDirectory((Split-Path $report -Parent))}
    if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -ne 'missing-file') {[IO.File]::WriteAllText($report,'<!DOCTYPE html><html><body>Fixture report</body></html>')}
}
$exitCode=if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -in @('failed','failed-report')) {1} else {0}
$result=[pscustomobject]@{MemoryCheckCompleted=$true;ExitCode=$exitCode;ReportPath=$report}
$result
if ($env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO -eq 'duplicate') {$result}
'@
foreach ($client in @('SaaS','Subway')) {
    $name='DeviceManagement/KioskThoroughCheck.ps1'
    $bundle.Files[$name]=$fixture.Replace('@@CLIENT@@',$client)
}
# Prevent any real installation during menu fixtures, including unexpected routes.
foreach($client in @('SaaS','Subway')) {
    $bundle.Files['DeviceManagement/Installations/KIOSK/Install.ps1']='param($Context) throw ''Unexpected installation fixture route; no setup executed.'''
}
$bundle.Files['DeviceManagement/OtherTools/PaymentCronJob.ps1']=@'
param([switch]$MenuRun)
$answer=Read-Host 'Enable SIX Cron? [Y/N]'
Write-Host ('CRON_FIXTURE_RESULT='+$answer)
[pscustomobject]@{Status='Skipped';ReturnToMenu=($answer -eq 'N')}
'@
$bundle.Files['DeviceManagement/OtherTools/KioskMaintenance.ps1']=@'
param($ToolId,[switch]$MenuRun,$ProjectRoot)
Write-Host ('MAINTENANCE_FIXTURE_ID='+$ToolId)
[pscustomobject]@{Status='Pass';ReturnToMenu=$false}
'@
$bundle.Files['DeviceManagement/Core/Context.psm1']=$bundle.Files['DeviceManagement/Core/Context.psm1'].Replace("'C:\Thorough Check'",'$env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT')
# ConsoleHost suppresses Read-Host prompt text when stdin is redirected. Trace
# entry to the real pause statement while retaining the actual nested prompt.
$pause="[void](Read-Host '  Press Enter to return to Other Tools')"
$bundle.Files['DeviceManagement/Start-DeviceManagement.ps1']=$bundle.Files['DeviceManagement/Start-DeviceManagement.ps1'].Replace($pause,("Write-Host 'CRON_RESULT_PAUSE'; "+$pause))
[void][IO.Directory]::CreateDirectory((Join-Path $projectRoot 'output/payment-cron-job'))
$menu=$bundle.Files['DeviceManagement/Start-DeviceManagement.ps1']
$menuAst=[Management.Automation.Language.Parser]::ParseInput($menu,[ref]$tokens,[ref]$errors)
$screen=@($menuAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$screen'})[0]
$initialization=$menu.Substring(0,$screen.Extent.StartOffset)
$callAst=[Management.Automation.Language.Parser]::ParseInput($initialization,[ref]$tokens,[ref]$errors)
$start=$callAst.ParamBlock.Extent.StartOffset
$end=$callAst.ParamBlock.Extent.EndOffset
$attributes=$callAst.ParamBlock.Attributes
if ($attributes.Count) {$start=$attributes[0].Extent.StartOffset}
$initialization=$initialization.Remove($start,$end-$start)
$callCode='param([string]$Client,[string]$Mode,[string]$Device=''KIOSK'',[string]$OperationId=''ThoroughCheck'',[string]$Browser=''Edge'')'+"`r`n"+$initialization+@'
$validated=Assert-RunSelection -ClientsConfiguration $clientsConfiguration -OperationsConfiguration $operationsConfiguration -ClientId $Client -Device $Device -OperationId $OperationId -Mode $Mode
$context=New-DeviceManagementContext -ClientType $Client -DeviceType $Device -Operation $OperationId -Mode $Mode -Browser $Browser -ClientLocation 'Branch with spaces & apostrophe '' preserved' -AgentName 'Agent & O''Brien <fixture>' -RootPath $architectureRoot
Invoke-ConfiguredOperation -RootPath $architectureRoot -Operation $validated.Operation -Context $context
'@
$originalExitCode=$global:LASTEXITCODE
try {
    $forbidden=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Invoke-WebRequest','Invoke-RestMethod','Expand-Archive','New-Item','Out-File','Start-Process','Remove-Item')},$true))
    Assert-Memory ($forbidden.Count -eq 0) 'Entry still downloads/writes/extracts a project or starts a child process.'
    foreach ($client in @('SaaS','Subway')) {
        foreach ($mode in @('Audit','Apply','Final')) {
            foreach ($scenario in @('report','failed-report','no-report','failed','incomplete','duplicate','throw','missing-file','wrong-folder')) {
                $env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO=$scenario
                $execution=Invoke-DeviceManagementMemoryScript -Code $callCode -Bundle $bundle -RuntimeCode $runtime -Parameters @{Client=$client;Mode=$mode}
                Assert-Memory ($execution.State -eq 'Completed') ('Dispatcher pipeline failed: '+$execution.Failure+' '+($execution.Errors | Out-String))
                $results=@($execution.Output)
                Assert-Memory ($results.Count -eq 1) 'Expected exactly one operation result.'
                $expected=if ($scenario -eq 'report' -or ($mode -eq 'Audit' -and $scenario -eq 'no-report')) {'Pass'} else {'Fail'}
                Assert-Memory ($results[0].Status -eq $expected) ("$client/$mode/$scenario expected $expected; got "+($results | Out-String))
                if ($scenario -in @('report','failed-report')) {Assert-Memory ($results[0].Message -match 'Report: .+exact-') 'Exact returned report was lost.'}
            }
            Write-Output ('PASS: '+$client+'/'+$mode+' named flags, report/decline/failure/partial/missing/duplicate/wrong-path completion boundaries')
        }
    }
    $calls=@(Get-Content -LiteralPath $log | ForEach-Object {$_ | ConvertFrom-Json})
    Assert-Memory ($calls.Count -eq 54) 'Unexpected number of client source calls.'
    foreach ($call in $calls) {
        Assert-Memory ($call.Architecture -and -not $call.CompletionFile -and $call.Device -eq 'KIOSK') 'Architecture context wrote a completion file or lost device type.'
        Assert-Memory (@($call.Apply,$call.Audit,$call.Final | Where-Object {$_}).Count -eq 1) 'Audit/Apply/Final flags were mixed.'
        Assert-Memory ($call.Count -eq 1 -and $call.PID -eq $PID) 'Client state leaked between operations or a child process was used.'
        Assert-Memory ($call.Branch -eq 'Branch with spaces & apostrophe '' preserved') 'Audit/Apply/Final branch context changed.'
        Assert-Memory ($call.Agent -ceq 'Agent & O''Brien <fixture>') 'Audit/Apply/Final agent context changed.'
    }
    Assert-Memory ($global:LASTEXITCODE -eq $originalExitCode) 'Client native exit state leaked to caller.'
    $before=$calls.Count
    foreach ($selection in @(@{Client='SaaS';Mode='Audit';Device='POS'},@{Client='Subway';Mode='Apply';OperationId='PaymentService'})) {
        $execution=Invoke-DeviceManagementMemoryScript -Code $callCode -Bundle $bundle -RuntimeCode $runtime -Parameters $selection
        Assert-Memory ($execution.Output.Count -eq 1 -and $execution.Output[0].Status -eq 'Unavailable') 'Pending operation was not guarded.'
    }
    Assert-Memory (@(Get-Content -LiteralPath $log).Count -eq $before) 'Pending operation reached a client source.'
    Write-Output 'PASS: Pending operations blocked; client state and caller exit state isolated; no completion files.'
    $oldData=$resources['Deployment/MemoryRuntime.ps1'].Data
    $newData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('# corrupted runtime'))
    $corrupt=$entry.Replace($oldData,$newData)
    $caught=$false
    try {& ([scriptblock]::Create($corrupt))} catch {$caught=$_.Exception.Message -match 'resource verification failed'}
    Assert-Memory $caught 'Embedded resource corruption was not rejected.'
    Write-Output 'PASS: corrupted embedded resource rejected before execution.'

    # Exercise real nested ConsoleHost prompts and repeated navigation. Only the
    # two client bodies and report destination are fixtures; menu/modules are real.
    $promptFixture=$fixture.Replace('$script:FixtureCount++', '$script:FixtureCount++; if ($Apply) { $answer=Read-Host ''Fixture source hostname''; Write-Host (''FIXTURE_HOSTNAME='' + $answer) }')
    foreach ($client in @('SaaS','Subway')) {
        $name='DeviceManagement/KioskThoroughCheck.ps1'
        $bundle.Files[$name]=$promptFixture.Replace('@@CLIENT@@',$client)
    }
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach ($name in $bundle.Files.Keys) {
        $bytes=[Text.Encoding]::UTF8.GetBytes($bundle.Files[$name])
        $hasher=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','')} finally {$hasher.Dispose()}
        $lines.Add(("'{0}' = @{{Data='{1}';SHA256='{2}'}}" -f $name,[Convert]::ToBase64String($bytes),$hash))
    }
    $literal='@{'+"`r`n"+($lines -join "`r`n")+"`r`n}"
    $interactive=[KioskTestSource]::ReadAllText((Join-Path $projectRoot 'Deployment\Bootstrap.ps1.template')).Replace('@@RESOURCES@@',$literal)
    $interactivePath=Join-Path $fixtureRoot 'interactive.ps1'
    [IO.File]::WriteAllText($interactivePath,($interactive+"`r`n"+'Write-Output ''MEMORY_RETURNED_TO_CALLER'''),(New-Object Text.UTF8Encoding($false)))
    $env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO='no-report'
    $inputs=@('invalid','1','1','2','1','1','','Interactive Agent','','Interactive Branch','5','8','2','HOST-FROM-PROMPT','3','2','1','1','1','SaaS Agent','SaaS Branch','0')
    $ui=$inputs | & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1 | Out-String
    Assert-Memory ($LASTEXITCODE -eq 0 -and $ui -match 'MEMORY_RETURNED_TO_CALLER' -and $ui -match 'FIXTURE_HOSTNAME=HOST-FROM-PROMPT' -and $ui -match 'Subway > KIOSK > Thorough Check' -and $ui -match 'SaaS > KIOSK > Thorough Check') ('Interactive memory navigation failed: '+$ui)
    $newCalls=@(Get-Content -LiteralPath $log | Select-Object -Skip $before | ForEach-Object {$_ | ConvertFrom-Json})
    Assert-Memory ($newCalls.Count -eq 3 -and $newCalls[0].Client -eq 'Subway' -and $newCalls[0].Audit -and $newCalls[0].Branch -eq 'Interactive Branch' -and $newCalls[1].Apply -and $newCalls[1].Branch -eq 'Interactive Branch' -and $newCalls[2].Client -eq 'SaaS' -and $newCalls[2].Audit -and $newCalls[2].Branch -eq 'SaaS Branch') 'Audit input was not forwarded, reused in Apply or isolated across clients.'
    Assert-Memory ($newCalls[0].Agent -ceq 'Interactive Agent' -and $newCalls[1].Agent -ceq 'Interactive Agent' -and $newCalls[2].Agent -ceq 'SaaS Agent') 'Agent input was not forwarded, reused in Apply or isolated across clients.'
    Assert-Memory ([regex]::Matches($ui,'This option is not available yet').Count -eq 1) 'Unavailable selections advanced to another screen.'
    Assert-Memory ($ui -match '\[2\] Payment Service \(Not available\)' -and $ui -notmatch 'KIOSK Installation \(Not available\)') 'Installation readiness or pending payment label is incorrect.'
    Assert-Memory ($ui -match 'Invalid selection. Enter a displayed option number.' -and $ui -match 'Invalid selection. Enter 2, 3, 8 or 0.') 'Invalid menu/navigation input was not explained.'
    Assert-Memory ($ui -notmatch 'Review settings. HTML report is optional.|Apply the agreed repairs and verify results.|Select mode:|Select device:|Select operation:') 'Removed help text or inconsistent input prompts remain.'
    Write-Output 'PASS: full menu, unavailable/invalid input stays in place, Back/Main Menu/repeated clients, nested Read-Host, branch input and caller return.'
    foreach($quickClient in @(@{Key='1';Name='Subway'},@{Key='2';Name='SaaS'})) {
        $beforeQuick=@(Get-Content -LiteralPath $log).Count
        $quickInputs=@($quickClient.Key,'1','1','1','Quick Agent','Quick Branch','2','QUICK-HOST','0')
        $quickUi=$quickInputs|& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1|Out-String
        $quickCalls=@(Get-Content -LiteralPath $log|Select-Object -Skip $beforeQuick|ForEach-Object {$_|ConvertFrom-Json})
        Assert-Memory ($LASTEXITCODE -eq 0 -and $quickUi -match 'MEMORY_RETURNED_TO_CALLER' -and $quickUi -match 'FIXTURE_HOSTNAME=QUICK-HOST' -and $quickUi -notmatch 'Invalid selection') 'Direct Audit-footer Apply did not complete and return'
        Assert-Memory ($quickCalls.Count -eq 2 -and $quickCalls[0].Audit -and $quickCalls[1].Apply) 'Audit footer must run exactly Audit then Apply'
        Assert-Memory (@($quickCalls|Where-Object {$_.Client -ne $quickClient.Name -or $_.Branch -ne 'Quick Branch' -or $_.Agent -ne 'Quick Agent' -or $_.Device -ne 'KIOSK'}).Count -eq 0) 'Audit footer lost the selected client, device, branch or agent'
        Assert-Memory ([regex]::Matches($quickUi,'\[2\] Apply Fix\s+\[3\] Main Menu').Count -eq 1) 'Apply shortcut must appear only on the completed Audit footer'
    }
    Write-Output 'PASS: both clients Audit footer runs Apply directly with retained context; Apply result retains ordinary navigation.'
    $env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO='incomplete'
    $failedStartInputs=@('2','1','1','1','Fixture Agent','Fixture Branch','2','0')
    $failedStartUi=$failedStartInputs|& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1|Out-String
    Assert-Memory ($LASTEXITCODE -eq 0 -and $failedStartUi -match 'Invalid selection. Enter 3, 8 or 0.' -and $failedStartUi -notmatch '\[2\] Apply Fix\s+\[3\] Main Menu') 'Failed startup offered a direct Apply shortcut'
    $env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO='no-report'
    foreach($answer in @('N','Y')){
        $toolInputs=if($answer -eq 'N'){@('4','1','N','8','0')}else{@('4','1','Y','','8','0')}
        $toolUi=$toolInputs|& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1|Out-String
        [IO.File]::WriteAllText((Join-Path $projectRoot ('output/payment-cron-job/menu-'+$answer+'.txt')),$toolUi,[Text.UTF8Encoding]::new($false))
        Assert-Memory ($LASTEXITCODE -eq 0 -and $toolUi -match ('CRON_FIXTURE_RESULT='+$answer) -and $toolUi -match '\[4\] Other Tools' -and $toolUi -match 'Other Tools > Payment Cron Job' -and $toolUi -notmatch '\[1\] Check Schedules|\[2\] Enable SIX Cron') 'Other Tools did not use the automatic check/fix prompt route'
        Assert-Memory (($toolUi -match 'CRON_RESULT_PAUSE') -eq ($answer -eq 'Y') -and $toolUi -notmatch 'Invalid selection') 'Decline did not return directly or confirmed result was cleared without a pause'
    }
    foreach($toolChoice in @(
        @{Key='2';Id='KioskLauncherTask';Title='Kiosk Launcher Task Scheduler'},
        @{Key='3';Id='ZabbixInstaller';Title='Zabbix Installer'},
        @{Key='4';Id='NmapInstaller';Title='Nmap Installer'}
    )){
        $beforeTool=@(Get-Content -LiteralPath $log).Count
        $toolInputs=@('4',$toolChoice.Key,'','8','0')
        $toolUi=$toolInputs|& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1|Out-String
        Assert-Memory ($LASTEXITCODE -eq 0 -and $toolUi.Contains('MAINTENANCE_FIXTURE_ID='+$toolChoice.Id) -and $toolUi.Contains('Other Tools > '+$toolChoice.Title) -and $toolUi -notmatch 'Invalid selection') 'Maintenance tool menu routed to the wrong handler or lost return navigation'
        Assert-Memory (@(Get-Content -LiteralPath $log).Count -eq $beforeTool) 'Maintenance tool unexpectedly invoked a full kiosk check'
    }
    Write-Output 'PASS: all four Other Tools entries, selected maintenance handlers, Payment Cron Y/N, result pause and Back/Main Menu/Exit; only harmless tool fixtures executed.'
    foreach($clientChoice in @(@{Key='1';Client='Subway'},@{Key='2';Client='SaaS'})) {
        $beforeFinal=@(Get-Content -LiteralPath $log).Count
        $finalInputs=@($clientChoice.Key,'1','1','3','0')
        $finalUi=$finalInputs | & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1 | Out-String
        Assert-Memory ($LASTEXITCODE -eq 0 -and $finalUi -match 'MEMORY_RETURNED_TO_CALLER') 'Final menu did not return to its caller.'
        $finalCalls=@(Get-Content -LiteralPath $log | Select-Object -Skip $beforeFinal | ForEach-Object {$_ | ConvertFrom-Json})
        Assert-Memory ($finalCalls.Count -eq 0) 'Removed Final selection ran a device check.'
        Assert-Memory ($finalUi -notmatch '\[3\] Thorough Check Report\s*\r?\n' -and $finalUi -match '\[1\] Audit Report' -and $finalUi -match '\[2\] Apply Fix' -and $finalUi -match 'Invalid selection. Enter a displayed option number.') 'The terminal menu did not retain only Audit and Apply Fix.'
        [IO.File]::WriteAllText((Join-Path $projectRoot ('Docs\Validation\final-report-'+$clientChoice.Client+'-menu.txt')),$finalUi,(New-Object Text.UTF8Encoding($false)))
        Write-Output ('PASS: '+$clientChoice.Client+' terminal offers Audit and Apply Fix; removed Final input runs no device check.')
    }
    # Installation is always a fixture, including real interactive menu routing.
    $installCallerExit=$global:LASTEXITCODE
    $installationName='DeviceManagement/Installations/KIOSK/Install.ps1'
    $installFixture=@'
param($Context)
if($Context.ClientType -notin @('SaaS','Subway')){throw 'Wrong installation source selected.'}
$script:InstallationFixtureCount++
[IO.File]::AppendAllText((Join-Path $env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT 'install-calls.jsonl'),(([pscustomobject]@{Client=$Context.ClientType;Device=$Context.DeviceType;Operation=$Context.Operation;Mode=$Context.Mode;Browser=$Context.Browser;Count=$script:InstallationFixtureCount;PID=$PID} | ConvertTo-Json -Compress)+[Environment]::NewLine))
$global:LASTEXITCODE=765
switch($env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO) {
    'throw' {throw 'Installation fixture refused to start.'}
    'missing' {return}
    'error' {Write-Error 'Installation fixture error' -ErrorAction Continue}
    'interactive' {
        $user=Read-Host 'Kiosk User [SELISE-KIOSK]'
        $restaurant=Read-Host 'Restaurant ID'
        $kiosk=Read-Host 'Kiosk ID'
        $hostname=Read-Host 'Hostname [DEVICE-KIOSK01]'
        Write-Host ('INSTALL_INPUTS='+(@($user,$restaurant,$kiosk,$hostname) -join '|'))
    }
}
$result=[pscustomobject]@{Status=$(if($env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO -eq 'fail'){'Fail'}else{'Pass'});Message=($Context.ClientType+' KIOSK Installation fixture completed.');Context=$Context}
if($env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO -eq 'invalid'){$result.Status='Unknown'}
$result
if($env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO -eq 'duplicate'){$result}
'@
    foreach($client in @('SaaS','Subway')){$bundle.Files['DeviceManagement/Installations/KIOSK/Install.ps1']=$installFixture.Replace('@@INSTALLCLIENT@@',$client)}
    $oldInstallScenario=$env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO
    try {
        foreach($installClient in @('SaaS','Subway')) {
            foreach($browser in @('Edge')) {
                foreach($scenario in @('pass','fail','throw','missing','duplicate','invalid','error')) {
                    $env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO=$scenario
                    $execution=Invoke-DeviceManagementMemoryScript -Code $callCode -Bundle $bundle -RuntimeCode $runtime -Parameters @{Client=$installClient;Mode='Apply';Browser=$browser;OperationId='KioskInstallation'}
                    $expected=if($scenario -eq 'pass'){'Pass'}else{'Fail'}
                    Assert-Memory ($execution.State -eq 'Completed' -and $execution.Output.Count -eq 1 -and $execution.Output[0].Status -eq $expected) ('Installation dispatch/completion failed: '+$installClient+'/'+$browser+'/'+$scenario)
                    $lastCall=Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
                    Assert-Memory ($lastCall.Browser -eq $browser -and $lastCall.Client -eq $installClient -and $lastCall.Count -eq 1) 'Browser/client context was lost across the installation runspace.'
                }
            }
        }
        $callsBefore=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count
        foreach($selection in @(@{Client='Subway';Mode='Audit';OperationId='KioskInstallation'},@{Client='SaaS';Mode='Audit';OperationId='KioskInstallation'})) {
            $execution=Invoke-DeviceManagementMemoryScript -Code $callCode -Bundle $bundle -RuntimeCode $runtime -Parameters $selection
            Assert-Memory ($execution.Output.Count -eq 1 -and $execution.Output[0].Status -eq 'Unavailable') 'Another selection reached installation.'
        }
        Assert-Memory (@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count -eq $callsBefore) 'Unsupported installation started a handler.'
        $savedHandler=$bundle.Files[$installationName];$bundle.Files.Remove($installationName)
        $execution=Invoke-DeviceManagementMemoryScript -Code $callCode -Bundle $bundle -RuntimeCode $runtime -Parameters @{Client='SaaS';Mode='Apply';OperationId='KioskInstallation'}
        Assert-Memory ($execution.Output.Count -eq 1 -and $execution.Output[0].Status -eq 'Fail') 'Missing installation resource was not rejected.'
        $bundle.Files[$installationName]=$savedHandler
        Assert-Memory ($global:LASTEXITCODE -eq $installCallerExit) 'Installation exit state leaked to caller.'
        $env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO='interactive'
        $lines.Clear()
        foreach($name in $bundle.Files.Keys) {
            $bytes=[Text.Encoding]::UTF8.GetBytes($bundle.Files[$name])
            $hasher=[Security.Cryptography.SHA256]::Create()
            try{$hash=[BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','')}finally{$hasher.Dispose()}
            $lines.Add(("'{0}' = @{{Data='{1}';SHA256='{2}'}}" -f $name,[Convert]::ToBase64String($bytes),$hash))
        }
        $literal='@{'+"`r`n"+($lines -join "`r`n")+"`r`n}"
        $interactive=[KioskTestSource]::ReadAllText((Join-Path $projectRoot 'Deployment\Bootstrap.ps1.template')).Replace('@@RESOURCES@@',$literal)
        [IO.File]::WriteAllText($interactivePath,($interactive+"`r`n"+'Write-Output ''MEMORY_RETURNED_TO_CALLER'''),(New-Object Text.UTF8Encoding($false)))
        foreach($clientKey in @('2','1')) {
            foreach($browserKey in @('1','2')) {
                $expectedBrowser='Edge'
                $callsBeforeChoice=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count
                # The removed option 2 must be rejected before selecting Edge.
                $browserInputs=if($browserKey -eq '2'){@('2','1')}else{@('1')}
                $installInputs=@($clientKey,'1','3','invalid')+$browserInputs+@('SELISE-KIOSK','RESTAURANT-99','Kiosk-9','HOST-99','8','8','0')
                $installUi=$installInputs | & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1 | Out-String
                Assert-Memory ($LASTEXITCODE -eq 0 -and $installUi -match 'INSTALL_INPUTS=SELISE-KIOSK\|RESTAURANT-99\|Kiosk-9\|HOST-99' -and $installUi -match 'MEMORY_RETURNED_TO_CALLER') 'Browser installation menu/input/return failed.'
                Assert-Memory ($installUi -match 'Select Kiosk Browser' -and $installUi -match '\[1\] Microsoft Edge' -and $installUi -notmatch 'Chrome') 'Edge-only kiosk browser choice was not displayed.'
                Assert-Memory ($installUi -notmatch 'KIOSK Installation \(Not available\)|Select Mode|Branch Name') 'Installation used the old unavailable/mode/branch path.'
                $lastCall=Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
                Assert-Memory ($lastCall.Browser -eq $expectedBrowser) 'Interactive browser choice did not reach the handler.'
                Assert-Memory (@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count -eq ($callsBeforeChoice+1)) 'Removed browser option started an installation.'
                if($browserKey -eq '2'){Assert-Memory ([regex]::Matches($installUi,'Invalid selection').Count -ge 2) 'Removed option 2 was not rejected.'}
            }
            $callsBeforeCancel=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count
            foreach($cancelInputs in @(@($clientKey,'1','3','0'),@($clientKey,'1','3','8','0'),@($clientKey,'1','3','2','0'))) {
                $cancelUi=$cancelInputs | & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1 | Out-String
                Assert-Memory ($LASTEXITCODE -eq 0 -and $cancelUi -match 'MEMORY_RETURNED_TO_CALLER' -and $cancelUi -notmatch 'INSTALL_INPUTS=') 'Browser Back/Exit started setup.'
            }
            Assert-Memory (@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count -eq $callsBeforeCancel) 'Browser cancellation reached an installer.'
        }
        $switchBefore=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl')).Count
        $switchInputs=@('2','1','3','2','1','SELISE-KIOSK','R1','K1','HOST1','8','2','1','SELISE-KIOSK','R2','K2','HOST2','0')
        $switchUi=$switchInputs | & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $interactivePath 2>&1 | Out-String
        $switchCalls=@(Get-Content -LiteralPath (Join-Path $fixtureRoot 'install-calls.jsonl') | Select-Object -Skip $switchBefore | ForEach-Object {$_ | ConvertFrom-Json})
        Assert-Memory ($LASTEXITCODE -eq 0 -and $switchCalls.Count -eq 2 -and $switchCalls[0].Browser -eq 'Edge' -and $switchCalls[1].Browser -eq 'Edge') 'Result Back did not retain Edge-only setup.'
        [IO.File]::WriteAllText((Join-Path $projectRoot 'Docs\Validation\saas-kiosk-installation-menu.txt'),$installUi,(New-Object Text.UTF8Encoding($false)))
        Write-Output 'PASS: SaaS/Subway isolated installation sources, Edge menu/four prompts, removed browser option rejected, verified/failed/missing/duplicate/error outcomes, mode isolation, Back/Exit and caller return. Only fixtures executed.'
    } finally { $env:DEVICE_MANAGEMENT_MEMORY_INSTALL_SCENARIO=$oldInstallScenario }
} finally {
    $env:DEVICE_MANAGEMENT_MEMORY_TEST_ROOT=$previousRoot
    $env:DEVICE_MANAGEMENT_MEMORY_TEST_SCENARIO=$previousScenario
    if ((Split-Path $fixtureRoot -Parent) -ceq ([IO.Path]::GetTempPath()).TrimEnd('\') -and (Split-Path $fixtureRoot -Leaf) -match '^DeviceManagement-MemoryTest-[a-f0-9]{32}$') {Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}
