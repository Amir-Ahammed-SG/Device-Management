<#
.SYNOPSIS
    Kiosk health audit with an interactive Audit / Apply mode menu.
.DESCRIPTION
    Without mode switches, choose Audit Mode or Apply Mode from the menu.
    -AuditOnly/-WhatIf only read system state. -FinalReport saves a plain configuration report without repairs.
    Apply Mode/-Apply configures the kiosk; existing passwords are never reset.
    POS is reserved and currently rejected before any checks or changes.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter(Mandatory=$true)][ValidateSet('SaaS','Subway')][string]$ClientType,
    [switch]$Apply,
    [switch]$AuditOnly,
    [switch]$FinalReport,
    [ValidateSet('KIOSK', 'POS')][string]$DeviceType = 'KIOSK',
    [string]$ClientLocation,
    [string]$AgentName,
    [string]$RestaurantId,
    [string]$KioskId,
    [string]$KioskHostname,
    [Security.SecureString]$KioskPassword,
    [switch]$ArchitectureRun,
    [string]$ArchitectureResultPath
)

$clientMemory=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
if(-not $clientMemory){Import-Module (Join-Path $PSScriptRoot 'Core\KioskClient.psm1') -Scope Local -ErrorAction Stop}
$clientConfiguration=if($clientMemory){$clientMemory.Configurations.KioskClients}else{$null}
$script:KioskClientSettings=Get-KioskClientSettings -ClientType $ClientType -ProjectRoot $PSScriptRoot -Configuration $clientConfiguration

