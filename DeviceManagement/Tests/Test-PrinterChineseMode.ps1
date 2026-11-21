. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('output\printer-chinese-mode\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert-ChineseMode {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    Set-KioskTestClient $client
    $sourceText=[KioskTestSource]::ReadAllText((Join-Path $root 'KioskThoroughCheck.ps1'))
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-ChineseMode (-not $errors.Count) 'Expanded engine does not parse.'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-Printer {throw 'Read-only rendering queried printers'}
    function Set-Printer {throw 'Chinese mode must remain read-only'}
    function Restart-Service {throw 'Chinese mode must not restart a service'}
    $required=Get-ThoroughServiceEndpointRequirements
    function New-ChineseConfig {
        param($Value,[switch]$Missing)
        $print=[ordered]@{PrinterName='Kitchen';KioskPrinterName='POSPrinter POS-80'}
        if(-not $Missing){$print.KioskPrinterDisableChineseMode=$Value}
        [pscustomobject]@{PaymentService='PRINT';Print=[pscustomobject]$print;ScheduleConfiguration=[pscustomobject]@{Provider='KitchenTicketPrint';BranchUUID='FIXTURE-BRANCH';IsKioskPrintingEnabled=$true;IsEnabled=$false};MonitoringServiceBaseUrl=$required.MonitoringServiceBaseUrl;CmsGatewayBaseUrl=$required.CmsGatewayBaseUrl;OrderServiceBaseUrl=$required.OrderServiceBaseUrl}
    }
    $cases=@(
        @{Id='boolean-true';Value=$true;Text='True';State='match';Pass=$true},
        @{Id='string-true';Value='true';Text='True';State='match';Pass=$true},
        @{Id='uppercase';Value='TRUE';Text='True';State='match';Pass=$true},
        @{Id='boolean-false';Value=$false;Text='False';State='mismatch';Pass=$false},
        @{Id='string-false';Value='false';Text='False';State='mismatch';Pass=$false},
        @{Id='empty';Value='';Text='(empty)';State='unverified';Pass=$false},
        @{Id='null';Value=$null;Text='Not configured';State='unverified';Pass=$false},
        @{Id='missing';Missing=$true;Text='Not configured';State='unverified';Pass=$false},
        @{Id='invalid';Value='enabled';Text='enabled';State='mismatch';Pass=$false},
        @{Id='numeric';Value=1;Text='1';State='mismatch';Pass=$false}
    )
    foreach($version in @('12.9.0','13.0','13.4.2.1','14.0.0','Not verified','','v13')){
        $isV13=$version -in @('13.0','13.4.2.1')
        foreach($case in $cases){
            $configuration=New-ChineseConfig -Value $case.Value -Missing:([bool]$case.Missing)
            $source=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';Shortcut='<code>notepad.exe appsettings.json</code>';ConfigurationSnapshot=$configuration;ConfigurationServiceVersion=$version;FoundStateHtml='Recorded';Status='Pass';ActionTaken='Read only'}
            $before=$source | ConvertTo-Json -Depth 12 -Compress
            $row=@(Get-ThoroughAppSettingsReportRows $source | Where-Object ItemTitle -EQ 'Print')[0]
            $fields=Get-ThoroughReportHighlightFields $row.FoundStateHtml
            Assert-ChineseMode ($fields.ContainsKey('KioskPrinterDisableChineseMode') -eq $isV13) ('Wrong version scope: '+$version)
            Assert-ChineseMode (($row.Status -eq 'Pass') -eq (-not $isV13 -or $case.Pass)) 'A false/missing v13 value was reported healthy, or another version was affected.'
            if($isV13){
                Assert-ChineseMode ($fields.KioskPrinterDisableChineseMode -ceq $case.Text) 'Boolean display is not normalized.'
                $requirements=Get-ThoroughReportHighlightFields $row.ExpectedHtml
                Assert-ChineseMode ($requirements.KioskPrinterDisableChineseMode -ceq 'True') 'Required Chinese mode is not True.'
                $highlighted=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml (Format-ThoroughReportFieldLabels $row.FoundStateHtml) -RequirementHtml (Format-ThoroughReportFieldLabels $row.ExpectedHtml)
                $field=@(Read-ThoroughAuditFields $highlighted | Where-Object Label -EQ 'Disable Chinese Mode')
                Assert-ChineseMode ($field.Count -eq 1 -and $field[0].State -eq $case.State) 'Chinese mode has an incorrect finding color.'
                Assert-ChineseMode ((Test-ThoroughAppSettingsReview $row) -eq (-not $case.Pass)) 'Chinese mode did not retain manual review for incorrect/missing values.'
                Assert-ChineseMode ((Get-ThoroughReportAppliedHtml $row) -notmatch 'Completed') 'Read-only Chinese mode was reported as repaired.'
            }
            $lines=@(Get-ThoroughPaymentConfigurationAuditLines -Configuration $configuration -ServiceName FixturePayment -ConfigurationPath 'fixture.json' -ServiceVersion $version)
            Assert-ChineseMode ((($lines -join "`n") -match 'Disable Chinese Mode:') -eq $isV13) 'Raw inspection has the wrong v13 scope.'
            Assert-ChineseMode (($source | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'Reading Chinese mode changed recorded settings.'
        }
    }
    foreach($case in $cases){
        $source=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';Shortcut='<code>notepad.exe appsettings.json</code>';ConfigurationSnapshot=(New-ChineseConfig -Value $case.Value -Missing:([bool]$case.Missing));ConfigurationServiceVersion='13.0.0';FoundStateHtml='Recorded';Status='Pass';ActionTaken='Read only'}
        foreach($mode in @('Audit','Fix','Final')){
            $snapshot=New-ThoroughReportSnapshot -Rows @($source) -BeforeRows @($source) -DisplayMode $mode -AfterApply:($mode -eq 'Fix') -Hostname FIXTURE-PC
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            if($mode -eq 'Audit'){
                $view=Get-AuditRenderedComponent $html Printer
                $field=@($view.Fields | Where-Object Setting -EQ 'Disable Chinese Mode')
                Assert-ChineseMode ($field.Count -eq 1 -and $field[0].Required -eq 'True' -and $field[0].Found -ceq $case.Text) 'Audit lost the v13 setting or displayed a different value.'
            }elseif($mode -eq 'Fix' -and -not $case.Pass){
                $view=Get-SettingRenderedComponent $html Printer
                $field=@($view.Fields | Where-Object Setting -EQ 'Disable Chinese Mode')
                Assert-ChineseMode ($field.Count -eq 1 -and $field[0].Value -eq 'Not applied') 'Apply claimed to change the read-only Chinese mode.'
            }
            if($case.Id -in @('string-true','boolean-false','missing')){[IO.File]::WriteAllText((Join-Path $fixture ($client+'-'+$mode+'-'+$case.Id+'.html')),$html,[Text.UTF8Encoding]::new($false))}
        }
    }
    # Exercise the actual engine inspection in Audit and Apply with correct URLs.
    $start=$sourceText.IndexOf("    `$configurationStatus = 'Pass'");$end=$sourceText.IndexOf('    $appSettingsRowAdded = $true',$start)
    $inspection=[scriptblock]::Create($sourceText.Substring($start,$end-$start))
    $folder=Join-Path $fixture $client;[void][IO.Directory]::CreateDirectory($folder)
    $primaryExecutablePath=Join-Path $folder 'FixturePayment.exe';[IO.File]::WriteAllText($primaryExecutablePath,'Fixture only')
    $primaryService=[pscustomobject]@{Name='FixturePayment'};$primaryServiceState='Running';$secAppNum=5;$secAppTitle='AppSettings Check'
    function Get-ThoroughAppSettingsPrinterInventory {return}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    foreach($primaryServiceVersion in @('12.0.0','13.0.0','14.0.0','Not verified')){
        foreach($apply in @($false,$true)){
            foreach($case in $cases){
                $json=New-ChineseConfig -Value $case.Value -Missing:([bool]$case.Missing) | ConvertTo-Json -Depth 8
                $path=Join-Path $folder 'appsettings.json';[IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
                $original=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
                $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$apply
                . $inspection
                $isV13=$primaryServiceVersion -eq '13.0.0'
                Assert-ChineseMode ($auditRows[0].ConfigurationServiceVersion -ceq $primaryServiceVersion) 'Engine lost the detected service version.'
                Assert-ChineseMode (($auditRows[0].Status -eq 'Pass') -eq (-not $isV13 -or $case.Pass)) 'Engine aggregate did not reflect the read-only v13 requirement.'
                Assert-ChineseMode ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $original) 'Audit/Apply changed the Chinese-mode key or added it when missing.'
            }
        }
    }
    $configuration=New-ChineseConfig -Value $false
    $configuration.MonitoringServiceBaseUrl='https://old.example.test/monitor'
    $path=Join-Path $folder 'appsettings.json';[IO.File]::WriteAllText($path,($configuration | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $script:ApplyChanges=$true
    $repair=Set-ThoroughServiceEndpoints -Path $path -BackupFolder (Join-Path $folder 'backups')
    $after=ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($path))
    Assert-ChineseMode ($repair.Changed -and $after.MonitoringServiceBaseUrl -eq $required.MonitoringServiceBaseUrl -and $after.Print.KioskPrinterDisableChineseMode -ceq $false) 'The endpoint Apply repair changed read-only Chinese mode.'
    Write-Output ('PASS: '+$client+' v13-only Chinese mode; Boolean/string display; false/missing/invalid values; immutable Audit/Apply, detected-version wiring and report rendering.')
}
