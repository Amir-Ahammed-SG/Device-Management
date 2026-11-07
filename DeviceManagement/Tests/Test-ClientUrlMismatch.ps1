. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Actual parsing and rendering against disposable launchers; no device mutations.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output/client-url-mismatch/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-ClientUrl {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    $sourceName=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $tokens=$null;$parseErrors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot $sourceName),[ref]$tokens,[ref]$parseErrors)
    Assert-ClientUrl (-not $parseErrors.Count) 'Shared engine parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-ThoroughDeviceHostname {return 'HOST-01'}
    function Read-Host {throw 'URL diagnostics must not prompt'}
    function Set-KioskLauncherHostname {throw 'Wrong-client launcher must not be rewritten'}
    function Get-CimInstance {throw 'Rendering must not query the device'}
    $other=if($client -eq 'SaaS'){'Subway'}else{'SaaS'}
    $ownOrigin=$script:KioskClientSettings.Origin
    $otherOrigin=$script:KioskClientSettings.ClientOrigins[$other]
    foreach($applyMode in @($false,$true)){
        $script:ApplyChanges=$applyMode
        foreach($case in @('matching','other-client','unknown-site','lookalike')){
            $origin=switch($case){'matching'{$ownOrigin};'other-client'{$otherOrigin};'unknown-site'{'https://other.example.test'};'lookalike'{$otherOrigin+'.evil.example.test'}}
            $url=$origin+'/#/onboarding/login?restaurantId=R1&kioskId=KIOSK-01&host=HOST-01'
            $launcher=Join-Path $fixtureRoot ($client+'-'+$case+'-'+$applyMode+'.ps1')
            [IO.File]::WriteAllText($launcher,('Start-Process msedge.exe -ArgumentList ''--kiosk '+$url+''' '+"`n"+'throw "Never execute a fixture launcher"'),[Text.UTF8Encoding]::new($false))
            $hash=(Get-FileHash -LiteralPath $launcher).Hash
            $script:ApplyChanges=$false
            $inspection=Repair-LauncherDetails -Path $launcher -Hostname HOST-01
            $script:ApplyChanges=$applyMode
            Assert-ClientUrl (($inspection.Status -eq 'Pass') -eq ($case -eq 'matching')) 'Wrong client or unknown origin falsely passed'
            Assert-ClientUrl ($inspection.LauncherValues['Host Name'] -eq 'HOST-01' -and $inspection.LauncherValues['KIOSK ID'] -eq 'KIOSK-01' -and $inspection.LauncherValues['Restaurant ID'] -eq 'R1') 'Wrong-client detection hid readable launcher values'
            $launchRow=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Kiosk Launch Architecture';ItemSub='';Shortcut=$inspection.Shortcut;FoundStateHtml=$inspection.StateHtml;Status=$inspection.Status;ActionTaken=$inspection.Action;ExpectedHostName='HOST-01'}
            $policyRow=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='System & Browser Policies';ItemSub='';Shortcut='regedit';FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Local Network Allowlist'=$origin;'Translation'='Disabled';'Visual Search'='Disabled';'Edge Gestures'='Disabled';'Additional allowlist entry 2'=$otherOrigin+' (preserved)';'Pinch-to-Zoom'='Disabled'}));Status=$inspection.Status;ActionTaken='Existing values preserved; no changes made.'}
            $rows=@($launchRow,$policyRow)
            $before=ConvertTo-Json -InputObject $rows -Depth 16 -Compress
            foreach($mode in @('Audit','Fix','Final')){
                $snapshot=New-ThoroughReportSnapshot -Rows $rows -BeforeRows $rows -DisplayMode $mode -AfterApply $applyMode
                $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
                [IO.File]::WriteAllText((Join-Path $fixtureRoot ($client+'-'+$case+'-'+$applyMode+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
                if($case -eq 'matching'){
                    Assert-ClientUrl ($html -notmatch '<span class="client-url-note">') 'Matching URL or optional extra permission was falsely labeled a mismatch'
                    continue
                }
                $expected='Wrong URL'
                Assert-ClientUrl ($html.Contains('<span class="client-url-note">'+$expected+'</span>')) ('Missing visible diagnosis: '+$client+'/'+$case+'/'+$mode)
                Assert-ClientUrl ($html -notmatch 'Wrong URL:|URL detected;|does not match the selected') 'The URL badge contains an explanatory sentence'
                foreach($componentName in @('Kiosk Launch Script','System & Browser Policies')){
                    $component=if($mode -eq 'Audit'){Get-AuditRenderedComponent $html $componentName}else{Get-SettingRenderedComponent $html $componentName}
                    $notes=@([regex]::Matches($component.Html,'<span class="client-url-note">'))
                    $expectedCount=if($mode -eq 'Fix' -and $applyMode){2}else{1}
                    Assert-ClientUrl ($component.Count -eq 1 -and $notes.Count -eq $expectedCount) 'Diagnosis was missing, duplicated or attached to an optional entry'
                    Assert-ClientUrl ([regex]::Matches($component.Html,'<span class="client-url-inline">').Count -eq $expectedCount -and $html.Contains('style="table-layout:auto"')) 'URL and badge are not kept together with room for their full width'
                    Assert-ClientUrl ($component.Html.Contains($origin) -and $component.Html.Contains('finding-mismatch')) 'URL or requirement mismatch styling was lost'
                }
            }
            Assert-ClientUrl ((ConvertTo-Json -InputObject $rows -Depth 16 -Compress) -ceq $before -and (Get-FileHash -LiteralPath $launcher).Hash -ceq $hash -and $script:ApplyChanges -eq $applyMode) 'Diagnostics changed observations, launcher contents or Apply mode'
        }
    }
    $settings=Get-KioskClientSettings -ClientType $client -ProjectRoot $projectRoot
    $settings.ClientOrigins[$other]='https://changed.example.test'
    $fresh=Get-KioskClientSettings -ClientType $client -ProjectRoot $projectRoot
    Assert-ClientUrl ($fresh.ClientOrigins[$other] -eq $otherOrigin) 'Origin map mutations leaked into shared configuration'
    Write-Output ('PASS: '+$client+' URL diagnosis in Audit/Fix/Final; matched/opposite/unknown/lookalike origins, literal launcher values, retained failures, read-only behavior and copied client origins.')
}
