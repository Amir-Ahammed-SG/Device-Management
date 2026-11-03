. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Read definitions and render fixtures only. Never execute device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output\final-mode-verification'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-Final {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
Import-Module (Join-Path $projectRoot 'Core\Validation.psm1') -Force
Import-Module (Join-Path $projectRoot 'Core\Context.psm1') -Force
$operations=Import-PowerShellDataFile (Join-Path $projectRoot 'Config\Operations.psd1')
$clients=Import-PowerShellDataFile (Join-Path $projectRoot 'Config\Clients.psd1')
foreach($operation in $operations.Operations){
    $modes=@(Get-OperationModes $operations ([pscustomobject]$operation) 'SaaS' 'KIOSK')
    Assert-Final ($modes.Id -notcontains 'Final') ('Standalone Final is still visible for '+$operation.Id)
    if($operation.Id -eq 'ThoroughCheck'){
        Assert-Final (($modes.DisplayName -join '|') -ceq 'Audit Report|Apply Fix') 'Mode order or names changed.'
    }
}
$rejected=$false
try{Assert-RunSelection $clients $operations 'SaaS' 'KIOSK' 'PaymentService' 'Final' | Out-Null}catch{$rejected=$true}
Assert-Final $rejected 'Final could be routed to a payment installation.'

$handler=[IO.File]::ReadAllText((Join-Path $projectRoot 'Checks\KIOSK\ThoroughCheck.ps1'))
$argumentStart=$handler.IndexOf('$arguments = @(')
$argumentEnd=$handler.IndexOf('$startedAt =',$argumentStart)
$buildArguments=[scriptblock]::Create($handler.Substring($argumentStart,$argumentEnd-$argumentStart))
$Context=New-DeviceManagementContext -ClientType SaaS -DeviceType KIOSK -Operation ThoroughCheck -Mode Final -RootPath $projectRoot -ClientLocation 'Known Branch'
$legacyScript='C:\Fixture with spaces\Client.ps1'
. $buildArguments
Assert-Final ($arguments -contains '-FinalReport' -and $arguments -notcontains '-Apply' -and $arguments -notcontains '-AuditOnly') 'Local Final dispatch mixed mutation flags.'
Assert-Final ($arguments -contains '-ClientLocation' -and $arguments -contains 'Known Branch') 'Local Final lost the known branch.'
Assert-Final (-not (Test-Path -LiteralPath $completionPath)) 'Argument construction created a completion file.'

foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $path=Join-Path $sourceRoot $sourceName
    $text=[IO.File]::ReadAllText($path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Final ($errors.Count -eq 0) 'Client source failed to parse.'
    Assert-Final ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'FinalReport') 'Client has no FinalReport parameter.'
    $functions=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    function Read-Host {throw 'Final requested interactive configuration.'}
    function Confirm-KioskApply {throw 'Final attempted Apply confirmation.'}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount,$IsFinal)}
    function Read-AuditReportChoice {return $script:GenerateFixtureReport}
    $guard=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match 'Use only one of'})[0]
    $guardCode=[scriptblock]::Create($guard.Extent.Text)
    foreach($combination in @(@($false,$false,$true),@($true,$false,$true),@($false,$true,$true),@($true,$true,$false))){
        $Apply=$combination[0];$AuditOnly=$combination[1];$FinalReport=$combination[2]
        $caught=$false
        try{. $guardCode}catch{$caught=$true}
        Assert-Final ($caught -eq (@($combination | Where-Object {$_}).Count -gt 1)) 'Mixed mode switches were accepted.'
    }
    $Apply=$false;$AuditOnly=$false;$FinalReport=$true;$WhatIfPreference=$false
    $start=$text.IndexOf('$script:ApplyChanges = $false')
    $end=$text.IndexOf('$runMode =',$start)
    . ([scriptblock]::Create($text.Substring($start,$end-$start)))
    Assert-Final (-not (Test-CanApply) -and -not $Apply -and -not $AuditOnly) 'Final enabled repairs or used Audit prompts.'

    $finalizer=$ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    $auditRows=New-Object 'Collections.Generic.List[psobject]'
    $fixtures=@(
        @{Section=2;Title='Kiosk Application & Policies';Item='KIOSK Account';Sub='';State='Account Missing. Please create manually.';Status='Fail'},
        @{Section=3;Title='Core Background Services';Item='PreviousPayment (Legacy)';Sub='Type: Old Payment Service';State='Stopped';Status='Offline'},
        @{Section=4;Title='Security, Network & System Integrity';Item='Inbound TCP 5009 Rule';Sub='Type: Firewall Rule Presence';State='Available';Status='Pass'},
        @{Section=4;Title='Security, Network & System Integrity';Item='Nmap Diagnostic Tool';Sub='';State='Not verified';Status='Fail'},
        @{Section=4;Title='Security, Network & System Integrity';Item='lodctr /R Performance Counter';Sub='';State='<div class="kv-block"><div><span class="kv-label">Audit:</span> Not executed</div></div>';Status='Bypass'},
        @{Section=5;Title='AppSettings Check';Item='MonitoringServiceBaseUrl';Sub='';State='https://example.test/api?x=1&amp;y=2';Status='Pass'}
    )
    foreach($fixture in $fixtures){$auditRows.Add([pscustomobject]@{SectionNumber=$fixture.Section;SectionTitle=$fixture.Title;ItemTitle=$fixture.Item;ItemSub=$fixture.Sub;Shortcut=(New-ReportCommand @('notepad.exe "C:\Sample & Support\appsettings.json"'));FoundStateHtml=$fixture.State;Status=$fixture.Status;ActionTaken='Fixture only.'})}
    $firewall=$auditRows | Where-Object ItemTitle -eq 'Inbound TCP 5009 Rule'
    $firewall | Add-Member NoteProperty FirewallPort 5009
    $firewall | Add-Member NoteProperty FirewallReadVerified $true
    $firewall | Add-Member NoteProperty FirewallObservations @([pscustomobject]@{Direction='Inbound';Protocol='TCP';Ports=@('5009');Enabled='Yes';Action='Allow'})
    $before=$auditRows.ToArray() | ConvertTo-Json -Depth 8 -Compress
    $outputFolder=$previewRoot;$deviceType='KIOSK';$reportKioskId='Kiosk-1';$KioskId=$null;$kioskUser='SELISE-KIOSK'
    $reportHostname='SAMPLE-HOST';$clientLocation='Sample & Branch';$runId='FINAL-FIXTURE'
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $reportPath=Join-Path $previewRoot ($client+'-Final.html')
    # A Final report must be generated even when an Audit report would be declined.
    $script:GenerateFixtureReport=$false
    . $render
    Assert-Final ($generateReport -and (Test-Path -LiteralPath $reportPath)) 'Final did not save a report automatically.'
    Assert-Final (-not (Test-CanApply)) 'Rendering enabled Apply.'
    Assert-Final (($auditRows.ToArray() | ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'Rendering changed recorded observations.'
    $html=[IO.File]::ReadAllText($reportPath)
    Assert-Final ($html.Contains('<h1>THOROUGH CHECK REPORT</h1>')) 'Final title is incorrect.'
    Assert-Final ($html -match '<th>Restaurant ID</th><td>Not detected</td>' -and $html -notmatch '<th>Required Configuration</th>|<th>Findings</th>') 'Final metadata or columns are incorrect.'
    Assert-Final ($html.Contains('final-report setting-report') -and $html.Contains('background:#fffbf0')) 'Final is missing the approved column theme.'
    Assert-Final (-not $html.Contains('class="command-copy"') -and $html -notmatch '<span class="badge') 'Final contains command boxes or Pass/Fail badges.'
    $firewall=Get-SettingRenderedComponent $html 'Firewall Inbound Port'
    Assert-Final (@($firewall.Fields|Where-Object {$_.Setting -eq 'Ports' -and $_.Value -eq '5009'}).Count -eq 1) 'Final lost its actual firewall target.'
    foreach($table in [regex]::Matches($html,'(?is)<table class="checks"[^>]*>.*?</table>')){
        Assert-Final ($table.Value.Contains('<th scope="col">Component</th><th scope="col">Setting</th><th scope="col">Status</th>') -and [regex]::Matches($table.Value,'<col\b').Count -eq 3) 'Final columns are incorrect, including AppSettings.'
    }
    $counter=Get-SettingRenderedComponent $html 'Performance Counter'
    Assert-Final (@($counter.Fields|Where-Object {$_.Setting -eq 'Rebuild State' -and $_.Value -eq 'Not executed (read-only verification)'}).Count -eq 1) 'Final counter state was inferred from an earlier Apply.'
    Assert-Final ((Get-SettingRenderedComponent $html 'KIOSK Account').Text -match 'Account Missing. Please create manually.') 'Final hid a missing account.'
    $legacyView=Get-SettingRenderedComponent $html 'Legacy Payment Services'
    Assert-Final ($legacyView.Text -match 'Stopped' -and $legacyView.Html -notmatch 'class="badge') 'Final replaced observed legacy values with a verification badge.'
    $finalPath=Get-KioskReportPath -Folder $previewRoot -Client '..\Branch' -Computer 'HOST' -IsApply $false -IsFinal $true -RunId $runId
    Assert-Final ((Split-Path $finalPath -Parent) -eq $previewRoot -and (Split-Path $finalPath -Leaf) -like 'Thorough Check Reports -*') 'Final filename escaped its directory or used the Audit prefix.'
    $applyPath=Get-KioskReportPath -Folder $previewRoot -Client '..\Branch' -Computer HOST -IsApply $true -RunId $runId
    Assert-Final ($applyPath -ceq $finalPath) 'Modes no longer use the same combined report path.'
    Write-Output ('PASS: '+$client+' Final is read-only, saves per-setting current values, preserves failed/skipped/legacy outcomes, and omits command boxes.')
    $FinalReport=$false;$script:ApplyChanges=$false;$reportPath=Join-Path $previewRoot ($client+'-Declined-'+[guid]::NewGuid().ToString('N')+'.html')
    . $render
    Assert-Final (-not $generateReport -and -not (Test-Path -LiteralPath $reportPath)) 'Audit report decline changed.'
}
Write-Output 'PASS: Standalone Final is hidden from terminal modes; legacy read-only flags, invalid mixed modes and Audit decline verified without device operations.'
