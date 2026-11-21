
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
# Functions and synthetic observations only. No device checks or repairs run here.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output\legacy-service-reports'
[void][IO.Directory]::CreateDirectory($outputRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-LegacyReport([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
foreach($file in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $file
    $path=Join-Path $sourceRoot 'KioskThoroughCheck.ps1'
    $originalHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-LegacyReport (-not $errors.Count) 'Client source does not parse.'
    $functions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    Use-SettingLayoutRuleAssertions -SourceName $file
    function New-LegacyFixture([string]$Name,[string]$Status='Offline',[string]$Note='No change needed; verified Stopped / Manual; all recovery actions: Take No Action',[string]$State='Stopped'){
        $recovery=[pscustomobject]@{Verified=$true;First='Take No Action';Second='Take No Action';Subsequent='Take No Action'}
        [pscustomobject]@{SectionNumber=3;SectionTitle='Core Background Services';ItemTitle=($Name+' (Legacy)');ItemSub='Type: Old Payment Service';Shortcut=(New-ReportCommand @('services.msc'));FoundStateHtml=(ConvertTo-ServiceFindingHtml -ServiceState $State -StartupType Manual -Recovery $recovery);Status=$Status;ActionTaken=[Net.WebUtility]::HtmlEncode($Note)}
    }
    Assert-LegacyReport (@(Get-ThoroughReportDisplayRows -Rows @()).Count -eq 0) 'An empty service collection produced a legacy component.'
    foreach($case in @('single','multiple','mixed','unknown','blank')){
        $services=@(New-LegacyFixture 'SubwayLocal')
        if($case -ne 'single'){
            $status=switch($case){'mixed'{'Fail'};'unknown'{'Bypass'};default{'Offline'}}
            $note=if($case -eq 'mixed'){'Startup set to Manual; Failed: stop denied. Manual action required.'}else{'No change needed'}
            $second=New-LegacyFixture '[Payment & <Old>]' $status $note $(if($case -eq 'mixed'){'Running'}elseif($case -eq 'unknown'){'Not verified'}else{'Stopped'})
            if($case -eq 'blank'){$second.FoundStateHtml=''}
            $services+=,$second
        }
        $primary=New-LegacyFixture 'Primary'
        $primary.ItemTitle='Payment Gateway Middleware';$primary.ItemSub='Type: Payment Gateway Middleware';$primary.Status='Pass'
        $unrelated=New-LegacyFixture 'Monitoring'
        $unrelated.ItemTitle='Zabbix Agent 2';$unrelated.ItemSub='Type: Infrastructure Monitoring';$unrelated.Status='Pass'
        $raw=@($primary,$services[0],$unrelated)+@($services | Select-Object -Skip 1)
        $rawBefore=$raw | ConvertTo-Json -Depth 12 -Compress
        $display=@(Get-ThoroughReportDisplayRows -Rows $raw)
        Assert-LegacyReport ($display.Count -eq 3 -and $display[0] -eq $primary -and $display[2] -eq $unrelated) 'Grouping moved or grouped unrelated services.'
        $group=$display[1]
        Assert-LegacyReport ($group.ItemTitle -ceq 'Legacy Payment Services' -and $group.LegacyServiceRows.Count -eq $services.Count) 'Legacy services were not collected under one component.'
        Assert-LegacyReport (($display | ConvertTo-Json -Depth 12 -Compress) -ceq (@(Get-ThoroughReportDisplayRows -Rows $display) | ConvertTo-Json -Depth 12 -Compress)) 'Repeated grouping changed the report.'
        $expectedStatus=if($case -in @('single','multiple')){'Pass'}else{'Fail'}
        Assert-LegacyReport ($group.Status -ceq $expectedStatus) ('Legacy failure or unreadable state became Pass: '+$case)
        Assert-LegacyReport ([regex]::Matches($group.ExpectedHtml,'class="kv-label"').Count -eq 5 -and $group.ExpectedHtml -notmatch 'config-item-title|<hr') 'Shared requirements were repeated per service.'
        Assert-LegacyReport ([regex]::Matches($group.Shortcut,'<code').Count -eq 1 -and $group.Shortcut.Contains('services.msc')) 'Shared service command was duplicated or changed.'
        $formatted=Format-ThoroughReportFieldLabels $group.FoundStateHtml
        Assert-LegacyReport ([regex]::Matches($formatted,'<hr class="block-divider">').Count -eq ($services.Count-1)) 'Legacy block dividers are incorrect.'
        if($services.Count -gt 1){Assert-LegacyReport ($formatted.Contains('&#91;Payment &amp; &lt;Old&gt;&#93;')) 'Actual service identity was changed or not escaped.'}
        foreach($mode in @('Audit','Fix','Final')){
            $snapshot=New-ThoroughReportSnapshot -Rows $raw -DisplayMode $mode -ClientLocation 'Sample' -DeviceType KIOSK -Hostname SAMPLE -KioskUserName SELISE-KIOSK
            $html=$utf8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            if($mode -eq 'Audit'){
                $auditView=Get-AuditRenderedComponent $html 'Legacy Payment Services'
                Assert-LegacyReport ($auditView.Count -eq 1 -and $auditView.Headings.Count -eq $services.Count) 'Audit lost grouped service identities.'
                Assert-LegacyReport ($auditView.Headings -contains 'SubwayLocal') 'The first legacy service identity was lost.'
                if($case -eq 'mixed'){Assert-LegacyReport (@($auditView.Fields|Where-Object {$_.Setting -eq 'Service State' -and $_.Found -eq 'Running' -and $_.Html -match 'finding-mismatch'}).Count -eq 1) 'A failed legacy service state was hidden.'}
                [IO.File]::WriteAllText((Join-Path $outputRoot ($file.Replace('.ps1','')+'-'+$mode+'-'+$case+'.html')),$html,$utf8)
                continue
            }
            $rows=@([regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value.Contains('class="device-title">Legacy Payment Services</div>')})
            if($mode -eq 'Fix' -and $case -in @('single','multiple')){
                Assert-LegacyReport ($rows.Count -eq 0) 'Healthy unchanged legacy services remain in Fix.'
                continue
            }
            Assert-LegacyReport ($rows.Count -eq 1) 'Rendered report contains multiple legacy components.'
            $cells=@([regex]::Matches($rows[0].Value,'(?is)<td\b[^>]*>(.*?)</td>'))
            $findingIndex=if($mode -eq 'Final'){1}elseif($mode -eq 'Fix'){2}else{3}
            $finding=$cells[$findingIndex].Groups[1].Value
            Assert-LegacyReport ([regex]::Matches($finding,'class="config-item-title"').Count -eq $services.Count) 'A service observation was lost.'
            Assert-LegacyReport ($finding.Contains('>SubwayLocal</div>')) 'Single-service identity heading is missing.'
            Assert-LegacyReport ($finding -notmatch '<hr[^>]*>\s*</div>$') 'A trailing divider was rendered.'
            if($mode -eq 'Final'){
                Assert-LegacyReport ($cells[2].Value -match ('>'+ $expectedStatus +'</span>')) 'Final aggregate status contradicts service results.'
                Assert-LegacyReport ($html -notmatch 'class="finding-value finding-') 'Final field colors returned.'
            }elseif($mode -eq 'Audit'){
                Assert-LegacyReport ([regex]::Matches($cells[2].Value,'class="kv-label"').Count -eq 5) 'Audit requirements were repeated.'
                if($case -eq 'mixed'){Assert-LegacyReport ($finding -match 'finding-mismatch[^>]*><span class="kv-label">Service State:</span> Running') 'A mismatched service state was hidden.'}
            }else{
                $applied=$cells[3].Groups[1].Value
                Assert-LegacyReport ([regex]::Matches($applied,'class="config-item-title"').Count -eq $services.Count) 'Applied notes lost their service identities.'
                if($case -eq 'mixed'){Assert-LegacyReport ($applied.Contains('Manual Action Required') -and $applied.Contains('Startup set to Manual') -and $applied.Contains('stop denied')) 'Partial changes or failure details were lost.'}
            }
            [IO.File]::WriteAllText((Join-Path $outputRoot ($file.Replace('.ps1','')+'-'+$mode+'-'+$case+'.html')),$html,$utf8)
        }
        Assert-LegacyReport (($raw | ConvertTo-Json -Depth 12 -Compress) -ceq $rawBefore) 'Report rendering modified original observations.'
    }
    # Every repeated block type uses exactly one separator; single records use none.
    foreach($kind in @('Printer','Account','Terminal','Task','Schedule','Kitchen print schedule','Actual service name')){
        $one='<div class="config-item-title">['+$kind+' 1]</div>'+(ConvertTo-ReportDefinitionHtml ([ordered]@{Value='[Printer 2] & <literal>'}))
        $two='<div class="config-item-title">['+$kind+' 2]</div><div>Second record</div>'
        foreach($separator in @('','<hr>','<hr><hr>','<hr class="block-divider">')){
            $formatted=Format-ThoroughReportFieldLabels ($one+$separator+$two)
            Assert-LegacyReport ([regex]::Matches($formatted,'<hr\b').Count -eq 1) ('Missing or repeated divider for '+$kind)
            Assert-LegacyReport ((Format-ThoroughReportFieldLabels $formatted) -ceq $formatted) 'Divider formatting is not idempotent.'
            Assert-LegacyReport ($formatted.Contains('[Printer 2] &amp; &lt;literal&gt;')) 'Formatting changed a literal field value.'
        }
        Assert-LegacyReport ((Format-ThoroughReportFieldLabels $one) -notmatch '<hr') 'Single block has a divider.'
    }
    $twoGroups='<div class="config-group-title">First group</div><div class="config-item-title">One</div><div>A</div><div class="config-item-title">Two</div><div>B</div><div class="config-group-title">Second group</div><div class="config-item-title">Three</div><div>C</div>'
    $formatted=Format-ThoroughReportFieldLabels $twoGroups
    Assert-LegacyReport ([regex]::Matches($formatted,'<hr\b').Count -eq 1 -and $formatted -notmatch '<hr[^>]*><div class="config-item-title">Three') 'A new collection inherited the prior collection divider.'
    Assert-LegacyReport ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $originalHash) 'Fixture tests changed source code.'
    Write-Output ('PASS: '+$file+' legacy grouping, real service identities, mixed/unverified failures, partial actions, unchanged observations, all report modes and repeatable record dividers.')
}
