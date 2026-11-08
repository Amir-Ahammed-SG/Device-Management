
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# Exercise only selected definitions/blocks with in-memory services and accounts.
# No Windows account, service, registry, firewall or installer mutation is allowed.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$parent=$projectRoot
function Assert-ApplyRequirement { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Reset-LegacyFixture {
    $script:services=@{
        Primary=[pscustomobject]@{Name='Primary';State='Running';StartMode='Auto'}
        Older=[pscustomobject]@{Name='Older';State='Running';StartMode='Auto'}
    }
    $script:recovery=@{Primary=@(1,1,0);Older=@(1,1,1)}
    $script:mutations=[Collections.Generic.List[string]]::new()
    $script:recoveryFailure=$false; $script:stopFailure=$false; $script:stopNoEffect=$false; $script:readFailure=$false
    $script:primaryRecoveryValid=$true; $script:captured=$null
}
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $sourcePath=Join-Path $parent $sourceName
    $source=[KioskTestSource]::ReadAllText($sourcePath)
    $tokens=$null; $errors=$null
    $ast=[KioskTestSource]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
    Assert-ApplyRequirement ($errors.Count -eq 0) 'Source parser errors'
    $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $actualRecoveryRepair=${function:Invoke-ServiceRecoveryRepair}
    $actualNoActionRepair=${function:Invoke-ServiceNoActionRecoveryRepair}
    $actualFirewallState=${function:Get-KioskFirewallState}
    function Write-Host { [CmdletBinding()]param($Object,$ForegroundColor) }
    function Get-AuditService { param($ServiceName) $script:services[$ServiceName] }
    function Read-ServiceRecoveryPolicy { param($ServiceName) return $script:primaryRecoveryValid }
    function Read-ServiceNoActionRecoveryPolicy {
        param($ServiceName)
        if ($script:readFailure) { throw 'Fixture recovery read denied' }
        return @($script:recovery[$ServiceName] | Where-Object {$_ -ne 0}).Count -eq 0
    }
    function Get-ServiceRecoveryDetails {
        param($ServiceName)
        if ($script:readFailure) { return [pscustomobject]@{Verified=$false;First='Not verified';Second='Not verified';Subsequent='Not verified';Error='Fixture read denied'} }
        ConvertFrom-ServiceRecoveryActionTypes -Types $script:recovery[$ServiceName]
    }
    function Invoke-ServiceNoActionRecoveryRepair {
        param($ServiceName)
        $script:mutations.Add('Recovery:'+$ServiceName)
        if ($script:recoveryFailure) { return $false }
        $script:recovery[$ServiceName]=@()
        return $true
    }
    function Set-Service { [CmdletBinding()]param($Name,$StartupType) Assert-ApplyRequirement ($Name -eq 'Older' -and $StartupType -eq 'Manual') 'Unexpected service startup mutation'; $script:mutations.Add('Manual:'+$Name); $script:services[$Name].StartMode='Manual' }
    function Stop-Service { [CmdletBinding()]param($Name) Assert-ApplyRequirement ($Name -eq 'Older') 'Unexpected service stop'; $script:mutations.Add('Stop:'+$Name); if ($script:stopFailure) {throw 'Fixture stop denied'}; if (-not $script:stopNoEffect) {$script:services[$Name].State='Stopped'} }
    function Get-Service { [CmdletBinding()]param($Name) $service=[pscustomobject]@{Name=$Name}; $service | Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)}; $service }
    function Add-AuditEntry { param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken) $script:captured=[pscustomobject]@{ItemTitle=$ItemTitle;Status=$Status;FoundStateHtml=$FoundStateHtml;ActionTaken=$ActionTaken} }
    function Start-Process { throw 'Unexpected process execution' }
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        Reset-LegacyFixture
        Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified $true
        Assert-ApplyRequirement ($script:captured.Status -eq $(if ($mode) {'Offline'} else {'Fail'})) 'Legacy status did not match actual state'
        Assert-ApplyRequirement ($script:mutations.Count -eq $(if ($mode) {3} else {0})) 'Audit mutated services or Apply omitted a repair'
        if ($mode) {
            Assert-ApplyRequirement (($script:mutations -join '|') -eq 'Recovery:Older|Manual:Older|Stop:Older') 'Legacy repair did not disable recovery before stopping'
            Assert-ApplyRequirement ([regex]::Matches($script:captured.FoundStateHtml,'Take No Action').Count -eq 3) 'Actual no-action recovery values were not reported'
            Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified $true
            Assert-ApplyRequirement ($script:mutations.Count -eq 3 -and $script:captured.Status -eq 'Offline') 'Repeat Apply changed an already compliant legacy service'
        } else { Assert-ApplyRequirement ([regex]::Matches($script:captured.FoundStateHtml,'Restart the service').Count -eq 3) 'Audit hid actual legacy recovery actions' }
        $expected=Get-ReportRequirement ([pscustomobject]@{ItemTitle='Older (Legacy)';ItemSub='Type: Old Payment Service'})
        Assert-ApplyRequirement ([regex]::Matches($expected,'Take No Action').Count -eq 3 -and $expected -match 'Manual') 'Legacy requirements omit recovery actions'
    }
    $script:ApplyChanges=$true
    foreach ($primaryProblem in @('reportedFailure','stopped','manual','recovery')) {
        Reset-LegacyFixture
        switch ($primaryProblem) {
            stopped {$script:services.Primary.State='Stopped'}
            manual {$script:services.Primary.StartMode='Manual'}
            recovery {$script:primaryRecoveryValid=$false}
        }
        Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified ($primaryProblem -ne 'reportedFailure')
        Assert-ApplyRequirement ($script:mutations.Count -eq 0 -and $script:captured.Status -eq 'Fail') "Legacy changed while primary was not verified: $primaryProblem"
    }
    Reset-LegacyFixture
    Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Primary -PrimaryServiceName Primary -PrimaryVerified $true
    Assert-ApplyRequirement ($script:mutations.Count -eq 0 -and $script:captured.Status -eq 'Fail') 'Primary service was modified as legacy'
    Reset-LegacyFixture; $script:recoveryFailure=$true
    Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified $true
    Assert-ApplyRequirement (($script:mutations -join '|') -eq 'Recovery:Older' -and $script:captured.Status -eq 'Fail' -and $script:captured.FoundStateHtml -match 'Running') 'Failed recovery verification did not prevent the remaining changes'
    foreach ($failure in @('stopFailure','stopNoEffect','readFailure')) {
        Reset-LegacyFixture; Set-Variable -Scope Script -Name $failure -Value $true
        Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified $true
        Assert-ApplyRequirement ($script:captured.Status -eq 'Fail') "Legacy failure reported success: $failure"
        if ($failure -eq 'readFailure') { Assert-ApplyRequirement ($script:mutations.Count -eq 0 -and $script:captured.FoundStateHtml -match 'Not verified') 'Unreadable recovery allowed a mutation' }
        else { Assert-ApplyRequirement ($script:captured.FoundStateHtml -match 'Running' -and $script:captured.FoundStateHtml -match 'Manual') 'Partial failure did not report actual state' }
    }
    Reset-LegacyFixture; $script:services.Older.State='Stopped'; $script:services.Older.StartMode='Manual'
    Invoke-LegacyPaymentServiceCheck -LegacyService $script:services.Older -PrimaryServiceName Primary -PrimaryVerified $true
    Assert-ApplyRequirement (($script:mutations -join '|') -eq 'Recovery:Older' -and $script:captured.Status -eq 'Offline') 'Recovery-only repair made unrelated changes'

    # The actual discovery loop must use the final primary row, not an earlier flag.
    $loop=$ast.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Extent.Text.StartsWith('foreach ($legacy in @($paymentServices')},$true)
    $actualLegacyCheck=${function:Invoke-LegacyPaymentServiceCheck}
    function Invoke-LegacyPaymentServiceCheck { param($LegacyService,$PrimaryServiceName,$PrimaryVerified) $script:receivedPrimaryVerified=$PrimaryVerified }
    $primaryService=[pscustomobject]@{Name='Primary'}
    $paymentServices=@($primaryService,[pscustomobject]@{Name='Older'})
    foreach ($status in @('Pass','Fail')) {
        $primaryServiceRow=[pscustomobject]@{Status=$status}
        . ([scriptblock]::Create($loop.Extent.Text))
        Assert-ApplyRequirement ($script:receivedPrimaryVerified -eq ($status -eq 'Pass')) 'Legacy gate did not use final primary verification'
    }
    ${function:Invoke-LegacyPaymentServiceCheck}=$actualLegacyCheck

    # Check recovery action selection without allowing native service mutation.
    $script:policyCalls=0; $script:primaryRecoveryValid=$true; $script:readFailure=$false
    function Start-Process {throw 'Recovery must not invoke a fixed-timing sc.exe command'}
    function Set-ServiceRecoveryActionPolicy {
        param($ServiceName,[switch]$RestartFirstTwo)
        Assert-ApplyRequirement (Test-CanApply) 'Audit attempted recovery mutation'
        $script:policyCalls++;$script:policyService=$ServiceName;$script:restartFirstTwo=[bool]$RestartFirstTwo
        $script:recovery[$ServiceName]=if ($RestartFirstTwo) {@(1,1,0)} else {@(0,0,0)}
    }
    & $actualRecoveryRepair -ServiceName 'FixturePayment' | Out-Null
    Assert-ApplyRequirement ($script:policyCalls -eq 1 -and $script:policyService -ceq 'FixturePayment' -and $script:restartFirstTwo) 'Required restart action types were not selected'
    $script:recovery.FixtureLegacy=@(1,1,1)
    & $actualNoActionRepair -ServiceName 'FixtureLegacy' | Out-Null
    Assert-ApplyRequirement ($script:policyCalls -eq 2 -and $script:policyService -ceq 'FixtureLegacy' -and -not $script:restartFirstTwo) 'No Action types were not selected'
    $script:ApplyChanges=$false; $before=$script:policyCalls; $threw=$false
    try { & $actualRecoveryRepair -ServiceName 'FixturePayment' | Out-Null } catch {$threw=$true}
    Assert-ApplyRequirement ($threw -and $script:policyCalls -eq $before) 'Audit invoked native recovery repair'

    # Existing accounts: only the two required flags may change, including disabled accounts.
    function Get-LocalAccountProperties { param($UserName) $script:accountFlags }
    function Set-LocalUser { [CmdletBinding()]param($Name,$PasswordNeverExpires,$UserMayChangePassword) $script:accountWrites++; if (-not $script:accountWriteNoEffect) { $script:accountFlags.PasswordNeverExpires=$PasswordNeverExpires; $script:accountFlags.UserCannotChangePassword=-not $UserMayChangePassword } }
    # Route the new narrow writer through this fixture's existing mock; never bind ADSI.
    function Open-ThoroughLocalAccount {throw 'Live Windows account access is forbidden in this fixture.'}
    function Enable-LocalAccountPasswordFlags {
        param([string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword)
        $settings=@{Name=$UserName}
        if($PasswordNeverExpires){$settings.PasswordNeverExpires=$true}
        if($UserCannotChangePassword){$settings.UserMayChangePassword=$false}
        Set-LocalUser @settings
        [pscustomobject]@{Changed=$true}
    }

    function New-LocalUser {throw 'Unexpected account creation'}
    function Enable-LocalUser {throw 'Unexpected account enabling'}
    function Disable-LocalUser {throw 'Unexpected account disabling'}
    function Add-LocalGroupMember {throw 'Unexpected privilege change'}
    function Remove-LocalGroupMember {throw 'Unexpected privilege change'}
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($admin in @($false,$true)) {
            $account=[pscustomobject]@{Name=$(if ($admin) {'Administrator'} else {'SELISE-KIOSK'});Enabled=$false;SID=[pscustomobject]@{Value='FixtureSid'}}
            $adminSids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($admin) {[void]$adminSids.Add('FixtureSid')}
            $script:accountFlags=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}; $script:accountWrites=0; $script:accountWriteNoEffect=$false
            $result=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids
            Assert-ApplyRequirement (($result.Status -eq 'Pass') -eq ($mode -and $admin)) 'Account requirements including administrator privilege were not reflected in status'
            if (-not $admin) {
                $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='Administrative Accounts';FoundStateHtml=$result.StateHtml})
                Assert-ApplyRequirement ($view.ExpectedHtml -match 'Account Privilege:</span> Standard or Administrator' -and $view.FindingsHtml -match 'Account Privilege:</span> Standard' -and $result.Action -match 'Manual action required') 'Privilege display or preserved administrative check action is incorrect'
            }
            Assert-ApplyRequirement ($script:accountWrites -eq [int]$mode -and -not $account.Enabled -and $account.SID.Value -eq 'FixtureSid') 'Account enabled state, identity or privilege changed'
            if ($mode) { Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids | Out-Null; Assert-ApplyRequirement ($script:accountWrites -eq 1) 'Compliant account flags were rewritten' }
            $missing=New-MissingAccountResult -RequestedName $account.Name
            $view=Get-AccountReportView ([pscustomobject]@{ItemTitle=$(if ($admin) {'Administrative Accounts'} else {'KIOSK Account'});FoundStateHtml=$missing.StateHtml})
            Assert-ApplyRequirement ($missing.Status -eq 'Fail' -and $view.FindingsHtml -ceq 'Account Missing. Please create manually.') 'Missing account message is incorrect'
            $note=Get-ThoroughConsoleNote -ItemTitle $(if ($admin) {'Administrative Accounts'} else {'KIOSK Account'}) -FoundStateHtml $missing.StateHtml -Status 'Fail' -ActionTaken $missing.Action
            Assert-ApplyRequirement ($note.StartsWith('Account Missing. Please create manually.')) 'Missing-account console message does not request manual creation'
        }
    }
    $script:ApplyChanges=$true; $script:accountWriteNoEffect=$true
    $script:accountFlags=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}
    $result=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $adminSids
    Assert-ApplyRequirement ($result.Status -eq 'Fail' -and $result.Action -match 'not verified after Apply' -and -not $account.Enabled) 'Account repair without successful readback was reported as Pass'

    # Existing matching firewall rules retain their profiles. Only missing rules
    # lead to creation/repair of managed rules with Profile Any.
    $script:firewallWrites=[Collections.Generic.List[string]]::new()
    $script:managedExists=$false
    function Get-NetFirewallPortFilter { [CmdletBinding()]param($PolicyStore,$AssociatedNetFirewallRule) [pscustomobject]@{Protocol='TCP';LocalPort='5009'} }
    function Get-NetFirewallRule {
        [CmdletBinding()]param($AssociatedNetFirewallPortFilter,$PolicyStore,$Name)
        if ($null -ne $AssociatedNetFirewallPortFilter) { [pscustomobject]@{Enabled='True';Direction='Inbound';Action='Allow';Profile='Private'} }
        elseif ($script:managedExists) { [pscustomobject]@{Name=$Name} }
    }
    $existing=& $actualFirewallState -Port 5009
    Assert-ApplyRequirement ($existing.HasAllow -and $existing.Verified) 'Existing matching rule unexpectedly required all profiles'
    function Get-KioskFirewallState { param($Port) [pscustomobject]@{HasAllow=$script:firewallAvailable;Verified=$script:firewallAvailable;Details='Fixture'} }
    function New-NetFirewallRule {
        [CmdletBinding()]param($Name,$DisplayName,$PolicyStore,$Direction,$LocalPort,$Protocol,$Action,$Enabled,$Profile)
        Assert-ApplyRequirement ($Profile -eq 'Any' -and $LocalPort -eq 5009 -and $Protocol -eq 'TCP' -and $Direction -eq 'Inbound' -and $Action -eq 'Allow') 'Created firewall rule scope incorrect'
        $script:firewallWrites.Add('Create'); $script:firewallAvailable=$true
    }
    function Set-NetFirewallRule {
        [CmdletBinding()]param($Name,$PolicyStore,$Direction,$Action,$Enabled,$Profile)
        Assert-ApplyRequirement ($Profile -eq 'Any' -and $Name -eq 'SELISE-Kiosk-TCP-5009-Inbound') 'Updated rule scope incorrect'
        $script:firewallWrites.Add('Update'); $script:firewallAvailable=$true
    }
    function Set-NetFirewallPortFilter {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,$Protocol,$LocalPort)
        process { Assert-ApplyRequirement ($Protocol -eq 'TCP' -and $LocalPort -eq 5009) 'Updated firewall port incorrect'; $script:firewallWrites.Add('Filter') }
    }
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode; $script:firewallAvailable=$true; $script:firewallWrites.Clear()
        Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'Fixture'
        Assert-ApplyRequirement ($script:captured.Status -eq 'Pass' -and $script:firewallWrites.Count -eq 0) 'Existing matching rule was changed'
        $script:firewallAvailable=$false; $script:managedExists=$false
        Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'Fixture'
        Assert-ApplyRequirement (($script:captured.Status -eq 'Pass') -eq $mode) 'Missing firewall rule status incorrect'
        Assert-ApplyRequirement ($script:firewallWrites.Count -eq [int]$mode) 'Audit wrote a firewall rule or Apply did not create it'
    }
    $script:ApplyChanges=$true; $script:firewallAvailable=$false; $script:managedExists=$true; $script:firewallWrites.Clear()
    Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'Fixture'
    Assert-ApplyRequirement ($script:captured.Status -eq 'Pass' -and ($script:firewallWrites -join '|') -eq 'Update|Filter') 'Missing managed rule was not repaired with readback'
    Write-Output "PASS: $sourceName verified legacy recovery/primary guard, Audit safety, actual findings, required action-only recovery selection, required-only account flags and firewall create/skip scope"
}
