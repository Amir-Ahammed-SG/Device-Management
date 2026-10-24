# Definitions and in-memory fixtures only. Never contact a Windows account API.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
function Assert-AccountClassification {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-AccountClassification ($errors.Count -eq 0) 'Client source parse failed.'
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    function Get-LocalUser {[CmdletBinding()]param() $script:fixtureUsers}
    function Get-KioskAutoLoginUserName {return $null}
    function Get-KioskProfilePath {param($UserName) if($UserName -ceq $script:dualRoleName){return 'C:\FixtureProfile'}}
    function Test-Path {param($LiteralPath,$PathType) return $LiteralPath -ceq 'C:\FixtureProfile\Scripts\LaunchKiosk.ps1'}
    function Get-LocalAdministratorSidSet {
        $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($name in @('Admin','Administrator','SupportAdmin','CustomKioskAdmin')){[void]$set.Add($name)}
        return ,$set
    }
    function Get-LocalAccountProperties {param($UserName) if($UserName -ceq $script:unreadableAccount){throw 'Fixture account properties unreadable.'}; return $script:fixtureFlags[$UserName]}
    function Set-LocalUser {
        [CmdletBinding()]param($Name,[bool]$PasswordNeverExpires,[bool]$UserMayChangePassword)
        $script:fixtureWrites.Add($Name)
        if($PSBoundParameters.ContainsKey('PasswordNeverExpires')){$script:fixtureFlags[$Name].PasswordNeverExpires=$PasswordNeverExpires}
        if($PSBoundParameters.ContainsKey('UserMayChangePassword')){$script:fixtureFlags[$Name].UserCannotChangePassword=-not $UserMayChangePassword}
    }
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

    function New-LocalUser {throw 'Unexpected account creation.'}
    function Enable-LocalUser {throw 'Unexpected account enabling.'}
    function Disable-LocalUser {throw 'Unexpected account disabling.'}
    function Add-LocalGroupMember {throw 'Unexpected privilege change.'}
    function Remove-LocalGroupMember {throw 'Unexpected privilege change.'}
    foreach($apply in @($false,$true)){
        $script:ApplyChanges=$apply
        foreach($dualRole in @('Administrator','CustomKioskAdmin')){
            $script:dualRoleName=$dualRole
            $script:unreadableAccount=$null
            $script:fixtureUsers=@(foreach($name in @('SupportAdmin','SELISE-KIOSK','StandardUser','CustomKioskAdmin','Administrator','Admin')){
                [pscustomobject]@{Name=$name;Enabled=$true;SID=[pscustomobject]@{Value=$name}}
            })
            $script:fixtureFlags=@{}
            foreach($user in $script:fixtureUsers){$script:fixtureFlags[$user.Name]=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}}
            $script:fixtureWrites=[Collections.Generic.List[string]]::new()
            $before=$script:fixtureUsers | ConvertTo-Json -Depth 4 -Compress
            $adminDiscovery=Get-AdministrativeLocalAccounts
            $names=@($adminDiscovery.Accounts | ForEach-Object {$_.Name})
            Assert-AccountClassification (($names -join '|') -ceq 'Admin|Administrator|CustomKioskAdmin|SupportAdmin') 'Named administrators were not prioritized or an active administrator was omitted.'
            $kiosk=Get-KioskAccountCheck
            Assert-AccountClassification ($kiosk.Account.Name -ceq $dualRole -and $kiosk.Result.DetectedAccountNames -contains $dualRole) 'An administrator with a launcher was omitted from kiosk classification.'
            $admin=Get-AdministrativeAccountCheck
            Assert-AccountClassification ($admin.DetectedAccountNames -contains $dualRole) 'Kiosk classification removed the administrative role.'
            Assert-AccountClassification ($admin.DetectedAccountNames -notcontains 'StandardUser') 'An unrelated standard account was classified as an administrator.'
            Assert-AccountClassification ($kiosk.Result.DetectedAccountNames -notcontains 'SupportAdmin') 'Administrator privilege alone incorrectly implied kiosk setup.'
            Assert-AccountClassification (($script:fixtureUsers | ConvertTo-Json -Depth 4 -Compress) -ceq $before) 'Classification changed account activation, names or identities.'
            if($apply){
                Assert-AccountClassification ($admin.Status -ceq 'Pass' -and $kiosk.Result.Status -ceq 'Pass') 'Required property readback failed.'
                Assert-AccountClassification ($script:fixtureWrites.Count -eq 5 -and @($script:fixtureWrites | Where-Object {$_ -ceq $dualRole}).Count -eq 1) 'A dual-role account was repaired twice or an unrelated user was changed.'
                [void](Get-KioskAccountCheck);[void](Get-AdministrativeAccountCheck)
                Assert-AccountClassification ($script:fixtureWrites.Count -eq 5) 'Repeated checks rewrote compliant properties.'
            }else{Assert-AccountClassification ($script:fixtureWrites.Count -eq 0) 'Audit changed account properties.'}
        }
        $script:dualRoleName=$null
        foreach($pair in @(@($true,$false),@($false,$true),@($true,$true),@($false,$false))){
            foreach($otherActive in @($false,$true)){
                $script:fixtureUsers=@(
                    [pscustomobject]@{Name='Administrator';Enabled=$pair[1];SID=[pscustomobject]@{Value='Administrator'}}
                    [pscustomobject]@{Name='SupportAdmin';Enabled=$otherActive;SID=[pscustomobject]@{Value='SupportAdmin'}}
                    [pscustomobject]@{Name='Admin';Enabled=$pair[0];SID=[pscustomobject]@{Value='Admin'}}
                    [pscustomobject]@{Name='CustomKioskAdmin';Enabled=$false;SID=[pscustomobject]@{Value='CustomKioskAdmin'}}
                    [pscustomobject]@{Name='StandardUser';Enabled=$true;SID=[pscustomobject]@{Value='StandardUser'}}
                )
                $script:fixtureFlags=@{};$script:fixtureWrites=[Collections.Generic.List[string]]::new();$script:unreadableAccount=$null
                foreach($user in $script:fixtureUsers){$script:fixtureFlags[$user.Name]=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}}
                $expected=@(if($pair[0]){'Admin'};if($pair[1]){'Administrator'};if($otherActive){'SupportAdmin'})
                $hasActive=$expected.Count -gt 0
                if(-not $hasActive){$expected=@('Admin','Administrator')}
                $discovered=Get-AdministrativeLocalAccounts
                $names=@($discovered.Accounts | ForEach-Object {$_.Name})
                Assert-AccountClassification (($names -join '|') -ceq ($expected -join '|')) 'Administrative active preference, primary names or disabled fallback is incorrect.'
                $result=Get-AdministrativeAccountCheck
                Assert-AccountClassification (($result.DetectedAccountNames -join '|') -ceq ($expected -join '|')) 'Reported administrative names differ from selected accounts.'
                $expectedWrites=@(if($apply -and $hasActive){$expected})
                Assert-AccountClassification (($script:fixtureWrites -join '|') -ceq ($expectedWrites -join '|')) 'Apply changed an omitted or disabled administrator.'
                foreach($user in @($script:fixtureUsers | Where-Object {-not $_.Enabled})){
                    Assert-AccountClassification (-not $script:fixtureFlags[$user.Name].PasswordNeverExpires -and -not $script:fixtureFlags[$user.Name].UserCannotChangePassword) 'A disabled administrator property changed.'
                }
                $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='Administrative Accounts';FoundStateHtml=$result.StateHtml})
                $expectedStatus=if($hasActive){'Active'}else{'Disabled'}
                Assert-AccountClassification ($view.FindingsHtml.Contains(('Account Status:</span> '+$expectedStatus))) 'Selected administrator activation status is incorrect.'
                Assert-AccountClassification (($result.Status -ceq 'Pass') -eq ($apply -and $hasActive)) 'Administrator compliance does not reflect actual required properties.'
            }
            $script:fixtureUsers=@(
                [pscustomobject]@{Name='SELISE';Enabled=$pair[0];SID=[pscustomobject]@{Value='SELISE'}}
                [pscustomobject]@{Name='SELISE-KIOSK';Enabled=$pair[1];SID=[pscustomobject]@{Value='SELISE-KIOSK'}}
                [pscustomobject]@{Name='StandardUser';Enabled=$true;SID=[pscustomobject]@{Value='StandardUser'}}
            )
            $script:fixtureFlags=@{};$script:fixtureWrites=[Collections.Generic.List[string]]::new();$script:unreadableAccount=$null
            foreach($user in $script:fixtureUsers){$script:fixtureFlags[$user.Name]=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}}
            $expected=@(if($pair[0]){'SELISE'};if($pair[1]){'SELISE-KIOSK'})
            $hasActive=$expected.Count -gt 0
            if(-not $hasActive){$expected=@('SELISE','SELISE-KIOSK')}
            $result=Get-KioskAccountCheck
            Assert-AccountClassification (($result.Result.DetectedAccountNames -join '|') -ceq ($expected -join '|')) 'Kiosk active preference or disabled fallback is incorrect.'
            Assert-AccountClassification (($result.Account.Enabled -eq $hasActive)) 'A disabled kiosk account was selected despite an active alternative.'
            $expectedWrites=@(if($apply -and $hasActive){$expected})
            Assert-AccountClassification (($script:fixtureWrites -join '|') -ceq ($expectedWrites -join '|')) 'Apply changed an omitted or disabled kiosk account.'
            $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$result.Result.StateHtml})
            $expectedStatus=if($hasActive){'Active'}else{'Disabled'}
            Assert-AccountClassification ($view.FindingsHtml.Contains(('Account Status:</span> '+$expectedStatus))) 'Selected kiosk activation status is incorrect.'
        }
        foreach($enabled in @($false,$true)){
            $script:unreadableAccount='Administrator'
            $script:fixtureUsers=@([pscustomobject]@{Name='Administrator';Enabled=$enabled;SID=[pscustomobject]@{Value='Administrator'}})
            $script:fixtureWrites.Clear()
            $failed=Get-AdministrativeAccountCheck
            $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='Administrative Accounts';FoundStateHtml=$failed.StateHtml})
            $expectedStatus=if($enabled){'Active'}else{'Disabled'}
            Assert-AccountClassification ($failed.Status -ceq 'Fail' -and $view.FindingsHtml.Contains('Account Name:</span> Administrator') -and $view.FindingsHtml.Contains(('Account Status:</span> '+$expectedStatus)) -and $view.FindingsHtml.Contains('Password Never Expires:</span> Not verified')) 'A failed property read lost known identity/status or claimed verified properties.'
            Assert-AccountClassification ($script:fixtureWrites.Count -eq 0) 'An unreadable account caused a repair.'
        }
    }
    Write-Output ('PASS: '+$sourceName+' named-admin priority, active/disabled pair matrix, disabled fallback without repairs, kiosk/admin dual roles, failed-read details, Audit safety and idempotent repairs')
}
