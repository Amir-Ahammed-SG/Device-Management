[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]$Context
)

$ErrorActionPreference = 'Stop'
if ($Context.DeviceType -ne 'KIOSK' -or $Context.Operation -ne 'ThoroughCheck') {
    return New-OperationResult -Status Fail -Message 'The KIOSK Thorough Check handler received an invalid context.' -Context $Context
}
if ($Context.Mode -notin @('Audit', 'Apply', 'Final')) {
    return New-OperationResult -Status Fail -Message "Unsupported KIOSK Thorough Check mode: $($Context.Mode)" -Context $Context
}
if ($Context.ClientType -notin @('SaaS', 'Subway')) {
    return New-OperationResult -Status Fail -Message "Unsupported KIOSK Thorough Check client: $($Context.ClientType)" -Context $Context
}
if (-not [Environment]::Is64BitProcess) {
    return New-OperationResult -Status Fail -Message 'Run the device-management launcher from 64-bit Windows PowerShell.' -Context $Context
}

$sourceRoot = [IO.Path]::GetFullPath($Context.RootPath)
$sourceName = 'KioskThoroughCheck.ps1'
$legacyScript = Join-Path $sourceRoot $sourceName
if (-not (Test-Path -LiteralPath $legacyScript -PathType Leaf)) {
    return New-OperationResult -Status Fail -Message "$($Context.ClientType) KIOSK Thorough Check source is missing: $legacyScript" -Context $Context
}

$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $legacyScript,
    '-ClientType', $Context.ClientType,
    '-ArchitectureRun',
    '-DeviceType', 'KIOSK'
)
$completionPath = Join-Path ([IO.Path]::GetTempPath()) ('KioskAuditCompletion-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
$arguments += @('-ArchitectureResultPath', $completionPath)
if ($Context.Mode -eq 'Apply') {
    $arguments += '-Apply'

} elseif ($Context.Mode -eq 'Final') {
    $arguments += '-FinalReport'

}
else { $arguments += '-AuditOnly' }
if (-not [string]::IsNullOrWhiteSpace([string]$Context.ClientLocation)) { $arguments += @('-ClientLocation', [string]$Context.ClientLocation) }
if ($Context.PSObject.Properties['AgentName'] -and -not [string]::IsNullOrWhiteSpace([string]$Context.AgentName)) { $arguments += @('-AgentName', [string]$Context.AgentName) }

$startedAt = Get-Date
$powershell = Join-Path $PSHOME 'powershell.exe'
& $powershell @arguments 2>&1 | Out-Host
$operationExitCode = $LASTEXITCODE
$completed = Test-Path -LiteralPath $completionPath -PathType Leaf
Remove-Item -LiteralPath $completionPath -Force -ErrorAction SilentlyContinue
if (-not $completed) {
    return New-OperationResult -Status Fail -Message "$($Context.ClientType) KIOSK Thorough Check could not start or complete. Review the PowerShell error and retry." -Context $Context
}

$report = $null
if (Test-Path -LiteralPath $Context.ReportFolder -PathType Container) {
    $report = Get-ChildItem -LiteralPath $Context.ReportFolder -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}
if (-not $report) {
    if ($Context.Mode -eq 'Audit') {
        $status = if ($operationExitCode -eq 0) { 'Pass' } else { 'Fail' }
        $message = if ($operationExitCode -eq 0) { "$($Context.ClientType) KIOSK Thorough Check completed. HTML report was not generated." } else { "$($Context.ClientType) KIOSK Thorough Check completed with failed checks. HTML report was not generated; review the terminal results." }
        return New-OperationResult -Status $status -Message $message -Context $Context
    }
    return New-OperationResult -Status Fail -Message "$($Context.ClientType) KIOSK Thorough Check finished with exit code $operationExitCode, but no new report was found." -Context $Context
}
if ($operationExitCode -ne 0) {
    return New-OperationResult -Status Fail -Message ("{0} KIOSK Thorough Check completed with failed checks. Report: {1}" -f $Context.ClientType, $report.FullName) -Context $Context
}
New-OperationResult -Status Pass -Message ("{0} KIOSK Thorough Check completed. Report: {1}" -f $Context.ClientType, $report.FullName) -Context $Context
