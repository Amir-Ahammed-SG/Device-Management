# Developer/CI tooling only. Not included in a kiosk release.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$policy=Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'ScriptAnalysis\Policy.psd1')
$required=[version]$policy.AnalyzerVersion
if(-not @(Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object Version -eq $required).Count){
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if(-not @(Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Where-Object Version -ge ([version]'2.8.5.201')).Count){
        [void](Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop)
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion $required -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module -Name PSScriptAnalyzer -RequiredVersion $required -Force -ErrorAction Stop
$loaded=Get-Module -Name PSScriptAnalyzer | Where-Object Version -eq $required
if(-not $loaded){throw ('PSScriptAnalyzer '+$required+' was not loaded.')}
Write-Output ('PSScriptAnalyzer '+$required+' is ready. Existing PSGallery trust settings were not changed.')
