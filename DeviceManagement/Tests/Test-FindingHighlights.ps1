# Compare and render fixtures only. Never run a device check or repair.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output\finding-highlights'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-Highlight {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$cases=@(
    @{Label='Service State';Expected='Running';Actual='Running';Result='match'},
    @{Label='Service State';Expected='Running';Actual='Stopped';Result='mismatch'},
    @{Label='Service State';Expected='Running';Actual='Not verified';Result=''},
    @{Label='Startup type';Expected='Automatic';Actual='Automatic';Result='match'},
    @{Label='Startup type';Expected='Automatic';Actual='Manual';Result='mismatch'},
    @{Label='First failure';Expected='Restart the service';Actual='Take No Action';Result='mismatch'},
    @{Label='Second failure';Expected='Restart the service';Actual='Restart the service';Result='match'},
    @{Label='Subsequent failures';Expected='Take No Action';Actual='Take No Action';Result='match'},
    @{Label='Service Name';Reference='Expected Names';Expected='SubwayLocal or AspPaymentSubwayProd';Actual='AspPaymentSubwayProd';Result='match'},
    @{Label='Service Name';Reference='Expected Names';Expected='SubwayLocal or AspPaymentSubwayProd';Actual='OtherPayment';Result='mismatch'},
    @{Label='Version';Expected='0.0.0.0';Actual='9.2.3.4';Result='match';Collected=$true},
    @{Label='Version';Expected='0.0.0.0';Actual='Not detected';Result='mismatch';Missing=$true},
    @{Label='Version';Expected='0.0.0.0';Actual='Not verified';Result=''},
    @{Label='Version';Expected='8.0.0.0';Actual='9.2.3.4';Result='mismatch'},
    @{Label='Version';Expected='0.0.0.0';Actual='9.2.3.4';Section='AppSettings Check';Result='match';Collected=$true},
    @{Label='Host Name';Expected='KIOSK-01';Actual='kiosk-01';Result='match'},
    @{Label='Host Name';Expected='KIOSK-01';Actual='KIOSK-02';Result='mismatch'},
    @{Label='Host Name';Expected='KIOSK-01';Actual='Dynamic / not verified (HostnameItem=system.hostname)';Result=''},
    @{Label='Host Name';Expected='Not verified';Actual='KIOSK-01';Result=''},
    @{Label='Account Name';Expected='Admin, Administrator';Actual='Administrator';Result='match'},
    @{Label='Account Name';Expected='Support <Two> & Desk';Actual='Support <Two> & Desk';Result='match'},
    @{Label='Account Privilege';Expected='Local user';Actual='Standard Local User';Result='match'},
    @{Label='Account Privilege';Expected='Local user';Actual='Local Administrator';Result='mismatch'},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='Standard';Result='match'},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='Administrator';Result='match'},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='Standard Local User';Result='match'},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='Local Administrator';Result='match'},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='Not verified';Result=''},
    @{Label='Account Privilege';Expected='Standard or Administrator';Actual='';Result='mismatch'},
    @{Label='Account Status';Expected='Active / Disabled';Actual='Active';Result='match'},
    @{Label='Account Status';Expected='Active / Disabled';Actual='Disabled';Result='match'},
    @{Label='Password Never Expires';Expected='Enabled';Actual='Enabled';Result='match'},
    @{Label='User Cannot Change Password';Expected='Enabled';Actual='Disabled';Result='mismatch'},
    @{Label='User Cannot Change Password';Expected='Enabled';Actual='Not verified';Result=''},
    @{Label='Printer Name';Expected='BIXOLON or EPSON';Actual='BIXOLON BK3-3';Result='match'},
    @{Label='Printer Name';Expected='BIXOLON or EPSON';Actual='EPSON TM-m30';Result='match'},
    @{Label='Printer Name';Expected='BIXOLON or EPSON';Actual='Other Printer';Result='mismatch'},
    @{Label='Printer status';Expected='Active / Idle / Error';Actual='Idle';Result='match'},
    @{Label='Printer status';Expected='Active / Idle / Error';Actual='Error';Result='match'},
    @{Label='Keep printed documents';Expected='Enabled';Actual='Disabled';Result='mismatch'},
    @{Label='Restaurant ID';Expected='Configured';Actual='BRANCH-123';Result='match'},
    @{Label='Kiosk ID';Expected='Configured';Actual='Not configured';Result='mismatch'},
    @{Label='Host name';Expected='Configured';Actual='Not detected';Result=''},
    @{Label='Restaurant ID';Expected='Configured';Actual='';Result='mismatch'},
    @{Label='Launcher Path';Reference='Launch Script';Expected='Available';Actual='C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1';Result='match';Collected=$true},
    @{Label='Launcher Path';Reference='Launch Script';Expected='Available';Actual='C:\Sample & <Support>\LaunchKiosk.ps1';Result='match';Collected=$true},
    @{Label='Launcher Path';Reference='Launch Script';Expected='Available';Actual='Missing. Manual action required.';Result='mismatch';Missing=$true},
    @{Label='Launcher Path';Reference='Launch Script';Expected='Available';Actual='Not verified. Please check manually.';Result=''},
    @{Label='Startup BAT';Expected='Available';Actual='LaunchKiosk.bat';Result='match'},
    @{Label='Startup BAT';Expected='Available';Actual='Missing. Manual action required.';Result='mismatch'},
    @{Label='Desktop Shortcut';Expected='Available';Actual='Launch Kiosk.lnk';Result='match'},
    @{Label='Desktop Shortcut';Expected='Available';Actual='Not verified. Please check manually.';Result=''},
    @{Label='Location';Expected='Path';Actual='C:\Users\SELISE-KIOSK\Startup';Result='match';Collected=$true},
    @{Label='Location';Expected='Path';Actual='';Result='mismatch';Missing=$true},
    @{Label='Location';Expected='Path';Actual='Not verified';Result=''},
    @{Label='Task Name';Expected='e.g. Restart PS';Actual='Nightly Payment Restart';Item='Payment Service Restart Task';Result='match';Collected=$true},
    @{Label='Task Name';Expected='e.g. Restart PS';Actual='Missing Payment Restart';Item='Payment Service Restart Task';Result='match';Collected=$true},
    @{Label='Task Name';Expected='e.g. Restart PS';Actual='Not found';Item='Payment Service Restart Task';Result='mismatch';Missing=$true},
    @{Label='Task Name';Expected='e.g. Restart PS';Actual='Not verified';Item='Payment Service Restart Task';Result=''},
    @{Label='Trigger Time';Expected='time';Actual='Everyday at 4:15 AM';Item='Payment Service Restart Task';Result='match';Collected=$true},
    @{Label='Trigger Time';Expected='time';Actual='No trigger configured';Item='Payment Service Restart Task';Result='mismatch';Missing=$true},
    @{Label='Trigger Time';Expected='time';Actual='Daily schedule; Start: invalid (Not verified)';Item='Payment Service Restart Task';Result=''},
    @{Label='Last Run';Expected='date & time';Actual='21 Oct 2026, 4:15 AM';Item='Payment Service Restart Task';Result='match';Collected=$true},
    @{Label='Last Run';Expected='date & time';Actual='Not recorded';Item='Payment Service Restart Task';Status='Pass';Result='mismatch';Missing=$true},
    @{Label='Next Run';Expected='date & time';Actual='22 Oct 2026, 4:15 AM';Item='Payment Service Restart Task';Result='match';Collected=$true},
    @{Label='Next Run';Expected='date & time';Actual='';Item='Payment Service Restart Task';Result='mismatch';Missing=$true},
    @{Label='Default User';Expected='Kiosk account';Actual='SELISE-KIOSK';User='SELISE-KIOSK';Result='match'},
    @{Label='Default User';Expected='Kiosk account';Actual='Administrator';User='SELISE-KIOSK';Result='mismatch'},
    @{Label='Default User';Expected='Kiosk account';Actual='SELISE-KIOSK';Result=''},
    @{Label='Automatic Sign-In Limit';Expected='Unlimited';Actual='0';Result='mismatch'},
    @{Label='Default Domain';Expected='Local computer';Actual='Local computer';Result='match'},
    @{Label='Translation';Expected='Disabled';Actual='Enabled';Result='mismatch'},
    @{Label='Pinch-to-Zoom';Expected='Disabled';Actual='Disabled';Result='match'},
    @{Label='Local Network Allowlist';Expected='https://kiosk.example.test';Actual='https://other.example.test';Result='mismatch'},
    @{Label='Tool State';Reference='Installed';Expected='Yes';Actual='Installed';Item='Nmap Diagnostic Tool';Result='match'},
    @{Label='Tool State';Reference='Installed';Expected='Yes';Actual='Not installed. Please install manually.';Item='Nmap Diagnostic Tool';Result='mismatch'},
    @{Label='Version';Expected='Readable';Actual='7.992';Item='Nmap Diagnostic Tool';Result='match'},
    @{Label='Version';Expected='Readable';Actual='Not verified. Please check manually.';Item='Nmap Diagnostic Tool';Result=''},
    @{Label='Rule';Expected='Available';Actual='Available';Item='Inbound TCP 5009 Rule';Result='match'},
    @{Label='Rule';Expected='Available';Actual='Missing';Item='Inbound TCP 5009 Rule';Result='mismatch'},
    @{Label='Rebuild State';Reference='Apply Fix';Expected='Exit code 0';Actual='Exit code: 0';Item='lodctr /R Performance Counter';Result='match'},
    @{Label='Rebuild State';Reference='Apply Fix';Expected='Exit code 0';Actual='Exit code: 5';Item='lodctr /R Performance Counter';Result='mismatch'},
    @{Label='Provider';Expected='SIX';Actual='SIX';Section='AppSettings Check';Result='match';Collected=$true},
    @{Label='Provider';Expected='SIX';Actual='NETS';Section='AppSettings Check';Result='match';Collected=$true},
    @{Label='IsEnabled';Expected='True';Actual='False';Section='AppSettings Check';Result='match';Collected=$true},
    @{Label='Provider';Expected='SIX';Actual='Missing. Manual action required.';Section='AppSettings Check';Result='';Color='unverified'},
    @{Label='Translation';Expected='Disabled';Actual='Disabled';Status='Bypass';Result=''}
)
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Highlight ($errors.Count -eq 0) 'Client source does not parse.'
    foreach($entry in ([ordered]@{'$sec4Num'='4';'$secAppNum'='5'}).GetEnumerator()){
        $number=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq $entry.Key},$true))
        Assert-Highlight ($number.Count -eq 1 -and $number[0].Right.Extent.Text -ceq $entry.Value) 'Production report section numbers do not match Security 4 and AppSettings 5.'
    }
    $definitions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $formatters=@($definitions | Where-Object {$_.Name -in @('Get-ThoroughReportHighlightFields','Get-ThoroughReportCollectedValueState','Get-ThoroughReportFindingComparison','Format-ThoroughReportFindingHighlights','Test-ThoroughHostname')})
    foreach($formatter in $formatters){
        $unexpected=@($formatter.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -notin @('Where-Object','Get-ThoroughReportHighlightFields','Get-ThoroughReportCollectedValueState','Get-ThoroughReportFindingComparison','Test-ThoroughHostname')},$true))
        Assert-Highlight ($unexpected.Count -eq 0) 'A comparison helper can call a device operation.'
    }
    foreach($case in $cases){
        $row=[pscustomobject]@{ItemTitle=$(if($case.Item){$case.Item}else{'Fixture'});SectionTitle=$(if($case.Section){$case.Section}else{'Core Background Services'});Status=$(if($case.Status){$case.Status}else{'Fail'})}
        $reference=if($case.Reference){$case.Reference}else{$case.Label}
        $requirements=@{};$requirements[$reference]=$case.Expected
        $observed=ConvertTo-ReportDefinitionHtml ([ordered]@{$case.Label=$case.Actual})
        $expected=ConvertTo-ReportDefinitionHtml $requirements
        $before=$row | ConvertTo-Json -Compress
        $result=Get-ThoroughReportFindingComparison -Row $row -Label $case.Label -Value $case.Actual -Requirements $requirements -KioskAccountName $case.User
        Assert-Highlight ($result -ceq $case.Result) ('Wrong comparison for '+$case.Label+' = '+$case.Actual+' (expected '+$case.Result+', got '+$result+')')
        $html=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $observed -RequirementHtml $expected -KioskAccountName $case.User
        $expectedClass=if($case.Color){$case.Color}elseif($case.Result){$case.Result}elseif($row.Status -eq 'Bypass'){''}elseif($case.Actual -match '(?i)\bnot\s+verified\b'){'unverified'}else{''}
        if($expectedClass){Assert-Highlight ($html.Contains(('class="finding-value finding-'+$expectedClass+'"'))) 'A value lacks its expected comparison or information style.'}
        else{Assert-Highlight ($html -ceq $observed) 'An informational reference or bypassed value changed.'}
        if($case.Collected){Assert-Highlight ($html.Contains('title="Value collected"') -and -not $html.Contains('Matches required configuration')) 'A collected value was presented as a fixed requirement match.'}
        if($case.Missing){Assert-Highlight ($html.Contains('title="Value not collected"')) 'A missing recorded value lost its descriptive tooltip.'}
        $restored=$html -replace '<div class="finding-value finding-(?:match|mismatch|unverified)" title="[^"]*">','<div>'
        Assert-Highlight ($restored -ceq $observed -and ($row | ConvertTo-Json -Compress) -ceq $before) 'Highlighting changed escaped values or recorded outcomes.'
        Assert-Highlight ((Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $html -RequirementHtml $expected -KioskAccountName $case.User) -ceq $html) 'Highlighting is not idempotent.'
    }
    foreach($ports in @('5009','4100','4101','4102','4103','4100-4103')){
        foreach($state in @('Available','Missing','Not verified')){
            $title='Inbound TCP '+$ports+$(if($ports.Contains('-')){' Rules'}else{' Rule'})
            $row=[pscustomobject]@{ItemTitle=$title;ItemSub='Type: Firewall Rule Presence';SectionTitle='Security, Network & System Integrity';Status='Fail'}
            $formatted=Format-ReportState -Item $title -Html $state
            Assert-Highlight ($formatted.Contains(('Rule:</span> '+$state))) 'A conditional firewall state lost its Rule label.'
            $colored=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $formatted -RequirementHtml (Get-ReportRequirement $row)
            if($state -eq 'Not verified'){Assert-Highlight ($colored -match 'finding-unverified' -and $colored -notmatch 'finding-match|finding-mismatch') 'An unverified firewall rule lacks amber styling or was compared.'}
            else{Assert-Highlight ($colored.Contains(('class="finding-value finding-'+$(if($state -eq 'Available'){'match'}else{'mismatch'})+'"'))) 'A required or conditional firewall rule lacks its expected highlight.'}
        }
    }
    $missingRow=[pscustomobject]@{ItemTitle='KIOSK Account';SectionTitle='Kiosk Application & Policies';Status='Fail'}
    $missing=Format-ThoroughReportFindingHighlights -Row $missingRow -FindingsHtml 'Account Missing. Please create manually.' -RequirementHtml (Get-ReportRequirement $missingRow)
    Assert-Highlight ($missing -match 'finding-mismatch') 'A confirmed missing account lacks its mismatch highlight.'
    $unverified=Format-ThoroughReportFindingHighlights -Row $missingRow -FindingsHtml 'Account not verified. Please check manually.' -RequirementHtml (Get-ReportRequirement $missingRow)
    Assert-Highlight (($unverified -replace '<[^>]+>','') -ceq 'Account not verified. Please check manually.' -and $unverified -match 'finding-unverified' -and $unverified -notmatch 'finding-match|finding-mismatch') 'An unverified account changed text or was assigned a match outcome.'
    foreach($record in @(
        @{Value=$false;Text='False';Class='match'},
        @{Value=$true;Text='True';Class='match'},
        @{Value=0;Text='0';Class='match'},
        @{Value='';Text='';Class='unverified'},
        @{Value=$null;Text='';Class='unverified'},
        @{Value='   ';Text='   ';Class='unverified'},
        @{Value='(empty)';Text='(empty)';Class='unverified'},
        @{Value='Not configured';Text='Not configured';Class='unverified'},
        @{Value='Not recorded';Text='Not recorded';Class='unverified'},
        @{Value='https://example.test/?a=1&b=<sample>';Text='https://example.test/?a=1&amp;b=&lt;sample&gt;';Class='match'},
        @{Value='Missing Printer Name';Text='Missing Printer Name';Class='match'},
        @{Value='Not verified';Text='Not verified';Class='unverified'},
        @{Value='Manual action required.';Text='Manual action required.';Class='unverified'},
        @{Value='Missing. Manual action required.';Text='Missing. Manual action required.';Class='unverified'},
        @{Value='Unknown';Text='Unknown';Class='unverified'},
        @{Value='Unavailable';Text='Unavailable';Class='unverified'}
    )){
        $row=[pscustomobject]@{ItemTitle='Recorded fixture';SectionTitle='AppSettings Check';Status='Fail'}
        $state=ConvertTo-ReportDefinitionHtml ([ordered]@{'Value'=$record.Value})
        $highlighted=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $state -RequirementHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Value'='True'}))
        Assert-Highlight ($highlighted.Contains(('class="finding-value finding-'+$record.Class+'"')) -and $highlighted.Contains(('Value:</span> '+$record.Text))) 'An AppSettings value lacks its presence color or changed its encoding/value.'
        $restored=$highlighted -replace '<div class="finding-value finding-(?:match|mismatch|unverified)" title="[^"]*">','<div>'
        Assert-Highlight ($restored -ceq $state -and $row.Status -eq 'Fail') 'AppSettings color changed raw values or the recorded result.'
        Assert-Highlight ((Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $highlighted -RequirementHtml '') -ceq $highlighted) 'AppSettings coloring is not idempotent.'
        if($record.Class -eq 'match'){Assert-Highlight ($highlighted.Contains('title="Value collected"')) 'An AppSettings value claims an exact configuration match.'}
    }
    $unreadableRow=[pscustomobject]@{ItemTitle='Payment Service appsettings.json';SectionTitle='AppSettings Check';Status='Fail'}
    $unreadable=Format-ThoroughReportFindingHighlights -Row $unreadableRow -FindingsHtml '<div class="kv-block">Not verified. File unreadable.</div>' -RequirementHtml ''
    Assert-Highlight ($unreadable -match 'finding-unverified' -and $unreadable.Contains('Not verified. File unreadable.') -and $unreadableRow.Status -eq 'Fail') 'An unreadable AppSettings result lost its failure, text or amber style.'
    Assert-Highlight ((Format-ThoroughReportFindingHighlights -Row $unreadableRow -FindingsHtml $unreadable -RequirementHtml '') -ceq $unreadable) 'Plain unverified styling is not idempotent.'
    foreach($record in @(
        @{Text='Not detected';Class='unverified'},@{Text='Not recorded';Class='unverified'},
        @{Text='Unknown';Class='unverified'},@{Text='Unavailable';Class='unverified'},
        @{Text='Running Payment Service or configuration path not available';Class='unverified'},
        @{Text='Missing. Manual action required.';Class='unverified'}
    )){
        $plain='<div class="kv-block">'+$record.Text+'</div>'
        $colored=Format-ThoroughReportFindingHighlights -Row $unreadableRow -FindingsHtml $plain -RequirementHtml ''
        Assert-Highlight ($colored.Contains(('finding-value finding-'+$record.Class+'"')) -and $colored.Contains($record.Text)) 'A plain AppSettings absence/manual-action notice has the wrong color.'
        Assert-Highlight ((Format-ThoroughReportFindingHighlights -Row $unreadableRow -FindingsHtml $colored -RequirementHtml '') -ceq $colored) 'Plain AppSettings coloring is not idempotent.'
    }
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $origin=if($client -eq 'Subway'){'https://kiosk.subway.ch'}else{'https://kiosk.ordermonkey.com'}
    $finalizer=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    function New-HighlightRow {
        param([int]$Section,[string]$SectionTitle,[string]$Title,[string]$Sub,[string]$State,[string]$Status)
        [pscustomobject]@{SectionNumber=$Section;SectionTitle=$SectionTitle;ItemTitle=$Title;ItemSub=$Sub;Shortcut='<code>services.msc</code>';FoundStateHtml=$State;Status=$Status;ActionTaken='Fixture only'}
    }
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        $accountState=@(foreach($name in @('SELISE','SELISE-KIOSK')){
            ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$name;'Account Privilege'='Standard Local User';'Account Status'='Active';'Password Never Expires'='Enabled';'User Cannot Change Password'=$(if($name -eq 'SELISE'){'Enabled'}else{'Disabled'})})
        }) -join '<hr>'
        $paymentName=if($client -eq 'Subway'){'SubwayLocal'}else{'AspPaymentSaaSProd'}
        $recovery=ConvertFrom-ServiceRecoveryActionTypes -Types @(1,0,0)
        $rows=@(
            (New-HighlightRow 1 'Hardware & Peripherals' 'BIXOLON BK3-3' 'Type: Receipt / POS Printer' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Printer Name'='BIXOLON BK3-3';'Printer status'='Idle';'Keep printed documents'='Enabled'})) 'Pass'),
            (New-HighlightRow 1 'Hardware & Peripherals' 'EPSON TM-m30' 'Type: Receipt / POS Printer' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Printer Name'='EPSON TM-m30';'Printer status'='Idle';'Keep printed documents'='Disabled'})) 'Fail'),
            (New-HighlightRow 2 'Kiosk Application & Policies' 'KIOSK Account' 'Verified configuration' $accountState 'Fail'),
            (New-HighlightRow 2 'Kiosk Application & Policies' 'Kiosk Launch Architecture' 'Verified configuration' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Launcher Path'='C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1';'Restaurant ID'='SAMPLE-BRANCH';'Kiosk ID'='Kiosk-1';'Host name'='SAMPLE-KIOSK-01';'URL origin'=$origin})) 'Pass'),
            (New-HighlightRow 2 'Kiosk Application & Policies' 'System & Browser Policies' 'Verified configuration' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Local Network Allowlist'=$origin;'Translation'='Disabled';'Visual Search'='Enabled';'Edge Gestures'='Disabled';'Pinch-to-Zoom'='Disabled'})) 'Fail'),
            (New-HighlightRow 3 'Core Background Services' 'Payment Gateway Middleware' 'Type: Payment Gateway Middleware' (ConvertTo-ServiceFindingHtml -ServiceName $paymentName -ServiceState 'Stopped' -StartupType 'Auto' -Recovery $recovery -Version '9.2.3.4') 'Fail'),
            (New-HighlightRow 5 'AppSettings Check' 'Payout Scheduler' 'appsettings.json' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Provider'='SIX';'IsEnabled'='False'})) 'Pass'),
            (New-HighlightRow 4 'Security, Network & System Integrity' 'Nmap Diagnostic Tool' 'Type: Executable / Version Check' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Tool State'='Installed';'Version'='7.992';'Executable Path'='C:\Program Files\Nmap\nmap.exe'})) 'Pass'),
            (New-HighlightRow 4 'Security, Network & System Integrity' 'Administrative Accounts' 'Verified configuration' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='Administrator';'Account Privilege'='Local Administrator';'Account Status'='Active';'Password Never Expires'='Not verified'})) 'Fail'),
            (New-HighlightRow 4 'Security, Network & System Integrity' 'lodctr /R Performance Counter' 'Type: System Performance Rebuild' (ConvertTo-ReportDefinitionHtml $(if($isApply){[ordered]@{'Rebuild State'='Exit code: 0'}}else{[ordered]@{'Audit'='Not executed'}})) $(if($isApply){'Pass'}else{'Bypass'}))
        )
        $rows[6] | Add-Member NoteProperty ExpectedHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Provider'='SIX, NETS, NEXIDE';'IsEnabled'='False / True'}))
        $before=$rows | ConvertTo-Json -Depth 6 -Compress
        $auditRows=[Collections.Generic.List[psobject]]@($rows)
        $mode=if($isApply){'Apply'}else{'Audit'}
        $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-preview.html')
        $runId='FINDING-HIGHLIGHT-PREVIEW';$clientLocation='Sample branch';$deviceType='KIOSK'
        $reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null;$kioskUser='SELISE-KIOSK'
        . $render
        Assert-Highlight (($rows | ConvertTo-Json -Depth 6 -Compress) -ceq $before) 'The renderer changed observations or recorded outcomes.'
        $html=[IO.File]::ReadAllText($reportPath)
        $headings=@([regex]::Matches($html,'<th colspan="[45]" class="section-title">([^<]+)</th>') | ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
        $expectedHeadings='1. Hardware & Peripherals|2. Kiosk Application & Policies|3. Core Background Services|4. Security, Network & System Integrity'+$(if(-not $isApply){'|5. AppSettings Check'})
        Assert-Highlight (($headings -join '|') -ceq $expectedHeadings) 'Applicable rendered sections are not in the requested numbered order.'
        Assert-Highlight ($html.Contains('#e8f5e9') -and $html.Contains('#fdecec') -and $html.Contains('#fff8e1') -and $html.Contains('#7a5a00') -and $html.Contains('Amber = Not verified;') -and $html -notmatch 'finding-recorded') 'Highlight styling or legend is missing.'
        foreach($row in [regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>')){
            if($row.Value -notmatch 'class="device-title"'){continue}
            $cells=@([regex]::Matches($row.Value,'(?is)<td\b[^>]*>(.*?)</td>') | ForEach-Object {$_.Groups[1].Value})
            if($isApply){
                Assert-Highlight (($cells[0],$cells[1],$cells[3] -join '') -notmatch 'class="finding-value') 'Highlighting escaped the Findings column.'
                # Compare observations at the common index used by the assertions below.
                $cells=@($cells[0],$cells[1],'',$cells[2])
            }else{Assert-Highlight (($cells[0..2] -join '') -notmatch 'class="finding-value') 'Highlighting escaped the Findings column.'}
            if($cells[0].Contains('>Payout Scheduler</div>')){Assert-Highlight ($cells.Count -eq 4 -and [regex]::Matches($cells[3],'finding-match" title="Value collected"').Count -eq 2 -and $cells[3].Contains('IsEnabled:</span> False')) 'AppSettings provider/False values lost their collected-value colors.'}
            if($cells[0].Contains('>Payment Gateway</div>')){
                Assert-Highlight ($cells[3] -match 'finding-mismatch[^>]*><span class="kv-label">Service State:</span> Stopped') 'The failed service state was hidden.'
                if(-not $isApply){
                    Assert-Highlight ($cells[3] -match 'finding-match[^>]*><span class="kv-label">Startup type:</span> Automatic' -and $cells[3] -match 'finding-match" title="Value collected"><span class="kv-label">Version:</span> 9\.2\.3\.4</div>') 'Audit lost the compared startup or collected version.'
                }else{Assert-Highlight ($cells[3] -notmatch 'Startup type:</span> Automatic|Version:</span> 9\.2\.3\.4') 'Fix repeats healthy service fields.'}
            }
            if($cells[0].Contains('>Printer</div>')){
                Assert-Highlight ($cells[3] -match '>Printer 01<' -and $cells[3] -match '>Printer 02<' -and $cells[3] -match 'finding-mismatch[^>]*><span class="kv-label">Keep printed documents:</span> Disabled') 'Multiple printer values lost the failed record or identities.'
                if(-not $isApply){Assert-Highlight ($cells[3] -match 'finding-match[^>]*><span class="kv-label">Keep printed documents:</span> Enabled') 'Audit lost the healthy printer record.'}
                else{Assert-Highlight ($cells[3] -notmatch 'Keep printed documents:</span> Enabled') 'Fix repeats healthy retention values.'}
            }
            if($cells[0].Contains('>KIOSK Account</div>')){Assert-Highlight ($cells[3] -match '>Account 01<' -and $cells[3] -match '>Account 02<' -and $cells[3] -match 'finding-mismatch[^>]*><span class="kv-label">User Cannot Change Password:</span> Disabled') 'Multiple account values lost their independent highlights.'}
            if($cells[0].Contains('>Administrative Accounts</div>')){Assert-Highlight ($cells[3] -match 'finding-unverified[^>]*><span class="kv-label">Password Never Expires:</span> Not verified') 'An unverified account flag lacks amber styling.'}
            if($cells[0].Contains('>Performance Counter</div>')){
                if($isApply){Assert-Highlight ($cells[3] -match 'No further fix needed' -and $cells[3] -notmatch 'finding-unverified') 'Fix did not summarize the healthy counter result.'}
                else{Assert-Highlight ($cells[3] -match 'finding-unverified[^>]*><span class="kv-label">Audit:</span> Not executed' -and $rows[-1].Status -eq 'Bypass') 'Audit counter observation is not amber or its recorded outcome changed.'}
            }
        }
    }
    Write-Output ('PASS: '+$client+' '+$cases.Count+' comparison cases, escaping/idempotency, no device calls, unchanged outcomes, grouped values and Audit/Apply rendering')
}
