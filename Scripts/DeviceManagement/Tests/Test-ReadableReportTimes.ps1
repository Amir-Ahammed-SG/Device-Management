
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Pure presentation fixtures. Never query or modify system clocks or tasks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$deviceZone=[TimeZoneInfo]::CreateCustomTimeZone('TestDevicePlus02',[TimeSpan]::FromHours(2),'Test device +02','Test device +02')
function Assert-Readable {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$dateCases=@(
    @{Input='22-Oct-2026 19:50:01 +06:00';Expected='22 Oct 2026, 3:50 PM'},
    @{Input='21-Oct-2026 04:15:00';Expected='21 Oct 2026, 4:15 AM'},
    @{Input='22-Oct-2026 04:15:00';Expected='22 Oct 2026, 4:15 AM'},
    @{Input='2026-10-22T00:15:00+02:00';Expected='22 Oct 2026, 12:15 AM'},
    @{Input='2026-10-22T00:15:00Z';Expected='22 Oct 2026, 2:15 AM'},
    @{Input='2026-10-22T19:50:01.1234567-05:30';Expected='23 Oct 2026, 3:20 AM'},
    @{Input='22-Oct-2026 00:00:00';Expected='22 Oct 2026, 12:00 AM'},
    @{Input='22-Oct-2026 12:00:00';Expected='22 Oct 2026, 12:00 PM'},
    @{Input='2024-02-29T04:15:00';Expected='29 Feb 2024, 4:15 AM'},
    @{Input='2026-02-29T04:15:00';Expected='2026-02-29T04:15:00'},
    @{Input='Not recorded';Expected='Not recorded'},
    @{Input='Not verified. Please check manually.';Expected='Not verified. Please check manually.'},
    @{Input='';Expected=''},
    @{Input='22 October 2026, 7:50:01 PM (UTC+06:00)';Expected='22 Oct 2026, 3:50 PM'},
    @{Input='22 Oct 2026, 7:50 PM BST';Expected='22 Oct 2026, 3:50 PM'},
    @{Input=[datetime]::SpecifyKind([datetime]'2026-10-22T04:15:59',[DateTimeKind]::Unspecified);Expected='22 Oct 2026, 4:15 AM'},
    @{Input=[datetime]::SpecifyKind([datetime]'2026-10-22T04:15:59',[DateTimeKind]::Utc);Expected='22 Oct 2026, 6:15 AM'}
)
$durationCases=@(
    @{Input='PT6H';Expected='6 hours'},@{Input='P1D';Expected='1 day'},
    @{Input='PT90M';Expected='1 hour, 30 minutes'},@{Input='P2DT3H4M5S';Expected='2 days, 3 hours, 4 minutes, 5 seconds'},
    @{Input='PT0.5S';Expected='0.5 seconds'},@{Input='PT0S';Expected='0 seconds'},
    @{Input='P1Y';Expected='P1Y'},@{Input='invalid';Expected='invalid'}
)
$triggerCases=@(
    @{Input='Daily; Enabled: True; Start: 2026-01-01T04:15:00; DaysInterval: 1';Keep=@('Everyday at 4:15 AM');Omit=@('DaysInterval','2026-01-01T','Enabled','Starts')},
    @{Input='Daily; Enabled: False; Start: 2026-01-01T04:15:00; DaysInterval: 2';Keep=@('Every 2 days at 4:15 AM','Disabled');Omit=@('Enabled')},
    @{Input='Daily; Enabled: True; Start: 2026-01-01T04:15:00; DaysInterval: 1; Repetition Interval: PT6H; Repetition Duration: P1D';Keep=@('Repeats every 6 hours for 1 day');Omit=@('PT6H','P1D')},
    @{Input='Weekly; Enabled: True; Start: 2026-01-01T04:15:00+02:00; WeeksInterval: 2; DaysOfWeek: Monday, Wednesday';Keep=@('Every 2 weeks at 4:15 AM','Days of week: Monday, Wednesday');Omit=@('UTC','BST')},
    @{Input='Daily; Enabled: True; Start: 2026-01-01T04:15:00Z; DaysInterval: 1';Keep=@('Everyday at 6:15 AM');Omit=@('UTC','BST')},
    @{Input='Time; Enabled: True; Start: 2026-10-22T04:15:00; Elapsed one-time trigger';Keep=@('Once on 22 Oct 2026 at 4:15 AM','Elapsed one-time trigger');Omit=@()},
    @{Input='Daily; Enabled: True; Start: 2026-01-01T04:15:00; End: 2026-10-21T05:00:00; DaysInterval: 1; Expired';Keep=@('Ends 21 Oct 2026, 5:00 AM','Expired');Omit=@()},
    @{Input='Boot; Enabled: True; Start: 2026-01-01T04:15:00; Delay: PT30S';Keep=@('At system startup','Starts 01 Jan 2026, 4:15 AM','Delay: 30 seconds');Omit=@('startup at 4:15')},
    @{Input='Daily; Enabled: Not verified; Start: invalid; DaysInterval: 0';Keep=@('State: Not verified','Start: invalid (Not verified)','Days interval: 0');Omit=@('Every day')},
    @{Input='Daily; Enabled: True; Start: 2026-01-01T04:15:00; DaysInterval: 1 | Logon; Enabled: False';Keep=@('Everyday at 4:15 AM','At user sign-in','Disabled');Omit=@()},
    @{Input='CustomTrigger; Value: keep <literal> & data';Keep=@('CustomTrigger; Value: keep <literal> & data');Omit=@()},
    @{Input='No trigger configured';Keep=@('No trigger configured');Omit=@()},
    @{Input='Not verified. Please check manually.';Keep=@('Not verified. Please check manually.');Omit=@()}
)
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $path=Join-Path $sourceRoot $name
    $sourceHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Readable (-not $errors.Count) 'Client source does not parse.'
    $definitions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine))
    $script:ApplyChanges=$false
    foreach($case in $dateCases){
        $actual=Format-ThoroughReportDateTime $case.Input -DeviceTimeZone $deviceZone
        Assert-Readable ($actual -ceq $case.Expected) ('Timestamp changed meaning or offset: '+$case.Input+' => '+$actual)
        Assert-Readable ((Format-ThoroughReportDateTime $actual -DeviceTimeZone $deviceZone) -ceq $actual) 'Readable date formatting is not idempotent.'
    }
    foreach($case in $durationCases){Assert-Readable ((Format-ThoroughReportDuration $case.Input) -ceq $case.Expected) ('Duration lost precision: '+$case.Input)}
    foreach($case in $triggerCases){
        $actual=Format-ThoroughReportTriggerDetails $case.Input -DeviceTimeZone $deviceZone
        foreach($value in $case.Keep){Assert-Readable ($actual.Contains($value)) ('Trigger detail was lost: '+$value+' => '+$actual)}
        foreach($value in $case.Omit){Assert-Readable (-not $actual.Contains($value)) ('Misleading/raw trigger detail: '+$value)}
        Assert-Readable ((Format-ThoroughReportTriggerDetails $actual -DeviceTimeZone $deviceZone) -ceq $actual) 'Readable trigger formatting is not idempotent.'
    }
    $culture=[Threading.Thread]::CurrentThread.CurrentCulture
    try{
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        Assert-Readable ((Format-ThoroughReportDateTime '22-Oct-2026 19:50:01 +06:00' -DeviceTimeZone $deviceZone) -ceq $dateCases[0].Expected) 'Report dates depend on the system language.'
    }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$culture}
    $raw=ConvertTo-ReportDefinitionHtml ([ordered]@{'Task Name'='Restart <Payment> & Check';'Task Enabled'='Yes';'Restart Target'='Gateway';'Trigger Details'=$triggerCases[2].Input;'Last Run'=$dateCases[1].Input;'Next Run'=$dateCases[2].Input})
    $view=Format-ReportState 'Payment Service Restart Task' $raw
    Assert-Readable ($view.Contains('Restart &lt;Payment&gt; &amp; Check') -and $view.Contains('Repeats every 6 hours for 1 day') -and $view.Contains('21 Oct 2026, 4:15 AM') -and $view.Contains('Trigger Time:')) 'Rendered task values were unsafe or not readable.'
    Assert-Readable ($raw.Contains('PT6H') -and $raw.Contains('21-Oct-2026 04:15:00')) 'The original recorded values were changed.'
    Assert-Readable (-not $script:ApplyChanges) 'Display formatting enabled device changes.'
    Assert-Readable ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $sourceHash) 'Presentation tests changed a source.'
    # Generated Time is Bangladesh time even when the device is in another zone.
    foreach($zone in @([TimeZoneInfo]::Utc,$deviceZone,[TimeZoneInfo]::CreateCustomTimeZone('TestMinus08',[TimeSpan]::FromHours(-8),'Test -08','Test -08'))){
        $bst=Format-ThoroughReportDateTime '2026-10-22T13:50:59Z' -TimeZone BST -DeviceTimeZone $zone
        Assert-Readable ($bst -ceq '22 Oct 2026, 7:50 PM BST') 'Generated Time depends on the device zone or includes seconds.'
        Assert-Readable ((Format-ThoroughReportDateTime $bst -TimeZone BST -DeviceTimeZone $zone) -ceq $bst) 'BST formatting is not idempotent.'
    }
    Assert-Readable ((Format-ThoroughReportDateTime '2026-10-22T22:15:00Z' -TimeZone BST) -ceq '23 Oct 2026, 4:15 AM BST') 'BST conversion lost its date rollover.'
    Assert-Readable ((Format-ThoroughReportDateTime '2026-10-22T23:15:00Z' -DeviceTimeZone $deviceZone) -ceq '23 Oct 2026, 1:15 AM') 'Device-local conversion lost its date rollover.'
    $swissZone=[TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
    Assert-Readable ((Format-ThoroughReportDateTime '2026-01-01T04:15:00Z' -DeviceTimeZone $swissZone) -ceq '01 Jan 2026, 5:15 AM') 'Device winter offset is incorrect.'
    Assert-Readable ((Format-ThoroughReportDateTime '2026-07-01T04:15:00Z' -DeviceTimeZone $swissZone) -ceq '01 Jul 2026, 6:15 AM') 'Device daylight-saving offset is incorrect.'
    $before=[DateTimeOffset]::UtcNow.AddMinutes(-1)
    foreach($mode in @('Audit','Fix','Final')){
        $snapshot=New-ThoroughReportSnapshot -Rows @() -DisplayMode $mode -DeviceType KIOSK -Hostname SAMPLE
        $generatedDate=[datetime]::ParseExact(($snapshot.GeneratedAt -replace ' BST$',''),'dd MMM yyyy, h:mm tt',[Globalization.CultureInfo]::InvariantCulture)
        $generatedInstant=[datetimeoffset]::new($generatedDate,[TimeSpan]::FromHours(6))
        Assert-Readable ($generatedInstant -ge $before -and $generatedInstant -le [DateTimeOffset]::UtcNow) 'Snapshot Generated Time is not the current BST instant.'
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        Assert-Readable ($html.Contains('<span class="report-generated-at"><strong>Generated Time:</strong> '+$snapshot.GeneratedAt+'</span>')) 'Report and snapshot Generated Time disagree.'
    }
    Write-Output ('PASS: '+$name+' compact dates, BST-only generation, device-local task times, date rollovers, daylight saving, locale independence, interval/failure details, unchanged raw values and safe HTML.')
}
