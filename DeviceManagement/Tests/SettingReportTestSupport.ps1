
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Inspect rendered field rows independently of the production field parser.
function Get-SettingRenderedComponent {
    param([string]$Html,[string]$Name)
    $all=[Collections.Generic.List[object]]::new();$count=0
    foreach($table in [regex]::Matches($Html,'(?is)<table class="checks"[^>]*>.*?</table>')){
        $body=[regex]::Match($table.Value,'(?is)<tbody>(.*?)</tbody>').Groups[1].Value
        $body=[regex]::Replace($body,'(?i)<(br|hr)(\b[^>]*?)(?<!/)>','<$1$2/>')
        $xml=[xml]('<root>'+$body+'</root>');$remaining=0
        foreach($row in $xml.root.tr){
            $identity=$row.SelectSingleNode('./td[@class="setting-component"]')
            if($identity){$remaining=if($identity.InnerText -eq $Name){$count++;[int]$identity.GetAttribute('rowspan')}else{0}}
            if($remaining -gt 0){$all.Add($row);$remaining--}
        }
    }
    $fields=[Collections.Generic.List[object]]::new();$headings=[Collections.Generic.List[string]]::new();$record=''
    foreach($row in $all){
        $heading=$row.SelectSingleNode('./td[@class="setting-record-heading"]')
        if($heading){$record=$heading.InnerText;$headings.Add($record);continue}
        $label=$row.SelectSingleNode('./td[@class="setting-label"]')
        $before=$row.SelectSingleNode('./td[@class="setting-before"]')
        $value=$row.SelectSingleNode('./td[@class="setting-current"]')
        $fields.Add([pscustomobject]@{Record=$record;Setting=$label.InnerText;Findings=$(if($before){$before.InnerText}else{''});Value=$value.InnerText;BeforeHtml=$(if($before){$before.InnerXml}else{''});Html=$value.InnerXml;Note=$(if($value.span){$value.span.GetAttribute('title')}else{''})})
    }
    $commands=@(foreach($row in $all){foreach($button in $row.SelectNodes('.//button[@class="command-copy"]')){$button.GetAttribute('data-command')}})
    [pscustomobject]@{Count=$count;Fields=$fields.ToArray();Headings=$headings.ToArray();Commands=$commands;Text=(($all|ForEach-Object {$_.InnerText}) -join ' ');Html=(($all|ForEach-Object {$_.OuterXml}) -join '')}
}

function Get-LegacySettingCells {
    param([string]$Html,[string]$Name)
    foreach($row in [regex]::Matches($Html,'(?is)<tr\b[^>]*>.*?</tr>')){
        if($row.Value.Contains('<div class="device-title">'+[Net.WebUtility]::HtmlEncode($Name)+'</div>')){
            return @([regex]::Matches($row.Value,'(?is)<td\b[^>]*>(.*?)</td>')|ForEach-Object {$_.Groups[1].Value})
        }
    }
}

function Remove-AuditAdditionalReferenceSection {
    param([string]$Html)
    # The requested manual references are tested in Test-AuditColumnLayout.
    # Historical comparison covers report bytes outside the approved reference/footer changes.
    # Normalize only the exact historical footer layout to the requested layout.
    # Test-ClientDetailsHeader independently checks the new footer and attribution.
    $Html=[regex]::Replace($Html,'(?s)<footer class="report-footer"><span>Retain with the device configuration records\.<br><span class="report-generated-at"><strong>Generated Time:</strong> (?<Time>[^<]*)</span></span><span class="report-prepared-by"><strong>Prepared by:</strong> .*?</span></footer>',[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        '<footer class="report-footer"><span>Retain with the device configuration records.</span><span class="report-generated-at"><strong>Generated Time:</strong> '+$match.Groups['Time'].Value+'</span></footer>'
    })
    [regex]::Replace($Html,'(?s)<section class="report-additional" aria-labelledby="additional-heading">.*?</section>\r?\n','')
}

