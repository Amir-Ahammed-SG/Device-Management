# Copy real sources, then use harmless child fixtures. Never run device checks.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$fixtureRoot = Join-Path $projectRoot ('output\self-contained\' + [guid]::NewGuid().ToString('N'))
$copyRoot = Join-Path $fixtureRoot 'DeviceManagement'
[void][IO.Directory]::CreateDirectory($copyRoot)
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($folder in @('Core','Config','Checks','Deployment','Installations','OtherTools','Packages')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $folder) -Destination $copyRoot -Recurse
}
foreach ($name in @('Start-DeviceManagement.ps1','KioskThoroughCheck.ps1')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $copyRoot
}
$release = & (Join-Path $copyRoot 'Deployment\Build-Release.ps1') -ReleaseId '20261106-contained-fixture'
if ($release.Files -ne 23 -or -not (Test-Path -LiteralPath $release.BootstrapPath)) { throw 'Standalone release build failed.' }
$tokens=$null; $errors=$null
$launcherAst = [KioskTestSource]::ParseFile((Join-Path $copyRoot 'Start-DeviceManagement.ps1'),[ref]$tokens,[ref]$errors)
$boundary = @($launcherAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$thoroughCheckOperation.ImplementationState'
})
if ($errors.Count -or $boundary.Count -ne 1) { throw 'Cannot identify launcher startup.' }
$startup = $launcherAst.Extent.Text.Substring(0,$boundary[0].Extent.EndOffset)
$startup += "`r`nif (`$thoroughCheckOperation.ReadySelections.Count -ne 6) { throw 'Client readiness failed.' }"
$startupPath = Join-Path $copyRoot 'Test-Startup.ps1'
[IO.File]::WriteAllText($startupPath,$startup,$utf8)
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $startupPath
if ($LASTEXITCODE -ne 0) { throw 'Standalone launcher startup failed.' }
$reportRoot = Join-Path $fixtureRoot 'reports'
[void][IO.Directory]::CreateDirectory($reportRoot)
$clientFixture = @'
param([string]$ClientType,[switch]$ArchitectureRun,[switch]$AuditOnly,[switch]$Apply,[switch]$FinalReport,[string]$DeviceType,[string]$ClientLocation,[string]$AgentName,[string]$ArchitectureResultPath)
if($ClientType -cne '@@CLIENT@@'){exit 5}
if (-not $ArchitectureRun -or $DeviceType -ne 'KIOSK' -or $ClientLocation -ne 'Fixture Branch' -or $AgentName -ne 'Fixture Agent') { exit 3 }
if (([int][bool]$AuditOnly + [int][bool]$Apply + [int][bool]$FinalReport) -ne 1) { exit 4 }
[IO.File]::WriteAllText('@@REPORT@@','<html>Fixture report</html>')
[IO.File]::WriteAllText($ArchitectureResultPath,'Completed')
exit 0
'@
Import-Module (Join-Path $copyRoot 'Core\Reporting.psm1') -Force
foreach ($client in @('SaaS','Subway')) {
    $name = 'KioskThoroughCheck.ps1'
    [IO.File]::WriteAllText((Join-Path $fixtureRoot $name),"throw 'Parent-folder source must never run.'",$utf8)
    foreach ($mode in @('Audit','Apply','Final')) {
        $report = Join-Path $reportRoot ($client+'-'+$mode+'.html')
        [IO.File]::WriteAllText((Join-Path $copyRoot $name),$clientFixture.Replace('@@REPORT@@',$report.Replace("'","''")).Replace('@@CLIENT@@',$client),$utf8)
        $context = [pscustomobject]@{
            RootPath=$copyRoot; ReportFolder=$reportRoot; ClientType=$client; DeviceType='KIOSK'
            Operation='ThoroughCheck'; Mode=$mode; ClientLocation='Fixture Branch'; AgentName='Fixture Agent'
        }
        $result = & (Join-Path $copyRoot 'Checks\KIOSK\ThoroughCheck.ps1') -Context $context
        if ($result.Status -ne 'Pass' -or $result.Message -notlike ('*'+$report)) { throw ('Standalone handler failed: '+$client+'/'+$mode+': '+$result.Message) }
    }
}
Write-Output 'PASS: standalone build, launcher startup, and both clients in Audit/Apply/Final with harmless child fixtures.'
