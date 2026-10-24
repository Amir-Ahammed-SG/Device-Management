Set-StrictMode -Version 2.0

function New-OperationResult {
    param (
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Fail', 'Unavailable')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        $Context
    )
    [pscustomobject]@{ Status = $Status; Message = $Message; Context = $Context }
}

Export-ModuleMember -Function New-OperationResult
