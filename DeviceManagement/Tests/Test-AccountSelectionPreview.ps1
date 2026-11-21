
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
# Render actual account-selection results with fixture APIs only.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$previewRoot=Join-Path $projectRoot ('output\account-previews\run-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $previewRoot 'fixture-profile'
$script:fixtureProfilePath=$profile
[void][IO.Directory]::CreateDirectory((Join-Path $profile 'Scripts'))
[IO.File]::WriteAllText((Join-Path $profile 'Scripts\LaunchKiosk.ps1'),'# Fixture: never execute.')
function Assert-AccountPreview {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($sourceName in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $sourceName
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-AccountPreview ($errors.Count -eq 0) 'Client parse failed.'
    . ([scriptblock]::Create(($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    Use-SettingLayoutRuleAssertions -SourceName $sourceName
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $finalizer=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    function Get-LocalUser {[CmdletBinding()]param() $script:fixtureUsers}
    function Get-KioskAutoLoginUserName {return $script:autoUser}
    function Get-KioskProfilePath {param($UserName) if($UserName -ceq $script:profileUser){return $script:fixtureProfilePath}}
    function Get-LocalAdministratorSidSet {
        $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($name in @('Admin','Administrator','SupportAdmin')){[void]$set.Add($name)}
        return ,$set
    }
    function Get-LocalAccountProperties {param($UserName) return $script:fixtureFlags[$UserName]}
    function Set-LocalUser {
        [CmdletBinding()]param($Name,[bool]$PasswordNeverExpires,[bool]$UserMayChangePassword)
        $user=$script:fixtureUsers | Where-Object Name -ceq $Name
        Assert-AccountPreview ([bool]$user.Enabled) 'A disabled account was changed.'
        if($PSBoundParameters.ContainsKey('PasswordNeverExpires')){$script:fixtureFlags[$Name].PasswordNeverExpires=$PasswordNeverExpires}
        if($PSBoundParameters.ContainsKey('UserMayChangePassword')){$script:fixtureFlags[$Name].UserCannotChangePassword=-not $UserMayChangePassword}
    }
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

    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($apply in @($false,$true)){
        $script:ApplyChanges=$apply
        $mode=if($apply){'Apply'}else{'Audit'}
        foreach($case in @('active-preferred','disabled-only','dual-role')){
            $names=if($case -eq 'dual-role'){@('Admin','StandardUser')}else{@('Admin','Administrator','SELISE','SELISE-KIOSK','SupportAdmin')}
            $script:fixtureUsers=@(foreach($name in $names){
                $enabled=if($case -eq 'dual-role'){$true}else{$case -eq 'active-preferred' -and $name -in @('Administrator','SELISE-KIOSK','SupportAdmin')}
                [pscustomobject]@{Name=$name;Enabled=$enabled;SID=[pscustomobject]@{Value=$name}}
            })
            $script:profileUser=if($case -eq 'dual-role'){'Admin'}elseif($case -eq 'active-preferred'){'SupportAdmin'}else{$null}
            $script:autoUser=if($case -eq 'dual-role'){'Admin'}elseif($case -eq 'active-preferred'){'SELISE-KIOSK'}else{$null}
            $script:fixtureFlags=@{}
            foreach($user in $script:fixtureUsers){$script:fixtureFlags[$user.Name]=[pscustomobject]@{PasswordNeverExpires=$false;UserCannotChangePassword=$false}}
            $kiosk=Get-KioskAccountCheck
            $admin=Get-AdministrativeAccountCheck
            $expectedKiosk=if($case -eq 'dual-role'){@('Admin')}elseif($case -eq 'active-preferred'){@('SELISE-KIOSK','SupportAdmin')}else{@('SELISE','SELISE-KIOSK')}
            $expectedAdmin=if($case -eq 'dual-role'){@('Admin')}elseif($case -eq 'active-preferred'){@('Administrator','SupportAdmin')}else{@('Admin','Administrator')}
            Assert-AccountPreview (($kiosk.Result.DetectedAccountNames -join '|') -ceq ($expectedKiosk -join '|')) ('Kiosk selection mismatch: '+$case+'; actual '+($kiosk.Result.DetectedAccountNames -join '|'))
            Assert-AccountPreview (($admin.DetectedAccountNames -join '|') -ceq ($expectedAdmin -join '|')) 'Administrative selection mismatch.'
            $auditRows=[Collections.Generic.List[psobject]]::new()
            $auditRows.Add([pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='KIOSK Account';ItemSub='Verified configuration';Shortcut=$kiosk.Result.Shortcut;FoundStateHtml=$kiosk.Result.StateHtml;Status=$kiosk.Result.Status;ActionTaken=$kiosk.Result.Action})
            $auditRows.Add([pscustomobject]@{SectionNumber=5;SectionTitle='Security, Network & System Integrity';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Shortcut=$admin.Shortcut;FoundStateHtml=$admin.StateHtml;Status=$admin.Status;ActionTaken=$admin.Action})
            $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-'+$case+'.html')
            $runId='ACCOUNT-SELECTION-PREVIEW';$clientLocation='Sample branch';$deviceType='KIOSK';$reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
            . $render
            $html=[KioskTestSource]::ReadAllText($reportPath)
            if($mode -eq 'Audit'){
                $kioskAudit=Get-AuditRenderedComponent $html 'KIOSK Account'
                $adminAudit=Get-AuditRenderedComponent $html 'Administrative Accounts'
                $actualKiosk=@($kioskAudit.Fields|Where-Object Setting -EQ 'Account Name'|ForEach-Object {$_.Found})
                $actualAdmin=@($adminAudit.Fields|Where-Object Setting -EQ 'Account Name'|ForEach-Object {$_.Found})
                Assert-AccountPreview (($actualKiosk -join '|') -ceq ($expectedKiosk -join '|') -and ($actualAdmin -join '|') -ceq ($expectedAdmin -join '|')) 'Audit lost the selected account identities.'
                if($case -eq 'disabled-only'){Assert-AccountPreview (@(@($kioskAudit.Fields)+@($adminAudit.Fields)|Where-Object {$_.Setting -eq 'Account Status' -and $_.Found -eq 'Disabled'}).Count -eq 4) 'Audit lost disabled-account status.'}
            }
            Assert-AccountPreview ($html -notmatch 'Account:</span> Present|or local administrator') 'Removed account labels remain.'
            if($case -eq 'active-preferred'){
                Assert-AccountPreview ($html -notmatch 'Account Status:</span> Disabled|Account Name:</span> Admin</div>|Account Name:</span> SELISE</div>') 'An inactive alternative remains in the report.'
            }
            if($case -eq 'disabled-only' -and $mode -ne 'Audit'){
                $accountNames=[regex]::Matches($html,'<span class="kv-label">Account Name:</span> (?:SELISE|SELISE-KIOSK|Admin|Administrator)</div>')
                Assert-AccountPreview ($accountNames.Count -eq 4) 'Disabled-only account identities were lost.'
                if($mode -eq 'Audit'){Assert-AccountPreview ([regex]::Matches($html,'Account Status:</span> Disabled').Count -eq 4) 'Audit lost disabled-account status.'}
            }
            foreach($user in @($script:fixtureUsers | Where-Object {-not $_.Enabled})){
                Assert-AccountPreview (-not $script:fixtureFlags[$user.Name].PasswordNeverExpires -and -not $script:fixtureFlags[$user.Name].UserCannotChangePassword) 'A disabled account property changed.'
            }
        }
        Write-Output ('PASS: '+$client+'/'+$mode+' actual selection report previews: active alternatives, disabled-only fallback, dual administrator/kiosk role and disabled properties preserved')
    }
}
