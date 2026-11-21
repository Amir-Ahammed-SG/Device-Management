
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Definitions, isolated prompt blocks and fixture reports only. No device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$fixtureRoot=Join-Path $projectRoot ('output\audit-client-input\fixtures\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-AuditInput {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Set-Service {throw 'Metadata handling attempted a service mutation.'}
function Get-CimInstance {throw 'Metadata handling queried a device.'}
function Set-LocalUser {throw 'Metadata handling changed an account.'}
function Set-ItemProperty {throw 'Metadata handling wrote a registry value.'}
$branch='Redo - FRANK & O''Brien <East> "Desk"'
foreach($name in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $name
    $path=Join-Path $sourceRoot 'KioskThoroughCheck.ps1';$tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-AuditInput ($errors.Count -eq 0) 'Client source has parser errors.'
    . ([scriptblock]::Create((($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n")))
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if([string]::IsNullOrWhiteSpace($ClientLocation)') -and $n.Extent.Text.Contains('Get-ThoroughAuditClientLocation')},$true))
    Assert-AuditInput ($nodes.Count -eq 1) 'Expected one Audit metadata input block.'
    $inputBlock=[scriptblock]::Create($nodes[0].Extent.Text)
    $reportPath=Join-Path $fixtureRoot ($client+'.html')
    $script:PromptReplies=[Collections.Generic.Queue[string]]::new()
    foreach($value in @('','  ',$branch)){$script:PromptReplies.Enqueue($value)}
    $script:PromptCalls=0
    function Read-Host {param($Prompt) $script:PromptCalls++;if($Prompt -ne 'Branch Name' -or -not $script:PromptReplies.Count){throw 'Unexpected metadata prompt.'};$script:PromptReplies.Dequeue()}
    $ClientLocation=$null;$AuditOnly=$true;$script:ApplyChanges=$false
    $count=@([IO.Directory]::GetFiles($fixtureRoot)).Count
    . $inputBlock
    Assert-AuditInput ($ClientLocation -ceq $branch -and $script:PromptCalls -eq 3) 'Audit did not collect a nonblank branch exactly.'
    Assert-AuditInput (@([IO.Directory]::GetFiles($fixtureRoot)).Count -eq $count) 'Collecting Audit metadata wrote a file.'
    function Read-Host {throw 'Fix or an explicitly provided Audit branch prompted again.'}
    . $inputBlock
    Assert-AuditInput ($ClientLocation -ceq $branch) 'An explicit Audit value was replaced.'
    # The standalone Main Menu reset must retain the branch even if Audit was not saved.
    $reset=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($nextOption -eq ''3'')')},$true))[0]
    $nextOption='3';. ([scriptblock]::Create($reset.Extent.Text))
    $AuditOnly=$false;. $inputBlock
    Assert-AuditInput ($ClientLocation -ceq $branch) 'Returning to the standalone menu discarded the Audit branch.'
    # Saved Audit supplies the branch across fresh runs without extra files.
    $row=[pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='Type: Event Viewer Channel';Shortcut='';FoundStateHtml='Enabled';Status='Pass';ActionTaken='No change needed'}
    $audit=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -ClientLocation $branch -DeviceType KIOSK -Hostname SAMPLE
    [void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME @($audit) Audit)
    $hash=(Get-FileHash -LiteralPath $reportPath).Hash;$files=@([IO.Directory]::GetFiles($fixtureRoot)).Count
    $ClientLocation=$null;$AuditOnly=$false;. $inputBlock
    Assert-AuditInput ($ClientLocation -ceq $branch) 'A fresh Fix did not reuse the saved Audit branch.'
    Assert-AuditInput ((Get-FileHash -LiteralPath $reportPath).Hash -ceq $hash -and @([IO.Directory]::GetFiles($fixtureRoot)).Count -eq $files) 'Saved Audit lookup changed files.'
    foreach($mode in @('Audit','Fix','Final')){
        $snapshot=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode $mode -ClientLocation $ClientLocation -DeviceType KIOSK -Hostname SAMPLE -AfterApply ($mode -ne 'Audit')
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        Assert-AuditInput ($html.Contains('<th>Branch</th><td>'+[Net.WebUtility]::HtmlEncode($branch)+'</td>')) 'Report metadata changed or failed to encode the branch.'
    }
    $other=if($client -eq 'SaaS'){'Subway'}else{'SaaS'}
    Assert-AuditInput ($null -eq (Get-ThoroughAuditClientLocation $reportPath $other $env:COMPUTERNAME)) 'A different client supplied the branch.'
    Assert-AuditInput ($null -eq (Get-ThoroughAuditClientLocation $reportPath $client 'ANOTHER-DEVICE')) 'A different device supplied the branch.'
    # Launcher hostname filenames differ from the initial Windows computer path.
    $alternateFolder=Join-Path $fixtureRoot ($client+'-hostname');[void][IO.Directory]::CreateDirectory($alternateFolder)
    $initialPath=Join-Path $alternateFolder ('Thorough Check Reports - '+$client+' - WINDOWS-NAME.html')
    $alternatePath=Join-Path $alternateFolder ('Thorough Check Reports - '+$client+' - LAUNCHER-HOST.html')
    [void](Save-ThoroughReportBundle $alternatePath $client $env:COMPUTERNAME @($audit) Audit)
    Assert-AuditInput ((Get-ThoroughAuditClientLocation $initialPath $client $env:COMPUTERNAME) -ceq $branch) 'Launcher hostname filename prevented saved Audit reuse.'
    $unrelatedPath=Join-Path $alternateFolder ('Thorough Check Reports - '+$client+' - OTHER-DEVICE.html')
    [void](Save-ThoroughReportBundle $unrelatedPath $client 'ANOTHER-DEVICE' @($audit) Audit)
    Assert-AuditInput ((Get-ThoroughAuditClientLocation $initialPath $client $env:COMPUTERNAME) -ceq $branch) 'A different device interfered with saved Audit lookup.'
    $conflictPath=Join-Path $alternateFolder ('Thorough Check Reports - '+$client+' - OLD-HOST.html')
    $conflict=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -ClientLocation 'Different branch'
    [void](Save-ThoroughReportBundle $conflictPath $client $env:COMPUTERNAME @($conflict) Audit)
    Assert-AuditInput ($null -eq (Get-ThoroughAuditClientLocation $initialPath $client $env:COMPUTERNAME)) 'Conflicting saved Audit branches were guessed.'
    $ClientLocation='Explicit Fix branch';. $inputBlock
    Assert-AuditInput ($ClientLocation -ceq 'Explicit Fix branch') 'An explicit Fix parameter was replaced by saved metadata.'
    foreach($case in @('missing','unsupported','no-audit','placeholder')){
        $reportPath=Join-Path $fixtureRoot ($client+'-'+$case+'.html')
        if($case -eq 'unsupported'){[IO.File]::WriteAllText($reportPath,'<html>Do not overwrite</html>',$utf8)}
        if($case -eq 'no-audit'){$fix=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -ClientLocation 'Unrelated old Fix';[void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME @($fix) Fix)}
        if($case -eq 'placeholder'){$blank=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -ClientLocation 'Not provided';[void](Save-ThoroughReportBundle $reportPath $client $env:COMPUTERNAME @($blank) Audit)}
        $existed=Test-Path -LiteralPath $reportPath;$beforeHash=if($existed){(Get-FileHash -LiteralPath $reportPath).Hash}else{''}
        $ClientLocation=$null;$AuditOnly=$false;. $inputBlock
        Assert-AuditInput ($ClientLocation -ceq 'Not provided') 'Unavailable saved Audit metadata was guessed.'
        if($existed){Assert-AuditInput ((Get-FileHash -LiteralPath $reportPath).Hash -ceq $beforeHash) 'Invalid/unsupported metadata report was changed.'}else{Assert-AuditInput (-not (Test-Path -LiteralPath $reportPath)) 'Missing metadata created a report or cache.'}
    }
    # Fix-first's placeholder must not suppress the next Audit input.
    $script:PromptReplies=[Collections.Generic.Queue[string]]::new();$script:PromptReplies.Enqueue('New Audit branch')
    function Read-Host {param($Prompt) if($Prompt -ne 'Branch Name'){throw 'Unexpected prompt.'};$script:PromptReplies.Dequeue()}
    $AuditOnly=$true;. $inputBlock
    Assert-AuditInput ($ClientLocation -ceq 'New Audit branch') 'A Fix-first placeholder suppressed Audit input.'
    Assert-AuditInput (-not (Test-CanApply)) 'Metadata collection enabled repairs.'
    Write-Output ('PASS: '+$client+' Audit-only input, blank retry, explicit parameter, session/saved-Audit reuse, no Fix prompt, escaped metadata, client/device isolation and no cache/report writes.')
}
# Local file dispatcher constructs named arguments for Audit as well as Apply/Final.
$handler=[KioskTestSource]::ReadAllText((Join-Path $projectRoot 'Checks\KIOSK\ThoroughCheck.ps1'))
$start=$handler.IndexOf('$arguments = @(');$end=$handler.IndexOf('$startedAt =',$start)
$build=[scriptblock]::Create($handler.Substring($start,$end-$start))
$legacyScript='C:\Fixture with spaces\Client.ps1'
foreach($mode in @('Audit','Apply','Final')){
    $Context=[pscustomobject]@{Mode=$mode;ClientLocation=$branch}
    . $build
    $expected=switch($mode){'Audit'{'-AuditOnly'};'Apply'{'-Apply'};'Final'{'-FinalReport'}}
    Assert-AuditInput ($arguments -contains $expected -and $arguments -contains '-ClientLocation' -and $arguments -ccontains $branch) 'Local mode flags or branch forwarding changed.'
    Assert-AuditInput (-not (Test-Path -LiteralPath $completionPath)) 'Constructing arguments created a completion file.'
}
Write-Output 'PASS: Local Audit/Apply/Final named argument construction preserves branch text without execution.'
