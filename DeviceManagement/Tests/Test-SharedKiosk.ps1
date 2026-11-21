# Exercise actual shared functions and client isolation with synthetic data.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
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
    $context=New-DeviceManagementContext -ClientType $client -DeviceType KIOSK -Operation KioskInstallation -Mode Apply -RootPath $root
    Assert-Shared ($context.Browser -ceq 'Edge') 'Kiosk installation did not default to Edge.'
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
$ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
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

# Shared-only delivery: no client-specific runtime entry points remain.
$removed=@(
    'SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1',
    'Installations\KIOSK\SaaS-Install.ps1','Installations\KIOSK\Subway-Install.ps1',
    'Installations\KIOSK\SaaS','Installations\KIOSK\Subway',
    'Tools\Restore-ReportLayout.ps1'
)
foreach($path in $removed){
    Assert-Shared (-not (Test-Path -LiteralPath (Join-Path $root $path))) ('Obsolete separate-model entry remains: '+$path)
}
Write-Output 'PASS: shared client configuration, copied settings, isolated runspaces, URLs, service preference, report identity, and shared-only runtime entry points.'
