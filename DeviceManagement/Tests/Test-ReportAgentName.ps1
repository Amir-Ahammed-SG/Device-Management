# Isolated metadata prompts and synthetic report rendering only. No device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output\report-agent-name\fixtures\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-AgentName {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Set-Service {throw 'Agent metadata changed a service.'}
function Set-LocalUser {throw 'Agent metadata changed an account.'}
function Set-ItemProperty {throw 'Agent metadata changed the registry.'}
$agent='Amir & O''Brien <script>alert("fixture")</script> '+[char]0x0986
$branch='Sample & Branch'
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $name),[ref]$tokens,[ref]$errors)
    Assert-AgentName ($errors.Count -eq 0) 'Client source has parser errors.'
    . ([scriptblock]::Create((($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n")))
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $agentNodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if([string]::IsNullOrWhiteSpace($AgentName)') -and $n.Extent.Text.Contains('Get-ThoroughAuditAgentName')},$true))
    $branchNodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if([string]::IsNullOrWhiteSpace($ClientLocation)') -and $n.Extent.Text.Contains('Get-ThoroughAuditClientLocation')},$true))
    Assert-AgentName ($agentNodes.Count -eq 1 -and $branchNodes.Count -eq 1 -and $agentNodes[0].Extent.StartOffset -lt $branchNodes[0].Extent.StartOffset) 'Agent input must precede Branch input.'
    $inputBlock=[scriptblock]::Create($agentNodes[0].Extent.Text+"`r`n"+$branchNodes[0].Extent.Text)
    $reportPath=Join-Path $fixtureRoot ($client+'.html')
    $AgentName=$null;$ClientLocation=$null;$AuditOnly=$true;$script:ApplyChanges=$false
    $script:Prompts=[Collections.Generic.List[string]]::new()
    $script:Replies=[Collections.Generic.Queue[string]]::new()
    foreach($value in @('','  ',('  '+$agent+'  '),'',$branch)){$script:Replies.Enqueue($value)}
    function Read-Host {param($Prompt) $script:Prompts.Add($Prompt);if(-not $script:Replies.Count){throw 'Unexpected prompt.'};$script:Replies.Dequeue()}
    $files=@([IO.Directory]::GetFiles($fixtureRoot)).Count
    . $inputBlock
    Assert-AgentName ($AgentName -ceq $agent -and $ClientLocation -ceq $branch) 'Audit did not require and preserve the entered identity.'
    Assert-AgentName (($script:Prompts -join '|') -ceq 'Agent Name|Agent Name|Agent Name|Branch Name|Branch Name') 'Audit prompt ordering or blank retry changed.'
    Assert-AgentName (@([IO.Directory]::GetFiles($fixtureRoot)).Count -eq $files) 'Metadata input wrote a file.'
    function Read-Host {throw 'Explicit metadata or Apply/Final prompted for Agent Name.'}
    . $inputBlock
    $AuditOnly=$false;. $inputBlock
    Assert-AgentName ($AgentName -ceq $agent) 'Session identity was discarded.'
    $row=[pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='Type: Event Viewer Channel';Shortcut='';FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Log State'='Disabled'}));Status='Fail';ActionTaken='Not Applied'}
    $audit=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -AgentName $agent -ClientLocation $branch
    $snapshots=@($audit)
    foreach($mode in @('Fix','Final')){$snapshots+=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode $mode -AuditSource $audit -ClientLocation $branch}
    foreach($snapshot in $snapshots){
        $html=$utf8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        $footer=[regex]::Match($html,'(?s)<footer class="report-footer">.*?</footer>').Value
        Assert-AgentName ($snapshot.AgentName -ceq $agent -and $footer.Contains('<strong>Prepared by:</strong> '+[Net.WebUtility]::HtmlEncode($agent))) 'Report did not inherit or escape the agent name.'
        Assert-AgentName (-not $footer.Contains('<script>') -and $footer.Contains('Retain with the device configuration records.')) 'Agent input injected markup or displaced the existing footer.'
    }
    [void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME $snapshots Audit)
    $saved=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($reportPath))
    Assert-AgentName ($saved.Reports.Audit.AgentName -ceq $agent) 'Saved report lost the agent name.'
    $auditBytes=$saved.Reports.Audit.HtmlBase64
    $hash=(Get-FileHash -LiteralPath $reportPath).Hash
    $AgentName=$null;$ClientLocation=$null;. $inputBlock
    Assert-AgentName ($AgentName -ceq $agent -and (Get-FileHash -LiteralPath $reportPath).Hash -ceq $hash) 'Fresh Apply did not read saved Audit identity without writing.'
    $post=@(foreach($mode in @('Fix','Final')){New-ThoroughReportSnapshot -Rows @($row) -DisplayMode $mode -AfterApply $true -AgentName $AgentName -ClientLocation $branch})
    [void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME $post Fix)
    $saved=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($reportPath))
    Assert-AgentName ($saved.Reports.Audit.HtmlBase64 -ceq $auditBytes -and $saved.Reports.Fix.AgentName -ceq $agent -and $saved.Reports.Final.AgentName -ceq $agent) 'Apply changed Audit attribution or lost the agent name.'
    $other=if($client -eq 'SaaS'){'Subway'}else{'SaaS'}
    Assert-AgentName ($null -eq (Get-ThoroughAuditAgentName $reportPath $other $env:COMPUTERNAME)) 'Agent reused across clients.'
    Assert-AgentName ($null -eq (Get-ThoroughAuditAgentName $reportPath $client 'OTHER-DEVICE')) 'Agent reused across devices.'
    $alternate=Join-Path $fixtureRoot ($client+'-alternate');[void][IO.Directory]::CreateDirectory($alternate)
    $initial=Join-Path $alternate ('Thorough Check Reports - '+$client+' - WINDOWS.html')
    $launcher=Join-Path $alternate ('Thorough Check Reports - '+$client+' - LAUNCHER.html')
    [void](Save-ThoroughReportBundle $launcher $client $env:COMPUTERNAME @($audit) Audit)
    Assert-AgentName ((Get-ThoroughAuditAgentName $initial $client $env:COMPUTERNAME) -ceq $agent) 'Launcher filename prevented saved agent reuse.'
    [void](Save-ThoroughReportBundle (Join-Path $alternate ('Thorough Check Reports - '+$client+' - OLD.html')) $client $env:COMPUTERNAME @($audit) Audit)
    Assert-AgentName ($null -eq (Get-ThoroughAuditAgentName $initial $client $env:COMPUTERNAME)) 'Ambiguous saved reports supplied an agent.'
    foreach($case in @('missing','unsupported','no-audit','legacy')){
        $reportPath=Join-Path $fixtureRoot ($client+'-'+$case+'.html')
        if($case -eq 'unsupported'){[IO.File]::WriteAllText($reportPath,'<html>Preserve this file</html>',$utf8)}
        if($case -eq 'no-audit'){[void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME @($post) Fix)}
        if($case -eq 'legacy'){
            $legacy=$audit | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $legacy.PSObject.Properties.Remove('AgentName')
            [void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME @($legacy) Audit)
        }
        $existed=Test-Path -LiteralPath $reportPath;$before=if($existed){(Get-FileHash -LiteralPath $reportPath).Hash}else{''}
        $AgentName=$null;$ClientLocation='Explicit branch';$AuditOnly=$false;. $inputBlock
        Assert-AgentName ($AgentName -ceq 'Not provided') 'Unavailable Audit attribution was guessed.'
        if($existed){Assert-AgentName ((Get-FileHash -LiteralPath $reportPath).Hash -ceq $before) 'Reading metadata changed a legacy/unsupported report.'}
        $fallback=New-ThoroughReportSnapshot -Rows @() -DisplayMode Final -AgentName $AgentName
        Assert-AgentName ($utf8.GetString([Convert]::FromBase64String($fallback.HtmlBase64)).Contains('<strong>Prepared by:</strong> Not provided')) 'Legacy report fallback failed.'
    }
    $script:Replies=[Collections.Generic.Queue[string]]::new();$script:Replies.Enqueue('New Agent')
    function Read-Host {param($Prompt) if($Prompt -ne 'Agent Name'){throw 'Unexpected metadata prompt.'};$script:Replies.Dequeue()}
    $AuditOnly=$true;. $inputBlock
    Assert-AgentName ($AgentName -ceq 'New Agent' -and -not (Test-CanApply)) 'Fix-first suppressed subsequent Audit agent input or enabled repairs.'
    Write-Output ('PASS: '+$client+' agent-before-branch input, blank retry, escaped footer, all views, saved/session identity, Apply preserves Audit, legacy/conflict isolation and no device changes.')
}
# Named local child-process arguments, including a name containing special characters.
$handler=[IO.File]::ReadAllText((Join-Path $projectRoot 'Checks\KIOSK\ThoroughCheck.ps1'))
$start=$handler.IndexOf('$arguments = @(');$end=$handler.IndexOf('$startedAt =',$start)
$build=[scriptblock]::Create($handler.Substring($start,$end-$start))
$legacyScript='C:\Fixture\Client.ps1'
foreach($mode in @('Audit','Apply','Final')){
    $Context=[pscustomobject]@{Mode=$mode;ClientLocation=$branch;AgentName=$agent}
    . $build
    Assert-AgentName ($arguments -contains '-AgentName' -and $arguments -ccontains $agent) 'Local dispatcher did not preserve Agent Name.'
}
Write-Output 'PASS: local Audit/Apply/Final dispatcher forwards agent metadata without executing a client.'
