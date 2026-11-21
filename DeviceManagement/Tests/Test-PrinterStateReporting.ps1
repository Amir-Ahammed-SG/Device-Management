. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Execute the real discovery block against in-memory printer API fixtures only.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
function Assert-PrinterState {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
foreach($client in @('SaaS','Subway')){
    $sourceName=$client
    Set-KioskTestClient -ClientType $client
    $source=[KioskTestSource]::ReadAllText((Join-Path $projectRoot 'KioskThoroughCheck.ps1'))
    $tokens=$null;$parseErrors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $projectRoot 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-PrinterState (-not $parseErrors.Count) 'Shared engine parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"))
    $start=$source.IndexOf('# 1.1 Multi-Printer Discovery')
    $end=$source.IndexOf('# 1.2 PrintService Event Log',$start)
    $discover=[scriptblock]::Create($source.Substring($start,$end-$start))
    function Start-AuditStep {param($Number,$Name)}
    function Write-AuditOperation {param($Message)}
    function Get-Printer {[CmdletBinding()]param($Name) if($Name){$script:printers | Where-Object Name -EQ $Name}else{$script:printers}}
    function Get-CimInstance {[CmdletBinding()]param($ClassName) Assert-PrinterState ($ClassName -eq 'Win32_Printer') 'Unexpected device query'; $script:cimPrinters}
    function Set-Printer {[CmdletBinding()]param($Name,$KeepPrintedJobs) $script:writes++; Assert-PrinterState ($KeepPrintedJobs -eq $true) 'Unapproved printer setting change'; ($script:printers | Where-Object Name -EQ $Name).KeepPrintedJobs=$true}
    function Invoke-CimMethod {throw 'Queue or printer state must not be changed'}
    function Resume-PrintJob {throw 'Print jobs must not be changed'}
    function Add-AuditEntry {param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken) $script:rows.Add([pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle=$ItemTitle;ItemSub=$ItemSub;Shortcut=$Shortcut;FoundStateHtml=$FoundStateHtml;Status=$Status;ActionTaken=$ActionTaken})}
    $cases=@(
        @{Name='Idle';Status='Normal';Expected='Idle'},
        @{Name='Active';Status='Printing';Expected='Active'},
        @{Name='Numeric idle';Status=0;Expected='Idle'},
        @{Name='Numeric active';Status=1024;Expected='Active'},
        @{Name='Unavailable text';Status='NotAvailable';Expected='Not available'},
        @{Name='Unavailable spaced';Status='Error, Not Available';Expected='Not available'},
        @{Name='Unavailable bit';Status=4096;Expected='Not available'},
        @{Name='Unavailable combined';Status=4226;Expected='Not available'},
        @{Name='Unavailable CIM';Status='Normal';Extended=11;Expected='Not available'},
        @{Name='Offline text';Status='Offline';Expected='Offline'},
        @{Name='Offline bit';Status=128;Expected='Offline'},
        @{Name='Offline CIM';Status='Normal';CimStatus=7;Expected='Offline'},
        @{Name='Offline extended';Status='Normal';Extended=8;Expected='Offline'},
        @{Name='Offline flag';Status='Normal';WorkOffline=$true;Expected='Offline'},
        @{Name='Paused text';Status='Paused';Expected='Paused'},
        @{Name='Paused bit';Status=1;Expected='Paused'},
        @{Name='Paused extended';Status='Normal';Extended=7;Expected='Paused'},
        @{Name='Error text';Status='Error';Expected='Error'},
        @{Name='Error bit';Status=2;Expected='Error'},
        @{Name='Error detected';Status='Normal';Detected=4;Expected='Error'},
        @{Name='Error extended';Status='Normal';Extended=9;Expected='Error'}
    )
    foreach($applyMode in @($false,$true)){
        $script:ApplyChanges=$applyMode
        foreach($retention in @($false,$true)){
            $script:writes=0
            $script:printers=@(foreach($case in $cases){[pscustomobject]@{Name=('EPSON '+$case.Name);PrinterStatus=$case.Status;KeepPrintedJobs=$retention;WorkOffline=[bool]$case.WorkOffline}})
            $script:cimPrinters=@(foreach($case in $cases){[pscustomobject]@{Name=('EPSON '+$case.Name);PrinterStatus=$(if($case.CimStatus){$case.CimStatus}else{3});ExtendedPrinterStatus=$case.Extended;DetectedErrorState=$(if($case.Detected){$case.Detected}else{0});WorkOffline=[bool]$case.WorkOffline;KeepPrintedJobs=$retention}})
            $script:rows=[Collections.Generic.List[object]]::new()
            . $discover
            Assert-PrinterState ($script:rows.Count -eq $cases.Count) 'A configured queue disappeared from discovery'
            $healthyCount=0
            foreach($case in $cases){
                $row=@($script:rows | Where-Object ItemTitle -EQ ('EPSON '+$case.Name))[0]
                $state=Get-ThoroughReportHighlightFields $row.FoundStateHtml
                $healthy=$case.Expected -in @('Idle','Active') -and ($retention -or $applyMode)
                if($healthy){$healthyCount++}
                Assert-PrinterState ($state['Printer status'] -ceq $case.Expected -and ($row.Status -eq 'Pass') -eq $healthy) ('State was flattened or falsely healthy: '+$client+'/'+$case.Name)
                if($case.Expected -in @('Not available','Offline')){Assert-PrinterState ($row.ActionTaken -match 'connection and availability') 'Unavailable printer has no availability action'}
            }
            Assert-PrinterState ($script:writes -eq $(if($applyMode -and -not $retention){$cases.Count}else{0})) 'Audit wrote settings or Apply changed settings beyond retention'
            $beforeRows=@($script:rows | ForEach-Object {$_.PSObject.Copy()})
            if($applyMode -and -not $retention){
                foreach($beforeRow in $beforeRows){$beforeRow.FoundStateHtml=$beforeRow.FoundStateHtml.Replace('Enabled','Disabled');$beforeRow.Status='Fail';$beforeRow.ActionTaken='Enable Keep printed documents in Apply Mode'}
            }
            $original=ConvertTo-Json -InputObject $script:rows.ToArray() -Depth 16 -Compress
            foreach($mode in @('Audit','Fix','Final')){
                $snapshot=New-ThoroughReportSnapshot -Rows $script:rows.ToArray() -BeforeRows $beforeRows -DisplayMode $mode -AfterApply $applyMode
                $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
                $component=if($mode -eq 'Audit'){Get-AuditRenderedComponent $html 'Printer'}else{Get-SettingRenderedComponent $html 'Printer'}
                foreach($stateName in @('Not available','Offline','Paused','Error')){
                    Assert-PrinterState ($component.Text.Contains($stateName) -eq ($mode -ne 'Final')) ('Printer state visibility changed unexpectedly in '+$mode+': '+$stateName)
                }
                if($mode -eq 'Fix'){
                    $nameFields=@($component.Fields | Where-Object Setting -EQ 'Printer Name')
                    Assert-PrinterState ($nameFields.Count -eq $component.Headings.Count -and @($nameFields | Where-Object {$_.Html -ne '' -or $_.Value -ne ''}).Count -eq 0) 'Printer identity is missing or has an Applied label'
                    foreach($case in @($cases | Where-Object {$_.Expected -notin @('Idle','Active')})){
                        Assert-PrinterState (@($component.Headings | Where-Object {$_.EndsWith('EPSON '+$case.Name)}).Count -eq 1) 'A failed printer lost its unique heading identity'
                    }
                    $statusFields=@($component.Fields | Where-Object Setting -EQ 'Printer status')
                    $manualCount=@($cases | Where-Object {$_.Expected -in @('Not available','Offline','Paused','Error')}).Count
                    Assert-PrinterState (@($statusFields | Where-Object Value -EQ 'Manual Action Required').Count -eq $manualCount) 'A manually repairable printer status was labeled Not applied or a sibling inherited its label'
                    Assert-PrinterState (@($statusFields | Where-Object {$_.Value -eq 'Manual Action Required' -and $_.Html -notmatch 'finding-manual'}).Count -eq 0) 'Manual action does not use the status badge style'
                    $retentionFields=@($component.Fields | Where-Object Setting -EQ 'Keep printed documents')
                    if(-not $applyMode){Assert-PrinterState (@($retentionFields | Where-Object Value -NE 'Not applied').Count -eq 0) 'An automatic retention fix was incorrectly labeled manual'}
                    elseif(-not $retention){Assert-PrinterState (@($retentionFields | Where-Object Value -NE 'Enabled').Count -eq 0) 'A verified retention repair lost its Applied value'}
                }
                if($mode -eq 'Fix' -and $retention){Assert-PrinterState (@($component.Headings | Where-Object {$_.EndsWith('EPSON Idle')}).Count -eq 0) 'Healthy unchanged printer appeared in Fix'}
                if($mode -ne 'Fix'){
                    $expectedCount=if($mode -eq 'Final'){@($cases | Where-Object {$_.Expected -in @('Idle','Active')}).Count}else{$cases.Count}
                    Assert-PrinterState (@($component.Fields | Where-Object Setting -EQ 'Printer Name').Count -eq $expectedCount) 'Audit/Final printer identity selection changed'
                }
            }
            Assert-PrinterState ((ConvertTo-Json -InputObject $script:rows.ToArray() -Depth 16 -Compress) -ceq $original) 'Rendering changed printer observations'
        }
    }
    # Missing readback remains uncertain; recovered queues are not left manual.
    $before=$script:rows[6].PSObject.Copy()
    foreach($case in @('unverified','recovered')){
        $after=$before.PSObject.Copy()
        if($case -eq 'unverified'){$after.ActionTaken='Printer readback failed; not verified.'}
        else{$after.Status='Pass';$after.ActionTaken='No changes needed';$after.FoundStateHtml=$after.FoundStateHtml.Replace('Not available','Idle')}
        $snapshot=New-ThoroughReportSnapshot -Rows @($after) -BeforeRows @($before) -DisplayMode Fix -AfterApply $true
        $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
        $component=Get-SettingRenderedComponent $html 'Printer'
        Assert-PrinterState ($component.Headings.Count -eq 1 -and $component.Headings[0].Contains($before.ItemTitle) -and @($component.Fields | Where-Object {$_.Setting -eq 'Printer Name' -and $_.Html -eq '' -and $_.Findings -eq $before.ItemTitle}).Count -eq 1) 'A single printer lost its identity or labeled its Applied cell'
        $field=@($component.Fields | Where-Object Setting -EQ 'Printer status')[0]
        $expected=if($case -eq 'unverified'){'Not verified'}else{'Idle'}
        Assert-PrinterState ($field.Value -ceq $expected) 'An unknown readback or recovered queue was incorrectly labeled manual'
    }
    $snapshot=New-ThoroughReportSnapshot -Rows @($before) -DisplayMode Fix -AfterApply $true
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    $component=Get-SettingRenderedComponent $html 'Printer'
    $nameField=@($component.Fields | Where-Object Setting -EQ 'Printer Name')[0]
    Assert-PrinterState ($nameField.Findings -ceq $before.ItemTitle -and $nameField.Html -ceq '') 'A missing baseline hid printer identity or added an Applied label'
    $identityOnly=$script:rows[0].PSObject.Copy()
    $identityOnly.ItemTitle='Receipt Queue'
    $identityOnly.FoundStateHtml=$identityOnly.FoundStateHtml.Replace('EPSON Idle','Receipt Queue')
    $snapshot=New-ThoroughReportSnapshot -Rows @($identityOnly) -DisplayMode Fix -AfterApply $false
    $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
    Assert-PrinterState ((Get-SettingRenderedComponent $html 'Printer').Count -eq 0 -and $html.Contains('No fixes required.')) 'A name-only difference invented a printer repair or left an empty heading'
    Write-Output ('PASS: '+$client+' 84 discovery cases, full Audit/Fix evidence and Active/Idle-only Final; combined flags and retention-only Apply remain truthful.')
}
