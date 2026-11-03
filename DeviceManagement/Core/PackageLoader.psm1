Set-StrictMode -Version 2.0

function Resolve-OperationHandlerPath {
    param (
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)]$Context
    )
    $relative = $Operation.HandlerTemplate.Replace('{Client}', $Context.ClientType).Replace('{Device}', $Context.DeviceType)
    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $RootPath $relative))
    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Operation handler resolved outside the architecture root.' }
    return $candidate
}

function Invoke-ConfiguredOperation {
    param (
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)]$Context
    )
    if (-not (Test-OperationSelectionReady -Operation $Operation -ClientId $Context.ClientType -Device $Context.DeviceType -Mode $Context.Mode)) {
        return New-OperationResult -Status Unavailable -Message ("{0} for {1}/{2} is not implemented yet. No system changes were made." -f $Operation.DisplayName, $Context.ClientType, $Context.DeviceType) -Context $Context
    }
    $handler = Resolve-OperationHandlerPath $RootPath $Operation $Context
    if (-not (Test-Path -LiteralPath $handler -PathType Leaf)) { throw "Configured operation handler is missing: $handler" }
    & $handler -Context $Context
}

function Invoke-DeviceManagementOtherTool {
    param([Parameter(Mandatory=$true)][string]$RootPath,[Parameter(Mandatory=$true)][ValidateSet('PaymentCronJob')][string]$ToolId)
    $embedded=Get-Variable -Name MemoryBundle -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $embedded){
        $resource='DeviceManagement/OtherTools/PaymentCronJob.ps1'
        if(-not $script:MemoryBundle.Files.ContainsKey($resource)){throw 'The embedded Payment Cron Job tool is missing.'}
        $execution=Invoke-DeviceManagementMemoryScript -Code $script:MemoryBundle.Files[$resource] -Bundle $script:MemoryBundle -RuntimeCode $script:MemoryRuntime -Parameters @{MenuRun=$true}
        if($execution.State -ne 'Completed' -or $execution.Errors.Count -gt 0){throw 'Payment Cron Job could not complete; review the terminal output.'}
        $results=@($execution.Output)
    }else{
        $path=Join-Path $RootPath 'OtherTools\PaymentCronJob.ps1'
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Payment Cron Job script is missing.'}
        $results=@(& $path -MenuRun)
    }
    if($results.Count -ne 1 -or -not $results[0].PSObject.Properties['Status'] -or $results[0].Status -notin @('Pass','Fail','Skipped') -or -not $results[0].PSObject.Properties['ReturnToMenu'] -or $results[0].ReturnToMenu -isnot [bool]){throw 'Payment Cron Job did not return a verified completion result.'}
    $results[0]
}

Export-ModuleMember -Function Resolve-OperationHandlerPath, Invoke-ConfiguredOperation, Invoke-DeviceManagementOtherTool
