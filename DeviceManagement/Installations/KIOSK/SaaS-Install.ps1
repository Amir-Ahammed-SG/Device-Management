[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Context)

$ErrorActionPreference='Stop'
function Test-SaaSKioskInstallationAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-SaaSKioskInstallationReadback {
    param([string]$Path,[string]$Name,$Expected)
    $actual=(Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    if($null -eq $actual -or [string]$actual -cne [string]$Expected) { throw ('Setup verification failed: '+$Path+' / '+$Name) }
}
try {
    if($Context.ClientType -ne 'SaaS' -or $Context.DeviceType -ne 'KIOSK' -or $Context.Operation -ne 'KioskInstallation' -or $Context.Mode -ne 'Apply') {
        throw 'Unsupported SaaS KIOSK Installation selection. No setup was started.'
    }
    if($WhatIfPreference) {
        return [pscustomobject]@{Status='Unavailable';Message='KIOSK Installation was not run in WhatIf mode.';Context=$Context}
    }
    if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Run KIOSK Installation from 64-bit Windows PowerShell 5.1.'
    }
    if(-not (Test-SaaSKioskInstallationAdministrator)) { throw 'Run KIOSK Installation from an Administrator terminal.' }
    $sourceName='DeviceManagement/Installations/KIOSK/SaaS/Kiosk_Mode_Setup.ps1'
    $memory=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
    if($memory) {
        if(-not $memory.Files.ContainsKey($sourceName)) { throw 'The embedded SaaS KIOSK setup script is missing.' }
        $setupCode=[string]$memory.Files[$sourceName]
    } else {
        $sourcePath=Join-Path $PSScriptRoot 'SaaS\Kiosk_Mode_Setup.ps1'
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
    Assert-SaaSKioskInstallationReadback $RegPath 'DefaultUserName' $KioskUser
    Assert-SaaSKioskInstallationReadback $RegPath 'DefaultPassword' ''
    Assert-SaaSKioskInstallationReadback $RegPath 'AutoAdminLogon' '1'
    Assert-SaaSKioskInstallationReadback 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls' '1' 'https://kiosk.ordermonkey.com'
    Assert-SaaSKioskInstallationReadback $EdgeUIRegPath 'AllowEdgeSwipe' 0
    foreach($name in @('MultiFingerSwipeEnabled','ThreeFingerSlideEnabled','FourFingerSlideEnabled')) {
        Assert-SaaSKioskInstallationReadback $TouchRegPath $name 0
    }
    Assert-SaaSKioskInstallationReadback $EdgePolicyPath 'VisualSearchEnabled' 0
    Assert-SaaSKioskInstallationReadback $EdgePolicyPath 'TranslateEnabled' 0
    foreach($file in @(@{Path=$KioskScriptPath;Expected=$KioskScriptContent},@{Path=$BatchFilePath;Expected=$BatchFileContent})) {
        if(-not (Test-Path -LiteralPath $file.Path -PathType Leaf) -or ([string](Get-Content -LiteralPath $file.Path -Raw -ErrorAction Stop)).TrimEnd("`r","`n") -cne $file.Expected.TrimEnd("`r","`n")) {
            throw ('Setup file verification failed: '+$file.Path)
        }
    }
    return [pscustomobject]@{Status='Pass';Message=('SaaS KIOSK Installation completed and verified. Kiosk User: '+$KioskUser+'; Hostname: '+$HostName+'.');Context=$Context}
} catch {
    return [pscustomobject]@{Status='Fail';Message=('SaaS KIOSK Installation could not complete. '+$_.Exception.Message);Context=$Context}
}
