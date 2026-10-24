# Compiled into the in-memory PackageLoader module, not used by local file runs.
function Invoke-ConfiguredOperation {
    param (
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)]$Context
    )
    if (-not (Test-OperationSelectionReady -Operation $Operation -ClientId $Context.ClientType -Device $Context.DeviceType -Mode $Context.Mode)) {
        return New-OperationResult -Status Unavailable -Message ("{0} for {1}/{2} is not implemented yet. No system changes were made." -f $Operation.DisplayName, $Context.ClientType, $Context.DeviceType) -Context $Context
    }
    if ($Context.Operation -ne 'ThoroughCheck' -or $Operation.Id -ne 'ThoroughCheck' -or $Context.DeviceType -ne 'KIOSK' -or $Context.ClientType -notin @('SaaS', 'Subway') -or $Context.Mode -notin @('Audit', 'Apply', 'Final')) {
        return New-OperationResult -Status Fail -Message 'Unsupported in-memory operation context. No checks were started.' -Context $Context
    }
    $sourceName = if ($Context.ClientType -eq 'Subway') { 'SubwayKioskThoroughCheck.ps1' } else { 'SaaSKioskThoroughCheckScript.ps1' }
    $arguments = @{ ArchitectureRun = $true; DeviceType = 'KIOSK' }
    if ($Context.Mode -eq 'Apply') {
        $arguments.Apply = $true

    } elseif ($Context.Mode -eq 'Final') {
        $arguments.FinalReport = $true

    }
    else { $arguments.AuditOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.ClientLocation)) { $arguments.ClientLocation = [string]$Context.ClientLocation }

    try {
        $execution = Invoke-DeviceManagementMemoryScript -Code $script:MemoryBundle.Files[$sourceName] -Bundle $script:MemoryBundle -RuntimeCode $script:MemoryRuntime -Parameters $arguments
        $completion = @($execution.Output | Where-Object { $_.PSObject.Properties['MemoryCheckCompleted'] -and $_.MemoryCheckCompleted -eq $true })
        if ($execution.State -ne 'Completed' -or $completion.Count -ne 1) {
            $detail = if ($execution.Failure) { [string]$execution.Failure } else { ($execution.Errors | Out-String).Trim() }
            throw ('Thorough Check did not return a verified completion result. ' + $detail)
        }
        $completed = $completion[0]
        $reportPath = [string]$completed.ReportPath
        if ([string]::IsNullOrWhiteSpace($reportPath)) {
            if ($Context.Mode -ne 'Audit') { throw ($Context.Mode + ' completed without a report path.') }
            $status = if ($completed.ExitCode -eq 0) { 'Pass' } else { 'Fail' }
            $message = if ($completed.ExitCode -eq 0) { "$($Context.ClientType) KIOSK Thorough Check completed. HTML report was not generated." } else { "$($Context.ClientType) KIOSK Thorough Check completed with failed checks. HTML report was not generated; review the terminal results." }
            return New-OperationResult -Status $status -Message $message -Context $Context
        }
        $expectedFolder = [IO.Path]::GetFullPath($Context.ReportFolder).TrimEnd('\')
        $actualFolder = Split-Path ([IO.Path]::GetFullPath($reportPath)) -Parent
        if ($actualFolder -ine $expectedFolder -or [IO.Path]::GetExtension($reportPath) -ine '.html' -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'The exact report path could not be verified.' }
        $status = if ($completed.ExitCode -eq 0) { 'Pass' } else { 'Fail' }
        $message = if ($completed.ExitCode -eq 0) { "$($Context.ClientType) KIOSK Thorough Check completed. Report: $reportPath" } else { "$($Context.ClientType) KIOSK Thorough Check completed with failed checks. Report: $reportPath" }
        return New-OperationResult -Status $status -Message $message -Context $Context
    } catch {
        return New-OperationResult -Status Fail -Message ("$($Context.ClientType) KIOSK Thorough Check could not start or complete. " + $_.Exception.Message) -Context $Context
    }
}
