
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Synthetic observations and report rendering only; no device operations.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$previewRoot=Join-Path $projectRoot 'output/client-details-preview'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-Header {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$identity=[pscustomobject]@{ReportId='OMK-123456';GeneratedAt='03 Nov 2026, 1:20 PM BST'}
$cases=@(
    @{Launcher='Kiosk-1';Requested='Kiosk-2';Number='01'},
    @{Launcher='kiosk-01';Requested='';Number='01'},
    @{Launcher='KIOSK105';Requested='';Number='105'},
    @{Launcher='7';Requested='';Number='07'},
    @{Launcher='Not detected';Requested='Kiosk-3';Number='03'},
    @{Launcher='';Requested='';Number='Not verified'},
    @{Launcher='Front Desk & <East>';Requested='';Number='Front Desk & <East>'}
)
foreach($client in @('SaaS','Subway')){
    $name=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot $name),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $script:ApplyChanges=$false
    $previews=[ordered]@{}
    foreach($mode in @('Audit','Fix','Final')){
        foreach($case in $cases){
            $snapshot=New-ThoroughReportSnapshot -Rows @() -DisplayMode $mode -AuditSource $identity -ClientLocation 'Veeva Acai - Bochum & <fixture>' -AgentName 'Test Agent' -DeviceType KIOSK -Hostname 'DESKTOP-JKKO5ID' -LauncherRestaurantId 'R-123 & <fixture>' -LauncherKioskId $case.Launcher -RequestedKioskId $case.Requested
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            $metadata=[regex]::Match($html,'(?is)<table class="metadata"[^>]*>(.*?)</table>').Groups[1].Value
            $labels=@([regex]::Matches($metadata,'<th>(.*?)</th>') | ForEach-Object {$_.Groups[1].Value})
            Assert-Header (($labels -join '|') -ceq 'Client Type|Branch|Restaurant ID|Hostname|Device|Prepared by') 'Client detail fields are out of order.'
            Assert-Header ($html.Contains('<h2>CLIENT DETAILS</h2>') -and -not $html.Contains('<h2>REPORT DETAILS</h2>')) 'Client details heading is incorrect.'
            Assert-Header ($metadata.Contains('<th>Client Type</th><td>'+$client+'</td>')) 'The selected client was lost.'
            $expectedDevice=if($case.Number -eq 'Not verified'){'Kiosk (number not verified)'}elseif($case.Number -match '^\d+$'){'Kiosk-'+([uint32]$case.Number)}else{'Kiosk - '+$case.Number}
            Assert-Header ($metadata.Contains('<th>Device</th><td>'+[Net.WebUtility]::HtmlEncode($expectedDevice)+'</td>')) 'Merged device label is incorrect.'
            Assert-Header ($metadata.Contains('<th>Prepared by</th><td>Test Agent</td>') -and $metadata -notmatch 'Device Number|Device Type') 'Prepared by did not replace the separate device number.'
            Assert-Header ($metadata.Contains('Bochum &amp; &lt;fixture&gt;') -and $metadata.Contains('R-123 &amp; &lt;fixture&gt;')) 'Metadata was not safely encoded.'
            Assert-Header (-not $metadata.Contains('Generated Time')) 'Generated Time remains in the header.'
            $footer=[regex]::Match($html,'(?is)<footer class="report-footer">(.*?)</footer>').Groups[1].Value
            Assert-Header ($footer.Contains('<strong>Generated Time:</strong> '+$identity.GeneratedAt) -and $footer.Contains('<strong>Prepared by:</strong> Test Agent')) 'Footer time or agent is missing.'
            Assert-Header ($snapshot.ReportId -ceq $identity.ReportId -and $snapshot.GeneratedAt -ceq $identity.GeneratedAt) 'Presentation changed the report identity or time.'
            if($case -eq $cases[0]){
                $previews[$mode]=$snapshot
                [IO.File]::WriteAllText((Join-Path $previewRoot ($client+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
            }
        }
    }
    $state=[pscustomobject]@{Version=1;ClientType=$client;ComputerName='FIXTURE-PC';BundleId='OMK-123456';Reports=[pscustomobject]$previews;LatestMode='Audit'}
    $bundle=New-ThoroughReportBundleHtml $state
    $roundTrip=Read-ThoroughReportBundleState $bundle
    Assert-Header ($roundTrip.Reports.Final.GeneratedAt -ceq $identity.GeneratedAt) 'Header reordering broke the saved report.'
    [IO.File]::WriteAllText((Join-Path $previewRoot ($client+'-Combined.html')),$bundle,[Text.UTF8Encoding]::new($false))
    Write-Output ('PASS: '+$client+' Audit/Fix/Final client details order, device numbers, safe values, footer timestamp/agent and saved-report round-trip.')
}
