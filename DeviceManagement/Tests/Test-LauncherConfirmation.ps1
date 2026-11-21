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
    $source=$client
    Set-KioskTestClient -ClientType $client
    $ast=[KioskTestSource]::ParseFile((Join-Path $project 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-Confirmation (-not $errors.Count) 'Source parse failed'
    $functions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $realWrite=(Get-Command Write-ThoroughTextChange).ScriptBlock
    $realDetails=(Get-Command Add-LauncherReportDetails).ScriptBlock
    function Write-ThoroughTextChange {param($Original,[string]$Text,[string]$BackupFolder)
        Assert-Confirmation ($Original.Path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) 'Real configuration write attempted'
        & $realWrite -Original $Original -Text $Text -BackupFolder (Join-Path $root backups)
    }
    function Get-ThoroughDeviceHostname {$script:activeName}
    function Read-Host {param($Prompt) $script:prompts.Add($Prompt);if(-not $script:answers.Count){throw 'Unexpected prompt: '+$Prompt};$script:answers.Dequeue()}
    # Every launcher-only path must succeed with OS/credential APIs forbidden.
    function Rename-Computer {throw 'Windows rename is forbidden'}
    function Restart-Computer {throw 'Computer restart is forbidden'}
    function Get-Credential {throw 'Domain credential prompts are forbidden'}
    function New-ItemProperty {throw 'Launcher confirmation must not write the registry'}
    function Get-ItemPropertyValue {throw 'Pending computer-name registry inspection is forbidden'}
    function Get-Item {throw 'Auto-login registry inspection is forbidden'}
    function Get-CimInstance {throw 'Only the Windows hostname suggestion may query computer identity'}
    function Reset-Confirmation {
        $script:ApplyChanges=$true;$script:activeName='DEVICE-01'
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
    function New-ConfirmedPlan {New-ThoroughLauncherPlan -Path $script:path}

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=OLD&kioskId=K1&host=OLD-HOST&extra=Keep%20Me' -OtherOrigin -Unicode
    $script:answers.Enqueue('NEW R&2');$script:answers.Enqueue('');$script:answers.Enqueue('')
    $plan=New-ConfirmedPlan
    Assert-Confirmation ($script:prompts.Count -eq 3 -and $script:prompts[0] -like '*Restaurant ID*' -and $script:prompts[1] -like '*Kiosk ID*' -and $script:prompts[2] -like 'Hostname*') 'Prompt order incorrect'
    Assert-Confirmation ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $beforeBytes) 'Preflight mutated state'
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Pass' -and $result.LauncherValues['Restaurant ID'] -ceq 'NEW R&2' -and $result.LauncherValues['KIOSK ID'] -ceq 'K1') 'Confirmed IDs not applied'
    Assert-Confirmation ($plan.Url.Contains('restaurantId=NEW%20R%262') -and $plan.Url.Contains('&extra=Keep%20Me') -and $plan.Url.StartsWith($script:KioskClientSettings.Origin)) 'URL origin/encoding or unrelated parameter lost'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-Confirmation ($bytes[0] -eq 255 -and $bytes[1] -eq 254 -and [IO.File]::ReadAllText($path).Contains('--customer-flag')) 'Encoding or flags changed'
    Assert-Confirmation ([Convert]::ToBase64String([IO.File]::ReadAllBytes($plan.Change.BackupPath)) -ceq $beforeBytes) 'Exact backup missing'
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
    Assert-Confirmation ($blocked -and -not $script:prompts.Count) 'Audit prompted/mutated'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
    $plan=New-ThoroughLauncherPlan $path 'R2' 'K2' 'DEVICE-01'
    [IO.File]::AppendAllText($path,"`n# concurrent change")
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Fail' -and [IO.File]::ReadAllText($path).Contains('# concurrent change')) 'Concurrent edit overwritten'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=DEVICE-01'
    $plan=New-ThoroughLauncherPlan $path 'R' 'K' 'DEVICE-01'
    [IO.File]::AppendAllText($path,"`n# concurrent no-op edit")
    $result=Invoke-ThoroughLauncherPlan $plan $path ''
    Assert-Confirmation ($result.Status -eq 'Fail' -and -not $plan.Verified -and [IO.File]::ReadAllText($path).Contains('# concurrent no-op edit')) 'No-op bypassed concurrent file validation'

    Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD'
    $plan=New-ThoroughLauncherPlan $path 'NEW-R' 'NEW-K' 'DEVICE-01'
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

    foreach($hostValue in @('CUSTOM-HOST','OM-DHK-PAN-KIOSK-LONG','branch.example.com','CUSTOM_HOST')){
        Reset-Confirmation;New-ConfirmationFixture '?restaurantId=R&kioskId=K&host=OLD-HOST'
        $plan=New-ThoroughLauncherPlan $path 'R' 'K' $hostValue
        $script:ConfirmedLauncherPlan=$plan
        $result=Repair-LauncherDetails -Path $path -Restaurant 'R' -Kiosk 'K' -Hostname $hostValue
        $script:ConfirmedLauncherPlan=$null
        Assert-Confirmation ($result.Status -eq 'Pass' -and $result.LauncherValues['Host Name'] -ceq $hostValue -and $script:activeName -ceq 'DEVICE-01') 'Custom host must update only the launcher, preserving the Windows name'
        Assert-Confirmation (-not $plan.PSObject.Properties['DomainCredential'] -and -not $plan.PSObject.Properties['Computer']) 'Launcher plan retains OS rename dependencies'
    }
    # Older saved observations must not resurrect the removed OS rename check.
    $retired=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='Windows Computer Name';ItemSub='Verified configuration';Shortcut='';FoundStateHtml='Restart Required';Status='Fail';ActionTaken='Historical rename check'}
    $snapshot=New-ThoroughReportSnapshot -Rows @($newLauncher) -BeforeRows @($oldLauncher,$retired) -DisplayMode Fix -AfterApply $true
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    Assert-Confirmation (-not $html.Contains('<div class="device-title">Windows Computer Name</div>') -and $retired.FoundStateHtml -ceq 'Restart Required') 'Retired rename check reappeared or historical observations were modified'
    $commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    Assert-Confirmation (-not @($commands | Where-Object {$_ -in @('Rename-Computer','Restart-Computer','Get-Credential')}).Count) 'Engine still contains a computer rename/restart/credential command'
    Write-Output ('PASS: '+$client+' launcher-only confirmed IDs/order and custom hostname, URL safety, backups, readback rollback, concurrency, retired report handling; Windows rename/restart/registry/credential APIs forbidden.')
}
