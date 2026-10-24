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

Export-ModuleMember -Function Resolve-OperationHandlerPath, Invoke-ConfiguredOperation
