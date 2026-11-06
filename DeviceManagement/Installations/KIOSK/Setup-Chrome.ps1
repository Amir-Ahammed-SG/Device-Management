# Shared Chrome kiosk setup. Run in an elevated 64-bit Windows PowerShell 5.1.
# Chrome must already be installed. This replaces this account's LaunchKiosk startup target.
# Browser kiosk mode is fullscreen; it does not configure Windows Assigned Access.
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param([switch]$PassThru,[Parameter(Mandatory=$true)][ValidateSet('SaaS','Subway')][string]$ClientType,[hashtable]$ClientSettings)
$ErrorActionPreference='Stop'
if(-not $ClientSettings){
    $projectRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $projectRoot 'Core\KioskClient.psm1') -Scope Local -ErrorAction Stop
    $ClientSettings=Get-KioskClientSettings -ClientType $ClientType -ProjectRoot $projectRoot
}
if($ClientSettings.ClientType -cne $ClientType){throw 'Kiosk setup client does not match its configuration.'}

function Test-ChromeKioskAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-ChromeKioskUser {
    $users=@(Get-LocalUser -ErrorAction Stop)
    $suggestion=$null
    foreach($preferred in @('SELISE-KIOSK','SELISE')) {
        $match=@($users | Where-Object { $_.Name -ieq $preferred })
        if($match.Count -eq 1) { $suggestion=[string]$match[0].Name; break }
    }
    if(-not $users.Count) { throw 'No existing local account could be found. Create the kiosk account before running setup.' }
    while($true) {
        $prompt=if($suggestion) {
            Write-Host 'Press Enter to keep it, or type another existing Windows username.' -ForegroundColor Gray
            'Kiosk User ['+$suggestion+']'
        } else { 'Kiosk User' }
        $answer=([string](Read-Host $prompt)).Trim()
        if(-not $answer) { $answer=$suggestion }
        $match=@($users | Where-Object { $_.Name -ieq $answer })
        if($match.Count -eq 1 -and $match[0].Enabled) { return [string]$match[0].Name }
        Write-Host 'Enter an existing, enabled local account. No account will be created or enabled.' -ForegroundColor Yellow
    }
}

function Read-ChromeKioskRequiredId {
    param([Parameter(Mandatory=$true)][string]$Label)
    while($true) {
        $answer=([string](Read-Host $Label)).Trim()
        if($answer -match '^[A-Za-z0-9._~-]+$') { return $answer }
        Write-Host ($Label+' is required. Use letters, numbers, dots, underscores or dashes without spaces.') -ForegroundColor Yellow
    }
}

function Test-ChromeKioskHostName {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253) { return $false }
    foreach($label in $Value.Split('.')) {
        if($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') { return $false }
    }
    return $true
}

function Get-ChromeKioskFullHostname {
    # DNSHostName preserves the full active hostname, including names longer than 15 characters.
    $systems=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property DNSHostName -ErrorAction Stop)
    if($systems.Count -ne 1) { throw 'The full Windows DNS hostname could not be read.' }
    $name=([string]$systems[0].DNSHostName).Trim()
    if($name.Length -lt 1 -or $name.Length -gt 63 -or $name -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') {
        throw 'The full Windows DNS hostname could not be verified.'
    }
    return $name
}

function Read-ChromeKioskHostName {
    $suggestion=$null
    try { $suggestion=Get-ChromeKioskFullHostname }
    catch { Write-Host 'Full Windows hostname could not be detected. Enter the full hostname manually.' -ForegroundColor Yellow }
    if(-not (Test-ChromeKioskHostName $suggestion)) { $suggestion=$null }
    while($true) {
        $prompt=if($suggestion) {
            Write-Host 'Press Enter to keep it, or type a different hostname.' -ForegroundColor Gray
            'Hostname ['+$suggestion+']'
        } else { 'Hostname' }
        $answer=([string](Read-Host $prompt)).Trim()
        if(-not $answer) { $answer=$suggestion }
        if(Test-ChromeKioskHostName $answer) { return $answer }
        Write-Host 'Enter a valid hostname, or press Enter to confirm the suggested name.' -ForegroundColor Yellow
    }
}



