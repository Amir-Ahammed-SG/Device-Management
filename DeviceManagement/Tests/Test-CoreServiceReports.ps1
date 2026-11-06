
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$root=$projectRoot
function Assert-ServiceReport { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Get-FieldNames { param([string]$Html) @([regex]::Matches($Html,'<span class="kv-label">([^<]+):</span>') | ForEach-Object { $_.Groups[1].Value }) }
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $root $sourceName),[ref]$tokens,[ref]$errors)
    Assert-ServiceReport ($errors.Count -eq 0) 'Source parse failed'
    $text=[KioskTestSource]::ReadAllText((Join-Path $root $sourceName))
    $definitions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))

    $none=ConvertFrom-ServiceRecoveryActionTypes -Types @()
    Assert-ServiceReport ($none.First -eq 'Take No Action' -and $none.Second -eq 'Take No Action' -and $none.Subsequent -eq 'Take No Action') 'Empty recovery array not shown as no action'
    $repeat=ConvertFrom-ServiceRecoveryActionTypes -Types @(1,0)
    Assert-ServiceReport ($repeat.First -eq 'Restart the service' -and $repeat.Second -eq 'Take No Action' -and $repeat.Subsequent -eq 'Take No Action') 'Last recovery action not repeated'
    $unknown=ConvertFrom-ServiceRecoveryActionTypes -Types @(9)
    Assert-ServiceReport (-not $unknown.Verified -and $unknown.First -match 'Unknown') 'Unknown recovery action was verified'
    $actual=ConvertFrom-ServiceRecoveryActionTypes -Types @(2,3,1)
    $html=ConvertTo-ServiceFindingHtml -ServiceName 'ObservedService' -ServiceState 'Stopped' -StartupType 'Manual' -Recovery $actual -Version '8.0.0.0'
    Assert-ServiceReport (($((Get-FieldNames $html) -join '|')) -ceq 'Service Name|Service State|Startup type|First failure|Second failure|Subsequent failures|Version') 'Payment Findings fields are out of order'
    Assert-ServiceReport ($html -match 'Stopped' -and $html -match 'Restart the computer' -and $html -match 'Run a program' -and $html -match '8.0.0.0') 'Actual findings were replaced with expected values'
    Assert-ServiceReport ($html -notmatch 'Expected Names|Executable File Version') 'Unexpected payment Findings fields'

    $paymentExpected=Get-ReportRequirement ([pscustomobject]@{ ItemTitle='Payment Gateway Middleware'; ItemSub='Type: Payment Gateway Middleware' })
    Assert-ServiceReport (((Get-FieldNames $paymentExpected) -join '|') -ceq 'Expected Names|Service State|Startup type|First failure|Second failure|Subsequent failures|Version') 'Payment Expected fields are out of order'
    $expectedNames=if ($sourceName -like 'Subway*') { 'SubwayLocal or AspPaymentSubwayProd' } else { 'AspPaymentSaaSProd' }
    Assert-ServiceReport ($paymentExpected.Contains($expectedNames) -and $paymentExpected.Contains('Readable') -and -not $paymentExpected.Contains('0.0.0.0')) 'Payment expected names or Readable version requirement missing'
    $zabbixExpected=Get-ReportRequirement ([pscustomobject]@{ ItemTitle='Zabbix Agent 2'; ItemSub='Type: Infrastructure Monitoring' })
    Assert-ServiceReport (((Get-FieldNames $zabbixExpected) -join '|') -ceq 'Service State|Startup type|First failure|Second failure|Subsequent failures|Host Name') 'Zabbix Expected fields are out of order'
    $wuExpected=Get-ReportRequirement ([pscustomobject]@{ ItemTitle='Windows Update (wuauserv)'; ItemSub='Type: Windows Update Engine' })
    Assert-ServiceReport (((Get-FieldNames $wuExpected) -join '|') -ceq 'Service State|Startup type|First failure|Second failure|Subsequent failures') 'Update Expected fields are out of order'

    $configFolder=Join-Path $projectRoot 'output\report-layout\service-test-fixtures'
    New-Item -ItemType Directory -Path $configFolder -Force | Out-Null
    $agentConfig=Join-Path $configFolder 'zabbix_agent2.conf'
    [IO.File]::WriteAllText($agentConfig,'Hostname=MONITORING-HOST-02',[Text.UTF8Encoding]::new($false))
    Assert-ServiceReport ((Get-ZabbixConfiguredHostname -CommandLine '"C:\Agent\zabbix_agent2.exe"' -DefaultConfigurationPath $agentConfig) -eq 'MONITORING-HOST-02') 'Default Zabbix config not read'
    Assert-ServiceReport ((Get-ZabbixConfiguredHostname -CommandLine ('agent.exe --config "'+$agentConfig+'"')) -eq 'MONITORING-HOST-02') 'Explicit Zabbix config not read'
    Assert-ServiceReport ((Get-ZabbixConfiguredHostname -CommandLine '' -DefaultConfigurationPath $agentConfig) -match 'Not verified') 'Absent service reused another agent config'

    # Everything below is an in-memory service boundary. No Windows APIs run.
    $script:fixtureState='Running'; $script:fixtureStartup='Auto'; $script:fixtureActions=@(1,1,0); $script:fixtureMutations=0
    function Get-ServiceRecoveryActionTypes { param($ServiceName) $script:fixtureActions }
    function Get-AuditService { param($ServiceName) [pscustomobject]@{ Name=$ServiceName; State=$script:fixtureState; StartMode=$script:fixtureStartup } }
    function Read-ServiceRecoveryPolicy { param($ServiceName) return (($script:fixtureActions -join ',') -eq '1,1,0') }
    function Read-ServiceNoActionRecoveryPolicy { param($ServiceName) return @($script:fixtureActions | Where-Object { $_ -ne 0 }).Count -eq 0 }
    function Set-Service { [CmdletBinding()]param($Name,$StartupType) $script:fixtureMutations++; $script:fixtureStartup=if ($StartupType -eq 'Automatic') {'Auto'} else {[string]$StartupType} }
    function Start-Service { [CmdletBinding()]param($Name) $script:fixtureMutations++; $script:fixtureState='Running' }
    function Stop-Service { [CmdletBinding()]param($Name,[switch]$Force) $script:fixtureMutations++; $script:fixtureState='Stopped' }
    function Get-Service {
        [CmdletBinding()]param($Name)
        $service=[pscustomobject]@{ Name=$Name }
        $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status,$Timeout) }
        $service
    }
    function Invoke-ServiceRecoveryRepair { param($ServiceName) $script:fixtureMutations++; $script:fixtureActions=@(1,1,0); $true }
    function Invoke-ServiceNoActionRecoveryRepair { param($ServiceName) $script:fixtureMutations++; $script:fixtureActions=@(); $true }
    function Start-AuditStep { param($Number,$Name) }
    # Run the actual version-detail try/catch with only file and service fixtures.
    $detailTry=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text -match '^\{\s*\$primaryExecutablePath = Get-PaymentExecutablePath \$primaryService'},$true) | Select-Object -First 1
    Assert-ServiceReport ($null -ne $detailTry) 'Payment detail verification boundary missing'
    $fixtureExecutable=Join-Path $configFolder 'FixturePayment.exe'
    [IO.File]::WriteAllText($fixtureExecutable,'',[Text.UTF8Encoding]::new($false))
    $primaryService=[pscustomobject]@{Name='FixturePayment';PathName=('"'+$fixtureExecutable+'"');State='Running';StartMode='Auto'}
    function Get-ThoroughPaymentVersionDetails { param($ExecutablePath) [pscustomobject]@{Version=$script:observedVersion;ExecutableFileVersion=$script:observedVersion} }
    foreach ($applyMode in @($false,$true)) {
        $script:ApplyChanges=$applyMode
        foreach ($observedVersion in @('8.3.2.1','10.5.0.0','Not detected')) {
            $script:observedVersion=$observedVersion
            foreach ($initialStatus in @('Pass','Fail')) {
                $primaryServiceRow=[pscustomobject]@{Status=$initialStatus;ActionTaken='Service settings checked';FoundStateHtml='Not verified';RecoveryDetails=$none}
                $script:fixtureMutations=0
                . ([scriptblock]::Create($detailTry.Extent.Text))
                $expectedStatus=if ($observedVersion -eq 'Not detected') { 'Fail' } else { $initialStatus }
                Assert-ServiceReport ($primaryServiceRow.Status -eq $expectedStatus) 'Version placeholder enforced as a target or existing failure hidden'
                Assert-ServiceReport ($primaryServiceRow.FoundStateHtml.Contains(('Version:</span> '+$observedVersion))) 'Actual installed version was replaced by the placeholder'
                Assert-ServiceReport ($script:fixtureMutations -eq 0) 'Version inspection changed service state'
            }
        }
    }
    $script:AuditStepTimer=$null
    $sec3Num=3; $sec3Title='Core Background Services'
    foreach ($applyMode in @($false,$true)) {
        $script:ApplyChanges=$applyMode
        $auditRows=[Collections.Generic.List[psobject]]::new()
        $script:fixtureState='Stopped'; $script:fixtureStartup='Manual'; $script:fixtureActions=@(2,3,0); $script:fixtureMutations=0
        Invoke-RequiredServiceCheck -ServiceName 'FixturePayment' -ItemTitle 'Payment Gateway Middleware' -ItemSub 'Type: Payment Gateway Middleware'
        $row=$auditRows[-1]
        Assert-ServiceReport (($row.Status -eq 'Pass') -eq $applyMode) 'Service result does not reflect readback'
        Assert-ServiceReport (((Get-FieldNames $row.FoundStateHtml) -join '|') -ceq 'Service Name|Service State|Startup type|First failure|Second failure|Subsequent failures|Version') 'Observed recovery fields absent'
        if (-not $applyMode) { Assert-ServiceReport ($script:fixtureMutations -eq 0 -and $row.FoundStateHtml -match 'Restart the computer') 'Audit modified or hid actual service actions' }
        else { Assert-ServiceReport ($row.FoundStateHtml -match 'Startup type:</span> Automatic') 'Apply startup readback not normalized' }

        $auditRows=[Collections.Generic.List[psobject]]::new()
        $script:fixtureState='Running'; $script:fixtureStartup='Manual'; $script:fixtureActions=@(1,1,0); $script:fixtureMutations=0
        $begin=$text.IndexOf('# 3.3 Windows Update Service',[StringComparison]::Ordinal)
        $end=$text.IndexOf('# GROUP 5:',$begin,[StringComparison]::Ordinal)
        . ([scriptblock]::Create($text.Substring($begin,$end-$begin)))
        $row=$auditRows[-1]
        Assert-ServiceReport (((Get-FieldNames $row.FoundStateHtml) -join '|') -ceq 'Service State|Startup type|First failure|Second failure|Subsequent failures') 'Windows Update Findings fields are out of order'
        $expectedStartup=if ($applyMode) {'Disabled'} else {'Manual'}
        Assert-ServiceReport ($row.FoundStateHtml.Contains('Startup type:</span> '+$expectedStartup) -and $script:fixtureStartup -eq $expectedStartup) 'Windows Update startup type was not recorded accurately'
        if ($applyMode) {
            Assert-ServiceReport ($row.Status -eq 'Pass' -and $row.FoundStateHtml -notmatch 'Restart the service' -and $script:fixtureState -eq 'Stopped') 'Update Apply did not report actual no-action readback'
            $applied=Get-ThoroughReportAppliedHtml $row
            Assert-ServiceReport ($applied -match 'Startup set to Disabled' -and $applied -match 'Service stop requested' -and $applied -match 'Recovery actions set to Take No Action' -and $applied -notmatch 'No change needed') 'Applied omitted the actual Update repairs.'
            $writes=$script:fixtureMutations
            . ([scriptblock]::Create($text.Substring($begin,$end-$begin)))
            Assert-ServiceReport ($script:fixtureMutations -eq $writes -and (Get-ThoroughReportAppliedHtml $auditRows[-1]) -match '^No change needed') 'Repeat Update Apply reported a repair or changed a compliant service.'
        }
        else { Assert-ServiceReport ($row.Status -eq 'Fail' -and $script:fixtureMutations -eq 0 -and $row.FoundStateHtml -match 'Service State:</span> Running') 'Update Audit changed state or hid mismatch' }
    }
    function Get-ServiceRecoveryActionTypes { param($ServiceName) throw 'Fixture access denied' }
    $failedRecovery=Get-ServiceRecoveryDetails -ServiceName 'Fixture'
    Assert-ServiceReport (-not $failedRecovery.Verified -and $failedRecovery.First -eq 'Not verified') 'Unreadable recovery settings were invented'
    Write-Host "PASS: $sourceName ordered service fields, actual recovery values, hostname sources, Audit safety and Apply readback"
}
