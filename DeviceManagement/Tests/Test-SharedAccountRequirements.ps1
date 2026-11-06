
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Render report fixtures only. Never contact account, printer or service APIs.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$previewRoot=Join-Path $projectRoot 'output\shared-requirements'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-SharedRequirement {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}

foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-SharedRequirement ($errors.Count -eq 0) 'Client source parse failed.'
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $finalizer=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    function New-SharedAccountFixture {
        param([string]$Title,[int]$Section,[string[]]$Names,[string]$Case)
        $states=@(for($index=0;$index -lt $Names.Count;$index++){
            $flags=[ordered]@{
                'Account Name'=$Names[$index]
                'Account Privilege'=$(if($Title -eq 'Administrative Accounts' -or $index -eq 0){'Local Administrator'}else{'Standard Local User'})
                'Account Status'=$(if($Case -eq 'disabled'){'Disabled'}else{'Enabled'})
                'Password Never Expires'='Enabled'
                'User Cannot Change Password'=$(if($Case -eq 'multiple' -and $index -gt 0){'Disabled'}else{'Enabled'})
            }
            if($Case -eq 'partial' -and $index -gt 0){$flags.Remove('User Cannot Change Password')}
            if($Case -eq 'unknown-status'){$flags.Remove('Account Status')}
            ConvertTo-ReportDefinitionHtml $flags
        })
        $state=if($Case -eq 'missing'){'Account Missing. Please create manually.'}elseif($Case -eq 'unreadable'){'Not verified. Please check manually.'}else{'<div class="account-stack">'+($states -join '<hr>')+'</div>'}
        [pscustomobject]@{
            SectionNumber=$Section;SectionTitle=$(if($Title -eq 'KIOSK Account'){'Kiosk Application & Policies'}else{'Security, Network & System Integrity'})
            ItemTitle=$Title;ItemSub='Verified configuration';Shortcut=(New-AccountReportCommand -AccountNames $Names)
            FoundStateHtml=$state;Status=$(if($Case -in @('single','disabled')){'Pass'}else{'Fail'});ActionTaken='Fixture observation only'
        }
    }
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        $mode=if($isApply){'Apply'}else{'Audit'}
        foreach($case in @('single','multiple','missing','unreadable','partial','disabled','unknown-status')){
            $kioskNames=@('SELISE');$adminNames=@('Administrator')
            if($case -in @('multiple','partial')){$kioskNames+=@('SELISE-KIOSK');$adminNames+=@('Support & Desk <Two>')}
            if($case -in @('missing','unreadable')){$kioskNames=@();$adminNames=@()}
            $accountRows=@(
                (New-SharedAccountFixture 'KIOSK Account' 2 $kioskNames $case)
                (New-SharedAccountFixture 'Administrative Accounts' 5 $adminNames $case)
            )
            $rawRows=@(foreach($name in @('BIXOLON BK3-3','EPSON TM-m30')){
                [pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle=$name;ItemSub='Type: Receipt / POS Printer';Shortcut=(New-ReportCommand @('control printers',('rundll32 printui.dll,PrintUIEntry /o /n "{0}"' -f $name)));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Printer Name'=$name;'Printer status'='Idle';'Keep printed documents'='Enabled'}));Status='Pass';ActionTaken='Fixture observation only'}
            })+@($accountRows)
            $before=$rawRows | ConvertTo-Json -Depth 5 -Compress
            foreach($row in $accountRows){
                $view=Get-AccountReportView $row
                $expectedNames=@(if($row.ItemTitle -eq 'KIOSK Account'){$kioskNames}else{$adminNames})
                Assert-SharedRequirement ($view.ExpectedHtml -notmatch 'config-item-title|<hr>' -and [regex]::Matches($view.ExpectedHtml,'class="kv-label"').Count -eq 5) 'Account requirements were repeated or numbered.'
                foreach($label in @('Account Name','Account Privilege','Account Status','Password Never Expires','User Cannot Change Password')){
                    Assert-SharedRequirement ([regex]::Matches($view.ExpectedHtml,([regex]::Escape($label)+':</span>')).Count -eq 1) ('Requirement repeated: '+$label)
                }
                Assert-SharedRequirement ($view.ExpectedHtml.Contains('Account Status:</span> Active / Disabled') -and $view.FindingsHtml -notmatch 'Account:</span> Present') 'The account status reference or removed presence field is incorrect.'
                Assert-SharedRequirement ($view.ExpectedHtml.Contains('Account Privilege:</span> Standard or Administrator</div>')) 'Account privilege reference must use the standard display labels.'
                if($row.ItemTitle -eq 'Administrative Accounts'){
                    Assert-SharedRequirement ($view.ExpectedHtml.Contains('Account Name:</span> Admin, Administrator</div>')) 'Administrative account name reference must stay fixed.'
                }
                if($expectedNames.Count){
                    if($row.ItemTitle -eq 'KIOSK Account'){
                        Assert-SharedRequirement ($view.ExpectedHtml.Contains(('Account Name:</span> '+[Net.WebUtility]::HtmlEncode(($expectedNames -join ', '))))) 'Shared kiosk reference lost account names or escaping.'
                    }
                    for($index=0;$index -lt $expectedNames.Count;$index++){
                        Assert-SharedRequirement ($view.FindingsHtml.Contains(('Account Name:</span> '+[Net.WebUtility]::HtmlEncode($expectedNames[$index])))) 'Findings lost an actual account name.'
                        if($expectedNames.Count -gt 1){Assert-SharedRequirement ($view.FindingsHtml.Contains(('[Account '+($index+1)+']'))) 'Numbered account Findings missing.'}
                    }
                    if($expectedNames.Count -eq 1){Assert-SharedRequirement ($view.FindingsHtml -notmatch 'config-item-title') 'A single account was unnecessarily numbered.'}
                }
                if($case -eq 'missing'){Assert-SharedRequirement ($view.FindingsHtml -ceq 'Account Missing. Please create manually.') 'Missing account instructions changed.'}
                if($case -eq 'unreadable'){Assert-SharedRequirement ($view.FindingsHtml -ceq 'Not verified. Please check manually.') 'Unreadable account state changed.'}
                if($case -eq 'partial'){Assert-SharedRequirement ($view.FindingsHtml.Contains('User Cannot Change Password:</span> Not verified')) 'An unreadable flag was reported as enabled.'}
                if($case -eq 'multiple'){Assert-SharedRequirement ($view.FindingsHtml.Contains('User Cannot Change Password:</span> Disabled')) 'A disabled flag was lost.'}
                if($case -eq 'disabled'){Assert-SharedRequirement ($view.FindingsHtml.Contains('Account Status:</span> Disabled')) 'A disabled account was reported as active.'}
                if($case -eq 'unknown-status'){Assert-SharedRequirement ($view.FindingsHtml.Contains('Account Status:</span> Not verified')) 'An unreadable account status was invented.'}
                if(-not $expectedNames.Count -and $row.ItemTitle -eq 'Administrative Accounts'){
                    Assert-SharedRequirement ($view.ExpectedHtml.Contains('Account Name:</span> Admin, Administrator</div>') -and $view.ExpectedHtml -notmatch 'or local administrator') 'The administrative account name reference is incorrect.'
                }
            }
            $auditRows=[Collections.Generic.List[psobject]]::new()
            foreach($row in $rawRows){$auditRows.Add($row)}
            $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-'+$case+'.html')
            $runId='SHARED-REQUIREMENTS-PREVIEW';$clientLocation='Sample branch';$deviceType='KIOSK'
            $reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
            . $render
            Assert-SharedRequirement (($rawRows | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Report formatting changed original observations or statuses.'
            $html=[KioskTestSource]::ReadAllText($reportPath)
            $rows=@([regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value -match '<div class="device-title">(?:Printer|KIOSK Account|Administrative Accounts)</div>'})
            Assert-SharedRequirement ($rows.Count -eq 3) 'Report no longer has one row per component.'
            foreach($rowMatch in $rows){
                $cells=@([regex]::Matches($rowMatch.Value,'(?is)<td\b[^>]*>(.*?)</td>'))
                Assert-SharedRequirement ($cells.Count -eq $(if($isApply){5}else{4})) 'Report columns changed.'
                $required=$cells[2].Groups[1].Value
                $printer=$cells[0].Groups[1].Value.Contains('>Printer</div>')
                Assert-SharedRequirement ($required -notmatch 'config-item-title|<hr>' -and [regex]::Matches($required,'class="kv-label"').Count -eq $(if($printer){3}else{5})) 'Rendered requirements were repeated or numbered.'
                if($isApply){
                    $status=if($printer -or $case -in @('single','disabled')){'Pass'}else{'Fail'}
                    Assert-SharedRequirement ($cells[4].Groups[1].Value.Contains(('>'+$status+'</span>'))) 'Report formatting changed an observed result.'
                }
            }
        }
        Write-Output ('PASS: '+$client+'/'+$mode+' shared requirements, named/numbered kiosk and administrative Findings, single/multiple/missing/unreadable/partial/disabled/unknown-status accounts and actual report rendering')
    }
}
