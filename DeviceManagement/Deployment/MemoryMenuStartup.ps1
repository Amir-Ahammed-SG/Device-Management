# This replaces only the local-file startup section when building a CDN entry.
$architectureRoot = Join-Path $env:SystemDrive 'SELISE-DeviceManagement-Memory\DeviceManagement'
foreach ($moduleName in @('Validation.psm1', 'Context.psm1', 'Menu.psm1', 'Reporting.psm1', 'PackageLoader.psm1')) {
    $moduleCode = $DeviceManagementMemoryBundle.Files['DeviceManagement/Core/' + $moduleName]
    $moduleParameters = @{}
    if ($moduleName -eq 'PackageLoader.psm1') { $moduleParameters.ArgumentList = @($DeviceManagementMemoryBundle, $DeviceManagementMemoryRuntime) }
    $module = New-Module -Name ('DeviceManagementMemory.' + $moduleName.Replace('.psm1', '')) -ScriptBlock ([scriptblock]::Create($moduleCode)) @moduleParameters
    Import-Module -ModuleInfo $module -Scope Local -Force -ErrorAction Stop
}
$clientsConfiguration = $DeviceManagementMemoryBundle.Configurations.Clients
$operationsConfiguration = $DeviceManagementMemoryBundle.Configurations.Operations
$paymentPackagesConfiguration = $DeviceManagementMemoryBundle.Configurations.PaymentPackages
$thoroughCheckOperation = @($operationsConfiguration.Operations | Where-Object { $_.Id -eq 'ThoroughCheck' }) | Select-Object -First 1
if (-not $thoroughCheckOperation) { throw 'The Thorough Check operation is missing from the in-memory configuration.' }
foreach ($requiredSource in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
    if (-not $DeviceManagementMemoryBundle.Files.ContainsKey($requiredSource)) { throw ('The in-memory client source is missing: ' + $requiredSource) }
}
$thoroughCheckOperation.ReadySelections = @('SaaS|KIOSK|Audit', 'SaaS|KIOSK|Apply', 'SaaS|KIOSK|Final', 'Subway|KIOSK|Audit', 'Subway|KIOSK|Apply', 'Subway|KIOSK|Final')
$thoroughCheckOperation.ImplementationState = 'Ready'
