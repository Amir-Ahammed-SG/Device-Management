
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# In-memory services only. No production entry point, service API or installer runs.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$root=$projectRoot
function Assert-CoreChange {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
foreach ($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null;$errors=$null
    $text=[KioskTestSource]::ReadAllText((Join-Path $root $name))
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Assert-CoreChange ($errors.Count -eq 0) 'Production source did not parse'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $actualInstall=${function:Invoke-ZabbixAgentInstall}
    function Read-Host {throw 'Unexpected hostname prompt'}
    function Start-Process {
        [CmdletBinding()]param($FilePath,$ArgumentList,[switch]$Wait,[switch]$NoNewWindow,[switch]$PassThru)
        $script:processCalls++
        Assert-CoreChange ($ArgumentList -match '-NonInteractive.*-EncodedCommand ([A-Za-z0-9+/=]+)$') 'Installer was not non-interactive/encoded'
        $command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
        Assert-CoreChange ($errors.Count -eq 0 -and $command -notmatch 'cmd.exe|Invoke-Expression|Read-Host|install_zabbix.ps1') 'Unsafe or interactive installer wrapper invoked'
        Assert-CoreChange ($command -match "FromBase64String\('([A-Za-z0-9+/=]+)'\)") 'Encoded hostname not supplied'
        $script:passedHostname=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
        [pscustomobject]@{ExitCode=$script:installExit}
    }
    $script:processCalls=0;$script:installExit=0;$script:ApplyChanges=$false
    $threw=$false;try {Invoke-ZabbixAgentInstall -Hostname 'LAUNCHER-01'} catch {$threw=$true}
    Assert-CoreChange ($threw -and $script:processCalls -eq 0) 'Audit launched an installer'
    $script:ApplyChanges=$true
    foreach ($invalid in @('','Not verified','Not detected',"Bad`nHost",'Bad"Host')) {
        $threw=$false;try {Invoke-ZabbixAgentInstall -Hostname $invalid} catch {$threw=$true}
        Assert-CoreChange ($threw -and $script:processCalls -eq 0) 'Unverified hostname launched an installer'
    }
    foreach ($hostValue in @('LAUNCHER-01',"Literal-'`$value & host")) {
        Invoke-ZabbixAgentInstall -Hostname $hostValue
        Assert-CoreChange ($script:passedHostname -ceq $hostValue) 'Launcher hostname was changed in command transport'
    }
    $script:installExit=5;$threw=$false;try {Invoke-ZabbixAgentInstall -Hostname 'LAUNCHER-01'} catch {$threw=$true}
    Assert-CoreChange $threw 'Installer failure was ignored'

    # Exercise the actual Zabbix orchestration block with fake service/install boundaries.
    function Read-Host {param($Prompt) Assert-CoreChange ($Prompt -ceq 'Zabbix Hostname') 'Unexpected prompt';$script:promptCalls++;return $script:hostnameReply}
    function Start-AuditStep {param($Number,$Name)}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    function Get-AuditService {param($ServiceName) if ($script:agentPresent) {[pscustomobject]@{Name=$ServiceName;PathName='fixture-agent.exe';State='Running';StartMode='Auto'}}}
    function Invoke-ZabbixAgentInstall {param($Hostname) [void](New-ZabbixInstallCommand -Hostname $Hostname);$script:installCalls++;$script:agentPresent=$true;$script:observedHost=$Hostname}
    function Get-ZabbixConfiguredHostname {param($CommandLine) if (-not $CommandLine) {return 'Not verified'}; $script:observedHost}
    function Add-AuditEntry {param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken) $auditRows.Add([pscustomobject]@{ItemTitle=$ItemTitle;ItemSub=$ItemSub;FoundStateHtml=$FoundStateHtml;Status=$Status;ActionTaken=$ActionTaken})}
    function Invoke-RequiredServiceCheck {param($ServiceName,$ItemTitle,$ItemSub,[switch]$DeferConsole) $auditRows.Add([pscustomobject]@{ItemTitle=$ItemTitle;ItemSub=$ItemSub;FoundStateHtml='';Status=$(if ($script:agentPresent) {'Pass'} else {'Fail'});ActionTaken=''})}
    $start=$text.IndexOf("Start-AuditStep 8 'Zabbix Agent 2'")
    $end=$text.IndexOf('# 3.3 Windows Update Service',$start)
    $zabbixBlock=[scriptblock]::Create($text.Substring($start,$end-$start))
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($present in @($false,$true)) {
            foreach ($hostname in @('LAUNCHER-01','Not verified')) {
                $script:agentPresent=$present;$script:observedHost='LAUNCHER-01';$script:installCalls=0;$script:promptCalls=0;$script:hostnameReply='ZABBIX-MANUAL-01'
                $reportHostname=$hostname;$auditRows=[Collections.Generic.List[psobject]]::new()
                . $zabbixBlock
                $shouldInstall=$mode -and -not $present
                Assert-CoreChange ($script:installCalls -eq [int]$shouldInstall) 'Incorrect agent installation condition'
                $shouldPrompt=$shouldInstall -and $hostname -eq 'Not verified'
                Assert-CoreChange ($script:promptCalls -eq [int]$shouldPrompt -and $reportHostname -ceq $hostname) 'Unexpected prompt count or launcher hostname was changed'
                $shouldPass=$shouldInstall -or ($present -and $hostname -eq 'LAUNCHER-01')
                Assert-CoreChange (($auditRows[-1].Status -eq 'Pass') -eq $shouldPass) 'Unverified hostname/service was accepted'
                $expected=Get-ReportRequirement $auditRows[-1]
                $expectedHost=if ($shouldPrompt) {'ZABBIX-MANUAL-01'} else {$hostname}
                Assert-CoreChange ($expected.Contains('Host Name:</span> '+$expectedHost)) 'Chosen hostname missing from required configuration'
                if ($shouldInstall) {
                    Assert-CoreChange ($script:observedHost -ceq $expectedHost) 'Installer did not receive the chosen hostname'
                    Assert-CoreChange ($auditRows[-1].ActionTaken -match '^Installed missing Zabbix Agent; service presence verified') 'New Zabbix installation was absent from the action record.'
                }
            }
        }
        $script:agentPresent=$true;$script:observedHost='OTHER-HOST';$script:installCalls=0;$script:promptCalls=0
        $reportHostname='LAUNCHER-01';$auditRows=[Collections.Generic.List[psobject]]::new()
        . $zabbixBlock
        Assert-CoreChange ($auditRows[-1].Status -eq 'Fail' -and $script:observedHost -ceq 'OTHER-HOST' -and $script:installCalls -eq 0 -and $script:promptCalls -eq 0) 'Existing mismatched hostname was changed or accepted'
    }
    foreach ($unusable in @('', 'Not detected','Bad"Hostname',"Bad`nHostname")) {
        $script:ApplyChanges=$true;$script:agentPresent=$false;$script:observedHost='';$script:installCalls=0;$script:promptCalls=0;$script:hostnameReply='MANUAL-FALLBACK'
        $reportHostname=$unusable;$auditRows=[Collections.Generic.List[psobject]]::new()
        . $zabbixBlock
        Assert-CoreChange ($auditRows[-1].Status -eq 'Pass' -and $script:installCalls -eq 1 -and $script:promptCalls -eq 1 -and $script:observedHost -ceq 'MANUAL-FALLBACK' -and $reportHostname -ceq $unusable) 'Unusable launcher hostname did not use the validated fallback independently of the launcher'
    }
    foreach ($invalidReply in @('', 'Not verified','Bad"Hostname',"Bad`nHostname")) {
        $script:ApplyChanges=$true;$script:agentPresent=$false;$script:observedHost='';$script:installCalls=0;$script:promptCalls=0;$script:hostnameReply=$invalidReply
        $reportHostname='Not verified';$auditRows=[Collections.Generic.List[psobject]]::new()
        . $zabbixBlock
        Assert-CoreChange ($auditRows[-1].Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:promptCalls -eq 1 -and $reportHostname -ceq 'Not verified' -and $auditRows[-1].ExpectedHostName -ceq 'Not verified') 'Blank/invalid fallback launched installer or changed launcher hostname/reference'
    }

    # Exercise the actual Windows Update block, including no-op repeats and failures.
    $start=$text.IndexOf('# 3.3 Windows Update Service')
    $end=$text.IndexOf('# GROUP 5:',$start)
    $wuBlock=[scriptblock]::Create($text.Substring($start,$end-$start))
    function Get-AuditService {param($ServiceName) if (-not $script:missing) {[pscustomobject]@{Name=$ServiceName;State=$script:state;StartMode=$script:startup}}}
    function Read-ServiceNoActionRecoveryPolicy {param($ServiceName) if ($script:denied) {throw 'Recovery read denied'};return $script:noAction}
    function Invoke-ServiceNoActionRecoveryRepair {param($ServiceName) $script:mutations.Add('Recovery');if (-not $script:recoveryFailed) {$script:noAction=$true};return $script:noAction}
    function Get-ServiceRecoveryDetails {param($ServiceName) [pscustomobject]@{Verified=(-not $script:denied);First=$(if ($script:noAction) {'Take No Action'} else {'Restart the service'});Second='Take No Action';Subsequent='Take No Action';Error='Fixture denied'}}
    function Set-Service {[CmdletBinding()]param($Name,$StartupType) Assert-CoreChange ($Name -eq 'wuauserv' -and $StartupType -eq 'Disabled') 'Unexpected service change';$script:mutations.Add('Disabled');if ($script:disableFailed) {throw 'Disable denied'};if (-not $script:noEffect) {$script:startup='Disabled'}}
    function Stop-Service {[CmdletBinding()]param($Name,[switch]$Force) Assert-CoreChange ($Name -eq 'wuauserv') 'Another service stopped';$script:mutations.Add('Stopped');if (-not $script:stopFailed) {$script:state='Stopped'}}
    function Get-Service {[CmdletBinding()]param($Name) $service=[pscustomobject]@{};$service | Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)};$service}
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($initialState in @('Running','Stopped')) {
            foreach ($initialStartup in @('Manual','Auto','Disabled')) {
                foreach ($initialRecovery in @($false,$true)) {
                    $script:state=$initialState;$script:startup=$initialStartup;$script:noAction=$initialRecovery
                    $script:mutations=[Collections.Generic.List[string]]::new()
                    $script:denied=$false;$script:missing=$false;$script:disableFailed=$false;$script:stopFailed=$false;$script:noEffect=$false;$script:recoveryFailed=$false
                    $auditRows=[Collections.Generic.List[psobject]]::new();. $wuBlock
                    $compliant=$mode -or ($initialState -eq 'Stopped' -and $initialStartup -eq 'Disabled' -and $initialRecovery)
                    Assert-CoreChange (($auditRows[-1].Status -eq 'Pass') -eq $compliant) 'Windows Update status does not reflect all required settings'
                    if ($mode) {
                        Assert-CoreChange ($script:state -eq 'Stopped' -and $script:startup -eq 'Disabled' -and $script:noAction) 'Windows Update Apply omitted a required repair'
                        $before=$script:mutations.Count;$auditRows=[Collections.Generic.List[psobject]]::new();. $wuBlock
                        Assert-CoreChange ($script:mutations.Count -eq $before) 'Compliant Windows Update settings were rewritten'
                        Assert-CoreChange ((Get-ThoroughReportAppliedHtml $auditRows[-1]) -match '<strong>No Change Needed</strong>') 'Compliant Update service was reported as repaired.'
                    } else {Assert-CoreChange ($script:mutations.Count -eq 0 -and $script:startup -ceq $initialStartup -and $script:state -ceq $initialState) 'Audit changed Windows Update'}
                }
            }
        }
    }
    foreach ($problem in @('denied','missing','disableFailed','stopFailed','noEffect','recoveryFailed')) {
        $script:ApplyChanges=$true;$script:state='Running';$script:startup='Manual';$script:noAction=$false
        $script:denied=$false;$script:missing=$false;$script:disableFailed=$false;$script:stopFailed=$false;$script:noEffect=$false;$script:recoveryFailed=$false
        Set-Variable -Scope Script -Name $problem -Value $true
        $script:mutations=[Collections.Generic.List[string]]::new();$auditRows=[Collections.Generic.List[psobject]]::new();. $wuBlock
        Assert-CoreChange ($auditRows[-1].Status -eq 'Fail') "Windows Update failure reported as Pass: $problem"
        $applied=Get-ThoroughReportAppliedHtml $auditRows[-1]
        Assert-CoreChange ($applied -match '<strong>Manual Action Required</strong>' -and $applied -notmatch '<strong>No Change Needed</strong>') 'Failed Update repair was reported as applied or unnecessary.'
        if($problem -eq 'disableFailed'){Assert-CoreChange ($applied -match 'Recovery actions set to Take No Action' -and $applied -match 'Disable denied') 'Partial Update repair was lost from the action record.'}
        if ($problem -in @('denied','missing')) {Assert-CoreChange ($script:mutations.Count -eq 0) 'Missing/unreadable service caused a write'}
        if ($problem -eq 'recoveryFailed') {Assert-CoreChange (($script:mutations -join '|') -eq 'Recovery') 'Unverified recovery did not prevent later repairs'}
    }
    Write-Output "PASS: $name non-interactive launcher hostname transport, agent installation guards/matches, Windows Update Disabled/Stopped matrix, no-op repeats, Audit safety and failure readback"
}
