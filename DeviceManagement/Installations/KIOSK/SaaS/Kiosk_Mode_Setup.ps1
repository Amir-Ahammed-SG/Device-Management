# This file helps to set up Microsoft Edge in a Kiosk-mode like environment.
 
# Step 1: Setup a Local User (No Microsoft Account), name = SELISE-KIOSK
 
# Step 2: Launch Powershell as Admin (Win+X -> Powershell (Administrator)
 
# Step 3: Copy and paste the whole content of this file in the Powershell and press Enter-PSHostProcess
#			--> This will Enable Auto-Login for the SELISE-KIOSK User, Disable Gestures in Edge, create Script Directory, create Launch Script and create a batch file
 
# Please check the Powershell output for errors
 
 
function Read-SaaSKioskUser {
    $users=@(Get-LocalUser -ErrorAction Stop)
    $suggestion=$null
    foreach($preferred in @('SELISE-KIOSK','SELISE')) {
        $match=@($users | Where-Object { $_.Name -ieq $preferred })
        if($match.Count -eq 1) { $suggestion=[string]$match[0].Name; break }
    }
    if(-not $users.Count) { throw 'No existing local account could be found. Create the kiosk account before running setup.' }
    while($true) {
        $prompt=if($suggestion) { 'Kiosk User ['+$suggestion+']' } else { 'Kiosk User' }
        $answer=([string](Read-Host $prompt)).Trim()
        if(-not $answer) { $answer=$suggestion }
        $match=@($users | Where-Object { $_.Name -ieq $answer })
        if($match.Count -eq 1 -and $match[0].Enabled) { return [string]$match[0].Name }
        Write-Host 'Enter an existing, enabled local account. No account will be created or enabled.' -ForegroundColor Yellow
    }
}

function Read-SaaSKioskRequiredId {
    param([Parameter(Mandatory=$true)][string]$Label)
    while($true) {
        $answer=([string](Read-Host $Label)).Trim()
        if($answer -match '^[A-Za-z0-9._~-]+$') { return $answer }
        Write-Host ($Label+' is required. Use letters, numbers, dots, underscores or dashes without spaces.') -ForegroundColor Yellow
    }
}

function Test-SaaSKioskHostName {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253) { return $false }
    foreach($label in $Value.Split('.')) {
        if($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') { return $false }
    }
    return $true
}

function Get-SaaSKioskFullHostname {
    # DNSHostName preserves the full active hostname, including names longer than 15 characters.
    $systems=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property DNSHostName -ErrorAction Stop)
    if($systems.Count -ne 1) { throw 'The full Windows DNS hostname could not be read.' }
    $name=([string]$systems[0].DNSHostName).Trim()
    if($name.Length -lt 1 -or $name.Length -gt 63 -or $name -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') {
        throw 'The full Windows DNS hostname could not be verified.'
    }
    return $name
}

function Read-SaaSKioskHostName {
    $suggestion=$null
    try { $suggestion=Get-SaaSKioskFullHostname }
    catch { Write-Host 'Full Windows hostname could not be detected. Enter the full hostname manually.' -ForegroundColor Yellow }
    if(-not (Test-SaaSKioskHostName $suggestion)) { $suggestion=$null }
    while($true) {
        $prompt=if($suggestion) { 'Hostname ['+$suggestion+']' } else { 'Hostname' }
        $answer=([string](Read-Host $prompt)).Trim()
        if(-not $answer) { $answer=$suggestion }
        if(Test-SaaSKioskHostName $answer) { return $answer }
        Write-Host 'Enter a valid hostname, or press Enter to confirm the suggested name.' -ForegroundColor Yellow
    }
}

