# Real presentation functions and synthetic observations only. No device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output/audit-column-layout'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-AuditColumns {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Get-Definitions {param([string]$Path)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    ($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
}
function New-AuditFixtureRow {param($Section,$Title,$Sub,$Fields,$Status='Fail',$SectionTitle='Fixture section')
    [pscustomobject]@{SectionNumber=$Section;SectionTitle=$SectionTitle;ItemTitle=$Title;ItemSub=$Sub;Shortcut=(New-ReportCommand @('services.msc'));FoundStateHtml=$(if($Fields -is [Collections.IDictionary]){ConvertTo-ReportDefinitionHtml $Fields}else{[string]$Fields});Status=$Status;ActionTaken='Synthetic read-only observation.'}
}
function Read-AuditComponent {param([string]$Html,[string]$Name)
    $tables=[regex]::Matches($Html,'(?is)<table class="checks"[^>]*>.*?</table>')
    foreach($table in $tables){
        $body=[regex]::Match($table.Value,'(?is)<tbody>(.*?)</tbody>').Groups[1].Value
        $body=[regex]::Replace($body,'(?i)<(br|hr)(\b[^>]*?)(?<!/)>','<$1$2/>')
        $xml=[xml]('<root>'+$body+'</root>')
        $selected=[Collections.Generic.List[object]]::new();$remaining=0
        foreach($row in $xml.root.tr){
            $identity=$row.SelectSingleNode('./td[@class="audit-component"]')
            if($identity){$remaining=if($identity.InnerText -eq $Name){[int]$identity.GetAttribute('rowspan')}else{0}}
            if($remaining -gt 0){$selected.Add($row);$remaining--}
        }
        if($selected.Count){return $selected.ToArray()}
    }
    throw ('Missing component: '+$Name)
}
$identity=[pscustomobject]@{ReportId='OMK-123456';GeneratedAt='03 Nov 2026, 1:20 PM BST';AgentName='Fixture Agent'}
foreach($client in @('SaaS','Subway')){
    $name=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $beforePath=Join-Path $projectRoot ('output/audit-implementation/before/'+$name)
    $beforeRenderer=$null
    if(Test-Path -LiteralPath $beforePath){
        . ([scriptblock]::Create((Get-Definitions $beforePath)))
        $beforeRenderer=(Get-Command New-ThoroughReportSnapshot).ScriptBlock
    }
    . ([scriptblock]::Create((Get-Definitions (Join-Path $sourceRoot $name))))
    $script:ApplyChanges=$false
    function Get-CimInstance {throw 'A renderer queried the device.'}
    function Set-Service {throw 'A renderer changed a service.'}
    function Set-LocalUser {throw 'A renderer changed an account.'}
    function Set-ItemProperty {throw 'A renderer wrote the registry.'}
    function Start-Process {throw 'A renderer started a process.'}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($printer in @('EPSON & <Front>','BIXOLON "Kitchen"')){
        $r=New-AuditFixtureRow 1 $printer 'Type: Receipt / POS Printer' ([ordered]@{'Printer Name'=$printer;'Printer status'='Idle';'Keep printed documents'=$(if($printer -like 'EPSON*'){'Disabled'}else{'Enabled'})})
        $r.Shortcut=New-ReportCommand @('control printers',('rundll32 printui.dll,PrintUIEntry /o /n "'+$printer+'"'));$rows.Add($r)
    }
    $rows.Add((New-AuditFixtureRow 1 'PrintService Operational Log' '' 'Disabled'))
    $accountHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='SELISE-KIOSK';'Account Privilege'='Standard';'Account Status'='Active';'Password Never Expires'='Enabled';'User Cannot Change Password'='Disabled'}))+
        (ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='SELISE';'Account Privilege'='Administrator';'Account Status'='Active';'Password Never Expires'='Not verified';'User Cannot Change Password'='Disabled'}))
    $account=New-AuditFixtureRow 2 'KIOSK Account' '' $accountHtml
    $account.Shortcut=New-AccountReportCommand @('SELISE-KIOSK','SELISE');$rows.Add($account)
    $admin=New-AuditFixtureRow 4 'Administrative Accounts' '' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='Admin';'Account Privilege'='Administrator';'Account Status'='Active';'Password Never Expires'='Disabled';'User Cannot Change Password'='Disabled'}))
    $admin.Shortcut=New-AccountReportCommand @('Admin');$rows.Add($admin)
    $origin=if($client -eq 'SaaS'){'https://kiosk.ordermonkey.com'}else{'https://kiosk.subway.ch'}
    $launcher=New-AuditFixtureRow 2 'Kiosk Launch Architecture' '' ([ordered]@{'Launcher Path'='C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1';'Restaurant ID'='R & <123>';'Kiosk ID'='Kiosk-1';'Host name'='Not detected';'URL origin'=$origin})
    $launcher|Add-Member NoteProperty ExpectedHostName 'WINDOWS-HOST';$rows.Add($launcher)
    foreach($service in @('Legacy One','Legacy & <Two>')){
        $rows.Add((New-AuditFixtureRow 3 $service 'Type: Old Payment Service' ([ordered]@{'Service State'='Stopped';'Startup type'='Disabled';'First failure'='Take No Action';'Second failure'='Take No Action';'Subsequent failures'='Take No Action'}) Offline))
    }
    $firewall=New-AuditFixtureRow 4 'Inbound TCP 5009 Rule' 'Type: Firewall' '' Pass
    $firewall|Add-Member NoteProperty FirewallPort 5009
    $firewall|Add-Member NoteProperty FirewallReadVerified $true
    $firewall|Add-Member NoteProperty FirewallObservations @([pscustomobject]@{Direction='Inbound';Protocol='TCP';Ports=@('5009');Enabled='Yes';Action='Allow'})
    $rows.Add($firewall)
    $rows.Add((New-AuditFixtureRow 4 'lodctr /R Performance Counter' '' ([ordered]@{'Audit'='Not executed'}) Bypass))
    $config=[pscustomobject]@{PaymentService='NETS';PaymentConfiguration=[pscustomobject]@{NetsTerminals=@(
        [pscustomobject]@{PosId=0;KioskId='01';TerminalIPAddress='192.0.2.1';TerminalId='';Currency='CHF';Language='de';IsSetupEnabled=$false},
        [pscustomobject]@{PosId=2;KioskId='02';TerminalIPAddress='192.0.2.2';TerminalId='T2';Currency='CHF';Language='de';IsSetupEnabled=$true}
    )};ScheduleConfiguration=[pscustomobject]@{Schedules=@([pscustomobject]@{Provider='KitchenTicketPrint';IsKioskPrintingEnabled=$true;IsEnabled=$false},[pscustomobject]@{Provider='NETS';IsEnabled=$false},[pscustomobject]@{Provider='NETS';IsEnabled=$true})};Print=[pscustomobject]@{PrinterName='EPSON & <Front>'};MonitoringServiceBaseUrl='https://example.test/?a=1&b=2';CmsGatewayBaseUrl='https://example.test/cms';OrderServiceBaseUrl='https://example.test/order'}
    $app=New-AuditFixtureRow 5 'AppSettings Check' '' '' Pass 'AppSettings Check'
    $app|Add-Member NoteProperty ConfigurationSnapshot $config
    $app|Add-Member NoteProperty ConfigurationServiceName 'Payment Fixture'
    $app|Add-Member NoteProperty ConfigurationPath 'C:\Fixture & Support\appsettings.json'
    $rows.Add($app)
    $opaque=New-AuditFixtureRow 4 'Opaque evidence' '' '<div>Read failed &amp; access denied<br>Retry manually.</div>'
    $opaque|Add-Member NoteProperty ExpectedHtml 'Inspect manually.';$rows.Add($opaque)
    $before=$rows.ToArray() | ConvertTo-Json -Depth 18 -Compress
    $parameters=@{Rows=$rows.ToArray();DeviceType='KIOSK';Hostname='WINDOWS-HOST';LauncherKioskId='Kiosk-1';LauncherRestaurantId='R & <123>';ClientLocation='Fixture & Branch';AgentName='Fixture Agent';AuditSource=$identity;KioskUserName='SELISE-KIOSK'}
    $reports=[ordered]@{}
    foreach($mode in @('Audit','Fix','Final')){
        $snapshot=New-ThoroughReportSnapshot @parameters -DisplayMode $mode
        $reports[$mode]=$snapshot
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        [IO.File]::WriteAllText((Join-Path $previewRoot ($client+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
        if($mode -ne 'Audit'){
            if($beforeRenderer){
                $old=& $beforeRenderer @parameters -DisplayMode $mode
                $configPattern='(?is)<h2>CONFIGURATION CHECK</h2>(.*?)<p class="legend">'
                $currentBody=[regex]::Match($html,$configPattern).Groups[1].Value
                $oldBody=[regex]::Match([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($old.HtmlBase64)),$configPattern).Groups[1].Value
                Assert-AuditColumns ($currentBody -ceq $oldBody) ($mode+' configuration changed while implementing the header.')
            }
            Assert-AuditColumns (-not $html.Contains('class="audit-setting"')) ($mode+' inherited the Audit layout.')
            continue
        }
        Assert-AuditColumns ($html.Contains('<th scope="col">Setting</th><th scope="col">Required</th><th scope="col">Findings</th>')) 'Audit has incorrect columns.'
        Assert-AuditColumns ($html.Contains('<body class="audit-report">') -and $html.Contains('background:#edf4fb') -and $html.Contains('background:#fffbf0')) 'Approved Audit column colors are missing.'
        Assert-AuditColumns ($html -notmatch '>Mismatch<|>Not detected</span>\s*<[^>]+>Not verified') 'Extra finding status labels remain.'
        $printers=@(Read-AuditComponent $html 'Printer')
        Assert-AuditColumns (@($printers|Where-Object {$_.SelectSingleNode('./td[@class="audit-record-heading"]')}).Count -eq 2) 'Multiple printers lost their record headings.'
        Assert-AuditColumns (($printers|ForEach-Object {$_.InnerText}) -join '' -match 'EPSON & <Front>' -and (($printers|ForEach-Object {$_.InnerText}) -join '') -match 'BIXOLON "Kitchen"') 'Printer identity or escaping was lost.'
        $commands=@($printers[0].SelectNodes('.//button[@class="command-copy"]')|ForEach-Object {$_.GetAttribute('data-command')})
        Assert-AuditColumns ($commands.Count -eq 3 -and @($commands|Where-Object {$_ -eq 'control printers'}).Count -eq 1) 'Shared or device-specific commands were lost or duplicated.'
        $accounts=@(Read-AuditComponent $html 'KIOSK Account')
        $accountText=($accounts|ForEach-Object {$_.InnerText}) -join ''
        Assert-AuditColumns ($accountText.Contains('Account 01 - SELISE-KIOSK') -and $accountText.Contains('Account 02 - SELISE')) 'Multiple accounts lost identity.'
        Assert-AuditColumns (@($accounts|Where-Object {$_.SelectSingleNode('./td[@class="audit-setting"]') -and $_.SelectSingleNode('./td[@class="audit-setting"]').InnerText -eq 'User Cannot Change Password'}).Count -eq 1) 'Administrator records received the standard kiosk password restriction.'
        $adminRows=@(Read-AuditComponent $html 'Administrative Accounts')
        Assert-AuditColumns ((($adminRows|ForEach-Object {$_.InnerText}) -join '') -notmatch 'User Cannot Change Password') 'Administrative password policy changed.'
        $launchRows=@(Read-AuditComponent $html 'Kiosk Launch Script')
        $hostRow=@($launchRows|Where-Object {$_.SelectSingleNode('./td[@class="audit-setting"]').InnerText -eq 'Host name'})[0]
        Assert-AuditColumns ($hostRow.SelectSingleNode('./td[@class="audit-findings"]').InnerText -ceq 'Not detected' -and $hostRow.OuterXml.Contains('finding-unverified')) 'Unavailable hostname was relabeled or lost warning styling.'
        Assert-AuditColumns ($launchRows.Count -eq 5) 'Launcher alias matching added or removed a field.'
        $legacy=@(Read-AuditComponent $html 'Legacy Payment Services')
        Assert-AuditColumns (@($legacy|Where-Object {$_.SelectSingleNode('./td[@class="audit-record-heading"]')}).Count -eq 2) 'Multiple legacy services lost their headings.'
        $firewallRows=@(Read-AuditComponent $html 'Firewall Inbound Port')
        Assert-AuditColumns ((($firewallRows|ForEach-Object {$_.InnerText}) -join '').Contains('5009') -and $firewallRows.Count -eq 5) 'Actual firewall rules were lost.'
        $terminal=@(Read-AuditComponent $html 'Payment Configuration')
        $terminalText=($terminal|ForEach-Object {$_.InnerText}) -join ''
        Assert-AuditColumns ($terminalText.Contains('Terminal 01') -and $terminalText.Contains('Terminal 02') -and $terminalText.Contains('False') -and $terminalText.Contains('192.0.2.2')) 'AppSettings terminal grouping, zero/false or values were lost.'
        $zeroPosition=@($terminal|Where-Object {$_.SelectSingleNode('./td[@class="audit-setting"]') -and $_.SelectSingleNode('./td[@class="audit-setting"]').InnerText -eq 'PosId' -and $_.SelectSingleNode('./td[@class="audit-findings"]').InnerText -ceq '0'})
        Assert-AuditColumns ($zeroPosition.Count -eq 1) 'A collected zero was changed or treated as missing.'
        $counter=@(Read-AuditComponent $html 'Performance Counter')
        Assert-AuditColumns ((($counter|ForEach-Object {$_.InnerText}) -join '').Contains('Not executed') -and (($counter|ForEach-Object {$_.InnerText}) -join '') -notmatch 'Completed') 'Audit counter inspection was presented as a completed rebuild.'
        $notes=@(Read-AuditComponent $html 'Opaque evidence')
        Assert-AuditColumns ((($notes|ForEach-Object {$_.InnerText}) -join '').Contains('Read failed & access denied') -and (($notes|ForEach-Object {$_.InnerText}) -join '').Contains('Retry manually.')) 'Unstructured evidence was dropped.'
    }
    if($beforeRenderer){
        foreach($mode in @('Fix','Final')){
            $post=New-ThoroughReportSnapshot @parameters -DisplayMode $mode -AfterApply $true -BeforeRows $rows.ToArray()
            $oldPost=& $beforeRenderer @parameters -DisplayMode $mode -AfterApply $true -BeforeRows $rows.ToArray()
            $configPattern='(?is)<h2>CONFIGURATION CHECK</h2>(.*?)<p class="legend">'
            $postBody=[regex]::Match([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($post.HtmlBase64)),$configPattern).Groups[1].Value
            $oldPostBody=[regex]::Match([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($oldPost.HtmlBase64)),$configPattern).Groups[1].Value
            Assert-AuditColumns ($postBody -ceq $oldPostBody) ('Post-Apply '+$mode+' configuration changed while implementing the header.')
        }
    }
    Assert-AuditColumns (($rows.ToArray() | ConvertTo-Json -Depth 18 -Compress) -ceq $before) 'Audit presentation changed raw observations.'
    $state=[pscustomobject]@{Version=1;ClientType=$client;ComputerName='FIXTURE-PC';BundleId='OMK-123456';LatestMode='Audit';Reports=[pscustomobject]$reports}
    $bundle=New-ThoroughReportBundleHtml $state
    $saved=Read-ThoroughReportBundleState $bundle
    Assert-AuditColumns ($saved.Reports.Audit.HtmlBase64 -ceq $reports.Audit.HtmlBase64) 'Saved Audit did not round-trip.'
    [IO.File]::WriteAllText((Join-Path $previewRoot ($client+'-Combined.html')),$bundle,[Text.UTF8Encoding]::new($false))
    Write-Output ('PASS: '+$client+' five Audit columns, grouping, source values/commands, role-specific requirements, safe warnings, unchanged observations and Fix/Final output.')
}
