[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Context)

$ErrorActionPreference='Stop'
function Test-KioskInstallationAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-KioskInstallationReadback {
    param([string]$Path,[string]$Name,$Expected)
    $actual=(Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    if($null -eq $actual -or [string]$actual -cne [string]$Expected) { throw ('Setup verification failed: '+$Path+' / '+$Name) }
}
try {
    if($Context.ClientType -notin @('SaaS','Subway') -or $Context.DeviceType -ne 'KIOSK' -or $Context.Operation -ne 'KioskInstallation' -or $Context.Mode -ne 'Apply') {
        throw 'Unsupported KIOSK Installation selection. No setup was started.'
    }
    if($WhatIfPreference) {
        return [pscustomobject]@{Status='Unavailable';Message='KIOSK Installation was not run in WhatIf mode.';Context=$Context}
    }
    if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Run KIOSK Installation from 64-bit Windows PowerShell 5.1.'
    }
    if(-not (Test-KioskInstallationAdministrator)) { throw 'Run KIOSK Installation from an Administrator terminal.' }
    $clientMemory=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
    $projectRoot=if($clientMemory){$null}else{Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
    if($clientMemory -and (-not $clientMemory.Configurations -or -not $clientMemory.Configurations.KioskClients)){throw 'The embedded kiosk client configuration is missing.'}
    if(-not $clientMemory){Import-Module (Join-Path $projectRoot 'Core\KioskClient.psm1') -Scope Local -ErrorAction Stop}
    $clientConfiguration=if($clientMemory){$clientMemory.Configurations.KioskClients}else{$null}
    $clientSettings=Get-KioskClientSettings -ClientType $Context.ClientType -ProjectRoot $projectRoot -Configuration $clientConfiguration
    $browser=if($Context.PSObject.Properties['Browser']) { [string]$Context.Browser } else { 'Edge' }
    if($browser -notin @('Edge','Chrome')) { throw 'Choose Microsoft Edge or Google Chrome for KIOSK Installation.' }
    $sourceFile=if($browser -eq 'Chrome') { 'Setup-Chrome.ps1' } else { 'Setup-Edge.ps1' }
    $sourceName='DeviceManagement/Installations/KIOSK/'+$sourceFile
    $memory=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
    if($memory) {
        if(-not $memory.Files.ContainsKey($sourceName)) { throw 'The embedded KIOSK setup script is missing.' }
        $setupCode=[string]$memory.Files[$sourceName]
    } else {
        $sourcePath=Join-Path $PSScriptRoot $sourceFile
        $setupCode=[IO.File]::ReadAllText($sourcePath)
    }
    if($browser -eq 'Chrome') {
        $previousNativeExit=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $previousNativeValue=if($previousNativeExit) { $previousNativeExit.Value } else { $null }
        try {
            $chromeResults=@(& ([scriptblock]::Create($setupCode)) -PassThru -ClientType $Context.ClientType -ClientSettings $clientSettings)
        } finally {
            if($previousNativeExit) { $global:LASTEXITCODE=$previousNativeValue }
            else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        }
        if($chromeResults.Count -ne 1 -or -not $chromeResults[0].PSObject.Properties['ChromeKioskSetupCompleted'] -or $chromeResults[0].ChromeKioskSetupCompleted -ne $true -or $chromeResults[0].ClientType -cne $Context.ClientType -or [string]::IsNullOrWhiteSpace([string]$chromeResults[0].KioskUser) -or [string]::IsNullOrWhiteSpace([string]$chromeResults[0].HostName)) {
            throw 'Chrome setup did not return one verified completion result.'
        }
        return [pscustomobject]@{Status='Pass';Message=($Context.ClientType+' Chrome KIOSK Installation completed and verified. Kiosk User: '+$chromeResults[0].KioskUser+'; Hostname: '+$chromeResults[0].HostName+'.');Context=$Context}
    }
    # Dot sourcing retains the original script's values for readback. Capture
    # native stdout so the handler returns exactly one structured result.
    $previousNativeExit=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousNativeValue=if($previousNativeExit) { $previousNativeExit.Value } else { $null }
    try {
        $global:LASTEXITCODE=0
        $setupOutput=@(. ([scriptblock]::Create($setupCode)) -ClientType $Context.ClientType -ClientSettings $clientSettings)
        $nativeExit=$global:LASTEXITCODE
    } finally {
        if($previousNativeExit) { $global:LASTEXITCODE=$previousNativeValue }
        else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
    foreach($line in $setupOutput) { Write-Host ([string]$line) }
    if($nativeExit -ne 0) { throw ('The setup registry command returned exit code '+$nativeExit+'.') }
    Assert-KioskInstallationReadback $RegPath 'DefaultUserName' $KioskUser
    Assert-KioskInstallationReadback $RegPath 'DefaultPassword' ''
    Assert-KioskInstallationReadback $RegPath 'AutoAdminLogon' '1'
    Assert-KioskInstallationReadback 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls' '1' $clientSettings.Origin
    Assert-KioskInstallationReadback $EdgeUIRegPath 'AllowEdgeSwipe' 0
    foreach($name in @('MultiFingerSwipeEnabled','ThreeFingerSlideEnabled','FourFingerSlideEnabled')) {
        Assert-KioskInstallationReadback $TouchRegPath $name 0
    }
    Assert-KioskInstallationReadback $EdgePolicyPath 'VisualSearchEnabled' 0
    Assert-KioskInstallationReadback $EdgePolicyPath 'TranslateEnabled' 0
    foreach($file in @(@{Path=$KioskScriptPath;Expected=$KioskScriptContent},@{Path=$BatchFilePath;Expected=$BatchFileContent})) {
        if(-not (Test-Path -LiteralPath $file.Path -PathType Leaf) -or ([string](Get-Content -LiteralPath $file.Path -Raw -ErrorAction Stop)).TrimEnd("`r","`n") -cne $file.Expected.TrimEnd("`r","`n")) {
            throw ('Setup file verification failed: '+$file.Path)
        }
    }
    if(-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { throw 'Setup Desktop shortcut could not be verified.' }
    $shortcutReader=New-Object -ComObject WScript.Shell
    $savedShortcut=$shortcutReader.CreateShortcut($ShortcutPath)
    if([string]$savedShortcut.TargetPath -ine $BatchFilePath -or [string]$savedShortcut.WorkingDirectory -ine $StartupFolder -or [int]$savedShortcut.WindowStyle -ne 7 -or [string]$savedShortcut.Description -cne 'Launch Kiosk Mode') {
        throw 'Setup Desktop shortcut configuration could not be verified. Review the existing shortcut manually.'
    }
    return [pscustomobject]@{Status='Pass';Message=($Context.ClientType+' KIOSK Installation completed and verified. Kiosk User: '+$KioskUser+'; Hostname: '+$HostName+'.');Context=$Context}
} catch {
    return [pscustomobject]@{Status='Fail';Message=(($Context.ClientType+' KIOSK Installation could not complete. ')+$_.Exception.Message);Context=$Context}
}
