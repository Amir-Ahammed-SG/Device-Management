# Inspect rendered HTML independently of the production field-projection parser.
function Get-AuditRenderedComponent {
    param([string]$Html,[string]$Name)
    $rows=[Collections.Generic.List[object]]::new();$count=0
    foreach($table in [regex]::Matches($Html,'(?is)<table class="checks"[^>]*>.*?</table>')){
        $body=[regex]::Match($table.Value,'(?is)<tbody>(.*?)</tbody>').Groups[1].Value
        $body=[regex]::Replace($body,'(?i)<(br|hr)(\b[^>]*?)(?<!/)>','<$1$2/>')
        $xml=[xml]('<root>'+$body+'</root>');$remaining=0
        foreach($row in $xml.root.tr){
            $component=$row.SelectSingleNode('./td[@class="audit-component"]')
            if($component){$remaining=if($component.InnerText -eq $Name){$count++;[int]$component.GetAttribute('rowspan')}else{0}}
            if($remaining -gt 0){$rows.Add($row);$remaining--}
        }
    }
    $fields=[Collections.Generic.List[object]]::new();$headings=[Collections.Generic.List[string]]::new();$record=''
    foreach($row in $rows){
        $heading=$row.SelectSingleNode('./td[@class="audit-record-heading"]')
        if($heading){$record=$heading.InnerText;$headings.Add($record);continue}
        $setting=$row.SelectSingleNode('./td[@class="audit-setting"]')
        $required=$row.SelectSingleNode('./td[@class="audit-required"]')
        $found=$row.SelectSingleNode('./td[@class="audit-findings"]')
        $fields.Add([pscustomobject]@{Record=$record;Setting=$setting.InnerText;Required=$required.InnerText;Found=$found.InnerText;Html=$found.InnerXml})
    }
    $commands=@(foreach($row in $rows){foreach($button in $row.SelectNodes('.//button[@class="command-copy"]')){$button.GetAttribute('data-command')}})
    [pscustomobject]@{Count=$count;Fields=$fields.ToArray();Headings=$headings.ToArray();Commands=$commands;Text=(($rows|ForEach-Object {$_.InnerText}) -join ' ');Html=(($rows|ForEach-Object {$_.OuterXml}) -join '')}
}
