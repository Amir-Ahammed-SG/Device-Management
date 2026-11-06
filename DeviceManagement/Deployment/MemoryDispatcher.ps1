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
    if ($Context.Operation -eq 'KioskInstallation' -and $Operation.Id -eq 'KioskInstallation' -and $Context.ClientType -in @('SaaS','Subway') -and $Context.DeviceType -eq 'KIOSK' -and $Context.Mode -eq 'Apply') {
        try {
            $handlerName='DeviceManagement/Installations/KIOSK/Install.ps1'
            if (-not $script:MemoryBundle.Files.ContainsKey($handlerName)) { throw 'The embedded installation handler is missing.' }
            $execution=Invoke-DeviceManagementMemoryScript -Code $script:MemoryBundle.Files[$handlerName] -Bundle $script:MemoryBundle -RuntimeCode $script:MemoryRuntime -Parameters @{Context=$Context}
            $results=@($execution.Output)
            if ($execution.State -ne 'Completed' -or $execution.Errors.Count -gt 0 -or $results.Count -ne 1 -or $results[0].Status -notin @('Pass','Fail','Unavailable') -or [string]::IsNullOrWhiteSpace([string]$results[0].Message)) {
                throw 'The installation handler did not return a verified operation result.'
            }
            return New-OperationResult -Status $results[0].Status -Message $results[0].Message -Context $Context
        } catch {
            return New-OperationResult -Status Fail -Message ($Context.ClientType+' KIOSK Installation could not start or complete. '+$_.Exception.Message) -Context $Context
        }
    }
    if ($Context.Operation -ne 'ThoroughCheck' -or $Operation.Id -ne 'ThoroughCheck' -or $Context.DeviceType -ne 'KIOSK' -or $Context.ClientType -notin @('SaaS', 'Subway') -or $Context.Mode -notin @('Audit', 'Apply', 'Final')) {
        return New-OperationResult -Status Fail -Message 'Unsupported in-memory operation context. No checks were started.' -Context $Context
    }
    $sourceName = 'DeviceManagement/KioskThoroughCheck.ps1'
    $arguments = @{ ClientType = $Context.ClientType; ArchitectureRun = $true; DeviceType = 'KIOSK' }
    if ($Context.Mode -eq 'Apply') {
        $arguments.Apply = $true

    } elseif ($Context.Mode -eq 'Final') {
        $arguments.FinalReport = $true

    }
    else { $arguments.AuditOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.ClientLocation)) { $arguments.ClientLocation = [string]$Context.ClientLocation }
    if ($Context.PSObject.Properties['AgentName'] -and -not [string]::IsNullOrWhiteSpace([string]$Context.AgentName)) { $arguments.AgentName = [string]$Context.AgentName }

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
