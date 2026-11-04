. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
# Fixtures only: do not contact Windows Firewall or change live rules.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output\firewall-groups'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-FirewallReport {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $source=Join-Path $sourceRoot $sourceName
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    Assert-FirewallReport ($errors.Count -eq 0) 'Source parse failed.'
    $definitions=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    Use-SettingLayoutRuleAssertions -SourceName $sourceName
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount,$IsFinal)}
    function Get-NetFirewallPortFilter {[CmdletBinding()]param($PolicyStore)$script:filterReads++;if($script:denyRead){throw 'Fixture firewall read denied'};$script:filters}
    function Get-NetFirewallRule {[CmdletBinding()]param($AssociatedNetFirewallPortFilter,$PolicyStore,$Name)if($PSBoundParameters.ContainsKey('Name')){throw 'Unexpected managed-rule lookup'};$AssociatedNetFirewallPortFilter.FixtureRules}
    function New-NetFirewallRule {throw 'Unexpected firewall creation'}
    function Set-NetFirewallRule {throw 'Unexpected firewall change'}
    function Set-NetFirewallPortFilter {throw 'Unexpected port-filter change'}
    function New-FilterFixture {
        param([string[]]$Ports,[string]$Direction='Inbound',[string]$Protocol='TCP',[string]$Enabled='True',[string]$Action='Allow')
        [pscustomobject]@{LocalPort=$Ports;Protocol=$Protocol;FixtureRules=@([pscustomobject]@{Direction=$Direction;Enabled=$Enabled;Action=$Action;Profile='Private';Name='Fixture <Rule> & TCP'})}
    }
    function Collect-FirewallFixture {
        param([int[]]$Ports)
        $auditRows.Clear()
        foreach($port in $Ports){Invoke-KioskFirewallPortCheck -Port $port -RulePurpose 'Fixture only'}
    }
    $sec4Num=4;$sec4Title='Security, Network & System Integrity'
    $script:filterReads=0;$script:denyRead=$false
    $finalizer=$ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($mode in @('Audit','Apply','Final')){
        $script:ApplyChanges=$mode -eq 'Apply';$FinalReport=$mode -eq 'Final'
        foreach($provider in @('NETS','NEXIDE','SIX','PRINT')){
            $ports=if($provider -in @('NETS','NEXIDE')){@(5009,4100,4101,4102,4103)}else{@(5009)}
            $auditRows=New-Object 'Collections.Generic.List[psobject]'
            $script:filters=@($ports | ForEach-Object {New-FilterFixture @([string]$_)})
            $filterSnapshot=$script:filters | ConvertTo-Json -Depth 8 -Compress
            Collect-FirewallFixture $ports
            Assert-FirewallReport ($auditRows.Count -eq $ports.Count -and @($auditRows | Where-Object Status -ne Pass).Count -eq 0) 'Per-port verification changed.'
            $before=$auditRows.ToArray() | ConvertTo-Json -Depth 10 -Compress
            $rows=@(Get-ThoroughReportDisplayRows $auditRows.ToArray())
            Assert-FirewallReport ($rows.Count -eq 1 -and $rows[0].ItemTitle -eq 'Firewall Inbound Port' -and $rows[0].Status -eq 'Pass') 'Firewall rules were not consolidated into one verified component.'
            $expectedFields=Get-ThoroughReportHighlightFields $rows[0].ExpectedHtml
            $actualFields=Get-ThoroughReportHighlightFields $rows[0].FoundStateHtml
            foreach($key in @('Direction','Protocol','Ports','Enabled','Action')){Assert-FirewallReport ($actualFields.ContainsKey($key) -and $actualFields[$key] -ceq $expectedFields[$key]) ('Actual rule field was lost: '+$key)}
            Assert-FirewallReport ($actualFields.Ports -ceq ($ports -join ', ')) 'Provider-specific port list is wrong.'
            Assert-FirewallReport (($auditRows.ToArray() | ConvertTo-Json -Depth 10 -Compress) -ceq $before) 'Grouping modified original observations.'
            Assert-FirewallReport (($script:filters | ConvertTo-Json -Depth 8 -Compress) -ceq $filterSnapshot) 'Rule data was changed.'
            $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-'+$provider+'.html')
            $runId='FIREWALL-FIXTURE';$clientLocation='Firewall preview';$deviceType='KIOSK';$reportKioskId='Kiosk-1';$KioskId=$null;$kioskUser='SELISE-KIOSK';$reportHostname='SAMPLE-KIOSK01'
            . $render
            $html=[IO.File]::ReadAllText($reportPath)
            if($mode -eq 'Audit'){
                $auditView=Get-AuditRenderedComponent $html 'Firewall'
                Assert-FirewallReport ($auditView.Count -eq 1 -and $auditView.Fields.Count -eq 5) 'Audit lost or duplicated actual firewall fields.'
                foreach($spec in @(@('Ports',($ports -join ', ')),@('Direction','Inbound'),@('Protocol','TCP'),@('Enabled','Yes'),@('Action','Allow'))){
                    Assert-FirewallReport (@($auditView.Fields|Where-Object {$_.Setting -eq $spec[0] -and $_.Found -eq $spec[1]}).Count -eq 1) 'Actual Audit firewall rule value changed.'
                }
                Assert-FirewallReport ($auditView.Commands.Count -eq 1 -and $auditView.Commands[0] -ceq 'wf.msc') 'Grouped Audit firewall command changed.'
                Assert-FirewallReport ($auditView.Html -notmatch 'finding-mismatch|finding-unverified') 'Healthy firewall values became warning values.'
                continue
            }
            $displayRows=@([regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value.Contains('class="device-title">Firewall</div>')})
            if($mode -eq 'Apply'){
                Assert-FirewallReport ($displayRows.Count -eq 0 -and $html.Contains('No fixes required.')) 'Healthy unchanged firewall component remains in Fix.'
                continue
            }
            Assert-FirewallReport ($displayRows.Count -eq 1 -and $html -notmatch 'Rule:</span> Available|class="component-context"') 'Repeated components or old Available-only findings remain.'
            $cells=@([regex]::Matches($displayRows[0].Value,'(?is)<td\b[^>]*>(.*?)</td>'))
            $foundIndex=if($mode -eq 'Final'){1}elseif($mode -eq 'Apply'){2}else{3}
            $found=Get-ThoroughReportHighlightFields $cells[$foundIndex].Groups[1].Value
            if($mode -eq 'Apply'){Assert-FirewallReport ($cells[$foundIndex].Value.Contains('No further fix needed.')) 'Healthy firewall fields were repeated in Fix.'}
            else{Assert-FirewallReport ($found.Ports -eq ($ports -join ', ') -and $found.Direction -eq 'Inbound' -and $found.Action -eq 'Allow') 'Rendered Findings do not contain the actual rules.'}
            Assert-FirewallReport ([regex]::Matches($displayRows[0].Value,'data-command="wf.msc"').Count -eq $(if($mode -eq 'Final'){0}else{1})) 'Grouped firewall command did not follow the selected report layout.'
            if($mode -eq 'Final'){Assert-FirewallReport ($html -notmatch 'class="finding-value finding-|#e8f5e9|#fff8e1|#fdecec') 'Final received comparison colors.'}
            elseif($mode -eq 'Audit'){Assert-FirewallReport ([regex]::Matches($cells[$foundIndex].Value,'finding-match').Count -eq 5) 'Not every actual firewall field was compared correctly.'}
        }
    }
    $script:ApplyChanges=$false;$FinalReport=$false
    foreach($case in @('partial','missing','disabled','blocked','outbound','denied','range','any','legacy-available','contradictory-pass')){
        $ports=@(5009,4100,4101,4102,4103)
        $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:denyRead=$false
        $script:filters=@($ports | ForEach-Object {New-FilterFixture @([string]$_)})
        switch($case){
            'partial' {$script:filters=@($script:filters | Where-Object {$_.LocalPort -ne '4102'})}
            'missing' {$script:filters=@()}
            'disabled' {$script:filters[2].FixtureRules[0].Enabled='False'}
            'blocked' {$script:filters[2].FixtureRules[0].Action='Block'}
            'outbound' {$script:filters[2].FixtureRules[0].Direction='Outbound'}
            'denied' {$script:denyRead=$true}
            'range' {$script:filters=@((New-FilterFixture @('5009','4100-4103') -Protocol '6'))}
            'any' {$script:filters=@((New-FilterFixture @('Any')))}
        }
        Collect-FirewallFixture $ports
        if($case -eq 'legacy-available'){
            foreach($row in $auditRows){$row.PSObject.Properties.Remove('FirewallObservations');$row.PSObject.Properties.Remove('FirewallReadVerified')}
        }elseif($case -eq 'contradictory-pass'){$auditRows[2].FirewallObservations[0].Enabled='No'}
        $group=@(Get-ThoroughReportDisplayRows $auditRows.ToArray())[0]
        Assert-FirewallReport ($group.Status -eq $(if($case -in @('range','any')){'Pass'}else{'Fail'})) ('Wrong grouped status: '+$case)
        $fields=Get-ThoroughReportHighlightFields $group.FoundStateHtml
        if($case -eq 'partial'){Assert-FirewallReport ($fields.Ports -notmatch '4102' -and $fields['Missing Allow Rules (Ports)'] -eq '4102') ('Missing port was shown as available: '+($fields|ConvertTo-Json -Compress))}
        if($case -eq 'missing'){Assert-FirewallReport ($fields.Ports -eq 'None') 'Missing rules were shown as verified values.'}
        if($case -eq 'disabled'){Assert-FirewallReport ($fields.Enabled -match 'No') 'Actual disabled state was replaced by Yes.'}
        if($case -eq 'blocked'){Assert-FirewallReport ($fields.Action -match 'Block') 'Actual Block action was replaced by Allow.'}
        if($case -eq 'outbound'){Assert-FirewallReport ($fields.Direction -match 'Outbound') 'Actual direction was replaced by Inbound.'}
        if($case -in @('denied','legacy-available')){Assert-FirewallReport ($fields.Direction -like 'Not verified*' -and $fields.ContainsKey('Unverified Ports')) 'Unknown values were invented from expected configuration.'}
        if($case -in @('range','any')){
            Assert-FirewallReport ($fields.Ports -eq $(if($case -eq 'range'){'5009, 4100-4103'}else{'All ports (Any)'})) 'Actual range/all-port values were replaced with requested ports.'
            $colored=Format-ThoroughReportFindingHighlights -Row $group -FindingsHtml $group.FoundStateHtml -RequirementHtml $group.ExpectedHtml
            Assert-FirewallReport ($colored -match 'finding-match[^>]*><span class="kv-label">Ports:') 'Covering ranges/Any were incorrectly highlighted as mismatched.'
        }
    }
    # Verify the actual Apply handler with a mutable fixture store only.
    $script:denyRead=$false;$script:ApplyChanges=$true
    function Get-NetFirewallRule {
        [CmdletBinding()]param($AssociatedNetFirewallPortFilter,$PolicyStore,$Name)
        if($PSBoundParameters.ContainsKey('Name')){if($script:managedExists){$script:filters[0].FixtureRules[0]}}
        else{$AssociatedNetFirewallPortFilter.FixtureRules}
    }
    function Get-NetFirewallPortFilter {[CmdletBinding()]param($PolicyStore,$AssociatedNetFirewallRule)$script:filters}
    function New-NetFirewallRule {
        [CmdletBinding()]param($Name,$DisplayName,$PolicyStore,$Direction,$LocalPort,$Protocol,$Action,$Enabled,$Profile)
        Assert-FirewallReport ($LocalPort -eq 5009 -and $Protocol -eq 'TCP' -and $Direction -eq 'Inbound' -and $Action -eq 'Allow' -and $Profile -eq 'Any') 'Managed creation scope changed.'
        $script:writes.Add('Create')
        if(-not $script:noEffect){$script:filters=@(New-FilterFixture @('5009'))}
    }
    function Set-NetFirewallRule {
        [CmdletBinding()]param($Name,$PolicyStore,$Direction,$Action,$Enabled,$Profile)
        Assert-FirewallReport ($Name -eq 'SELISE-Kiosk-TCP-5009-Inbound' -and $Direction -eq 'Inbound' -and $Action -eq 'Allow' -and $Profile -eq 'Any') 'Managed update scope changed.'
        $script:writes.Add('Update')
        if(-not $script:noEffect){$rule=$script:filters[0].FixtureRules[0];$rule.Direction='Inbound';$rule.Action='Allow';$rule.Enabled='True'}
    }
    function Set-NetFirewallPortFilter {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,$Protocol,$LocalPort)
        process{Assert-FirewallReport ($Protocol -eq 'TCP' -and $LocalPort -eq 5009) 'Managed port update scope changed.';$script:writes.Add('Filter');if(-not $script:noEffect){$script:filters[0].Protocol=$Protocol;$script:filters[0].LocalPort=@([string]$LocalPort)}}
    }
    foreach($case in @('existing','create','update','create-no-effect','update-no-effect')){
        $script:writes=New-Object 'Collections.Generic.List[string]';$script:managedExists=$case -like 'update*';$script:noEffect=$case -like '*-no-effect'
        $script:filters=if($case -eq 'existing'){@(New-FilterFixture @('5009'))}elseif($script:managedExists){@(New-FilterFixture @('5009') -Enabled 'False' -Action 'Block')}else{@()}
        $auditRows=New-Object 'Collections.Generic.List[psobject]'
        Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'Fixture only'
        Assert-FirewallReport (($auditRows[0].Status -eq 'Pass') -eq (-not $script:noEffect)) ('Apply readback outcome changed: '+$case)
        $expectedWrites=if($case -eq 'existing'){''}elseif($case -like 'create*'){'Create'}else{'Update|Filter'}
        Assert-FirewallReport (($script:writes -join '|') -ceq $expectedWrites) ('Apply changed an existing rule or lost a managed repair: '+$case)
        $group=@(Get-ThoroughReportDisplayRows $auditRows.ToArray())[0]
        Assert-FirewallReport (($group.Status -eq 'Pass') -eq (-not $script:noEffect)) ('Grouped repair result ignored readback: '+$case)
    }
    Write-Output ('PASS: '+$client+' one firewall component across Audit/Apply/Final; actual fields, conditional ports, ranges/Any, missing/disabled/blocked/outbound/unknown rules; existing rules preserved; create/update and failed readback remain truthful.')
}
