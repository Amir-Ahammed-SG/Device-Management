Set-StrictMode -Version 2.0

function Show-DeviceManagementHeader {
    param ([string]$Title, [string]$Breadcrumb)
    Clear-Host
    Write-Host '  SELISE | DEVICE MANAGEMENT' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    if ($Breadcrumb) { Write-Host ("  {0}" -f $Breadcrumb) -ForegroundColor Gray }
    Write-Host ''
    Write-Host ("  {0}" -f $Title) -ForegroundColor White
    Write-Host ''
}

function Show-DeviceManagementNavigation {
    param (
        [switch]$AllowMainMenu,
        [switch]$AllowApplyFix,
        [switch]$AllowBack,
        [switch]$AllowExit,
        [string]$BackKey = '8',
        [string]$ExitKey = '0'
    )
    $links = @()
    if ($AllowApplyFix) { $links += '[2] Apply Fix' }
    if ($AllowMainMenu) { $links += '[3] Main Menu' }
    if ($AllowBack) { $links += ('[{0}] Back' -f $BackKey) }
    if ($AllowExit) { $links += ('[{0}] Exit' -f $ExitKey) }
    Write-Host ''
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    if ($links.Count -gt 0) { Write-Host ('  ' + ($links -join '    ')) -ForegroundColor White }
    Write-Host ''
}

function Get-MenuItemValue {
    param ($Item, [string]$Name)
    if ($Item -is [Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $property = $Item.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Read-NumberedSelection {
    param (
        [Parameter(Mandatory = $true)][object[]]$Items,
        [switch]$AllowBack,
        [switch]$AllowExit,
        [string]$BackKey = '8',
        [string]$ExitKey = '0',
        [string]$Prompt = 'Select option'
    )
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $implementationState = Get-MenuItemValue $Items[$index] 'ImplementationState'
        $unavailable = $implementationState -and $implementationState -ne 'Ready'
        $suffix = if ($unavailable) { ' (Not available)' } else { '' }
        $color = if ($unavailable) { 'Gray' } else { 'White' }
        $description = Get-MenuItemValue $Items[$index] 'Description'
        Write-Host ("    [{0}] {1}{2}" -f ($index + 1), $Items[$index].DisplayName, $suffix) -ForegroundColor $color
        if ($description) {
            Write-Host ("        {0}" -f $description) -ForegroundColor Gray
        }
    }
    Show-DeviceManagementNavigation -AllowBack:$AllowBack -AllowExit:$AllowExit -BackKey $BackKey -ExitKey $ExitKey
    do {
        $choice = ([string](Read-Host ("  {0}" -f $Prompt))).Trim()
        if ($AllowBack -and $choice -eq $BackKey) { return '__BACK__' }
        if ($AllowExit -and $choice -eq $ExitKey) { return '__EXIT__' }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
            $implementationState = Get-MenuItemValue $Items[$number - 1] 'ImplementationState'
            if ($implementationState -and $implementationState -ne 'Ready') {
                Write-Host '  This option is not available yet. Select another option.' -ForegroundColor Yellow
                continue
            }
            return $Items[$number - 1]
        }
        Write-Host '  Invalid selection. Enter a displayed option number.' -ForegroundColor Yellow
    } while ($true)
}

Export-ModuleMember -Function Show-DeviceManagementHeader, Show-DeviceManagementNavigation, Read-NumberedSelection
