$projectRoot = Split-Path $PSScriptRoot -Parent
# Render only the report finalizer with synthetic data. Never execute device checks.
$ErrorActionPreference = 'Stop'
$root = Split-Path $projectRoot -Parent
$previewDir = Join-Path $projectRoot 'output\report-layout'
New-Item -ItemType Directory -Path $previewDir -Force | Out-Null

# Load definitions only: never start the launcher menu or a device operation.
$launcherTokens = $null; $launcherErrors = $null
$launcherAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'Start-DeviceManagement.ps1'), [ref]$launcherTokens, [ref]$launcherErrors)
if ($launcherErrors.Count -gt 0) { throw ($launcherErrors | Out-String) }
$launcherFunctions = $launcherAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
. ([scriptblock]::Create(($launcherFunctions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))

foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
    $path = Join-Path $root $sourceName
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $source = [IO.File]::ReadAllText($path)
    $definitions=$ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
    . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $displayNames=[ordered]@{
        'Physical Printers'='Printer'; 'PrintService Operational Log'='PrintService Log'
        'Kiosk Launch Architecture'='Kiosk Launch Script'; 'SELISE-KIOSK Startup Folder'='Startup Folder'
        'Payment Gateway Middleware'='Payment Gateway'; 'Zabbix Agent 2'='Zabbix Agent'
        'Windows Update (wuauserv)'='Windows Update'; 'PaymentService'='Payment Service'
        'PaymentConfiguration'='Payment Configuration'; 'ScheduleConfiguration'='WebApp/Shop Print'; 'Print'='Printer'
        'MonitoringServiceBaseUrl'='Monitoring Service'; 'CmsGatewayBaseUrl'='CMS Gateway'; 'OrderServiceBaseUrl'='Order Service'
        'Inbound TCP 5009 Rule'='Firewall Inbound Port'; 'Inbound TCP 4100-4103 Rules'='Firewall Inbound Port'
        'lodctr /R Performance Counter'='Performance Counter'
    }
    foreach ($entry in $displayNames.GetEnumerator()) {
        if ((Get-ThoroughReportComponentName $entry.Key) -cne $entry.Value) { throw "Display name mismatch: $($entry.Key)" }
    }
    foreach ($port in @('5009','4100-4103')) {
        $firewallRow=[pscustomobject]@{ItemTitle=('Inbound TCP '+$port+' Rule');ItemSub='Type: Firewall Rule Presence'}
        if ((Get-ReportRequirement $firewallRow) -notmatch ([regex]::Escape($port))) { throw 'Firewall display rename lost the required port' }
    }
    $outerTry = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report' }, $true) | Select-Object -Last 1
    $render = [scriptblock]::Create(($outerTry.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n")
    function Start-AuditStep { param($Number, $Name) }
    function Read-AuditReportChoice { return $script:GenerateFixtureReport }
    $client = if ($sourceName -like 'Subway*') { 'Subway' } else { 'SaaS' }
    $auditPresentation=@{}
    foreach ($mode in @('Audit', 'Apply Fix')) {
        $script:ApplyChanges = $mode -eq 'Apply Fix'
        $script:GenerateFixtureReport = $true
        $outputFolder = $previewDir
        $reportPath = Join-Path $previewDir ($client + '-' + ($mode -replace ' ', '-') + '-preview.html')
        $runId = 'SAMPLE-20261018-001'
        $clientLocation = 'Sample site <fixture>'
        $deviceType = 'KIOSK'
        $reportHostname = 'SAMPLE-KIOSK-02'
        $reportKioskId = 'Kiosk-1'
        $KioskId = $null
        $auditRows = [Collections.Generic.List[psobject]]@(
            [pscustomobject]@{ SectionNumber=1; SectionTitle='Accounts & Privileges'; ItemTitle='KIOSK Account'; ItemSub='Verified configuration'; Shortcut='<code>lusrmgr.msc</code>'; FoundStateHtml='<div class="account-stack"><div class="kv-block"><div><span class="kv-label">Account Name:</span> SELISE-KIOSK</div><div><span class="kv-label">Account Privilege:</span> Standard Local User</div><div><span class="kv-label">Account Status:</span> Enabled</div><div><span class="kv-label">Password Never Expires:</span> Enabled</div><div><span class="kv-label">User Cannot Change Password:</span> Enabled</div></div></div>'; Status='Pass'; ActionTaken='Properties verified; existing password retained' },
            [pscustomobject]@{ SectionNumber=2; SectionTitle='Kiosk Application & Policies'; ItemTitle='System & Browser Policies'; ItemSub='Verified configuration'; Shortcut='<code>regedit</code>'; FoundStateHtml='Translation: Disabled<br>Visual Search: Disabled<br>Edge Gestures: Disabled<br>Pinch-to-Zoom: Disabled'; Status='Pass'; ActionTaken='Policy settings verified' },
            [pscustomobject]@{ SectionNumber=2; SectionTitle='Kiosk Application & Policies'; ItemTitle='SELISE-KIOSK Startup Folder'; ItemSub='Type: User Startup'; Shortcut='<code>explorer.exe</code>'; FoundStateHtml='LaunchKiosk.bat: Missing'; Status='Fail'; ActionTaken='Restore the missing launcher; readback not verified' },
            [pscustomobject]@{ SectionNumber=3; SectionTitle='Core Background Services'; ItemTitle='Payment middleware'; ItemSub='Type: Payment Gateway Middleware'; Shortcut='<code>services.msc</code>'; FoundStateHtml='Service State: Running<br>Startup Type: Auto'; Status='Online'; ActionTaken='Service settings verified' },
            [pscustomobject]@{ SectionNumber=3; SectionTitle='Core Background Services'; ItemTitle='Old middleware'; ItemSub='Type: Old Payment Service'; Shortcut='<code>services.msc</code>'; FoundStateHtml='Service State: Stopped<br>Startup Type: Disabled'; Status='Offline'; ActionTaken='Legacy service stopped and disabled' },
            [pscustomobject]@{ SectionNumber=4; SectionTitle='Security & Network'; ItemTitle='lodctr /R Performance Counter'; ItemSub='Type: System Performance Rebuild'; Shortcut='<code>perfmon</code>'; FoundStateHtml='Not executed'; Status='Bypass'; ActionTaken='Skipped; health was not verified' },
            [pscustomobject]@{ SectionNumber=5; SectionTitle='AppSettings Check'; ItemTitle='Payment Service appsettings.json'; ItemSub='Type: Read-only Configuration Inspection'; Shortcut='<code>C:\Sample\appsettings.json</code>'; FoundStateHtml='<div class="kv-block">PaymentService: NETS<br>KioskId: Kiosk-2<br>TerminalIPAddress: 192.0.2.10<br>Currency: CHF</div>'; Status='Pass'; ActionTaken='Configuration values collected; no values changed' },
            [pscustomobject]@{ SectionNumber=6; SectionTitle='Execution <fixture>'; ItemTitle='Unexpected interruption'; ItemSub='Verified configuration'; Shortcut=''; FoundStateHtml='Partial run'; Status='Fail'; ActionTaken='Fixture interruption &lt;details&gt;' }
        )
        $auditRows[0].Shortcut=New-AccountReportCommand -AccountNames @('SELISE-KIOSK')
        $auditRows[6].Shortcut=New-ReportCommand @('notepad.exe "C:\Sample & Support\appsettings.json"')
        $auditRows[3].ItemTitle='Payment Gateway Middleware'
        $paymentServiceName=if ($client -eq 'Subway') { 'SubwayLocal' } else { 'AspPaymentSaaSProd' }
        $restartRecovery=ConvertFrom-ServiceRecoveryActionTypes -Types @(1,1,0)
        $noActionRecovery=ConvertFrom-ServiceRecoveryActionTypes -Types @()
        $legacyFixture=$auditRows | Where-Object { $_.ItemSub -eq 'Type: Old Payment Service' } | Select-Object -First 1
        $legacyFixture.FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceState 'Stopped' -StartupType 'Manual' -Recovery $noActionRecovery
        $legacyFixture.ActionTaken='Verified Stopped / Manual; first, second and subsequent failures: Take No Action'
        $auditRows[3].FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceName $paymentServiceName -ServiceState 'Running' -StartupType 'Auto' -Recovery $restartRecovery -Version '8.3.2.1'
        $fixtureConfiguration = [pscustomobject]@{
            PaymentService='NETS'
            PaymentConfiguration=[pscustomobject]@{ NetsTerminals=@([pscustomobject]@{ PosId='POS'; KioskId='Kiosk-2'; TerminalIPAddress='192.0.2.10'; TerminalId=''; Currency='CHF'; Language='en'; IsSetupEnabled=$false }) }
            ScheduleConfiguration=[pscustomobject]@{ Schedules=@([pscustomobject]@{ Provider='KitchenTicketPrint'; IsKioskPrintingEnabled=$false; IsEnabled=$false },[pscustomobject]@{Provider='NETS';IsEnabled=$true}) }
            Print=[pscustomobject]@{ PrinterName='Kitchen <Printer>'; KioskPrinterName='Receipt' }
            MonitoringServiceBaseUrl='https://example.test/monitor'; CmsGatewayBaseUrl='https://example.test/cms'; OrderServiceBaseUrl='https://example.test/orders'
        }
        $auditRows[6] | Add-Member -NotePropertyName ConfigurationSnapshot -NotePropertyValue $fixtureConfiguration
        $auditRows[6] | Add-Member -NotePropertyName ConfigurationServiceName -NotePropertyValue 'FixturePayment'
        $auditRows[6] | Add-Member -NotePropertyName ConfigurationPath -NotePropertyValue 'C:\Sample\appsettings.json'
        $auditRows.Add([pscustomobject]@{ SectionNumber=1; SectionTitle='Accounts & Privileges'; ItemTitle='Physical Printers'; ItemSub='Type: Receipt / Hardware'; Shortcut='<code>control printers</code>'; FoundStateHtml='Not verified. Please check manually.'; Status='Fail'; ActionTaken='No physical printer detected. Check connection and printer driver.' })
        $auditRows.Add([pscustomobject]@{ SectionNumber=3; SectionTitle='Core Background Services'; ItemTitle='Zabbix Agent 2'; ItemSub='Type: Infrastructure Monitoring'; Shortcut='<code>services.msc</code>'; FoundStateHtml=(ConvertTo-ServiceFindingHtml -ServiceState 'Running' -StartupType 'Auto' -Recovery $restartRecovery -HostName 'MONITORING-HOST-02'); Status='Pass'; ActionTaken='Service settings and configured monitoring hostname verified' })
        $auditRows.Add([pscustomobject]@{ SectionNumber=3; SectionTitle='Core Background Services'; ItemTitle='Windows Update (wuauserv)'; ItemSub='Type: Windows Update Engine'; Shortcut='<code>services.msc</code>'; FoundStateHtml=(ConvertTo-ServiceFindingHtml -ServiceState 'Stopped' -StartupType 'Disabled' -Recovery $noActionRecovery); Status='Pass'; ActionTaken='Stopped / Disabled; recovery readback verified' })
        $auditRows.Add([pscustomobject]@{ SectionNumber=7; SectionTitle='Administrative Accounts'; ItemTitle='Administrative Accounts'; ItemSub='Verified configuration'; Shortcut='<code>lusrmgr.msc</code>'; FoundStateHtml='<div class="kv-block"><div><span class="kv-label">Account Name:</span> Administrator</div><div><span class="kv-label">Account Privilege:</span> Local Administrator</div><div><span class="kv-label">Account Status:</span> Enabled</div><div><span class="kv-label">Password Never Expires:</span> Enabled</div><div><span class="kv-label">User Cannot Change Password:</span> Enabled</div></div>'; Status='Pass'; ActionTaken='Account properties verified' })
        $adminFixture=$auditRows[$auditRows.Count-1]
        $secondAdmin=$adminFixture.FoundStateHtml.Replace('Account Name:</span> Administrator','Account Name:</span> SupportOperator')
        $adminFixture.FoundStateHtml='<div class="account-stack">'+$adminFixture.FoundStateHtml+'<hr>'+$secondAdmin+'</div>'
        $adminFixture.Shortcut=New-AccountReportCommand -AccountNames @('Administrator','SupportOperator')
        . $render
        $html = [IO.File]::ReadAllText($reportPath)
        $expectedTitle=if ($mode -eq 'Audit') { 'Thorough Check Audit Report' } else { 'Thorough Check Fix Report' }
        foreach ($required in @(('<h1>'+$expectedTitle.ToUpperInvariant()+'</h1>'), ('<title>'+$expectedTitle+'</title>'), '<h2>CLIENT DETAILS</h2>', '<h2>CONFIGURATION CHECK</h2>', ('<td>' + $client + '</td>'), '<th>Findings</th>', '<th>Branch</th>', '<th>Hostname</th>', '<th>Device</th><td>Kiosk-1</td>', 'badge-fail', '192.0.2.10', 'Sample site &lt;fixture&gt;', 'Execution &lt;fixture&gt;', 'Partial run', '@media print')) {
            if (-not $html.Contains($required)) { throw "Missing report content '$required' in $reportPath" }
        }
        if ($html -match 'Overall result|VERIFICATION RECORD|summary-grid|stat-card|EXCEPTIONS / CORRECTIVE ACTIONS|class="exceptions"|Value from appsettings.json|Only when PaymentService is NETS / Nexi|Report mode:|<th>Report mode</th>|<th>Computer name</th>|<th>Client / Site</th>|class="brand"|IT OPERATIONS|<strong>SELISE</strong>') { throw 'Removed report content is still present' }
        if ($html -notmatch '<th>Restaurant ID</th><td>Not detected</td>') { throw 'Unavailable Restaurant ID was not shown explicitly' }
        if ($html -notmatch '<strong>Generated Time:</strong> \d{2} [A-Za-z]{3} \d{4}, \d{1,2}:\d{2} (?:AM|PM) BST</span>') { throw 'Generated Time is not compact Bangladesh time' }
        if ($totalCount -ne 12 -or $passCount -ne 8 -or $failCount -ne 3 -or $skipCount -ne 1) { throw 'Result accounting changed' }
        if ($html.Contains('Old middleware (Offline)')) { throw 'Expected stopped legacy service incorrectly listed as an exception' }
        $expectedHeaders = if ($mode -eq 'Audit') { '<th>Component</th><th>Shortcut / Command</th><th>Required Configuration</th><th>Findings</th>' } else { '<th>Component</th><th>Shortcut / Command</th><th>Findings</th><th>Applied</th>' }
        if (-not $html.Contains($expectedHeaders)) { throw 'Incorrect report column order' }
        if ($html -match '<th>Reference</th>|<th>Result</th>') { throw 'Removed report columns remain' }
        if ($mode -eq 'Audit' -and $html -match '<th>Status</th>') { throw 'Fix Status column appeared in Audit' }
        foreach($table in [regex]::Matches($html,'(?is)<table class="checks"[^>]*>.*?</table>')){
            $appSettings=$table.Value.Contains('aria-label="AppSettings Check"')
            $hasStatus=$false
            $columnCount=if($hasStatus){5}else{4}
            if(($table.Value.Contains('<th>Status</th>')) -ne $hasStatus -or -not $table.Value.Contains(('colspan="'+$columnCount+'"')) -or [regex]::Matches($table.Value,'<col\b').Count -ne $columnCount){throw 'Section-specific headers, colspan or column widths are misaligned'}
            if($appSettings -and $table.Value -match 'class="badge'){throw 'AppSettings contains status badges'}
        }
        foreach ($groupName in @('PaymentService','PaymentConfiguration','ScheduleConfiguration','Print','MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')) {
            if($mode -ne 'Audit'){continue} # Fix omits healthy collected-only components.
            if (-not $html.Contains(('device-title">' + (Get-ThoroughReportComponentName $groupName) + '</div>'))) { throw "Missing point-7 group: $groupName" }
            if ($html.Contains(('<span class="kv-label">'+$groupName+':</span>'))) { throw 'AppSettings field label was not renamed' }
        }
        foreach ($rowMatch in [regex]::Matches($html, '(?is)<tr\b[^>]*>.*?</tr>')) {
            if ($rowMatch.Value -notmatch 'class="device-title"') { continue }
            $cells=@(Get-HtmlReportRowCells -RowHtml $rowMatch.Value)
            $displayTitle=Get-HtmlReportRowTitle -RowHtml $rowMatch.Value
            $sourceRow=@(Get-ThoroughReportDisplayRows -Rows $auditRows.ToArray()) | Where-Object { (Get-ThoroughReportComponentName $_.ItemTitle) -eq $displayTitle -and (($mode -eq 'Audit' -and (Format-ThoroughReportFieldLabels (Get-ReportRequirement $_)) -ceq $cells[2]) -or ($mode -ne 'Audit' -and (Get-ThoroughReportAppliedHtml -Row $_) -ceq $cells[3])) } | Select-Object -First 1
            if ($null -eq $sourceRow) { throw "Unknown displayed component: $displayTitle" }
            $hasStatus=$false
            if($cells.Count -ne $(if($hasStatus){5}else{4})){throw 'Incorrect section-specific report cell count'}
            $serviceTitle=$sourceRow.ItemTitle
            if($mode -ne 'Audit'){
                if($cells[3] -cne (Get-ThoroughReportAppliedHtml -Row $sourceRow)){throw 'Fix lost or changed the recorded action notes'}
                # Normalize common fields for the requirement/observation checks
                # below. Only Audit actually renders a requirement column.
                $cells=@($cells[0],$cells[1],(Format-ThoroughReportFieldLabels (Get-ReportRequirement $sourceRow)),$cells[2])
            }
            $expectedComponent='<div class="device-title">'+[Net.WebUtility]::HtmlEncode($displayTitle)+'</div>'
            if ($cells[0] -cne $expectedComponent) { throw 'Component contains a type, subtitle or command instead of only its name' }
            $expectedCommands=@([regex]::Matches($sourceRow.Shortcut,'(?is)<code\b[^>]*>(.*?)</code>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
            $buttonCommands=@([regex]::Matches($cells[1],'data-command="([^"]*)"') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
            if (($buttonCommands -join "`n") -cne ($expectedCommands -join "`n")) { throw 'Copy boxes changed the command text or command count' }
            if ($expectedCommands.Count -eq 0 -and $cells[1] -cne '&mdash;') { throw 'Empty command cell has an active copy control' }
            if ($cells[2] -notmatch 'class="kv-label"' -or $cells[2] -match '<code>') { throw 'Required configuration does not contain labelled requirements' }
            if ($cells[3] -match 'class="badge|finding-result|finding-notes|No physical printer detected|Restore the missing launcher') { throw 'Findings contains status or action content' }
            $commonCells=$cells[0..2] -join '|'
            if ($mode -eq 'Audit') {
                $auditPresentation[$serviceTitle]=$commonCells
            } else {
                if ($auditPresentation[$serviceTitle] -cne $commonCells) { throw 'Audit and Fix changed component identity, commands or reference requirements' }
                if($hasStatus){
                    if ($cells[4] -notmatch '>(Pass|Fail)</span>$') { throw 'Fix status is not Pass/Fail' }
                    if ($serviceTitle -in @('lodctr /R Performance Counter','Physical Printers','Unexpected interruption','SELISE-KIOSK Startup Folder') -and $cells[4] -notmatch '>Fail</span>$') { throw 'Skipped or failed check reported as Pass' }
                    if ($serviceTitle -in @('Old middleware','Payment Gateway Middleware') -and $cells[4] -notmatch '>Pass</span>$') { throw 'Verified service state reported as Fail' }
                }
            }
            if ($mode -eq 'Audit' -and (Get-HtmlReportRowTitle -RowHtml $rowMatch.Value) -eq 'KIOSK Account') {
                if ($cells[3] -notmatch 'Account Name:</span> SELISE-KIOSK') { throw 'Kiosk account name missing from Findings' }
                foreach ($label in @('Account Privilege','Account Status','Password Never Expires','User Cannot Change Password')) {if ($cells[3] -notmatch ([regex]::Escape($label)+':')) {throw 'Account property missing from Findings'}}
                foreach ($label in @('Password Never Expires','User Cannot Change Password')) {if ($cells[2] -notmatch ($label+':</span> Enabled')) {throw 'Account property missing from Required Configuration'}}
                if ($cells[2] -notmatch 'Account Privilege:</span> Standard or Administrator') {throw 'Kiosk privilege reference incorrect'}
                if ($cells[2] -notmatch 'Account Name:|Account Privilege:') { throw 'Account identity not in Required Configuration' }
            }
            if ($mode -eq 'Audit' -and (Get-HtmlReportRowTitle -RowHtml $rowMatch.Value) -eq 'Administrative Accounts') {
                $adminLabels=@([regex]::Matches($cells[3],'<span class="kv-label">([^<]+):</span>') | ForEach-Object { $_.Groups[1].Value })
                $adminFieldOrder='Account Name|Account Privilege|Account Status|Password Never Expires|User Cannot Change Password'
                if (($adminLabels -join '|') -cne ($adminFieldOrder+'|'+$adminFieldOrder)) { throw 'Administrative Findings field order is incorrect' }
                if ($cells[3] -notmatch 'Account Name:</span> Administrator' -or $cells[3] -notmatch 'Account Status:</span> Active') { throw 'Administrative Findings identity or status missing' }
            }
            if ((Get-HtmlReportRowTitle -RowHtml $rowMatch.Value) -in @('KIOSK Account','Administrative Accounts')) {
                if ($cells[2] -match 'config-item-title|<hr>' -or [regex]::Matches($cells[2],'class="kv-label"').Count -ne 5) { throw 'Account requirements were repeated or numbered' }
                if ($cells[2] -notmatch 'Account Status:</span> Active / Disabled' -or $cells[3] -match 'Account:</span> Present') { throw 'Required or actual account status is incorrect' }
            }
            if ($mode -eq 'Audit' -and $serviceTitle -in @('Payment Gateway Middleware','Zabbix Agent 2','Windows Update (wuauserv)')) {
                if ($cells[3] -match 'Expected Names|Executable File Version|\(Active\)') { throw 'Unexpected service Findings content' }
                foreach ($label in @('Service State','Startup type','First failure','Second failure','Subsequent failures')) {
                    if (-not $cells[3].Contains($label+':</span>')) { throw "Missing service Findings field: $label" }
                }
                if ($serviceTitle -eq 'Payment Gateway Middleware' -and $cells[2] -notmatch 'Expected Names:') { throw 'Expected service names were not placed in Required Configuration' }
                if ($serviceTitle -eq 'Payment Gateway Middleware' -and ($cells[2] -notmatch 'Version:</span> 0\.0\.0\.0' -or $cells[3] -notmatch 'Version:</span> 8\.3\.2\.1')) { throw 'Version reference or actual finding is incorrect' }
            }
        }
        $originalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($reportPath))
        $operationResult = [pscustomobject]@{ Status='Fail'; Message="Checks completed with failed checks. Report: $reportPath"; Context=$null }
        $formatWarnings = @()
        $formattedResult = Update-ThoroughCheckOperationResult -Result $operationResult -DeviceType KIOSK -ClientType $client -WarningVariable formatWarnings
        if ($formatWarnings.Count -gt 0 -or $formattedResult.Message -notmatch 'Professional report format applied') { throw 'Launcher rejected the native report layout' }
        if ($formattedResult.Status -ne 'Fail') { throw 'Launcher changed the operation result status' }
        Update-ThoroughCheckHtmlReport -Path $reportPath -DeviceType KIOSK -ClientType $client
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($reportPath)) -cne $originalBytes) { throw 'Launcher rewrote the approved report layout or results' }
        Write-Host "PASS: $client / $mode launcher formatting, unchanged report bytes and repeated formatting"

        $invalidPath = Join-Path $previewDir "$client-invalid-$($mode -replace ' ', '-').html"
        $invalidHtml = $html.Replace('</main>', '')
        try {
            [IO.File]::WriteAllText($invalidPath, $invalidHtml, [Text.UTF8Encoding]::new($false))
            $rejected = $false
            try { Update-ThoroughCheckHtmlReport -Path $invalidPath -DeviceType KIOSK -ClientType $client } catch { $rejected = $true }
            if (-not $rejected) { throw 'Launcher accepted an incomplete report' }
            if ([IO.File]::ReadAllText($invalidPath) -cne $invalidHtml) { throw 'Launcher changed the incomplete report' }
        } finally { Remove-Item -LiteralPath $invalidPath -Force -ErrorAction SilentlyContinue }
        Write-Host "PASS: $client / $mode report, partial results, escaping, statuses and client requirements"
        $presentPath=$reportPath
        $presentState=$auditRows[0].FoundStateHtml
        $presentAction=$auditRows[0].ActionTaken
        $presentShortcut=$auditRows[0].Shortcut
        $presentRows=$auditRows
        $missingResult=New-MissingAccountResult -RequestedName 'SELISE or SELISE-KIOSK'
        $auditRows[0].FoundStateHtml=$missingResult.StateHtml
        $auditRows[0].Status='Fail'
        $auditRows[0].ActionTaken=$missingResult.Action
        $auditRows[0].Shortcut=$missingResult.Shortcut
        $auditRows=[Collections.Generic.List[psobject]]@($auditRows | Where-Object { $_.ItemTitle -notin @('Kiosk Launch Architecture','SELISE-KIOSK Startup Folder','Kiosk Auto-Login','System & Browser Policies') })
        $reportPath=$presentPath.Replace('-preview.html','-missing-account-preview.html')
        . $render
        $missingHtml=[IO.File]::ReadAllText($reportPath)
        $missingRow=[regex]::Matches($missingHtml,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object { (Get-HtmlReportRowTitle -RowHtml $_.Value) -eq 'KIOSK Account' } | Select-Object -First 1
        $missingCells=@(Get-HtmlReportRowCells -RowHtml $missingRow.Value)
        if($mode -ne 'Audit'){
            if($missingCells[3] -notmatch 'Manual Action Required|Account Missing'){throw 'Missing-account action was reported as successful'}
            $missingCells=@($missingCells[0],$missingCells[1],(Get-ReportRequirement $auditRows[0]),$missingCells[2])
        }
        if (($missingCells[3] -replace '<[^>]+>','') -cne 'Account Missing. Please create manually.' -or $missingCells[3] -notmatch 'finding-mismatch') { throw 'Missing-account Findings does not request manual creation or lacks mismatch highlighting' }
        if ($missingCells[1] -match 'net user' -or $missingCells[1] -notmatch 'lusrmgr.msc') { throw 'Missing account has a specific-user command or lacks the general shortcut' }
        if ($missingCells[2] -notmatch 'Account Name:</span> SELISE or SELISE-KIOSK' -or $missingCells[2] -notmatch 'Account Privilege:</span> Standard or Administrator' -or $missingCells[2] -notmatch 'Password Never Expires:</span> Enabled' -or $missingCells[2] -notmatch 'User Cannot Change Password:</span> Enabled') { throw 'Missing-account Required Configuration is incomplete' }

        if ($missingHtml -match 'device-title">(Kiosk Launch Script|Startup Folder|Kiosk Auto-Login|System &amp; Browser Policies)</div>') { throw 'Missing-account preview includes dependent kiosk checks' }
        Update-ThoroughCheckHtmlReport -Path $reportPath -DeviceType KIOSK -ClientType $client
        $auditRows=$presentRows
        $auditRows[0].FoundStateHtml=$presentState
        $auditRows[0].Status='Pass'
        $auditRows[0].ActionTaken=$presentAction
        $auditRows[0].Shortcut=$presentShortcut
        $reportPath=$presentPath
        Write-Host "PASS: $client / $mode missing-account Findings and identity columns"
    }
    $script:ApplyChanges = $false
    $script:GenerateFixtureReport = $false
    $reportPath = Join-Path $previewDir "$client-declined-report.html"
    . $render
    if (Test-Path -LiteralPath $reportPath) { throw 'Declined Audit report was written' }
    Write-Host "PASS: $client declined Audit report"
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply;$script:GenerateFixtureReport=$true
        $auditRows=[Collections.Generic.List[psobject]]@(
            [pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';ItemSub='Type: Read-only Configuration Inspection';Shortcut='';FoundStateHtml='<div class="kv-block">Not verified. File unreadable.</div>';Status='Fail';ActionTaken='Fixture read failure'},
            [pscustomobject]@{SectionNumber=6;SectionTitle='Execution';ItemTitle='Unexpected interruption';ItemSub='Verified configuration';Shortcut='';FoundStateHtml='Partial run';Status='Fail';ActionTaken='Fixture interruption'}
        )
        $reportPath=Join-Path $previewDir ($client+'-'+$(if($isApply){'Apply'}else{'Audit'})+'-unreadable-appsettings.html')
        . $render
        $unreadableHtml=[IO.File]::ReadAllText($reportPath)
        $tables=@([regex]::Matches($unreadableHtml,'(?is)<table class="checks"[^>]*>.*?</table>'))
        $appTable=$tables | Where-Object {$_.Value.Contains('aria-label="AppSettings Check"')} | Select-Object -First 1
        $executionTable=$tables | Where-Object {$_.Value.Contains('aria-label="Execution"')} | Select-Object -First 1
        $appRow=[regex]::Matches($appTable.Value,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value -match 'class="device-title"'} | Select-Object -First 1
        if(@(Get-HtmlReportRowCells $appRow.Value).Count -ne 4 -or $appTable.Value -match '<th>Status</th>|class="badge' -or $appTable.Value -notmatch 'File unreadable'){throw 'Unreadable AppSettings lost its Findings or retained Status'}
        if($executionTable.Value -match '<th>Status</th>' -or ($executionTable.Value.Contains('<th>Applied</th>') -ne $isApply)){throw 'Execution section has the wrong columns'}
        if($totalCount -ne 2 -or $failCount -ne 2){throw 'Presentation changed recorded collection failures'}
    }
    Write-Host "PASS: $client mixed sections and unreadable AppSettings retain Findings, counts and section-specific status layout"
    foreach($isApply in @($false,$true)){
        foreach($toolState in @('Installed','Not installed. Please install manually.','Not verified. Please check manually.')){
            $script:ApplyChanges=$isApply;$script:GenerateFixtureReport=$true
            $nmapValues=[ordered]@{'Tool State'=$toolState}
            if($toolState -eq 'Installed'){$nmapValues['Version']='7.992';$nmapValues['Executable Path']='C:\Program Files\Nmap\nmap.exe'}
            $counterValues=if($isApply){[ordered]@{'Rebuild State'='Exit code: 0'}}else{[ordered]@{'Audit'='Not executed'}}
            $auditRows=[Collections.Generic.List[psobject]]@(
                [pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Shortcut='<code>lusrmgr.msc</code>';FoundStateHtml='Account settings unavailable';Status='Fail';ActionTaken='Fixture read failure'},
                [pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='Nmap Diagnostic Tool';ItemSub='Type: Executable / Version Check';Shortcut='<code>nmap --version</code>';FoundStateHtml=(ConvertTo-ReportDefinitionHtml $nmapValues);Status=$(if($toolState -eq 'Installed'){'Pass'}else{'Fail'});ActionTaken='Fixture observation'},
                [pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='lodctr /R Performance Counter';ItemSub='Type: System Performance Rebuild';Shortcut='<code>perfmon</code>';FoundStateHtml=(ConvertTo-ReportDefinitionHtml $counterValues);Status=$(if($isApply){'Pass'}else{'Bypass'});ActionTaken='Fixture observation'}
            )
            $scenario=if($toolState -eq 'Installed'){'installed'}elseif($toolState.StartsWith('Not installed')){'missing'}else{'unverified'}
            $reportPath=Join-Path $previewDir ($client+'-'+$(if($isApply){'Apply'}else{'Audit'})+'-security-'+$scenario+'.html')
            . $render
            $securityHtml=[IO.File]::ReadAllText($reportPath)
            foreach($row in [regex]::Matches($securityHtml,'(?is)<tr\b[^>]*>.*?</tr>')){
                $title=Get-HtmlReportRowTitle $row.Value
                if(-not $title){continue}
                $cells=@(Get-HtmlReportRowCells $row.Value)
                if($isApply){
                    $sourceRow=$auditRows | Where-Object {(Get-ThoroughReportComponentName $_.ItemTitle) -eq $title} | Select-Object -First 1
                    if($cells.Count -ne 4 -or $cells[3] -cne (Get-ThoroughReportAppliedHtml $sourceRow)){throw 'Security Fix action notes are incorrect'}
                    $cells=@($cells[0],$cells[1],(Get-ReportRequirement $sourceRow),$cells[2])
                }
                switch($title){
                    'Administrative Accounts' {if(($cells[3] -replace '<[^>]+>','') -cne 'Account not verified. Please check manually.' -or $cells[3] -notmatch 'finding-unverified'){throw 'Account fallback message or amber styling is missing'}}
                    'Nmap Diagnostic Tool' {
                        if($cells[2] -notmatch 'Installed:</span> Yes' -or $cells[2] -match 'Executable:</span> Present'){throw 'Nmap requirement was misplaced'}
                        if($isApply -and $toolState -eq 'Installed'){if($cells[3] -notmatch 'No further fix needed'){throw 'Healthy Nmap values were repeated in Fix'}}
                        elseif($cells[3] -notmatch ([regex]::Escape('Tool State:</span> '+$toolState))){throw 'Nmap actual installation state was misplaced'}

                    }
                    'Performance Counter' {
                        if($cells[2] -match 'Audit:|Not executed' -or $cells[2] -notmatch 'Apply Fix:</span> Exit code 0'){throw 'Audit execution note remains in Required Configuration'}
                        if($isApply){if($cells[3] -match 'Audit|Not executed' -or $cells[3] -notmatch 'No further fix needed'){throw 'Healthy counter result was not summarized in Fix'}}
                        elseif($cells[3] -notmatch 'Audit:</span> Not executed'){throw 'Audit execution note is missing from Findings'}
                    }
                }
            }
        }
    }
    Write-Host "PASS: $client actionable account fallback, truthful Nmap states and mode-specific counter Findings in rendered reports"
}
