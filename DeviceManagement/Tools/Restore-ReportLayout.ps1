<#
.SYNOPSIS
    Lists or restores saved Thorough Check report layouts without running checks.
.EXAMPLE
    .\Tools\Restore-ReportLayout.ps1 -List
.EXAMPLE
    .\Tools\Restore-ReportLayout.ps1 -RestorePoint 20261022-report-columns-01 -WhatIf
.EXAMPLE
    .\Tools\Restore-ReportLayout.ps1 -RestorePoint 20261022-report-columns-01
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [switch]$List,
    [ValidatePattern('^[0-9]{8}-[A-Za-z0-9-]+$')][string]$RestorePoint,
    [string]$SourceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)
$ErrorActionPreference='Stop'
$backupRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'Backups\ReportLayouts'
function Get-LayoutHash {
    param([AllowEmptyString()][string]$Text)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','') }
    finally { $hasher.Dispose() }
}
function Get-LayoutBlock {
    param($Ast,[string]$Name)
    if($Name -eq 'ReportRenderer'){
        $matches=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Writing HTML report'},$true))
        if($matches.Count -ne 1){throw 'Cannot identify the report renderer safely.'}
        return $matches[0].Finally
    }
    if($Name -notin @('ConvertTo-ThoroughFinalReportHtml','Format-ThoroughFinalServiceRecovery','Get-ThoroughReportBlockAlignmentScript','Format-ThoroughFixFindings','Get-ThoroughFixAccountReportView','Test-ThoroughFixReportRow','Get-ThoroughReportAppliedHtml','Get-KioskReportPath','New-ThoroughReportSnapshot','New-ThoroughReportBundleHtml','Read-ThoroughReportBundleState','Save-ThoroughReportBundle','Format-ReportState','Get-AccountReportView','Get-ReportRequirement','Get-ThoroughReportCollectedValueState','Get-ThoroughReportFindingComparison','Format-ThoroughReportFindingHighlights','Format-ThoroughReportFieldLabels','Format-ThoroughReportDateTime','Format-ThoroughReportDuration','Format-ThoroughReportTriggerDetails','Get-ThoroughReportDisplayRows','New-ThoroughLegacyServiceReportRow')){throw 'Unsupported report layout block.'}
    $matches=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($matches.Count -gt 1){throw ('Ambiguous report helper: '+$Name)}
    if($matches.Count){return $matches[0]}
}
function Read-LayoutAst {
    param([string]$Text)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('PowerShell syntax validation failed: '+($errors | Out-String))}
    $ast
}
if($List -or [string]::IsNullOrWhiteSpace($RestorePoint)){
    Get-ChildItem -LiteralPath $backupRoot -Filter '*.json' -File -ErrorAction Stop | ForEach-Object {
        $record=[IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json
        [pscustomobject]@{RestorePoint=$record.Id;Created=$record.Created;Description=$record.Description}
    }
    return
}
$recordPath=Join-Path $backupRoot ($RestorePoint+'.json')
$record=[IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
if($record.Version -ne 1 -or $record.Id -cne $RestorePoint -or @($record.Clients).Count -ne 2){throw 'Invalid report layout restore point.'}
$sourceDirectory=[IO.Path]::GetFullPath($SourceRoot)
$plans=New-Object 'Collections.Generic.List[object]'
$seen=New-Object 'Collections.Generic.HashSet[string]'
# Validate both clients and every saved block before writing either file.
foreach($client in $record.Clients){
    if($client.FileName -notin @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1') -or -not $seen.Add($client.FileName)){throw 'Invalid client source in restore point.'}
    $path=Join-Path $sourceDirectory $client.FileName
    $before=[IO.File]::ReadAllText($path)
    $ast=Read-LayoutAst $before
    $edits=New-Object 'Collections.Generic.List[object]'
    foreach($change in $client.Changes){
        if((Get-LayoutHash ([string]$change.Before)) -cne $change.BeforeSHA256){throw 'Restore point content failed checksum verification.'}
        $block=Get-LayoutBlock $ast $change.Name
        if(-not $block){
            if([string]$change.Before -eq ''){continue}
            throw ('Report layout block is missing: '+$change.Name)
        }
        $currentHash=Get-LayoutHash $block.Extent.Text
        if($currentHash -ceq $change.BeforeSHA256){continue}
        if($currentHash -cne $change.AfterSHA256){throw ('Report layout has changed since this restore point: '+$client.FileName+'/'+$change.Name+'. No files were changed.')}
        $edits.Add([pscustomobject]@{Start=$block.Extent.StartOffset;Length=$block.Extent.Text.Length;Text=[string]$change.Before})
    }
    $after=$before
    foreach($edit in @($edits | Sort-Object Start -Descending)){$after=$after.Remove($edit.Start,$edit.Length).Insert($edit.Start,$edit.Text)}
    [void](Read-LayoutAst $after)
    if($after -cne $before){$plans.Add([pscustomobject]@{Path=$path;Before=$before;After=$after})}
}
if(-not $plans.Count){Write-Output 'The saved report layout is already restored.';return}
if(-not $PSCmdlet.ShouldProcess(($plans.Path -join ', '),('Restore report layout '+$RestorePoint))){return}
$utf8=New-Object Text.UTF8Encoding($false)
$written=New-Object 'Collections.Generic.List[object]'
try{
    foreach($plan in $plans){
        # Recheck after preflight so a concurrent edit is never overwritten.
        if([IO.File]::ReadAllText($plan.Path) -cne $plan.Before){throw 'Source changed after preflight; restoration cancelled.'}
        $stage=Join-Path (Split-Path $plan.Path -Parent) ('.ReportLayout-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            [IO.File]::WriteAllText($stage,$plan.After,$utf8)
            [IO.File]::Replace($stage,$plan.Path,[System.Management.Automation.Language.NullString]::Value)
            $written.Add($plan)
            if([IO.File]::ReadAllText($plan.Path) -cne $plan.After){throw 'Restored report layout failed readback verification.'}
        }finally{if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Force -ErrorAction Stop}}
    }
}catch{
    $failure=$_
    foreach($plan in $written){
        try{
            if([IO.File]::ReadAllText($plan.Path) -cne $plan.After){throw 'Source changed after restoration; automatic undo would overwrite a concurrent edit.'}
            [IO.File]::WriteAllText($plan.Path,$plan.Before,$utf8)
        }
        catch{Write-Warning ('Could not undo the interrupted source restore: '+$plan.Path)}
    }
    throw $failure
}
Write-Output ('Restored report layout '+$RestorePoint+'. Existing device settings and unrelated source code were not changed.')
