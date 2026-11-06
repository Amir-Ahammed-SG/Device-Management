# Disposable source fixtures only. No device script, installer or service is run.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$driver=Join-Path $root 'Deployment\Test-ScriptAnalysis.ps1'
$policy=Import-PowerShellDataFile (Join-Path $root 'Deployment\ScriptAnalysis\Policy.psd1')
$fixture=Join-Path $root ('output\static-analysis-tests\'+[guid]::NewGuid().ToString('N'))
$utf8=New-Object Text.UTF8Encoding($false)
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Core'))
$source=Join-Path $fixture 'Main.ps1'
$policyPath=Join-Path $fixture 'Policy.psd1'
$output=Join-Path $fixture 'output\reports'
function Assert-Static([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Set-FixturePolicy([string]$Version=$policy.AnalyzerVersion,[string]$SourcePath='Main.ps1',[string]$ExtraRule=''){
    $text=@'
@{
    AnalyzerVersion='@@VERSION@@'
    BlockingSeverities=@('Error')
    BlockingRules=@('PSAvoidUsingPlainTextForPassword','PSAvoidUsingConvertToSecureStringWithPlainText'@@EXTRA@@)
    SourcePaths=@('@@SOURCE@@','Core')
    ExcludedDirectories=@('output','Backups','Docs','Tests','node_modules')
}
'@
    $extra=if($ExtraRule){",'$ExtraRule'"}else{''}
    [IO.File]::WriteAllText($policyPath,$text.Replace('@@VERSION@@',$Version).Replace('@@SOURCE@@',$SourcePath).Replace('@@EXTRA@@',$extra),$utf8)
}
function Run-Fixture([string]$Mode='Gate'){
    $log=Join-Path $fixture ('run-'+[guid]::NewGuid().ToString('N')+'.log')
    $previousPreference=$ErrorActionPreference
    try{
        # Windows PowerShell turns a native child's redirected stderr into
        # ErrorRecords. Capture expected negative-test exits without aborting.
        $ErrorActionPreference='Continue'
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $driver -ProjectRoot $fixture -PolicyPath $policyPath -OutputDirectory $output -Mode $Mode *> $log
        $exitCode=$LASTEXITCODE
    }finally{$ErrorActionPreference=$previousPreference}
    [pscustomobject]@{ExitCode=$exitCode;Report=$(if(Test-Path -LiteralPath (Join-Path $output 'report.json')){Get-Content -LiteralPath (Join-Path $output 'report.json') -Raw|ConvertFrom-Json}else{$null});Log=$log}
}
Set-FixturePolicy
[IO.File]::WriteAllText($source,"throw 'Analyzed source must never execute.'`n",$utf8)
$result=Run-Fixture
Assert-Static ($result.ExitCode -eq 0 -and $result.Report.Complete -and $result.Report.FileCount -eq 1 -and $result.Report.ErrorCount -eq 0) 'Clean source did not pass static analysis without execution.'
$before=(Get-FileHash -LiteralPath $source).Hash
$result=Run-Fixture
Assert-Static ($result.ExitCode -eq 0 -and (Get-FileHash -LiteralPath $source).Hash -ceq $before) 'Analysis modified the input source.'
[IO.File]::WriteAllText($source,"gci`n",$utf8)
$result=Run-Fixture
Assert-Static ($result.ExitCode -eq 0 -and $result.Report.WarningCount -gt 0 -and $result.Report.BlockingCount -eq 0) 'Advisory warnings incorrectly blocked CI or were hidden.'
[IO.File]::WriteAllText($source,'function Test-FixtureCredential { param([string]$Password) $Password }',$utf8)
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and @($result.Report.Findings|Where-Object {$_.RuleName -eq 'PSAvoidUsingPlainTextForPassword' -and $_.Blocking}).Count -gt 0) 'The plaintext-password security rule did not block.'
[IO.File]::WriteAllText($source,'function Broken {',$utf8)
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and $result.Report.ErrorCount -gt 0 -and $result.Report.BlockingCount -gt 0 -and $result.Report.Complete) 'Parser errors were not recorded and blocked.'
$result=Run-Fixture -Mode ReportOnly
Assert-Static ($result.ExitCode -eq 0 -and $result.Report.Status -eq 'FindingsDetected' -and $result.Report.ErrorCount -gt 0) 'Report-only mode hid errors or returned a misleading Passed status.'
[IO.File]::WriteAllText($source,"Write-Output 'Fixture'`n",$utf8)
foreach($directory in @('output','Backups','Docs','Tests','node_modules')){
    $path=Join-Path $fixture ('Core\'+$directory)
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'Excluded.ps1'),'function Broken {',$utf8)
}
$result=Run-Fixture
Assert-Static ($result.ExitCode -eq 0 -and $result.Report.FileCount -eq 1) 'Excluded generated, backup or test sources were analyzed.'
Set-FixturePolicy -SourcePath 'Missing.ps1'
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete -and $result.Report.Status -eq 'NotCompleted') 'A missing source left a stale successful report or passed.'
Set-FixturePolicy -SourcePath '..\Outside.ps1'
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete) 'A source outside the selected project was accepted.'
Set-FixturePolicy -Version '99.99.99'
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete) 'A missing pinned analyzer version was silently ignored.'
Set-FixturePolicy -ExtraRule 'UnknownSecurityRule'
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete) 'A misspelled blocking rule was silently ignored.'
Set-FixturePolicy -SourcePath 'Core'
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete) 'An empty source inventory passed.'
[IO.File]::WriteAllText($policyPath,'@{ BrokenPolicy = ',$utf8)
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete -and $result.Report.Status -eq 'NotCompleted') 'An invalid policy left a stale successful report.'
Remove-Item -LiteralPath $policyPath
$result=Run-Fixture
Assert-Static ($result.ExitCode -ne 0 -and -not $result.Report.Complete -and $result.Report.Status -eq 'NotCompleted') 'A missing policy left a stale successful report.'
Write-Output 'PASS: 14 static-analysis scenarios: clean/advisory/security/parser gates, report-only mode, excluded paths, unchanged sources, stale-report prevention, traversal, missing version, unknown rule, empty coverage, and invalid/missing policy failures.'
exit 0