# BEGIN KIOSK SHARED MODULES
# Dot sourcing preserves script variables and the existing execution/repair gates.
foreach($part in @('Common','Reporting','Launcher','Accounts','Services')){
    $resource='DeviceManagement/Core/Kiosk/'+$part+'.ps1'
    if($clientMemory){
        if(-not $clientMemory.Files.ContainsKey($resource)){throw ('Shared kiosk module is missing: '+$part)}
        . ([scriptblock]::Create([string]$clientMemory.Files[$resource]))
    }else{
        $partPath=Join-Path $PSScriptRoot ('Core\Kiosk\'+$part+'.ps1')
        if(-not [IO.File]::Exists($partPath)){throw ('Shared kiosk module is missing: '+$part)}
        $partTokens=$null;$partErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($partPath,[ref]$partTokens,[ref]$partErrors)
        if($partErrors.Count){throw ('Shared kiosk module failed syntax validation: '+$part)}
        . $partPath
    }
}
# END KIOSK SHARED MODULES
if (@($Apply,$AuditOnly,$FinalReport | Where-Object { $_ }).Count -gt 1) { throw 'Use only one of -Apply, -AuditOnly or -FinalReport.' }
if ($DeviceType -ne 'KIOSK') { throw 'POS setup is not available yet. No checks or changes were performed.' }
if (-not [Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell as Administrator.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run Windows PowerShell as Administrator.'
}

# KioskFunction Get-ThoroughDeviceHostname

# KioskFunction Confirm-KioskApply

do {
$script:AuditRunTimer = [Diagnostics.Stopwatch]::StartNew()
$script:AuditStepTimer = $null
$script:ApplyChanges = $false
$reportHostname = Get-ThoroughDeviceHostname
$reportKioskId = $null
$reportRestaurantId = 'Not detected'
if (-not $Apply -and -not $AuditOnly -and -not $FinalReport -and -not $WhatIfPreference) {
    Write-Host "`n  SELISE | KIOSK SYSTEM CHECK" -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  Select an operation' -ForegroundColor White
    Write-Host ''
    Write-Host '  [1] Audit Report' -ForegroundColor White
    Write-Host '      Review current settings and generate a report.' -ForegroundColor Gray
    Write-Host '      System configuration remains unchanged.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [2] Apply Fix' -ForegroundColor White
    Write-Host '      Apply kiosk settings, verify results and save a report.' -ForegroundColor Gray
    Write-Host ''

    Write-Host ''
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    do {
        $modeChoice = ([string](Read-Host '  Select option')).Trim()
        if ($modeChoice -notin @('1', '2')) {
            Write-Host 'Invalid option. Please enter 1 or 2.' -ForegroundColor Yellow
        }
    } until ($modeChoice -in @('1', '2'))
    if ($modeChoice -eq '2') { $Apply = $true }

    else { $AuditOnly = $true }
}
if ($Apply -and -not $WhatIfPreference) {
    $script:ApplyChanges = Confirm-KioskApply -ErrorAction Stop
}
$runMode = if ($FinalReport) { 'THOROUGH CHECK REPORT' } elseif ($script:ApplyChanges) { 'APPLY' } else { 'AUDIT ONLY' }

$ProgressPreference = 'SilentlyContinue'
$outputFolder = 'C:\Thorough Check'
# Apply mode always writes a report. Audit mode creates the folder only after
# the operator chooses to generate the HTML report.
if ($script:ApplyChanges -and -not (Test-Path -LiteralPath $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
}
$runId = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
# KioskFunction Get-KioskReportPath
$reportPath = Get-KioskReportPath -Folder $outputFolder -Client $ClientLocation -Computer $env:COMPUTERNAME -IsApply $script:ApplyChanges -RunId $runId -IsFinal ([bool]$FinalReport)
$auditRows = [System.Collections.Generic.List[PSObject]]::new()

# KioskFunction Test-CanApply

# KioskFunction Write-ThoroughConsoleLine

# KioskFunction Get-ThoroughReportComponentName

# KioskFunction Format-ThoroughReportFieldLabels


# KioskFunction Format-ThoroughFinalServiceRecovery

# KioskFunction Get-ThoroughReportBlockAlignmentScript

# KioskFunction Format-ThoroughFixFindings

# KioskFunction Test-ThoroughFixReportRow

# KioskFunction Get-ThoroughAuditClientLocation

# KioskFunction Get-ThoroughAuditAgentName

# KioskFunction Get-ThoroughFixAccountReportView

# KioskFunction Read-ThoroughAuditFields

# KioskFunction Expand-ThoroughUnavailableFields

# KioskFunction Get-KioskLaunchTaskReportState

# KioskFunction Get-KioskLaunchTaskHistory

# KioskFunction ConvertTo-ThoroughAuditRows

# KioskFunction Get-ThoroughAuditColumnStyle

# KioskFunction Get-ThoroughAuditHoverScript

# KioskFunction Get-ThoroughSettingRecords

# KioskFunction ConvertTo-ThoroughSettingValue

# KioskFunction ConvertTo-ThoroughSettingRows

# KioskFunction Get-ThoroughSettingColumnStyle

# KioskFunction Get-ThoroughSettingHoverScript


# KioskFunction Get-ThoroughAuditAdditionalHtml

# KioskFunction New-ThoroughReportSnapshot


# KioskFunction New-ThoroughReportBundleHtml

# KioskFunction Read-ThoroughReportBundleState

# KioskFunction Save-ThoroughReportBundle


# KioskFunction ConvertTo-ThoroughFinalReportHtml
# KioskFunction Get-ThoroughReportAppliedHtml

# KioskFunction Get-ThoroughReportTitle

# KioskFunction Get-ThoroughConsoleKioskId

# KioskFunction Write-ThoroughConsoleHeader

# KioskFunction Start-AuditStep

# KioskFunction Write-AuditOperation

# KioskFunction Get-ThoroughConsoleNote

# KioskFunction Add-AuditEntry

# KioskFunction Write-ThoroughConsoleEntry

# KioskFunction Complete-ThoroughConsole


# KioskFunction New-CheckResult

# KioskFunction Format-ReportAction

# KioskFunction New-ReportCommand

# KioskFunction ConvertTo-ReportCommandBoxes

# KioskFunction Get-ThoroughReportCopyScript


# KioskFunction Format-ThoroughReportDateTime

# KioskFunction Format-ThoroughReportDuration

# KioskFunction Format-ThoroughReportTriggerDetails


# KioskFunction Format-ReportState

# KioskFunction Convert-ReportHtmlToTerminalText

# KioskFunction Get-ThoroughPayoutSchedules

# KioskFunction New-ThoroughAppSettingsGroupRow

# KioskFunction Get-ThoroughAppSettingsReportRows

# KioskFunction New-ThoroughPrinterReportRow

# KioskFunction New-ThoroughFirewallReportRow

# KioskFunction ConvertTo-FirewallRuleObservation


# KioskFunction New-ThoroughLegacyServiceReportRow

# KioskFunction Get-ThoroughReportDisplayRows

# KioskFunction ConvertTo-ReportDefinitionHtml

# KioskFunction Get-AccountReportView

# KioskFunction Get-ThoroughFinalKioskAccountRow

# KioskFunction Get-ThoroughFinalAccountRow

# KioskFunction Test-ThoroughFinalAccountReadback

# KioskFunction Get-ThoroughFinalAdministrativeAccountRow

# KioskFunction Get-ThoroughFinalPrinterRow

# KioskFunction Get-ThoroughFinalReportRows

# KioskFunction Get-ThoroughReportHighlightFields

# KioskFunction Get-ThoroughReportCollectedValueState

# KioskFunction Get-ThoroughReportFindingComparison

# KioskFunction Format-ThoroughReportFindingHighlights
# KioskFunction Get-ReportRequirement

# KioskFunction New-ThoroughReportId

# KioskFunction Get-ThoroughReportDeviceLabel

# KioskFunction Test-ThoroughHostname

# KioskFunction Read-ThoroughFixHostname

# KioskFunction Read-ThoroughTextFile

# KioskFunction Write-ThoroughTextChange

# KioskFunction Restore-ThoroughTextChange

# KioskFunction Test-KioskKnownWrongOrigin

# KioskFunction Set-KioskLauncherOrigin

# KioskFunction Set-KioskLauncherHostname

# KioskFunction Get-ZabbixHostnameSetting

# KioskFunction Update-ZabbixServiceReport

# KioskFunction Set-ZabbixDeviceHostname


# KioskFunction Copy-ThoroughObservationRows

# KioskFunction Find-ThoroughExistingBundle

# KioskFunction Get-ThoroughSnapshotObservations

# KioskFunction Get-ThoroughBeforeFindingRow

# KioskFunction Get-ThoroughFixAccountBeforeView

# KioskFunction Test-ThoroughAppSettingsReview


# KioskFunction Read-AuditReportChoice

# KioskFunction Add-ResultEntry

# KioskFunction Add-LauncherReportDetails

# KioskFunction Resolve-KioskUrl





# KioskFunction Get-ThoroughLauncherEdit

# KioskFunction Read-ThoroughLauncherId

# KioskFunction Set-ThoroughUrlParameter

# KioskFunction New-ThoroughLauncherPlan

# KioskFunction Invoke-ThoroughLauncherPlan

# KioskFunction Repair-LauncherDetails

# KioskFunction Get-LocalAccount

# KioskFunction Get-LocalAccountProperties

# KioskFunction Get-LocalAdministratorSidSet

# KioskFunction Get-LocalAccountPrivilege

# KioskFunction Get-AdministrativeLocalAccounts

# KioskFunction New-AccountReportCommand

# KioskFunction New-MissingAccountResult

# KioskFunction Open-ThoroughLocalAccount

# KioskFunction Enable-LocalAccountPasswordFlags

# KioskFunction Invoke-ExistingAccountPolicy


# KioskFunction Get-TargetLocalAccounts

# KioskFunction Join-AccountCheckResults

# KioskFunction Get-KioskAutoLoginUserName

# KioskFunction Get-KioskAccountCheck

# KioskFunction Get-AdministrativeAccountCheck

# KioskFunction Get-KioskProfilePath

# KioskFunction Initialize-KioskProfile

# KioskFunction Test-KioskAutoLogin

# Collect report identity in Audit; Apply reuses the session or saved Audit.
if([string]::IsNullOrWhiteSpace($AgentName) -or $AgentName -eq 'Not provided'){
    if($AuditOnly){
        do {$AgentName=([string](Read-Host 'Agent Name')).Trim()} while([string]::IsNullOrWhiteSpace($AgentName))
    }else{
        $AgentName=Get-ThoroughAuditAgentName -Path $reportPath -ClientType $script:KioskClientSettings.ClientType -ComputerName $env:COMPUTERNAME
        if([string]::IsNullOrWhiteSpace($AgentName)){$AgentName='Not provided'}
    }
}
if([string]::IsNullOrWhiteSpace($ClientLocation) -or $ClientLocation -eq 'Not provided'){
    if($AuditOnly){
        do {$ClientLocation=Read-Host 'Branch Name'} while([string]::IsNullOrWhiteSpace($ClientLocation))
    }else{
        $ClientLocation=Get-ThoroughAuditClientLocation -Path $reportPath -ClientType $script:KioskClientSettings.ClientType -ComputerName $env:COMPUTERNAME
        if([string]::IsNullOrWhiteSpace($ClientLocation)){$ClientLocation='Not provided'}
    }
}

# Resolve one saved bundle by Windows computer identity, including older launcher-based filenames.
$existingBundle=Find-ThoroughExistingBundle -Path $reportPath -ClientType $script:KioskClientSettings.ClientType -ComputerName $env:COMPUTERNAME
if($existingBundle){$reportPath=$existingBundle.Path}
$savedBeforeRows=@()
if($script:ApplyChanges -and $existingBundle){
    $savedBeforeRows=@(Get-ThoroughSnapshotObservations $existingBundle.State.Reports.Audit)
}
$script:ConfirmedLauncherPlan=$null
if($script:ApplyChanges){
    # Select the existing account with mutation disabled. Complete all launcher
    # input validation before any component repair starts.
    $script:ApplyChanges=$false
    try{$preflightAccount=Get-KioskAccountCheck}finally{$script:ApplyChanges=$true}
    if(-not $preflightAccount.Account){throw 'Apply cancelled: a single existing kiosk account must be verified first.'}
    $preflightProfile=Get-KioskProfilePath $preflightAccount.Account.Name
    if(-not $preflightProfile){throw 'Apply cancelled: the existing kiosk profile is unavailable.'}
    $script:ConfirmedLauncherPlan=New-ThoroughLauncherPlan -Path (Join-Path $preflightProfile 'Scripts\LaunchKiosk.ps1') -Restaurant $RestaurantId -Kiosk $KioskId -Hostname $KioskHostname
    $RestaurantId=$script:ConfirmedLauncherPlan.Restaurant
    $KioskId=$script:ConfirmedLauncherPlan.Kiosk
    $KioskHostname=$script:ConfirmedLauncherPlan.Hostname
}
$applyRequested=[bool]$script:ApplyChanges
$beforeApplyRows=@()
$script:BeforeApplyInspection=$false

Write-ThoroughConsoleHeader -Client $script:KioskClientSettings.ClientType -Device $DeviceType -Branch $ClientLocation -IsApply $script:ApplyChanges -IsFinal ([bool]$FinalReport) -KioskId (Get-ThoroughConsoleKioskId)

# Each component reports local failures. A finalizer also saves partial results after unexpected errors.
try {
foreach($inspectOnly in $(if($applyRequested){@($true,$false)}else{@($false)})){
    $script:BeforeApplyInspection=[bool]$inspectOnly
    $script:ApplyChanges=$applyRequested -and -not $inspectOnly
    $auditRows.Clear()
    if($inspectOnly){Write-Host 'Checking current configuration before applying fixes...' -ForegroundColor Cyan}

# =============================================================
# GROUP 1: HARDWARE & PERIPHERALS
# =============================================================
$sec1Num = 1
$sec1Title = 'Hardware & Peripherals'

# KioskFunction Get-PrinterHealth

# KioskFunction Get-ThoroughAppSettingsPrinterInventory

# 1.1 Multi-Printer Discovery
Start-AuditStep 1 'Printer detection, status and document retention'
try {
    Write-AuditOperation 'Waiting for Windows printer discovery...'
    $installedPrinters = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch 'OneNote|PDF|XPS|Fax' })
    Write-AuditOperation 'Reading printer hardware state from Windows CIM...'
    $cimPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)
    if ($installedPrinters.Count -eq 0) { throw 'No physical printer detected. Check connection and printer driver.' }
    foreach ($ptr in $installedPrinters) {
        $pName = $ptr.Name
        $printerAction = 'No changes needed'
        $printerChanges = [Collections.Generic.List[string]]::new()
        $printerStatus = 'Fail'
        $printerState = 'Not verified. Please check manually.'
        $keepPrintedState = 'Not verified. Please check manually.'
        try {
            $cimPrinter = @($cimPrinters | Where-Object { $_.Name -eq $pName }) | Select-Object -First 1
            if (-not $cimPrinter) { throw 'Win32_Printer state is unavailable for this queue.' }
            $health = Get-PrinterHealth -Printer $ptr -CimPrinter $cimPrinter
            $printerState = $health.State
            $keepPrinted = $ptr.KeepPrintedJobs
            if ($null -eq $keepPrinted) { $keepPrinted = $cimPrinter.KeepPrintedJobs }
            if ($null -eq $keepPrinted) { throw 'Cannot read Keep printed documents setting.' }
            $keepPrintedState = if ($keepPrinted) { 'Enabled' } else { 'Disabled' }
            if (-not $keepPrinted -and (Test-CanApply)) {
                Set-Printer -Name ([WildcardPattern]::Escape($pName)) -KeepPrintedJobs $true -ErrorAction Stop
                $ptr = Get-Printer -Name ([WildcardPattern]::Escape($pName)) -ErrorAction Stop
                $keepPrinted = $ptr.KeepPrintedJobs
                if ($null -eq $keepPrinted) { $keepPrintedState = 'Not verified. Please check manually.'; throw 'Cannot verify Keep printed documents setting.' }
                $keepPrintedState = if ($keepPrinted) { 'Enabled' } else { 'Disabled' }
                if (-not $keepPrinted) { throw 'Keep printed documents could not be enabled.' }
                $printerChanges.Add('Enabled Keep printed documents')
            }

            $printerState = $health.State
            if ($health.Healthy -and $keepPrinted) { $printerStatus = 'Pass' }
            if (-not $keepPrinted) { $printerChanges.Add('Enable Keep printed documents in Apply Mode') }
            if ($health.State -in @('Offline','Not available')) { $printerChanges.Add('Check printer connection and availability') }
            elseif ($printerState -in @('Error','Paused')) { $printerChanges.Add('Check printer status manually') }
            if ($printerChanges.Count -gt 0) { $printerAction = $printerChanges -join '; ' }
        } catch {
            $printerAction = $_.Exception.Message
        }
        $printerHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Printer Name'=$pName; 'Printer status'=$printerState; 'Keep printed documents'=$keepPrintedState })
        $printerShortcut = New-ReportCommand @('control printers', ('rundll32 printui.dll,PrintUIEntry /o /n "{0}"' -f $pName))
        Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle $pName -ItemSub 'Type: Receipt / POS Printer' -Shortcut $printerShortcut -FoundStateHtml $printerHtml -Status $printerStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($printerAction))
    }
} catch {
    Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle 'Physical Printers' -ItemSub 'Type: Receipt / Hardware' -Shortcut '<code>control printers</code>' -FoundStateHtml 'Not verified. Please check manually.' -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))
}

