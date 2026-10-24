$projectRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
$parent=Split-Path $projectRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output\kiosk-verification\run-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
function Assert-Kiosk {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
function New-LauncherCase {
    param([string]$Url,[Text.Encoding]$Encoding=([Text.UTF8Encoding]::new($false)))
    $folder=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $path=Join-Path $folder 'LaunchKiosk.ps1'
    $text='# Preserve customer settings '+[char]0x00E9+"`r`n"+'$other = ''untouched'''+"`r`n"+'Start-Process msedge.exe -ArgumentList ''--kiosk "'+$Url+'" --edge-kiosk-type=fullscreen'''
    [IO.File]::WriteAllText($path,$text,$Encoding)
    [pscustomobject]@{Path=$path;Text=$text;Folder=$folder;Bytes=[IO.File]::ReadAllBytes($path)}
}
foreach ($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $parent $name),[ref]$tokens,[ref]$errors)
    Assert-Kiosk ($errors.Count -eq 0) 'Source parser errors'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $actualAutoLoginName=${function:Get-KioskAutoLoginUserName}
    $origin=if ($name -like 'Subway*') {'https://kiosk.subway.ch'} else {'https://kiosk.ordermonkey.com'}
    function Set-LocalUser {throw 'Compliant kiosk account must not be changed'}
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

    function New-LocalUser {throw 'Kiosk account must not be created'}
    function Get-LocalAccountProperties {[pscustomobject]@{PasswordNeverExpires=$true;UserCannotChangePassword=$true}}
    function Enable-LocalUser {throw 'Kiosk account must not be enabled'}
    function Add-LocalGroupMember {throw 'Kiosk privileges must not change'}
    function Copy-Item {throw 'Backup or replacement files must not be created'}
    function Get-LocalUser {[CmdletBinding()]param($Name) if ($Name) {$script:users | Where-Object {$_.Name -ieq $Name}} else {$script:users}}
    function Get-KioskAutoLoginUserName {$script:autoUser}
    function Get-KioskProfilePath {param($UserName) $script:profiles[$UserName]}
    function Get-LocalAdministratorSidSet {return ,[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)}
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($userName in @('sElIsE','SeLiSe-KiOsK','Custom Kiosk User')) {
            $script:users=@([pscustomobject]@{Name=$userName;Enabled=$true;SID=[pscustomobject]@{Value='Fixture'}})
            $script:profiles=@{};$script:autoUser=$null
            if ($userName -like 'Custom*') {
                $profile=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
                [IO.Directory]::CreateDirectory((Join-Path $profile 'Scripts')) | Out-Null
                [IO.File]::WriteAllText((Join-Path $profile 'Scripts\LaunchKiosk.ps1'),'# Existing launcher')
                $script:profiles[$userName]=$profile
            }
            $check=Get-KioskAccountCheck
            Assert-Kiosk ($check.Account.Name -ceq $userName -and $check.Result.Status -eq 'Pass') 'Existing kiosk account was not found'
            $view=Get-AccountReportView ([pscustomobject]@{ItemTitle='KIOSK Account';FoundStateHtml=$check.Result.StateHtml})
            foreach ($label in @('Password Never Expires','User Cannot Change Password')) {
                Assert-Kiosk ($view.ExpectedHtml -match ($label+':</span> Enabled') -and $view.FindingsHtml -match ($label+':</span> Enabled')) 'Kiosk password property missing from reference or Findings'
            }
            Assert-Kiosk ($view.FindingsHtml -match 'Account Privilege:' -and $view.FindingsHtml -match 'Account Status:</span> Active' -and $view.ExpectedHtml -match 'Account Privilege:</span> Standard or Administrator') 'Kiosk privilege or status missing'
            Assert-Kiosk ($view.FindingsHtml.Contains('Account Name:</span> '+$userName)) 'Kiosk account name missing from Findings'
        }
        $script:users=@([pscustomobject]@{Name='Custom no profile';Enabled=$true;SID=[pscustomobject]@{Value='Fixture'}})
        $script:profiles=@{};$script:autoUser='Custom no profile'
        Assert-Kiosk ((Get-KioskAccountCheck).Account.Name -eq 'Custom no profile') 'Configured custom auto-login user was not identified'
        $script:autoUser=$null
        Assert-Kiosk ($null -eq (Get-KioskAccountCheck).Account) 'Unrelated user was guessed as the kiosk user'
        $script:users=@()
        Assert-Kiosk ((Get-KioskAccountCheck).Result.Status -eq 'Fail') 'Missing account was not reported'
        $script:users=@();$script:profiles=@{};$script:autoUser=$null
        foreach ($custom in @('Custom A','Custom B')) {
            $profile=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory((Join-Path $profile 'Scripts')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $profile 'Scripts\LaunchKiosk.ps1'),'# Existing launcher')
            $script:profiles[$custom]=$profile
            $script:users+=[pscustomobject]@{Name=$custom;Enabled=$true;SID=[pscustomobject]@{Value=$custom}}
        }
        $ambiguous=Get-KioskAccountCheck
        Assert-Kiosk ($null -eq $ambiguous.Account -and $ambiguous.Result.Status -eq 'Fail') 'Ambiguous launcher profiles were guessed'
        $script:autoUser='Custom B'
        Assert-Kiosk ((Get-KioskAccountCheck).Account.Name -eq 'Custom B') 'Configured auto-login user did not resolve launcher ambiguity'

        $script:replies=[Collections.Generic.Queue[string]]::new();$script:prompts=[Collections.Generic.List[string]]::new()
        function Read-Host {param($Prompt) $script:prompts.Add($Prompt); if ($script:replies.Count) {return $script:replies.Dequeue()}; return ''}
        $url=$origin+'/#/onboarding/login?restaurantId=KEEP%2fOriginal&kioskId=Kiosk-2&host=HOST&custom=untouched%2fVALUE'
        $case=New-LauncherCase $url
        $result=Repair-LauncherDetails -Path $case.Path
        Assert-Kiosk ($result.Status -eq 'Pass' -and $script:prompts.Count -eq 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($case.Path)) -ceq [Convert]::ToBase64String($case.Bytes)) 'Complete launcher was prompted for or changed'
        foreach ($encoding in @([Text.UTF8Encoding]::new($false),[Text.UTF8Encoding]::new($true),[Text.Encoding]::Unicode)) {
            foreach ($missing in @('restaurantId','kioskId','host','all')) {
                $url=$origin+'/#/onboarding/login?restaurantId=KEEP&kioskId=Kiosk-2&host=HOST&custom=untouched%2fVALUE'
                if ($missing -eq 'all') {$url=$origin+'/#/onboarding/login?custom=untouched%2fVALUE'}
                else {$url=$url -replace ('([?&]'+$missing+'=)[^&]*'),'$1'}
                $case=New-LauncherCase $url $encoding
                $script:prompts.Clear();$script:replies.Clear();$script:replies.Enqueue('Must not be requested')
                $result=Repair-LauncherDetails -Path $case.Path -Restaurant 'SUPPLIED-R' -Kiosk 'SUPPLIED-K' -Hostname 'SUPPLIED-H'
                Assert-Kiosk ($result.Status -eq 'Fail' -and $result.Action -match 'Manual action required') 'Missing launcher values were not reported for manual action'
                Assert-Kiosk ($script:prompts.Count -eq 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($case.Path)) -ceq [Convert]::ToBase64String($case.Bytes)) 'Launcher values were prompted for or changed'
                Assert-Kiosk ($result.LauncherValues['URL'] -ceq $url -and $result.StateHtml -notmatch 'SUPPLIED-') 'Supplied values were incorrectly reported as findings'
                Assert-Kiosk ([IO.Directory]::GetFiles($case.Folder).Count -eq 1) 'Backup, temporary or additional file created'
            }
        }
        foreach ($problem in @('conflict','oldHostname','syntax','missingFile')) {
            $url=$origin+'/#/onboarding/login?restaurantId=R&kioskId=K&host=H'
            if ($problem -eq 'conflict') {$url+='&host=OTHER'}
            if ($problem -eq 'oldHostname') {$url=$url.Replace('host=H','hostname=H')}
            $case=New-LauncherCase $url
            if ($problem -eq 'syntax') {[IO.File]::WriteAllText($case.Path,'function Broken {')}
            if ($problem -eq 'missingFile') {[IO.File]::Delete($case.Path)}
            $before=if ([IO.File]::Exists($case.Path)) {[Convert]::ToBase64String([IO.File]::ReadAllBytes($case.Path))} else {'missing'}
            $script:prompts.Clear();$script:replies.Clear()
            $result=Repair-LauncherDetails -Path $case.Path
            $after=if ([IO.File]::Exists($case.Path)) {[Convert]::ToBase64String([IO.File]::ReadAllBytes($case.Path))} else {'missing'}
            Assert-Kiosk ($result.Status -eq 'Fail' -and $before -ceq $after -and $script:prompts.Count -eq 0 -and [IO.Directory]::GetFiles($case.Folder).Count -le 1) "Inspection changed or requested values: $problem"
        }
    }
    # A missing/blank password is deliberately not queried for auto-login verification.
    $script:users=@([pscustomobject]@{Name='Custom Kiosk';Enabled=$true;SID=[pscustomobject]@{Value='Fixture'}})
    $script:autoValues=@{AutoAdminLogon='1';DefaultUserName='Custom Kiosk';DefaultDomainName='.';AutoLogonCount=$null}
    function Get-Item {
        [CmdletBinding()]param($LiteralPath)
        Assert-Kiosk ($LiteralPath -ceq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') 'Unexpected auto-login registry read'
        if($script:autoReadDenied){throw 'Fixture registry access denied'}
        $key=[pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValue {param($Name) if ($Name -match 'Password') {throw 'Password must not be queried'};return $script:autoValues[$Name]}
        return $key
    }
    function Set-ItemProperty {throw 'Auto-login settings must not be changed'}
    function New-ItemProperty {throw 'Auto-login settings must not be created'}
    function Remove-ItemProperty {throw 'Auto-login settings must not be removed'}
    function Test-Path {[CmdletBinding()]param($LiteralPath,$PathType) if ($LiteralPath -like 'HKLM:*') {return $true};if ($PathType -eq 'Container') {return [IO.Directory]::Exists($LiteralPath)};return [IO.File]::Exists($LiteralPath)}
    $script:autoReadDenied=$false
    $autoCases=@(
        @{Label='missing domain and limit';Domain=$null;Count=$null;ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$true},
        @{Label='blank domain and limit';Domain='';Count='';ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$true},
        @{Label='local dot';Domain='.';Count=$null;ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$true},
        @{Label='local computer name';Domain=$env:COMPUTERNAME;Count=$null;ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$true},
        @{Label='other domain';Domain='Company & Other';Count=$null;ExpectedDomain='Company &amp; Other';ExpectedLimit='Unlimited';Pass=$false},
        @{Label='positive count';Domain='.';Count=3;ExpectedDomain='Local computer';ExpectedLimit='3';Pass=$false},
        @{Label='numeric zero';Domain='.';Count=0;ExpectedDomain='Local computer';ExpectedLimit='0';Pass=$false},
        @{Label='string zero';Domain='.';Count='0';ExpectedDomain='Local computer';ExpectedLimit='0';Pass=$false},
        @{Label='automatic sign-in disabled';Domain='.';Count=$null;Enabled='0';ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$false},
        @{Label='different user';Domain='.';Count=$null;User='Other & Kiosk';ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$false},
        @{Label='disabled account';Domain='.';Count=$null;AccountEnabled=$false;ExpectedDomain='Local computer';ExpectedLimit='Unlimited';Pass=$false}
    )
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        $script:autoValues=@{AutoAdminLogon='1';DefaultUserName='Custom Kiosk';DefaultDomainName='.';AutoLogonCount=$null}
        Assert-Kiosk ((& $actualAutoLoginName) -eq 'Custom Kiosk') 'Custom auto-login discovery failed'
        foreach($autoCase in $autoCases){
            $script:users[0].Enabled=if($autoCase.ContainsKey('AccountEnabled')){$autoCase.AccountEnabled}else{$true}
            $script:autoValues=@{AutoAdminLogon=$(if($autoCase.ContainsKey('Enabled')){$autoCase.Enabled}else{'1'});DefaultUserName=$(if($autoCase.ContainsKey('User')){$autoCase.User}else{'Custom Kiosk'});DefaultDomainName=$autoCase.Domain;AutoLogonCount=$autoCase.Count}
            $before=$script:autoValues | ConvertTo-Json -Compress
            $autoResult=Test-KioskAutoLogin -UserName 'Custom Kiosk'
            Assert-Kiosk (($script:autoValues | ConvertTo-Json -Compress) -ceq $before) 'Auto-login inspection changed fixture registry values'
            Assert-Kiosk (($autoResult.Status -eq 'Pass') -eq $autoCase.Pass) ('Incorrect auto-login verification: '+$autoCase.Label)
            $labels=@([regex]::Matches($autoResult.StateHtml,'kv-label">([^<]+):') | ForEach-Object {$_.Groups[1].Value})
            Assert-Kiosk (($labels -join '|') -ceq 'Automatic Sign-In|Default User|Default Domain|Automatic Sign-In Limit') 'Auto-login Findings do not contain exactly the approved four fields'
            $expectedEnabled=if($script:autoValues.AutoAdminLogon -eq '1'){'Enabled'}else{'Disabled'}
            Assert-Kiosk ($autoResult.StateHtml.Contains(('Automatic Sign-In:</span> '+$expectedEnabled)) -and $autoResult.StateHtml.Contains(('Default User:</span> '+[Net.WebUtility]::HtmlEncode($script:autoValues.DefaultUserName)))) 'Automatic sign-in state or dynamic username was lost'
            Assert-Kiosk ($autoResult.StateHtml.Contains(('Default Domain:</span> '+$autoCase.ExpectedDomain)) -and $autoResult.StateHtml.Contains(('Automatic Sign-In Limit:</span> '+$autoCase.ExpectedLimit))) 'Actual domain or automatic sign-in limit was lost'
            $requirement=Get-ReportRequirement ([pscustomobject]@{ItemTitle='Kiosk Auto-Login'})
            Assert-Kiosk ($requirement -ceq (ConvertTo-ReportDefinitionHtml ([ordered]@{'Automatic Sign-In'='Enabled';'Default User'='Kiosk account';'Default Domain'='Local computer';'Automatic Sign-In Limit'='Unlimited'}))) 'Auto-login requirements do not match the approved labels'
        }
        $script:users[0].Enabled=$true
        $script:autoReadDenied=$true
        $readFailed=$false
        try{Test-KioskAutoLogin -UserName 'Custom Kiosk' | Out-Null}catch{$readFailed=$_.Exception.Message -eq 'Fixture registry access denied'}
        Assert-Kiosk $readFailed 'A failed registry read was reported as verified'
        $script:autoReadDenied=$false

        # Real report renderer, using synthetic auto-login values only.
        $script:users=@([pscustomobject]@{Name='SELISE-KIOSK';Enabled=$true;SID=[pscustomobject]@{Value='Fixture'}})
        $script:autoValues=@{AutoAdminLogon='1';DefaultUserName='SELISE-KIOSK';DefaultDomainName='';AutoLogonCount=$null}
        $autoResult=Test-KioskAutoLogin -UserName 'SELISE-KIOSK'
        $auditRows=[Collections.Generic.List[psobject]]::new()
        $autoResult | Add-Member NoteProperty Shortcut (New-ReportCommand @('regedit','reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon','reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName'))
        $auditRows.Add([pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Kiosk Auto-Login';ItemSub='Verified configuration';Shortcut=$autoResult.Shortcut;FoundStateHtml=$autoResult.StateHtml;Status=$autoResult.Status;ActionTaken=$autoResult.Action})
        $previewRoot=Join-Path $projectRoot 'output\auto-login'
        [void][IO.Directory]::CreateDirectory($previewRoot)
        $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
        $modeName=if($mode){'Apply'}else{'Audit'}
        $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$modeName+'-preview.html')
        $runId='SAMPLE-AUTOLOGIN';$clientLocation='Sample branch';$deviceType='KIOSK';$reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
        function Read-AuditReportChoice {return $true}
        function Start-AuditStep {param($Number,$Name)}
        function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
        $finalizer=$ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
        . ([scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
        $html=[IO.File]::ReadAllText($reportPath)
        Assert-Kiosk ($html.Contains($autoResult.StateHtml) -and $html.Contains($requirement) -and ($html -match '<th>Status</th>') -eq $mode) 'Rendered auto-login report content or Audit/Apply columns changed'
        Assert-Kiosk ($html.Contains('/v AutoAdminLogon') -and $html.Contains('/v DefaultUserName')) 'Report labels changed actual registry command names'
        $script:users=@([pscustomobject]@{Name='Custom Kiosk';Enabled=$true;SID=[pscustomobject]@{Value='Fixture'}})
    }
    Write-Output "PASS: $name kiosk account discovery/custom names and required properties, 24 read-only auto-login cases with four display fields and numeric zero handled correctly, Audit/Apply previews, read-only launcher checks without prompts, encoding/content preservation and no backup files"
}
