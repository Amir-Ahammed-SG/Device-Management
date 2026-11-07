# Actual function definitions, disposable files and mocked Windows APIs only.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
$project=Split-Path $PSScriptRoot -Parent
$root=Join-Path $project ('output\launcher-confirmation\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert-Confirmation {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    $tokens=$null;$errors=$null
    $source=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $ast=[KioskTestSource]::ParseFile((Join-Path $project $source),[ref]$tokens,[ref]$errors)
    Assert-Confirmation (-not $errors.Count) 'Source parse failed'
    $functions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $realWrite=(Get-Command Write-ThoroughTextChange).ScriptBlock
    $realState=(Get-Command Get-ThoroughComputerNameState).ScriptBlock
    $realDetails=(Get-Command Add-LauncherReportDetails).ScriptBlock
    function Write-ThoroughTextChange {param($Original,[string]$Text,[string]$BackupFolder)
        Assert-Confirmation ($Original.Path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) 'Real configuration write attempted'
        & $realWrite -Original $Original -Text $Text -BackupFolder (Join-Path $root backups)
    }
    function Get-ThoroughDeviceHostname {$script:activeName}
    function Get-ThoroughComputerNameState {[pscustomobject]@{Active=$script:activeName;Pending=$script:pendingName;RenamePending=($script:pendingName -ine $script:activeName);PartOfDomain=$script:domainJoined}}
    function Get-CimInstance {param($ClassName) [pscustomobject]@{PartOfDomain=$script:domainJoined}}
    function Get-ItemPropertyValue {param($LiteralPath,$Name) if($LiteralPath -like '*ActiveComputerName'){$script:netbiosName}else{$script:pendingName}}
    function Read-Host {param($Prompt) $script:prompts.Add($Prompt);if(-not $script:answers.Count){throw 'Unexpected prompt: '+$Prompt};$script:answers.Dequeue()}
    function Get-LocalAccount {param($UserName) [pscustomobject]@{Name=$UserName;Enabled=$true}}
    function Get-Item {param($LiteralPath)
        Assert-Confirmation ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') 'Unexpected registry read'
        $key=[pscustomobject]@{}
        $key|Add-Member ScriptMethod GetValue {param($Name) switch($Name){'DefaultDomainName'{$script:loginDomain};'DefaultUserName'{'SELISE-KIOSK'}}}
        $key|Add-Member ScriptMethod GetValueKind {param($Name) [Microsoft.Win32.RegistryValueKind]::String}
        $key
    }
    function New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force)
        Assert-Confirmation ($Name -eq 'DefaultDomainName' -and $LiteralPath -like '*\Winlogon') 'Unexpected registry write'
        $script:loginDomain=$Value;$script:registryWrites++
    }
    function Get-Credential {param($Message) $script:credentialCalls++;if($script:declineCredential){return $null};[pscredential]::new('DOMAIN\operator',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))}
    function Rename-Computer {param($NewName,[switch]$Force,[switch]$PassThru,$DomainCredential)
        Assert-Confirmation (-not $PSBoundParameters.ContainsKey('Restart')) 'Implicit restart attempted'
        $script:renameCalls++
        if($script:renameFailure){throw 'Fixture rename failure'}
        if($script:domainJoined){Assert-Confirmation ($null -ne $DomainCredential) 'Domain credential not passed'}
        $script:pendingName=$NewName;[pscustomobject]@{HasSucceeded=$true}
    }
    function Restart-Computer {param([switch]$Confirm) $script:restartCalls++}
    function Reset-Confirmation {
        $script:ApplyChanges=$true;$script:activeName='DEVICE-01';$script:pendingName='DEVICE-01';$script:netbiosName='DEVICE-01'
        $script:domainJoined=$false;$script:loginDomain='DEVICE-01';$script:renameCalls=0;$script:registryWrites=0;$script:restartCalls=0
        $script:credentialCalls=0;$script:declineCredential=$false;$script:renameFailure=$false;$script:ThoroughRestartRequired=$false
        $script:answers=[Collections.Generic.Queue[string]]::new();$script:prompts=[Collections.Generic.List[string]]::new()
    }
    function New-ConfirmationFixture {
        param([string]$Query,[switch]$OtherOrigin,[switch]$Unicode)
        $script:path=Join-Path $root ([guid]::NewGuid().ToString('N')+'.ps1')
        $origin=if($OtherOrigin){if($client -eq 'SaaS'){'https://kiosk.subway.ch'}else{'https://kiosk.ordermonkey.com'}}else{$script:KioskClientSettings.Origin}
        $script:before="# customer comment`r`nStart-Process msedge.exe -ArgumentList '--kiosk $origin/#/onboarding/login$Query --disable-pinch --customer-flag'`r`n"
        $encoding=if($Unicode){[Text.UnicodeEncoding]::new($false,$true)}else{[Text.UTF8Encoding]::new($false)}
        [IO.File]::WriteAllText($script:path,$script:before,$encoding)
        $script:beforeBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($script:path))
    }
    function New-ConfirmedPlan {New-ThoroughLauncherPlan -Path $script:path -UserName 'SELISE-KIOSK'}

    Reset-Confirmation
    # Actual registry reader must distinguish long DNS names from shortened NetBIOS.
    $script:activeName='OM-DHK-PAN-KIOSK-LONG';$script:pendingName='OM-DHK-PAN-KIOS';$script:netbiosName=$script:pendingName
    $state=& $realState
    Assert-Confirmation (-not $state.RenamePending -and $state.Active -eq 'OM-DHK-PAN-KIOSK-LONG') 'Long DNS name mistaken for a pending rename'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=OLD&kioskId=K1&host=OLD-HOST&extra=Keep%20Me' -OtherOrigin -Unicode
    $script:answers.Enqueue('NEW R&2');$script:answers.Enqueue('');$script:answers.Enqueue('')
    $plan=New-ConfirmedPlan
    Assert-Confirmation ($script:prompts.Count -eq 3 -and $script:prompts[0] -like '*Restaurant ID*' -and $script:prompts[1] -like '*Kiosk ID*' -and $script:prompts[2] -like 'Hostname*') 'Prompt order incorrect'
    Assert-Confirmation ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $beforeBytes -and $script:renameCalls -eq 0 -and $script:registryWrites -eq 0) 'Preflight mutated state'
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Pass' -and $result.LauncherValues['Restaurant ID'] -ceq 'NEW R&2' -and $result.LauncherValues['KIOSK ID'] -ceq 'K1') 'Confirmed IDs not applied'
    Assert-Confirmation ($plan.Url.Contains('restaurantId=NEW%20R%262') -and $plan.Url.Contains('&extra=Keep%20Me') -and $plan.Url.StartsWith($script:KioskClientSettings.Origin)) 'URL origin/encoding or unrelated parameter lost'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-Confirmation ($bytes[0] -eq 255 -and $bytes[1] -eq 254 -and [IO.File]::ReadAllText($path).Contains('--customer-flag')) 'Encoding or flags changed'
    Assert-Confirmation ([Convert]::ToBase64String([IO.File]::ReadAllBytes($plan.Change.BackupPath)) -ceq $beforeBytes) 'Exact backup missing'
    $computer=Invoke-ThoroughComputerNameCheck $plan 'SELISE-KIOSK'
    Assert-Confirmation ($computer.Status -eq 'Pass' -and $script:renameCalls -eq 0 -and -not $script:ThoroughRestartRequired) 'Same Windows name was renamed'
    $script:answers.Enqueue('');$script:answers.Enqueue('');$script:answers.Enqueue('')
    $second=New-ConfirmedPlan;$result=Invoke-ThoroughLauncherPlan $second $path ''
    Assert-Confirmation (-not $second.Change.Changed -and $result.Status -eq 'Pass') 'Repeated confirmed Apply was not idempotent'

    # A present ID can already satisfy "Configured" and still be changed by the
    # operator. Show its actual before/after values in Fix, in the new order.
    $oldLauncher=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Kiosk Launch Architecture';ItemSub='Verified configuration';Shortcut=(New-ReportCommand @('notepad fixture.ps1'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Launcher Path'=$path;'Restaurant ID'='OLD-R';'Kiosk ID'='OLD-K';'Host name'='DEVICE-01';'URL origin'=$script:KioskClientSettings.Origin}));Status='Pass';ActionTaken='Audit only'}
    $newLauncher=$oldLauncher|Select-Object *
    $newLauncher.FoundStateHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{'Launcher Path'=$path;'URL origin'=$script:KioskClientSettings.Origin;'Restaurant ID'='NEW-R';'Kiosk ID'='NEW-K';'Host name'='DEVICE-01'})
    $newLauncher.ActionTaken='Updated launcher settings; readback verified.'
    $snapshot=New-ThoroughReportSnapshot -Rows @($newLauncher) -BeforeRows @($oldLauncher) -DisplayMode Fix -AfterApply $true
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    $view=Get-SettingRenderedComponent $html 'Kiosk Launch Script'
    $idFields=@($view.Fields | Where-Object Setting -IN @('Restaurant ID','Kiosk ID'))
    Assert-Confirmation (($idFields.Setting -join '|') -ceq 'Restaurant ID|Kiosk ID' -and ($idFields.Findings -join '|') -ceq 'OLD-R|OLD-K' -and ($idFields.Value -join '|') -ceq 'NEW-R|NEW-K') 'Changed valid IDs missing from Fix or observations overwritten'

    foreach($query in @('', '?restaurantId=&kioskId=&host=', '?restaurantId&kioskId&extra=keep')){
        Reset-Confirmation;New-ConfirmationFixture $query
        $script:answers.Enqueue('');$script:answers.Enqueue('R1');$script:answers.Enqueue('');$script:answers.Enqueue('KIOSK-02');$script:answers.Enqueue('')
        $plan=New-ConfirmedPlan;$result=Invoke-ThoroughLauncherPlan $plan $path ''
        Assert-Confirmation ($result.Status -eq 'Pass' -and -not @((Resolve-KioskUrl $plan.Url).Issues).Count) 'Missing ID retry/add failed'
    }

    foreach($query in @('?restaurantId=A&restaurantId=B&kioskId=K', '?RestaurantId=A&kioskId=K', '?restaurantId=A&kioskId=K&host=X&host=Y', '?restaurantId=A&kioskId=K&hostname=X')){
        Reset-Confirmation;New-ConfirmationFixture $query
        $blocked=$false;try{$null=New-ConfirmedPlan}catch{$blocked=$true}
        Assert-Confirmation ($blocked -and -not $script:prompts.Count -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $beforeBytes) 'Ambiguous URL accepted or prompted'
    }
    foreach($bad in @('https://unknown.example/#/onboarding/login?restaurantId=R&kioskId=K', 'https://kiosk.subway.ch/#/wrong?restaurantId=R&kioskId=K')){
        Reset-Confirmation;New-ConfirmationFixture ''
        [IO.File]::WriteAllText($path,("Start-Process msedge.exe -ArgumentList '--kiosk "+$bad+"'"))
        $blocked=$false;try{$null=New-ConfirmedPlan}catch{$blocked=$true}
        Assert-Confirmation ($blocked -and -not $script:prompts.Count) 'Unknown origin/route accepted'
    }
    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=DEVICE-01'
    [IO.File]::AppendAllText($path,"`n# SIG # Begin signature block")
    $blocked=$false;try{$null=New-ConfirmedPlan}catch{$blocked=$true}
    Assert-Confirmation ($blocked -and -not $script:prompts.Count) 'Signed launcher modified'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=DEVICE-01'
    $script:ApplyChanges=$false
    $blocked=$false;try{$null=New-ConfirmedPlan}catch{$blocked=$true}
    $result=Invoke-ThoroughComputerNameCheck $null 'SELISE-KIOSK'
    Assert-Confirmation ($blocked -and $result.Status -eq 'Pass' -and -not $script:prompts.Count -and -not $script:renameCalls) 'Audit prompted/mutated'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
    $plan=New-ThoroughLauncherPlan $path 'R2' 'K2' 'DEVICE-01' 'SELISE-KIOSK'
    [IO.File]::AppendAllText($path,"`n# concurrent change")
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Fail' -and [IO.File]::ReadAllText($path).Contains('# concurrent change')) 'Concurrent edit overwritten'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=DEVICE-01'
    $plan=New-ThoroughLauncherPlan $path 'R' 'K' 'DEVICE-01' 'SELISE-KIOSK'
    [IO.File]::AppendAllText($path,"`n# concurrent no-op edit")
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Fail' -and -not $plan.Verified -and [IO.File]::ReadAllText($path).Contains('# concurrent no-op edit')) 'No-op bypassed concurrent file validation'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
    $plan=New-ThoroughLauncherPlan $path 'NEW-R' 'NEW-K' 'DEVICE-01' 'SELISE-KIOSK'
    $script:failDetailsOnce=$true
    function Add-LauncherReportDetails {
        param($Result,[string]$Path,[string]$ShortcutPath,[string]$StartupBatchPath)
        $observed=& $realDetails $Result $Path $ShortcutPath $StartupBatchPath
        if($script:failDetailsOnce){$script:failDetailsOnce=$false;$observed.LauncherValues['URL']='readback-fixture-mismatch'}
        $observed
    }
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Fail' -and -not $plan.Verified -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $beforeBytes) 'Failed multi-field readback did not restore exact original bytes'
    Set-Item -Path Function:Add-LauncherReportDetails -Value $realDetails

    foreach($domainJoined in @($false,$true)){
        Reset-Confirmation;$script:domainJoined=$domainJoined;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
        $plan=New-ThoroughLauncherPlan $path 'R' 'K' 'NEW-DEVICE' 'SELISE-KIOSK'
        $null=Invoke-ThoroughLauncherPlan $plan $path ''
        $result=Invoke-ThoroughComputerNameCheck $plan 'SELISE-KIOSK'
        Assert-Confirmation ($result.Status -eq 'Fail' -and $result.State -eq 'Restart Required' -and $script:ThoroughRestartRequired -and $script:renameCalls -eq 1 -and $script:activeName -eq 'DEVICE-01') 'Rename reported success before reboot'
        $beforeRow=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Windows Computer Name';ItemSub='Verified configuration';Shortcut=(New-ReportCommand @('sysdm.cpl'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Active hostname'='DEVICE-01';'Requested hostname'='DEVICE-01';'Pending hostname'='None';'Rename status'='Verified'}));Status='Pass';ActionTaken='Windows computer name inspected without changes.'}
        $afterRow=$beforeRow|Select-Object *;$afterRow.Status=$result.Status;$afterRow.FoundStateHtml=$result.StateHtml;$afterRow.ActionTaken=$result.Action
        foreach($mode in @('Fix','Final')){
            $snapshot=New-ThoroughReportSnapshot -Rows @($afterRow) -BeforeRows @($beforeRow) -DisplayMode $mode -AfterApply $true -Hostname 'DEVICE-01' -DeviceType KIOSK -LauncherKioskId 'KIOSK-01' -ClientLocation 'Fixture'
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            $view=Get-SettingRenderedComponent $html 'Windows Computer Name'
            $pendingField=@($view.Fields|Where-Object Setting -EQ 'Rename status')
            Assert-Confirmation ($pendingField.Count -eq 1 -and $pendingField[0].Value -eq 'Restart Required' -and $pendingField[0].Html.Contains('finding-unverified')) 'Report concealed pending restart or claimed verification'
            if($mode -eq 'Fix'){Assert-Confirmation ($pendingField[0].Findings -eq 'Verified') 'Pre-fix computer-name observation overwritten'}
            [IO.File]::WriteAllText((Join-Path $root ($client+'-'+$mode+'-pending.html')),$html,[Text.UTF8Encoding]::new($false))
        }
        Assert-Confirmation ($script:loginDomain -eq '.' -and $null -eq $plan.DomainCredential) 'Local sign-in not preserved or credential retained'
        $script:answers.Enqueue('');Confirm-ThoroughRestart
        Assert-Confirmation ($script:restartCalls -eq 0) 'Default restart was not declined'
        $script:answers.Enqueue('y');Confirm-ThoroughRestart
        Assert-Confirmation ($script:restartCalls -eq 1) 'Explicit restart did not run'
        $script:answers.Enqueue('');$script:answers.Enqueue('');$script:answers.Enqueue('NEW-DEVICE')
        $again=New-ConfirmedPlan;$null=Invoke-ThoroughLauncherPlan $again $path '';$result=Invoke-ThoroughComputerNameCheck $again 'SELISE-KIOSK'
        Assert-Confirmation ($script:renameCalls -eq 1 -and $result.State -eq 'Restart Required') 'Pending rename reissued'
        $script:activeName='NEW-DEVICE';$script:ApplyChanges=$false
        $result=Invoke-ThoroughComputerNameCheck $null 'SELISE-KIOSK'
        Assert-Confirmation ($result.Status -eq 'Pass') 'Post-reboot Audit did not verify active name'
    }

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
    $plan=New-ThoroughLauncherPlan $path 'R' 'K' 'NEW-DEVICE' 'SELISE-KIOSK'
    $null=Invoke-ThoroughLauncherPlan $plan $path '';$script:renameFailure=$true
    $result=Invoke-ThoroughComputerNameCheck $plan 'SELISE-KIOSK'
    Assert-Confirmation ($result.Status -eq 'Fail' -and $script:loginDomain -eq 'DEVICE-01' -and -not $script:ThoroughRestartRequired -and -not $plan.Verified) 'Rename failure recovery incomplete'
    Assert-Confirmation ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $beforeBytes) 'Rename failure did not restore original launcher'

    Reset-Confirmation;$script:domainJoined=$true;$script:declineCredential=$true;New-ConfirmationFixture '?restaurantId=R&kioskId=K'
    $blocked=$false;try{$null=New-ThoroughLauncherPlan $path 'R' 'K' 'NEW-DEVICE' 'SELISE-KIOSK'}catch{$blocked=$true}
    Assert-Confirmation ($blocked -and -not $script:renameCalls -and -not $script:registryWrites) 'Declined domain credentials mutated state'
    Reset-Confirmation;$script:pendingName='OTHER-DEVICE';New-ConfirmationFixture '?restaurantId=R&kioskId=K'
    $blocked=$false;try{$null=New-ThoroughLauncherPlan $path 'R' 'K' 'NEW-DEVICE' 'SELISE-KIOSK'}catch{$blocked=$true}
    Assert-Confirmation ($blocked -and -not $script:renameCalls) 'Conflicting pending rename overwritten'
    foreach($invalid in @('all.numeric','12345','bad name','-bad',('x'*64))){Assert-Confirmation (-not (Test-ThoroughComputerName $invalid)) ('Unsafe Windows name accepted: '+$invalid)}
    Assert-Confirmation ((ConvertTo-ThoroughSettingValue 'Restart Required').Contains('finding-unverified')) 'Pending restart has no amber label'
    # Restart prompt is after report persistence in the executable source path.
    $body=[KioskTestSource]::ReadAllText((Join-Path $project $source))
    Assert-Confirmation ($body.LastIndexOf('if($generateReport){Confirm-ThoroughRestart}') -gt $body.LastIndexOf('$reportPath=Save-ThoroughReportBundle')) 'Restart can occur before report persistence'
    Write-Output ('PASS: '+$client+' confirmed launcher IDs/order, URL safety, exact backups, concurrency, Windows rename/domain/sign-in recovery and explicit restart.')
}