function Assert-SettingRuleParity {
    param($Current,$Legacy,[Collections.IDictionary]$Parameters)
    $newHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Current.HtmlBase64))
    $oldHtml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Legacy.HtmlBase64))
    if($Parameters.DisplayMode -eq 'Audit'){
        $newHtml=Remove-AuditAdditionalReferenceSection $newHtml
        $oldHtml=Remove-AuditAdditionalReferenceSection $oldHtml
        if(-not $Parameters.AuditSource){
            # Independent renders can straddle a minute boundary. Compare the
            # report content, not two separately generated wall-clock values.
            $time='(?<=<strong>Generated Time:</strong> )[^<]*(?=</span>)'
            $newHtml=[regex]::Replace($newHtml,$time,'GENERATED_TIME')
            $oldHtml=[regex]::Replace($oldHtml,$time,'GENERATED_TIME')
        }
        if($newHtml.Replace("`r`n","`n") -cne $oldHtml.Replace("`r`n","`n")){throw 'Setting layout changed Audit output'}
        return
    }
    $oldNames=@([regex]::Matches($oldHtml,'<div class="device-title">([^<]+)</div>')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
    $newNames=@([regex]::Matches($newHtml,'<div class="device-title">([^<]+)</div>')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
    if(($oldNames -join '|') -cne ($newNames -join '|')){throw 'Setting layout changed legacy component filtering'}
    foreach($name in $oldNames){
        $currentView=Get-SettingRenderedComponent $newHtml $name
        $oldCells=@(Get-LegacySettingCells $oldHtml $name)
        if($currentView.Count -ne 1){throw ('Setting layout duplicated '+$name)}
        if($Parameters.DisplayMode -eq 'Fix'){
            $commands=@([regex]::Matches($oldCells[1],'data-command="([^"]*)"')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
            if(($commands -join '|') -cne ($currentView.Commands -join '|')){throw ('Setting layout changed retained commands: '+$name)}
            if($Parameters.AfterApply -and -not @($Parameters.BeforeRows|Where-Object {$null -ne $_}).Count){continue}
            $oldValues=$oldCells[2];$newPairs=@($currentView.Fields|Where-Object Setting -NE 'Details'|ForEach-Object {$_.Setting+'='+$_.Findings})
        }else{
            $oldValues=$oldCells[1];$newPairs=@($currentView.Fields|Where-Object Setting -NE 'Details'|ForEach-Object {$_.Setting+'='+$_.Value})
            if($currentView.Commands.Count -or $currentView.Html -match 'class="badge'){throw 'Final contains commands or Pass/Fail badges'}
        }
        $oldPairs=@([regex]::Matches($oldValues,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>.*?)</div>')|ForEach-Object {
            $label=[Net.WebUtility]::HtmlDecode($_.Groups['Label'].Value).Trim()
            if($name -eq 'Performance Counter' -and $label -eq 'Audit'){$label='Rebuild State'}
            $label+'='+[Net.WebUtility]::HtmlDecode(([regex]::Replace($_.Groups['Value'].Value,'<[^>]*>',''))).Trim()
        })
        # Printer identity now belongs in the heading, never a Fix setting row.
        if($Parameters.DisplayMode -eq 'Fix' -and $name -eq 'Printer'){
            $oldPairs=@($oldPairs | Where-Object {-not $_.StartsWith('Printer Name=')})
        }
        if(($oldPairs -join '|') -cne ($newPairs -join '|')){
            # Unverified opaque inventory now has one row per required setting.
            # Accept only that exact projection: identical reason first, unknown
            # values afterward, and no invented or removed requirement labels.
            $oldReason=Convert-ReportHtmlToTerminalText $oldValues
            if(-not $oldPairs.Count -and $oldReason -match '(?i)\bnot\s+verified\b'){
                $sourceRows=@($Parameters.Rows|Where-Object { (Get-ThoroughReportComponentName $_.ItemTitle) -eq $name })
                if($sourceRows.Count -eq 1){
                    $required=@([regex]::Matches((Get-ReportRequirement $sourceRows[0]),'<span class="kv-label">([^<]+):</span>')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
                    if($Parameters.DisplayMode -eq 'Fix' -and $name -eq 'Printer'){$required=@($required | Where-Object {$_ -ne 'Printer Name'})}
                    $expectedPairs=@(for($i=0;$i -lt $required.Count;$i++){$required[$i]+'='+$(if($i -eq 0){$oldReason}else{'Not verified'})})
                    if($Parameters.DisplayMode -eq 'Fix' -and $name -eq 'Printer' -and $currentView.Headings -contains ('Printer - '+$oldReason)){$expectedPairs=@($required | ForEach-Object {$_+'=Not verified'})}
                    if($expectedPairs.Count -and ($expectedPairs -join '|') -ceq ($newPairs -join '|')){continue}
                }
            }
            # Final no longer has an aggregate Fail badge. Uncertain post-fix
            # properties must explicitly show Not verified instead of a cached
            # positive value. Other observed properties still match exactly.
            $safeMask=$Parameters.DisplayMode -eq 'Final' -and $Parameters.AfterApply -and $oldPairs.Count -eq $newPairs.Count
            for($i=0;$safeMask -and $i -lt $oldPairs.Count;$i++){
                if($oldPairs[$i] -ceq $newPairs[$i]){continue}
                $field=@($currentView.Fields|Where-Object Setting -NE 'Details')[$i]
                $oldLabel=$oldPairs[$i].Substring(0,$oldPairs[$i].IndexOf('='))
                if($field.Setting -cne $oldLabel -or $field.Value -cne 'Not verified' -or $field.Html -notmatch 'finding-unverified'){$safeMask=$false}
            }
            if(-not $safeMask){throw ('Setting layout changed selected properties or recorded values: '+$name+'; '+$Parameters.DisplayMode+'; old='+($oldPairs -join '|')+'; current='+($newPairs -join '|'))}
        }
    }
    if($Current.Origin -cne $Legacy.Origin -or ($Parameters.AuditSource -and ($Current.ReportId -cne $Legacy.ReportId -or $Current.GeneratedAt -cne $Legacy.GeneratedAt))){throw 'Setting layout changed report provenance'}
}

function Use-SettingLayoutRuleAssertions {
    param([string]$SourceName)
    # Older business-rule fixtures assert the previous HTML encoding. Execute
    # BOTH renderers for every fixture call and compare real production selection,
    # commands and property values first. Return the captured old presentation
    # only for those historical assertions. The new layout, Applied readback,
    # columns, styles and saved HTML are tested directly in Test-FixFinalSettingLayout.
    $fixture=[KioskTestSource]::ReadAllText((Join-Path $PSScriptRoot 'Fixtures/SettingLayoutLegacyRenderer.json'))|ConvertFrom-Json
    $captured=@($fixture|Where-Object FileName -EQ $SourceName)[0]
    $script:SettingRuleActualRenderer=(Get-Command New-ThoroughReportSnapshot).ScriptBlock
    $script:SettingRuleLegacyRenderer=& { . ([scriptblock]::Create($captured.Renderer)); (Get-Command New-ThoroughReportSnapshot).ScriptBlock }
    $rendererAst=$script:SettingRuleActualRenderer.Ast
    $parameters=if($rendererAst -is [Management.Automation.Language.FunctionDefinitionAst]){$rendererAst.Body.ParamBlock.Extent.Text}else{$rendererAst.ParamBlock.Extent.Text}
    $body=@'
    $current=& $script:SettingRuleActualRenderer @PSBoundParameters
    $legacy=& $script:SettingRuleLegacyRenderer @PSBoundParameters
    Assert-SettingRuleParity -Current $current -Legacy $legacy -Parameters $PSBoundParameters
    $legacy
'@
    Set-Item -Path Function:script:New-ThoroughReportSnapshot -Value ([scriptblock]::Create($parameters+"`n"+$body))
}
