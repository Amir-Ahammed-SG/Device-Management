# Current report schema and reusable browser fixtures; no device operations.
. (Join-Path $PSScriptRoot 'ReportFixtureSupport.ps1')
$ErrorActionPreference='Stop'
New-KioskReportFixtures
$layout=Join-Path $script:KioskTestProjectRoot 'output\report-layout'
foreach($client in @('SaaS','Subway')){foreach($mode in @('Audit','Fix','Final')){
    $name=$client+'-'+$(if($mode -eq 'Fix'){'Apply-Fix'}else{$mode})+'-preview.html'
    $html=[IO.File]::ReadAllText((Join-Path $layout $name))
    foreach($required in @('CLIENT DETAILS','CONFIGURATION CHECK','Fixture &amp; &lt;Branch&gt;','DEVICE-01','Fixture Agent','@media print')){
        if(-not $html.Contains($required)){throw ('Missing report content: '+$client+'/'+$mode+'/'+$required)}
    }
    if(-not $html.Contains('<th>Client Type</th><td>'+$client+'</td>')){throw 'Client identity crossed reports.'}
    if($html -match 'Report mode:|<th>Report ID</th>|<th>Computer name</th>'){throw 'Retired metadata fields remain.'}
    if([regex]::Matches($html,'<strong>Generated Time:</strong>').Count -ne 1){throw 'Report timestamp is missing or duplicated.'}
    $headers=if($mode -eq 'Audit'){@('Component','Shortcut / Command','Setting','Required','Findings')}elseif($mode -eq 'Fix'){@('Component','Shortcut / Command','Setting','Findings','Applied')}else{@('Component','Setting','Status')}
    foreach($label in $headers){if(-not $html.Contains('<th scope="col">'+$label+'</th>')){throw ('Report column missing: '+$mode+'/'+$label)}}
    if($mode -eq 'Final'){
        if($html -match 'class="command-copy"|class="badge'){throw 'Final contains actionable commands or verification badges.'}
    }else{
        foreach($command in @('lusrmgr.msc','net user &quot;SELISE-KIOSK&quot;','net user &quot;Administrator&quot;','notepad.exe &quot;C:\Sample &amp; Support\appsettings.json&quot;')){
            if(-not $html.Contains($command)){throw ('Command display/copy encoding changed: '+$command)}
        }
    }
    Write-Output ('PASS: '+$client+'/'+$mode+' current per-setting columns, safe metadata/commands, fixture paths, timestamp and read-only Final presentation.')
}}
