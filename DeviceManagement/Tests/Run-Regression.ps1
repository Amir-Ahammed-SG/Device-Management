# Run maintained fixtures in fresh processes. No production entry point is run.
[CmdletBinding()]
param([ValidatePattern('^[0-9]{8}-[A-Za-z0-9-]+$')][string]$ReleaseId,[switch]$IncludeBrowser)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $ReleaseId){
    $ReleaseId=[DateTime]::UtcNow.ToString('yyyyMMdd')+'-regression-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    [void](& (Join-Path $root 'Deployment\Build-Release.ps1') -ReleaseId $ReleaseId)
}
if(-not (Test-Path -LiteralPath (Join-Path $root ('output\releases\'+$ReleaseId+'\release.json')))){throw 'Build the selected release before running its regression fixtures.'}
$output=Join-Path $root ('output\regression\'+$ReleaseId)
[void][IO.Directory]::CreateDirectory($output)
$results=New-Object 'Collections.Generic.List[object]'
$utf8=New-Object Text.UTF8Encoding($false)
foreach($test in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File | Sort-Object Name){
    $browser=$test.Name -in @('Test-CombinedReportBrowser.ps1','Test-ReportClipboard.ps1')
    if($browser -and -not $IncludeBrowser){
        $results.Add([pscustomobject]@{Test=$test.Name;Status='Skipped';ExitCode=$null;Reason='Use -IncludeBrowser with Edge and Node.js.'})
        continue
    }
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$test.FullName)
    if($test.Name -eq 'Test-MemoryDelivery.ps1'){$arguments+=@('-ReleaseId',$ReleaseId)}
    $log=Join-Path $output ($test.BaseName+'.log')
    $ErrorActionPreference='Continue'
    & (Join-Path $PSHOME 'powershell.exe') @arguments *> $log
    $code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    $status=if($code -eq 0){'Passed'}else{'Failed'}
    $results.Add([pscustomobject]@{Test=$test.Name;Status=$status;ExitCode=$code;Log=$log})
    [IO.File]::WriteAllText((Join-Path $output 'results.json'),(ConvertTo-Json -InputObject $results.ToArray() -Depth 4),$utf8)
    Write-Output ($status+': '+$test.Name)
    if($code -ne 0){Get-Content -LiteralPath $log -Tail 12 | Write-Output}
}
$failed=@($results | Where-Object Status -EQ 'Failed')
$passed=@($results | Where-Object Status -EQ 'Passed')
$skipped=@($results | Where-Object Status -EQ 'Skipped')
[IO.File]::WriteAllText((Join-Path $output 'results.json'),(ConvertTo-Json -InputObject $results.ToArray() -Depth 4),$utf8)
Write-Output ('Regression: '+$passed.Count+' passed, '+$failed.Count+' failed, '+$skipped.Count+' explicitly skipped. Results: '+$output)
if($failed.Count){exit 1}
exit 0
