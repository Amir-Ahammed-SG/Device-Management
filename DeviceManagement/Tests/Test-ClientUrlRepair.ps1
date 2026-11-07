. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Disposable launcher bytes and fake registry keys only; no production mutation.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output/client-url-repair/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-UrlRepair {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function New-UrlPolicyKey {
    param([hashtable]$Values,[hashtable]$Kinds)
    $key=[pscustomobject]@{Values=$Values;Kinds=$Kinds}
    $key | Add-Member ScriptMethod GetValueNames {@($this.Values.Keys)}
    $key | Add-Member ScriptMethod GetValue {param($Name) $this.Values[$Name]}
    $key | Add-Member ScriptMethod GetValueKind {param($Name) $this.Kinds[$Name]}
    $key
}
foreach($client in @('SaaS','Subway')){
    $name=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $tokens=$null;$parseErrors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot $name),[ref]$tokens,[ref]$parseErrors)
    Assert-UrlRepair (-not $parseErrors.Count) 'Shared engine parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $script:realWrite=(Get-Command Write-ThoroughTextChange).ScriptBlock
    $script:realStream=(Get-Command Write-KioskPinchStream).ScriptBlock
    function Write-ThoroughTextChange {
        param($Original,$Text,$BackupFolder)
        Assert-UrlRepair ($Original.Path.StartsWith($fixtureRoot+'\',[StringComparison]::OrdinalIgnoreCase)) 'A fixture attempted a real launcher write'
        $script:writeCalls++
        if($script:hostFail -and $script:writeCalls -eq 2){throw 'Fixture hostname write failure'}
        & $script:realWrite -Original $Original -Text $Text -BackupFolder (Join-Path $fixtureRoot 'backups')
    }
    function Write-KioskPinchStream {
        param($Stream,$Bytes)
        & $script:realStream -Stream $Stream -Bytes $Bytes
        if($script:streamFail){$script:streamFail=$false;throw 'Fixture write/readback failure'}
    }
    function Get-ThoroughDeviceHostname {return 'HOST-01'}
    function Invoke-KioskPinchZoomCheck {param($UserName) New-CheckResult Pass 'Pinch configuration verified.' Disabled}
    function Read-Host {throw 'URL repair must not prompt'}
    function Start-Process {throw 'URL repair must not execute a launcher'}
    function Rename-Computer {throw 'URL repair must not rename Windows'}
    $own=$script:KioskClientSettings.Origin
    $otherName=if($client -eq 'SaaS'){'Subway'}else{'SaaS'}
    $other=$script:KioskClientSettings.ClientOrigins[$otherName]
    foreach($applyMode in @($false,$true)){
        foreach($case in @('wrong-client','matching','unknown','wrong-route','duplicate','dynamic','signed','multiple','syntax','write-failed','hostname-failed','utf16')){
            $script:ApplyChanges=$applyMode;$script:writeCalls=0;$script:streamFail=($case -eq 'write-failed');$script:hostFail=($case -eq 'hostname-failed')
            $origin=if($case -eq 'matching'){$own}elseif($case -eq 'unknown'){'https://unknown.example.test'}else{$other}
            $hostValue=if($case -eq 'hostname-failed'){'OLD-HOST'}else{'HOST-01'}
            $url=$origin+'/#/onboarding/login?restaurantId=R%201&kioskId=KIOSK-01&host='+$hostValue+'&custom=keep%2Fvalue+spaces&empty='
            if($case -eq 'wrong-route'){$url=$url.Replace('/onboarding/login','/other')}
            if($case -eq 'duplicate'){$url+='&kioskId=KIOSK-02'}
            $text='# customer note: '+$other+"`r`n"+'Start-Process msedge.exe -ArgumentList ''--kiosk '+$url+' --edge-kiosk-type=fullscreen --disable-pinch'''+"`r`n"+'throw "Never execute this fixture"'
            if($case -eq 'dynamic'){$text='$url="'+$url.Replace('KIOSK-01','$kiosk')+'"'}
            if($case -eq 'signed'){$text+="`r`n# SIG # Begin signature block"}
            if($case -eq 'multiple'){$text+="`r`n"+'$another='''+$url+''''}
            if($case -eq 'syntax'){$text='function Broken {'}
            $path=Join-Path $fixtureRoot ($client+'-'+$case+'-'+$applyMode+'.ps1')
            $encoding=if($case -eq 'utf16'){[Text.UnicodeEncoding]::new($false,$true,$true)}else{[Text.UTF8Encoding]::new($false,$true)}
            [IO.File]::WriteAllText($path,$text,$encoding)
            $before=[IO.File]::ReadAllBytes($path)
            $result=Repair-LauncherDetails -Path $path -Hostname HOST-01
            $shouldRepair=$applyMode -and $case -in @('wrong-client','utf16')
            $passed=$case -eq 'matching' -or $shouldRepair
            Assert-UrlRepair (($result.Status -eq 'Pass') -eq $passed) ('Wrong launcher outcome: '+$client+'/'+$case+'/'+$applyMode+': '+$result.Action)
            if($shouldRepair){
                $expected=$text.Replace('--kiosk '+$other,'--kiosk '+$own)
                Assert-UrlRepair (([IO.File]::ReadAllText($path,$encoding)) -ceq $expected) 'Origin repair changed parameters, comments or flags'
                $backup=@(Get-ChildItem -LiteralPath (Join-Path $fixtureRoot 'backups') -Filter ([IO.Path]::GetFileName($path)+'.*.bak'))
                Assert-UrlRepair ($backup.Count -eq 1 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup[0].FullName)) -ceq [Convert]::ToBase64String($before)) 'Original launcher backup was not exact'
                $count=$script:writeCalls
                $again=Repair-LauncherDetails -Path $path -Hostname HOST-01
                Assert-UrlRepair ($again.Status -eq 'Pass' -and $script:writeCalls -eq $count) 'Repeated Apply rewrote a correct URL'
            }else{
                Assert-UrlRepair ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($before)) ('Read-only, blocked or failed repair changed the launcher: '+$case)
            }
        }
    }
    $script:edge='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $script:allow=$script:edge+'\LocalNetworkAccessAllowedForUrls'
    $script:gestures='HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI'
    function Reset-UrlPolicy {
        param($Origin,[string]$Kind='String')
        $script:keys=@{}
        $script:keys[$script:allow]=New-UrlPolicyKey @{'1'=$Origin;'2'=$other;'9'='https://customer.example.test'} @{'1'=$Kind;'2'='String';'9'='String'}
        $script:keys[$script:edge]=New-UrlPolicyKey @{TranslateEnabled=0;VisualSearchEnabled=0} @{TranslateEnabled='DWord';VisualSearchEnabled='DWord'}
        $script:keys[$script:gestures]=New-UrlPolicyKey @{AllowEdgeSwipe=0} @{AllowEdgeSwipe='DWord'}
        $script:sets=0;$script:gets=0;$script:registryFail='';$script:denyNext=$false
    }
    function Get-Item {
        [CmdletBinding()]param($LiteralPath)
        Assert-UrlRepair ($script:keys.ContainsKey($LiteralPath)) 'An unexpected registry path was accessed'
        $script:gets++
        if($script:denyNext){$script:denyNext=$false;throw 'Fixture readback denied'}
        if($script:registryFail -eq 'race' -and $script:gets -eq 2){$script:keys[$script:allow].Values['1']='https://customer-new.example.test'}
        $script:keys[$LiteralPath]
    }
    function Test-Path {
        [CmdletBinding()]param($LiteralPath,$PathType)
        if($LiteralPath -like 'HKLM:*'){return $script:keys.ContainsKey($LiteralPath)}
        Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }
    function Set-ItemProperty {
        [CmdletBinding()]param($LiteralPath,$Name,$Value)
        Assert-UrlRepair ($LiteralPath -eq $script:allow -and $Name -ceq '1') 'Repair touched an additional policy or allowlist value'
        $script:sets++
        if($script:registryFail -eq 'denied'){throw 'Fixture write denied'}
        $script:keys[$LiteralPath].Values[$Name]=$Value
        if($script:sets -eq 1){
            switch($script:registryFail){
                'after-write' {throw 'Fixture error after write'}
                'readback' {$script:denyNext=$true}
                'foreign' {$script:keys[$LiteralPath].Values[$Name]='https://customer-new.example.test'}
            }
        }
    }
    function New-ItemProperty {throw 'All fixture policy values already exist'}
    function New-Item {throw 'All fixture policy keys already exist'}
    function Remove-ItemProperty {throw 'No additional allowlist entry may be removed'}
    foreach($applyMode in @($false,$true)){
        foreach($case in @('wrong-client','matching','unknown','wrong-type')){
            $script:ApplyChanges=$applyMode
            $origin=if($case -eq 'matching'){$own}elseif($case -eq 'unknown'){'https://customer.example.test'}else{$other}
            Reset-UrlPolicy $origin $(if($case -eq 'wrong-type'){'ExpandString'}else{'String'})
            $result=Invoke-BrowserPolicyCheck
            $repair=$applyMode -and $case -eq 'wrong-client'
            Assert-UrlRepair (($result.Status -eq 'Pass') -eq ($repair -or $case -eq 'matching')) 'Policy mismatch falsely passed or repair failed'
            Assert-UrlRepair ($script:keys[$script:allow].Values['1'] -ceq $(if($repair){$own}else{$origin}) -and $script:sets -eq [int]$repair) 'Policy repair changed an unapproved value'
            Assert-UrlRepair ($script:keys[$script:allow].Values['2'] -ceq $other -and $script:keys[$script:allow].Values['9'] -ceq 'https://customer.example.test') 'Additional permissions changed'
            if($repair){
                $again=Invoke-BrowserPolicyCheck
                Assert-UrlRepair ($again.Status -eq 'Pass' -and $script:sets -eq 1) 'Repeated Apply rewrote the policy'
                $row=[pscustomobject]@{SectionNumber=2;SectionTitle='Kiosk Application & Policies';ItemTitle='System & Browser Policies';ItemSub='';Shortcut='regedit';FoundStateHtml=$result.StateHtml;Status=$result.Status;ActionTaken=$result.Action}
                Assert-UrlRepair ((Get-ThoroughReportAppliedHtml -Row $row).Contains('<strong>Completed</strong>')) 'Verified URL repair was not recorded as Completed'
                $beforeRow=$row.PSObject.Copy()
                $beforeRow.FoundStateHtml=$beforeRow.FoundStateHtml.Replace($own,$other)
                $beforeRow.Status='Fail';$beforeRow.ActionTaken='Manual review required: Local Network Allowlist.'
                $fix=New-ThoroughReportSnapshot -Rows @($row) -BeforeRows @($beforeRow) -DisplayMode Fix -AfterApply $true
                $fixHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fix.HtmlBase64))
                $component=Get-SettingRenderedComponent $fixHtml 'System & Browser Policies'
                $field=@($component.Fields | Where-Object Setting -EQ 'Local Network Allowlist')[0]
                Assert-UrlRepair ($field.Findings.StartsWith($other) -and $field.Value -ceq $own) 'Fix report lost the actual pre-fix URL or verified Applied URL'
                $snapshot=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -AfterApply $true
                $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
                Assert-UrlRepair ($html.Contains($own) -and -not $html.Contains('<span class="client-url-note">Wrong URL</span>')) 'Final retained a Wrong URL badge after verified repair'
            }
        }
    }
    foreach($failure in @('denied','after-write','readback','race','foreign')){
        $script:ApplyChanges=$true
        Reset-UrlPolicy $other
        $script:registryFail=$failure
        $threw=$false
        try{Set-KioskMainAllowlistOrigin | Out-Null}catch{$threw=$true}
        $expected=if($failure -in @('race','foreign')){'https://customer-new.example.test'}else{$other}
        Assert-UrlRepair ($threw -and $script:keys[$script:allow].Values['1'] -ceq $expected -and $script:keys[$script:allow].Values['2'] -ceq $other) ('Registry failure did not preserve/restore configuration: '+$failure)
    }
    Write-Output ('PASS: '+$client+' Apply-only client URL repair, byte/encoding/parameter preservation, exact backups, repeat safety, signed/ambiguous/unknown rejection, hostname failure rollback, allowlist isolation and write/readback/race recovery.')
}
