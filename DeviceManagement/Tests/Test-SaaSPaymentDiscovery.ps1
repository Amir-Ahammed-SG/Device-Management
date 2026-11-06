# Extract discovery functions and the discovery boundary only; never run device checks.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')

$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$path=Join-Path $projectRoot 'SaaSKioskThoroughCheckScript.ps1'
$tokens=$null; $errors=$null
$ast=[KioskTestSource]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($name in @('Find-KioskPaymentServices','Select-PaymentPrimary')){
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $definition){throw ('Missing function: '+$name)}
    . ([scriptblock]::Create($definition.Extent.Text))
}
function New-ServiceFixture {
    param([string]$Name,[string]$State='Running',[string]$DisplayName='Fixture',[string]$PathName='C:\Fixture\Other.exe',[version]$Version='1.0')
    [pscustomobject]@{Name=$Name;State=$State;DisplayName=$DisplayName;PathName=$PathName;Version=$Version}
}
function Assert-Discovery {
    param([object[]]$Services,[string[]]$Expected,[string]$Case)
    $actual=@(Find-KioskPaymentServices -Services $Services | ForEach-Object {$_.Name})
    if(($actual -join '|') -cne ($Expected -join '|')){throw ($Case+': unexpected candidates: '+($actual -join ', '))}
}
$preferred=New-ServiceFixture 'AspPaymentSaaSProd'
$variant=New-ServiceFixture 'Custom-sAaSpRoD-02'
$stopped=New-ServiceFixture 'OlderSaaSProd' 'Stopped'
$fallback=New-ServiceFixture 'AspPaymentOther' -Version '9.0'
$stoppedFallback=New-ServiceFixture 'AspPaymentStopped' 'Stopped'
$byPath=New-ServiceFixture 'CustomExecutableService' -PathName '"C:\Payment\Kiosk Payment Middleware.exe" --service'
$byDisplay=New-ServiceFixture 'CustomDisplayService' -DisplayName 'Payment Middleware'
$unrelated=New-ServiceFixture 'UnrelatedService'
Assert-Discovery @($preferred,$fallback,$stoppedFallback,$unrelated) @($preferred.Name) 'Preferred running service wins'
Assert-Discovery @($variant,$fallback) @($variant.Name) 'Case-insensitive SaaSProd variant wins'
Assert-Discovery @($preferred,$stopped,$fallback) @($preferred.Name,$stopped.Name) 'Retain stopped preferred candidates'
Assert-Discovery @($stopped,$fallback,$stoppedFallback,$byPath,$byDisplay,$unrelated) @($fallback.Name,$byPath.Name,$byDisplay.Name) 'Only running middleware fallbacks'
Assert-Discovery @($fallback,$stoppedFallback) @($fallback.Name) 'No preferred candidate'
Assert-Discovery @($stopped,$stoppedFallback,$unrelated) @($stopped.Name) 'Retain stopped preferred when no running fallback'
Assert-Discovery @($stoppedFallback,$unrelated) @() 'Ignore stopped unrelated middleware'
Assert-Discovery @() @() 'Empty service collection'
function Get-PaymentExecutableVersion { param($Service) $Service.Version }
$primary=Select-PaymentPrimary @(Find-KioskPaymentServices -Services @($preferred,$stopped,$fallback))
if($primary.Name -cne $preferred.Name){throw 'Running preferred service was not selected.'}
$ambiguous=$false
try{[void](Select-PaymentPrimary @(Find-KioskPaymentServices -Services @($preferred,$variant)))}
catch{if($_.Exception.Message -notmatch 'primary selection requires review'){throw}; $ambiguous=$true}
if(-not $ambiguous){throw 'Equal-version preferred candidates must require review.'}

# Execute the actual discovery try block with a fake inventory and fail-closed prompts.
$discovery=$ast.Find({param($n)
    $n -is [Management.Automation.Language.TryStatementAst] -and
    $n.Body.Statements.Count -gt 1 -and $n.Body.Statements[0].Extent.Text -like '$allServices = @(Get-CimInstance*'
},$true)
if(-not $discovery){throw 'Cannot identify payment discovery boundary.'}
function Get-CimInstance { param($ClassName) if($ClassName -ne 'Win32_Service'){throw 'Unexpected inventory query'}; $script:inventory }
function Test-CanApply { $false }
function Read-Host { throw 'Audit discovery must not prompt.' }
foreach($scenario in @(@($preferred,$fallback),@($stopped,$fallback),@($unrelated))){
    $script:inventory=$scenario
    $paymentServices=@(); $paymentDiscoveryError=$null
    . ([scriptblock]::Create($discovery.Extent.Text))
    if($paymentDiscoveryError){throw $paymentDiscoveryError}
    $expected=@(Find-KioskPaymentServices -Services $scenario | ForEach-Object {$_.Name})
    if((@($paymentServices | ForEach-Object {$_.Name}) -join '|') -cne ($expected -join '|')){throw 'Audit boundary bypassed SaaS discovery.'}
}
Write-Output 'PASS: SaaSProd preference, case-insensitive variants, running middleware fallbacks, stopped/empty inventory, primary ambiguity, and Audit discovery integration.'
