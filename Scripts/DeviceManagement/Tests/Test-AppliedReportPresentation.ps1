
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Report definitions only; never run device checks or repairs.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
function Assert-Applied {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-AppliedFixture {
    param([string]$Title,[string]$Status,[string]$Note,[string]$Section='Kiosk Application & Policies',[string]$Sub='Verified configuration')
    [pscustomobject]@{ItemTitle=$Title;Status=$Status;ActionTaken=[Net.WebUtility]::HtmlEncode($Note);SectionTitle=$Section;ItemSub=$Sub}
}
$cases=@(
    @{Row=(New-AppliedFixture 'PaymentService' 'Fail' 'A value could not be collected' 'AppSettings Check');Label='Read Only';Keep=@();Omit=@('Manual Action Required')},
    @{Row=(New-AppliedFixture 'Printer' 'Pass' 'No changes needed');Label='No Change Needed';Keep=@();Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'Kiosk Launch Architecture' 'Pass' 'No change needed. No change needed');Label='No Change Needed';Keep=@();Omit=@('No change needed. No change needed')},
    @{Row=(New-AppliedFixture 'Payment Gateway Middleware' 'Pass' 'Service settings verified; no changes needed');Label='No Change Needed';Keep=@('Service settings verified');Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'Firewall Inbound Port' 'Pass' '5009: No change needed; 4100: No change needed');Label='No Change Needed';Keep=@('5009','4100');Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'Printer' 'Pass' 'BIXOLON BK3-3: Enabled Keep printed documents; readback verified; EPSON TM-m30: No change needed');Label='Completed';Keep=@('BIXOLON BK3-3','Enabled Keep printed documents','EPSON TM-m30','Configuration verified.');Omit=@()},
    @{Row=(New-AppliedFixture 'Payment Gateway Middleware' 'Pass' 'Startup set to Automatic; service started; Crash recovery configured and verified');Label='Completed';Keep=@('Startup set to Automatic','Service started','Crash recovery configured');Omit=@()},
    @{Row=(New-AppliedFixture 'Zabbix Agent 2' 'Fail' 'Service started; monitoring hostname could not be verified. Manual action required.');Label='Manual Action Required';Keep=@('Service started','hostname could not be verified');Omit=@('<strong>Completed</strong>')},
    @{Row=(New-AppliedFixture 'Windows Update (wuauserv)' 'Fail' 'Startup set to Disabled; Failed: Access denied');Label='Manual Action Required';Keep=@('Startup set to Disabled','Access denied');Omit=@('<strong>Completed</strong>')},
    @{Row=(New-AppliedFixture 'KIOSK Account' 'Fail' 'Account Missing. Please create manually.');Label='Manual Action Required';Keep=@('Account Missing','Please create manually');Omit=@('<strong>Completed</strong>')},
    @{Row=(New-AppliedFixture 'Kiosk Launch Architecture' 'Fail' 'Startup BAT is missing. Desktop shortcut was not created.');Label='Manual Action Required';Keep=@('Startup BAT is missing','was not created');Omit=@('<strong>Completed</strong>')},
    @{Row=(New-AppliedFixture 'KIOSK Account' 'Pass' '');Label='Not Verified';Keep=@('Please check manually');Omit=@('Completed','No Change Needed')},
    @{Row=(New-AppliedFixture 'Kiosk Auto-Login' 'Pass' 'Existing auto-login settings recorded without changes; verify actual sign-in manually.');Label='Verified';Keep=@('actual sign-in manually');Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'PaymentService Restart Task' 'Pass' 'Existing task configuration verified; task execution was not tested.');Label='Verified';Keep=@('task execution was not tested');Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'System & Browser Policies' 'Pass' 'Added only --disable-pinch to the verified Edge argument string; content readback verified. Restart Edge and verify touchscreen zoom.');Label='Completed';Keep=@('--disable-pinch','Restart Edge','verify touchscreen zoom');Omit=@()},
    @{Row=(New-AppliedFixture 'KIOSK Account' 'Pass' 'ahamm: Enabled Password Never Expires; readback verified');Label='Completed';Keep=@('ahamm:','Enabled Password Never Expires');Omit=@('Ahamm:')},
    @{Row=(New-AppliedFixture 'Nmap Diagnostic Tool' 'Fail' 'Installer failed for C:\Tools\Nmap: <script>alert(1)</script> & access denied');Label='Manual Action Required';Keep=@('C:\Tools\Nmap','&lt;script&gt;','&amp;');Omit=@('<script>')},
    @{Row=(New-AppliedFixture 'Previous (Legacy)' 'Offline' 'No change needed; verified Stopped / Manual' 'Core Background Services' 'Type: Old Payment Service');Label='No Change Needed';Keep=@('Stopped / Manual');Omit=@('Manual Action Required')},
    @{Row=(New-AppliedFixture 'Windows Update (wuauserv)' 'Pass' 'No change needed; verified Stopped / Disabled; all recovery actions: Take No Action');Label='No Change Needed';Keep=@('Stopped / Disabled','Take No Action');Omit=@('Completed')},
    @{Row=(New-AppliedFixture 'Other service' 'Offline' 'Service was not verified' 'Core Background Services' 'Type: Service');Label='Manual Action Required';Keep=@('not verified');Omit=@('<strong>Completed</strong>')},
    @{Row=(New-AppliedFixture 'KIOSK Account' 'Pass' 'Properties verified; existing password retained');Label='Verified';Keep=@('existing password retained');Omit=@('Completed')}
)
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $path=Join-Path $sourceRoot $sourceName
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Applied (-not $errors.Count) 'Client source does not parse.'
    $functions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine))
    $script:ApplyChanges=$false
    foreach($case in $cases){
        $before=$case.Row | ConvertTo-Json -Depth 5 -Compress
        $html=Get-ThoroughReportAppliedHtml $case.Row
        if($case.Label -eq 'Read Only'){Assert-Applied ($html -ceq 'Read Only') 'AppSettings lost its exact Read Only label.'}
        else{Assert-Applied ($html.Contains(('<strong>'+$case.Label+'</strong>'))) ('Wrong outcome label for '+$case.Row.ActionTaken+': '+$html)}
        foreach($value in $case.Keep){Assert-Applied ($html.IndexOf($value,[StringComparison]::OrdinalIgnoreCase) -ge 0) ('Recorded detail was lost: '+$value)}
        foreach($value in $case.Omit){Assert-Applied (-not $html.Contains($value)) ('Misleading or unsafe content: '+$value)}
        Assert-Applied (($case.Row | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Presentation changed recorded results.'
        Assert-Applied (-not $script:ApplyChanges) 'Presentation enabled device repairs.'
    }
    Assert-Applied ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $hash) 'Test changed a client source.'
    Write-Output ('PASS: '+$sourceName+' / '+$cases.Count+' cases: completed repairs, no-op repeats, grouped resources, read-only checks, partial failures, missing notes, manual instructions and safe HTML.')
}