function Read-ChromeKioskFile {
    param([string]$Path)
    return ,([IO.File]::ReadAllBytes($Path))
}
function Write-ChromeKioskFile {
    param([string]$Path,[byte[]]$Bytes)
    [IO.File]::WriteAllBytes($Path,$Bytes)
}
function Get-ChromeKioskRegistryState {
    param([string]$Path,[string]$Name)
    if(Test-Path -LiteralPath $Path) {
        $key=Get-Item -LiteralPath $Path
        if($key.GetValueNames() -contains $Name) {
            return @{Exists=$true;Value=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);Type=$key.GetValueKind($Name).ToString()}
        }
    }
    return @{Exists=$false;Value=$null;Type=$null}
}
function Set-ChromeKioskRegistryValue {
    param([string]$Path,[string]$Name,$Value,[string]$Type)
    if(-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

if($WhatIfPreference) { Write-Host 'WhatIf: Chrome kiosk setup would collect inputs and replace the selected account kiosk launcher. No changes made.'; return }
if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run setup from 64-bit Windows PowerShell 5.1.'
}
if(-not (Test-ChromeKioskAdministrator)) { throw 'Run setup from an Administrator terminal.' }
$KioskUser=Read-ChromeKioskUser
$restaurantId=Read-ChromeKioskRequiredId -Label 'Restaurant ID'
$kioskId=Read-ChromeKioskRequiredId -Label 'Kiosk ID [e.g. KIOSK-01]'
$HostName=Read-ChromeKioskHostName
$ProfilePath='C:\Users\'+$KioskUser
if(-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { throw ('Sign in to '+$KioskUser+' once first. The required profile is missing: '+$ProfilePath) }
$ChromePath=$null
foreach($candidate in @('C:\Program Files\Google\Chrome\Application\chrome.exe','C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',(Join-Path $ProfilePath 'AppData\Local\Google\Chrome\Application\chrome.exe'))) {
    if(Test-Path -LiteralPath $candidate -PathType Leaf) { $ChromePath=$candidate; break }
}
if(-not $ChromePath) { throw 'Google Chrome was not found in Program Files or the selected kiosk user profile. Install Chrome before running setup.' }
$Origin=$ClientSettings.Origin
$URL=$Origin+$ClientSettings.OnboardingPath+"?restaurantId=$restaurantId&kioskId=$kioskId&host=$HostName"
$RegPath='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$password=Get-ChromeKioskRegistryState $RegPath 'DefaultPassword'
$oldUser=Get-ChromeKioskRegistryState $RegPath 'DefaultUserName'
if($password.Exists -and [string]$password.Value -ne '' -and [string]$oldUser.Value -ine $KioskUser) {
    throw 'Existing auto-login credentials belong to another account. Configure auto-login for the kiosk account separately before setup.'
}
$ChromePolicyPath='HKLM:\SOFTWARE\Policies\Google\Chrome'
$NetworkPolicyPath=$ChromePolicyPath+'\LocalNetworkAccessAllowedForUrls'
# Keep existing allowlist entries. Reuse the origin if present, otherwise use a free numeric slot.
$NetworkValueName=$null
$networkNames=@()
if(Test-Path -LiteralPath $NetworkPolicyPath) { $networkNames=@((Get-Item -LiteralPath $NetworkPolicyPath).GetValueNames()) }
foreach($name in $networkNames) {
    if([string](Get-ChromeKioskRegistryState $NetworkPolicyPath $name).Value -eq $Origin) { $NetworkValueName=[string]$name; break }
}
if(-not $NetworkValueName) {
    for($index=1; $index -le 10000; $index++) {
        if($networkNames -notcontains [string]$index) { $NetworkValueName=[string]$index; break }
    }
}
if(-not $NetworkValueName) { throw 'No free Chrome local network allowlist slot was found.' }
$settings=@(
    @{Path=$RegPath;Name='DefaultUserName';Value=$KioskUser;Type='String'},
    @{Path=$RegPath;Name='DefaultDomainName';Value=$env:COMPUTERNAME;Type='String'},
    @{Path=$RegPath;Name='AutoAdminLogon';Value='1';Type='String'},
    @{Path=$ChromePolicyPath;Name='TranslateEnabled';Value=0;Type='DWord'},
    @{Path=$NetworkPolicyPath;Name=$NetworkValueName;Value=$Origin;Type='String'}
)
# Preserve an existing DefaultPassword. A missing value uses the original passwordless-account setup.
if(-not $password.Exists) { $settings+=@{Path=$RegPath;Name='DefaultPassword';Value='';Type='String'} }
$ScriptDir=Join-Path $ProfilePath 'Scripts'
$KioskScriptPath=Join-Path $ScriptDir 'LaunchKiosk.ps1'
$StartupFolder=Join-Path $ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$BatchFilePath=Join-Path $StartupFolder 'LaunchKiosk.bat'
# A separate Chrome profile prevents an ordinary running Chrome instance from consuming kiosk flags.
$ChromeProfile=Join-Path $ScriptDir 'ChromeKioskProfile'
$arguments='--kiosk "'+$URL+'" --incognito --no-first-run --no-default-browser-check --disable-pinch --overscroll-history-navigation=0 --user-data-dir="'+$ChromeProfile+'"'
$KioskScriptContent="Start-Process -FilePath '"+$ChromePath.Replace("'","''")+"' -ArgumentList '"+$arguments.Replace("'","''")+"' -WindowStyle Maximized`r`n"
$BatchFileContent="@echo off`r`nsetlocal DisableDelayedExpansion`r`nchcp 65001 >nul`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$KioskScriptPath.Replace('%','%%')+'"'+"`r`n"
# Windows PowerShell 5.1 needs a BOM for non-ASCII launcher paths; CMD needs a BOM-free BAT.
$encoding=New-Object Text.UTF8Encoding($true)
$batchEncoding=New-Object Text.UTF8Encoding($false)
$files=@(
    @{Path=$KioskScriptPath;Bytes=([byte[]]($encoding.GetPreamble()+$encoding.GetBytes($KioskScriptContent)))},
    @{Path=$BatchFilePath;Bytes=$batchEncoding.GetBytes($BatchFileContent)}
)
$directories=@($ScriptDir,$StartupFolder)
$CreateDesktopShortcut=$true
if($CreateDesktopShortcut) {
    $DesktopPath=Join-Path $ProfilePath 'Desktop'
    $ShortcutPath=Join-Path $DesktopPath 'LaunchKiosk.lnk'
    $directories+=$DesktopPath
    # Check COM availability before changing the system.
    $shortcutShell=New-Object -ComObject WScript.Shell
}
# Snapshot every existing value and file before the first write. Snapshots stay in memory.
$registryBackup=@($settings | ForEach-Object { @{Path=$_.Path;Name=$_.Name;State=(Get-ChromeKioskRegistryState $_.Path $_.Name)} })
$fileBackup=@($files | ForEach-Object { @{Path=$_.Path;Exists=(Test-Path -LiteralPath $_.Path -PathType Leaf);Bytes=$null} })
if($CreateDesktopShortcut) { $fileBackup+=@{Path=$ShortcutPath;Exists=(Test-Path -LiteralPath $ShortcutPath -PathType Leaf);Bytes=$null} }
foreach($file in $fileBackup) { if($file.Exists) { $file.Bytes=Read-ChromeKioskFile $file.Path } }
if(-not $PSCmdlet.ShouldProcess($KioskUser,('Configure '+$ClientType+' Chrome kiosk startup and auto-login'))) { return }
try {
    foreach($setting in $settings) { Set-ChromeKioskRegistryValue @setting }
    foreach($directory in $directories) {
        if(-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    foreach($file in $files) { Write-ChromeKioskFile $file.Path $file.Bytes }
    if($CreateDesktopShortcut) {
        $shortcut=$shortcutShell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath=$BatchFilePath
        $shortcut.WorkingDirectory=$StartupFolder
        $shortcut.WindowStyle=7
        $shortcut.Description='Launch Chrome Kiosk Mode'
        $shortcut.Save()
        $saved=$shortcutShell.CreateShortcut($ShortcutPath)
        if($saved.TargetPath -ine $BatchFilePath -or $saved.WorkingDirectory -ine $StartupFolder -or $saved.WindowStyle -ne 7 -or $saved.Description -cne 'Launch Chrome Kiosk Mode') { throw 'Desktop shortcut verification failed.' }
    }
    foreach($setting in $settings) {
        $actual=Get-ChromeKioskRegistryState $setting.Path $setting.Name
        if(-not $actual.Exists -or $actual.Type -ne $setting.Type -or [string]$actual.Value -cne [string]$setting.Value) { throw ('Registry verification failed: '+$setting.Path+' / '+$setting.Name) }
    }
    foreach($file in $files) {
        if([Convert]::ToBase64String((Read-ChromeKioskFile $file.Path)) -cne [Convert]::ToBase64String($file.Bytes)) { throw ('File verification failed: '+$file.Path) }
    }
} catch {
    $setupError=$_
    $rollbackErrors=@()
    foreach($file in $fileBackup) {
        try {
            if($file.Exists) { Write-ChromeKioskFile $file.Path $file.Bytes }
            elseif(Test-Path -LiteralPath $file.Path -PathType Leaf) { Remove-Item -LiteralPath $file.Path -Force }
        } catch { $rollbackErrors+=$_.Exception.Message }
    }
    foreach($item in $registryBackup) {
        try {
            if($item.State.Exists) { Set-ChromeKioskRegistryValue -Path $item.Path -Name $item.Name -Value $item.State.Value -Type $item.State.Type }
            elseif((Get-ChromeKioskRegistryState $item.Path $item.Name).Exists) { Remove-ItemProperty -LiteralPath $item.Path -Name $item.Name }
        } catch { $rollbackErrors+=$_.Exception.Message }
    }
    if($rollbackErrors.Count) { Write-Warning ('Rollback could not restore all items: '+($rollbackErrors -join '; ')) }
    throw $setupError
}
Write-Host "Chrome kiosk setup saved and verified for '$KioskUser': $URL"
Write-Host 'Sign in as the kiosk user to test Chrome, touch gestures, local network access, and auto-login. Existing Chrome kiosk windows must be closed before relaunch.'
if($PassThru) {
    [pscustomobject]@{ChromeKioskSetupCompleted=$true;ClientType=$ClientType;KioskUser=$KioskUser;HostName=$HostName}
}
