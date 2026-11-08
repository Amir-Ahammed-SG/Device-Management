
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Read-only fixture JSON and real report rendering; no services or device APIs.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$previewRoot=Join-Path $projectRoot 'output\payout-scheduler'
$fixtureRoot=Join-Path $previewRoot ('fixtures-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Payout {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-PayoutConfiguration {
    param([string]$Provider)
    [pscustomobject]@{
        PaymentService=$Provider
        PaymentConfiguration=[pscustomobject]@{
            SixTerminals=@([pscustomobject]@{KioskId='Kiosk-1';TerminalId='SIX-001';Currency='CHF';LogDirectory='C:\Sample\Logs';IsDeferredInitiation=$false})
            NetsTerminals=@([pscustomobject]@{PosId='POS-01';KioskId='Kiosk-1';TerminalIPAddress='192.0.2.20';TerminalId='';Currency='CHF';Language='en';IsSetupEnabled=$false})
        }
        ScheduleConfiguration=[pscustomobject]@{Schedules=@(
            [pscustomobject]@{Provider='KitchenTicketPrint';BranchUUID='00000000000000000000000000000001';IsKioskPrintingEnabled=$false;IsEnabled=$true},
            [pscustomobject]@{Provider='SIX';Name='Do not report SIX name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$false},
            [pscustomobject]@{Provider='NETS';Name='Do not report NETS name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$true},
            [pscustomobject]@{Provider='NEXIDE';Name='Do not report NEXIDE name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$false}
        )}
        Print=[pscustomobject]@{PrinterName='Kitchen & Receipt';KioskPrinterName='EPSON Receipt'}
        MonitoringServiceBaseUrl='https://example.test/monitor';CmsGatewayBaseUrl='https://example.test/cms';OrderServiceBaseUrl='https://example.test/orders'
    }
}
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
$caseCount=0
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Payout ($errors.Count -eq 0) 'Client source failed parsing'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Set-Content {throw 'Configuration writes are forbidden'}
    function Set-Service {throw 'Service changes are forbidden'}
    function Restart-Service {throw 'Service restarts are forbidden'}
    function Copy-Item {throw 'Configuration backups are forbidden'}
    function Get-CimInstance {throw 'Rendering queried the device'}
    $script:ApplyChanges=$false
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $identity=[pscustomobject]@{ReportId='OMK-244001';GeneratedAt='04 Nov 2026, 1:20 PM BST';AgentName='Fixture Agent'}
    $historical='<div class="config-item-title">[Schedule 1]</div>'+(ConvertTo-ReportDefinitionHtml ([ordered]@{Provider='SIX';IsEnabled=$false}))+'<div class="config-item-title">Schedule 02</div>'+(ConvertTo-ReportDefinitionHtml ([ordered]@{Provider='NEXIDE';IsEnabled=$true}))
    $normalized=Format-ThoroughReportFieldLabels $historical
    $headings=@([regex]::Matches($normalized,'<div class="config-item-title">([^<]+)</div>')|ForEach-Object {$_.Groups[1].Value})
    Assert-Payout (($headings -join '|') -ceq 'SIX Terminal|NETS Terminal' -and $normalized.Contains('Provider:</span> NEXIDE')) 'Saved schedule headings were renamed by ordinal or changed actual provider data'
    foreach($case in @('SIX','NETS','NEXIDE','PRINT','unknown','case-insensitive','missing-match','missing-flag','empty-flag','multiple','direct','array','empty-schedules','missing-branch','empty-branch','multiple-kitchen','branch-case')){
        $provider=switch($case){'case-insensitive'{' nEtS '};'unknown'{'OTHER'};{$_ -in @('SIX','NETS','NEXIDE','PRINT')}{$_};default{'NETS'}}
        $config=New-PayoutConfiguration $provider
        switch($case){
            'missing-match' {$config.ScheduleConfiguration.Schedules=@($config.ScheduleConfiguration.Schedules|Where-Object Provider -NE 'NETS')}
            'missing-flag' {($config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'NETS').PSObject.Properties.Remove('IsEnabled')}
            'empty-flag' {($config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'NETS').IsEnabled=''}
            'multiple' {$config.ScheduleConfiguration.Schedules+=@([pscustomobject]@{Provider='NETS';IsEnabled=$false})}
            'direct' {$config.ScheduleConfiguration=$config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'NETS'}
            'array' {$config.ScheduleConfiguration=$config.ScheduleConfiguration.Schedules}
            'empty-schedules' {$config.ScheduleConfiguration.Schedules=@()}
            'missing-branch' {($config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'KitchenTicketPrint').PSObject.Properties.Remove('BranchUUID')}
            'empty-branch' {($config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'KitchenTicketPrint').BranchUUID=''}
            'multiple-kitchen' {$config.ScheduleConfiguration.Schedules+=@([pscustomobject]@{Provider='KitchenTicketPrint';BranchUUID='00000000000000000000000000000002';IsKioskPrintingEnabled=$true;IsEnabled=$false})}
            'branch-case' {
                $kitchen=$config.ScheduleConfiguration.Schedules|Where-Object Provider -EQ 'KitchenTicketPrint'
                $kitchen.PSObject.Properties.Remove('BranchUUID');$kitchen|Add-Member NoteProperty branchUuid 'branch & <fixture>'
            }
        }
        # Deliberate decoys must never replace the value in the kitchen schedule.
        $config|Add-Member NoteProperty BranchUUID 'DO-NOT-USE-ROOT-BRANCH'
        $config.Print|Add-Member NoteProperty BranchUUID 'DO-NOT-USE-PRINT-BRANCH'
        foreach($schedule in @($config.ScheduleConfiguration.Schedules)){
            if($schedule -and $schedule.Provider -in @('SIX','NETS','NEXIDE')){$schedule|Add-Member NoteProperty BranchUUID 'DO-NOT-USE-PAYMENT-BRANCH' -Force}
        }
        $path=Join-Path $fixtureRoot ($client+'-'+$case+'-appsettings.json')
        [IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $snapshot=ConvertFrom-ThoroughPaymentJson ([KioskTestSource]::ReadAllText($path))
        $before=$snapshot|ConvertTo-Json -Depth 12 -Compress
        $source=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';ItemSub='Type: Read-only Configuration Inspection';Shortcut=(New-ReportCommand @('notepad.exe "'+$path+'"'));ConfigurationSnapshot=$snapshot;ConfigurationServiceName='SamplePayment';ConfigurationPath=$path;Status='Pass';FoundStateHtml='Fixture';ActionTaken='Fixture'}
        $rows=@(Get-ThoroughAppSettingsReportRows $source)
        $lines=@(Get-ThoroughPaymentConfigurationAuditLines $snapshot 'SamplePayment' $path)
        $lineText=$lines -join "`n"
        Assert-Payout ((Get-ThoroughReportComponentName 'ScheduleConfiguration') -ceq 'WebApp Printer' -and (Get-ThoroughReportComponentName 'Payout Scheduler') -ceq 'Cron Job') 'Requested component names are missing'
        Assert-Payout ($lineText -match 'WebApp Printer(?: \d+)?:' -and $lineText -match 'Kitchen Printer:' -and $lineText -match 'Kiosk/POS Printer:' -and $lineText -notmatch 'WebApp/Shop Print|Payout Scheduler|Do not report') ('Raw collection labels or selected fields are incorrect: '+$client+'/'+$case+'; '+$lineText)
        $webRow=@($rows|Where-Object ItemTitle -EQ 'ScheduleConfiguration')[0]
        $branchValues=@([regex]::Matches($webRow.FoundStateHtml,'BranchUUID:</span>\s*([^<]*)')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
        $kitchenUnavailable=$case -in @('direct','missing-branch','empty-branch','empty-schedules')
        $expectedBranches=if($case -eq 'multiple-kitchen'){@('00000000000000000000000000000001','00000000000000000000000000000002')}elseif($case -eq 'branch-case'){@('branch & <fixture>')}elseif($case -eq 'empty-branch'){@('(empty)')}elseif($kitchenUnavailable){@('Not configured')}else{@('00000000000000000000000000000001')}
        Assert-Payout (($branchValues -join '|') -ceq ($expectedBranches -join '|') -and $webRow.FoundStateHtml -notmatch 'DO-NOT-USE') 'WebApp BranchUUID came from an unrelated path, lost its record identity or was omitted'
        Assert-Payout (($webRow.Status -eq 'Fail') -eq $kitchenUnavailable) 'Missing BranchUUID or valid False settings changed collection status incorrectly'
        $payout=@($rows|Where-Object ItemTitle -EQ 'Payout Scheduler')
        $supported=$case -notin @('PRINT','unknown')
        if(-not $supported){Assert-Payout ($payout.Count -eq 0 -and $lineText -notmatch 'Cron Job') 'An unsupported provider acquired Cron Job data'}
        else{
            Assert-Payout ($payout.Count -eq 1) 'Cron Job component is missing or duplicated'
            $payout=$payout[0]
            $terminal=if($provider.Trim().ToUpperInvariant() -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'}
            $count=if($case -eq 'multiple'){2}else{1}
            $headings=@([regex]::Matches($payout.FoundStateHtml,'<div class="config-item-title">([^<]+)</div>')|ForEach-Object {$_.Groups[1].Value})
            Assert-Payout ($headings.Count -eq $count -and -not @($headings|Where-Object {$_ -cne $terminal}).Count -and $payout.FoundStateHtml -notmatch '\[?Schedule \d') 'Cron Job headings depend on array position instead of provider family'
            $missing=$case -in @('missing-match','missing-flag','empty-flag','empty-schedules')
            Assert-Payout (($payout.Status -eq 'Fail') -eq $missing) 'A False flag or absent schedule changed collection status'
            $fields=@(Read-ThoroughAuditFields $payout.FoundStateHtml|Where-Object Kind -EQ 'Field')
            Assert-Payout (($fields.Label -join '|') -ceq $(if($count -eq 2){'Provider|IsEnabled|Provider|IsEnabled'}else{'Provider|IsEnabled'})) 'Cron Job collected unexpected properties'
            if($case -notin @('missing-match','empty-schedules')){
                $selected=$provider.Trim().ToUpperInvariant()
                Assert-Payout (-not @($fields|Where-Object {$_.Label -eq 'Provider' -and $_.Text.Trim().ToUpperInvariant() -cne $selected}).Count) 'An unrelated payment provider was included'
            }
        }
        $reports=[ordered]@{}
        foreach($mode in @('Audit','Fix','Final')){
            $report=New-ThoroughReportSnapshot -Rows @($source) -BeforeRows @($source) -DisplayMode $mode -AfterApply:($mode -ne 'Audit') -AuditSource $identity -DeviceType KIOSK -Hostname FIXTURE-PC -LauncherKioskId Kiosk-1 -LauncherRestaurantId RESTAURANT-1 -AgentName 'Fixture Agent'
            $reports[$mode]=$report
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($report.HtmlBase64))
            Assert-Payout ($html -notmatch 'DO-NOT-USE-') 'A BranchUUID decoy leaked into the report'
            Assert-Payout ($html -notmatch '>WebApp/Shop Print<|>Payout Scheduler<|>PrinterName<|>KioskPrinterName<|>Schedule 0[12]<|Do not report') 'A report contains an old label or unrequested schedule data'
            if($mode -eq 'Audit'){
                $web=Get-AuditRenderedComponent $html 'WebApp Printer';$print=Get-AuditRenderedComponent $html Printer;$cron=Get-AuditRenderedComponent $html 'Cron Job'
                Assert-Payout ($web.Count -eq 1 -and $print.Count -eq 1 -and $cron.Count -eq [int]$supported) 'Audit component names or provider visibility are incorrect'
                $displayBranches=@($web.Fields|Where-Object Setting -EQ 'BranchUUID'|ForEach-Object {$_.Found})
                Assert-Payout (($displayBranches -join '|') -ceq ($expectedBranches -join '|')) 'Audit omitted or changed the collected kitchen BranchUUID'
                Assert-Payout (@($print.Fields|Where-Object {$_.Setting -eq 'Kitchen Printer' -and $_.Found -eq 'Kitchen & Receipt'}).Count -eq 1 -and @($print.Fields|Where-Object {$_.Setting -eq 'Kiosk/POS Printer' -and $_.Found -eq 'EPSON Receipt'}).Count -eq 1) 'Friendly printer labels lost their original JSON values'
                if($supported){Assert-Payout ($cron.Headings.Count -eq $count -and -not @($cron.Headings|Where-Object {$_ -cne $terminal}).Count) 'Audit lost the fixed provider-family headings'}
            }elseif($mode -eq 'Final'){
                $cron=Get-SettingRenderedComponent $html 'Cron Job';$print=Get-SettingRenderedComponent $html Printer
                $webFinal=Get-SettingRenderedComponent $html 'WebApp Printer'
                $displayBranches=@($webFinal.Fields|Where-Object Setting -EQ 'BranchUUID'|ForEach-Object {$_.Value})
                Assert-Payout (($displayBranches -join '|') -ceq ($expectedBranches -join '|')) 'Final omitted or changed the collected kitchen BranchUUID'
                Assert-Payout ($cron.Count -eq [int]$supported -and @($print.Fields|Where-Object {$_.Setting -eq 'Kitchen Printer' -and $_.Value -eq 'Kitchen & Receipt'}).Count -eq 1) 'Final lost component names or actual printer values'
                if($supported){Assert-Payout ($cron.Headings.Count -eq $count -and -not @($cron.Headings|Where-Object {$_ -cne $terminal}).Count) 'Final lost the fixed provider-family headings'}
            }else{
                $webFix=Get-SettingRenderedComponent $html 'WebApp Printer'
                if($kitchenUnavailable){
                    Assert-Payout ($webFix.Count -eq 1 -and -not @($webFix.Fields|Where-Object Value -NE 'Not applied').Count) 'Fix hid a missing BranchUUID or claimed a configuration repair'
                    $displayBranches=@($webFix.Fields|Where-Object Setting -EQ 'BranchUUID'|ForEach-Object {$_.Findings})
                    Assert-Payout (($displayBranches -join '|') -ceq ($expectedBranches -join '|')) 'Fix lost the original missing BranchUUID observation'
                }
                else{Assert-Payout ($webFix.Count -eq 0) 'A complete WebApp Printer record appeared in Fix'}
                $cron=Get-SettingRenderedComponent $html 'Cron Job'
                if($supported -and $missing){Assert-Payout ($cron.Count -eq 1 -and -not @($cron.Fields|Where-Object Value -NE 'Not applied').Count) 'Fix hid missing Cron data or claimed read-only repairs'}
                else{Assert-Payout ($cron.Count -eq 0) 'Healthy or unsupported Cron Job data appeared in Fix'}
            }
        }
        if($case -in @('SIX','NETS','NEXIDE','PRINT','multiple','multiple-kitchen','missing-branch')){
            $state=[pscustomobject]@{Version=1;ClientType=$client;ComputerName='FIXTURE-PC';BundleId=$identity.ReportId;LatestMode='Audit';Reports=[pscustomobject]$reports}
            [IO.File]::WriteAllText((Join-Path $previewRoot ($client+'-'+$case+'-preview.html')),(New-ThoroughReportBundleHtml $state),[Text.UTF8Encoding]::new($false))
        }
        Assert-Payout (($snapshot|ConvertTo-Json -Depth 12 -Compress) -ceq $before -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $hash) 'Read-only collection changed input JSON or configuration file bytes'
        $caseCount++
    }
}
Write-Output ('PASS: '+$caseCount+' provider/shape/missing-value cases across both clients and all report modes; fixed Cron headings, friendly printer names and unchanged configuration bytes.')
