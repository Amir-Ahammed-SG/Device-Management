
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Render recorded observations only. All device and task access is prohibited.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output/report-refinements'
[void][IO.Directory]::CreateDirectory($outputRoot)
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
function Assert-Refinement {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-RefinementRow {
    param([int]$Section,[string]$Name,$Fields,[string]$Status='Fail')
    [pscustomobject]@{SectionNumber=$Section;SectionTitle='Fixture section';ItemTitle=$Name;ItemSub='';Shortcut=(New-ReportCommand @('services.msc'));FoundStateHtml=$(if($Fields -is [Collections.IDictionary]){ConvertTo-ReportDefinitionHtml $Fields}else{[string]$Fields});Status=$Status;ActionTaken='Audit only'}
}
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot $name),[ref]$tokens,[ref]$errors)
    Assert-Refinement ($errors.Count -eq 0) 'Source parsing failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-CimInstance {throw 'Rendering queried the device'}
    function Get-ScheduledTask {throw 'Rendering queried Task Scheduler'}
    function Get-ScheduledTaskInfo {throw 'Rendering queried task history'}
    function Set-LocalUser {throw 'Rendering changed an account'}
    function Start-Process {throw 'Rendering launched a process'}
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $printer=New-RefinementRow 1 'Printer' 'Not verified. Please check manually.'
    $printer|Add-Member NoteProperty ExpectedHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Printer Name'='BIXOLON or EPSON';'Printer status'='Active / Idle / Error';'Keep printed documents'='Enabled'}))
    $kiosk=New-RefinementRow 2 'KIOSK Account' 'Not verified. Kiosk account could not be identified from the existing setup. Please check manually.'
    $task=New-RefinementRow 2 'Kiosk Launch Task' ([ordered]@{'Task Name'='Launch Kiosk';'Task'='Missing';'Task Enabled'='Not configured';'Run Level'='Not configured';'Script Path'='Not configured';'Trigger'='Not configured';'Last Run'='Not recorded';'Next Run'='Not recorded'})
    $service=New-RefinementRow 3 'Payment Middleware Service' ([ordered]@{'Service Name'='AspPaymentSaaSProd';'Service State'='Running';'Version'='9.0.0.0'}) Pass
    $service.ItemSub='Type: Payment Gateway Middleware'
    $zabbix=New-RefinementRow 3 'Zabbix Agent' ([ordered]@{'Service State'='Not verified';'Host Name'='Not verified (service path unavailable)'})
    $firewall=New-RefinementRow 4 'Firewall Inbound Port' ([ordered]@{'Direction'='Inbound';'Protocol'='TCP';'Ports'='Any';'Enabled'='Yes';'Action'='Allow'}) Pass
    $firewall|Add-Member NoteProperty ExpectedHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Direction'='Inbound';'Protocol'='TCP';'Ports'='5009';'Enabled'='Yes';'Action'='Allow'}))
    $accounts=@(foreach($accountName in @('ahamm','zahid')) {
        [pscustomobject]@{AccountName=$accountName;Status='Pass';Action='No changes needed';AccountPolicyChanged=$false;AdministrativePolicy=$true;State=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$accountName;'Account Privilege'='Administrator';'Account Status'='Active';'Password Never Expires'='Enabled'}))}
    })
    $admin=New-RefinementRow 4 'Administrative Accounts' ('<div class="account-stack">'+(($accounts|ForEach-Object {$_.State}) -join '<hr>')+'</div>') Pass
    $admin|Add-Member NoteProperty AccountResults $accounts
    $rows=@($printer,$kiosk,$task,$service,$zabbix,$firewall,$admin)
    $original=ConvertTo-Json -InputObject $rows -Depth 24 -Compress
    $identity=[pscustomobject]@{ReportId='OMK-245001';GeneratedAt='04 Nov 2026, 1:20 PM BST';AgentName='Fixture Agent'}
    foreach($mode in @('Audit','Fix','Final')) {
        $snapshot=New-ThoroughReportSnapshot -Rows $rows -DisplayMode $mode -AfterApply $false -AuditSource $identity -DeviceType KIOSK -Hostname 'FIXTURE-PC' -AgentName 'Fixture Agent' -ClientLocation 'Fixture Branch' -LauncherKioskId 'Kiosk-1'
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
        if($mode -eq 'Audit') {
            $p=Get-AuditRenderedComponent $html 'Printer'
            Assert-Refinement (($p.Fields.Setting -join '|') -eq 'Printer Name|Printer status|Keep printed documents') 'Unavailable printer collapsed into Details'
            Assert-Refinement (@($p.Fields|Where-Object Found -NotMatch '^Not verified').Count -eq 0) 'Unavailable printer fabricated a value'
            $k=Get-AuditRenderedComponent $html 'KIOSK Account'
            Assert-Refinement ($k.Fields.Count -eq 5 -and $k.Fields[0].Found -match 'could not be identified') 'Unknown kiosk account lost settings or inspection reason'
            $t=Get-AuditRenderedComponent $html 'Kiosk Launch Task'
            Assert-Refinement (($t.Fields.Setting -join '|') -eq 'Task Name|Task Status|Target|Trigger Time|Last Run|Next Run') 'Task report is not the compact six-field view'
            Assert-Refinement (@($t.Fields|Where-Object {$_.Setting -eq 'Task Status' -and $_.Found -eq 'Missing'}).Count -eq 1) 'Missing task shown as available'
            $a=Get-AuditRenderedComponent $html 'Administrative Accounts'
            Assert-Refinement (@($a.Fields|Where-Object {$_.Setting -eq 'Account Name' -and $_.Html -match 'finding-mismatch'}).Count -eq 0) 'Detected administrative identity is falsely red'
            $f=Get-AuditRenderedComponent $html 'Firewall'
            Assert-Refinement (@($f.Fields|Where-Object {$_.Setting -eq 'Ports' -and $_.Found -eq 'Any'}).Count -eq 1) 'Actual broad firewall port was replaced with a desired port'
        }else {
            $p=Get-SettingRenderedComponent $html 'Printer'
            Assert-Refinement (($p.Fields.Setting -join '|') -eq 'Printer Name|Printer status|Keep printed documents') ($mode+' collapsed unavailable printer settings')
            if($mode -eq 'Fix') {
                Assert-Refinement (@($p.Fields|Where-Object Value -NE 'Not applied').Count -eq 0) 'Audit-derived Fix fabricated applied values'
                Assert-Refinement (-not $html.Contains('<div class="device-title">Administrative Accounts</div>')) 'Healthy detected administrators leaked into Fix'
            }
        }
        Assert-Refinement ($html.Contains('service path unavailable')) 'Unavailable service reason was lost'
        Assert-Refinement ((ConvertTo-Json -InputObject $rows -Depth 24 -Compress) -ceq $original) 'Rendering changed saved observations'
    }
    $version=Get-ReportRequirement $service
    Assert-Refinement ($version -match 'Readable' -and $version -notmatch '0\.0\.0\.0') 'Readable version requirement still uses a fake version'
    $target='C:\Users\Fixture & <Desk>\Scripts\LaunchKiosk.ps1'
    $projected=Get-KioskLaunchTaskReportState (ConvertTo-ReportDefinitionHtml ([ordered]@{'Task Name'='Launch Kiosk';'Task'='Available';'Task Enabled'='Yes';'Script Path'=$target;'Trigger'='At logon';'Logon User'='PC\Fixture';'Startup Delay'='5 seconds';'Last Run'='04-Nov-2026 01:20:00';'Next Run'='Not recorded'}))
    $values=Get-ThoroughReportHighlightFields $projected
    Assert-Refinement ($values.Count -eq 6 -and $values['Target'] -ceq $target -and $values['Trigger Time'] -match '5 seconds' -and $values['Last Run'] -notmatch '^Not') 'Compact task lost escaped target, trigger delay or history'
    Assert-Refinement ((Get-KioskLaunchTaskHistory @([pscustomobject]@{TaskPath='\'}))['Last Run'] -eq 'Not verified') 'Denied history was fabricated'
    Write-Output ('PASS: '+$client+' unknown inventory fields, compact task, detected administrator identities, actual firewall ports, readable version and immutable Audit/Fix/Final observations.')
}
