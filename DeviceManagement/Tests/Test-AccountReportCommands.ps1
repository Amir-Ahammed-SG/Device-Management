
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# Exercise only definitions using in-memory accounts. No Windows account API runs.
$ErrorActionPreference='Stop'
$parent=$projectRoot
function Assert-AccountCommand { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Get-CommandText { param([string]$Html) @([regex]::Matches($Html,'(?is)<code\b[^>]*>(.*?)</code>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }) }
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $parent $sourceName),[ref]$tokens,[ref]$errors)
    Assert-AccountCommand ($errors.Count -eq 0) 'Source parsing failed'
    $definitions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    function Write-Host { [CmdletBinding()]param($Object,$ForegroundColor) }
    function Get-LocalUser { [CmdletBinding()]param() $script:fixtureUsers }
    function Get-KioskAutoLoginUserName {return $null}
    function Get-KioskProfilePath {param($UserName) return $null}
    function Get-LocalAccountProperties {
        param($UserName)
        if ($UserName -eq $script:unreadableUser) { throw 'Fixture: property access denied' }
        [pscustomobject]@{PasswordNeverExpires=$true;UserCannotChangePassword=$true}
    }
    function Get-LocalAdministratorSidSet {
        $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($user in $script:fixtureAdmins) { [void]$set.Add($user.SID.Value) }
        return ,$set
    }
    function Get-AdministrativeLocalAccounts { [pscustomobject]@{Accounts=@($script:fixtureAdmins);AdministratorSids=(Get-LocalAdministratorSidSet)} }
    function Set-LocalUser { throw 'Unexpected account mutation in command test' }
    # Route the new narrow writer through this fixture's existing mock; never bind ADSI.
    function Open-ThoroughLocalAccount {throw 'Live Windows account access is forbidden in this fixture.'}
    function Enable-LocalAccountPasswordFlags {
        param([string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword,[switch]$AllowPasswordChange)
        $settings=@{Name=$UserName}
        if($PasswordNeverExpires){$settings.PasswordNeverExpires=$true}
        if($UserCannotChangePassword){$settings.UserMayChangePassword=$false}
        if($AllowPasswordChange){$settings.UserMayChangePassword=$true}
        Set-LocalUser @settings
        [pscustomobject]@{Changed=$true}
    }

    foreach ($applyMode in @($false,$true)) {
        $script:ApplyChanges=$applyMode
        foreach ($names in @(@(),@('SELISE'),@('SeLiSe-KiOsK'),@('SELISE','SeLiSe-KiOsK'))) {
            $script:fixtureUsers=@(foreach ($name in $names) { [pscustomobject]@{Name=$name;Enabled=$true;SID=[pscustomobject]@{Value=$name}} })
            $script:fixtureAdmins=@(); $script:unreadableUser=$null
            $check=Get-KioskAccountCheck
            $auditRows=[Collections.Generic.List[psobject]]::new()
            Add-ResultEntry 2 Kiosk 'KIOSK Account' $check.Result
            $actual=@(Get-CommandText $auditRows[0].Shortcut)
            $expected=@('lusrmgr.msc')+@(foreach ($name in $names) { 'net user "{0}"' -f $name })
            Assert-AccountCommand (($actual -join '|') -ceq ($expected -join '|')) 'Kiosk commands do not match detected names'
            Assert-AccountCommand ($auditRows[0].Shortcut -notmatch 'SELISE or SELISE-KIOSK') 'Expected aliases leaked into a command'
            $boxes=ConvertTo-ReportCommandBoxes $auditRows[0].Shortcut
            $copyValues=@([regex]::Matches($boxes,'data-command="([^"]*)"') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
            Assert-AccountCommand (($copyValues -join '|') -ceq ($expected -join '|')) 'Copied account text differs from actual names'
        }
        $script:unreadableUser='SeLiSe-KiOsK'
        $failed=Get-KioskAccountCheck
        Assert-AccountCommand ($failed.Result.Shortcut -match 'SeLiSe-KiOsK') 'Existing account omitted after property inspection failed'
        $script:unreadableUser=$null
        $script:fixtureAdmins=@(foreach ($name in @('Administrator','Support & Desk')) { [pscustomobject]@{Name=$name;Enabled=$false;SID=[pscustomobject]@{Value=$name}} })
        $auditRows=[Collections.Generic.List[psobject]]::new()
        Add-ResultEntry 5 Security 'Administrative Accounts' (Get-AdministrativeAccountCheck)
        $actual=@(Get-CommandText $auditRows[0].Shortcut)
        Assert-AccountCommand (($actual -join '|') -ceq 'lusrmgr.msc|net user "Administrator"|net user "Support & Desk"') 'Administrative commands lost actual names or quoting'
        $script:fixtureAdmins=@()
        $auditRows=[Collections.Generic.List[psobject]]::new()
        Add-ResultEntry 5 Security 'Administrative Accounts' (Get-AdministrativeAccountCheck)
        Assert-AccountCommand (($auditRows[0].Shortcut) -ceq '<code>lusrmgr.msc</code>') 'Missing administrator generated a specific-user command'
    }
    $unique=@(Get-CommandText (New-AccountReportCommand -AccountNames @('SELISE','selise','')))
    Assert-AccountCommand (($unique -join '|') -ceq 'lusrmgr.msc|net user "SELISE"') 'Commands were not deduplicated case-insensitively'
    Microsoft.PowerShell.Utility\Write-Host "PASS: $sourceName Audit/Apply commands for missing, detected, grouped and unreadable accounts; exact copy text and no mutations"
}
