. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$preview=Join-Path $root 'output\firewall-provider-apply';[void][IO.Directory]::CreateDirectory($preview)
function Assert-ProviderFirewall {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    Set-KioskTestClient $client
    $tokens=$null;$errors=$null;$source=[KioskTestSource]::ReadAllText((Join-Path $root 'KioskThoroughCheck.ps1'))
    $ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-ProviderFirewall (-not $errors.Count) 'Expanded engine does not parse.'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $start=$source.IndexOf("Start-AuditStep 10 'Required inbound firewall rules'");$end=$source.IndexOf('# 4.2 Local Administrative Accounts',$start)
    $dispatch=[scriptblock]::Create($source.Substring($start,$end-$start))
    function Start-AuditStep {param($Number,$Name)}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    function New-ProviderFirewallRecord {
        param([string]$Name,[string[]]$Ports,[string]$Protocol='TCP',[string]$Enabled='True',[string]$Action='Allow')
        [pscustomobject]@{Protocol=$Protocol;LocalPort=$Ports;Rule=[pscustomobject]@{Name=$Name;Direction='Inbound';Action=$Action;Enabled=$Enabled;Profile='Private'}}
    }
    function Get-NetFirewallPortFilter {[CmdletBinding()]param($PolicyStore,$AssociatedNetFirewallRule)
        if($AssociatedNetFirewallRule){$script:store | Where-Object {$_.Rule.Name -eq $AssociatedNetFirewallRule.Name};return}
        if($script:denyRead){throw 'Fixture firewall read denied'}
        if($script:failNextRead){$script:failNextRead=$false;throw 'Fixture post-write read failed'}
        $script:store.ToArray()
    }
    function Get-NetFirewallRule {[CmdletBinding()]param($Name,$PolicyStore,$AssociatedNetFirewallPortFilter)
        if($PSBoundParameters.ContainsKey('Name')){foreach($record in $script:store){if($record.Rule.Name -eq $Name){$record.Rule}}}
        else{$AssociatedNetFirewallPortFilter.Rule}
    }
    function New-NetFirewallRule {[CmdletBinding()]param($Name,$DisplayName,$PolicyStore,$Direction,$LocalPort,$Protocol,$Action,$Enabled,$Profile)
        Assert-ProviderFirewall ($script:allowed -contains [int]$LocalPort -and $Name -eq ('SELISE-Kiosk-TCP-'+$LocalPort+'-Inbound') -and $PolicyStore -eq 'PersistentStore' -and $Direction -eq 'Inbound' -and $Protocol -eq 'TCP' -and $Action -eq 'Allow' -and [string]$Enabled -eq 'True' -and $Profile -eq 'Any') 'Creation changed unapproved ports, protocol, direction, store or profiles.'
        $script:writes.Add('Create:'+ $LocalPort)
        if([int]$LocalPort -eq $script:noEffectPort){return}
        $record=New-ProviderFirewallRecord $Name @([string]$LocalPort);$record.Rule.Profile='Any';$script:store.Add($record)
    }
    function Set-NetFirewallPortFilter {[CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,$Protocol,$LocalPort)
        process{
            Assert-ProviderFirewall ($InputObject.Rule.Name -match '^SELISE-Kiosk-TCP-(\d+)-Inbound$' -and $script:allowed -contains [int]$Matches[1]) 'Port repair changed an unrelated rule.'
            $target=[int]$Matches[1];$script:writes.Add('Port:'+ $target)
            $InputObject.Protocol=[string]$Protocol;$InputObject.LocalPort=@($LocalPort | ForEach-Object {[string]$_})
            if($script:failure -eq 'port' -and -not $script:failureFired){$script:failureFired=$true;throw 'Fixture partial port write failed'}
        }
    }
    function Set-NetFirewallRule {[CmdletBinding()]param($Name,$PolicyStore,$Direction,$Action,$Enabled,$Profile)
        Assert-ProviderFirewall ($Name -match '^SELISE-Kiosk-TCP-(\d+)-Inbound$' -and $script:allowed -contains [int]$Matches[1]) 'Rule repair changed an unrelated rule.'
        $target=[int]$Matches[1];$record=@($script:store | Where-Object {$_.Rule.Name -eq $Name})[0]
        if($PSBoundParameters.ContainsKey('Action') -and $Action -eq 'Allow' -and [string]$Enabled -eq 'True'){
            Assert-ProviderFirewall ($record.Protocol -eq 'TCP' -and ($record.LocalPort -join ',') -eq [string]$target) 'A managed Allow rule was enabled before narrowing its port.'
        }
        $script:writes.Add('Rule:'+ $target)
        foreach($field in @('Direction','Action','Enabled','Profile')){if($PSBoundParameters.ContainsKey($field)){$record.Rule.$field=[string]$PSBoundParameters[$field]}}
        if($script:failure -eq 'rule' -and -not $script:failureFired){$script:failureFired=$true;throw 'Fixture partial rule write failed'}
        if($script:failure -eq 'readback' -and -not $script:failureFired){$script:failureFired=$true;$script:failNextRead=$true}
    }
    function Reset-ProviderFirewallStore {
        $script:store=New-Object 'Collections.Generic.List[object]';$script:writes=New-Object 'Collections.Generic.List[string]'
        $script:denyRead=$false;$script:failNextRead=$false;$script:failure='';$script:failureFired=$false;$script:noEffectPort=-1
        $script:store.Add((New-ProviderFirewallRecord 'Unrelated application Any rule' @('Any')))
        $script:store.Add((New-ProviderFirewallRecord 'Unrelated port' @('9999')))
        $script:store.Add((New-ProviderFirewallRecord 'Customer block rule' @('5009') -Action Block))
    }
    $sec4Num=4;$sec4Title='Security, Network & System Integrity'
    foreach($detectedPaymentProvider in @('NETS','NEXIDE','SIX','PRINT','Not detected')){
        $script:allowed=if($detectedPaymentProvider -eq 'NETS'){@(5009,4100,4101,4102,4103)}elseif($detectedPaymentProvider -eq 'NEXIDE'){@(5009,20002,20007)}else{@(5009)}
        foreach($case in @('all-missing','partial','existing','repair-managed')){
            Reset-ProviderFirewallStore
            if($case -eq 'partial'){$script:store.Add((New-ProviderFirewallRecord 'Existing application port' @('5009')))}
            if($case -eq 'existing'){foreach($port in $script:allowed){$script:store.Add((New-ProviderFirewallRecord ('Existing '+$port) @([string]$port)))}}
            if($case -eq 'repair-managed'){foreach($port in $script:allowed){$script:store.Add((New-ProviderFirewallRecord ('SELISE-Kiosk-TCP-'+$port+'-Inbound') @('Any') -Protocol UDP -Enabled False -Action Block))}}
            $unrelatedBefore=@($script:store | Where-Object {$_.Rule.Name -notlike 'SELISE-*'}) | ConvertTo-Json -Depth 6 -Compress
            $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$false
            . $dispatch
            $beforeRows=$auditRows.ToArray()
            Assert-ProviderFirewall (-not $script:writes.Count -and ($auditRows.FirewallPort -join ',') -eq ($script:allowed -join ',')) 'Audit wrote rules or selected incorrect provider ports.'
            if($case -eq 'all-missing'){
                $group=@(Get-ThoroughReportDisplayRows $beforeRows)[0];$values=Get-ThoroughReportHighlightFields $group.FoundStateHtml
                Assert-ProviderFirewall ($group.Status -eq 'Fail' -and $values['Missing Allow Rules (Ports)'] -eq ($script:allowed -join ', ') -and $values.Ports -eq '5009') 'Any-port rules hid missing required rules or block evidence was lost.'
            }
            $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$true
            . $dispatch
            Assert-ProviderFirewall (@($auditRows | Where-Object Status -NE Pass).Count -eq 0 -and $auditRows.Count -eq $script:allowed.Count) ('Not every required port was repaired: '+$detectedPaymentProvider+'/'+$case)
            $expectedWrites=if($case -eq 'repair-managed'){$script:allowed.Count*2}elseif($case -eq 'existing'){0}elseif($case -eq 'partial'){$script:allowed.Count-1}else{$script:allowed.Count}
            Assert-ProviderFirewall ($script:writes.Count -eq $expectedWrites) 'Apply skipped a required port or changed an existing rule.'
            $unrelatedAfter=@($script:store | Where-Object {$_.Rule.Name -notlike 'SELISE-*'}) | ConvertTo-Json -Depth 6 -Compress
            Assert-ProviderFirewall ($unrelatedAfter -ceq $unrelatedBefore) 'Apply changed an unrelated, broad or customer Block rule.'
            $group=@(Get-ThoroughReportDisplayRows $auditRows.ToArray())[0];$values=Get-ThoroughReportHighlightFields $group.FoundStateHtml
            Assert-ProviderFirewall ($group.Status -eq 'Pass' -and $values.Ports -eq ($script:allowed -join ', ') -and -not $values.ContainsKey('Missing Allow Rules (Ports)') -and $values.Ports -notmatch 'Any') 'Final verified port list is inaccurate.'
            if($case -in @('all-missing','partial') -and $detectedPaymentProvider -in @('NETS','NEXIDE')){
                $expectedMissingPorts=if($case -eq 'partial'){
                    if($detectedPaymentProvider -eq 'NETS'){'4100, 4101, 4102, 4103'}else{'20002, 20007'}
                }else{ $script:allowed -join ', ' }
                $auditFix=New-ThoroughReportSnapshot -Rows $beforeRows -DisplayMode Fix -AfterApply $false -Hostname FIXTURE-PC
                $auditFixHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auditFix.HtmlBase64));$auditFixView=Get-SettingRenderedComponent $auditFixHtml Firewall
                $auditFixMissing=@($auditFixView.Fields | Where-Object Setting -EQ 'Missing Allow Rules (Ports)')
                Assert-ProviderFirewall ($auditFixMissing.Count -eq 1 -and $auditFixMissing[0].Findings -eq $expectedMissingPorts -and $auditFixMissing[0].Value -eq 'Not applied' -and $auditFixMissing[0].Html -match 'finding-unverified') 'Fix before Apply did not show Missing Allow Rules with Not applied amber tag.'

                $snapshot=New-ThoroughReportSnapshot -Rows $auditRows.ToArray() -BeforeRows $beforeRows -DisplayMode Fix -AfterApply $true -Hostname FIXTURE-PC
                $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64));$view=Get-SettingRenderedComponent $html Firewall
                $ports=@($view.Fields | Where-Object Setting -EQ Ports);$missing=@($view.Fields | Where-Object Setting -EQ 'Missing Allow Rules (Ports)')
                Assert-ProviderFirewall ($ports.Count -eq 1 -and $ports[0].Value -eq ($script:allowed -join ', ') -and $missing.Count -eq 1 -and $missing[0].Value -eq 'Created' -and $missing[0].Html -match 'finding-match') 'Fix Applied retained missing ports or lost verified port readback.'
                [IO.File]::WriteAllText((Join-Path $preview ($client+'-'+$detectedPaymentProvider+'-'+$case+'-Applied.html')),$html,[Text.UTF8Encoding]::new($false))
            }
            $writesBefore=$script:writes.Count;$auditRows=New-Object 'Collections.Generic.List[psobject]'
            . $dispatch
            Assert-ProviderFirewall ($script:writes.Count -eq $writesBefore -and @($auditRows | Where-Object Status -NE Pass).Count -eq 0) 'Repeat Apply changed already verified explicit port rules.'
        }
    }
    # Failed writes and failed readbacks must restore the managed rule exactly.
    $script:allowed=@(20007)
    foreach($faultCase in @('port','rule','readback')){
        Reset-ProviderFirewallStore
        $script:store.Add((New-ProviderFirewallRecord 'SELISE-Kiosk-TCP-20007-Inbound' @('Any') -Protocol UDP -Enabled False -Action Block))
        $before=$script:store | ConvertTo-Json -Depth 6 -Compress;$script:failure=$faultCase
        $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$true
        Invoke-KioskFirewallPortCheck -Port 20007 -RulePurpose 'NEXIDE fixture'
        Assert-ProviderFirewall ($auditRows[0].Status -eq 'Fail' -and $auditRows[0].ActionTaken -match 'Original managed firewall rule restored' -and ($script:store | ConvertTo-Json -Depth 6 -Compress) -ceq $before) ('Managed rollback failed: '+$faultCase+'; '+$auditRows[0].ActionTaken)
    }
    Reset-ProviderFirewallStore;$script:noEffectPort=20007;$script:allowed=@(5009,20002,20007);$detectedPaymentProvider='NEXIDE'
    $auditRows=New-Object 'Collections.Generic.List[psobject]';. $dispatch
    $group=@(Get-ThoroughReportDisplayRows $auditRows.ToArray())[0];$values=Get-ThoroughReportHighlightFields $group.FoundStateHtml
    Assert-ProviderFirewall ($group.Status -eq 'Fail' -and $values['Missing Allow Rules (Ports)'] -eq '20007' -and $values.Ports -eq '5009, 20002') 'An ineffective NEXIDE port creation was reported as successful.'
    Reset-ProviderFirewallStore;$script:denyRead=$true;$auditRows=New-Object 'Collections.Generic.List[psobject]';. $dispatch
    Assert-ProviderFirewall (-not $script:writes.Count -and @($auditRows | Where-Object Status -EQ Pass).Count -eq 0) 'Denied preflight reads triggered writes or became Pass.'
    Write-Output ('PASS: '+$client+' real provider dispatch; all-port Apply and idempotence; Any-rule exclusion; preserved existing/customer rules; narrowing before Allow, managed rollback, failed readback and truthful Fix port results.')
}
