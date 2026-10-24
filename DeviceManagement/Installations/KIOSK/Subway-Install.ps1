[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Context)

$ErrorActionPreference='Stop'
function Test-SubwayKioskInstallationAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-SubwayKioskInstallationReadback {
    param([string]$Path,[string]$Name,$Expected)
    $actual=(Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    if($null -eq $actual -or [string]$actual -cne [string]$Expected) { throw ('Setup verification failed: '+$Path+' / '+$Name) }
}
try {
    if($Context.ClientType -ne 'Subway' -or $Context.DeviceType -ne 'KIOSK' -or $Context.Operation -ne 'KioskInstallation' -or $Context.Mode -ne 'Apply') {
        throw 'Unsupported Subway KIOSK Installation selection. No setup was started.'
    }
    if($WhatIfPreference) {
        return [pscustomobject]@{Status='Unavailable';Message='KIOSK Installation was not run in WhatIf mode.';Context=$Context}
    }
    if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Run KIOSK Installation from 64-bit Windows PowerShell 5.1.'
    }
    if(-not (Test-SubwayKioskInstallationAdministrator)) { throw 'Run KIOSK Installation from an Administrator terminal.' }
    $sourceName='DeviceManagement/Installations/KIOSK/Subway/kiosk_mode_setup.ps1'
    $memory=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
    if($memory) {
        if(-not $memory.Files.ContainsKey($sourceName)) { throw 'The embedded Subway KIOSK setup script is missing.' }
        $setupCode=[string]$memory.Files[$sourceName]
    } else {
        $sourcePath=Join-Path $PSScriptRoot 'Subway\kiosk_mode_setup.ps1'
        $setupCode=[IO.File]::ReadAllText($sourcePath)
    }
    # Dot sourcing retains the original script's values for readback. Capture
    # native stdout so the handler returns exactly one structured result.
    $previousNativeExit=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousNativeValue=if($previousNativeExit) { $previousNativeExit.Value } else { $null }
    try {
        $global:LASTEXITCODE=0
        $setupOutput=@(. ([scriptblock]::Create($setupCode)))
        $nativeExit=$global:LASTEXITCODE
    } finally {
        if($previousNativeExit) { $global:LASTEXITCODE=$previousNativeValue }
        else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
    foreach($line in $setupOutput) { Write-Host ([string]$line) }
    if($nativeExit -ne 0) { throw ('The setup registry command returned exit code '+$nativeExit+'.') }
    Assert-SubwayKioskInstallationReadback $RegPath 'DefaultUserName' $KioskUser
    Assert-SubwayKioskInstallationReadback $RegPath 'DefaultPassword' ''
    Assert-SubwayKioskInstallationReadback $RegPath 'AutoAdminLogon' '1'
    Assert-SubwayKioskInstallationReadback 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls' '1' 'https://kiosk.subway.ch'
    Assert-SubwayKioskInstallationReadback $EdgeUIRegPath 'AllowEdgeSwipe' 0
    foreach($name in @('MultiFingerSwipeEnabled','ThreeFingerSlideEnabled','FourFingerSlideEnabled')) {
        Assert-SubwayKioskInstallationReadback $TouchRegPath $name 0
    }
    Assert-SubwayKioskInstallationReadback $EdgePolicyPath 'VisualSearchEnabled' 0
    Assert-SubwayKioskInstallationReadback $EdgePolicyPath 'TranslateEnabled' 0
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
    return [pscustomobject]@{Status='Pass';Message=('Subway KIOSK Installation completed and verified. Kiosk User: '+$KioskUser+'; Hostname: '+$HostName+'.');Context=$Context}
} catch {
    return [pscustomobject]@{Status='Fail';Message=('Subway KIOSK Installation could not complete. '+$_.Exception.Message);Context=$Context}
}