# 1.2 PrintService Event Log
Start-AuditStep 2 'PrintService event log'
$logName = 'Microsoft-Windows-PrintService/Operational'
$logStatus = 'Fail'
$logFound = 'Not verified'
try {
    $printLog = Get-WinEvent -ListLog $logName -Force -ErrorAction Stop
    $logAction = 'Operational log verified enabled'
    if (-not $printLog.IsEnabled) {
        if (Test-CanApply) {
            & wevtutil.exe sl $logName /e:true 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wevtutil returned exit code $LASTEXITCODE." }
            $printLog = Get-WinEvent -ListLog $logName -Force -ErrorAction Stop
            $logAction = 'PrintService log enabled and verified'
        } else { $logAction = 'Audit only; enable PrintService log in Apply mode' }
    }
    $logFound = if ($printLog.IsEnabled) { 'Enabled' } else { 'Disabled' }
    if ($printLog.IsEnabled) { $logStatus = 'Pass' }
    elseif (Test-CanApply) { throw 'PrintService log is still disabled after enabling it.' }
} catch { $logAction = "PrintService log check failed: $($_.Exception.Message)" }
Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle 'PrintService Operational Log' -ItemSub 'Type: Event Viewer Channel' -Shortcut '<code>eventvwr.msc</code>' -FoundStateHtml ([System.Net.WebUtility]::HtmlEncode($logFound)) -Status $logStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($logAction))

# =============================================================
# GROUP 2: KIOSK APPLICATION & POLICIES (POS is rejected at entry)
# =============================================================
$sec2Num = 2
$sec2Title = 'Kiosk Application & Policies'
$kioskUser = 'SELISE-KIOSK'





# KioskFunction Test-KioskStartupBatch

# KioskFunction Test-KioskDesktopShortcut

# KioskFunction Verify-KioskLaunchTargets

# KioskFunction Invoke-KioskLauncherConfiguration

# KioskFunction ConvertFrom-KioskEdgeArguments

# KioskFunction Resolve-KioskPinchLiteral

# KioskFunction Get-KioskPinchLaunchState

# KioskFunction Read-KioskPinchStream

# KioskFunction Write-KioskPinchStream

# KioskFunction Invoke-KioskPinchZoomCheck

# KioskFunction Set-KioskMainAllowlistOrigin

# KioskFunction Invoke-BrowserPolicyCheck

# KioskFunction Get-KioskLaunchTaskInventory

# KioskFunction Get-KioskLaunchTaskContext

# KioskFunction Test-KioskLaunchTaskIdentity

# KioskFunction Read-KioskLaunchTaskArguments

# KioskFunction Get-KioskLaunchTaskFields

# KioskFunction Get-KioskLaunchTaskRequirements

# KioskFunction Read-KioskLaunchTaskSnapshot

# KioskFunction Open-KioskLaunchTaskScheduler

# KioskFunction New-KioskLaunchTaskDefinition

# KioskFunction Register-MissingKioskLaunchTask

# KioskFunction Assert-KioskLaunchTaskBaseline

# KioskFunction Get-KioskLaunchTaskCheck

# KioskFunction Invoke-KioskLaunchTaskCheck

$kioskAccount = $null
try {
    Start-AuditStep 3 'SELISE local accounts'
    $accountCheck = Get-KioskAccountCheck
    $kioskAccount = $accountCheck.Account
    if ($null -ne $kioskAccount) { $kioskUser = [string]$kioskAccount.Name }
    Add-ResultEntry $sec2Num $sec2Title 'KIOSK Account' $accountCheck.Result
} catch { Add-ResultEntry $sec2Num $sec2Title 'KIOSK Account' (New-CheckResult 'Fail' $_.Exception.Message 'Local account lookup or property inspection failed; kiosk prerequisites were not verified') }

