# Exercise actual shared functions and compatibility boundaries with synthetic data.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$utf8=New-Object Text.UTF8Encoding($false)
$fixtureRoot=Join-Path $root ('output\shared-kiosk\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
Import-Module (Join-Path $root 'Core\KioskClient.psm1') -Force
$configuration=Import-PowerShellDataFile (Join-Path $root 'Config\KioskClients.psd1')
function Assert-Shared([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
Import-Module (Join-Path $root 'Core\Context.psm1') -Force
foreach($client in @('SaaS','Subway')){
    $context=New-DeviceManagementContext -ClientType $client -DeviceType KIOSK -Operation KioskInstallation -Mode Apply -Browser Edge -RootPath $root
    Assert-Shared ($context.Browser -ceq 'Edge') 'Edge installation context was rejected.'
    foreach($removedBrowser in @('Chrome','Firefox')){
        $rejected=$false
        try{[void](New-DeviceManagementContext -ClientType $client -DeviceType KIOSK -Operation KioskInstallation -Mode Apply -Browser $removedBrowser -RootPath $root)}catch{$rejected=$true}
        Assert-Shared $rejected 'An unsupported browser context was accepted.'
    }
}
foreach($removedPath in @('Installations\KIOSK\Setup-Chrome.ps1','Installations\KIOSK\SaaS\Kiosk_Mode_Setup_Chrome.ps1','Installations\KIOSK\Subway\Kiosk_Mode_Setup_Chrome.ps1')){
    Assert-Shared (-not (Test-Path -LiteralPath (Join-Path $root $removedPath))) 'A removed Chrome installation entry remains.'
}
$copy=Get-KioskClientSettings -ClientType Subway -Configuration $configuration
$copy.Origin='https://fixture.example';$copy.PreferredServiceNames[0]='Changed'
$fresh=Get-KioskClientSettings -ClientType Subway -Configuration $configuration
Assert-Shared ($fresh.Origin -ceq 'https://kiosk.subway.ch' -and $fresh.PreferredServiceNames[0] -ceq 'SubwayLocal') 'Selected settings leaked into the configuration.'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
Assert-Shared (-not $errors.Count) 'Shared check source does not parse.'
$definitions=($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`r`n"
$runtime=[IO.File]::ReadAllText((Join-Path $root 'Deployment\MemoryRuntime.ps1'))
. ([scriptblock]::Create($runtime))
$bundle=@{Files=@{'DeviceManagement/Core/KioskClient.psm1'=[IO.File]::ReadAllText((Join-Path $root 'Core\KioskClient.psm1'))};Configurations=@{KioskClients=$configuration}}
$modeValidation=@($ast.EndBlock.Statements | Where-Object {$_.Extent.Text.StartsWith('if (@($Apply')})
Assert-Shared ($modeValidation.Count -eq 1) 'Cannot identify the shared engine initialization boundary.'
$initialization=$ast.Extent.Text.Substring(0,$modeValidation[0].Extent.StartOffset)
$initialization+='[pscustomobject]@{Client=$script:KioskClientSettings.ClientType;Origin=$script:KioskClientSettings.Origin}|ConvertTo-Json -Compress'
foreach($folder in @('Core','Config')){Copy-Item -LiteralPath (Join-Path $root $folder) -Destination $fixtureRoot -Recurse}
$startupPath=Join-Path $fixtureRoot 'Test-EngineStartup.ps1'
[IO.File]::WriteAllText($startupPath,$initialization,$utf8)
foreach($client in @('SaaS','Subway')){
    $startup=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $startupPath -ClientType $client | ConvertFrom-Json
    Assert-Shared ($LASTEXITCODE -eq 0 -and $startup.Client -ceq $client -and $startup.Origin -ceq $configuration.Clients[$client].Origin) 'Local engine initialization did not load the selected client.'
    $execution=Invoke-DeviceManagementMemoryScript -Code $initialization -Bundle $bundle -RuntimeCode $runtime -Parameters @{ClientType=$client}
    Assert-Shared ($execution.State -eq 'Completed' -and $execution.Errors.Count -eq 0 -and $execution.Output.Count -eq 1) 'Embedded engine initialization failed.'
    $startup=$execution.Output[0]|ConvertFrom-Json
    Assert-Shared ($startup.Client -ceq $client -and $startup.Origin -ceq $configuration.Clients[$client].Origin) 'Embedded engine initialization used another client.'
}
$code='param([string]$ClientType,[string]$Folder)'+"`r`n"+$definitions+@'
$script:KioskClientSettings=Get-KioskClientSettings -ClientType $ClientType -Configuration $DeviceManagementMemoryBundle.Configurations.KioskClients
$valid=$script:KioskClientSettings.Origin+$script:KioskClientSettings.OnboardingPath+'?restaurantId=R1&kioskId=K1&host=HOST-01'
$preferred=if($ClientType -eq 'SaaS'){'CustomSaaSProd42'}else{'SubwayLocal'}
$services=@([pscustomobject]@{Name=$preferred;State='Running';PathName='';DisplayName=''},[pscustomobject]@{Name='AspPaymentForeign';State='Running';PathName='';DisplayName=''})
$candidates=@(Find-KioskPaymentServices -Services $services)
$row=[pscustomobject]@{ItemTitle='Payment Gateway Middleware';ItemSub='Type: Payment Gateway Middleware'}
[pscustomobject]@{
    Client=$script:KioskClientSettings.ClientType
    Report=Get-KioskReportPath -Folder $Folder -Client 'Branch' -Computer 'HOST-01' -IsApply $false -RunId 'Fixture'
    Primary=(Select-PaymentPrimary $candidates).Name
    ValidIssues=@((Resolve-KioskUrl $valid).Issues).Count
    WrongRoute=@((Resolve-KioskUrl ($valid.Replace('/#/onboarding/login?','/#/other?'))).BlockedIssues).Count
    WrongOrigin=@((Resolve-KioskUrl ($valid.Replace($script:KioskClientSettings.Origin,'https://wrong.example'))).BlockedIssues).Count
    Requirement=Get-ReportRequirement $row
}
'@
foreach($client in @('SaaS','Subway','SaaS')){
    $execution=Invoke-DeviceManagementMemoryScript -Code $code -Bundle $bundle -RuntimeCode $runtime -Parameters @{ClientType=$client;Folder=$fixtureRoot}
    Assert-Shared ($execution.State -eq 'Completed' -and $execution.Errors.Count -eq 0 -and $execution.Output.Count -eq 1) ('Shared function runspace failed: '+($execution.Errors | Out-String))
    $result=$execution.Output[0]
    $expected=if($client -eq 'SaaS'){'CustomSaaSProd42'}else{'SubwayLocal'}
    Assert-Shared ($result.Client -ceq $client -and $result.Primary -ceq $expected) 'Client configuration or payment preference crossed clients.'
    Assert-Shared ($result.Report -ceq (Join-Path $fixtureRoot ('Thorough Check Reports - '+$client+' - HOST-01.html'))) 'Client report filename changed.'
    Assert-Shared ($result.ValidIssues -eq 0 -and $result.WrongRoute -gt 0 -and $result.WrongOrigin -gt 0) 'Origin/route validation lost client isolation.'
    Assert-Shared ($result.Requirement.Contains($configuration.Clients[$client].PaymentServiceRequirement)) 'Payment report requirement used another client.'
}
$invalid=Invoke-DeviceManagementMemoryScript -Code $code -Bundle $bundle -RuntimeCode $runtime -Parameters @{ClientType='ViCafe';Folder=$fixtureRoot}
Assert-Shared ($invalid.State -ne 'Completed' -or $invalid.Errors.Count -gt 0) 'Unsupported client was accepted.'
$missing=@{Files=$bundle.Files;Configurations=@{}}
$invalid=Invoke-DeviceManagementMemoryScript -Code $code -Bundle $missing -RuntimeCode $runtime -Parameters @{ClientType='SaaS';Folder=$fixtureRoot}
Assert-Shared ($invalid.State -ne 'Completed' -or $invalid.Errors.Count -gt 0) 'Missing embedded client configuration was accepted.'

# Run old check paths against a harmless substitute engine, including exit propagation.
$stub=@'
param([string]$ClientType,[switch]$AuditOnly,[string]$AgentName,[string]$ClientLocation)
[pscustomobject]@{Client=$ClientType;Audit=[bool]$AuditOnly;Agent=$AgentName;Branch=$ClientLocation}|ConvertTo-Json -Compress
exit 11
'@
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'KioskThoroughCheck.ps1'),$stub,$utf8)
foreach($client in @('SaaS','Subway')){
    $name=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
    $original=[IO.File]::ReadAllText((Join-Path $root $name))
    Assert-Shared (($original -split "`n").Count -lt 60) 'A compatibility launcher contains a duplicated check implementation.'
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $fixtureRoot
    $output=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixtureRoot $name) -AuditOnly -AgentName 'Agent & Name' -ClientLocation 'Branch with spaces'
    $exitCode=$LASTEXITCODE;$result=$output|ConvertFrom-Json
    Assert-Shared ($exitCode -eq 11 -and $result.Client -ceq $client -and $result.Audit -and $result.Agent -ceq 'Agent & Name' -and $result.Branch -ceq 'Branch with spaces') 'Compatibility check parameters or exit code changed.'
}

# Legacy restore records must never replace shared code or turn a wrapper into a full script.
$toolFolder=Join-Path $fixtureRoot 'Tools';$backupFolder=Join-Path $fixtureRoot 'Backups\ReportLayouts'
[void][IO.Directory]::CreateDirectory($toolFolder);[void][IO.Directory]::CreateDirectory($backupFolder)
Copy-Item -LiteralPath (Join-Path $root 'Tools\Restore-ReportLayout.ps1') -Destination $toolFolder
$record=@{Version=1;Id='20261106-legacy-fixture';Clients=@(@{FileName='SaaSKioskThoroughCheckScript.ps1';Changes=@()},@{FileName='SubwayKioskThoroughCheck.ps1';Changes=@()})}
[IO.File]::WriteAllText((Join-Path $backupFolder ($record.Id+'.json')),($record|ConvertTo-Json -Depth 5),$utf8)
$before=(Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'KioskThoroughCheck.ps1')).Hash
$rejected=$false
try{& (Join-Path $toolFolder 'Restore-ReportLayout.ps1') -RestorePoint $record.Id -SourceRoot $fixtureRoot -Confirm:$false}
catch{if($_.Exception.Message -notmatch 'cannot be applied to the shared kiosk engine'){throw};$rejected=$true}
Assert-Shared ($rejected -and (Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'KioskThoroughCheck.ps1')).Hash -ceq $before) 'A legacy restore record was applied to shared code.'
Write-Output 'PASS: shared client configuration, copied settings, isolated runspaces, URLs, service preference, report identity, compatibility arguments/exit codes, and legacy restore guard.'
