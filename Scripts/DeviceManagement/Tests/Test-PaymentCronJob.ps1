
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Synthetic services and real disposable JSON bytes only. Never inspect a device service.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$root=Join-Path $projectRoot ('output/payment-cron-job/fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$exe=Join-Path $root 'Kiosk Payment Middleware.exe';$config=Join-Path $root 'appsettings.json'
[IO.File]::WriteAllText($exe,'Fixture executable - never run')
$path=Join-Path $projectRoot 'OtherTools/PaymentCronJob.ps1'
$tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
. ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
$realWrite=(Get-Command Write-PaymentCronBytes).ScriptBlock
$realRead=(Get-Command Read-PaymentCronBytes).ScriptBlock
function Assert-Cron {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)
    if($ClassName -eq 'Win32_Service'){$script:Services;return}
    if($ClassName -eq 'Win32_Process'){
        Assert-Cron ($Filter -eq 'ProcessId = 444') 'Unexpected process query'
        if($script:ProcessMode -eq 'missing'){return}
        [pscustomobject]@{ExecutablePath=$(if($script:ProcessMode -eq 'mismatch'){'C:\Other\host.exe'}else{$exe});CommandLine=$(if($script:ProcessMode -eq 'arguments'){'"'+$exe+'" --contentRoot C:\Other'}elseif($script:ProcessMode -eq 'unknown'){''}else{'"'+$exe+'"'})};return
    }
    throw 'Unexpected device query'
}
function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction)
    if($script:Linked -and $LiteralPath -eq $root){return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
}
function Test-PaymentCronAdministrator {$script:Admin}
function Write-PaymentCronBytes {param([IO.Stream]$Stream,[byte[]]$Bytes)
    Assert-Cron ($Stream.Name -eq $config) 'A write escaped the fixture file'
    $script:Writes++
    if(($script:Fault -eq 'partial' -and $script:Writes -eq 1) -or $script:Fault -eq 'restore-failed'){$Stream.Position=0;$Stream.WriteByte(0);throw 'Fixture partial write failure'}
    & $realWrite $Stream $Bytes
}
function Read-PaymentCronBytes {param([IO.Stream]$Stream)
    $script:Reads++;$bytes=& $realRead $Stream
    if($script:Fault -eq 'readback' -and $script:Reads -eq 3){$bytes[0]=0}
    ,$bytes
}
function Read-Host {param($Prompt)
    $script:Prompts.Add($Prompt)
    if($script:Answers.Count -eq 0){throw ('Unexpected prompt: '+$Prompt)}
    $script:Answers.Dequeue()
}
function Start-Process {throw 'Process execution is forbidden'}
# Runtime behavior is covered separately; these fixtures isolate JSON mutation.
function Confirm-PaymentCronRuntime {param($Context,$Snapshot) [pscustomobject]@{Status='Verified'}}
function Restart-Service {throw 'Service restart is forbidden'}
function Stop-Service {throw 'Service stop is forbidden'}
function Start-Service {throw 'Service start is forbidden'}
function Copy-Item {throw 'Backup creation is forbidden'}
function Set-Content {throw 'JSON serialization writes are forbidden'}
function Reset-Cron {
    $script:Admin=$true;$script:Linked=$false;$script:Fault='';$script:ProcessMode='';$script:Writes=0;$script:Reads=0;$script:WhatIfPreference=$false
    $script:Services=@([pscustomobject]@{Name='AspPaymentFixture';DisplayName='Payment Middleware';State='Running';PathName=('"'+$exe+'"');ProcessId=444})
    $script:Answers=[Collections.Generic.Queue[string]]::new();$script:Prompts=[Collections.Generic.List[string]]::new()
}
$json=@'
{
  // Keep comments, spacing, duplicate UIDs across providers and unrelated values.
  "IsEnabled": false,
  "Secret": "KEEP-PRIVATE-unchanged",
  "Decoy": {"Provider":"SIX","IsEnabled":false},
  "Unicode": "UNICODE",
  "Number": -1.234e+42,
  "ScheduleConfiguration": {
    "Schedules": [
      {"Provider":"NETS","Name":"Cron for nets payment balance","UID":"nets-uid","CronExpression":"0 3 * * *","IsEnabled":true},
      {"Provider":"SIX","Name":"Cron for six payment balance","UID":"same-uid","CronExpression":"0 3 * * *","IsEnabled": false /* six only */},
      {"Provider":"NEXIDE","Name":"Cron for nexi de payment balance","UID":"same-uid","CronExpression":"0 3 * * *","IsEnabled":false},
      {"Provider":"KitchenTicketPrint","BranchUUID":"keep-this","IsEnabled":false},
    ],
  },
  "String": "false SIX // not a comment /* still string */ \"quoted\" \\ slash",
}
'@
$json=$json.Replace('UNICODE',([string][char]0x00E9+[char]0x09AC+[char]0x09BE))
$expected=$json.Replace('"IsEnabled": false /* six only */','"IsEnabled": true /* six only */')
$encodings=@([Text.UTF8Encoding]::new($false,$true),[Text.UTF8Encoding]::new($true,$true),[Text.UnicodeEncoding]::new($false,$true,$true),[Text.UnicodeEncoding]::new($true,$true,$true),[Text.UTF32Encoding]::new($false,$true,$true),[Text.UTF32Encoding]::new($true,$true,$true))
$cases=0
foreach($encoding in $encodings){foreach($newline in @("`n","`r`n")){
    Reset-Cron
    $text=$json.Replace("`r`n","`n").Replace("`n",$newline)
    $wanted=$expected.Replace("`r`n","`n").Replace("`n",$newline)
    [byte[]]$before=$encoding.GetPreamble()+$encoding.GetBytes($text)
    [byte[]]$after=$encoding.GetPreamble()+$encoding.GetBytes($wanted)
    [IO.File]::WriteAllBytes($config,$before)
    $context=Get-PaymentCronServiceContext $script:Services[0]
    $snapshot=Read-PaymentCronSnapshot $config
    Assert-Cron ($snapshot.Model.Records.Count -eq 3 -and $snapshot.Model.Six.Count -eq 1 -and $snapshot.Model.Six[0].IsEnabled -eq $false) 'Incorrect schedule scope or Boolean handling'
    $actual=Enable-PaymentCronSix $context $snapshot
    Assert-Cron ((Test-PaymentCronBytesEqual $after ([IO.File]::ReadAllBytes($config))) -and $actual.Model.Six[0].IsEnabled -eq $true) 'Bytes outside SIX flag, encoding, BOM, comments or line endings changed'
    [void](Enable-PaymentCronSix $context $actual)
    Assert-Cron ($script:Writes -eq 1) 'Repeated Apply wrote again'
    $cases++
}}
$invalid=@(
    '{', '[]', '{}', '{"ScheduleConfiguration":{"Schedules":null}}',
    '{"ScheduleConfiguration":{"Schedules":[]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"NETS","IsEnabled":false}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX"}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":"false"}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":null}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":0}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":False}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":false,"isenabled":true}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","\u0050rovider":"NETS","IsEnabled":false}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":"SIX","IsEnabled":false},{"Provider":"SIX","IsEnabled":false}]}}',
    '{"ScheduleConfiguration":{"Schedules":[false]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"IsEnabled":false}]}}',
    '{"ScheduleConfiguration":{"Schedules":[{"Provider":" SIX ","IsEnabled":false}]}}',
    '{"bad":01,"ScheduleConfiguration":{"Schedules":[]}}',
    '{"bad":"\uXXXX","ScheduleConfiguration":{"Schedules":[]}}',
    '{"bad":"\q","ScheduleConfiguration":{"Schedules":[]}}',
    '/* unterminated', '{} trailing', '{}{}', ('{"deep":'+('['*66)+'0'+(']'*66)+'}')
)
foreach($text in $invalid){
    Reset-Cron;[IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false));$before=[IO.File]::ReadAllBytes($config)
    $script:Answers.Enqueue('Y');$result=Invoke-PaymentCronJob
    Assert-Cron ($result.Status -eq 'Fail' -and $script:Writes -eq 0 -and $script:Prompts.Count -eq 0) 'Invalid or ambiguous JSON authorized a fix or prompted for it'
    Assert-Cron (Test-PaymentCronBytesEqual $before ([IO.File]::ReadAllBytes($config))) 'Invalid configuration changed'
    $cases++
}
foreach($case in @('decline','invalid-then-decline','already','yes','no-admin','whatif','stopped','no-service','process-mismatch','process-missing','process-arguments','process-unknown','arguments','relative','hosted','linked','changed-file','changed-process','busy','partial','readback','restore-failed','missing-file','invalid-utf8')){
    Reset-Cron;[IO.File]::WriteAllText($config,$json,[Text.UTF8Encoding]::new($false))
    if($case -eq 'already'){[IO.File]::WriteAllText($config,$expected,[Text.UTF8Encoding]::new($false))}
    $before=[IO.File]::ReadAllBytes($config)
    switch($case){
        'no-admin' {$script:Admin=$false}
        'whatif' {$script:WhatIfPreference=$true}
        'stopped' {$script:Services[0].State='Stopped'}
        'no-service' {$script:Services=@()}
        'process-mismatch' {$script:ProcessMode='mismatch'}
        'process-missing' {$script:ProcessMode='missing'}
        'process-arguments' {$script:ProcessMode='arguments'}
        'process-unknown' {$script:ProcessMode='unknown'}
        'arguments' {$script:Services[0].PathName+=' --contentRoot C:\Other'}
        'relative' {$script:Services[0].PathName='relative.exe'}
        'hosted' {$script:Services[0].PathName='C:\Windows\System32\cmd.exe'}
        'linked' {$script:Linked=$true}
        {$_ -in @('partial','readback','restore-failed')} {$script:Fault=$case}
        'missing-file' {[IO.File]::Move($config,($config+'.fixture-hidden'))}
        'invalid-utf8' {[IO.File]::WriteAllBytes($config,[byte[]]@(123,255,125));$before=[IO.File]::ReadAllBytes($config)}
    }
    if($case -in @('changed-file','changed-process','busy')){
        $context=Get-PaymentCronServiceContext $script:Services[0];$snapshot=Read-PaymentCronSnapshot $config
        $lock=$null
        try{
            if($case -eq 'changed-file'){[IO.File]::AppendAllText($config,' ');$before=[IO.File]::ReadAllBytes($config)}
            if($case -eq 'changed-process'){$script:Services[0].ProcessId=445}
            if($case -eq 'busy'){$lock=[IO.FileStream]::new($config,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
            $caught=$false;try{[void](Enable-PaymentCronSix $context $snapshot)}catch{$caught=$true}
            Assert-Cron ($caught -and $script:Writes -eq 0) ('Concurrent or busy input was written: '+$case)
        }finally{if($lock){$lock.Dispose()}}
    }else{
        if($case -eq 'invalid-then-decline'){$script:Answers.Enqueue('invalid')}
        $script:Answers.Enqueue($(if($case -in @('decline','invalid-then-decline')){'N'}else{'Y'}))
        $result=Invoke-PaymentCronJob
        $expectedStatus=if($case -in @('decline','invalid-then-decline')){'Skipped'}elseif($case -in @('already','yes')){'Pass'}else{'Fail'}
        Assert-Cron ($result.Status -eq $expectedStatus) ('Incorrect terminal result: '+$case)
        if($expectedStatus -eq 'Skipped'){Assert-Cron $result.ReturnToMenu 'Decline did not return directly to Other Tools'}
        if($case -eq 'already'){Assert-Cron ($script:Prompts.Count -eq 0 -and $script:Writes -eq 0) 'Already true acquired a fix prompt or write'}
    }
    if($case -eq 'missing-file'){[IO.File]::Move(($config+'.fixture-hidden'),$config)}
    if($case -eq 'yes'){Assert-Cron ([KioskTestSource]::ReadAllText($config) -ceq $expected) 'Confirmed fix did not preserve the exact text'}
    elseif($case -ne 'restore-failed'){Assert-Cron (Test-PaymentCronBytesEqual $before ([IO.File]::ReadAllBytes($config))) ('Unexpected bytes after failure/decline: '+$case)}
    if($case -in @('partial','readback')){Assert-Cron ($script:Writes -eq 2) 'Failed write was not restored from memory'}
    $cases++
}
Reset-Cron
# Real service discovery must ignore stopped and unrelated services.
$script:Services+=@([pscustomobject]@{Name='AspPaymentStopped';DisplayName='Payment Middleware';State='Stopped';PathName=('"'+$exe+'"');ProcessId=0},[pscustomobject]@{Name='OtherService';DisplayName='Other';State='Running';PathName='C:\Other.exe';ProcessId=555})
Assert-Cron (@(Get-PaymentCronRunningServices).Count -eq 1) 'Discovery selected a stopped or unrelated service'
[IO.File]::WriteAllText($config,$json,[Text.UTF8Encoding]::new($false))
$script:Services=@($script:Services[0],([pscustomobject]@{Name='AspPaymentSecond';DisplayName='Payment Middleware';State='Running';PathName=('"'+$exe+'"');ProcessId=444}))
$script:Answers.Enqueue('2');$script:Answers.Enqueue('N');$result=Invoke-PaymentCronJob
Assert-Cron ($result.Status -eq 'Skipped' -and $script:Prompts.Count -eq 2 -and $script:Writes -eq 0) 'Multiple running services were guessed or ignored selection'
$files=@(Get-ChildItem -LiteralPath $root -File)
Assert-Cron ($files.Count -eq 2) 'Tool created a backup, temporary file or report'
Import-Module (Join-Path $projectRoot 'Core/Context.psm1') -Force
$runContext=New-DeviceManagementContext -ClientType SaaS -DeviceType KIOSK -Operation ThoroughCheck -Mode Audit -RootPath $projectRoot
Assert-Cron ($runContext.ReportFolder -ceq 'C:\Thorough Check') 'Launcher report location is not C:\Thorough Check'
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $source=Join-Path $projectRoot $name
    $sourceAst=[KioskTestSource]::ParseFile($source,[ref]$tokens,[ref]$errors)
    $assignment=@($sourceAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$outputFolder'},$true))
    Assert-Cron ($assignment.Count -eq 1) 'Client report root is ambiguous'
    . ([scriptblock]::Create($assignment[0].Extent.Text))
    $pathFunction=$sourceAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-KioskReportPath'},$true)
    . ([scriptblock]::Create($pathFunction.Extent.Text))
    $report=Get-KioskReportPath -Folder $outputFolder -Client Fixture -Computer FIXTURE-PC -RunId Test
    Assert-Cron ((Split-Path $report -Parent) -ceq $runContext.ReportFolder -and [KioskTestSource]::ReadAllText($source).Contains("`$BackupFolder='C:\Thorough Check\Restore Points'")) 'Client report/restore paths do not match launcher lookup'
}
Import-Module (Join-Path $projectRoot 'Core/PackageLoader.psm1') -Force
$localRoot=Join-Path $projectRoot ('output/payment-cron-job/dispatcher-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $localRoot 'OtherTools'))
$localTool=Join-Path $localRoot 'OtherTools/PaymentCronJob.ps1'
foreach($case in @('valid','missing-output','duplicate-output','invalid-output')){
    $code=switch($case){'valid'{'param([switch]$MenuRun) if(-not $MenuRun){throw "Menu context missing"};[pscustomobject]@{Status="Skipped";ReturnToMenu=$true}'};'missing-output'{'param([switch]$MenuRun) return'};'duplicate-output'{'param([switch]$MenuRun) 1;2'};'invalid-output'{'param([switch]$MenuRun) [pscustomobject]@{Status="Pass";ReturnToMenu="unverified"}'}}
    [IO.File]::WriteAllText($localTool,$code)
    $caught=$false;$result=$null;try{$result=Invoke-DeviceManagementOtherTool -RootPath $localRoot -ToolId PaymentCronJob}catch{$caught=$true}
    Assert-Cron ($caught -eq ($case -ne 'valid')) ('Local dispatcher accepted invalid completion: '+$case)
    if($case -eq 'valid'){Assert-Cron ($result.Status -eq 'Skipped' -and $result.ReturnToMenu) 'Local tool result lost its immediate return'}
    $cases++
}
$toolText=[KioskTestSource]::ReadAllText($path)
$entry=$toolText.LastIndexOf('$result=Invoke-PaymentCronJob',[StringComparison]::Ordinal)
foreach($status in @('Pass','Fail')){
    $stub='function Invoke-PaymentCronJob { [pscustomobject]@{Status="'+$status+'";ReturnToMenu=$false} }'+"`n"
    $standalone=Join-Path $localRoot ('standalone-'+$status+'.ps1')
    [IO.File]::WriteAllText($standalone,$toolText.Insert($entry,$stub),[Text.UTF8Encoding]::new($false))
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $standalone
    Assert-Cron ($LASTEXITCODE -eq $(if($status -eq 'Fail'){1}else{0})) 'Standalone completion did not propagate its actual status'
    $cases++
}
Write-Output ('PASS: '+$cases+' Payment Cron Job cases; exact byte preservation across six encodings, comments/decoys, invalid/ambiguous JSON, Y/N, idempotence, service identity, concurrent changes, locks, partial-write restore, no extra files and C-drive report paths.')
