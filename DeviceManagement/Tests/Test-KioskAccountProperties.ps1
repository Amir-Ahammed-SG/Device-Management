$projectRoot = Split-Path $PSScriptRoot -Parent
# Load definitions only. All account operations use in-memory fixtures.
$ErrorActionPreference='Stop'
$root=Split-Path $projectRoot -Parent
function Assert-KioskProperty {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $sourceName),[ref]$tokens,[ref]$errors)
    Assert-KioskProperty ($errors.Count -eq 0) 'Source parser errors'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    function Get-LocalUser {[CmdletBinding()]param() $script:users}
    function Get-KioskProfilePath {param($UserName) return $null}
    function Get-KioskAutoLoginUserName {return $script:autoUser}
    function Get-LocalAdministratorSidSet {
        $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($script:isAdmin) {[void]$set.Add('FixtureSid')}
        return ,$set
    }
    function Get-LocalAccountProperties {
        param($UserName)
        $script:reads++
        if ($script:readDenied -or ($script:readbackDenied -and $script:reads -gt 1)) {throw 'Fixture property read denied'}
        $script:flags
    }
    function Set-LocalUser {
        [CmdletBinding()]param($Name,[bool]$PasswordNeverExpires,[bool]$UserMayChangePassword)
        Assert-KioskProperty ($Name -ceq $script:users[0].Name) 'Another account was modified'
        $keys=@($PSBoundParameters.Keys | Where-Object {$_ -notin @('Name','ErrorAction')} | Sort-Object)
        Assert-KioskProperty (($keys -join '|') -ceq ($script:expectedKeys -join '|')) 'A property that was already enabled or another property was supplied'
        $script:writes++
        if ($script:writeDenied) {throw 'Fixture account write denied'}
        if (-not $script:noEffect) {
            if ($PSBoundParameters.ContainsKey('PasswordNeverExpires')) {$script:flags.PasswordNeverExpires=$PasswordNeverExpires}
            if ($PSBoundParameters.ContainsKey('UserMayChangePassword')) {$script:flags.UserCannotChangePassword=-not $UserMayChangePassword}
        }
    }
    # Route the new narrow writer through this fixture's existing mock; never bind ADSI.
    function Open-ThoroughLocalAccount {throw 'Live Windows account access is forbidden in this fixture.'}
    function Enable-LocalAccountPasswordFlags {
        param([string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword,[switch]$AllowPasswordChange)
        $settings=@{Name=$UserName}
        if($PasswordNeverExpires){$settings.PasswordNeverExpires=$true}
        if($UserCannotChangePassword){$settings.UserMayChangePassword=$false}
        if($AllowPasswordChange -and $script:flags.UserCannotChangePassword){$settings.UserMayChangePassword=$true}
        Set-LocalUser @settings
        [pscustomobject]@{Changed=$true}
    }

    function New-LocalUser {throw 'Account creation is forbidden'}
    function Enable-LocalUser {throw 'Account enabling is forbidden'}
    function Disable-LocalUser {throw 'Account disabling is forbidden'}
    function Add-LocalGroupMember {throw 'Privilege changes are forbidden'}
    function Remove-LocalGroupMember {throw 'Privilege changes are forbidden'}
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($name in @('sElIsE','SELISE-KIOSK','Custom Kiosk')) {
            foreach ($admin in @($false,$true)) {
                foreach ($initialFlags in @(@($false,$false),@($true,$false),@($false,$true),@($true,$true))) {
                    $script:users=@([pscustomobject]@{Name=$name;Enabled=$true;SID=[pscustomobject]@{Value='FixtureSid'}})
                    $script:autoUser=if ($name -like 'Custom*') {$name} else {$null}
                    $script:isAdmin=$admin
                    $script:flags=[pscustomobject]@{PasswordNeverExpires=$initialFlags[0];UserCannotChangePassword=$initialFlags[1]}
                    $needsPermissionChange=if($admin){$initialFlags[1]}else{-not $initialFlags[1]}
                    $script:expectedKeys=@($(if (-not $initialFlags[0]) {'PasswordNeverExpires'});$(if ($needsPermissionChange) {'UserMayChangePassword'})) | Where-Object {$_} | Sort-Object
                    $script:writes=0;$script:reads=0;$script:readDenied=$false;$script:readbackDenied=$false;$script:writeDenied=$false;$script:noEffect=$false
                    $check=Get-KioskAccountCheck
                    $compliant=$mode -or ($initialFlags[0] -and ($initialFlags[1] -eq (-not $admin)))
                    Assert-KioskProperty (($check.Result.Status -eq 'Pass') -eq $compliant) 'Kiosk status does not reflect required flags independently of privilege'
                    $expectedWrites=if ($mode -and $script:expectedKeys.Count) {1} else {0}
                    Assert-KioskProperty ($script:writes -eq $expectedWrites -and $script:users[0].Enabled -and $script:users[0].SID.Value -ceq 'FixtureSid') 'Write count or preserved account state incorrect'
                    $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$check.Result.StateHtml})
                    $expectedPrivilege=if ($admin) {'Administrator'} else {'Standard'}
                    Assert-KioskProperty ($view.ExpectedHtml -match 'Account Privilege:</span> Standard or Administrator' -and $view.FindingsHtml.Contains('Account Privilege:</span> '+$expectedPrivilege)) 'Privilege reference or actual finding incorrect'
                    Assert-KioskProperty ($view.ExpectedHtml.Contains('Account Name:</span> '+$name) -and $view.FindingsHtml.Contains('Account Name:</span> '+$name)) 'Account name lost from Required Configuration or Findings'
                    Assert-KioskProperty ($view.ExpectedHtml.Contains('Account Status:</span> Active / Disabled') -and $view.FindingsHtml.Contains('Account Status:</span> Active')) 'Actual account activation status was lost'
                    $pairs=@(,@('Password Never Expires',$script:flags.PasswordNeverExpires))
                    if(-not $admin){$pairs+=,@('User Cannot Change Password',$script:flags.UserCannotChangePassword)}
                    else {Assert-KioskProperty (-not ($view.ExpectedHtml+$view.FindingsHtml).Contains('User Cannot Change Password')) 'Administrative kiosk role still requires the removed flag'}
                    foreach ($pair in $pairs) {
                        $actual=if ($pair[1]) {'Enabled'} else {'Disabled'}
                        Assert-KioskProperty ($view.ExpectedHtml.Contains($pair[0]+':</span> Enabled') -and $view.FindingsHtml.Contains($pair[0]+':</span> '+$actual)) 'Required or actual property missing from report'
                    }
                    $again=Get-KioskAccountCheck
                    Assert-KioskProperty ($script:writes -eq $expectedWrites) 'Repeat check rewrote compliant flags'
                }
            }
        }
        $script:users=@();$script:autoUser=$null;$script:writes=0;$script:reads=0
        $missing=Get-KioskAccountCheck
        $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$missing.Result.StateHtml})
        Assert-KioskProperty ($missing.Result.Status -eq 'Fail' -and $null -eq $missing.Account -and $script:reads -eq 0 -and $script:writes -eq 0 -and $view.FindingsHtml -ceq 'Account Missing. Please create manually.') 'Missing account caused changes or did not request manual creation'
        Assert-KioskProperty ($view.ExpectedHtml -match 'SELISE or SELISE-KIOSK' -and $view.ExpectedHtml -match 'Password Never Expires:</span> Enabled' -and $view.ExpectedHtml -match 'User Cannot Change Password:</span> Enabled') 'Missing-account requirements incorrect'
    }
    $script:ApplyChanges=$true
    foreach ($failure in @('readDenied','writeDenied','noEffect','readbackDenied')) {
        $script:users=@([pscustomobject]@{Name='SELISE-KIOSK';Enabled=$true;SID=[pscustomobject]@{Value='FixtureSid'}})
        $script:autoUser=$null;$script:isAdmin=$false;$script:writes=0;$script:reads=0
        $script:flags=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}
        $script:expectedKeys=@('PasswordNeverExpires','UserMayChangePassword')
        $script:readDenied=$false;$script:writeDenied=$false;$script:noEffect=$false;$script:readbackDenied=$false
        Set-Variable -Scope Script -Name $failure -Value $true
        $check=Get-KioskAccountCheck
        Assert-KioskProperty ($check.Result.Status -eq 'Fail' -and $check.Account.Name -ceq 'SELISE-KIOSK' -and $check.Result.Shortcut -match 'SELISE-KIOSK' -and $script:users[0].Enabled) "Failed property operation claimed Pass or lost detected account: $failure"
        if ($failure -eq 'readDenied') {Assert-KioskProperty ($script:writes -eq 0) 'Unreadable properties caused a write'}
    }
    Write-Output "PASS: $sourceName kiosk Audit/Apply property matrix, only-disabled settings, aliases/custom accounts, privilege observation, preserved disabled state, missing accounts, readback failures and repeat safety"
}
