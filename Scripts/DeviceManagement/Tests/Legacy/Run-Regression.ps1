[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 3.4 -ErrorAction Stop
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Select-Object -ExpandProperty FullName)
$result = Invoke-Pester -Script $testFiles -PassThru
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
