[CmdletBinding()]
param ([Parameter(Mandatory = $true)]$Context)

New-OperationResult -Status Unavailable -Message ("{0} for {1}/{2} is pending implementation. No system changes were made." -f $Context.Operation, $Context.ClientType, $Context.DeviceType) -Context $Context
