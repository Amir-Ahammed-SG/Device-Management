# Build and fixture checks only. Never invoke a production client script.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9]{8}-[A-Za-z0-9-]+$')][string]$ReleaseId
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Run this build with 64-bit Windows PowerShell 5.1.'
}
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
[void][IO.Directory]::CreateDirectory((Join-Path $projectRoot 'Docs\Validation'))
$sourceFiles=@(
    Get-Item -LiteralPath (Join-Path $sourceRoot 'SaaSKioskThoroughCheckScript.ps1'),(Join-Path $sourceRoot 'SubwayKioskThoroughCheck.ps1')
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
        $_.Extension -in '.ps1','.psm1','.psd1' -and
        $_.FullName -notlike ($projectRoot+'\output\*') -and
        $_.FullName -notlike ($projectRoot+'\Backups\*') -and
        $_.FullName -notlike ($projectRoot+'\Docs\*')
    }
)
foreach ($file in $sourceFiles) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($file.FullName+': '+($parseErrors | Out-String)) }
}
Write-Output ('PASS: parsed '+$sourceFiles.Count+' PowerShell source files.')
& (Join-Path $PSScriptRoot 'Build-Release.ps1') -ReleaseId $ReleaseId
$releaseRoot=Join-Path $projectRoot ('output\releases\'+$ReleaseId)
$entryPath=Join-Path $releaseRoot 'Start-DeviceManagement.ps1'
$manifest=Get-Content -LiteralPath (Join-Path $releaseRoot 'release.json') -Raw | ConvertFrom-Json
if ($manifest.ReleaseId -cne $ReleaseId -or $manifest.Delivery -cne 'InMemory') { throw 'Release identity mismatch.' }
if ((Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash -ine $manifest.BootstrapSHA256) { throw 'Release checksum mismatch.' }
$bytes=[IO.File]::ReadAllBytes($entryPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'CDN entry must not have a UTF-8 BOM.' }
$strictUtf8=New-Object Text.UTF8Encoding($false,$true)
$entry=$strictUtf8.GetString($bytes)
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($entry,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$resources'},$true))
if ($assignments.Count -ne 1) { throw 'Expected one embedded resource map.' }
$resourceAst=[Management.Automation.Language.Parser]::ParseInput($assignments[0].Right.Extent.Text,[ref]$tokens,[ref]$parseErrors)
$resources=$resourceAst.EndBlock.Statements[0].PipelineElements[0].Expression.SafeGetValue()
if ($resources.Count -ne $manifest.Files.Count -or $resources.Count -ne 19) { throw 'Runtime resource inventory changed; review the build manifest.' }
foreach ($file in $manifest.Files) {
    $relative=if ($file.Path -eq 'Deployment/MemoryRuntime.ps1') {'DeviceManagement/'+$file.Path} else {$file.Path}
    $source=Join-Path $sourceRoot $relative
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $file.SourceSHA256) { throw ('Source changed during build: '+$file.Path) }
    if (-not $resources.ContainsKey($file.Path)) { throw ('Missing resource '+$file.Path) }
    $resource=$resources[$file.Path]
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $actual=[BitConverter]::ToString($hash.ComputeHash([Convert]::FromBase64String($resource.Data))).Replace('-','') } finally { $hash.Dispose() }
    if ($actual -ine $resource.SHA256 -or $actual -ine $file.RuntimeSHA256) { throw ('Runtime checksum mismatch: '+$file.Path) }
}
Write-Output 'PASS: release bytes, manifest, current sources and all 19 runtime resources match.'
$fixtures=@(
    'Test-ChromeKioskInstallation.ps1',
    'Test-SaaSKioskInstallation.ps1',
    'Test-SubwayKioskInstallation.ps1',
    'Test-ApprovedReportFixes.ps1',
    'Test-FixAccountFilter.ps1',
    'Test-AuditBasedReports.ps1',
    'Test-AuditClientInput.ps1',
    'Test-ReportAgentName.ps1',
    'Test-FindingHighlights.ps1',
    'Test-LauncherInspection.ps1',
    'Test-KioskAccountProperties.ps1'
)
# A separate process prevents one fixture's mocks or preferences leaking to another.
foreach ($fixture in $fixtures) {
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $projectRoot ('Tests\'+$fixture)))
    if ($fixture -eq 'Test-ApprovedReportFixes.ps1') { $arguments+=@('-SourceRoot',$sourceRoot) }
    & (Join-Path $PSHOME 'powershell.exe') @arguments
    if ($LASTEXITCODE -ne 0) { throw ('Fixture failed: '+$fixture) }
}
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Tests\Test-CdnBootstrap.ps1') -ReleaseId $ReleaseId
if ($LASTEXITCODE -ne 0) { throw 'In-memory delivery fixtures failed.' }
Write-Output ('PASS: verified release '+$ReleaseId)
