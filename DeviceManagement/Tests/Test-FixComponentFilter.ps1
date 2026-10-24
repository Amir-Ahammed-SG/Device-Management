# Pure report fixtures and disposable output; never execute device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$output=Join-Path $projectRoot 'output\fix-component-filter'
$point=Get-Content -LiteralPath (Join-Path $projectRoot 'Backups\ReportLayouts\20261023-fix-component-filter-01.json') -Raw | ConvertFrom-Json
function Assert-FixFilter {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Read-FilterView {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
function New-FilterRow {
    param([string]$Title,[string]$Status='Pass',[string]$Value='Enabled',[string]$Note='No change needed',[int]$Section=1,[string]$SectionTitle='Hardware & Peripherals')
    [pscustomobject]@{SectionNumber=$Section;SectionTitle=$SectionTitle;ItemTitle=$Title;ItemSub='Fixture check';Shortcut='<code>services.msc</code>';Status=$Status;ActionTaken=$Note;ExpectedHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'State'='Enabled'}));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'State'=$Value}))}
}
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $name),[ref]$tokens,[ref]$errors)
    Assert-FixFilter ($errors.Count -eq 0) 'Client source failed parsing.'
    $definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    function Get-CimInstance {throw 'Renderer queried the device.'}
    function Set-Service {throw 'Renderer changed a service.'}
    function Start-Process {throw 'Renderer started a process.'}
    $script:ApplyChanges=$false
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $identity=[pscustomobject]@{ReportId='OMK-230001';GeneratedAt='23 Oct 2026, 4:15 PM BST'}
    $healthy=New-FilterRow 'Already correct'
    $needed=New-FilterRow 'Needs repair' Fail Disabled
    $manual=New-FilterRow 'Manual verification' Unknown 'Not verified. Please check manually.'
    $repaired=New-FilterRow 'Repaired this run' Pass Enabled 'Service started; readback verified' 3 'Core Background Services'
    $partial=New-FilterRow 'Partial repair' Fail Disabled 'Startup set to Automatic; service start denied. Manual action required.' 3 'Core Background Services'
    $readOnly=New-FilterRow 'Collected configuration' Pass Enabled 'Read only; values collected' 5 'AppSettings Check'
    $rows=@($healthy,$needed,$manual,$repaired,$partial,$readOnly)
    $before=$rows | ConvertTo-Json -Depth 8 -Compress
    $audit=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -AuditSource $identity -Hostname 'SAMPLE-DEVICE'
    $final=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AuditSource $identity -Hostname 'SAMPLE-DEVICE'
    # Audit and Final must remain byte-identical to the previous renderer.
    $savedRenderer=@($point.Clients | Where-Object FileName -EQ $name)[0].Changes | Where-Object Name -EQ 'New-ThoroughReportSnapshot'
    . ([scriptblock]::Create($savedRenderer.Before))
    $oldAudit=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -AuditSource $identity -Hostname 'SAMPLE-DEVICE'
    $oldFinal=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AuditSource $identity -Hostname 'SAMPLE-DEVICE'
    Assert-FixFilter ($oldAudit.HtmlBase64 -ceq $audit.HtmlBase64 -and $oldFinal.HtmlBase64 -ceq $final.HtmlBase64) 'Fix filtering changed Audit or Final.'
    . ([scriptblock]::Create(($definitions | Where-Object Name -EQ 'New-ThoroughReportSnapshot').Extent.Text))
    $derived=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AuditSource $identity
    $derivedHtml=Read-FilterView $derived
    Assert-FixFilter ($derivedHtml -notmatch 'device-title">(?:Already correct|Repaired this run|Collected configuration)</div>') 'Audit-derived Fix retained a healthy unchanged component or fabricated a repair.'
    Assert-FixFilter ($derivedHtml -match 'device-title">Needs repair</div>' -and $derivedHtml -match 'device-title">Manual verification</div>') 'A pending or unverified check was hidden.'
    Assert-FixFilter ($derivedHtml -notmatch '5\. AppSettings Check|>Completed</strong>') 'An empty section or unexecuted repair remains in derived Fix.'
    $fixed=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AfterApply $true -ClientLocation 'Sample branch' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -Hostname 'SAMPLE-DEVICE'
    $fixedHtml=Read-FilterView $fixed
    Assert-FixFilter ($fixedHtml -match 'device-title">Repaired this run</div>' -and $fixedHtml -match '>Completed</strong>' -and $fixedHtml.Contains('Service started')) 'A successful repair record was dropped.'
    Assert-FixFilter ($fixedHtml -match 'device-title">Partial repair</div>' -and $fixedHtml -match 'Service start denied') 'A partial repair or error detail was dropped.'
    Assert-FixFilter ($fixedHtml -notmatch 'device-title">Already correct</div>|5\. AppSettings Check') 'A healthy component or empty section remains in actual Fix.'
    foreach($status in @('Fail','Bypass','Unknown','Offline')){
        $unknown=New-FilterRow ('Unresolved '+$status) $status 'Not verified. Please check manually.'
        $view=New-ThoroughReportSnapshot -Rows @($unknown) -DisplayMode Fix -AuditSource $identity
        Assert-FixFilter ((Read-FilterView $view).Contains('device-title">Unresolved '+$status+'</div>')) 'An unresolved check was dropped based on its status.'
    }
    $contradiction=New-FilterRow 'Mismatch despite Pass' Pass Disabled
    $view=New-ThoroughReportSnapshot -Rows @($contradiction) -DisplayMode Fix -AuditSource $identity
    Assert-FixFilter ((Read-FilterView $view).Contains('device-title">Mismatch despite Pass</div>')) 'A visible mismatch was hidden by an aggregate Pass.'
    $unknownApp=New-FilterRow 'Unreadable configuration' Pass 'Not verified. Please check manually.' '' 5 'AppSettings Check'
    $view=New-ThoroughReportSnapshot -Rows @($unknownApp) -DisplayMode Fix -AuditSource $identity
    Assert-FixFilter ((Read-FilterView $view).Contains('Unreadable configuration') -and (Read-FilterView $view).Contains('Read Only')) 'Unverified configuration requiring manual review was dropped.'
    $allGood=@($healthy,$readOnly)
    $empty=New-ThoroughReportSnapshot -Rows $allGood -DisplayMode Fix -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -Hostname 'SAMPLE-DEVICE'
    $emptyHtml=Read-FilterView $empty
    Assert-FixFilter ($emptyHtml.Contains('No fixes required.') -and $emptyHtml -notmatch '<table class="checks"|class="device-title"') 'Healthy data did not produce the clean empty state.'
    $appliedEmpty=New-ThoroughReportSnapshot -Rows $allGood -DisplayMode Fix -AfterApply $true
    Assert-FixFilter ((Read-FilterView $appliedEmpty).Contains('No fixes required.')) 'A no-op Apply retained healthy components.'
    $noData=New-ThoroughReportSnapshot -Rows @() -DisplayMode Fix -AuditSource $identity
    Assert-FixFilter ((Read-FilterView $noData).Contains('No findings available.') -and -not (Read-FilterView $noData).Contains('No fixes required.')) 'Missing observations were reported as a healthy device.'
    $legacy=New-FilterRow 'Legacy service (Legacy)' Offline Enabled 'No change needed'
    $legacy.ItemSub='Type: Old Payment Service'
    $view=New-ThoroughReportSnapshot -Rows @($legacy) -DisplayMode Fix -AuditSource $identity
    Assert-FixFilter ((Read-FilterView $view).Contains('No fixes required.')) 'An expected healthy stopped legacy service was treated as a failure.'
    $legacy.ActionTaken='Startup set to Manual; service stop requested; readback verified'
    $view=New-ThoroughReportSnapshot -Rows @($legacy) -DisplayMode Fix -AfterApply $true
    Assert-FixFilter ((Read-FilterView $view).Contains('Legacy Payment Services') -and (Read-FilterView $view).Contains('Completed')) 'A grouped legacy repair record was dropped.'
    Assert-FixFilter (($rows | ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'Filtering mutated original observations.'
    Assert-FixFilter (-not (Test-CanApply)) 'Filtering enabled the repair gate.'
    $reports=[pscustomobject]@{Audit=$audit;Fix=$fixed;Final=$final}
    $bundle=[pscustomobject]@{Version=1;TestOnly=$true;ClientType=$client;ComputerName='SAMPLE-DEVICE';BundleId='OMK-230002';CreatedAt='2026-10-23';UpdatedAt='2026-10-23';LatestMode='Fix';Reports=$reports}
    [IO.File]::WriteAllText((Join-Path $output ($client+'-Fix-Report-Preview.html')),(New-ThoroughReportBundleHtml $bundle),(New-Object Text.UTF8Encoding($false)))
    $bundle.Reports.Fix=$empty
    $bundle.Reports.Audit=New-ThoroughReportSnapshot -Rows $allGood -DisplayMode Audit -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -Hostname 'SAMPLE-DEVICE'
    $bundle.Reports.Final=New-ThoroughReportSnapshot -Rows $allGood -DisplayMode Final -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -LauncherKioskId 'Kiosk-1' -Hostname 'SAMPLE-DEVICE'
    [IO.File]::WriteAllText((Join-Path $output ($client+'-No-Fixes-Preview.html')),(New-ThoroughReportBundleHtml $bundle),(New-Object Text.UTF8Encoding($false)))
    Write-Output ('PASS: '+$client+' healthy components/empty sections omitted; actual and partial repairs, unknown/manual checks retained; no-op summary; Audit/Final byte-identical; data and repair gate unchanged.')
}
