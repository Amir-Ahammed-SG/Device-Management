# Real report-file I/O against disposable fixtures. No device operations run.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'output\single-file-reports\Bundle.functions.ps1')
function New-ThoroughReportId {'OMK-'+(Get-Random -Minimum 0 -Maximum 1000000).ToString('D6')}
function Assert-Store {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$fixtureRoot=Join-Path $root ('output\single-file-reports\store-tests\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8=New-Object Text.UTF8Encoding($false)
function New-Snapshot {
    param([string]$Client,[string]$Mode,[string]$Id,[string]$Marker)
    $path=Join-Path $root ('output\final-report-test\'+$Client+'-'+$Mode+'-TestPreview.html')
    $html=[IO.File]::ReadAllText($path)
    $oldId=[regex]::Match($html,'<th>Report ID</th><td>(OMK-\d{6})</td>').Groups[1].Value
    $html=$html.Replace('<td>'+$oldId+'</td>','<td>'+$Id+'</td>').Replace('</main>','<p>'+[Net.WebUtility]::HtmlEncode($Marker)+'</p></main>')
    [pscustomobject]@{Mode=$Mode;ReportId=$Id;GeneratedAt='22-Oct-2026 19:00:00 +06:00';HtmlBase64=[Convert]::ToBase64String($utf8.GetBytes($html));ExportFileName='Thorough Check Report.html'}
}
foreach($client in @('SaaS','Subway')){
    $clientFolder=Join-Path $fixtureRoot $client;[void][IO.Directory]::CreateDirectory($clientFolder)
    $path=Join-Path $clientFolder 'Thorough Check Reports.html'
    $audit=New-Snapshot $client Audit OMK-110001 ('AUDIT-ONLY '+[char]9731+' & <value>')
    $fix=New-Snapshot $client Fix OMK-110002 'FIX-ONLY'
    $final=New-Snapshot $client Final OMK-110003 'FINAL-AFTER-FIX'
    $saved=Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($audit) Audit
    Assert-Store ($saved -ceq $path) 'Writer changed the report path.'
    $first=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-Store ($first.Reports.Audit.HtmlBase64 -ceq $audit.HtmlBase64 -and $null -eq $first.Reports.Fix -and $null -eq $first.Reports.Final) 'An unexecuted mode was filled with invented data.'
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($fix,$final) Fix)
    $applied=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-Store ($applied.BundleId -ceq $first.BundleId -and $applied.CreatedAt -ceq $first.CreatedAt) 'An update replaced the combined-report identity.'
    Assert-Store ($applied.Reports.Audit.HtmlBase64 -ceq $audit.HtmlBase64 -and $applied.Reports.Fix.HtmlBase64 -ceq $fix.HtmlBase64 -and $applied.Reports.Final.HtmlBase64 -ceq $final.HtmlBase64) 'A saved report was lost, changed or copied into the wrong mode.'
    $freshFinal=New-Snapshot $client Final OMK-110004 'FRESH-READ-ONLY-FINAL'
    [void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($freshFinal) Final)
    $updated=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($path))
    Assert-Store ($updated.Reports.Audit.HtmlBase64 -ceq $audit.HtmlBase64 -and $updated.Reports.Fix.HtmlBase64 -ceq $fix.HtmlBase64 -and $updated.Reports.Final.HtmlBase64 -ceq $freshFinal.HtmlBase64 -and $updated.LatestMode -eq 'Final') 'Final verification rewrote Audit or Fix.'
    Assert-Store (@(Get-ChildItem -LiteralPath $clientFolder -File).Count -eq 1) 'Successful updates left separate reports or temporary files.'
    $before=[IO.File]::ReadAllText($path)
    foreach($problem in @('wrong-client','wrong-computer','invalid-snapshot')){
        $failed=$false
        try{
            switch($problem){
                'wrong-client' {[void](Save-ThoroughReportBundle $path $(if($client -eq 'SaaS'){'Subway'}else{'SaaS'}) 'FIXTURE-PC' @($audit) Audit)}
                'wrong-computer' {[void](Save-ThoroughReportBundle $path $client 'OTHER-PC' @($audit) Audit)}
                'invalid-snapshot' {$bad=$audit.PSObject.Copy();$bad.HtmlBase64='not base64';[void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($bad) Audit)}
            }
        }catch{$failed=$true}
        Assert-Store ($failed -and [IO.File]::ReadAllText($path) -ceq $before) ('Invalid update overwrote a report: '+$problem)
    }
    [IO.File]::WriteAllText($path,'<html>Existing unsupported report</html>',$utf8)
    $failed=$false
    try{[void](Save-ThoroughReportBundle $path $client 'FIXTURE-PC' @($audit) Audit)}catch{$failed=$true}
    Assert-Store ($failed -and [IO.File]::ReadAllText($path) -ceq '<html>Existing unsupported report</html>') 'An unsupported existing report was overwritten.'
    Write-Output ('PASS: '+$client+' one-file Audit -> Fix/Final -> fresh Final; exact snapshot/identity retention, unexecuted modes empty, invalid updates preserved and no temporary files.')
}
