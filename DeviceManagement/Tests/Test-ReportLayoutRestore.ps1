# Exercise the restore tool against disposable source copies, never production sources.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$tool=Join-Path $projectRoot 'Tools\Restore-ReportLayout.ps1'
$point='20261023-fix-component-filter-01'
$record=[IO.File]::ReadAllText((Join-Path $projectRoot ('Backups\ReportLayouts\'+$point+'.json'))) | ConvertFrom-Json
$fixtureRoot=Join-Path $projectRoot ('output\report-columns\restore-tests\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function Assert-Restore {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$sources=@('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')
$originalHashes=@{}
foreach($name in $sources){
    $source=Join-Path $sourceRoot $name
    $originalHashes[$name]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    # An unrelated edit must survive a report-only restore.
    [IO.File]::WriteAllText((Join-Path $fixtureRoot $name),('# Unrelated later edit'+"`r`n"+[IO.File]::ReadAllText($source)),$utf8)
}
$listed=@(& $tool -List)
Assert-Restore ($listed.RestorePoint -contains $point) 'Restore point was not listed.'
$before=@{}
foreach($name in $sources){$before[$name]=[IO.File]::ReadAllText((Join-Path $fixtureRoot $name))}
& $tool -RestorePoint $point -SourceRoot $fixtureRoot -WhatIf
foreach($name in $sources){Assert-Restore ([IO.File]::ReadAllText((Join-Path $fixtureRoot $name)) -ceq $before[$name]) 'WhatIf changed a source file.'}
& $tool -RestorePoint $point -SourceRoot $fixtureRoot -Confirm:$false
$restored=@{}
foreach($client in $record.Clients){
    $text=[IO.File]::ReadAllText((Join-Path $fixtureRoot $client.FileName))
    Assert-Restore ($text.StartsWith('# Unrelated later edit')) 'Restore overwrote an unrelated edit.'
    foreach($change in $client.Changes){if(-not $change.Before){Assert-Restore (-not $text.Contains(('function '+$change.Name+' {'))) 'Added presentation helper was not removed.'}}
    foreach($change in $client.Changes){if($change.Before){Assert-Restore ($text.Contains([string]$change.Before)) ('Original report block was not restored: '+$change.Name)}}
    Assert-Restore ($text.Contains('$wuChanges.Add') -and $text.Contains('$legacyChanges.Add') -and $text.Contains('$zabbixInstalledThisRun')) 'Report restore removed unrelated operation logging.'
    $restored[$client.FileName]=$text
}
& $tool -RestorePoint $point -SourceRoot $fixtureRoot -Confirm:$false
foreach($name in $sources){Assert-Restore ([IO.File]::ReadAllText((Join-Path $fixtureRoot $name)) -ceq $restored[$name]) 'Repeat restore was not idempotent.'}
# A later report edit in the second client must prevent writes to both clients.
foreach($name in $sources){[IO.File]::WriteAllText((Join-Path $fixtureRoot $name),$before[$name],$utf8)}
$secondPath=Join-Path $fixtureRoot $sources[1]
[IO.File]::WriteAllText($secondPath,($before[$sources[1]].Replace('# Keep unresolved checks and this run''s recorded repairs in the Fix report.','# Later report presentation change.')),$utf8)
$guarded=@{}
foreach($name in $sources){$guarded[$name]=[IO.File]::ReadAllText((Join-Path $fixtureRoot $name))}
$rejected=$false
try{& $tool -RestorePoint $point -SourceRoot $fixtureRoot -Confirm:$false}catch{$rejected=$_.Exception.Message -match 'changed since this restore point'}
Assert-Restore $rejected 'A later report change was overwritten.'
foreach($name in $sources){
    Assert-Restore ([IO.File]::ReadAllText((Join-Path $fixtureRoot $name)) -ceq $guarded[$name]) 'Preflight failure wrote a client file.'
    Assert-Restore ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $name) -Algorithm SHA256).Hash -ceq $originalHashes[$name]) 'Test modified a production source.'
}
Write-Output 'PASS: Restore-point listing, WhatIf, both-client restoration, unchanged unrelated edits/logging, repeat restore and later-layout rejection. Production sources were not restored.'
