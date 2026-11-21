. (Join-Path $PSScriptRoot 'ReportFixtureSupport.ps1')
. (Join-Path $PSScriptRoot 'BrowserTestSupport.ps1')
$ErrorActionPreference='Stop'
New-KioskReportFixtures
Invoke-KioskBrowserTest -ScriptPath (Join-Path $PSScriptRoot 'Test-ReportClipboard.mjs')