function Assert-SaaSKioskSetupInputs {
    param([Parameter(Mandatory=$true)][string]$UserName)
    if(-not (Test-Path -LiteralPath ('C:\Users\'+$UserName) -PathType Container)) {
        throw ('The existing setup requires an initialized profile at C:\Users\'+$UserName+'. Sign in to that account once before running setup.')
    }
    if(-not (Test-Path -LiteralPath 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' -PathType Leaf)) {
        throw 'Microsoft Edge was not found at the path used by this setup script.'
    }
}

$KioskUser = Read-SaaSKioskUser
$restaurantId = Read-SaaSKioskRequiredId -Label 'Restaurant ID'
$kioskId = Read-SaaSKioskRequiredId -Label 'Kiosk ID'
$HostName = Read-SaaSKioskHostName
Assert-SaaSKioskSetupInputs -UserName $KioskUser
$URL = "https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=$restaurantId&kioskId=$kioskId&host=$HostName" # only change if SaaS Url installation is needed (https://kiosk.ordermonkey.com)
$EdgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


# Enable Auto Login
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $RegPath -Name "DefaultUserName" -Value $KioskUser
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value ""
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1"

# Block Browser Pop-Ups to ensure smooth operation
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls" /v "1" /t REG_SZ /d "https://kiosk.ordermonkey.com" /f
 
# Disable Swipe Gestures (Left-Right, Right-Left, Three-Finger, Four-Finger)
$EdgeUIRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
if (!(Test-Path $EdgeUIRegPath)) { New-Item -Path $EdgeUIRegPath -Force | Out-Null }
Set-ItemProperty -Path $EdgeUIRegPath -Name "AllowEdgeSwipe" -Type DWord -Value 0
 
$TouchRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"
if (!(Test-Path $TouchRegPath)) { New-Item -Path $TouchRegPath -Force | Out-Null }
Set-ItemProperty -Path $TouchRegPath -Name "MultiFingerSwipeEnabled" -Type DWord -Value 0
Set-ItemProperty -Path $TouchRegPath -Name "ThreeFingerSlideEnabled" -Type DWord -Value 0
Set-ItemProperty -Path $TouchRegPath -Name "FourFingerSlideEnabled" -Type DWord -Value 0
 
# Disable Visual Search Icon in Edge
$EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (!(Test-Path $EdgePolicyPath)) { New-Item -Path $EdgePolicyPath -Force | Out-Null }
Set-ItemProperty -Path $EdgePolicyPath -Name "VisualSearchEnabled" -Type DWord -Value 0
 
# Disable Edge Translation Prompt
Set-ItemProperty -Path $EdgePolicyPath -Name "TranslateEnabled" -Type DWord -Value 0
 
# Restart Explorer to Apply Gesture & Translation Settings
Stop-Process -Name explorer -Force
Start-Process explorer.exe
 
# Create Kiosk Script Directory
$ScriptDir = "C:\Users\$KioskUser\Scripts"
if (-not (Test-Path $ScriptDir)) {
    New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null
}
 
# Create Kiosk Launch Script
$KioskScriptPath = Join-Path $ScriptDir "LaunchKiosk.ps1"
$KioskScriptContent = @"
Start-Process -FilePath '$EdgePath' -ArgumentList '--kiosk $URL --edge-kiosk-type=fullscreen --no-first-run --disable-pinch --disable-features=msEdgeSwipe' -WindowStyle Maximized
"@
$KioskScriptContent | Set-Content -Path $KioskScriptPath
 
# Create Startup Folder and Add Batch File
$StartupFolder = "C:\Users\$KioskUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
if (-not (Test-Path $StartupFolder)) {
    New-Item -ItemType Directory -Path $StartupFolder -Force | Out-Null
}
 
$BatchFilePath = Join-Path $StartupFolder "LaunchKiosk.bat"
$BatchFileContent = "powershell.exe -ExecutionPolicy Bypass -File `"$KioskScriptPath`""
$BatchFileContent | Set-Content -Path $BatchFilePath
 
Write-Host "Setup complete. The system will auto-login as '$KioskUser' and launch Microsoft Edge in kiosk mode at: $URL"

