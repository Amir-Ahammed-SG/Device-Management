. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Function definitions and disposable files only. Never execute a kiosk launcher.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$fixtureRoot=Join-Path $projectRoot ('output/console-kiosk-identity/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-ConsoleIdentity {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    $sourceName=$client
    Set-KioskTestClient -ClientType $client
    $tokens=$null;$parseErrors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-ConsoleIdentity (-not $parseErrors.Count) 'Shared engine failed to parse'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $call=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-ThoroughConsoleHeader'},$true))
    Assert-ConsoleIdentity ($call.Count -eq 1 -and $call[0].Extent.Text.Contains('-KioskId (Get-ThoroughConsoleKioskId)')) 'Header does not collect current kiosk identity before checks'
    function Get-LocalUser {[CmdletBinding()]param() if($script:denyUsers){throw 'Fixture account access denied'}; $script:fixtureUsers}
    function Get-KioskAutoLoginUserName {if($script:denyAuto){throw 'Fixture auto-login access denied'}; $script:autoUser}
    function Get-KioskProfilePath {param($UserName) if($script:denyProfile){throw 'Fixture profile access denied'}; $script:profiles[$UserName]}
    function Read-Host {throw 'Identity display must not prompt'}
    function Invoke-ExistingAccountPolicy {throw 'Identity display must not apply account policy'}
    function Repair-LauncherDetails {throw 'Identity display must not repair a launcher'}
    function Start-Process {throw 'Identity display must not execute a launcher'}
    function Write-Host {[CmdletBinding()]param([object]$Object,[ConsoleColor]$ForegroundColor) $script:lines.Add([string]$Object)}
    $origin=$script:KioskClientSettings.Origin
    foreach($applyMode in @($false,$true)){
        $script:ApplyChanges=$applyMode
        foreach($case in @('single','auto-selected','ambiguous','disabled-sibling','missing','denied-users','denied-profile','denied-auto','syntax','wrong-origin','wrong-route','duplicate-id','empty-id','dynamic','encoded-id')){
            $script:profiles=@{}
            foreach($userName in @('Kiosk A','Kiosk B')){
                $profilePath=Join-Path $fixtureRoot ($client+'-'+$case+'-'+$applyMode+'-'+$userName)
                [void][IO.Directory]::CreateDirectory((Join-Path $profilePath 'Scripts'))
                $script:profiles[$userName]=$profilePath
            }
            $script:fixtureUsers=@([pscustomobject]@{Name='Kiosk A';Enabled=$true})
            $script:autoUser='';$script:denyUsers=$false;$script:denyProfile=$false;$script:denyAuto=$false
            $id=if($case -eq 'encoded-id'){'Kiosk%2D105'}else{'Kiosk-1'}
            $url=$origin+'/#/onboarding/login?restaurantId=R1&kioskId='+$id+'&host=HOST-01'
            switch($case){
                'wrong-origin' {$url=$url.Replace($origin,'https://other.example.test')}
                'wrong-route' {$url=$url.Replace('/onboarding/login','/other')}
                'duplicate-id' {$url+='&kioskId=Kiosk-2'}
                'empty-id' {$url=$url.Replace('kioskId=Kiosk-1','kioskId=')}
                'denied-users' {$script:denyUsers=$true}
                'denied-profile' {$script:denyProfile=$true}
                'denied-auto' {$script:denyAuto=$true}
            }
            $text='Start-Process msedge.exe -ArgumentList ''--kiosk "'+$url+'"'''+"`n"+'throw "A launcher must never execute during identity inspection"'
            if($case -eq 'syntax'){$text='function Broken {'}
            if($case -eq 'dynamic'){$text='$url = "'+$url.Replace('Kiosk-1','$kioskId')+'"'}
            $launcher=Join-Path $script:profiles['Kiosk A'] 'Scripts/LaunchKiosk.ps1'
            [IO.File]::WriteAllText($launcher,$text,[Text.UTF8Encoding]::new($false))
            if($case -in @('auto-selected','ambiguous','disabled-sibling')){
                $script:fixtureUsers+=@([pscustomobject]@{Name='Kiosk B';Enabled=($case -ne 'disabled-sibling')})
                [IO.File]::WriteAllText((Join-Path $script:profiles['Kiosk B'] 'Scripts/LaunchKiosk.ps1'),$text.Replace('Kiosk-1','Kiosk-2'))
                if($case -eq 'auto-selected'){$script:autoUser='Kiosk B'}
            }
            if($case -eq 'missing'){[IO.File]::Delete($launcher)}
            $before=@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
            $actual=Get-ThoroughConsoleKioskId
            $expected=switch($case){'auto-selected'{'Kiosk-2'};'encoded-id'{'Kiosk-105'};{$_ -in @('single','disabled-sibling','denied-auto')}{'Kiosk-1'};default{'Not verified'}}
            Assert-ConsoleIdentity ($actual -ceq $expected) ($client+'/'+$case+' identity was guessed or lost: '+$actual)
            $after=@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
            Assert-ConsoleIdentity ($before -ceq $after -and $script:ApplyChanges -eq $applyMode) 'Header inspection changed a file or Apply mode'
            foreach($mode in @('Audit','Apply','Final')){
                $script:lines=[Collections.Generic.List[string]]::new()
                Write-ThoroughConsoleHeader -Client $client -Device KIOSK -Branch Test -IsApply ($mode -eq 'Apply') -IsFinal ($mode -eq 'Final') -KioskId $actual
                $expectedDevice=switch($expected){'Kiosk-1'{'KIOSK-01'};'Kiosk-2'{'KIOSK-02'};'Kiosk-105'{'KIOSK-105'};default{'KIOSK (number not verified)'}}
                $output=$script:lines -join "`n"
                Assert-ConsoleIdentity ($output.Contains('Device : '+$expectedDevice) -and $output.Contains('Client : '+$client) -and $output.Contains('Branch : Test')) 'Console header lost device number or client context'
            }
        }
    }
    Microsoft.PowerShell.Utility\Write-Host ('PASS: '+$client+' read-only kiosk identity and Audit/Apply/Final header; profile selection, ambiguity, missing/denied/invalid/dynamic launchers and encoded IDs.')
}
