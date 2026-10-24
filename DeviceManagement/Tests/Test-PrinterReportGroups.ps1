# Render the real finalizer with fixture printers. Never contact printer APIs.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output\printer-reports'
[void][IO.Directory]::CreateDirectory($previewRoot)
function Assert-PrinterReport {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}

foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-PrinterReport ($errors.Count -eq 0) 'Client source parse failed.'
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    . (Join-Path $PSScriptRoot 'ReportRenderTestSupport.ps1')
    $finalizer=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    function New-PrinterFixture {
        param([string]$Name,[string]$Status='Pass',[string]$State='Idle',[string]$Retention='Enabled',[switch]$Missing)
        $fields=[ordered]@{'Printer Name'=$Name;'Printer status'=$State;'Keep printed documents'=$Retention}
        [pscustomobject]@{
            SectionNumber=1;SectionTitle='Hardware & Peripherals'
            ItemTitle=$(if($Missing){'Physical Printers'}else{$Name})
            ItemSub=$(if($Missing){'Type: Receipt / Hardware'}else{'Type: Receipt / POS Printer'})
            Shortcut=$(if($Missing){New-ReportCommand @('control printers')}else{New-ReportCommand @('control printers',('rundll32 printui.dll,PrintUIEntry /o /n "{0}"' -f $Name))})
            FoundStateHtml=$(if($Missing){'Not verified. Please check manually.'}else{ConvertTo-ReportDefinitionHtml $fields})
            Status=$(if($Missing){'Fail'}else{$Status});ActionTaken='Fixture observation only'
        }
    }
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        $mode=if($isApply){'Apply'}else{'Audit'}
        foreach($case in @('single','multiple','error','disabled','unknown','missing','partial')){
            $printers=@(switch($case){
                'single' {New-PrinterFixture 'BIXOLON BK3-3'}
                'multiple' {New-PrinterFixture 'BIXOLON BK3-3';New-PrinterFixture 'Kitchen & Bar <One>' -State Active}
                'error' {New-PrinterFixture 'BIXOLON BK3-3';New-PrinterFixture 'Receipt 2' -Status Fail -State Error}
                'disabled' {New-PrinterFixture 'BIXOLON BK3-3';New-PrinterFixture 'Receipt 2' -Status Fail -Retention Disabled}
                'unknown' {New-PrinterFixture 'BIXOLON BK3-3';New-PrinterFixture 'Receipt 2' -Status Bypass -State 'Not verified. Please check manually.'}
                'missing' {New-PrinterFixture '' -Missing}
                'partial' {New-PrinterFixture 'BIXOLON BK3-3';New-PrinterFixture '' -Missing}
            })
            $log=[pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='Type: Event Viewer Channel';Shortcut='<code>eventvwr.msc</code>';FoundStateHtml='Enabled';Status='Pass';ActionTaken='Fixture observation only'}
            $rawRows=@($printers)+@($log)
            $before=$rawRows | ConvertTo-Json -Depth 5 -Compress
            $display=@(Get-ThoroughReportDisplayRows -Rows $rawRows)
            Assert-PrinterReport ($display.Count -eq 2 -and $display[0].ItemTitle -ceq 'Printer' -and $display[1].ItemTitle -ceq 'PrintService Operational Log') 'Printers were not grouped in their original section order.'
            Assert-PrinterReport (($rawRows | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Grouping changed original observations.'
            $repeated=@(Get-ThoroughReportDisplayRows -Rows $display)
            Assert-PrinterReport (($repeated | ConvertTo-Json -Depth 5 -Compress) -ceq ($display | ConvertTo-Json -Depth 5 -Compress)) 'Grouping an already grouped report changed its result.'
            $group=$display[0]
            $expectedStatus=if($case -in @('single','multiple')){'Pass'}else{'Fail'}
            Assert-PrinterReport ($group.Status -ceq $expectedStatus) ('A partial/failed/unverified printer was reported healthy: '+$case)
            Assert-PrinterReport ($group.ExpectedHtml -notmatch 'Printer detection' -and $group.ExpectedHtml -match 'Printer Name:</span> BIXOLON or EPSON' -and $group.ExpectedHtml -match 'Printer status:</span> Active / Idle / Error' -and $group.ExpectedHtml -match 'Keep printed documents:</span> Enabled') 'Printer requirements were incorrect.'
            Assert-PrinterReport ($group.ExpectedHtml -notmatch 'config-item-title|<hr>' -and [regex]::Matches($group.ExpectedHtml,'class="kv-label"').Count -eq 3) 'Printer requirements were repeated or numbered.'
            Assert-PrinterReport ($group.FoundStateHtml -notmatch 'Printer detection|Detected -') 'Legacy printer-detection wording remains.'
            $printerNumber=0
            foreach($printer in @($printers | Where-Object ItemSub -eq 'Type: Receipt / POS Printer')){
                $printerNumber++
                $encoded=[Net.WebUtility]::HtmlEncode($printer.ItemTitle)
                Assert-PrinterReport ($group.FoundStateHtml.Contains(('Printer Name:</span> '+$encoded))) 'A printer name was lost or not encoded.'
                if($printers.Count -gt 1){
                    $heading='<div class="config-item-title">[Printer '+$printerNumber+']</div>'
                    Assert-PrinterReport (-not $group.ExpectedHtml.Contains($heading) -and $group.FoundStateHtml.Contains($heading)) 'Printer numbering must appear only in Findings.'
                    Assert-PrinterReport (-not $group.ExpectedHtml.Contains(('['+$encoded+']')) -and -not $group.FoundStateHtml.Contains(('['+$encoded+']'))) 'A printer name remains in a group heading.'
                }
            }
            $copyCommands=@([regex]::Matches($group.Shortcut,'(?is)<code\b[^>]*>(.*?)</code>') | ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
            Assert-PrinterReport (@($copyCommands | Where-Object {$_ -ceq 'control printers'}).Count -eq 1) 'The shared printer command was lost or duplicated.'
            Assert-PrinterReport ($copyCommands.Count -eq (1+@($printers | Where-Object ItemSub -eq 'Type: Receipt / POS Printer').Count)) 'A per-printer command was lost or changed.'
            if($case -eq 'missing'){Assert-PrinterReport ($group.FoundStateHtml.Contains('Not verified. Please check manually.')) 'Missing printers did not request manual verification.'}

            $auditRows=[Collections.Generic.List[psobject]]::new()
            foreach($row in $rawRows){$auditRows.Add($row)}
            $outputFolder=$previewRoot;$reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-'+$case+'.html')
            $runId='PRINTER-PREVIEW';$clientLocation='Printer grouping preview';$deviceType='KIOSK'
            $reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
            $expectedApplied=Get-ThoroughReportAppliedHtml -Row $group
            . $render
            $html=[IO.File]::ReadAllText($reportPath)
            $printerRows=@([regex]::Matches($html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value -match '<div class="device-title">Printer</div>'})
            if($isApply -and $case -eq 'single'){
                Assert-PrinterReport ($printerRows.Count -eq 0 -and $html.Contains('No fixes required.')) 'Healthy unchanged printer was retained in Fix.'
                continue
            }
            Assert-PrinterReport ($printerRows.Count -eq 1) 'Rendered report has multiple printer components.'
            $cells=@([regex]::Matches($printerRows[0].Value,'(?is)<td\b[^>]*>(.*?)</td>'))
            Assert-PrinterReport ($cells.Count -eq 4) 'Audit/Apply column layout changed.'
            Assert-PrinterReport ($cells[2].Groups[1].Value -notmatch 'Printer detection' -and $cells[3].Groups[1].Value -notmatch 'Printer detection|Detected -') 'Rendered report contains removed wording.'
            $buttons=@([regex]::Matches($cells[1].Groups[1].Value,'data-command="([^"]*)"') | ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
            Assert-PrinterReport (($buttons -join "`n") -ceq ($copyCommands -join "`n")) 'Copy controls changed the grouped commands.'
            if($isApply){Assert-PrinterReport ($cells[3].Groups[1].Value -ceq $expectedApplied) 'Rendered grouped printer operation notes are incorrect.'}
        }
        Write-Output ('PASS: '+$client+'/'+$mode+' single/multiple/missing printers, encoded headings, commands, mixed statuses, unchanged observations and real report rendering')
    }
}
