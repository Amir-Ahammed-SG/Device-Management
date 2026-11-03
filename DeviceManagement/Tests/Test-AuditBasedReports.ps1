. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Real renderer and report persistence, disposable data only. No device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output\audit-based-reports\fixtures\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-AuditView {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Decode-View {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $name),[ref]$tokens,[ref]$errors)
    Assert-AuditView ($errors.Count -eq 0) 'Source failed parsing.'
    . ([scriptblock]::Create((($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n")))
    Use-SettingLayoutRuleAssertions -SourceName $name
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $path=Join-Path $fixtureRoot ($client+'.html')
    function Set-Service {throw 'Report attempted a service mutation.'}
    function Get-CimInstance {throw 'Report attempted a device check.'}
    function Start-Process {throw 'Report attempted to start a process.'}
    $row=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='System & Browser Policies';ItemSub='Verified configuration';Shortcut='<code>regedit</code>';Status='Fail';ActionTaken='Audit only; existing configuration preserved';FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Translation'='Disabled';'Visual Search'='Enabled';'Edge Gestures'='Not verified. Please check manually.'}))}
    $good=[pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='Type: Event Viewer Channel';Shortcut='<code>eventvwr.msc</code>';Status='Pass';ActionTaken='No change needed';FoundStateHtml='Enabled'}
    $app=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='PaymentService';ItemSub='Read only';Shortcut='';Status='Pass';ActionTaken='Collected';FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Payment Service'='NETS';'IsEnabled'=$false}))}
    $rows=@($good,$row,$app)
    $before=$rows | ConvertTo-Json -Depth 6 -Compress
    $script:ApplyChanges=$false
    $audit=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -ClientLocation 'Audit branch' -DeviceType KIOSK -Hostname 'AUDIT-HOST'
    $fix=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AuditSource $audit -ClientLocation 'Audit branch' -DeviceType KIOSK -Hostname 'AUDIT-HOST'
    $final=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AuditSource $audit -ClientLocation 'Audit branch' -DeviceType KIOSK -Hostname 'AUDIT-HOST'
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($audit,$fix,$final) Audit)
    $document=[IO.File]::ReadAllText($path);$state=Read-ThoroughReportBundleState $document
    [IO.File]::WriteAllText((Join-Path $projectRoot ('output\audit-based-reports\'+$client+'-Audit-Based-Report.html')),$document,(New-Object Text.UTF8Encoding($false)))
    Assert-AuditView (-not $document.Contains('<select id="bundle-client"')) 'Production report still has a Client selector.'
    foreach($mode in @('Fix','Final')){
        Assert-AuditView ($state.Reports.$mode.Origin -eq 'Audit observations' -and $state.Reports.$mode.ReportId -ceq $audit.ReportId -and $state.Reports.$mode.GeneratedAt -ceq $audit.GeneratedAt) 'Derived view lost its Audit origin, identity or time.'
    }
    $fixHtml=Decode-View $state.Reports.Fix;$finalHtml=Decode-View $state.Reports.Final
    Assert-AuditView (($rows | ConvertTo-Json -Depth 6 -Compress) -ceq $before) 'Rendering changed the observed input rows.'
    Assert-AuditView ($fixHtml.Contains('Visual Search:</span> Enabled') -and $fixHtml.Contains('Required: Disabled') -and $fixHtml.Contains('Edge Gestures:</span> Not verified.')) 'Fix lost a required repair or manual verification.'
    Assert-AuditView (-not $fixHtml.Contains('Translation:</span> Disabled')) 'Fix repeats a correct non-identity value.'
    Assert-AuditView (-not $fixHtml.Contains('device-title">PrintService Log</div>') -and $fixHtml.Contains('>Not Applied</strong>') -and -not $fixHtml.Contains('>Completed</strong>')) 'Audit-derived Fix claims a repair or repeats healthy components.'
    Assert-AuditView (-not $fixHtml.Contains('5. AppSettings Check') -and $finalHtml.Contains('Payment Service:</span> NETS') -and $finalHtml.Contains('IsEnabled:</span> False')) 'Healthy read-only configuration was not limited to the complete reports.'
    Assert-AuditView ($finalHtml.Contains('Translation:</span> Disabled') -and $finalHtml.Contains('Visual Search:</span> Enabled') -and $finalHtml.Contains('Recorded result: Fail">Fail</span>') -and $finalHtml -notmatch 'class="finding-value finding-|#(?:e8f5e9|fdecec|fff8e1)') 'Audit-derived Final lost observations, failures or neutral formatting.'
    $informationalMismatch=$row.PSObject.Copy();$informationalMismatch.Status='Pass'
    $pending=New-ThoroughReportSnapshot -Rows @($informationalMismatch) -DisplayMode Fix -AuditSource $audit
    Assert-AuditView ((Decode-View $pending).Contains('>Not Applied</strong>') -and -not (Decode-View $pending).Contains('>No Change Needed</strong>')) 'A field requiring attention was labelled No Change Needed from the aggregate status alone.'
    # A subsequent Audit refreshes the two derived views before any Fix run.
    $row.FoundStateHtml=$row.FoundStateHtml.Replace('Enabled','Missing')
    $second=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -Hostname 'SECOND-AUDIT'
    $derived=@($second;(New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AuditSource $second -Hostname 'SECOND-AUDIT');(New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AuditSource $second -Hostname 'SECOND-AUDIT'))
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' $derived Audit)
    $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-AuditView ($state.Reports.Fix.ReportId -ceq $second.ReportId -and (Decode-View $state.Reports.Final).Contains('SECOND-AUDIT')) 'A newer Audit did not refresh derived views.'
    # Fix updates the two views from actual post-fix observations and preserves Audit.
    $row.Status='Pass';$row.ActionTaken='Added Visual Search; readback verified';$row.FoundStateHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{'Translation'='Disabled';'Visual Search'='Disabled';'Edge Gestures'='Disabled'})
    $realFix=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AfterApply $true -Hostname 'POST-FIX'
    $realFinal=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AfterApply $true -Hostname 'POST-FIX'
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($realFix,$realFinal) Fix)
    $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-AuditView ($state.Reports.Audit.HtmlBase64 -ceq $second.HtmlBase64 -and $state.Reports.Final.Origin -eq 'Apply Fix readback' -and (Decode-View $state.Reports.Fix).Contains('No further fix needed.') -and (Decode-View $state.Reports.Fix).Contains('>Completed</strong>')) 'Actual Fix lost the saved Audit, recorded actions or final readback.'
    Copy-Item -LiteralPath $path -Destination (Join-Path $projectRoot ('output\audit-based-reports\'+$client+'-After-Fix-Report.html')) -Force
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' $derived Audit)
    $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-AuditView ($state.Reports.Fix.HtmlBase64 -ceq $realFix.HtmlBase64 -and $state.Reports.Final.HtmlBase64 -ceq $realFinal.HtmlBase64) 'Audit-derived data overwrote an actual Fix run.'
    # Failed readback and unstructured failures are retained, never changed into No fix needed.
    $failed=$row.PSObject.Copy();$failed.Status='Fail';$failed.FoundStateHtml='Service query failed. Please check manually.'
    $failedView=New-ThoroughReportSnapshot -Rows @($failed) -DisplayMode Fix -AfterApply $true
    Assert-AuditView ((Decode-View $failedView).Contains('Service query failed. Please check manually.') -and (Decode-View $failedView).Contains('Manual Action Required')) 'An unstructured failed readback was suppressed.'
    Assert-AuditView (-not (Test-CanApply)) 'Rendering enabled the repair gate.'
    Write-Output ('PASS: '+$client+' Audit-derived views, production selector removal, issue-only Findings, honest Applied labels, neutral Final, refresh/real-run precedence and failed-readback preservation.')
}
