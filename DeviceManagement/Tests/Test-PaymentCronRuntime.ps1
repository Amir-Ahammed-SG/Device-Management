# All service/process/control operations are fixtures. Native Restart Manager
# smoke check queries only this test process's own disposable open log file.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$root=Join-Path $projectRoot ('output/payment-cron-runtime/fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$exe=Join-Path $root 'Kiosk Payment Middleware.exe';$path=Join-Path $root 'appsettings.json';$log=Join-Path $root 'Payment_Middleware_fixture.txt'
[IO.File]::WriteAllText($exe,'Fixture only - never run')
$tokens=$null;$errors=$null
$source=Join-Path $projectRoot 'OtherTools/PaymentCronJob.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
. ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
$realOwners=(Get-Command Get-PaymentCronLogOwners).ScriptBlock
$realConfirm=(Get-Command Confirm-PaymentCronRuntime).ScriptBlock
$realWait=(Get-Command Wait-PaymentCronServiceState).ScriptBlock
$realWrite=(Get-Command Write-PaymentCronBytes).ScriptBlock
function Assert-Runtime {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$json='{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","Name":"Cron six [fixture]","UID":"shared-uid","CronExpression":"0 3 * * *","IsEnabled":true},{"Provider":"NETS","Name":"Nets","UID":"shared-uid","CronExpression":"0 3 * * *","IsEnabled":false},{"Provider":"Other","Name":"Other","UID":"other-uid","CronExpression":"* * * * *","IsEnabled":true}]}}'
function Reset-Runtime {
    $script:Mode='success';$script:Admin=$true;$script:WhatIfPreference=$false;$script:Stops=0;$script:Starts=0;$script:ServiceReads=0;$script:Writes=0
    $script:Created=[datetime]::UtcNow.AddMinutes(-10);$script:OriginalCreated=$script:Created
    $script:Service=[pscustomobject]@{Name='AspPaymentRuntimeFixture';DisplayName='Payment Middleware';State='Running';PathName=('"'+$exe+'"');ProcessId=444}
    $script:Answers=[Collections.Generic.Queue[string]]::new();$script:Prompts=[Collections.Generic.List[string]]::new()
    [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($log,"old registration must never count`r`n",[Text.UTF8Encoding]::new($false))
}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction)
    if($ClassName -eq 'Win32_Service'){
        $script:ServiceReads++
        if($script:Mode -eq 'crash' -and $script:ServiceReads -ge 6){$script:Service.State='Stopped'}
        if($script:Mode -eq 'process-switch' -and $script:ServiceReads -ge 6){$script:Service.ProcessId=777}
        $script:Service;return
    }
    if($ClassName -eq 'Win32_Process'){
        Assert-Runtime ($Filter -eq ('ProcessId = '+$script:Service.ProcessId)) 'Process query did not target the selected service'
        [pscustomobject]@{ExecutablePath=$exe;CommandLine=('"'+$exe+'"');CreationDate=$script:Created};return
    }
    throw 'Unexpected native query'
}
function Get-PaymentCronLogFiles {
    if($script:Mode -eq 'no-logs'){return}
    if($script:Mode -eq 'baseline-denied' -and $script:Starts -eq 0){throw 'Fixture log access denied'}
    Get-Item -LiteralPath $log
}
function Get-PaymentCronLogOwners {param($Path)
    if($script:Mode -eq 'owners-denied'){throw 'Fixture ownership unavailable'}
    $owner=[pscustomobject]@{Pid=$(if($script:Mode -eq 'wrong-owner'){999}else{$script:Service.ProcessId});StartedUtc=$(if($script:Mode -eq 'stale-owner'){$script:OriginalCreated}else{$script:Created})}
    $owner
    if($script:Mode -eq 'multiple-owners'){[pscustomobject]@{Pid=999;StartedUtc=$script:Created}}
}
function Test-PaymentCronAdministrator {$script:Admin}
function Read-Host {param($Prompt)
    $script:Prompts.Add($Prompt)
    if($script:Answers.Count -eq 0){throw ('Unexpected fixture prompt: '+$Prompt)}
    $script:Answers.Dequeue()
}
function Wait-PaymentCronServiceState {param($Name,$State,$TimeoutSeconds=30) & $realWait -Name $Name -State $State -TimeoutSeconds 0}
function Confirm-PaymentCronRuntime {param($Context,$Snapshot) & $realConfirm -Context $Context -Snapshot $Snapshot -VerificationSeconds 0 -StableSeconds 0}
function Write-PaymentCronBytes {param($Stream,$Bytes)
    Assert-Runtime ($Stream.Name -eq $path) 'Configuration write escaped the fixture'
    $script:Writes++;& $realWrite $Stream $Bytes
}
function Invoke-CimMethod {param($InputObject,$MethodName,$OperationTimeoutSec,$ErrorAction)
    Assert-Runtime ($InputObject.Name -ceq 'AspPaymentRuntimeFixture') 'An unselected service was controlled'
    if($MethodName -eq 'StopService'){
        $script:Stops++
        if($script:Mode -eq 'stop-refused'){return [pscustomobject]@{ReturnValue=3}}
        $script:Service.State=if($script:Mode -eq 'stop-timeout'){'Stop Pending'}else{'Stopped'}
        if($script:Mode -eq 'stop-rpc-failed'){throw 'Fixture lost stop response after stopping'}
        return [pscustomobject]@{ReturnValue=0}
    }
    Assert-Runtime ($MethodName -eq 'StartService') 'Unexpected service mutation'
    $script:Starts++
    if($script:Mode -eq 'start-failed' -or ($script:Mode -eq 'start-recovery' -and $script:Starts -eq 1)){return [pscustomobject]@{ReturnValue=2}}
    $script:Service.State=if($script:Mode -eq 'start-timeout'){'Start Pending'}else{'Running'}
    $script:Service.ProcessId=if($script:Mode -eq 'pid-reuse'){444}else{555}
    if($script:Mode -ne 'old-process'){$script:Created=[datetime]::UtcNow.AddSeconds(-1)}
    if($script:Mode -eq 'config-changed-after'){[IO.File]::AppendAllText($path,' ')}
    $stamp=$script:Created.AddMilliseconds(200)
    if($script:Mode -eq 'stale-log'){$stamp=$script:OriginalCreated}
    if($script:Mode -eq 'future-log'){$stamp=[datetime]::UtcNow.AddMinutes(10)}
    $time=([DateTimeOffset]$stamp).ToString('yyyy-MM-dd HH:mm:ss.fff zzz',[Globalization.CultureInfo]::InvariantCulture)
    $message='++Registering schedule: Cron six [fixture] (shared-uid)'
    if($script:Mode -eq 'wrong-uid'){$message=$message.Replace('shared-uid','other-uid')}
    if($script:Mode -eq 'wrong-name'){$message=$message.Replace('Cron six [fixture]','Nets')}
    $level=if($script:Mode -eq 'wrong-level'){'WRN'}else{'INF'}
    $lines=$time+' ['+$level+'] '+$message+"`r`n"
    if($script:Mode -ne 'incomplete-log'){$lines+=$time+" [INF] ++Schdules successfully registered...`r`n"}
    if($script:Mode -eq 'startup-error'){$lines+=$time+" [ERR] Host terminated unexpectedly.`r`n"}
    if($script:Mode -eq 'truncated-log'){[IO.File]::WriteAllText($log,'')}
    else{[IO.File]::AppendAllText($log,$lines,[Text.UTF8Encoding]::new($false))}
    [pscustomobject]@{ReturnValue=0}
}
function Restart-Service {throw 'Unbounded/forced restart is forbidden'}
function Stop-Service {throw 'Unbounded/dependent service stop is forbidden'}
function Start-Service {throw 'Unbounded start is forbidden'}
function Stop-Process {throw 'Process killing is forbidden'}
function Start-Process {throw 'Process execution is forbidden'}
function Copy-Item {throw 'Backup creation is forbidden'}
$cases=0
foreach($mode in @('success','pid-reuse','decline','invalid-decline','no-admin','whatif','process-changed','config-changed','uid-conflict','no-start-time','stop-refused','stop-rpc-failed','stop-timeout','start-failed','start-recovery','start-timeout','old-process','crash','process-switch','config-changed-after','no-logs','baseline-denied','owners-denied','wrong-owner','multiple-owners','stale-owner','stale-log','future-log','wrong-uid','wrong-name','wrong-level','incomplete-log','startup-error','truncated-log')){
    Reset-Runtime;$script:Mode=$mode
    $context=Get-PaymentCronServiceContext $script:Service;$snapshot=Read-PaymentCronSnapshot $path
    switch($mode){
        'no-admin' {$script:Admin=$false}
        'whatif' {$script:WhatIfPreference=$true}
        'process-changed' {$script:Service.ProcessId=555}
        'config-changed' {[IO.File]::AppendAllText($path,' ')}
        'uid-conflict' {$snapshot.Model.AllSchedules[1].IsEnabled=$true}
        'no-start-time' {$context.StartedUtc=$null}
        'invalid-decline' {$script:Answers.Enqueue('invalid')}
    }
    $script:ServiceReads=0
    $script:Answers.Enqueue($(if($mode -in @('decline','invalid-decline')){'N'}else{'Y'}))
    $result=Confirm-PaymentCronRuntime $context $snapshot
    $expected=if($mode -in @('success','pid-reuse')){'Verified'}elseif($mode -in @('decline','invalid-decline','no-logs','baseline-denied','owners-denied','wrong-owner','multiple-owners','stale-owner','stale-log','future-log','wrong-uid','wrong-name','wrong-level','incomplete-log','truncated-log')){'Pending'}else{'Failed'}
    Assert-Runtime ($result.Status -eq $expected) ('Incorrect runtime verification: '+$mode+' / '+$result.Status)
    if($mode -in @('decline','invalid-decline','no-admin','whatif','process-changed','config-changed','uid-conflict','no-start-time')){Assert-Runtime ($script:Stops -eq 0 -and $script:Starts -eq 0) ('Unsafe restart: '+$mode)}
    if($mode -eq 'stop-refused'){Assert-Runtime ($script:Stops -eq 1 -and $script:Starts -eq 0) 'Refused stop forced a dependent service'}
    if($mode -eq 'start-recovery'){Assert-Runtime ($script:Starts -eq 2 -and $script:Service.State -eq 'Running') 'Failed start did not attempt selected-service recovery'}
    if($mode -eq 'stop-rpc-failed'){Assert-Runtime ($script:Starts -eq 1 -and $script:Service.State -eq 'Running') 'Lost stop response left a confirmed stopped service without recovery'}
    Assert-Runtime ($script:Writes -eq 0) 'Restart verification rewrote configuration'
    $wanted=if($mode -in @('config-changed','config-changed-after')){$json+' '}else{$json}
    Assert-Runtime ([IO.File]::ReadAllText($path) -ceq $wanted) ('Runtime verification changed file bytes: '+$mode)
    $cases++
}
foreach($enabled in @($false,$true)){
    foreach($answer in @('N','Y')){
        Reset-Runtime
        if(-not $enabled){[IO.File]::WriteAllText($path,$json.Replace('"IsEnabled":true},{"Provider":"NETS"','"IsEnabled":false},{"Provider":"NETS"'),[Text.UTF8Encoding]::new($false));$script:Answers.Enqueue('Y')}
        $script:Answers.Enqueue($answer)
        $result=Invoke-PaymentCronJob
        Assert-Runtime ($result.Status -eq $(if($answer -eq 'Y'){'Pass'}else{'Skipped'}) -and $result.RuntimeStatus -eq $(if($answer -eq 'Y'){'Verified'}else{'Pending'})) 'Main flow lost runtime status or reported an unverified result as Pass'
        Assert-Runtime ($script:Stops -eq $(if($answer -eq 'Y'){1}else{0}) -and $script:Writes -eq $(if($enabled){0}else{1})) 'Main flow changed restart/write scope'
        Assert-Runtime (@($script:Prompts|Where-Object {$_ -match '^  Enable SIX'}).Count -eq $(if($enabled){0}else{1})) 'Already enabled configuration acquired a fix prompt'
        $cases++
    }
}
foreach($provider in @('NETS','KitchenTicketPrint')){
    Reset-Runtime
    $conflict=$json.Replace('"Provider":"NETS"',('"Provider":"'+$provider+'"')).Replace('"IsEnabled":false},{"Provider":"Other"','"IsEnabled":true},{"Provider":"Other"')
    [IO.File]::WriteAllText($path,$conflict,[Text.UTF8Encoding]::new($false));$script:Answers.Enqueue('Y')
    $result=Invoke-PaymentCronJob
    Assert-Runtime ($result.Status -eq 'Fail' -and $script:Prompts.Count -eq 0 -and $script:Writes -eq 0 -and $script:Stops -eq 0) 'Enabled shared UID was not blocked before prompts/mutations'
    $cases++
}
foreach($field in @('Name','UID','CronExpression')){
    Reset-Runtime
    $broken=$json.Replace(('"'+$field+'":"'+$(switch($field){'Name'{'Cron six [fixture]'};'UID'{'shared-uid'};'CronExpression'{'0 3 * * *'}})+'"'),('"'+$field+'":""'))
    [IO.File]::WriteAllText($path,$broken,[Text.UTF8Encoding]::new($false));$result=Invoke-PaymentCronJob
    Assert-Runtime ($result.Status -eq 'Fail' -and $script:Prompts.Count -eq 0 -and $script:Stops -eq 0 -and $script:Writes -eq 0) 'Incomplete SIX identity was enabled or restarted'
    $cases++
}
# Validate the real, read-only Windows owner API without controlling any service.
$owned=Join-Path $root 'owned-log.txt';$stream=[IO.FileStream]::new($owned,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{
    $owners=@(& $realOwners $owned)
    Assert-Runtime (@($owners|Where-Object Pid -EQ $PID).Count -eq 1) 'Native log-owner query did not identify this fixture process'
}finally{$stream.Dispose()}
Write-Output ('PASS: '+$cases+' runtime cases; explicit Y/N, selected-service control, restart/recovery/timeouts, fresh process-owned registration evidence, ambiguity/staleness/errors, unchanged JSON, main flow and native read-only log-owner query. No real service was controlled.')
