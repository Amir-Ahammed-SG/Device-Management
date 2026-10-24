# Read-only fixture JSON and real report rendering; no services or device APIs.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
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
            [pscustomobject]@{Provider='KitchenTicketPrint';IsKioskPrintingEnabled=$false;IsEnabled=$true},
            [pscustomobject]@{Provider='SIX';Name='Do not report SIX name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$false},
            [pscustomobject]@{Provider='NETS';Name='Do not report NETS name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$true},
            [pscustomobject]@{Provider='NEXIDE';Name='Do not report NEXIDE name';UID='Do not report UID';CronExpression='Do not report cron';IsEnabled=$false}
        )}
        Print=[pscustomobject]@{PrinterName='Kitchen & Receipt';KioskPrinterName='EPSON Receipt'}
        MonitoringServiceBaseUrl='https://example.test/monitor';CmsGatewayBaseUrl='https://example.test/cms';OrderServiceBaseUrl='https://example.test/orders'
    }
}
$caseCount=0
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Payout ($errors.Count -eq 0) 'Client source parser errors'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $finalizer=$ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    function Set-Content {throw 'AppSettings writes are forbidden'}
    function Set-Service {throw 'Service changes are forbidden'}
    function Restart-Service {throw 'Service restarts are forbidden'}
    function Copy-Item {throw 'AppSettings backups are forbidden'}
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        $mode=if($isApply){'Apply'}else{'Audit'}
        foreach($case in @('SIX','NETS','NEXIDE','PRINT','unknown','case-insensitive','missing-match','missing-flag','empty-flag','multiple','direct','array','empty-schedules')){
            $provider=switch($case){'case-insensitive'{' nEtS '};'unknown'{'OTHER'};{$_ -in @('SIX','NETS','NEXIDE','PRINT')}{$_};default{'NETS'}}
            $config=New-PayoutConfiguration $provider
            switch($case){
                'missing-match' {$config.ScheduleConfiguration.Schedules=@($config.ScheduleConfiguration.Schedules | Where-Object Provider -NE 'NETS')}
                'missing-flag' {($config.ScheduleConfiguration.Schedules | Where-Object Provider -EQ 'NETS').PSObject.Properties.Remove('IsEnabled')}
                'empty-flag' {($config.ScheduleConfiguration.Schedules | Where-Object Provider -EQ 'NETS').IsEnabled=''}
                'multiple' {$config.ScheduleConfiguration.Schedules+=@([pscustomobject]@{Provider='NETS';IsEnabled=$false})}
                'direct' {$config.ScheduleConfiguration=$config.ScheduleConfiguration.Schedules | Where-Object Provider -EQ 'NETS'}
                'array' {$config.ScheduleConfiguration=$config.ScheduleConfiguration.Schedules}
                'empty-schedules' {$config.ScheduleConfiguration.Schedules=@()}
            }
            $path=Join-Path $fixtureRoot ($client+'-'+$mode+'-'+$case+'-appsettings.json')
            [IO.File]::WriteAllText($path,($config | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $snapshot=ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($path))
            $before=$snapshot | ConvertTo-Json -Depth 12 -Compress
            $source=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';ItemSub='Type: Read-only Configuration Inspection';Shortcut=(New-ReportCommand @('notepad.exe "'+$path+'"'));ConfigurationSnapshot=$snapshot;ConfigurationServiceName='SamplePayment';ConfigurationPath=$path;Status='Pass';FoundStateHtml='Fixture only';ActionTaken='Fixture only'}
            $rows=@(Get-ThoroughAppSettingsReportRows $source)
            $lines=@(Get-ThoroughPaymentConfigurationAuditLines -Configuration $snapshot -ServiceName 'SamplePayment' -ConfigurationPath $path)
            $lineText=$lines -join "`n"
            Assert-Payout (($snapshot | ConvertTo-Json -Depth 12 -Compress) -ceq $before -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $hash) 'AppSettings data or file was changed'
            $webPrint=@($rows | Where-Object ItemTitle -EQ 'ScheduleConfiguration')
            Assert-Payout ($webPrint.Count -eq 1 -and (Get-ThoroughReportComponentName 'ScheduleConfiguration') -ceq 'WebApp/Shop Print') 'WebApp/Shop Print was renamed incorrectly or omitted'
            $payout=@($rows | Where-Object ItemTitle -EQ 'Payout Scheduler')
            $supported=$case -notin @('PRINT','unknown')
            if(-not $supported){
                Assert-Payout ($payout.Count -eq 0 -and $lineText -notmatch 'Payout Scheduler') 'PRINT or an unsupported provider included payout schedules'
            }else{
                Assert-Payout ($payout.Count -eq 1) 'Payout component is missing or duplicated'
                $payout=$payout[0]
                Assert-Payout ($payout.ExpectedHtml -ceq (ConvertTo-ReportDefinitionHtml ([ordered]@{Provider='SIX, NETS, NEXIDE';IsEnabled='False / True'}))) 'Payout reference differs from the approved fields'
                $labels=@([regex]::Matches($payout.FoundStateHtml,'kv-label">([^<]+):') | ForEach-Object {$_.Groups[1].Value})
                $expectedLabels=if($case -eq 'multiple'){'Provider|IsEnabled|Provider|IsEnabled'}else{'Provider|IsEnabled'}
                Assert-Payout (($labels -join '|') -ceq $expectedLabels -and $payout.FoundStateHtml -notmatch 'Name:|UID:|CronExpression:|KitchenTicketPrint') 'Payout Findings contains unrelated or missing fields'
                $missing=$case -in @('missing-match','missing-flag','empty-flag','empty-schedules')
                Assert-Payout (($payout.Status -eq 'Fail') -eq $missing) 'Missing payout values or false flags have an incorrect result'
                if($case -in @('missing-match','empty-schedules')){
                    Assert-Payout ($payout.FoundStateHtml -match 'Provider:</span> Not configured' -and $payout.FoundStateHtml -match 'IsEnabled:</span> Not configured') 'Absent matching schedule used another provider as fallback'
                }else{
                    $selected=$provider.Trim().ToUpperInvariant()
                    $actualProviders=@([regex]::Matches($payout.FoundStateHtml,'Provider:</span> ([^<]*)') | ForEach-Object {$_.Groups[1].Value.Trim().ToUpperInvariant()})
                    Assert-Payout (@($actualProviders | Where-Object {$_ -cne $selected}).Count -eq 0) 'An unrelated payout provider was included'
                    if(-not $missing){Assert-Payout ($payout.FoundStateHtml -match 'IsEnabled:</span> (True|False)') 'Boolean values were lost'}
                }
                if($case -eq 'multiple'){Assert-Payout ($payout.FoundStateHtml -match '\[Schedule 1\]' -and $payout.FoundStateHtml -match '\[Schedule 2\]') 'Multiple matching schedules were not retained'}
                Assert-Payout ($lineText -notmatch 'Do not report') 'Payout collection included unrequested schedule details'
                if($case -ne 'multiple'){
                    $payoutLines=@($lines | Select-Object -Skip ([array]::IndexOf($lines,'Payout Scheduler:')))
                    Assert-Payout ($payoutLines[0] -ceq 'Payout Scheduler:' -and $payoutLines[1] -match '^  Provider:' -and $payoutLines[2] -match '^  IsEnabled:') 'Underlying collection lost the payout field order'
                }
            }
            if($case -in @('SIX','NETS','NEXIDE','PRINT')){
                $missingLines=@($lines | Where-Object {$_ -match ':\s*Not configured$' -or ($_ -match ':\s*\(empty\)$' -and $_ -notmatch 'TerminalId:\s*\(empty\)$')})
                Assert-Payout ($missingLines.Count -eq 0) 'A configured true/false value was counted as missing'
                $source.FoundStateHtml=ConvertTo-ThoroughPaymentReportHtml $lines
                $auditRows=[Collections.Generic.List[psobject]]::new();$auditRows.Add($source)
                $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-'+$case+'-preview.html')
                $runId='SAMPLE-PAYOUT';$clientLocation='Sample branch';$deviceType='KIOSK';$reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
                . $render
                $html=[IO.File]::ReadAllText($reportPath)
                if($script:ApplyChanges){
                    Assert-Payout (-not $html.Contains('device-title">WebApp/Shop Print</div>') -and -not $html.Contains('device-title">Payout Scheduler</div>')) 'Healthy read-only schedule components remain in Fix'
                    Assert-Payout ($html.Contains('Read Only') -or $html.Contains('No fixes required.')) 'Pending configuration review lost its read-only label or empty state'
                }else{
                    Assert-Payout ($html.Contains('device-title">WebApp/Shop Print</div>') -and -not $html.Contains('device-title">Scheduler</div>')) 'Rendered print component has the old name'
                    Assert-Payout ($html.Contains('device-title">Payout Scheduler</div>') -eq ($case -ne 'PRINT')) 'Rendered payout visibility does not match the provider'
                    $withoutRecordStyles=$html -replace '<div class="finding-value finding-(?:match|mismatch|unverified)" title="[^"]*">','<div>'
                    if($case -ne 'PRINT'){Assert-Payout ($withoutRecordStyles.Contains($payout.FoundStateHtml)) 'Rendered payout values changed'}
                    Assert-Payout ($html.Contains('finding-match" title="Value collected"')) 'Collected configuration values lost their green presence styling'
                }
                Assert-Payout ($html -notmatch '<th>Status</th>|class="badge') 'AppSettings retains Status'
                if($html.Contains('<table class="checks"')){Assert-Payout ($html.Contains('colspan="4"') -and [regex]::Matches($html,'<col\b').Count -eq 4) 'AppSettings columns are misaligned'}
            }
            $caseCount++
        }
    }
}
Write-Output ("PASS: $caseCount read-only payout/provider/shape/missing-value cases and 16 real-renderer previews across both clients and modes. No device or service changes ran.")
