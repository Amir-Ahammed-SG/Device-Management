# Run only definitions and the actual report finalizer. Never run device-check bodies.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output\single-file-reports\integration\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Combined {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Load-Definitions {param([string]$Path)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    [pscustomobject]@{Ast=$ast;Code=(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n")}
}
$launcher=Load-Definitions (Join-Path $projectRoot 'Start-DeviceManagement.ps1')
. ([scriptblock]::Create($launcher.Code))
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $source=Load-Definitions (Join-Path $sourceRoot $sourceName)
    . ([scriptblock]::Create($source.Code))
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $outer=$source.Ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($outer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Complete-ThoroughConsole {param($IsApply,$FailedCount,$IsFinal)}
    function Start-AuditStep {param($Number,$Name)}
    function Read-AuditReportChoice {return $script:GenerateFixtureReport}
    function Set-Service {throw 'Renderer attempted a service change.'}
    function Get-CimInstance {throw 'Renderer ran a device check.'}
    function Set-LocalUser {throw 'Renderer attempted an account change.'}
    function Start-Process {throw 'Renderer started a process.'}
    $outputFolder=Join-Path $fixtureRoot $client;[void][IO.Directory]::CreateDirectory($outputFolder)
    $reportRestaurantId='R-INTEGRATION';$deviceType='KIOSK';$reportKioskId='Kiosk-1';$KioskId=$null;$kioskUser='SELISE-KIOSK';$runId='COMBINED-FIXTURE'
    $script:GenerateFixtureReport=$true;$auditSnapshot=$null;$fixSnapshot=$null
    foreach($mode in @('Audit','Fix','Final')){
        $script:ApplyChanges=$mode -eq 'Fix';$FinalReport=$mode -eq 'Final'
        $reportHostname=$mode+'-LAUNCHER-HOST';$clientLocation=$mode+' Branch'
        $reportPath=Get-KioskReportPath -Folder $outputFolder -Client $clientLocation -Computer $env:COMPUTERNAME -IsApply $script:ApplyChanges -IsFinal $FinalReport -RunId $runId
        $auditRows=[Collections.Generic.List[psobject]]::new()
        $auditRows.Add([pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='Type: Event Viewer Channel';Shortcut='<code>eventvwr.msc</code>';FoundStateHtml='Enabled';Status='Pass';ActionTaken='No change needed'})
        $counterState=if($mode -eq 'Fix'){ConvertTo-ReportDefinitionHtml ([ordered]@{'Rebuild State'='Exit code: 0'})}else{ConvertTo-ReportDefinitionHtml ([ordered]@{'Audit'='Not executed'})}
        $auditRows.Add([pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='lodctr /R Performance Counter';ItemSub='Type: System Performance Rebuild';Shortcut='<code>perfmon</code>';FoundStateHtml=$counterState;Status=$(if($mode -eq 'Fix'){'Pass'}else{'Bypass'});ActionTaken=$(if($mode -eq 'Fix'){'Performance counters rebuilt; lodctr returned exit code 0'}else{'Not executed; health not verified'})})
        $before=$auditRows.ToArray() | ConvertTo-Json -Depth 6 -Compress
        . $render
        Assert-Combined (($auditRows.ToArray() | ConvertTo-Json -Depth 6 -Compress) -ceq $before) 'Rendering changed the observed device results.'
        Assert-Combined ((Test-CanApply) -eq ($mode -eq 'Fix')) 'Rendering a Final view changed the execution repair gate.'
        Assert-Combined (@(Get-ChildItem -LiteralPath $outputFolder -File).Count -eq 1) 'Modes created multiple persistent files.'
        $document=[IO.File]::ReadAllText($reportPath)
        $state=Read-ThoroughReportBundleState $document
        Assert-Combined ($state.LatestMode -ceq $mode -and $state.ClientType -ceq $client) 'Wrong mode or client was saved.'
        if($mode -eq 'Audit'){
            $auditSnapshot=$state.Reports.Audit.HtmlBase64
            Assert-Combined ($state.Reports.Fix.Origin -eq 'Audit observations' -and $state.Reports.Final.Origin -eq 'Audit observations') 'Audit did not supply the unrun Fix and Final views.'
            Assert-Combined ($state.Reports.Fix.ReportId -ceq $state.Reports.Audit.ReportId -and $state.Reports.Final.GeneratedAt -ceq $state.Reports.Audit.GeneratedAt) 'Audit-derived views invented another run identity or time.'
        }else{
            Assert-Combined ($state.Reports.Audit.HtmlBase64 -ceq $auditSnapshot) 'Another mode rewrote the saved Audit.'
            $finalHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($state.Reports.Final.HtmlBase64))
            if($mode -eq 'Fix'){
                $fixSnapshot=$state.Reports.Fix.HtmlBase64
                Assert-Combined ($state.Reports.Final.Origin -eq 'Apply Fix readback' -and $finalHtml.Contains('actual post-fix configuration observed during Apply Fix') -and $finalHtml.Contains('Rebuild State:</span> Exit code: 0')) 'Apply did not generate Final from its actual post-fix observations.'
            }else{
                Assert-Combined ($state.Reports.Fix.HtmlBase64 -ceq $fixSnapshot) 'Read-only Final changed the saved Fix.'
                Assert-Combined ($state.Reports.Final.Origin -eq 'Read-only verification' -and $finalHtml.Contains('Not executed (read-only verification)') -and $finalHtml.Contains('Recorded result: Bypass">Fail</span>')) 'Fresh Final reused an old rebuild Pass or ran a repair.'
            }
        }
        $hash=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash
        Update-ThoroughCheckHtmlReport -Path $reportPath -DeviceType KIOSK -ClientType $client
        Assert-Combined ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash -ceq $hash) 'Launcher rewrote the combined report.'
    }
    $script:ApplyChanges=$false;$FinalReport=$false;$script:GenerateFixtureReport=$false
    $before=[IO.File]::ReadAllText($reportPath);. $render
    Assert-Combined ([IO.File]::ReadAllText($reportPath) -ceq $before) 'Declining an Audit report updated the existing file.'
    # First-ever Apply has no fabricated Audit; it still provides Fix and Final.
    $script:ApplyChanges=$true;$FinalReport=$false;$outputFolder=Join-Path $fixtureRoot ($client+'-ApplyFirst');[void][IO.Directory]::CreateDirectory($outputFolder)
    $reportPath=Get-KioskReportPath -Folder $outputFolder -Client '' -Computer $env:COMPUTERNAME -IsApply $true -RunId 'FIRST-APPLY'
    . $render
    $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($reportPath))
    Assert-Combined ($null -eq $state.Reports.Audit -and $null -ne $state.Reports.Fix -and $null -ne $state.Reports.Final) 'Apply-first invented Audit or omitted post-fix Final.'
    Write-Output ('PASS: '+$client+' real finalizer persists one file across modes; Apply creates a post-fix Final; fresh Final is read-only; declined Audit, Apply-first and launcher validation are truthful.')
}
