# Render recorded fixtures only. Do not execute an Audit or query real accounts.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
$project=Split-Path $PSScriptRoot -Parent
$output=Join-Path $project ('output/final-kiosk-user/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
function Assert-FinalUser {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Read-FinalUserHtml {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
foreach($client in @('SaaS','Subway')){
    $source=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $project $source),[ref]$tokens,[ref]$errors)
    Assert-FinalUser (-not $errors.Count) 'Engine parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-LocalUser {throw 'Renderer must not query Windows accounts'}
    function Get-CimInstance {throw 'Renderer must not query the computer'}
    function Set-LocalUser {throw 'Renderer must not change accounts'}
    function Read-Host {throw 'Renderer must not prompt for a user'}
    function New-FinalUserEntry {
        param([string]$Name,[string]$Password='Enabled',[string]$Status='Pass',[string]$Action='Password properties verified; no changes needed.')
        [pscustomobject]@{AccountName=$Name;Status=$Status;Action=$Action;StateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$Name;'Account Privilege'='Standard Local User';'Account Status'='Active';'Password Never Expires'='Enabled';'User Cannot Change Password'=$Password}))}
    }
    function New-FinalUserRow {
        param([object[]]$Entries,[string]$Title='KIOSK Account')
        [pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle=$Title;ItemSub='Verified configuration';Shortcut=(New-ReportCommand @('lusrmgr.msc'));FoundStateHtml=(($Entries|ForEach-Object {$_.StateHtml}) -join '<hr>');Status='Fail';ActionTaken='Multiple account observations';AccountResults=$Entries}
    }
    $first=New-FinalUserEntry 'SaaS Test'
    $second=New-FinalUserEntry 'SELISE-KIOSK' Disabled Fail 'Required password property remains disabled; readback verified.'
    $row=New-FinalUserRow @($first,$second)
    $before=$row|ConvertTo-Json -Depth 12 -Compress
    $identity=[pscustomobject]@{ReportId='OMK-711234';GeneratedAt='07 Nov 2026, 11:16 AM BST';AgentName='Fixture'}
    $audit=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -KioskUserName 'SaaS Test' -AuditSource $identity
    $fix=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -KioskUserName 'SaaS Test' -AuditSource $identity
    foreach($selected in @('SaaS Test','selise-kiosk')){
        foreach($afterApply in @($false,$true)){
            $final=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -KioskUserName $selected -AfterApply $afterApply -AuditSource $identity
            $html=Read-FinalUserHtml $final
            $view=Get-SettingRenderedComponent $html 'KIOSK Account'
            $names=@($view.Fields|Where-Object Setting -EQ 'Account Name')
            Assert-FinalUser ($names.Count -eq 1 -and $names[0].Value -ieq $selected -and $view.Headings.Count -eq 0) 'Final retained other kiosk users or account numbering'
            $other=if($selected -ieq 'SaaS Test'){'SELISE-KIOSK'}else{'SaaS Test'}
            Assert-FinalUser (-not $view.Html.Contains($other)) 'Unselected account leaked into Final settings/action details'
            $password=@($view.Fields|Where-Object Setting -EQ 'User Cannot Change Password')[0]
            Assert-FinalUser ($password.Value -eq $(if($selected -ieq 'SaaS Test'){'Enabled'}else{'Disabled'})) 'Sibling failure changed the selected user settings'
            [IO.File]::WriteAllText((Join-Path $output ($client+'-'+$selected.Replace(' ','-')+'-'+$afterApply+'.html')),$html,[Text.UTF8Encoding]::new($false))
        }
    }
    foreach($selected in @('','Unknown User','Not verified')){
        $final=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -KioskUserName $selected -AuditSource $identity
        $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'KIOSK Account'
        Assert-FinalUser ($view.Text.Contains('Kiosk user not verified') -and -not $view.Text.Contains('SaaS Test') -and -not $view.Text.Contains('SELISE-KIOSK')) 'Unverified selection guessed or exposed an account'
    }
    $duplicate=New-FinalUserRow @($first,$first,$second)
    $final=New-ThoroughReportSnapshot -Rows @($duplicate) -DisplayMode Final -KioskUserName 'SaaS Test'
    Assert-FinalUser ((Read-FinalUserHtml $final).Contains('Kiosk user not verified')) 'Ambiguous source account records were guessed'
    $uncertain=$row|Select-Object *
    $uncertain.AccountResults=@($first,$first,$second)
    $final=New-ThoroughReportSnapshot -Rows @($uncertain) -DisplayMode Final -KioskUserName 'SaaS Test' -AfterApply $true
    $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'KIOSK Account'
    Assert-FinalUser (@($view.Fields|Where-Object Setting -EQ 'User Cannot Change Password')[0].Value -eq 'Not verified') 'Duplicate result metadata fabricated a verified setting'
    $missingMetadata=$row|Select-Object *;$missingMetadata.AccountResults=@($null)
    $final=New-ThoroughReportSnapshot -Rows @($missingMetadata) -DisplayMode Final -KioskUserName 'SaaS Test' -AfterApply $true
    $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'KIOSK Account'
    Assert-FinalUser (@($view.Fields|Where-Object Setting -EQ 'User Cannot Change Password')[0].Value -eq 'Not verified' -and -not $view.Text.Contains('SELISE-KIOSK')) 'Missing metadata fabricated success or exposed another user'
    $failed=New-FinalUserRow @((New-FinalUserEntry 'SaaS Test' Enabled Fail 'Password update readback failed.'),$second)
    $final=New-ThoroughReportSnapshot -Rows @($failed) -DisplayMode Final -KioskUserName 'SaaS Test' -AfterApply $true
    $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'KIOSK Account'
    Assert-FinalUser (@($view.Fields|Where-Object Setting -EQ 'User Cannot Change Password')[0].Value -eq 'Not verified') 'Selected-user failed readback became a verified value'
    $escaped='Desk & <East>'
    $escapedRow=New-FinalUserRow @((New-FinalUserEntry $escaped),$second)
    $final=New-ThoroughReportSnapshot -Rows @($escapedRow) -DisplayMode Final -KioskUserName $escaped
    $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'KIOSK Account'
    Assert-FinalUser ($view.Text.Contains($escaped) -and $view.Html.Contains('&lt;East&gt;') -and -not $view.Html.Contains('SELISE-KIOSK')) 'Selected account escaping/identity failed'
    $adminEntries=@((New-FinalUserEntry Administrator),(New-FinalUserEntry Admin))
    foreach($entry in $adminEntries){$entry.StateHtml=$entry.StateHtml.Replace('Standard Local User','Local Administrator')}
    $admin=New-FinalUserRow $adminEntries 'Administrative Accounts'
    $final=New-ThoroughReportSnapshot -Rows @($admin) -DisplayMode Final -KioskUserName 'SaaS Test'
    $view=Get-SettingRenderedComponent (Read-FinalUserHtml $final) 'Administrative Accounts'
    Assert-FinalUser (@($view.Fields|Where-Object Setting -EQ 'Account Name').Count -eq 1 -and @($view.Fields|Where-Object Setting -EQ 'Account Name')[0].Value -eq 'Admin') 'Confirmed kiosk projection interfered with administrative priority'
    Assert-FinalUser (($row|ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'Final projection mutated Audit/Apply observations'
    $auditAfter=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -KioskUserName 'SaaS Test' -AuditSource $identity
    $fixAfter=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -KioskUserName 'SaaS Test' -AuditSource $identity
    Assert-FinalUser ($auditAfter.HtmlBase64 -ceq $audit.HtmlBase64 -and $fixAfter.HtmlBase64 -ceq $fix.HtmlBase64) 'Final filtering changed Audit/Fix output'
    $bundlePath=Join-Path $output ($client+'-bundle.html')
    [void](Save-ThoroughReportBundle -Path $bundlePath -ClientType $client -ComputerName 'FIXTURE' -Snapshots @($audit) -PreferredMode Audit)
    $final=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -KioskUserName 'SaaS Test' -AuditSource $identity
    [void](Save-ThoroughReportBundle -Path $bundlePath -ClientType $client -ComputerName 'FIXTURE' -Snapshots @($fix,$final) -PreferredMode Final)
    $saved=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($bundlePath))
    Assert-FinalUser ($saved.Reports.Audit.HtmlBase64 -ceq $audit.HtmlBase64 -and $saved.Reports.Final.HtmlBase64 -ceq $final.HtmlBase64) 'Saved bundle replaced Audit or lost selected-user Final'
    $calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-ThoroughReportSnapshot'},$true))
    $elements=$calls[0].CommandElements
    $argument=$null
    for($i=0;$i -lt $elements.Count-1;$i++){if($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'KioskUserName'){$argument=$elements[$i+1].Extent.Text}}
    Assert-FinalUser ($argument -and $argument.Contains('$kioskAccount')) 'Production snapshot uses an unconfirmed default username'
    $expression=[scriptblock]::Create('param($kioskAccount,$kioskUser) '+$argument)
    Assert-FinalUser ([string](& $expression $null 'SELISE-KIOSK') -eq '' -and [string](& $expression ([pscustomobject]@{Name='SaaS Test'}) 'SELISE-KIOSK') -ceq 'SaaS Test') 'Production report identity guessed the fallback user'
    Write-Output ('PASS: '+$client+' Final contains only the confirmed kiosk user; ambiguous/missing selection, escaped names, independent readback, admin retention, unchanged Audit/Fix and saved history verified.')
}
