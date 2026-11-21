# Static inspection only: no analyzed script is executed and no -Fix is used.
[CmdletBinding()]
param(
    [ValidateSet('Gate','ReportOnly')][string]$Mode='Gate',
    [string]$ProjectRoot,
    [string]$PolicyPath,
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess){throw 'Run static analysis in 64-bit Windows PowerShell 5.1, matching the release runtime.'}
if([string]::IsNullOrWhiteSpace($ProjectRoot)){$ProjectRoot=Split-Path $PSScriptRoot -Parent}
$project=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
if([string]::IsNullOrWhiteSpace($PolicyPath)){$PolicyPath=Join-Path $PSScriptRoot 'ScriptAnalysis\Policy.psd1'}
$settingsPath=Join-Path $PSScriptRoot 'ScriptAnalysis\Settings.psd1'
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Join-Path $project 'output\script-analysis'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
$outputRoot=[IO.Path]::GetFullPath((Join-Path $project 'output')).TrimEnd('\','/')
if($output -ine $outputRoot -and -not $output.StartsWith($outputRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Analysis reports must stay under the selected project output directory.'}
[void][IO.Directory]::CreateDirectory($output)
$utf8=New-Object Text.UTF8Encoding($false)
$pending=[ordered]@{Analyzer='PSScriptAnalyzer';AnalyzerVersion='NotLoaded';Status='NotCompleted';Complete=$false;GeneratedAt=[DateTimeOffset]::UtcNow.ToString('o');Message='Analysis has not completed. Check the command failure before using this report.'}
[IO.File]::WriteAllText((Join-Path $output 'report.json'),($pending|ConvertTo-Json),$utf8)
[IO.File]::WriteAllText((Join-Path $output 'report.md'),"# PowerShell static analysis`n`nAnalysis has not completed. Check the command failure before using this report.`n",$utf8)
$policy=Import-PowerShellDataFile -LiteralPath $PolicyPath
$pending.AnalyzerVersion=$policy.AnalyzerVersion
[IO.File]::WriteAllText((Join-Path $output 'report.json'),($pending|ConvertTo-Json),$utf8)
if('Error' -notin $policy.BlockingSeverities){throw 'Error severity must remain blocking in the analysis policy.'}
$settings=Import-PowerShellDataFile -LiteralPath $settingsPath
if('Error' -notin $settings.Severity -or 'Warning' -notin $settings.Severity -or -not $settings.IncludeDefaultRules){throw 'Default Error and Warning rules must remain enabled.'}
Import-Module -Name PSScriptAnalyzer -RequiredVersion ([version]$policy.AnalyzerVersion) -Force -ErrorAction Stop
$availableRules=@(Get-ScriptAnalyzerRule | ForEach-Object RuleName)
foreach($rule in $policy.BlockingRules){if($rule -notin $availableRules){throw ('Unknown blocking analyzer rule: '+$rule)}}
function Test-ExcludedAnalysisPath([string]$Path){
    $relative=$Path.Substring($project.Length).TrimStart('\','/')
    foreach($segment in ($relative -split '[\\/]')){if($segment -in $policy.ExcludedDirectories){return $true}}
    return $false
}
$files=New-Object 'Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
function Add-AnalysisSource([IO.FileSystemInfo]$Item){
    if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return}
    if(Test-ExcludedAnalysisPath $Item.FullName){return}
    if($Item.PSIsContainer){foreach($child in (Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)){Add-AnalysisSource $child};return}
    if($Item.Extension -in @('.ps1','.psm1','.psd1')){$files[$Item.FullName.Substring($project.Length+1).Replace('\','/')]=$Item.FullName}
}
foreach($sourcePath in $policy.SourcePaths){
    if([IO.Path]::IsPathRooted($sourcePath)){throw 'Analysis source paths must be relative to the project.'}
    $absolute=[IO.Path]::GetFullPath((Join-Path $project $sourcePath))
    if(-not $absolute.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Analysis source escaped the project directory.'}
    Add-AnalysisSource (Get-Item -LiteralPath $absolute -Force -ErrorAction Stop)
}
if(-not $files.Count){throw 'No source files were selected; analysis cannot pass without coverage.'}
$findings=New-Object 'Collections.Generic.List[object]'
$engineErrors=New-Object 'Collections.Generic.List[string]'
$sourceHashes=New-Object 'Collections.Generic.List[object]'
foreach($relative in $files.Keys){
    $path=$files[$relative]
    $sourceHashes.Add([pscustomobject]@{Path=$relative;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()})
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){
        foreach($problem in $parseErrors){$findings.Add([pscustomobject]@{Path=$relative;Line=$problem.Extent.StartLineNumber;Column=$problem.Extent.StartColumnNumber;RuleName='ParserError';Severity='Error';Message=$problem.Message;Blocking=$true})}
        continue
    }
    try{
        foreach($finding in @(Invoke-ScriptAnalyzer -Path $path -Settings $settingsPath -ErrorAction Stop)){
            $severity=[string]$finding.Severity
            $blocking=$severity -in $policy.BlockingSeverities -or $finding.RuleName -in $policy.BlockingRules
            $findings.Add([pscustomobject]@{Path=$relative;Line=$finding.Line;Column=$finding.Column;RuleName=$finding.RuleName;Severity=$severity;Message=$finding.Message;Blocking=[bool]$blocking})
        }
    }catch{$engineErrors.Add($relative+': '+$_.Exception.Message)}
}
foreach($source in $sourceHashes){if((Get-FileHash -LiteralPath $files[$source.Path] -Algorithm SHA256).Hash -ine $source.SHA256){$engineErrors.Add('Source changed during analysis: '+$source.Path)}}
$ordered=@($findings | Sort-Object Path,Line,Column,RuleName)
$errors=@($ordered|Where-Object Severity -eq 'Error').Count
$warnings=@($ordered|Where-Object Severity -eq 'Warning').Count
$blocking=@($ordered|Where-Object Blocking).Count
$status=if($engineErrors.Count){'ToolFailure'}elseif($blocking){'FindingsDetected'}else{'Passed'}
$report=[ordered]@{
    Analyzer='PSScriptAnalyzer';AnalyzerVersion=$policy.AnalyzerVersion;PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    GeneratedAt=[DateTimeOffset]::UtcNow.ToString('o');Mode=$Mode;Status=$status;Complete=($engineErrors.Count -eq 0)
    PolicySHA256=(Get-FileHash -LiteralPath $PolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    SettingsSHA256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    FileCount=$files.Count;ErrorCount=$errors;WarningCount=$warnings;BlockingCount=$blocking
    BlockingSeverities=@($policy.BlockingSeverities);BlockingRules=@($policy.BlockingRules)
    Sources=$sourceHashes.ToArray();ToolErrors=$engineErrors.ToArray();Findings=$ordered
}
[void][IO.Directory]::CreateDirectory($output)
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $output 'report.json'),($report|ConvertTo-Json -Depth 7),$utf8)
$lines=New-Object 'Collections.Generic.List[string]'
$lines.Add('# PowerShell static analysis report');$lines.Add('')
$lines.Add(('Analyzer: PSScriptAnalyzer '+$policy.AnalyzerVersion+' | Windows PowerShell '+$PSVersionTable.PSVersion))
$lines.Add(('Status: '+$status+' | Mode: '+$Mode+' | Files: '+$files.Count+' | Errors: '+$errors+' | Warnings: '+$warnings+' | Blocking: '+$blocking))
$lines.Add('');$lines.Add('Warnings remain visible and are advisory unless their rule is explicitly blocking. Static analysis does not execute device checks or replace functional tests.');$lines.Add('')
$lines.Add('| Rule | Severity | Count |');$lines.Add('| --- | --- | --- |')
foreach($group in ($ordered|Group-Object RuleName,Severity|Sort-Object Count -Descending)){$first=$group.Group[0];$lines.Add(('| '+$first.RuleName+' | '+$first.Severity+' | '+$group.Count+' |'))}
$lines.Add('');$lines.Add('## Findings');$lines.Add('');$lines.Add('| File | Line | Severity | Rule | Blocking | Message |');$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach($finding in $ordered){$message=([string]$finding.Message).Replace('|','\|') -replace '[\r\n]+',' ';$lines.Add(('| '+$finding.Path+' | '+$finding.Line+' | '+$finding.Severity+' | '+$finding.RuleName+' | '+$finding.Blocking+' | '+$message+' |'))}
if($engineErrors.Count){$lines.Add('');$lines.Add('## Incomplete analysis');foreach($problem in $engineErrors){$lines.Add('- '+$problem)}}
[IO.File]::WriteAllText((Join-Path $output 'report.md'),($lines -join "`n")+"`n",$utf8)
Write-Output ('PSScriptAnalyzer '+$policy.AnalyzerVersion+': '+$files.Count+' files, '+$errors+' errors, '+$warnings+' warnings, '+$blocking+' blocking findings.')
Write-Output ('Reports: '+$output)
if($engineErrors.Count){throw 'Static analysis did not complete. See report.json tool errors.'}
if($Mode -eq 'Gate' -and $blocking){throw ('Static analysis gate failed with '+$blocking+' blocking findings.')}
