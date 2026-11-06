
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# Isolated fixtures only. Never use real Windows profiles, shortcuts or registry.
$ErrorActionPreference='Stop'
$parent=$projectRoot
$fixtureRoot=Join-Path $projectRoot ('output\launcher-inspection\run-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
function Assert-Inspection { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Get-FixtureSnapshot {
    param([switch]$ExcludeShortcut)
    (@(Get-ChildItem -LiteralPath $script:profilePath -Recurse -File | Where-Object { -not $ExcludeShortcut -or $_.FullName -ne $script:shortcutPath } | Sort-Object FullName | ForEach-Object {
        $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join "`n"
}
function New-LauncherFixture {
    $script:profilePath=Join-Path $fixtureRoot ('Branch & Device-'+[guid]::NewGuid().ToString('N'))
    $script:launchPath=Join-Path $script:profilePath 'Scripts\LaunchKiosk.ps1'
    $script:batchPath=Join-Path $script:profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
    $script:shortcutPath=Join-Path $script:profilePath 'Desktop\Launch Kiosk.lnk'
    foreach ($path in @($script:launchPath,$script:batchPath,$script:shortcutPath)) { [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null }
    $url=$script:origin+'/#/onboarding/login?restaurantId=R1&kioskId=K1&host=HOST-01&custom=Keep%20Me'
    $script:expectedLauncherUrl=$url
    [IO.File]::WriteAllText($script:launchPath,('Start-Process msedge.exe -ArgumentList ''--kiosk "'+$url+'"'''))
    [IO.File]::WriteAllText($script:batchPath,('@echo off'+"`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Scripts\LaunchKiosk.ps1"'))
    [IO.File]::WriteAllText((Join-Path (Split-Path $script:batchPath -Parent) 'Customer Startup.bat'),'customer startup content')
    $script:shortcutRecords=@{}
    $script:saveCalls=0; $script:removedShortcuts=0; $script:badReadback=$false; $script:profileMissing=$false
}
function Add-FixtureShortcut {
    param([string]$Target)
    [IO.File]::WriteAllText($script:shortcutPath,'Existing shortcut fixture bytes must remain unchanged')
    $script:shortcutRecords[$script:shortcutPath]=@{TargetPath=$Target;Arguments='';WorkingDirectory='Existing directory';Description='Existing description'}
}
function New-PolicyKey {
    param([string]$Path)
    $key=[pscustomobject]@{RegistryPath=$Path;Values=@{};Kinds=@{}}
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
    $key | Add-Member ScriptMethod GetValue { param($Name) return $this.Values[$Name] }
    $key | Add-Member ScriptMethod GetValueKind { param($Name) return $this.Kinds[$Name] }
    $script:registryKeys[$Path]=$key
    return $key
}
function Reset-PolicyFixture {
    $script:registryKeys=@{}; $script:policyWrites=0; $script:keyWrites=0
    $script:edge='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $script:allow=$script:edge+'\LocalNetworkAccessAllowedForUrls'
    $script:gestures='HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI'
    foreach ($path in @('HKLM:\','HKLM:\SOFTWARE','HKLM:\SOFTWARE\Policies','HKLM:\SOFTWARE\Policies\Microsoft','HKLM:\SOFTWARE\Policies\Microsoft\Windows',$script:edge,$script:allow,$script:gestures)) { New-PolicyKey $path | Out-Null }
    foreach ($spec in @(@($script:allow,'1',$script:origin,'String'),@($script:edge,'TranslateEnabled',0,'DWord'),@($script:edge,'VisualSearchEnabled',0,'DWord'),@($script:gestures,'AllowEdgeSwipe',0,'DWord'))) {
        $script:registryKeys[$spec[0]].Values[$spec[1]]=$spec[2]
        $script:registryKeys[$spec[0]].Kinds[$spec[1]]=$spec[3]
    }
}
$originalFixtureComputerName=$env:COMPUTERNAME
try {
$env:COMPUTERNAME='HOST-01'
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $script:origin=if ($sourceName -eq 'SubwayKioskThoroughCheck.ps1') { 'https://kiosk.subway.ch' } else { 'https://kiosk.ordermonkey.com' }
    $tokens=$null; $errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $parent $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Inspection ($errors.Count -eq 0) 'Source did not parse'
    $definitions=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    function Get-ThoroughDeviceHostname { return 'HOST-01' }
    # Pinch repair has its own file/rollback fixtures in Test-PinchZoom.ps1.
    function Invoke-KioskPinchZoomCheck {param($UserName) New-CheckResult 'Pass' 'Fixture pinch check; no launcher changes.' 'Disabled'}
    function Get-KioskProfilePath { param($UserName) if ($script:profileMissing) { return $null }; return $script:profilePath }
    function Read-Host { throw 'Launcher inspection must not request values' }
    function Add-Type { throw 'Unexpected profile provisioning' }
    function Set-ItemProperty { throw 'Unexpected registry overwrite' }
    function Remove-ItemProperty { throw 'Unexpected registry deletion' }
    function Copy-Item { throw 'Unexpected file replacement or backup' }
    function Out-File { throw 'Unexpected launcher file creation' }
    function Start-Process { throw 'Unexpected launcher execution' }
    function Test-Path {
        [CmdletBinding()]param($LiteralPath,$PathType)
        if ($LiteralPath -like 'HKLM:*') { return $script:registryKeys.ContainsKey($LiteralPath) }
        if ($PathType -eq 'Container') { return [IO.Directory]::Exists($LiteralPath) }
        if ($PathType -eq 'Leaf') { return [IO.File]::Exists($LiteralPath) }
        return [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
    }
    function New-Object {
        [CmdletBinding()]param($ComObject)
        Assert-Inspection ($ComObject -eq 'WScript.Shell') 'Unexpected COM object'
        $shell=[pscustomobject]@{}
        $shell | Add-Member ScriptMethod CreateShortcut {
            param($Path)
            $link=[pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';Description=''}
            if ($script:shortcutRecords.ContainsKey($Path)) {
                foreach ($property in @('TargetPath','Arguments','WorkingDirectory','Description')) { $link.$property=$script:shortcutRecords[$Path][$property] }
                if ($script:badReadback) { $link.TargetPath='C:\Wrong target.bat' }
            }
            $link | Add-Member ScriptMethod Save {
                Assert-Inspection ($this.Path -eq $script:shortcutPath -and -not [IO.File]::Exists($this.Path)) 'Attempt to overwrite an existing shortcut or another file'
                $script:saveCalls++
                $script:shortcutRecords[$this.Path]=@{TargetPath=$this.TargetPath;Arguments=$this.Arguments;WorkingDirectory=$this.WorkingDirectory;Description=$this.Description}
                [IO.File]::WriteAllText($this.Path,'New fixture desktop shortcut')
            }
            return $link
        }
        return $shell
    }
    function Remove-Item {
        [CmdletBinding()]param($LiteralPath,[switch]$Force)
        Assert-Inspection ($LiteralPath -eq $script:shortcutPath -and $script:saveCalls -eq 1) 'Unexpected file deletion'
        $script:removedShortcuts++
        [IO.File]::Delete($LiteralPath)
    }
    function Get-Item { [CmdletBinding()]param($LiteralPath) if (-not $script:registryKeys.ContainsKey($LiteralPath)) { throw 'Missing fixture registry key' }; return $script:registryKeys[$LiteralPath] }
    function New-Item {
        [CmdletBinding()]param($Path)
        Assert-Inspection ($Path -like 'HKLM:*' -and -not $script:registryKeys.ContainsKey($Path)) 'Unexpected filesystem creation or registry overwrite'
        $script:keyWrites++
        New-PolicyKey $Path
    }
    function New-ItemProperty {
        [CmdletBinding()]param($LiteralPath,$Name,$Value,$PropertyType)
        $key=$script:registryKeys[$LiteralPath]
        Assert-Inspection ($null -ne $key -and -not $key.Values.ContainsKey($Name)) 'Existing policy value was overwritten'
        $script:policyWrites++
        $key.Values[$Name]=$Value; $key.Kinds[$Name]=$PropertyType
    }
    $validUrl=$script:origin+'/#/onboarding/login?restaurantId=R1&kioskId=K1&host=HOST-01'
    Assert-Inspection (@((Resolve-KioskUrl -Url $validUrl).Issues).Count -eq 0) 'Valid onboarding URL rejected'
    foreach($invalidUrl in @(
        ($script:origin+'/#/other?restaurantId=R1&kioskId=K1&host=HOST-01'),
        ($script:origin+'/?restaurantId=R1&kioskId=K1&host=HOST-01'),
        ($script:origin+'/#/onboarding/login/?restaurantId=R1&kioskId=K1&host=HOST-01'),
        ($script:origin+'/?redirect=/#/onboarding/login&restaurantId=R1&kioskId=K1&host=HOST-01'),
        ($validUrl.Replace('https://','http://')),
        ($validUrl.Replace($script:origin,'https://other.example.test'))
    )) {
        $resolved=Resolve-KioskUrl -Url $invalidUrl
        Assert-Inspection (@($resolved.BlockedIssues).Count -gt 0 -and $resolved.URL -ceq $invalidUrl) 'Invalid origin/route accepted or rewritten'
    }
    $missingParameters=Resolve-KioskUrl -Url ($script:origin+'/#/onboarding/login')
    Assert-Inspection (@($missingParameters.BlockedIssues).Count -eq 0 -and @($missingParameters.Missing).Count -eq 3) 'Valid route without parameters was misclassified'
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        New-LauncherFixture; Add-FixtureShortcut $script:batchPath
        $before=Get-FixtureSnapshot
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection ($result.Status -eq 'Pass' -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) 'Valid existing launcher or shortcut changed'
        Assert-Inspection ($result.LauncherValues['URL'] -ceq $script:expectedLauncherUrl -and $result.LauncherValues['Restaurant ID'] -ceq 'R1' -and $result.LauncherValues['KIOSK ID'] -ceq 'K1' -and $result.LauncherValues['Host Name'] -ceq 'HOST-01') 'Display formatting changed the full verification URL or collected identifiers'
        Assert-Inspection ($result.StateHtml.Contains(('URL origin:</span> '+$script:origin+'</div>')) -and $result.StateHtml -notmatch '/#/|restaurantId=|kioskId=|custom=') 'Launcher Findings contains the full URL instead of only its origin'
        $findingLabels=@([regex]::Matches($result.StateHtml,'class="kv-label">([^<]+):</span>') | ForEach-Object {$_.Groups[1].Value})
        $requirement=Get-ReportRequirement ([pscustomobject]@{ItemTitle='Kiosk Launch Architecture';ItemSub='Verified configuration'})
        $requiredLabels=@([regex]::Matches($requirement,'class="kv-label">([^<]+):</span>') | ForEach-Object {$_.Groups[1].Value})
        Assert-Inspection (($findingLabels -join '|') -ceq 'Launcher Path|Restaurant ID|Kiosk ID|Host name|URL origin' -and ($requiredLabels -join '|') -ceq 'Launch Script|Restaurant ID|Kiosk ID|Host name|URL origin') 'Launcher requirements or Findings have incorrect field labels/order'
        Assert-Inspection ($requirement.Contains('Launch Script:</span> Available') -and $requirement.Contains(('URL origin:</span> '+$script:origin))) 'Launcher availability or client-specific origin reference changed'
        Assert-Inspection ($result.StateHtml -notmatch 'Desktop Shortcut|Startup BAT|Launch Script:') 'Extra or outdated launcher Findings fields remain'
        Assert-Inspection ($result.StateHtml.Contains(('Launcher Path:</span> '+[Net.WebUtility]::HtmlEncode($script:launchPath)))) 'Launcher Path value or its HTML escaping changed'
        Assert-Inspection ($result.LauncherValues['Desktop Shortcut'] -ceq 'Available' -and $result.LauncherValues['Startup BAT'] -ceq 'Available') 'Display formatting changed raw file-availability evidence'
        New-LauncherFixture; $before=Get-FixtureSnapshot -ExcludeShortcut
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection (($result.Status -eq 'Pass') -eq $mode) 'Missing shortcut status incorrect'
        Assert-Inspection ($script:saveCalls -eq [int]$mode -and (Get-FixtureSnapshot -ExcludeShortcut) -ceq $before) 'Shortcut creation changed another file'
        if ($mode) { Assert-Inspection ($result.LauncherValues['Desktop Shortcut'] -ceq 'Available') 'Created shortcut availability was lost after verified readback' }
        else { Assert-Inspection ($result.LauncherValues['Desktop Shortcut'] -ceq 'Missing') 'A missing desktop shortcut was presented as available' }
        if ($mode) {
            $again=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
            Assert-Inspection ($again.Status -eq 'Pass' -and $script:saveCalls -eq 1) 'Existing shortcut was recreated'
        }
        New-LauncherFixture; Add-FixtureShortcut 'C:\Wrong target.bat'; $before=Get-FixtureSnapshot
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) 'Incorrect existing shortcut was modified'
        $urlProblems=@('missingHost','oldHostname','conflict','wrongOrigin','wrongRoute','syntax','missingScript')
        foreach ($urlProblem in $urlProblems) {
            New-LauncherFixture
            $text=[KioskTestSource]::ReadAllText($script:launchPath)
            switch ($urlProblem) {
                'missingHost' { $text=$text.Replace('&host=HOST-01','') }
                'oldHostname' { $text=$text.Replace('&host=HOST-01','&hostname=HOST-01') }
                'conflict' { $text=$text.Replace('&host=HOST-01','&host=HOST-01&host=OTHER') }
                'wrongOrigin' { $text=$text.Replace($script:origin,'https://other.example.test') }
                'wrongRoute' { $text=$text.Replace('/#/onboarding/login?','/#/other?') }
                'syntax' { $text='function Broken {' }
            }
            [IO.File]::WriteAllText($script:launchPath,$text)
            if ($urlProblem -eq 'missingScript') { [IO.File]::Delete($script:launchPath) }
            $before=Get-FixtureSnapshot
            $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
            if (-not $mode -or $urlProblem -ne 'missingHost') {
                Assert-Inspection ($result.Status -eq 'Fail' -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) "Launcher problem was changed or hidden: $urlProblem"
            } else {
                Assert-Inspection ($result.Status -eq 'Pass' -and $script:saveCalls -eq 1 -and $result.LauncherValues['Host Name'] -ceq 'HOST-01') "Missing host was not repaired in Apply: $urlProblem"
            }
        }
        New-LauncherFixture; [IO.File]::Delete($script:batchPath); $before=Get-FixtureSnapshot -ExcludeShortcut
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection ($result.Status -eq 'Fail' -and -not [IO.File]::Exists($script:batchPath) -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot -ExcludeShortcut) -ceq $before) 'Missing Startup BAT caused shortcut creation or falsely passed'
        Assert-Inspection (-not [IO.File]::Exists($script:shortcutPath) -and $result.LauncherValues['Startup BAT'] -ceq 'Missing. Manual action required.' -and $result.Action -match 'Startup BAT is missing. Manual action required.') 'Missing Startup BAT evidence or manual action was lost'
        New-LauncherFixture; Add-FixtureShortcut $script:batchPath; [IO.File]::Delete($script:batchPath); $before=Get-FixtureSnapshot
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) 'Existing shortcut was changed when its Startup BAT was missing'
        New-LauncherFixture; [IO.File]::WriteAllText($script:batchPath,'@echo off'); $before=Get-FixtureSnapshot
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) 'Unverified Startup target was modified or used for a new shortcut'
        New-LauncherFixture; $script:profileMissing=$true; $before=Get-FixtureSnapshot; $threw=$false
        try { Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01' | Out-Null } catch { $threw=$true }
        Assert-Inspection ($threw -and $script:saveCalls -eq 0 -and (Get-FixtureSnapshot) -ceq $before) 'Missing profile was provisioned'

        Reset-PolicyFixture
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection ($result.Status -eq 'Pass' -and $script:policyWrites -eq 0 -and $script:keyWrites -eq 0) 'Correct existing policy was rewritten'
        Reset-PolicyFixture; $script:registryKeys[$script:edge].Values['TranslateEnabled']=1
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:policyWrites -eq 0 -and $script:registryKeys[$script:edge].Values['TranslateEnabled'] -eq 1) 'Existing different policy was overwritten or incorrectly passed'
        Reset-PolicyFixture; $script:registryKeys[$script:edge].Kinds['TranslateEnabled']='String'
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:policyWrites -eq 0) 'Existing policy of wrong type was changed'
        Reset-PolicyFixture; $script:registryKeys[$script:edge].Values.Remove('TranslateEnabled')
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection (($result.Status -eq 'Pass') -eq $mode) 'Missing policy result incorrect'
        Assert-Inspection ($script:policyWrites -eq [int]$mode -and $script:keyWrites -eq 0) 'Missing-only policy creation changed an existing key'
        if ($mode) { Invoke-BrowserPolicyCheck | Out-Null; Assert-Inspection ($script:policyWrites -eq 1) 'Added policy was rewritten on repeat Apply' }
        Reset-PolicyFixture; $script:registryKeys[$script:allow].Values['2']='https://customer.example.test'; $script:registryKeys[$script:allow].Kinds['2']='String'
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection ($result.Status -eq 'Pass' -and $script:policyWrites -eq 0 -and $script:registryKeys[$script:allow].Values['2'] -eq 'https://customer.example.test') 'Additional allowlist entry was removed or incorrectly failed'
        Assert-Inspection ($result.StateHtml.Contains('Additional allowlist entry 2: https://customer.example.test (preserved)') -and $result.StateHtml -notmatch 'Obsolete') 'Extra permission content was hidden or mislabeled'
        Reset-PolicyFixture; $script:registryKeys.Remove($script:allow); $script:registryKeys.Remove($script:edge)
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection (($result.Status -eq 'Pass') -eq $mode) 'Missing policy keys were not handled correctly'
        Assert-Inspection ($script:keyWrites -eq $(if ($mode) {2} else {0}) -and $script:policyWrites -eq $(if ($mode) {3} else {0})) 'Unexpected policy key/value writes'
        Reset-PolicyFixture; $script:registryKeys[$script:edge].Values['TranslateEnabled']=1; $script:registryKeys[$script:edge].Values.Remove('VisualSearchEnabled')
        $result=Invoke-BrowserPolicyCheck
        Assert-Inspection ($result.Status -eq 'Fail' -and $script:policyWrites -eq [int]$mode -and $script:registryKeys[$script:edge].Values['TranslateEnabled'] -eq 1) 'Mixed missing and existing policy values were mishandled'
    }
    $script:ApplyChanges=$true
    New-LauncherFixture; $script:badReadback=$true; $before=Get-FixtureSnapshot
    $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' -Hostname 'HOST-01'
    Assert-Inspection ($result.Status -eq 'Fail' -and $script:saveCalls -eq 1 -and $script:removedShortcuts -eq 1 -and (Get-FixtureSnapshot) -ceq $before) 'Failed shortcut readback did not restore its prior absence'
    Write-Output "PASS: $sourceName Audit/Apply read-only launcher/profile/Startup/URL, missing-only desktop shortcut, byte preservation, rollback and missing-only policies"
}

} finally {$env:COMPUTERNAME=$originalFixtureComputerName}