if ($null -ne $kioskAccount) {
try {
    Start-AuditStep 4 'Kiosk profile and launcher'
    $result = Invoke-KioskLauncherConfiguration -UserName $kioskUser -Restaurant $RestaurantId -Kiosk $KioskId -Hostname $KioskHostname
    if ($result.PSObject.Properties['LauncherValues'] -and -not [string]::IsNullOrWhiteSpace([string]$result.LauncherValues['Restaurant ID'])) { $reportRestaurantId = [string]$result.LauncherValues['Restaurant ID'] }
    if ($result.PSObject.Properties['LauncherValues'] -and $result.LauncherValues['KIOSK ID'] -notin @($null,'','Not detected')) { $reportKioskId = [string]$result.LauncherValues['KIOSK ID'] }
    Add-ResultEntry $sec2Num $sec2Title 'Kiosk Launch Architecture' $result
    $auditRows[-1]|Add-Member NoteProperty ExpectedHostName $(if(Test-CanApply){$KioskHostname}else{Get-ThoroughDeviceHostname})
} catch { Add-ResultEntry $sec2Num $sec2Title 'Kiosk Launch Architecture' (New-CheckResult 'Fail' $_.Exception.Message 'Launcher configuration failed') }

try {
    $profile = Get-KioskProfilePath $kioskUser
    if (-not $profile) { throw 'SELISE-KIOSK Windows profile is not available. Sign in as SELISE-KIOSK once to initialize it.' }
    $startupPath = Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    $startupLauncher = Join-Path $startupPath 'LaunchKiosk.bat'
    $desktopShortcut = Join-Path $profile 'Desktop\Launch Kiosk.lnk'
    $startupLauncherAvailable = Test-Path -LiteralPath $startupLauncher -PathType Leaf -ErrorAction Stop
    $desktopShortcutAvailable = Test-Path -LiteralPath $desktopShortcut -PathType Leaf -ErrorAction Stop
    $startupHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{
        'Location' = $startupPath
        'Startup BAT' = $(if ($startupLauncherAvailable) { [IO.Path]::GetFileName($startupLauncher) } else { 'Missing. Manual action required.' })
        'Desktop Shortcut' = $(if ($desktopShortcutAvailable) { [IO.Path]::GetFileName($desktopShortcut) } else { 'Missing. Manual action required.' })
    })
    $startupStatus = if ($startupLauncherAvailable -and $desktopShortcutAvailable) { 'Pass' } else { 'Fail' }
    $startupAction = if ($startupStatus -eq 'Pass') { 'Startup BAT and kiosk desktop shortcut are available; filenames recorded. No files were changed.' } else { 'Startup BAT or kiosk desktop shortcut is missing. Manual action required. No files were changed.' }
    Add-AuditEntry $sec2Num $sec2Title 'SELISE-KIOSK Startup Folder' 'Type: User Startup' (New-ReportCommand @('explorer.exe "' + $startupPath + '"')) $startupHtml $startupStatus $startupAction
} catch {
    $startupHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Location'='Not verified. Please check manually.'; 'Startup BAT'='Not verified. Please check manually.'; 'Desktop Shortcut'='Not verified. Please check manually.' })
    Add-AuditEntry $sec2Num $sec2Title 'SELISE-KIOSK Startup Folder' 'Type: User Startup' '<code>explorer.exe</code>' $startupHtml 'Fail' ([Net.WebUtility]::HtmlEncode($_.Exception.Message))
}

try {
    Start-AuditStep 5 'Kiosk auto-login'
    $result = Test-KioskAutoLogin -UserName $kioskUser
    Add-ResultEntry $sec2Num $sec2Title 'Kiosk Auto-Login' $result
} catch { Add-ResultEntry $sec2Num $sec2Title 'Kiosk Auto-Login' (New-CheckResult 'Fail' $_.Exception.Message 'Auto-login verification failed') }

Start-AuditStep 6 'System and Edge policies'
try { Add-ResultEntry $sec2Num $sec2Title 'System & Browser Policies' (Invoke-BrowserPolicyCheck -UserName $kioskUser) }
catch { Add-ResultEntry $sec2Num $sec2Title 'System & Browser Policies' (New-CheckResult 'Fail' $_.Exception.Message 'Policy configuration failed') }
} else {
    Write-Verbose 'Kiosk account unavailable: launcher, startup, auto-login and browser-policy checks were omitted.'
}

Invoke-KioskLaunchTaskCheck -UserName $kioskUser -Account $kioskAccount

# =============================================================
# GROUP 3: CORE BACKGROUND SERVICES
# =============================================================
$sec3Num = 3
$sec3Title = 'Core Background Services'
$secAppNum = 5
$secAppTitle = 'AppSettings Check'

# KioskFunction Get-AuditService

# KioskFunction Get-ServiceRecoverySnapshot

# KioskFunction Set-ServiceRecoveryActionPolicy

# KioskFunction Read-ServiceRecoveryPolicy

# KioskFunction Invoke-ServiceRecoveryRepair

# KioskFunction Read-ServiceNoActionRecoveryPolicy

# KioskFunction Invoke-ServiceNoActionRecoveryRepair


# KioskFunction Get-ServiceRecoveryActionTypes

# KioskFunction ConvertFrom-ServiceRecoveryActionTypes

# KioskFunction Get-ServiceRecoveryDetails

# KioskFunction ConvertTo-ServiceFindingHtml


# KioskFunction Invoke-RequiredServiceCheck

# KioskFunction Get-PaymentExecutablePath

# KioskFunction Get-PaymentExecutableVersion

# KioskFunction Get-ThoroughPaymentVersionDetails

# KioskFunction Remove-ThoroughPaymentJsonComments

# KioskFunction ConvertFrom-ThoroughPaymentJson

# KioskFunction Get-ThoroughPaymentConfigValue

# KioskFunction Get-ThoroughServiceEndpointRequirements

# KioskFunction Test-ThoroughPaymentServiceV13

# KioskFunction Update-ThoroughServiceEndpointText

# KioskFunction Set-ThoroughServiceEndpoints

# KioskFunction Find-ThoroughPaymentConfigValues

# KioskFunction Format-ThoroughPaymentAuditValue

# KioskFunction Add-ThoroughPaymentTerminalLines

# KioskFunction Get-ThoroughPaymentConfigurationAuditLines

# KioskFunction ConvertTo-ThoroughPaymentReportHtml

# KioskFunction Select-PaymentPrimary

# KioskFunction Find-KioskPaymentServices

# KioskFunction Invoke-LegacyPaymentServiceCheck

# KioskFunction Read-PaymentTaskScriptText

# KioskFunction Get-PaymentTaskLiteral

# KioskFunction Get-PaymentTaskPowerShellOperations

# KioskFunction Get-PaymentTaskBatchOperations

# KioskFunction Get-PaymentRestartTaskAction

# KioskFunction Get-PaymentRestartTaskSchedule

# KioskFunction Invoke-PaymentRestartTaskCheck


