. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$preview=Join-Path $root 'output\appsettings-printer-match'
[void][IO.Directory]::CreateDirectory($preview)
function Assert-PrinterMatch {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    Set-KioskTestClient $client
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-PrinterMatch (-not $errors.Count) 'Expanded engine does not parse.'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-Printer {[CmdletBinding()]param() if($script:rendering){throw 'Renderer queried printers'};if($script:printerFailure){throw 'Printer API unavailable'};$script:fixturePrinters}
    function Get-PrinterPort {[CmdletBinding()]param() if($script:rendering){throw 'Renderer queried ports'};if($script:portFailure){throw 'Port API unavailable'};$script:fixturePorts}
    function Set-Printer {throw 'Printer configuration must remain unchanged'}
    function Set-Content {throw 'AppSettings must remain unchanged'}
    $script:rendering=$false;$script:portFailure=$false;$script:printerFailure=$false
    $script:fixturePrinters=@(
        [pscustomobject]@{Name='POSPrinter POS-80';PortName='USB001'},
        [pscustomobject]@{Name='Kitchen & Bar <One>';PortName='KitchenPort'},
        [pscustomobject]@{Name='USB prefix only';PortName='USB002'},
        [pscustomobject]@{Name='IP prefix only';PortName='IP_192.0.2.50'},
        [pscustomobject]@{Name='Unknown port';PortName='WSD-unknown'},
        [pscustomobject]@{Name='Pooled printer';PortName='USB001,KitchenPort'},
        [pscustomobject]@{Name='Literal [USB]*';PortName='USB001'}
    )
    $script:fixturePorts=@(
        [pscustomobject]@{Name='USB001';PortMonitor='USB Monitor'},
        [pscustomobject]@{Name='USB002';PortMonitor='Local Monitor'},
        [pscustomobject]@{Name='KitchenPort';PortMonitor='Standard TCP/IP Port';PrinterHostAddress='192.0.2.40'},
        [pscustomobject]@{Name='IP_192.0.2.50';PortMonitor='Local Monitor'}
    )
    $inventory=@(Get-ThoroughAppSettingsPrinterInventory)
    Assert-PrinterMatch ($inventory.Count -eq 7 -and $inventory[0].ConnectionType -eq 'USB' -and $inventory[1].ConnectionType -eq 'IP') 'Actual USB/TCP-IP evidence was not collected.'
    foreach($entry in $inventory[2..5]){Assert-PrinterMatch ($entry.ConnectionType -eq 'Not verified') 'A guessed/pooled connection was verified.'}
    $script:portFailure=$true
    Assert-PrinterMatch (@(Get-ThoroughAppSettingsPrinterInventory | Where-Object ConnectionType -NE 'Not verified').Count -eq 0) 'Unavailable port evidence became a verified connection.'
    $script:portFailure=$false;$script:printerFailure=$true
    Assert-PrinterMatch (@(Get-ThoroughAppSettingsPrinterInventory).Count -eq 0) 'Unavailable printers became a verified inventory.'
    $script:printerFailure=$false;$script:rendering=$true
    $cases=@(
        @{Id='matched';Kitchen='Kitchen & Bar <One>';Kiosk='POSPrinter POS-80';Green=@('Kitchen Printer','Kiosk/POS Printer')},
        @{Id='case-insensitive';Kitchen='kitchen & bar <one>';Kiosk='posprinter pos-80';Green=@('Kitchen Printer','Kiosk/POS Printer')},
        @{Id='wrong-connections';Kitchen='POSPrinter POS-80';Kiosk='Kitchen & Bar <One>';Green=@()},
        @{Id='unmatched';Kitchen='Missing printer';Kiosk='POSPrinter';Green=@()},
        @{Id='empty-kitchen';Kitchen='';Kiosk='POSPrinter POS-80';Green=@('Kiosk/POS Printer')},
        @{Id='empty-both';Kitchen='';Kiosk='';Green=@()},
        @{Id='unverified-ports';Kitchen='IP prefix only';Kiosk='USB prefix only';Green=@()},
        @{Id='pooled';Kitchen='Pooled printer';Kiosk='Pooled printer';Green=@()},
        @{Id='literal-name';Kitchen='';Kiosk='Literal [USB]*';Green=@('Kiosk/POS Printer')},
        @{Id='no-inventory';Kitchen='Kitchen & Bar <One>';Kiosk='POSPrinter POS-80';Green=@();NoInventory=$true},
        @{Id='duplicate';Kitchen='';Kiosk='POSPrinter POS-80';Green=@();Duplicate=$true}
    )
    foreach($case in $cases){
        $source=[pscustomobject]@{
            SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';ItemSub='Type: Read-only Configuration Inspection'
            Shortcut='<code>notepad.exe appsettings.json</code>';FoundStateHtml='Recorded configuration';Status='Fail';ActionTaken='Read only'
            ConfigurationSnapshot=[pscustomobject]@{PaymentService='PRINT';Print=[pscustomobject]@{PrinterName=$case.Kitchen;KioskPrinterName=$case.Kiosk}}
        }
        if(-not $case.NoInventory){
            $recorded=@($inventory)
            if($case.Duplicate){$recorded+=,[pscustomobject]@{Name='POSPrinter POS-80';PortName='KitchenPort';ConnectionType='IP'}}
            $source | Add-Member -NotePropertyName PrinterInventory -NotePropertyValue $recorded
        }
        # Persist and restore evidence as the combined report does.
        $source=$source | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $before=$source | ConvertTo-Json -Depth 12 -Compress
        $row=@(Get-ThoroughAppSettingsReportRows $source | Where-Object ItemTitle -EQ 'Print')[0]
        Assert-PrinterMatch ((Test-ThoroughAppSettingsReview $row) -eq ([string]::IsNullOrWhiteSpace($case.Kitchen) -or [string]::IsNullOrWhiteSpace($case.Kiosk))) 'Printer highlighting changed the existing AppSettings review outcome.'
        $observed=Format-ThoroughReportFieldLabels $row.FoundStateHtml
        $requirement=Format-ThoroughReportFieldLabels $row.ExpectedHtml
        $highlighted=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $observed -RequirementHtml $requirement
        $fields=@(Read-ThoroughAuditFields $highlighted | Where-Object Kind -EQ 'Field')
        foreach($field in $fields){
            if($case.Green -contains $field.Label){
                $connection=if($field.Label -eq 'Kitchen Printer'){'IP'}else{'USB'}
                Assert-PrinterMatch ($field.State -eq 'match' -and $field.Description -eq ('Matches installed '+$connection+' printer')) ('Matching printer was not verified: '+$case.Id+'/'+$field.Label)
            }elseif($field.Text -eq '(empty)'){
                Assert-PrinterMatch ($field.State -eq 'unverified') 'Empty printer lost its existing amber style.'
            }else{Assert-PrinterMatch ($field.State -eq '') ('Unmatched/wrong-connection printer changed color: '+$case.Id)}
        }
        Assert-PrinterMatch ((Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $highlighted -RequirementHtml $requirement) -ceq $highlighted) 'Printer matching is not idempotent.'
        Assert-PrinterMatch (($source | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'Matching changed recorded evidence.'
        foreach($mode in @('Audit','Fix','Final')){
            $snapshot=New-ThoroughReportSnapshot -Rows @($source) -DisplayMode $mode -Hostname 'FIXTURE-PC' -AfterApply:($mode -eq 'Fix')
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            if($mode -eq 'Audit'){
                $component=Get-AuditRenderedComponent $html 'Printer'
                Assert-PrinterMatch ($component.Count -eq 1) 'AppSettings printer component missing.'
                foreach($field in $component.Fields){
                    $green=$case.Green -contains $field.Setting
                    Assert-PrinterMatch (($field.Html -match 'audit-observed finding-match') -eq $green) ('Wrong visible printer color: '+$case.Id+'/'+$field.Setting)
                    if($field.Found -eq '(empty)'){Assert-PrinterMatch ($field.Html -match 'finding-unverified') 'Rendered empty printer lost amber.'}
                }
                Assert-PrinterMatch ($html.Contains('.audit-report .audit-observed.finding-match {') -and $html.Contains('background:#e8f5e9; color:#1b5e20;')) 'Visible green match CSS missing.'
            }
            if($case.Id -in @('matched','wrong-connections','empty-kitchen')){
                [IO.File]::WriteAllText((Join-Path $preview ($client+'-'+$mode+'-'+$case.Id+'.html')),$html,[Text.UTF8Encoding]::new($false))
            }
        }
    }
    Write-Output ('PASS: '+$client+' USB/IP evidence, failed APIs, exact names, wrong connections, empty/unmatched colors, persisted observations and Audit/Fix/Final rendering.')
}
