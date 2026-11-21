. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('output\service-endpoint-repair\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert-Endpoint {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    Set-KioskTestClient $client
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-Endpoint (-not $errors.Count) 'Expanded engine does not parse.'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $required=Get-ThoroughServiceEndpointRequirements
    $text=@'
{
  // Keep the customer's comments and formatting.
  "PaymentService": "PRINT",
  "MonitoringServiceBaseUrl": "https://old.example.test/monitor", // comment retained
  "CmsGatewayBaseUrl": "https://old.example.test/cms",
  "OrderServiceBaseUrl": "https://old.example.test/orders",
  "ApiKey": "FAKE-SECRET-FOR-PRESERVATION-TEST",
  "TenantId": "FAKE-TENANT",
  "GetOrdersEndpoint": "/CmsGateway/Query/GetOrders",
  "SavePaymentServicePingEndPoint": "/EnterpriseKioskBackOffice/Monitoring/SaveServicePing",
  "Nested": {"MonitoringServiceBaseUrl": "keep-nested-value"},
  "Unrelated": "text with \"quotes\", // and /* string content */",
  /* "OrderServiceBaseUrl": "comment-only" */
  "Enabled": false
}
'@
    $candidate=Update-ThoroughServiceEndpointText $text
    $expected=$text.Replace('https://old.example.test/monitor',$required.MonitoringServiceBaseUrl).Replace('https://old.example.test/cms',$required.CmsGatewayBaseUrl).Replace('https://old.example.test/orders',$required.OrderServiceBaseUrl)
    Assert-Endpoint ($candidate.Text -ceq $expected -and $candidate.ChangedKeys.Count -eq 3) 'Changes escaped the three approved URL values.'
    Assert-Endpoint (@((Update-ThoroughServiceEndpointText $candidate.Text).ChangedKeys).Count -eq 0) 'Correct URLs were not idempotent.'
    foreach($inputText in @('{}','{ /* keep */ }',('{"ApiKey":"FAKE-KEEP" // keep newline comment' + "`n" + '}'),'{"MonitoringServiceBaseUrl":null,"Other":[1,{"nested":true}]}')){
        $added=Update-ThoroughServiceEndpointText $inputText
        $config=ConvertFrom-ThoroughPaymentJson $added.Text
        foreach($key in $required.Keys){Assert-Endpoint ((Get-ThoroughPaymentConfigValue $config $key) -ceq $required[$key]) 'Missing/null endpoint was not repaired.'}
    }
    foreach($bad in @('{"MonitoringServiceBaseUrl":{},"ApiKey":"FAKE"}','{"MonitoringServiceBaseUrl":"a","MonitoringServiceBaseUrl":"b"}','[]','{ broken }')){
        $failed=$false
        try {[void](Update-ThoroughServiceEndpointText $bad)}catch{$failed=$true}
        Assert-Endpoint $failed 'Ambiguous or malformed configuration was accepted for writing.'
    }
    $backups=Join-Path $fixture ($client+'-backups')
    foreach($encoding in @([Text.UTF8Encoding]::new($false),[Text.UTF8Encoding]::new($true),[Text.UnicodeEncoding]::new($false,$true))){
        $path=Join-Path $fixture ($client+'-'+$encoding.CodePage+'-'+$encoding.GetPreamble().Length+'.json')
        [IO.File]::WriteAllText($path,$text,$encoding)
        $before=[IO.File]::ReadAllBytes($path)
        $script:ApplyChanges=$false;$blocked=$false
        try {[void](Set-ThoroughServiceEndpoints -Path $path -BackupFolder $backups)}catch{$blocked=$true}
        Assert-Endpoint ($blocked -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($before)) 'Audit changed AppSettings.'
        $script:ApplyChanges=$true
        $change=Set-ThoroughServiceEndpoints -Path $path -BackupFolder $backups
        Assert-Endpoint ($change.Changed -and $change.ChangedKeys.Count -eq 3 -and [IO.File]::ReadAllText($path) -ceq $expected) 'Apply did not repair and read back the URLs.'
        Assert-Endpoint ([Convert]::ToBase64String([IO.File]::ReadAllBytes($change.BackupPath)) -ceq [Convert]::ToBase64String($before)) 'Backup differs from the original bytes.'
        $written=[IO.File]::ReadAllBytes($path);$prefix=$encoding.GetPreamble()
        if($prefix.Length){Assert-Endpoint ([Convert]::ToBase64String($written[0..($prefix.Length-1)]) -ceq [Convert]::ToBase64String($prefix)) 'AppSettings encoding/BOM changed.'}
        $second=Set-ThoroughServiceEndpoints -Path $path -BackupFolder $backups
        Assert-Endpoint (-not $second.Changed -and -not $second.BackupPath) 'Repeat Apply rewrote a correct configuration.'
    }
    # Force a failure after the real write; the original bytes must be restored.
    $originalWriter=(Get-Command Write-ThoroughTextChange).ScriptBlock
    $originalParser=(Get-Command ConvertFrom-ThoroughPaymentJson).ScriptBlock
    $script:forceReadbackFailure=$false
    function Write-ThoroughTextChange {param($Original,$Text,$BackupFolder) $result=& $originalWriter @PSBoundParameters;$script:forceReadbackFailure=$true;$result}
    function ConvertFrom-ThoroughPaymentJson {param($Text) if($script:forceReadbackFailure){throw 'Fixture readback failure'};& $originalParser $Text}
    $path=Join-Path $fixture ($client+'-rollback.json');[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false));$failed=$false
    try {[void](Set-ThoroughServiceEndpoints -Path $path -BackupFolder $backups)}catch{$failed=$_.Exception.Message -match 'Previous AppSettings restored'}
    Assert-Endpoint ($failed -and [IO.File]::ReadAllText($path) -ceq $text) 'Failed readback did not restore the original AppSettings.'
    Set-Item Function:Write-ThoroughTextChange -Value $originalWriter
    Set-Item Function:ConvertFrom-ThoroughPaymentJson -Value $originalParser
    $script:forceReadbackFailure=$false;$script:ApplyChanges=$false
    function Restart-Service {throw 'Endpoint repair must not restart the Payment Service'}
    function Get-Printer {throw 'Rendering queried printers'}
    # Run the engine's real AppSettings block against a fixture service folder.
    $sourceText=[KioskTestSource]::ReadAllText((Join-Path $root 'KioskThoroughCheck.ps1'))
    $start=$sourceText.IndexOf("    `$configurationStatus = 'Pass'")
    $end=$sourceText.IndexOf('    $appSettingsRowAdded = $true',$start)
    Assert-Endpoint ($start -ge 0 -and $end -gt $start) 'Engine inspection block not found.'
    $inspect=[scriptblock]::Create($sourceText.Substring($start,$end-$start))
    $serviceFolder=Join-Path $fixture ($client+'-engine');[void][IO.Directory]::CreateDirectory($serviceFolder)
    $primaryExecutablePath=Join-Path $serviceFolder 'FixturePayment.exe';[IO.File]::WriteAllText($primaryExecutablePath,'Fixture only')
    $appPath=Join-Path $serviceFolder 'appsettings.json';[IO.File]::WriteAllText($appPath,$text,[Text.UTF8Encoding]::new($false))
    $primaryService=[pscustomobject]@{Name='FixturePayment'};$primaryServiceState='Running';$secAppNum=5;$secAppTitle='AppSettings Check'
    $originalSetter=(Get-Command Set-ThoroughServiceEndpoints).ScriptBlock
    function Set-ThoroughServiceEndpoints {param($Path) & $originalSetter -Path $Path -BackupFolder $backups}
    function Get-ThoroughAppSettingsPrinterInventory {return}
    function Write-ThoroughConsoleEntry {param($Row,$Number)}
    $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$false
    . $inspect
    $beforeRows=$auditRows.ToArray()
    Assert-Endpoint ([IO.File]::ReadAllText($appPath) -ceq $text -and $beforeRows[0].Status -eq 'Fail') 'Engine Audit changed the file or missed incorrect endpoints.'
    $auditRows=New-Object 'Collections.Generic.List[psobject]';$script:ApplyChanges=$true
    . $inspect
    Assert-Endpoint ([IO.File]::ReadAllText($appPath) -ceq $expected -and $auditRows[0].EndpointRepair.Changed) 'Engine Apply did not run the endpoint repair.'
    $fixed=New-ThoroughReportSnapshot -Rows $auditRows.ToArray() -BeforeRows $beforeRows -DisplayMode Fix -AfterApply $true -Hostname 'FIXTURE-PC'
    $fixedHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fixed.HtmlBase64))
    foreach($name in @('Monitoring Service','CMS Gateway','Order Service')){
        $view=Get-SettingRenderedComponent $fixedHtml $name
        Assert-Endpoint ($view.Count -eq 1 -and $view.Fields.Count -eq 1 -and $view.Fields[0].Findings -match 'old.example.test' -and $view.Fields[0].Value -match '^https://msblocks.selise.biz/api/' -and $view.Fields[0].Value -ne 'Not applied') 'Fix lost the original URL or verified Applied URL.'
    }
    [IO.File]::WriteAllText((Join-Path $fixture ($client+'-Applied.html')),$fixedHtml,[Text.UTF8Encoding]::new($false))
    function Set-ThoroughServiceEndpoints {param($Path) [IO.File]::WriteAllText($Path,$text.Replace('old.example.test','external.example.test'),[Text.UTF8Encoding]::new($false));throw 'Fixture concurrent configuration edit'}
    $auditRows=New-Object 'Collections.Generic.List[psobject]'
    . $inspect
    Assert-Endpoint ($auditRows[0].Status -eq 'Fail' -and $auditRows[0].ConfigurationSnapshot.MonitoringServiceBaseUrl -eq 'https://external.example.test/monitor' -and $auditRows[0].EndpointRepairError -match 'Fixture concurrent') 'Repair failure reported stale configuration instead of the remaining file.'
    Set-Item Function:Set-ThoroughServiceEndpoints -Value $originalSetter
    $script:ApplyChanges=$false
    foreach($state in @('correct','different','wrong-path','empty','missing','repaired')){
        $config=ConvertFrom-ThoroughPaymentJson $(if($state -in @('correct','repaired')){$expected}else{$text})
        if($state -eq 'wrong-path'){foreach($key in $required.Keys){$config.$key=$required[$key]+'/wrong'}}
        if($state -eq 'empty'){foreach($key in $required.Keys){$config.$key=''}}
        if($state -eq 'missing'){foreach($key in $required.Keys){$config.PSObject.Properties.Remove($key)}}
        $source=[pscustomobject]@{SectionNumber=5;SectionTitle='AppSettings Check';ItemTitle='Payment Service appsettings.json';Shortcut='<code>notepad.exe appsettings.json</code>';ConfigurationSnapshot=$config;FoundStateHtml='Recorded';Status='Fail';ActionTaken='Fixture'}
        if($state -eq 'repaired'){$source | Add-Member -NotePropertyName EndpointRepair -NotePropertyValue ([pscustomobject]@{Changed=$true;ChangedKeys=@($required.Keys);BackupPath='fixture-backup.json'})}
        $rows=@(Get-ThoroughAppSettingsReportRows $source | Where-Object {$required.Contains($_.ItemTitle)})
        Assert-Endpoint ($rows.Count -eq 3) 'An endpoint was lost from the report.'
        foreach($row in $rows){
            $healthy=$state -in @('correct','repaired')
            Assert-Endpoint (($row.Status -in @('Pass','Remediated')) -eq $healthy) 'Endpoint row status does not reflect the exact required URL.'
            $html=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml (Format-ThoroughReportFieldLabels $row.FoundStateHtml) -RequirementHtml (Format-ThoroughReportFieldLabels (Get-ReportRequirement $row))
            $fields=@(Read-ThoroughAuditFields $html | Where-Object Kind -EQ 'Field')
            Assert-Endpoint ($fields.Count -eq 1 -and $fields[0].State -eq $(if($healthy){'match'}else{'mismatch'})) 'Endpoint has the wrong match/mismatch color.'
            $applied=Get-ThoroughReportAppliedHtml $row
            if($state -eq 'repaired'){Assert-Endpoint ($applied -match '<strong>Completed</strong>' -and $applied -notmatch 'Read Only') 'Successful endpoint repair was reported read-only.'}
            elseif(-not $healthy){Assert-Endpoint ($applied -match 'Manual Review Required') 'Incorrect endpoint was reported verified.'}
        }
        $snapshot=New-ThoroughReportSnapshot -Rows @($source) -DisplayMode Audit -Hostname 'FIXTURE-PC'
        $report=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        foreach($name in @('Monitoring Service','CMS Gateway','Order Service')){
            $component=Get-AuditRenderedComponent $report $name
            Assert-Endpoint ($component.Count -eq 1 -and $component.Fields.Count -eq 1) 'Endpoint row missing from Audit.'
            Assert-Endpoint ($component.Fields[0].Required -ceq 'https://msblocks.selise.biz') 'Required must display only the service URL origin, without an API path.'
            Assert-Endpoint (($component.Fields[0].Html -match 'finding-match') -eq ($state -in @('correct','repaired'))) 'Audit endpoint did not show green only for a correct URL.'
        }
        Assert-Endpoint ($report -notmatch 'FAKE-SECRET|FAKE-TENANT') 'Unrelated private AppSettings values leaked into the report.'
        [IO.File]::WriteAllText((Join-Path $fixture ($client+'-'+$state+'.html')),$report,[Text.UTF8Encoding]::new($false))
    }
    Write-Output ('PASS: '+$client+' exact endpoint requirements/colors; Audit safety; three-value Apply; missing/null values; comment/key/encoding preservation; backups, rollback, and repeat Apply.')
}
