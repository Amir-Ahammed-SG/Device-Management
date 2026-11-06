# Compatibility launcher; client is fixed for this entry.
[CmdletBinding()]param([Parameter(Mandatory=$true)]$Context)
if($Context.ClientType -cne 'SaaS'){throw 'Client does not match this compatibility launcher.'}
& (Join-Path $PSScriptRoot 'Install.ps1') -Context $Context
