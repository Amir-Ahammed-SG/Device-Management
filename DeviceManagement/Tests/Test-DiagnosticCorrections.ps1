
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Synthetic observations and service/firewall fixtures only. No live device writes.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent;$sourceRoot=$projectRoot
$output=Join-Path $projectRoot 'output/diagnostic-corrections';[void][IO.Directory]::CreateDirectory($output)
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
function Assert-Diagnostic {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-DiagnosticRow {param([string]$Name,[string]$Html,[string]$Sub='')
    [pscustomobject]@{SectionNumber=4;SectionTitle='Diagnostic corrections';ItemTitle=$Name;ItemSub=$Sub;Shortcut=(New-ReportCommand @('services.msc'));FoundStateHtml=$Html;Status='Fail';ActionTaken='Recorded fixture'}
}
foreach($name in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $name
    $t=$null;$e=$null;$ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot 'KioskThoroughCheck.ps1'),[ref]$t,[ref]$e)
    Assert-Diagnostic ($e.Count -eq 0) 'Source parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    function Get-CimInstance {throw 'Unexpected live device query'}
    function Start-Process {throw 'Unexpected executable launch'}
    function Get-NetFirewallPortFilter {[CmdletBinding()]param($PolicyStore) $script:Filters}
    function Get-NetFirewallRule {[CmdletBinding()]param($AssociatedNetFirewallPortFilter,$PolicyStore) [pscustomobject]@{Enabled='True';Direction='Inbound';Action='Allow'}}
    foreach($order in @(@('Any','5009'),@('5009','Any'))){
        $script:Filters=@($order|ForEach-Object {[pscustomobject]@{Protocol='TCP';LocalPort=$_}})
        $actual=Get-KioskFirewallState 5009
        Assert-Diagnostic ($actual.Verified -and ($actual.Observations.Ports -join ',') -eq '5009') 'A broad all-port rule hid an available explicit port'
    }
    $script:Filters=@([pscustomobject]@{Protocol='TCP';LocalPort='Any'})
    $all=Get-KioskFirewallState 5009
    Assert-Diagnostic (-not $all.Verified -and -not $all.HasAllow -and @($all.Observations).Count -eq 0) 'An Any-port rule satisfied the explicit application port requirement'
    $firewall=New-DiagnosticRow 'Inbound TCP 5009 Rule' 'Missing'
    $firewall|Add-Member NoteProperty FirewallPort 5009
    $firewall|Add-Member NoteProperty FirewallReadVerified $true
    $firewall|Add-Member NoteProperty FirewallObservations @($all.Observations)
    $group=New-ThoroughFirewallReportRow @($firewall)
    Assert-Diagnostic ($group.Status -eq 'Fail' -and (Get-ThoroughReportHighlightFields $group.FoundStateHtml)['Ports'] -eq 'None' -and (Get-ThoroughReportHighlightFields $group.FoundStateHtml)['Missing Allow Rules (Ports)'] -eq '5009') 'An Any-port rule hid the missing explicit port in the report'
    $script:Filters=@();$none=Get-KioskFirewallState 5009
    $firewall.Status='Fail';$firewall.FirewallObservations=@($none.Observations)
    $missing=New-ThoroughFirewallReportRow @($firewall)
    Assert-Diagnostic ((Get-ThoroughReportHighlightFields $missing.FoundStateHtml)['Ports'] -eq 'None') 'Known empty firewall result was not None'
    $script:Filters=@([pscustomobject]@{Protocol='TCP';LocalPort='5009'})
    $specific=Get-KioskFirewallState 5009;$firewall.FirewallObservations=@($specific.Observations);$firewall.Status='Pass'
    $afterFirewall=New-ThoroughFirewallReportRow @($firewall);$afterFirewall.ActionTaken='Created inbound rule; readback verified'
    $applied=New-ThoroughReportSnapshot -Rows @($afterFirewall) -BeforeRows @($missing) -DisplayMode Fix -AfterApply $true
    $appliedHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($applied.HtmlBase64))
    $port=@((Get-SettingRenderedComponent $appliedHtml 'Firewall').Fields|Where-Object Setting -EQ 'Ports')[0]
    Assert-Diagnostic ($port.Findings -eq 'None' -and $port.Value -eq '5009') 'Changed firewall port list prevented verified Applied values from matching their baseline'
    $resolved=@((Get-SettingRenderedComponent $appliedHtml 'Firewall').Fields|Where-Object Setting -EQ 'Missing Allow Rules (Ports)')
    Assert-Diagnostic ($resolved.Count -eq 1 -and $resolved[0].Value -eq 'None' -and $resolved[0].Html -notmatch 'finding-unverified') 'Resolved missing ports were not cleared using the verified readback'
    $nmap=New-DiagnosticRow 'Nmap Diagnostic Tool' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Tool State'='Installed';'Version'='7.993';'Executable Path'='C:\Private\nmap.exe'}))
    $nmap|Add-Member NoteProperty RecordedRequirementHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Installed'='Yes';'Version'='Readable'}))
    $policy=New-DiagnosticRow 'System & Browser Policies' (ConvertTo-ReportDefinitionHtml ([ordered]@{'Pinch-to-Zoom'='Not verified. Please check manually.'}))
    $policy|Add-Member NoteProperty RecordedRequirementHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Pinch-to-Zoom'='Not verified. Please check manually.'}))
    $requiredPolicy=Get-ThoroughReportHighlightFields (Get-ReportRequirement $policy)
    $expectedOrigin=if($client -eq 'Subway'){'https://kiosk.subway.ch'}else{'https://kiosk.ordermonkey.com'}
    Assert-Diagnostic ($requiredPolicy['Local Network Allowlist'] -ceq $expectedOrigin) 'A client policy requirement used the other client URL'
    $recovery=[pscustomobject]@{First='Restart the service';Second='Restart the service';Subsequent='Take No Action';Verified=$true;Error=''}
    $zabbix=New-DiagnosticRow 'Zabbix Agent 2' ((ConvertTo-ServiceFindingHtml -ServiceState Running -StartupType Auto -Recovery $recovery)+(ConvertTo-ReportDefinitionHtml ([ordered]@{'Host Name'='DEVICE-01'}))) 'Type: Infrastructure Monitoring'
    $zabbix.Status='Pass';$zabbix|Add-Member NoteProperty RecoveryDetails $recovery
    $summary=Format-ThoroughFinalServiceRecovery $zabbix $zabbix.FoundStateHtml
    Assert-Diagnostic ([regex]::Matches($summary,'Recovery:</span>').Count -eq 1 -and $summary -match 'Recovery:</span> Configured') 'Hostname-only block invented a second unknown recovery summary'
    $rows=@($group,$nmap,$policy,$zabbix);$before=$rows|ConvertTo-Json -Depth 20 -Compress
    foreach($mode in @('Audit','Fix','Final')){
        $snapshot=New-ThoroughReportSnapshot -Rows $rows -DisplayMode $mode -DeviceType KIOSK -Hostname 'DEVICE-01' -AgentName 'Fixture Agent'
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        [IO.File]::WriteAllText((Join-Path $output ($client+'-'+$mode+'.html')),$html,[Text.UTF8Encoding]::new($false))
        Assert-Diagnostic ($html -notmatch 'Executable Path|C:\\Private') ($mode+' leaked the removed Nmap path')
        if($mode -eq 'Audit'){
            $fields=(Get-AuditRenderedComponent $html 'Nmap Diagnostic Tool').Fields
            Assert-Diagnostic (($fields.Setting -join '|') -eq 'Tool State|Version') 'Nmap has an extra Installed placeholder row'
            $pinch=@((Get-AuditRenderedComponent $html 'System & Browser Policies').Fields|Where-Object Setting -EQ 'Pinch-to-Zoom')[0]
            Assert-Diagnostic ($pinch.Required -eq 'Disabled' -and $pinch.Found -match 'Not verified') 'Unknown observation replaced the required pinch setting'
        }
        if($mode -eq 'Final'){
            $fields=(Get-SettingRenderedComponent $html 'Zabbix Agent').Fields
            Assert-Diagnostic (@($fields|Where-Object Setting -EQ 'Recovery').Count -eq 1) 'Final report duplicated recovery'
        }
    }
    Assert-Diagnostic (($rows|ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'Rendering mutated recorded observations'
    $script:FreshState='Running';$script:RecoveryFixed=$false;$script:RecoveryWrites=0;$script:ReadDenied=$false
    function Get-AuditService {param($ServiceName) Assert-Diagnostic ($ServiceName -eq 'Zabbix Agent 2') 'Unselected service queried';if($script:ReadDenied){throw 'Fixture denied'};[pscustomobject]@{State=$script:FreshState;StartMode='Auto'}}
    function Read-ServiceRecoveryPolicy {param($ServiceName) $script:RecoveryFixed}
    function Invoke-ServiceRecoveryRepair {param($ServiceName) Assert-Diagnostic (Test-CanApply) 'Audit attempted a recovery write';$script:RecoveryWrites++;$script:RecoveryFixed=$true;$true}
    function Get-ServiceRecoveryDetails {param($ServiceName) if($script:RecoveryFixed){$recovery}else{[pscustomobject]@{First='Take No Action';Second='Take No Action';Subsequent='Take No Action';Verified=$true;Error=''}}}
    function Add-AuditEntry {param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken,[switch]$DeferConsole) $auditRows.Add((New-DiagnosticRow $ItemTitle $FoundStateHtml $ItemSub));$auditRows[-1].Status=$Status;$auditRows[-1].ActionTaken=$ActionTaken}
    $auditRows=[Collections.Generic.List[object]]::new();$sec3Num=3;$sec3Title='Services';$script:ApplyChanges=$true
    Invoke-RequiredServiceCheck 'Zabbix Agent 2' 'Zabbix Agent 2' 'Type: Infrastructure Monitoring'
    Assert-Diagnostic ($script:RecoveryWrites -eq 1 -and $auditRows[-1].Status -eq 'Pass') 'Apply did not repair and read back recovery'
    $row=$auditRows[-1];Update-ZabbixServiceReport $row 'DEVICE-01'
    Assert-Diagnostic ((Get-ThoroughReportHighlightFields $row.FoundStateHtml)['Service State'] -eq 'Running') 'Fresh post-hostname Running state missing'
    $script:FreshState='Stopped';Update-ZabbixServiceReport $row 'DEVICE-01'
    Assert-Diagnostic ($row.Status -eq 'Fail' -and (Get-ThoroughReportHighlightFields $row.FoundStateHtml)['Service State'] -eq 'Stopped') 'Restart failure retained stale Running state'
    $script:ReadDenied=$true;Update-ZabbixServiceReport $row 'DEVICE-01'
    Assert-Diagnostic ($row.Status -eq 'Fail' -and (Get-ThoroughReportHighlightFields $row.FoundStateHtml)['Service State'] -eq 'Not verified') 'Unreadable post-restart state was fabricated'
    $script:ReadDenied=$false;$script:FreshState='Running';$script:RecoveryFixed=$false;$script:ApplyChanges=$false;$script:RecoveryWrites=0
    Invoke-RequiredServiceCheck 'Zabbix Agent 2' 'Zabbix Agent 2' 'Type: Infrastructure Monitoring'
    Assert-Diagnostic ($script:RecoveryWrites -eq 0 -and $auditRows[-1].Status -eq 'Fail') 'Audit repaired recovery or hid its mismatch'
    Write-Output ('PASS: '+$client+' specific/all/absent ports, Nmap projection, required pinch setting, single recovery summary, Apply recovery repair and fresh failed/healthy Zabbix readback; no real device changes.')
}