# 3.1 Payment Middleware
Start-AuditStep 7 'Payment middleware services'
$paymentServices = @()
$paymentDiscoveryError = $null
$detectedPaymentProvider = 'Not detected'
$selectedPaymentServiceName = $null
$appSettingsRowAdded = $false
try {
    $allServices = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $paymentServices = @(Find-KioskPaymentServices -Services $allServices)
    if ($paymentServices.Count -eq 0 -and (Test-CanApply)) {
        do {
            $manualServiceName = Read-Host "Please enter EXACT Service Name for Payment Middleware (or type 'skip')"
        } until (-not [string]::IsNullOrWhiteSpace($manualServiceName))
        if ($manualServiceName -ne 'skip') {
            $paymentServices = @($allServices | Where-Object { $_.Name -eq $manualServiceName })
        }
    }
} catch { $paymentDiscoveryError = $_.Exception.Message }

if ($paymentServices.Count -gt 0) {
    try {
    $primaryService = Select-PaymentPrimary $paymentServices
    $selectedPaymentServiceName = [string]$primaryService.Name
    Invoke-RequiredServiceCheck -ServiceName $primaryService.Name -ItemTitle 'Payment Gateway Middleware' -ItemSub 'Type: Payment Gateway Middleware' -DeferConsole
    $primaryServiceRow = $auditRows[$auditRows.Count - 1]
    $primaryExecutablePath = $null
    $primaryServiceVersion = 'Not verified'
    $primaryServiceState = [string]$primaryService.State
    try {
        $primaryExecutablePath = Get-PaymentExecutablePath $primaryService
        if (-not (Test-Path -LiteralPath $primaryExecutablePath -PathType Leaf)) { throw "Service executable not found: $primaryExecutablePath" }
        $versionDetails = Get-ThoroughPaymentVersionDetails $primaryExecutablePath
        $primaryServiceVersion = [string]$versionDetails.Version
        $currentPrimary = Get-AuditService -ServiceName $primaryService.Name
        if (-not $currentPrimary) { throw 'Primary Payment Service disappeared during detail verification.' }
        $primaryServiceState = [string]$currentPrimary.State
        $currentStartup = if ($currentPrimary.StartMode -eq 'Auto') { 'Automatic' } else { [string]$currentPrimary.StartMode }
        $primaryServiceRow.FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceName $currentPrimary.Name -ServiceState $currentPrimary.State -StartupType $currentPrimary.StartMode -Recovery $primaryServiceRow.RecoveryDetails -Version $versionDetails.Version
        if ([string]::IsNullOrWhiteSpace($versionDetails.Version) -or $versionDetails.Version -in @('Not detected','Not verified')) {
            $primaryServiceRow.Status='Fail'
            $primaryServiceRow.ActionTaken += '; Payment Service version could not be detected.'
        }
    } catch {
        $primaryServiceRow.Status = 'Fail'
        $existingAction = Convert-ReportHtmlToTerminalText $primaryServiceRow.ActionTaken
        $primaryServiceRow.ActionTaken = [Net.WebUtility]::HtmlEncode(($existingAction + '; Payment Service details not verified: ' + $_.Exception.Message).Trim(' ', ';'))
    }

    Write-ThoroughConsoleEntry -Row $primaryServiceRow -Number $auditRows.Count

    $configurationStatus = 'Pass'
    $configurationFound = '<div class="kv-block">Not verified</div>'
    $configurationAction = 'Configuration read from appsettings.json; no configuration values changed'
    $configurationPath = $null
    $configurationLines = @()
    $configurationSnapshot = $null
    $endpointRepair = $null
    $endpointRepairError = $null
    try {
        if ($primaryServiceState -ne 'Running') { throw 'A running Payment Service was not found; appsettings.json was not inspected.' }
        if ([string]::IsNullOrWhiteSpace($primaryExecutablePath)) { throw 'Payment Service executable path is unavailable.' }
        $configurationPath = Join-Path (Split-Path $primaryExecutablePath -Parent) 'appsettings.json'
        if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw "appsettings.json not found: $configurationPath" }
        $configuration = ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($configurationPath))
        $configurationSnapshot = $configuration
        if(Test-CanApply){
            try {
                $endpointRepair=Set-ThoroughServiceEndpoints -Path $configurationPath
                $configuration=ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($configurationPath))
                $configurationSnapshot=$configuration
                if($endpointRepair.Changed){$configurationAction='Updated AppSettings service URLs; file readback verified. Backup: '+$endpointRepair.BackupPath+'. Payment Service runtime activation was not verified.'}
            } catch {
                $endpointRepairError='AppSettings endpoint repair failed: '+$_.Exception.Message
                # Report the file that remains after rollback or a concurrent edit.
                $configurationSnapshot=$null
                $configuration=ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($configurationPath))
                $configurationSnapshot=$configuration
            }
        }
        $providerValue = ([string](Get-ThoroughPaymentConfigValue $configuration 'PaymentService')).Trim().ToUpperInvariant()
        $detectedPaymentProvider = if ([string]::IsNullOrWhiteSpace($providerValue)) { 'Not configured' } else { $providerValue }
        $configurationLines = @(Get-ThoroughPaymentConfigurationAuditLines -Configuration $configuration -ServiceName $primaryService.Name -ConfigurationPath $configurationPath -ServiceVersion $primaryServiceVersion)
        $configurationFound = ConvertTo-ThoroughPaymentReportHtml $configurationLines
        $missingConfigurationValues = @($configurationLines | Where-Object {
            $_ -match ':\s*Not configured$' -or ($_ -match ':\s*\(empty\)$' -and $_ -notmatch 'TerminalId:\s*\(empty\)$')
        })
        if ($missingConfigurationValues.Count -gt 0) {
            $configurationStatus = 'Fail'
            $configurationAction += "; $($missingConfigurationValues.Count) required value(s) are not configured"
        }
        $requiredEndpoints=Get-ThoroughServiceEndpointRequirements
        foreach($key in $requiredEndpoints.Keys){if(([string](Get-ThoroughPaymentConfigValue $configuration $key)).Trim() -cne $requiredEndpoints[$key]){$configurationStatus='Fail'}}
        if(Test-ThoroughPaymentServiceV13 $primaryServiceVersion){
            $chineseMode=Get-ThoroughPaymentConfigValue (Get-ThoroughPaymentConfigValue $configuration 'Print') 'KioskPrinterDisableChineseMode'
            if(([string]$chineseMode).Trim() -ine 'true'){$configurationStatus='Fail'}
        }
        if($endpointRepairError){$configurationStatus='Fail';$configurationAction+='; '+$endpointRepairError}
    } catch {
        $configurationStatus = 'Fail'
        $configurationAction = "AppSettings check failed: $($_.Exception.Message)"
    }
    $configurationShortcut = if ($configurationPath) { New-ReportCommand @('notepad.exe "' + $configurationPath + '"') } else { '<code>appsettings.json</code>' }
    Add-AuditEntry -SectionNumber $secAppNum -SectionTitle $secAppTitle -ItemTitle 'Payment Service appsettings.json' -ItemSub 'Type: Read-only Configuration Inspection' -Shortcut $configurationShortcut -FoundStateHtml $configurationFound -Status $configurationStatus -ActionTaken ([Net.WebUtility]::HtmlEncode($configurationAction))
    if ($null -ne $configurationSnapshot) {
        $configurationRow = $auditRows[$auditRows.Count - 1]
        $configurationRow | Add-Member -NotePropertyName ConfigurationSnapshot -NotePropertyValue $configurationSnapshot
        $configurationRow | Add-Member -NotePropertyName ConfigurationServiceName -NotePropertyValue $primaryService.Name
        $configurationRow | Add-Member -NotePropertyName ConfigurationServiceVersion -NotePropertyValue $primaryServiceVersion
        $configurationRow | Add-Member -NotePropertyName ConfigurationPath -NotePropertyValue $configurationPath
        $configurationRow | Add-Member -NotePropertyName PrinterInventory -NotePropertyValue @(Get-ThoroughAppSettingsPrinterInventory)
        if($endpointRepair){$configurationRow | Add-Member -NotePropertyName EndpointRepair -NotePropertyValue $endpointRepair}
        if($endpointRepairError){$configurationRow | Add-Member -NotePropertyName EndpointRepairError -NotePropertyValue $endpointRepairError}
    }
    $appSettingsRowAdded = $true

    foreach ($legacy in @($paymentServices | Where-Object { $_.Name -ne $primaryService.Name })) {
        Invoke-LegacyPaymentServiceCheck -LegacyService $legacy -PrimaryServiceName $primaryService.Name -PrimaryVerified ($primaryServiceRow.Status -eq 'Pass')
    }
    } catch {
        Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Payment service selection' -ItemSub 'Type: Payment Middleware' -Shortcut '<code>services.msc</code>' -FoundStateHtml 'Primary not verified' -Status 'Fail' -ActionTaken ([Net.WebUtility]::HtmlEncode($_.Exception.Message))
    }
} else {
    $paymentAction = if ($paymentDiscoveryError) { "Service discovery failed: $paymentDiscoveryError" } else { 'Service not detected. Install Payment Middleware or provide its exact service name in apply mode.' }
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Payment Middleware Service' -ItemSub 'Type: Middleware Service' -Shortcut '<code>services.msc</code>' -FoundStateHtml '<div class="kv-block">Service not detected</div>' -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($paymentAction))
}
if (-not $appSettingsRowAdded) {
    $appSettingsAction = if ($paymentDiscoveryError) { "AppSettings check failed because Payment Service discovery failed: $paymentDiscoveryError" } else { 'AppSettings check requires a running Payment Service; no configuration file was changed' }
    Add-AuditEntry -SectionNumber $secAppNum -SectionTitle $secAppTitle -ItemTitle 'Payment Service appsettings.json' -ItemSub 'Type: Read-only Configuration Inspection' -Shortcut '<code>appsettings.json</code>' -FoundStateHtml '<div class="kv-block">Running Payment Service or configuration path not available</div>' -Status 'Fail' -ActionTaken ([Net.WebUtility]::HtmlEncode($appSettingsAction))
}

