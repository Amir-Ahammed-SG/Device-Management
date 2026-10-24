$projectRoot = Split-Path $PSScriptRoot -Parent
# Compile the native helper but exercise only managed planning and fixture policies.
# Never query/change a real service or start sc.exe.
$ErrorActionPreference='Stop'
$root=Split-Path $projectRoot -Parent
function Assert-RecoveryTiming {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
function New-RecoveryFixture {
    param([uint32]$Reset,[int[]]$Types,[uint32[]]$Delays)
    $value=New-Object KioskAudit.RecoveryPolicySnapshot
    $value.ResetPeriod=$Reset;$value.ActionTypes=$Types;$value.DelaysMs=$Delays
    return $value
}
foreach ($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    Assert-RecoveryTiming ($errors.Count -eq 0) 'Source parser errors'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $loader=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ServiceRecoverySnapshot'},$true)
    $nativeSource=$loader.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('using System;')},$true).Value
    Assert-RecoveryTiming (-not [string]::IsNullOrWhiteSpace($nativeSource)) 'Native helper definition missing'
    if (-not ('KioskAudit.ServiceRecoverySettings' -as [type])) {Add-Type -TypeDefinition $nativeSource -ErrorAction Stop;$firstNativeSource=$nativeSource}
    else {Assert-RecoveryTiming ($nativeSource -ceq $firstNativeSource) 'Client recovery implementations differ'}
    $actualSetPolicy=${function:Set-ServiceRecoveryActionPolicy}
    function Get-ServiceRecoverySnapshot {
        param($ServiceName)
        Assert-RecoveryTiming ($ServiceName -ceq 'Fixture') 'Another service accessed'
        if ($script:readDenied) {throw 'Fixture recovery read denied'}
        $script:current
    }
    function Set-ServiceRecoveryActionPolicy {
        param($ServiceName,[switch]$RestartFirstTwo)
        if (-not (Test-CanApply)) {throw 'Audit write forbidden'}
        $before=Get-ServiceRecoverySnapshot -ServiceName $ServiceName
        if ([KioskAudit.ServiceRecoverySettings]::MatchesActions($before,[bool]$RestartFirstTwo)) {return}
        if ($script:writeDenied) {throw 'Fixture recovery write denied'}
        $after=[KioskAudit.ServiceRecoverySettings]::WithRequiredActions($before,[bool]$RestartFirstTwo)
        if (-not [KioskAudit.ServiceRecoverySettings]::TimingMatches($before,$after)) {throw 'Timing preservation failed'}
        $script:writes++;$script:current=$after
    }
    function Start-Process {throw 'Fixed-timing native command must not run'}
    $cases=@(
        @{Types=@();Delays=@();ExpectedDelays=@(0,0,0)},
        @{Types=@(2);Delays=@(17000);ExpectedDelays=@(17000,17000,17000)},
        @{Types=@(3,1);Delays=@(35000,90000);ExpectedDelays=@(35000,90000,90000)},
        @{Types=@(2,3,1);Delays=@(0,120000,[uint32]::MaxValue);ExpectedDelays=@(0,120000,[uint32]::MaxValue)},
        @{Types=@(1,1,0);Delays=@(1234,98765,5432);ExpectedDelays=@(1234,98765,5432)},
        @{Types=@(1,1,0,0);Delays=@(5,6,7,8);ExpectedDelays=@(5,6,7,8)},
        @{Types=@(1,1,0,1);Delays=@(5,6,7,8);ExpectedDelays=@(5,6,7,8)},
        @{Types=@(0);Delays=@(777);ExpectedDelays=@(777,777,777)}
    )
    foreach ($reset in @([uint32]0,[uint32]86400,[uint32]123456,[uint32]::MaxValue)) {
        foreach ($case in $cases) {
            foreach ($restart in @($false,$true)) {
                $before=New-RecoveryFixture $reset $case.Types $case.Delays
                $plan=[KioskAudit.ServiceRecoverySettings]::WithRequiredActions($before,$restart)
                Assert-RecoveryTiming ($plan.ResetPeriod -eq $reset -and ($plan.DelaysMs -join '|') -ceq ($case.ExpectedDelays -join '|')) 'Existing reset or effective delays changed in the action plan'
                Assert-RecoveryTiming (($before.ActionTypes -join '|') -ceq ($case.Types -join '|') -and ($before.DelaysMs -join '|') -ceq ($case.Delays -join '|')) 'Planning modified the original snapshot'
                Assert-RecoveryTiming ([KioskAudit.ServiceRecoverySettings]::MatchesActions($plan,$restart) -and [KioskAudit.ServiceRecoverySettings]::TimingMatches($before,$plan)) 'Required action types or preserved timing not verified'
                $expectedTypes=if ($restart) {@(1,1)+@(0)*([Math]::Max(3,$case.Types.Count)-2)} else {@(0)*[Math]::Max(3,$case.Types.Count)}
                Assert-RecoveryTiming (($plan.ActionTypes -join '|') -ceq ($expectedTypes -join '|')) 'Wrong first/second/subsequent action plan'
                foreach ($mode in @($false,$true)) {
                    $script:ApplyChanges=$mode;$script:current=$before;$script:readDenied=$false;$script:writeDenied=$false;$script:writes=0
                    $initialMatch=[KioskAudit.ServiceRecoverySettings]::MatchesActions($before,$restart)
                    $observed=if ($restart) {Read-ServiceRecoveryPolicy -ServiceName Fixture} else {Read-ServiceNoActionRecoveryPolicy -ServiceName Fixture}
                    Assert-RecoveryTiming ($observed -eq $initialMatch) 'Audit policy check depends on timing values'
                    if ($mode) {
                        if ($restart) {Invoke-ServiceRecoveryRepair -ServiceName Fixture | Out-Null} else {Invoke-ServiceNoActionRecoveryRepair -ServiceName Fixture | Out-Null}
                        Assert-RecoveryTiming ($script:writes -eq [int](-not $initialMatch) -and [KioskAudit.ServiceRecoverySettings]::TimingMatches($before,$script:current)) 'Apply changed timing or rewrote compliant actions'
                        $count=$script:writes
                        if ($restart) {Invoke-ServiceRecoveryRepair -ServiceName Fixture | Out-Null} else {Invoke-ServiceNoActionRecoveryRepair -ServiceName Fixture | Out-Null}
                        Assert-RecoveryTiming ($script:writes -eq $count) 'Repeat repair was not a no-op'
                    } else {
                        $threw=$false;try {if ($restart) {Invoke-ServiceRecoveryRepair -ServiceName Fixture | Out-Null} else {Invoke-ServiceNoActionRecoveryRepair -ServiceName Fixture | Out-Null}} catch {$threw=$true}
                        Assert-RecoveryTiming ($threw -and $script:writes -eq 0) 'Audit allowed recovery changes'
                        $threw=$false;try {& $actualSetPolicy -ServiceName Fixture -RestartFirstTwo:$restart} catch {$threw=$true}
                        Assert-RecoveryTiming $threw 'Native action setter allowed Audit mutation'
                    }
                }
            }
        }
    }
    $before=New-RecoveryFixture 86400 @(1,1,0) @(1000,2000,3000)
    $changed=New-RecoveryFixture 1 @(1,1,0) @(1000,2000,3000)
    Assert-RecoveryTiming (-not [KioskAudit.ServiceRecoverySettings]::TimingMatches($before,$changed)) 'Changed reset period was not detected'
    $changed=New-RecoveryFixture 86400 @(1,1,0) @(1000,2222,3000)
    Assert-RecoveryTiming (-not [KioskAudit.ServiceRecoverySettings]::TimingMatches($before,$changed)) 'Changed delay was not detected'
    foreach ($failure in @('readDenied','writeDenied')) {
        $script:ApplyChanges=$true;$script:current=New-RecoveryFixture 123 @(2,2,2) @(17,18,19);$script:readDenied=$false;$script:writeDenied=$false;$script:writes=0
        Set-Variable -Scope Script -Name $failure -Value $true
        $threw=$false;try {Invoke-ServiceRecoveryRepair -ServiceName Fixture | Out-Null} catch {$threw=$true}
        Assert-RecoveryTiming ($threw -and $script:writes -eq 0 -and $script:current.ResetPeriod -eq 123) 'Failed preflight/write was accepted or changed timing'
    }
    Write-Output "PASS: $name action-only recovery checks/repairs, arbitrary existing delays/reset including INFINITE, repeated-action semantics, empty policies, Audit guards, no-op repeats and failure propagation"
}
