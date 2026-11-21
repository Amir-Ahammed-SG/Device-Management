
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
# Functions and recorded fixtures only; never query or change Windows services.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output\final-service-recovery\fixtures'
[void][IO.Directory]::CreateDirectory($outputRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-Recovery([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
foreach($file in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $file
    $path=Join-Path $sourceRoot 'KioskThoroughCheck.ps1';$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Recovery (-not $errors.Count) 'Client does not parse.'
    $definitions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine))
    Use-SettingLayoutRuleAssertions -SourceName $file
    function New-ServiceFixture([string]$Title,[string]$Type,[string[]]$Actions,[string]$Status='Pass'){
        $recovery=[pscustomobject]@{First=$Actions[0];Second=$Actions[1];Subsequent=$Actions[2]}
        [pscustomobject]@{SectionNumber=3;SectionTitle='Core Background Services';ItemTitle=$Title;ItemSub=$Type;Shortcut=(New-ReportCommand @('services.msc'));Status=$Status;ActionTaken='No change needed';FoundStateHtml=(ConvertTo-ServiceFindingHtml -ServiceName 'Service & <Actual>' -ServiceState Running -StartupType Auto -Recovery $recovery -Version '9.2.3.4')}
    }
    $restart=@('Restart the service','Restart the service','Take No Action')
    $none=@('Take No Action','Take No Action','Take No Action')
    $cases=@(
        @{Name='payment';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=$restart;Expected='Configured';Status='Pass'},
        @{Name='zabbix-other-failure';Title='Zabbix Agent 2';Type='Type: Infrastructure Monitoring';Actions=$restart;Expected='Configured';Status='Fail'},
        @{Name='update';Title='Windows Update (wuauserv)';Type='Type: Windows Update Engine';Actions=$none;Expected='Configured';Status='Pass'},
        @{Name='legacy';Title='Actual legacy (Legacy)';Type='Type: Old Payment Service';Actions=$none;Expected='Configured';Status='Offline'},
        @{Name='restart-missing';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=$none;Expected='Not Configured';Status='Fail'},
        @{Name='update-restarts';Title='Windows Update (wuauserv)';Type='Type: Windows Update Engine';Actions=$restart;Expected='Not Configured';Status='Fail'},
        @{Name='subsequent-mixed';Title='Zabbix Agent 2';Type='Type: Infrastructure Monitoring';Actions=@('Restart the service','Restart the service','Take No Action / Restart the service');Expected='Not Configured';Status='Fail'},
        @{Name='unreadable';Title='Zabbix Agent 2';Type='Type: Infrastructure Monitoring';Actions=@('Not verified','Not verified','Not verified');Expected='Not Verified';Status='Fail'},
        @{Name='unknown';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=@('Restart the service','Unknown action (9)','Take No Action');Expected='Not Verified';Status='Fail'},
        @{Name='partial';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=@('Restart the service','','Take No Action');Expected='Not Verified';Status='Fail'},
        @{Name='known-mismatch-and-unknown';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=@('Take No Action','Not verified','Take No Action');Expected='Not Configured';Status='Fail'},
        @{Name='readback-unverified';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=$restart;Expected='Not Verified';Status='Fail'},
        @{Name='missing-fields';Title='Payment Gateway Middleware';Type='Type: Payment Gateway Middleware';Actions=$restart;Expected='Not Verified';Status='Fail'}
    )
    foreach($case in $cases){
        $row=New-ServiceFixture $case.Title $case.Type $case.Actions $case.Status
        if($case.Name -eq 'readback-unverified'){$row | Add-Member NoteProperty RecoveryDetails ([pscustomobject]@{Verified=$false})}
        if($case.Name -eq 'missing-fields'){$row.FoundStateHtml='Not verified. Please check manually.'}
        $before=$row | ConvertTo-Json -Depth 8 -Compress
        $summary=Format-ThoroughFinalServiceRecovery $row (Format-ReportState $row.ItemTitle $row.FoundStateHtml)
        Assert-Recovery ($summary.Contains(('Recovery:</span> '+$case.Expected))) ('Incorrect recovery summary: '+$case.Name)
        Assert-Recovery ((Format-ThoroughFinalServiceRecovery $row $summary) -ceq $summary) 'Repeated summary formatting changed the result.'
        foreach($mode in @('Audit','Fix','Final')){
            $snapshot=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode $mode -DeviceType KIOSK -Hostname SAMPLE
            $html=$utf8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            if($mode -eq 'Audit'){
                $componentName=if($row.ItemSub -eq 'Type: Old Payment Service'){'Legacy Payment Services'}else{Get-ThoroughReportComponentName $row.ItemTitle}
                $auditView=Get-AuditRenderedComponent $html $componentName
                Assert-Recovery ($auditView.Fields.Setting -notcontains 'Recovery') 'Final recovery summary leaked into Audit.'
                if($case.Name -ne 'missing-fields'){
                    $observed=Get-ThoroughReportHighlightFields (Format-ReportState $row.ItemTitle $row.FoundStateHtml)
                    foreach($label in @('First failure','Second failure','Subsequent failures')){
                        Assert-Recovery (@($auditView.Fields|Where-Object {$_.Setting -eq $label -and $_.Found -eq $observed[$label]}).Count -eq 1) ('Audit lost detailed recovery observations: '+$case.Name+' / '+$label)
                    }
                }else{Assert-Recovery ($auditView.Text -match 'Not verified') 'Audit lost unavailable service evidence.'}
                [IO.File]::WriteAllText((Join-Path $outputRoot ($file.Replace('.ps1','')+'-'+$mode+'-'+$case.Name+'.html')),$html,$utf8)
                continue
            }
            $serviceRow=@([regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value -match 'class="device-title"'})[0].Value
            $cells=@([regex]::Matches($serviceRow,'(?is)<td\b[^>]*>(.*?)</td>'))
            $finding=$cells[$(if($mode -eq 'Final'){1}elseif($mode -eq 'Fix'){2}else{3})].Groups[1].Value
            if($mode -eq 'Final'){
                Assert-Recovery ([regex]::Matches($finding,'Recovery:</span>').Count -eq 1 -and $finding.Contains('Recovery:</span> '+$case.Expected)) 'Final did not use one truthful recovery summary.'
                Assert-Recovery ($finding -notmatch 'First failure:|Second failure:|Subsequent failures:') 'Detailed recovery actions remain in Final.'
                Assert-Recovery ($cells[2].Value -match $(if($case.Status -in @('Pass','Offline')){'>Pass</span>'}else{'>Fail</span>'})) 'Recovery summarization changed the recorded component result.'
                if($case.Name -ne 'missing-fields'){
                    foreach($value in @('Service &amp; &lt;Actual&gt;','Service State:</span> Running','Startup type:</span> Automatic','Version:</span> 9.2.3.4')){Assert-Recovery ($finding.Contains($value)) 'A non-recovery service field was changed.'}
                }
            }else{
                Assert-Recovery ($finding -notmatch 'Recovery:</span>') 'Recovery summary leaked into Audit/Fix.'
                if($mode -eq 'Audit' -and $case.Name -ne 'missing-fields'){foreach($label in @('First failure','Second failure','Subsequent failures')){Assert-Recovery ($finding.Contains($label+':</span>')) 'Audit lost detailed recovery observations.'}}
            }
            [IO.File]::WriteAllText((Join-Path $outputRoot ($file.Replace('.ps1','')+'-'+$mode+'-'+$case.Name+'.html')),$html,$utf8)
        }
        Assert-Recovery (($row | ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'Final summary changed recorded fields or status.'
    }
    $legacy=@(
        (New-ServiceFixture 'Legacy & One (Legacy)' 'Type: Old Payment Service' $none Offline),
        (New-ServiceFixture 'Legacy Two (Legacy)' 'Type: Old Payment Service' $restart Fail),
        (New-ServiceFixture 'Legacy Three (Legacy)' 'Type: Old Payment Service' @('Not verified','Not verified','Not verified') Fail)
    )
    $snapshot=New-ThoroughReportSnapshot -Rows $legacy -DisplayMode Final -DeviceType KIOSK -Hostname SAMPLE
    $html=$utf8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    Assert-Recovery ([regex]::Matches($html,'Recovery:</span>').Count -eq 3 -and [regex]::Matches($html,'class="config-item-title"').Count -eq 3) 'Grouped legacy services lost per-service recovery summaries or headings.'
    Assert-Recovery ($html -match '(?s)Legacy &amp; One</div>.*?Recovery:</span> Configured.*?Legacy Two</div>.*?Recovery:</span> Not Configured.*?Legacy Three</div>.*?Recovery:</span> Not Verified') 'A legacy block inherited another service recovery result.'
    foreach($type in @('Type: Read-only Scheduled Task Verification','Type: Receipt / POS Printer','Type: Read-only Configuration Inspection')){
        $other=[pscustomobject]@{ItemSub=$type}
        $html=ConvertTo-ReportDefinitionHtml ([ordered]@{'First failure'='Keep this unrelated value'})
        Assert-Recovery ((Format-ThoroughFinalServiceRecovery $other $html) -ceq $html) 'Recovery summary changed a non-service component.'
    }
    Assert-Recovery ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $hash) 'Fixture tests changed a client source.'
    Write-Output ('PASS: '+$file+' Final-only recovery summaries; configured/mismatched/unverified/readback cases; grouped legacy isolation; preserved raw fields, component statuses, Audit/Fix detail and other components.')
}