# Read-only for Audit, Apply Fix and Thorough Check Report; only selected NETS / NEXIDE.
Invoke-PaymentRestartTaskCheck -PaymentProvider $detectedPaymentProvider -ServiceName $selectedPaymentServiceName

# KioskFunction Get-ZabbixConfiguredHostname

# KioskFunction Test-ZabbixMonitoringHostname

# KioskFunction Read-ZabbixMonitoringHostname

# Function definitions inserted into both production scripts by the updater.
# KioskFunction New-ZabbixInstallCommand

# KioskFunction Invoke-ZabbixAgentInstall


# 3.2 Zabbix Agent 2
Start-AuditStep 8 'Zabbix Agent 2'
$zabbixInstallError = $null
$zabbixInstalledThisRun = $false
$zabbixExpectedHostname = Get-ThoroughDeviceHostname
try {
    $zabbixService = Get-AuditService -ServiceName 'Zabbix Agent 2'
    if (-not $zabbixService -and (Test-CanApply)) {
        $zabbixExpectedHostname=Read-ZabbixMonitoringHostname -SuggestedName (Get-ThoroughDeviceHostname)
        if(Get-AuditService -ServiceName 'Zabbix Agent 2'){throw 'Zabbix appeared during hostname input; installation was not started. Run Apply again to inspect it.'}
        [void](New-ZabbixInstallCommand -Hostname $zabbixExpectedHostname)
        Invoke-ZabbixAgentInstall -Hostname $zabbixExpectedHostname
        $zabbixService = Get-AuditService -ServiceName 'Zabbix Agent 2'
        if (-not $zabbixService) { throw 'Installer exited but Zabbix Agent 2 service is still missing.' }
        $zabbixInstalledThisRun = $true
    }
} catch { $zabbixInstallError = $_.Exception.Message }
if ($zabbixInstallError) {
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Zabbix Agent 2' -ItemSub 'Type: Infrastructure Monitoring' -Shortcut '<code>services.msc</code>' -FoundStateHtml (ConvertTo-ServiceFindingHtml -ServiceState 'Not verified' -StartupType 'Not verified' -Recovery ([pscustomobject]@{First='Not verified';Second='Not verified';Subsequent='Not verified'}) -HostName 'Not verified') -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($zabbixInstallError))
    $auditRows[-1] | Add-Member NoteProperty ExpectedHostName $zabbixExpectedHostname
} else {
    Invoke-RequiredServiceCheck -ServiceName 'Zabbix Agent 2' -ItemTitle 'Zabbix Agent 2' -ItemSub 'Type: Infrastructure Monitoring' -DeferConsole
    $zabbixRow = $auditRows[$auditRows.Count - 1]
    if ($zabbixInstalledThisRun) { $zabbixRow.ActionTaken='Installed missing Zabbix Agent; service presence verified; '+$zabbixRow.ActionTaken }
    try { $agentHostname = Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName }
    catch { $agentHostname = 'Not verified (configuration unreadable)' }
    if(-not $zabbixInstalledThisRun -and (Test-ZabbixMonitoringHostname $agentHostname)){$zabbixExpectedHostname=$agentHostname}
    elseif((Test-CanApply) -and -not $zabbixInstalledThisRun -and -not (Test-ZabbixMonitoringHostname $agentHostname)){
        try{
            $missingHostname=Get-ZabbixHostnameSetting -CommandLine $zabbixService.PathName -AllowMissing
            if(-not [string]::IsNullOrWhiteSpace($missingHostname.Value)){throw 'An invalid existing Zabbix hostname requires manual review.'}
            $zabbixExpectedHostname=Read-ZabbixMonitoringHostname -SuggestedName (Get-ThoroughDeviceHostname)
            $hostnameChange=Set-ZabbixDeviceHostname -CommandLine $zabbixService.PathName -Hostname $zabbixExpectedHostname -OnlyIfMissing
            if($hostnameChange.Changed){$zabbixRow.ActionTaken+='; Updated Zabbix hostname to '+$zabbixExpectedHostname+'; service restarted and readback verified; Backup: '+$hostnameChange.BackupPath}
            $agentHostname=Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName
        }catch{
            $zabbixRow.Status='Fail';$zabbixRow.ActionTaken+='; Zabbix hostname update was not verified: '+$_.Exception.Message+'. Manual action required.'
            try{$agentHostname=Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName}catch{$agentHostname='Not verified'}
        }
    }
    $zabbixRow | Add-Member NoteProperty ExpectedHostName $zabbixExpectedHostname
    Update-ZabbixServiceReport -Row $zabbixRow -Hostname $agentHostname
    if ($agentHostname -match 'Not verified|Dynamic /') { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Zabbix monitoring hostname was not verified.' }
    elseif (-not (Test-ZabbixMonitoringHostname $zabbixExpectedHostname)) { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Zabbix monitoring hostname unavailable; manual verification is required.' }
    elseif ($agentHostname -cne $zabbixExpectedHostname) { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Zabbix hostname differs from the expected hostname; existing configuration preserved. Manual action required.' }
    Write-ThoroughConsoleEntry -Row $zabbixRow -Number $auditRows.Count
}

# 3.3 Windows Update Service
Start-AuditStep 9 'Windows Update service'
$wuStatus = 'Fail'
$wuState = 'Not verified'
$wuStartup = 'Not verified'
$wuRecovery = 'Not verified'
$wuAction = 'Audit only: no changes made'
$wuChanges=New-Object 'Collections.Generic.List[string]'
try {
    $wuauserv = Get-AuditService -ServiceName 'wuauserv'
    if (-not $wuauserv) { throw 'Windows Update service is missing.' }
    $wuState = [string]$wuauserv.State
    $wuStartup = [string]$wuauserv.StartMode
    $wuRecoveryValid = Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv'
    if (Test-CanApply) {
        if (-not $wuRecoveryValid) { $wuRecoveryValid = Invoke-ServiceNoActionRecoveryRepair -ServiceName 'wuauserv'; $wuChanges.Add('Recovery actions set to Take No Action') }
        if (-not $wuRecoveryValid) { throw 'Windows Update recovery settings could not be verified; remaining repairs skipped.' }
        if ($wuauserv.StartMode -ne 'Disabled') { Set-Service -Name 'wuauserv' -StartupType Disabled -ErrorAction Stop; $wuChanges.Add('Startup set to Disabled') }
        if ($wuauserv.State -ne 'Stopped') {
            Stop-Service -Name 'wuauserv' -Force -ErrorAction Stop
            $wuChanges.Add('Service stop requested')
            $wuWaitService = Get-Service -Name 'wuauserv' -ErrorAction Stop
            $wuWaitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
    }
    $wuauserv = Get-AuditService -ServiceName 'wuauserv'
    if (-not $wuauserv) { throw 'Windows Update service disappeared during verification.' }
    $wuState = [string]$wuauserv.State
    $wuStartup = [string]$wuauserv.StartMode
    $wuRecoveryValid = Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv'
    $wuRecovery = if ($wuRecoveryValid) { 'First, second and subsequent failures: Take No Action' } else { 'One or more failure actions are configured' }
    if ($wuState -ne 'Stopped' -or $wuStartup -ne 'Disabled' -or -not $wuRecoveryValid) { throw 'Windows Update must be Stopped / Disabled with all recovery actions set to Take No Action; run Apply mode or investigate the service error.' }
    $wuStatus = 'Pass'
    $wuAction = if ($wuChanges.Count) { ($wuChanges -join '; ')+'; readback verified' } else { 'No change needed; verified Stopped / Disabled; all recovery actions: Take No Action' }
} catch {
    $wuAction = ($wuChanges -join '; '); if ($wuAction) { $wuAction+='; ' }; $wuAction += "Failed: $($_.Exception.Message)"
    try {
        $wuFailedSnapshot = Get-AuditService -ServiceName 'wuauserv'
        if ($wuFailedSnapshot) {
            $wuState = [string]$wuFailedSnapshot.State
            $wuStartup = [string]$wuFailedSnapshot.StartMode
        }
        try {
            $wuRecovery = if (Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv') { 'First, second and subsequent failures: Take No Action' } else { 'One or more failure actions are configured' }
        } catch { $wuRecovery = 'Not verified' }
    } catch { $wuAction += '; Current state could not be refreshed' }
}
$wuRecoveryDetails=Get-ServiceRecoveryDetails -ServiceName 'wuauserv'
if (-not $wuRecoveryDetails.Verified) { $wuStatus='Fail'; $wuAction += '; Recovery actions not verified: '+$wuRecoveryDetails.Error }
$wuFound=ConvertTo-ServiceFindingHtml -ServiceState $wuState -StartupType $wuStartup -Recovery $wuRecoveryDetails
Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Windows Update (wuauserv)' -ItemSub 'Type: Windows Update Engine' -Shortcut '<code>services.msc</code>' -FoundStateHtml $wuFound -Status $wuStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($wuAction))

# GROUP 5: SECURITY, NETWORK & SYSTEM INTEGRITY
$sec4Num = 4
$sec4Title = 'Security, Network & System Integrity'
# 4.1 Inbound Port 5009 Firewall Rule
# KioskFunction Test-FirewallPortMatch

# KioskFunction Test-FirewallAny

# KioskFunction Get-KioskFirewallState

# KioskFunction Invoke-KioskFirewallPortCheck

Start-AuditStep 10 'Required inbound firewall rules'
Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'SELISE Kiosk'
$paymentFirewallPorts=@(switch($detectedPaymentProvider){
    'NETS' {@(4100,4101,4102,4103)}
    'NEXIDE' {@(20002,20007)}
})
foreach($paymentFirewallPort in $paymentFirewallPorts){
    Invoke-KioskFirewallPortCheck -Port $paymentFirewallPort -RulePurpose ($detectedPaymentProvider+' Payment Terminal')
}

# 4.2 Local Administrative Accounts
Start-AuditStep 11 'Administrative accounts'
try {
    Add-ResultEntry $sec4Num $sec4Title 'Administrative Accounts' (Get-AdministrativeAccountCheck)
} catch { Add-ResultEntry $sec4Num $sec4Title 'Administrative Accounts' (New-CheckResult 'Fail' $_.Exception.Message 'Account checks failed') }

# 4.3 Nmap Tool (Windows 10 Local Installer)
Start-AuditStep 12 'Nmap executable and version'
# KioskFunction Get-NmapExecutable

# KioskFunction Get-NmapVersion

# KioskFunction Get-LocalNmapInstaller

$nmapStatus = 'Fail'
$nmapPath = $null
$nmapDetectionVerified = $false
$nmapAction = 'Not installed'
$nmapVersion = $null
try {
    $nmapPath = Get-NmapExecutable
    $nmapDetectionVerified = $true
    if (-not $nmapPath) {
        $isWin10 = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption -match 'Windows 10'
        if (Test-CanApply) {
            $nmapDetectionVerified = $false
            if ($isWin10) {
                $installerPath = Get-LocalNmapInstaller -ScriptDirectory $PSScriptRoot
                # The public Nmap installer requires interaction. /S is an OEM-only feature.
                Write-Host '  Nmap setup will open. Complete the wizard to continue the check.' -ForegroundColor Cyan
                $installerProcess = Start-Process -FilePath $installerPath -Wait -PassThru -ErrorAction Stop
                if ($installerProcess.ExitCode -ne 0) { throw "Local Nmap installer returned exit code $($installerProcess.ExitCode); installation was cancelled or failed." }
                $nmapAction = 'Installed missing Nmap using the local setup wizard; existing installations are not upgraded'
            } else {
                $wingetCommand = Get-Command -Name winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $wingetCommand) { throw 'winget is unavailable; install Nmap manually from https://nmap.org/download.html' }
                & $wingetCommand.Source install --id Insecure.Nmap --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --no-upgrade 2>&1 | Out-Null
                $wingetExitCode = $LASTEXITCODE
                if ($wingetExitCode -ne 0) { throw "Nmap installer returned exit code $wingetExitCode; verify installation manually." }
                $nmapAction = 'Installed missing Nmap using winget; existing installations are not upgraded'
            }
            $nmapPath = Get-NmapExecutable
            $nmapDetectionVerified = $true
            if (-not $nmapPath) { throw 'Installer reported success but nmap.exe is still missing.' }
        } elseif ($isWin10) {
            $nmapAction = 'Audit only: Nmap missing; Apply Fix would open the local Nmap setup wizard'
        } else { $nmapAction = 'Audit only: Nmap missing; apply mode would attempt silent installation using winget' }
    } else { $nmapAction = 'Existing installation retained' }
    if ($nmapPath) {
        $nmapVersion = Get-NmapVersion -Path $nmapPath
        $nmapAction += '; version check passed'
        $nmapStatus = 'Pass'
    }
} catch {
    $nmapStatus = 'Fail'
    $nmapAction = "Nmap check or installation failed: $($_.Exception.Message)"
    if (-not $nmapDetectionVerified) {
        try {
            $nmapPath = Get-NmapExecutable
            $nmapDetectionVerified = $true
        } catch { $nmapPath = $null }
    }
}
$nmapToolState = if (-not $nmapDetectionVerified) { 'Not verified. Please check manually.' } elseif ($nmapPath) { 'Installed' } else { 'Not installed. Please install manually.' }
$nmapDetails = [ordered]@{ 'Tool State'=$nmapToolState }
if ($nmapPath) {
    $nmapDetails['Version'] = if ($null -ne $nmapVersion) { $nmapVersion.Version } else { 'Not verified. Please check manually.' }

}
$nmapFound = ConvertTo-ReportDefinitionHtml $nmapDetails
Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle 'Nmap Diagnostic Tool' -ItemSub 'Type: Executable / Version Check' -Shortcut '<code>nmap --version</code>' -FoundStateHtml $nmapFound -Status $nmapStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($nmapAction))

# 4.4 lodctr /R Performance Counter Rebuild
Start-AuditStep 13 'Performance counters'
$lodctrStatus = 'Bypass'
$lodctrState = 'Not executed (audit only)'
$lodctrAction = 'Audit only: performance counter rebuild skipped; health was not verified'
if (Test-CanApply) {
    try {
        $lodctrProcess = Start-Process -FilePath 'lodctr.exe' -ArgumentList '/R' -Wait -WindowStyle Hidden -PassThru -ErrorAction Stop
        $lodctrState = "Exit code: $($lodctrProcess.ExitCode)"
        if ($lodctrProcess.ExitCode -ne 0) { throw "lodctr /R failed with exit code $($lodctrProcess.ExitCode)." }
        $lodctrStatus = 'Pass'
        $lodctrAction = 'Performance counters rebuilt; lodctr returned exit code 0'
    } catch {
        $lodctrStatus = 'Fail'
        if ($lodctrState -eq 'Not executed (audit only)') { $lodctrState = 'Execution error' }
        $lodctrAction = "Performance counter rebuild failed: $($_.Exception.Message)"
    }
}
$lodctrFound = if ($script:ApplyChanges) {
    ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Rebuild State'=($lodctrState -replace ' \(audit only\)$','') })
} else {
    ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Audit'='Not executed' })
}
Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle 'lodctr /R Performance Counter' -ItemSub 'Type: System Performance Rebuild' -Shortcut '<code>perfmon</code>' -FoundStateHtml $lodctrFound -Status $lodctrStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($lodctrAction))


# END COMPONENT CHECKS
    if($inspectOnly){$beforeApplyRows=@(Copy-ThoroughObservationRows @(Get-ThoroughReportDisplayRows -Rows $auditRows.ToArray()))}
}
} catch {
    $interruption=if($script:BeforeApplyInspection){'Pre-Apply inspection was interrupted; no repairs were started.'}else{'Partial run; earlier changes may already have been applied'}
    if($script:BeforeApplyInspection){$script:ApplyChanges=$applyRequested}
    Add-ResultEntry 6 'Execution' 'Unexpected interruption' (New-CheckResult 'Fail' $_.Exception.Message $interruption)
} finally {
    $script:BeforeApplyInspection=$false
    $totalCount = $auditRows.Count
    $passCount = @($auditRows | Where-Object { $_.Status -in @('Pass','Online','Remediated') -or ($_.Status -eq 'Offline' -and $_.ItemSub -eq 'Type: Old Payment Service') }).Count
    $failCount = @($auditRows | Where-Object { $_.Status -eq 'Fail' -or ($_.Status -eq 'Offline' -and $_.ItemSub -ne 'Type: Old Payment Service') }).Count
    $skipCount = $totalCount - $passCount - $failCount
    $totalChecksStr = '{0:D2}' -f $totalCount
    $passedCountStr = '{0:D2}' -f $passCount
    $failedCountStr = '{0:D2}' -f $failCount
    $skippedCountStr = '{0:D2}' -f $skipCount

    if (-not $script:ApplyChanges) { Complete-ThoroughConsole -IsApply $false -FailedCount $failCount -IsFinal ([bool]$FinalReport) }
    $generateReport = [bool]($script:ApplyChanges -or $FinalReport)
    if (-not $script:ApplyChanges -and -not $FinalReport) {
        $generateReport = Read-AuditReportChoice
    }

    if ($generateReport) {
        if ($script:ApplyChanges) { Start-AuditStep 14 'Writing HTML report' }
        if (-not (Test-Path -LiteralPath $outputFolder)) {
            New-Item -ItemType Directory -Path $outputFolder -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
        }

$snapshotModes=if($script:ApplyChanges){@('Fix','Final')}elseif($FinalReport){@('Final')}else{@('Audit','Fix','Final')}
$auditSource=$null
$snapshots=@(foreach($snapshotMode in $snapshotModes){
    $snapshot=New-ThoroughReportSnapshot -Rows $auditRows.ToArray() -DisplayMode $snapshotMode -ClientLocation $clientLocation -AgentName $AgentName -DeviceType $deviceType -Hostname $reportHostname -LauncherKioskId $reportKioskId -LauncherRestaurantId $reportRestaurantId -RequestedKioskId $KioskId -KioskUserName $(if($null -ne $kioskAccount){[string]$kioskAccount.Name}else{''}) -AfterApply:([bool]$script:ApplyChanges) -AuditSource $auditSource -BeforeRows $(if($script:ApplyChanges){if($savedBeforeRows.Count){$savedBeforeRows}else{$beforeApplyRows}}else{@()})
    if($snapshotMode -eq 'Audit'){$auditSource=$snapshot}
    $snapshot
})
$preferredMode=if($script:ApplyChanges){'Fix'}elseif($FinalReport){'Final'}else{'Audit'}
$reportPath=Save-ThoroughReportBundle -Path $reportPath -ClientType $script:KioskClientSettings.ClientType -ComputerName $env:COMPUTERNAME -Snapshots $snapshots -PreferredMode $preferredMode
    if ($script:ApplyChanges) {
        Write-Host "Report saved: $reportPath" -ForegroundColor Cyan
        Complete-ThoroughConsole -IsApply $true -FailedCount $failCount
    } else {
        if ($FinalReport) { Write-Host "Report saved: $reportPath" -ForegroundColor Gray }
        else { Write-Host "`nAudit report saved to:`n$reportPath" -ForegroundColor Green }
    }
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $edgeExe = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

        try {
            if ($edgeExe) {
                [void](Start-Process -FilePath $edgeExe -ArgumentList "`"$reportPath`"")
            } else {
                [void](Start-Process -FilePath $reportPath)
            }
        } catch {
            # Fallback if running headless, in automated test mocks, or restricted process launch
        }
    }
    }
}
$global:LASTEXITCODE = if ($failCount -gt 0) { 1 } else { 0 }
if ($ArchitectureRun -and -not [string]::IsNullOrWhiteSpace($ArchitectureResultPath)) {
    [IO.File]::WriteAllText($ArchitectureResultPath, 'Completed', [Text.UTF8Encoding]::new($false))
}
if ($ArchitectureRun) {
    $nextOption = '0'
} else {
    Write-Host "`n  [3] Main Menu`n  [0] Exit" -ForegroundColor Cyan
    do {
        $nextOption = ([string](Read-Host '  Select option')).Trim()
        if ($nextOption -notin @('3', '0')) { Write-Host 'Please select 3 or 0.' -ForegroundColor Yellow }
    } until ($nextOption -in @('3', '0'))
}
if ($nextOption -eq '3') {
    $Apply = $false; $AuditOnly = $false; $FinalReport = $false
    $RestaurantId = ''; $KioskId = ''; $KioskHostname = ''; $KioskPassword = $null
}
} while ($nextOption -eq '3')
exit $global:LASTEXITCODE

