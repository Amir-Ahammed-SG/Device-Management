# Shared kiosk reporting functions. Dot-sourced into the engine's scope.

function Get-KioskReportPath {
    param ([string]$Folder, [string]$Client, [string]$Computer, [bool]$IsApply, [string]$RunId, [bool]$IsFinal=$false)
    # A stable client/computer filename lets independently run modes update one
    # report. Branch labels and launcher hostnames may change between runs.
    $computerLabel=($Computer -replace '[<>:"/\\|?*\x00-\x1F]','_').Trim().TrimEnd('.')
    if([string]::IsNullOrWhiteSpace($computerLabel)){$computerLabel='Unknown'}
    if($computerLabel.Length -gt 60){$computerLabel=$computerLabel.Substring(0,60).TrimEnd(' ','.')}
    Join-Path $Folder (('Thorough Check Reports - '+$script:KioskClientSettings.ClientType+' - ')+$computerLabel+'.html')
}

function Get-ThoroughReportComponentName {
    param ([string]$Name)
    switch -Exact ($Name) {
        'Physical Printers' { return 'Printer' }
        'PrintService Operational Log' { return 'PrintService Log' }
        'Kiosk Launch Architecture' { return 'Kiosk Launch Script' }
        'SELISE-KIOSK Startup Folder' { return 'Startup Folder' }
        'Payment Gateway Middleware' { return 'Payment Gateway' }
        'Payment Middleware Service' { return 'Payment Gateway' }
        'Zabbix Agent 2' { return 'Zabbix Agent' }
        'Windows Update (wuauserv)' { return 'Windows Update' }
        'PaymentService' { return 'Payment Service' }
        'PaymentConfiguration' { return 'Payment Configuration' }
        'ScheduleConfiguration' { return 'WebApp Printer' }
        'WebApp/Shop Print' { return 'WebApp Printer' }
        'Payout Scheduler' { return 'Cron Job' }
        'Firewall Inbound Port' { return 'Firewall' }
        'Print' { return 'Printer' }
        'MonitoringServiceBaseUrl' { return 'Monitoring Service' }
        'CmsGatewayBaseUrl' { return 'CMS Gateway' }
        'OrderServiceBaseUrl' { return 'Order Service' }
        'lodctr /R Performance Counter' { return 'Performance Counter' }
    }
    if ($Name -match '^Inbound TCP [0-9-]+ Rules?$') { return 'Firewall' }
    $Name
}

function Format-ThoroughReportFieldLabels {
    param ([string]$Html)
    # Change report labels and headings only; keys, values and commands stay intact.
    foreach ($name in @('PaymentService','PaymentConfiguration','ScheduleConfiguration','Print','MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')) {
        $label=Get-ThoroughReportComponentName $name
        $Html=$Html.Replace(('<span class="kv-label">'+$name+':</span>'),('<span class="kv-label">'+$label+':</span>'))
    }
    foreach($fieldLabel in @(@('PrinterName','Kitchen Printer'),@('KioskPrinterName','Kiosk/POS Printer'),@('KioskPrinterDisableChineseMode','Disable Chinese Mode'))){
        $Html=$Html.Replace(('<span class="kv-label">'+$fieldLabel[0]+':</span>'),('<span class="kv-label">'+$fieldLabel[1]+':</span>'))
    }
    # Older saved Audit records still use Schedule NN. Resolve their heading from
    # the provider recorded in that block, never from its position in the array.
    $Html=[regex]::Replace($Html,'(?is)(?<Heading><div class="config-item-title">\[?Schedule\s+\d+\]?</div>)(?<Body>.*?)(?=<div class="config-(?:item|group)-title">|$)',[Text.RegularExpressions.MatchEvaluator]{
        param($record)
        $providerField=[regex]::Match($record.Groups['Body'].Value,'<span class="kv-label">Provider:</span>\s*(?<Provider>[^<]+)')
        $provider=[Net.WebUtility]::HtmlDecode($providerField.Groups['Provider'].Value).Trim().ToUpperInvariant()
        $title=switch($provider){'SIX'{'SIX Terminal'};{$_ -in @('NETS','NEXIDE')}{'NETS Terminal'};default{''}}
        if(-not $title){return $record.Value}
        '<div class="config-item-title">'+$title+'</div>'+$record.Groups['Body'].Value
    })
    $Html=[regex]::Replace($Html,'<div class="config-item-title">\[(?<Title>[^<]*)\]</div>',[Text.RegularExpressions.MatchEvaluator]{
        param($heading)
        $title=$heading.Groups['Title'].Value
        $numbered=[regex]::Match($title,'^(?<Kind>Printer|Account|Terminal|Task|Schedule) (?<Number>[1-9]\d*)$')
        if($numbered.Success){
            $title=$numbered.Groups['Kind'].Value+' '+$numbered.Groups['Number'].Value.PadLeft(2,[char]'0')
        }
        '<div class="config-item-title">'+$title+'</div>'
    })
    foreach($group in @(@('NetsTerminals','NETS Terminals'),@('SixTerminals','SIX Terminals'))){
        $Html=$Html.Replace(('<div class="config-group-title">['+$group[0]+']</div>'),('<div class="config-group-title">'+$group[1]+'</div>'))
    }
    # Normalize record separators once, including stacks that did not supply them.
    $Html=[regex]::Replace($Html,'(?:<hr\b[^>]*>\s*)+(?=<div class="config-(?:item|group)-title">)','')
    $records=[pscustomobject]@{Seen=$false}
    $Html=[regex]::Replace($Html,'<div class="config-(?<Kind>item|group)-title">[^<]*</div>',[Text.RegularExpressions.MatchEvaluator]{
        param($heading)
        if($heading.Groups['Kind'].Value -eq 'group'){$records.Seen=$false;return $heading.Value}
        $separator=if($records.Seen){'<hr class="block-divider">'}else{''}
        $records.Seen=$true
        $separator+$heading.Value
    })
    $Html=[regex]::Replace($Html,'(?i)(<span class="kv-label">Host Name:</span>\s*)Not verified \((?:service configuration unavailable|configuration unreadable)\)','$1Not verified. The service configuration could not be read. Please check manually.')
    $Html
}

function Get-ThoroughReportBlockAlignmentScript {
    @'
<script>
(function () {
    'use strict';
    // Keep corresponding record headers and dividers aligned across report columns.
    var groups = [], queued = 0;
    function wrapRecord(title) {
        if (title.parentElement.classList.contains('aligned-record')) return title.parentElement;
        var record = document.createElement('div');
        record.className = 'aligned-record';
        title.parentNode.insertBefore(record, title);
        var node = title;
        while (node) {
            if (node !== title && node.nodeType === 1 && node.matches('hr,.config-item-title,.config-group-title')) break;
            var next = node.nextSibling;
            record.appendChild(node);
            node = next;
        }
        return record;
    }
    document.querySelectorAll('table.checks tbody tr').forEach(function (row) {
        var candidates = [];
        Array.from(row.cells).forEach(function (cell) {
            var titles = Array.from(cell.querySelectorAll('.config-item-title'));
            if (!titles.length) return;
            var key = JSON.stringify(titles.map(function (title) { return title.textContent.trim(); }));
            var candidate = candidates.find(function (entry) { return entry.key === key; });
            if (!candidate) { candidate = {key:key, columns:[]}; candidates.push(candidate); }
            candidate.columns.push({cell:cell, titles:titles});
        });
        candidates.forEach(function (candidate) {
            if (candidate.columns.length < 2) return;
            candidate.columns.forEach(function (column) { column.records = column.titles.map(wrapRecord); });
            groups.push(candidate);
        });
    });
    function synchronize() {
        if (queued) { window.cancelAnimationFrame(queued); queued = 0; }
        groups.forEach(function (group) {
            group.columns.forEach(function (column) {
                column.titles.forEach(function (title) { title.style.minHeight = ''; });
                column.records.forEach(function (record) { record.style.minHeight = ''; });
            });
            for (var index = 0; index < group.columns[0].records.length; index++) {
                var titleHeight = Math.ceil(Math.max.apply(null, group.columns.map(function (column) { return column.titles[index].getBoundingClientRect().height; })));
                group.columns.forEach(function (column) { column.titles[index].style.minHeight = titleHeight + 'px'; });
                var recordHeight = Math.ceil(Math.max.apply(null, group.columns.map(function (column) { return column.records[index].getBoundingClientRect().height; })));
                group.columns.forEach(function (column) { column.records[index].style.minHeight = recordHeight + 'px'; });
            }
        });
        document.documentElement.setAttribute('data-block-alignment', 'ready');
    }
    function schedule() {
        if (!queued) queued = window.requestAnimationFrame(synchronize);
    }
    synchronize();
    if (!groups.length) return;
    window.addEventListener('load', schedule);
    window.addEventListener('resize', schedule);
    window.addEventListener('beforeprint', synchronize);
    window.addEventListener('afterprint', schedule);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(schedule);
    if (window.MutationObserver) {
        var contentObserver = new MutationObserver(schedule);
        groups.forEach(function (group) {
            group.columns.forEach(function (column) { contentObserver.observe(column.cell, {childList:true, characterData:true, subtree:true}); });
        });
    }
    if (window.ResizeObserver) {
        var report = document.querySelector('main.report');
        var previousWidth = report.getBoundingClientRect().width;
        var widthObserver = new ResizeObserver(function () {
            var width = report.getBoundingClientRect().width;
            if (Math.abs(width - previousWidth) > 0.5) { previousWidth = width; schedule(); }
        });
        widthObserver.observe(report);
    }
}());
</script>
'@
}

function Format-ThoroughFixFindings {
    param($Row,[string]$FindingsHtml,[string]$RequirementHtml,[bool]$AfterApply=$false,[bool]$RecordScope=$false,[string[]]$ChangedLabels=@())
    # Presentation only: retain unresolved observations, never infer a repair.
    if($Row.SectionTitle -eq 'AppSettings Check'){return $FindingsHtml}
    $headings=@([regex]::Matches($FindingsHtml,'(?is)<div class="config-item-title">.*?</div>'))
    if($headings.Count){
        $prefix=$FindingsHtml.Substring(0,$headings[0].Index)
        $blocks=for($index=0;$index -lt $headings.Count;$index++){
            $start=$headings[$index].Index+$headings[$index].Length
            $end=if($index+1 -lt $headings.Count){$headings[$index+1].Index}else{$FindingsHtml.Length}
            $body=[regex]::Replace($FindingsHtml.Substring($start,$end-$start),'(?is)<hr\b[^>]*>','')
            $record=$Row
            if($Row.PSObject.Properties['LegacyServiceRows'] -and $index -lt @($Row.LegacyServiceRows).Count){$record=$Row.LegacyServiceRows[$index]}
            $headings[$index].Value+(Format-ThoroughFixFindings -Row $record -FindingsHtml $body -RequirementHtml $RequirementHtml -AfterApply $AfterApply -RecordScope $true)
        }
        return $prefix+($blocks -join '<hr class="block-divider">')
    }
    $fields=@([regex]::Matches($FindingsHtml,'(?is)<div\b[^>]*>(?:(?!</?div\b).)*</div>'))
    $issues=@($fields | Where-Object {$_.Value -match 'class="finding-value finding-(?:mismatch|unverified)"'})
    if($issues.Count -or $ChangedLabels.Count){
        $required=Get-ThoroughReportHighlightFields $RequirementHtml
        $selected=New-Object 'Collections.Generic.List[string]'
        foreach($field in $fields){
            $labelMatch=[regex]::Match($field.Value,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>')
            $label=if($labelMatch.Success){[Net.WebUtility]::HtmlDecode($labelMatch.Groups['Label'].Value).Trim()}else{''}
            $issue=$field.Value -match 'class="finding-value finding-(?:mismatch|unverified)"' -or $ChangedLabels -contains $label
            if(-not $issue -and $label -notin @('Account Name','Printer Name','Task Name','Service Name','Ports','Missing Allow Rules (Ports)','Unverified Ports')){continue}
            $selected.Add($field.Value)
            if($issue -and $required.ContainsKey($label)){
                $expected=[string]$required[$label]
                if($expected -and $expected -notin @('Path','time','date & time','0.0.0.0','Launcher hostname','Payment Service') -and $expected -notmatch '^e\.g\.'){
                    $selected.Add('<div class="fix-required">Required: '+[Net.WebUtility]::HtmlEncode($expected)+'</div>')
                }
            }
        }
        return '<div class="kv-block">'+($selected -join '')+'</div>'
    }
    # Unstructured warnings and failed readbacks must remain visible even if no
    # individual comparison field can explain the failure.
    $passed=$Row.Status -in @('Pass','Online','Remediated') -or ($Row.Status -eq 'Offline' -and $Row.ItemSub -eq 'Type: Old Payment Service')
    if($RecordScope -and $FindingsHtml -notmatch 'finding-(?:mismatch|unverified)'){
        $valueFields=@($fields | Where-Object {$_.Value.Contains('class="kv-label"')})
        $uncompared=@($valueFields | Where-Object {$_.Value -notmatch 'class="finding-value finding-match"'})
        if($valueFields.Count -and -not $uncompared.Count){
            $identity=@($valueFields | Where-Object {$_.Value -match 'class="kv-label">(?:Account Name|Printer Name|Task Name|Service Name):'}) -join ''
            $summary=if($AfterApply){'No further fix needed for these values.'}else{'No change needed for these values.'}
            return $identity+'<div class="fix-no-change">'+$summary+'</div>'
        }
    }
    if(-not $passed -or $FindingsHtml -match 'finding-(?:mismatch|unverified)|(?i:not\s+verified|manual\s+action\s+required)'){return $FindingsHtml}
    if($AfterApply){return '<div class="fix-no-change">No further fix needed.</div>'}
    '<div class="fix-no-change">No change needed.</div>'
}

function Test-ThoroughFixReportRow {
    param($Row,[string]$FindingsHtml,[string]$AppliedHtml,[bool]$AfterApply=$false)
    # Keep unresolved checks and this run's recorded repairs in the Fix report.
    # This is a display filter; it never changes observations or check outcomes.
    $passed=$Row.Status -in @('Pass','Online','Remediated') -or ($Row.Status -eq 'Offline' -and $Row.ItemSub -eq 'Type: Old Payment Service')
    if(-not $passed){return $true}
    if($FindingsHtml -match 'class="finding-value finding-(?:mismatch|unverified)"'){return $true}
    $text=Convert-ReportHtmlToTerminalText $FindingsHtml
    if($text -match '(?i)\bnot\s+verified\b|\bmanual\s+(?:action|review|verification)\s+(?:required|needed)\b'){return $true}
    if($AfterApply){
        if($Row.Status -eq 'Remediated' -or $AppliedHtml -match '<strong>(?:Completed|Not Verified|Manual Action Required)</strong>'){return $true}
        $note=Convert-ReportHtmlToTerminalText ([string]$Row.ActionTaken)
        if($note -match '(?i)\bnot\s+verified\b|\bmanual\s+(?:action|review|verification)\s+(?:required|needed)\b'){return $true}
    }
    return $false
}

function Get-ThoroughFixAccountReportView {
    param($Row,$AccountView,[string]$RequirementHtml,[bool]$AfterApply=$false,[bool]$AuditBased=$false)
    if($null -eq $AccountView -or -not $AccountView.PSObject.Properties['Records'] -or -not @($AccountView.Records).Count){return $null}
    $hasMetadata=[bool]$Row.PSObject.Properties['AccountResults']
    $metadata=@();if($hasMetadata){$metadata=@($Row.AccountResults)}
    $findings=New-Object 'Collections.Generic.List[string]'
    $applied=New-Object 'Collections.Generic.List[string]'
    $names=New-Object 'Collections.Generic.List[string]'
    foreach($account in $AccountView.Records){
        $matches=@($metadata | Where-Object {$_ -and $_.PSObject.Properties['AccountName'] -and [string]$_.AccountName -ieq [string]$account.AccountName})
        $own=if($matches.Count -eq 1){$matches[0]}else{$null}
        $record=$Row | Select-Object *
        $state=Format-ThoroughReportFieldLabels ([string]$account.FindingsHtml)
        $state=Format-ThoroughReportFindingHighlights -Row $record -FindingsHtml $state -RequirementHtml $RequirementHtml
        $fields=@([regex]::Matches($state,'(?is)<div\b[^>]*>(?:(?!</?div\b).)*</div>') | Where-Object {$_.Value.Contains('class="kv-label"')})
        $expectedFields=Get-ThoroughReportHighlightFields $RequirementHtml
        $requiredFieldCount=$expectedFields.Count
        if($account.PSObject.Properties['AdministrativePolicy'] -and $account.AdministrativePolicy -and $expectedFields.ContainsKey('User Cannot Change Password')){$requiredFieldCount--}
        $allMatched=$fields.Count -gt 0 -and $fields.Count -eq $requiredFieldCount -and -not @($fields | Where-Object {$_.Value -notmatch 'class="finding-value finding-match"'}).Count
        $uncertain=$false
        if($null -ne $own -and -not [string]::IsNullOrWhiteSpace([string]$own.Status)){
            $record.Status=[string]$own.Status
            $record.ActionTaken=[Net.WebUtility]::HtmlEncode([string]$own.Action)
        }elseif($AfterApply -or $hasMetadata){
            # Never attribute one account's repair to another when history lacks
            # an unambiguous result for this particular identity.
            $record.Status='Unknown';$record.ActionTaken='';$uncertain=$true
        }else{
            $record.Status=if($allMatched){'Pass'}else{'Fail'}
            $record.ActionTaken=''
        }
        $action=Get-ThoroughReportAppliedHtml -Row $record -AuditBased:$AuditBased -FindingsHtml $state
        $keep=Test-ThoroughFixReportRow -Row $record -FindingsHtml $state -AppliedHtml $action -AfterApply $AfterApply
        $manualReview=$null -ne $own -and [string]$own.Action -match '(?i)\bnot\s+verified\b|\bmanual\s+(?:action|review|verification)\s+(?:required|needed)\b'
        if($manualReview){$keep=$true}
        if($AfterApply -and $null -ne $own){
            if($own.PSObject.Properties['AccountPolicyChanged'] -and $own.AccountPolicyChanged -eq $true){$keep=$true}
            elseif(-not $keep -and -not $own.PSObject.Properties['AccountPolicyChanged']){
                $note=[string]$own.Action
                if($action -notmatch '<strong>No Change Needed</strong>' -and $note -notmatch '(?i)without changes|read.only'){
                    $keep=$true;$uncertain=$true
                }
            }
        }
        if(-not $keep){continue}
        $body=Format-ThoroughFixFindings -Row $record -FindingsHtml $state -RequirementHtml $RequirementHtml -AfterApply $AfterApply -RecordScope $true
        $passed=$record.Status -in @('Pass','Online','Remediated')
        if($uncertain -or (-not $passed -and $allMatched) -or ($manualReview -and $allMatched)){
            $nameField=@($fields | Where-Object {$_.Value -match 'class="kv-label">Account Name:'} | ForEach-Object {$_.Value}) -join ''
            $warning='<div class="finding-value finding-unverified" title="Account verification requires manual review">Not verified. Please review this account.</div>'
            if($allMatched){$body=$nameField+$warning}else{$body+=$warning}
            if(-not $uncertain -and -not [string]::IsNullOrWhiteSpace([string]$record.ActionTaken)){$body+='<div>'+[string]$record.ActionTaken+'</div>'}
        }
        if($uncertain){$action='<div class="applied-result"><strong>Not Verified</strong><div>Account-specific results are unavailable. Please check manually.</div></div>'}
        $heading=Format-ThoroughReportFieldLabels ([string]$account.HeadingHtml)
        [void]$findings.Add($heading+$body)
        [void]$applied.Add($heading+$action)
        [void]$names.Add([string]$account.AccountName)
    }
    # An unexplained failed aggregate must remain visible rather than becoming
    # a false clean report when older observations lack account result metadata.
    if(-not $findings.Count -and $Row.Status -notin @('Pass','Online','Remediated')){return $null}
    [pscustomobject]@{RetainedCount=$findings.Count;FindingsHtml=($findings -join '<hr class="block-divider">');AppliedHtml=($applied -join '<hr class="block-divider">');CommandHtml=(ConvertTo-ReportCommandBoxes (New-AccountReportCommand -AccountNames $names.ToArray()))}
}

function Read-ThoroughAuditFields {
    param([AllowEmptyString()][string]$Html)
    # Parse only the renderer's escaped HTML. DTDs and external resources are disabled.
    $events=[Collections.Generic.List[object]]::new()
    if([string]::IsNullOrWhiteSpace($Html)){return}
    $xml=[regex]::Replace($Html,'(?i)<(br|hr)(\b[^>]*?)(?<!/)>','<$1$2/>')
    $xml=[regex]::Replace($xml,'&(?!(?:amp|lt|gt|quot|apos);)[A-Za-z][A-Za-z0-9]+;',[Text.RegularExpressions.MatchEvaluator]{param($m) [Net.WebUtility]::HtmlEncode([Net.WebUtility]::HtmlDecode($m.Value))})
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
    $reader=$null;$inputText=[IO.StringReader]::new('<root>'+$xml+'</root>')
    try{
        $reader=[Xml.XmlReader]::Create($inputText,$settings)
        $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
    }catch{
        # Preserve opaque/malformed legacy findings rather than dropping any evidence.
        $plain=Convert-ReportHtmlToTerminalText $Html
        [pscustomobject]@{Kind='Text';Label='Details';Html=[Net.WebUtility]::HtmlEncode($plain);Text=$plain;State='';Description='';Group='';Record=''}
        return
    }finally{if($reader){$reader.Dispose()};$inputText.Dispose()}
    $context=[pscustomobject]@{Group='';Record=''}
    $walk={
        param([Xml.XmlNode]$Node)
        if($Node.NodeType -eq [Xml.XmlNodeType]::Text){
            if(-not [string]::IsNullOrWhiteSpace($Node.Value)){$events.Add([pscustomobject]@{Kind='Text';Label='Details';Html=$Node.OuterXml;Text=$Node.Value;State='';Description='';Group=$context.Group;Record=$context.Record})}
            return
        }
        if($Node.NodeType -ne [Xml.XmlNodeType]::Element -or $Node.Name -in @('hr','br')){return}
        $class=[string]$Node.GetAttribute('class')
        if($class -match '(?:^|\s)config-(group|item)-title(?:\s|$)'){
            $kind=if($Matches[1] -eq 'group'){'Group'}else{'Record'}
            if($kind -eq 'Group'){$context.Group=$Node.InnerText.Trim();$context.Record=''}else{$context.Record=$Node.InnerText.Trim()}
            $events.Add([pscustomobject]@{Kind=$kind;Label=$Node.InnerText.Trim();Html=$Node.OuterXml;Text=$Node.InnerText.Trim();State='';Description='';Group=$context.Group;Record=$context.Record})
            return
        }
        $label=$Node.SelectSingleNode('./span[contains(concat(" ",normalize-space(@class)," ")," kv-label ")]')
        $state='';$description='';$ancestor=$Node
        while($ancestor -and $ancestor.NodeType -eq [Xml.XmlNodeType]::Element){
            if(([string]$ancestor.GetAttribute('class')) -match '(?:^|\s)finding-(match|mismatch|unverified)(?:\s|$)'){
                $state=$Matches[1];$description=[string]$ancestor.GetAttribute('title');break
            }
            $ancestor=$ancestor.ParentNode
        }
        if($label){
            $valueNodes=@($Node.ChildNodes | Where-Object {-not [object]::ReferenceEquals($_,$label)})
            $events.Add([pscustomobject]@{Kind='Field';Label=$label.InnerText.Trim().TrimEnd(':');Html=(($valueNodes | ForEach-Object {$_.OuterXml}) -join '').Trim();Text=(($valueNodes | ForEach-Object {$_.InnerText}) -join '').Trim();State=$state;Description=$description;Group=$context.Group;Record=$context.Record})
            return
        }
        $structured=$Node.SelectNodes('.//*[contains(concat(" ",normalize-space(@class)," ")," kv-label ") or contains(concat(" ",normalize-space(@class)," ")," config-group-title ") or contains(concat(" ",normalize-space(@class)," ")," config-item-title ")]').Count -gt 0
        if(-not $structured -and $Node.Name -ne 'root'){
            if(-not [string]::IsNullOrWhiteSpace($Node.InnerText)){$events.Add([pscustomobject]@{Kind='Text';Label='Details';Html=$Node.OuterXml;Text=$Node.InnerText.Trim();State=$state;Description=$description;Group=$context.Group;Record=$context.Record})}
            return
        }
        foreach($child in $Node.ChildNodes){& $walk $child}
    }
    & $walk $document.DocumentElement
    $events.ToArray()
}

function Expand-ThoroughUnavailableFields {
    param([string]$Html,[string]$RequirementHtml)
    $observed=@(Read-ThoroughAuditFields $Html)
    $required=@(Read-ThoroughAuditFields $RequirementHtml|Where-Object Kind -EQ 'Field')
    if(-not $required.Count -or -not $observed.Count -or @($observed|Where-Object {$_.Kind -in @('Field','Group','Record')}).Count){return $Html}
    $reason=Convert-ReportHtmlToTerminalText $Html
    if($reason -notmatch '(?i)^(?:Not verified|Account not verified)(?:[.\s]|$)' -or $Html -match 'kv-label|fix-no-change'){return $Html}
    $parts=for($i=0;$i -lt $required.Count;$i++){
        $value=if($i -eq 0){$reason}else{'Not verified'}
        '<div class="finding-value finding-unverified" title="'+[Net.WebUtility]::HtmlEncode($reason)+'"><span class="kv-label">'+[Net.WebUtility]::HtmlEncode($required[$i].Label)+':</span> '+[Net.WebUtility]::HtmlEncode($value)+'</div>'
    }
    '<div class="kv-block">'+($parts -join '')+'</div>'
}

function Get-KioskLaunchTaskReportState {
    param([string]$Html)
    $v=Get-ThoroughReportHighlightFields $Html
    $missing=$v.ContainsKey('Task') -and $v['Task'] -in @('Missing','Not found')
    $unknown='Not verified'
    $name=if($v.ContainsKey('Task Name')){$v['Task Name']}else{$unknown}
    $status=if($missing){'Missing'}elseif($v.ContainsKey('Task Status')){$v['Task Status']}elseif($v['Task Enabled'] -eq 'Yes'){'Active'}elseif($v['Task Enabled'] -eq 'No'){'Disabled'}else{$unknown}
    $target=if($v.ContainsKey('Target')){$v['Target']}elseif($v.ContainsKey('Script Path')){$v['Script Path']}elseif($missing){'Not configured'}else{$unknown}
    $trigger=if($v.ContainsKey('Trigger Time')){$v['Trigger Time']}elseif($v.ContainsKey('Trigger')){$v['Trigger']}elseif($missing){'Not configured'}else{$unknown}
    if($trigger -eq 'At logon'){
        if($v['Logon User'] -and $v['Logon User'] -notmatch '^(?:Not |Unknown)'){$trigger+=' - '+$v['Logon User']}
        if($v['Startup Delay'] -and $v['Startup Delay'] -notmatch '^(?:Not |Unknown)'){$trigger+='; Delay: '+$v['Startup Delay']}
    }
    $fields=[ordered]@{'Task Name'=$name;'Task Status'=$status;'Target'=$target;'Trigger Time'=$trigger}
    foreach($label in @('Last Run')){$fields[$label]=if($v.ContainsKey($label)){Format-ThoroughReportDateTime -Value $v[$label]}elseif($missing){'Not recorded'}else{$unknown}}
    foreach($label in @('Last Run')){if($fields[$label] -match '^(?:30 Nov 1999, 12:00 AM|30-Nov-1999 00:00:00)$'){$fields[$label]='Not recorded'}}
    ConvertTo-ReportDefinitionHtml $fields
}

function ConvertTo-ThoroughAuditRows {
    param($Row,[string]$ComponentHtml,[string]$CommandHtml,[string]$RequirementHtml,[string]$FindingsHtml,$AccountView)
    $FindingsHtml=Expand-ThoroughUnavailableFields -Html $FindingsHtml -RequirementHtml $RequirementHtml
    $required=@(Read-ThoroughAuditFields $RequirementHtml)
    $observed=@(Read-ThoroughAuditFields $FindingsHtml)
    # Shorten only the Required cell; comparison and repair retain the full URL.
    if($Row.SectionTitle -eq 'AppSettings Check' -and $Row.ItemTitle -in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')){
        foreach($field in $required){
            $serviceOrigin=$null
            if($field.Kind -eq 'Field' -and [uri]::TryCreate($field.Text,[UriKind]::Absolute,[ref]$serviceOrigin)){
                $field.Text=$serviceOrigin.GetLeftPart([UriPartial]::Authority)
                $field.Html=[Net.WebUtility]::HtmlEncode($field.Text)
            }
        }
    }
    $specs=[Collections.Generic.List[object]]::new()
    $segments=[Collections.Generic.List[object]]::new()
    $current=[pscustomobject]@{Heading=$null;Group='';Record='';Fields=[Collections.Generic.List[object]]::new()}
    foreach($entry in $observed){
        if($entry.Kind -in @('Group','Record')){
            if($current.Heading -or $current.Fields.Count){$segments.Add($current)}
            $current=[pscustomobject]@{Heading=$entry;Group=$entry.Group;Record=$entry.Record;Fields=[Collections.Generic.List[object]]::new()}
        }else{$current.Fields.Add($entry)}
    }
    if($current.Heading -or $current.Fields.Count){$segments.Add($current)}
    $used=[Collections.Generic.HashSet[int]]::new()
    $aliases=@{'Launcher Path'='Launch Script';'File Path'='Directory';'Service Name'='Expected Names'}
    foreach($segment in $segments){
        if($segment.Heading){
            $headingHtml=$segment.Heading.Html
            $identity=@($segment.Fields | Where-Object {$_.Kind -eq 'Field' -and $_.Label -in @('Printer Name','Account Name')})
            if($segment.Heading.Kind -eq 'Record' -and $identity.Count -eq 1 -and $segment.Heading.Text -match '^(?:Printer|Account)\s+\d+$'){
                $headingHtml='<div class="config-item-title">'+[Net.WebUtility]::HtmlEncode($segment.Heading.Text+' - '+$identity[0].Text)+'</div>'
            }
            $specs.Add([pscustomobject]@{Kind='Heading';Html=$headingHtml})
        }
        $fields=@($segment.Fields | Where-Object Kind -eq 'Field')
        if(-not $fields.Count -and $segment.Fields.Count){
            $specs.Add([pscustomobject]@{Kind='Value';Label='Details';Required=$(if(-not $used.Count){$RequirementHtml}else{'&#8212;'});Found=(($segment.Fields | ForEach-Object {$_.Html}) -join '<br>');State='';Description=''})
            foreach($index in 0..($required.Count-1)){if($index -ge 0 -and $index -lt $required.Count){[void]$used.Add($index)}}
            continue
        }
        $administrativePolicy=$false
        if($AccountView -and $AccountView.PSObject.Properties['Records']){
            $name=@($fields | Where-Object Label -eq 'Account Name')
            if($name.Count -eq 1){
                $account=@($AccountView.Records | Where-Object AccountName -IEQ $name[0].Text)
                if($account.Count -eq 1){$administrativePolicy=[bool]$account[0].AdministrativePolicy}
            }
        }
        foreach($entry in $segment.Fields){
            $requiredHtml='&#8212;'
            if($entry.Kind -eq 'Field'){
                $key=if($aliases.ContainsKey($entry.Label)){$aliases[$entry.Label]}else{$entry.Label}
                $matchesForField=@(@(for($index=0;$index -lt $required.Count;$index++){
                    $candidate=$required[$index]
                    if($candidate.Kind -eq 'Field' -and $candidate.Label -ieq $key -and ($candidate.Group -eq '' -or $candidate.Group -eq $segment.Group) -and ($candidate.Record -eq '' -or $candidate.Record -eq $segment.Record)){
                        [pscustomobject]@{Index=$index;Field=$candidate;Specificity=([int]($candidate.Group -ne '')+[int]($candidate.Record -ne ''))}
                    }
                }) | Sort-Object Specificity -Descending)
                if($matchesForField.Count){
                    $best=$matchesForField[0];$requiredHtml=$best.Field.Html
                    [void]$used.Add([int]$best.Index)
                }
            }
            $specs.Add([pscustomobject]@{Kind='Value';Label=$entry.Label;Required=$requiredHtml;Found=$entry.Html;State=$entry.State;Description=$entry.Description})
        }
        # Apply only requirements relevant to this record; administrator records
        # deliberately omit the standard kiosk password-change restriction.
        foreach($index in 0..($required.Count-1)){
            if($index -lt 0 -or $index -ge $required.Count){continue}
            $candidate=$required[$index]
            if($candidate.Kind -ne 'Field' -or ($candidate.Group -and $candidate.Group -ne $segment.Group) -or ($candidate.Record -and $candidate.Record -ne $segment.Record)){continue}
            if($administrativePolicy -and $candidate.Label -eq 'User Cannot Change Password'){continue}
            $observedLabels=@($candidate.Label)+@($aliases.Keys | Where-Object {$aliases[$_] -ieq $candidate.Label})
            if(@($fields | Where-Object {$observedLabels -icontains $_.Label}).Count){continue}
            $specs.Add([pscustomobject]@{Kind='Value';Label=$candidate.Label;Required=$candidate.Html;Found='&#8212;';State='';Description='No corresponding field was recorded in this record.'})
            [void]$used.Add($index)
        }
    }
    # Keep unmatched requirement groups and opaque requirement notes visible too.
    for($index=0;$index -lt $required.Count;$index++){
        $entry=$required[$index]
        if($used.Contains($index) -or $entry.Kind -in @('Group','Record')){continue}
        if($entry.Kind -eq 'Field' -and $entry.Label -eq 'User Cannot Change Password' -and $AccountView -and @($AccountView.Records).Count -gt 0 -and -not @($AccountView.Records | Where-Object {-not $_.AdministrativePolicy}).Count){continue}
        if($entry.Kind -eq 'Text'){
            $specs.Add([pscustomobject]@{Kind='Value';Label='Required configuration';Required=$entry.Html;Found='&#8212;';State='';Description=''})
        }else{
            $specs.Add([pscustomobject]@{Kind='Value';Label=$entry.Label;Required=$entry.Html;Found='&#8212;';State='';Description='No corresponding field was recorded.'})
        }
    }
    if(-not $specs.Count){$specs.Add([pscustomobject]@{Kind='Value';Label='Details';Required=$RequirementHtml;Found=$(if($FindingsHtml){$FindingsHtml}else{'Not recorded'});State='unverified';Description='No structured observations were available.'})}
    $rows=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $specs.Count;$index++){
        $entry=$specs[$index]
        $identity=if($index -eq 0){'<td class="audit-component" rowspan="'+$specs.Count+'">'+$ComponentHtml+'</td><td class="audit-commands" rowspan="'+$specs.Count+'">'+$CommandHtml+'</td>'}else{''}
        if($entry.Kind -eq 'Heading'){
            $rows.Add('<tr class="audit-record-row">'+$identity+'<td class="audit-record-heading" colspan="3">'+$entry.Html+'</td></tr>')
        }else{
            $class=if($entry.State -in @('mismatch','unverified') -or ($entry.State -eq 'match' -and $entry.Description -in @('Matches installed USB printer','Matches installed IP printer','Matches required service URL'))){' finding-'+$entry.State}else{''}
            $title=if($entry.Description){' title="'+[Net.WebUtility]::HtmlEncode($entry.Description)+'"'}else{''}
            $rows.Add('<tr class="audit-setting-row">'+$identity+'<td class="audit-setting">'+[Net.WebUtility]::HtmlEncode($entry.Label)+'</td><td class="audit-required">'+$entry.Required+'</td><td class="audit-findings"><span class="audit-observed'+$class+'"'+$title+'>'+$entry.Found+'</span></td></tr>')
        }
    }
    $rows -join "`n"
}

function Get-ThoroughAuditColumnStyle {
    @'
    .audit-report .audit-setting { background:#f6f7f9; color:#343e49; font-weight:500; }
    .audit-report .audit-required { background:#edf4fb; color:#4b5561; }
    .audit-report .audit-findings { background:#fffbf0; }
    .audit-report .checks thead tr:last-child th:nth-child(3) { background:#e9ecf0; }
    .audit-report .checks thead tr:last-child th:nth-child(4) { background:#dfeaf7; }
    .audit-report .checks thead tr:last-child th:nth-child(5) { background:#f7efd8; }
    .audit-report .audit-record-heading { background:#edf1f6; color:#253b53; padding-top:11px; padding-bottom:11px; }
    .audit-report .audit-record-heading .config-item-title,
    .audit-report .audit-record-heading .config-group-title { margin:0; padding:0; border:0; background:transparent; font-weight:700; }
    .audit-report .checks td { white-space:normal; word-break:normal; overflow-wrap:anywhere; }
    .audit-report .audit-observed { display:inline-block; max-width:100%; white-space:normal; overflow-wrap:anywhere; vertical-align:top; }
    .audit-report .audit-observed.finding-mismatch { padding:1px 4px; border-radius:2px; background:#fdecec; color:#9b1c1c; }
    .audit-report .audit-observed.finding-unverified,
    .audit-report .finding-value.finding-unverified { padding:1px 4px; border:1px solid #d3a83e; border-radius:2px; background:#ffe3a0; color:#593900; }
    .audit-report .finding-match { background:transparent; color:inherit; }
    .audit-report .audit-observed.finding-match { padding:1px 4px; border-radius:2px; background:#e8f5e9; color:#1b5e20; }
    .audit-report .audit-record-row td { border-bottom-color:#e4e7eb; }
    .audit-report .audit-setting-row td { border-top-color:#e4e7eb; border-bottom-color:#e4e7eb; }
    @media screen { .audit-report .table-scroll { overflow-x:auto; } .audit-report .checks { min-width:960px; } }
@media screen {
    .audit-report .checks tbody td { transition: background-color 120ms ease; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-component { background: #e9eff6; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-commands { background: #f0f4f9; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-setting { background: #e9edf3; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-required { background: #e0ebf8; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-findings { background: #fff2d3; }
    .audit-report .checks tbody tr.audit-component-hover > td.audit-record-heading { background: #dfe7f1; }
}
@media (prefers-reduced-motion: reduce) {
    .audit-report .checks tbody td { transition: none; }
}

    @media print { .audit-report .audit-setting,.audit-report .audit-required,.audit-report .audit-findings,.audit-report .audit-record-heading,.audit-report .audit-observed { -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
'@
}

function Get-ThoroughAuditHoverScript {
    @'
<script>
(function () {
    document.querySelectorAll('.audit-report table.checks').forEach(function (table) {
        var groups = [], current = null, active = null;
        Array.from(table.querySelectorAll('tbody tr')).forEach(function (row) {
            if (Array.from(row.cells).some(function (cell) { return cell.classList.contains('audit-component'); })) {
                current = [];
                groups.push(current);
            }
            if (!current) return;
            row.dataset.auditComponentGroup = String(groups.length - 1);
            current.push(row);
        });
        function groupFor(target) {
            var row = target && target.closest ? target.closest('tr[data-audit-component-group]') : null;
            return row && row.closest('table') === table ? groups[Number(row.dataset.auditComponentGroup)] : null;
        }
        function highlight(group) {
            if (active === group) return;
            if (active) active.forEach(function (row) { row.classList.remove('audit-component-hover'); });
            active = group;
            if (active) active.forEach(function (row) { row.classList.add('audit-component-hover'); });
        }
        table.addEventListener('pointerover', function (event) { highlight(groupFor(event.target)); });
        table.addEventListener('pointerleave', function () { highlight(groupFor(document.activeElement)); });
        table.addEventListener('focusin', function (event) { highlight(groupFor(event.target)); });
        table.addEventListener('focusout', function (event) { highlight(groupFor(event.relatedTarget)); });
    });
}());
</script>
'@
}

function Get-ThoroughSettingRecords {
    param([AllowEmptyString()][string]$Html)
    # The existing Fix filter has already selected the records and properties.
    # Required hints remain available through comparison/action tooltips.
    $html=[regex]::Replace($Html,'(?is)(<div class="finding-value[^"\r\n]*" title=")([^"\r\n]*)(">(?:(?!</?div\b).)*</div>)<div class="fix-required">(?<Required>.*?)</div>',[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $match.Groups[1].Value+$match.Groups[2].Value+'; '+[Net.WebUtility]::HtmlEncode([Net.WebUtility]::HtmlDecode($match.Groups['Required'].Value))+$match.Groups[3].Value
    })
    $html=[regex]::Replace($html,'(?is)<div class="fix-required">.*?</div>','')
    # Legacy Fix fragments can leave an outer stack div open after filtering.
    # Browsers close it at the cell boundary; close that wrapper for XML parsing.
    $unclosed=[regex]::Matches($html,'(?i)<div(?:\s[^>]*)?>').Count-[regex]::Matches($html,'(?i)</div\s*>').Count
    if($unclosed -gt 0){$html+=('</div>'*$unclosed)}
    $records=[Collections.Generic.List[object]]::new()
    $current=[pscustomobject]@{Heading=$null;Group='';Record='';Fields=[Collections.Generic.List[object]]::new();Identity=$null;Key=''}
    foreach($entry in @(Read-ThoroughAuditFields $html)){
        if($entry.Kind -in @('Group','Record')){
            if($current.Heading -or $current.Fields.Count){$records.Add($current)}
            $current=[pscustomobject]@{Heading=$entry;Group=$entry.Group;Record=$entry.Record;Fields=[Collections.Generic.List[object]]::new();Identity=$null;Key=''}
        }else{$current.Fields.Add($entry)}
    }
    if($current.Heading -or $current.Fields.Count){$records.Add($current)}
    foreach($record in $records){
        foreach($label in @('Account Name','Printer Name','Service Name','Task Name','Terminal ID','TerminalId','POS ID','PosId','Ports')){
            $identity=@($record.Fields|Where-Object {$_.Kind -eq 'Field' -and $_.Label -ieq $label -and -not [string]::IsNullOrWhiteSpace($_.Text) -and $_.Text -notmatch '(?i)^(?:not verified|not detected|no printer detected|unknown|missing|not found)'})
            if($identity.Count -eq 1){$record.Identity=$identity[0];break}
        }
        $key=if($record.Identity){$record.Identity.Label+[char]31+$record.Identity.Text}else{$record.Record}
        $record.Key=$record.Group+[char]31+$key
    }
    $records.ToArray()
}

function ConvertTo-ThoroughSettingValue {
    param([AllowEmptyString()][string]$Html,[string]$State,[string]$Description)
    $plain=Convert-ReportHtmlToTerminalText $Html
    if($plain -match '(?i)\bnot\s+verified\b|^(?:not detected|no printer detected|not recorded|not applied|unknown|unavailable|not executed)(?:[.\s(]|$)'){$State='unverified'}
    $class=if($State -in @('mismatch','unverified','manual') -or ($State -eq 'match' -and $Description -in @('Matches installed USB printer','Matches installed IP printer','Matches required service URL'))){' finding-'+$State}else{''}
    $title=if($Description){' title="'+[Net.WebUtility]::HtmlEncode($Description)+'"'}else{''}
    '<span class="setting-observed'+$class+'"'+$title+'>'+$Html+'</span>'
}

function ConvertTo-ThoroughSettingRows {
    param($Row,[ValidateSet('Fix','Final')][string]$Mode,[string]$ComponentHtml,[string]$CommandHtml,
        [string]$FindingsHtml,[string]$CurrentHtml,[string]$AppliedHtml,[bool]$AfterApply=$false,[bool]$HasBeforeRow=$false)
    $requirement=Get-ReportRequirement $Row
    $FindingsHtml=Expand-ThoroughUnavailableFields $FindingsHtml $requirement
    $CurrentHtml=Expand-ThoroughUnavailableFields $CurrentHtml $requirement
    $records=@(Get-ThoroughSettingRecords $FindingsHtml)
    $currentRecords=@(Get-ThoroughSettingRecords $CurrentHtml)
    # This component is one aggregate; its port list can legitimately change
    # from None/Any to explicit ports after a verified repair or fresh readback.
    if($Row.ItemTitle -in @('Firewall Inbound Port','Payment Service Restart Task','PaymentService Restart Task') -and $records.Count -eq 1 -and $currentRecords.Count -eq 1){$currentRecords[0].Key=$records[0].Key}
    $noBaseline=$Mode -eq 'Fix' -and $AfterApply -and -not $HasBeforeRow
    # A retained repair may have only an old generic no-change summary. Show the
    # recorded post-fix properties without inventing their missing pre-fix values.
    if($noBaseline -and $FindingsHtml -match 'class="fix-no-change"' -and -not @($records.Fields|Where-Object Kind -EQ 'Field').Count){$records=$currentRecords}
    $specs=[Collections.Generic.List[object]]::new()
    foreach($record in $records){
        if($Row.ItemTitle -eq 'Kiosk Launch Architecture'){
            $launcherOrder=@('Launcher Path','URL origin','Restaurant ID','Kiosk ID','Host name')
            $record.Fields=@($record.Fields | Sort-Object { $position=[array]::IndexOf($launcherOrder,[string]$_.Label);if($position -lt 0){99}else{$position} })
        }
        if($record.Heading){
            $heading=$record.Heading.Html
            if($record.Heading.Kind -eq 'Record' -and $record.Identity -and $record.Identity.Label -in @('Account Name','Printer Name') -and $record.Heading.Text -match '^(?:Account|Printer)\s+\d+$'){
                $heading='<div class="config-item-title">'+[Net.WebUtility]::HtmlEncode($record.Heading.Text+' - '+$record.Identity.Text)+'</div>'
            }
            $specs.Add([pscustomobject]@{Kind='Heading';Html=$heading})
        }
        $matches=@($currentRecords|Where-Object {$_.Key -ieq $record.Key -and $_.Fields.Count})
        $post=if($matches.Count -eq 1){$matches[0]}else{$null}
        $note=if($Mode -eq 'Final'){Convert-ReportHtmlToTerminalText ([string]$Row.ActionTaken)}else{Convert-ReportHtmlToTerminalText $AppliedHtml}
        $trusted=$AfterApply -and $null -ne $post
        $readOnly=$Row.SectionTitle -eq 'AppSettings Check' -and $Row.ItemTitle -notin @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')
        if($AfterApply){
            if($record.Identity -and $record.Identity.Label -eq 'Account Name'){
                $own=@();if($Row.PSObject.Properties['AccountResults']){$own=@($Row.AccountResults|Where-Object {$_.AccountName -ieq $record.Identity.Text})}
                if($own.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$own[0].Status) -or $own[0].Status -in @('Unknown','Bypass')){$trusted=$false}
                else{
                    $note=[string]$own[0].Action
                    if($own[0].Status -notin @('Pass','Online','Remediated') -and $note -match '(?i)reject|exception|could not|failed|not verified'){$trusted=$false}
                }
            }elseif($Row.ItemTitle -match '^(?:KIOSK Account|Local Account:|Administrative Account|SELISE Local Accounts)'){$trusted=$false}
            elseif($Row.PSObject.Properties['LegacyServiceRows']){
                $own=@($Row.LegacyServiceRows|Where-Object {([regex]::Replace([string]$_.ItemTitle,'\s+\(Legacy\)$','')) -ieq $record.Record})
                if($own.Count -eq 1){$note=Convert-ReportHtmlToTerminalText ([string]$own[0].ActionTaken)}else{$trusted=$false}
            }elseif($record.Identity -and $record.Identity.Label -eq 'Printer Name'){
                # Grouped printer notes are prefixed with the exact printer name.
                # Read only this device's note; a sibling failure is not its result.
                $names=@($currentRecords|Where-Object {$_.Identity -and $_.Identity.Label -eq 'Printer Name'}|ForEach-Object {[regex]::Escape($_.Identity.Text)})
                $raw=Convert-ReportHtmlToTerminalText ([string]$Row.ActionTaken)
                $markers=@([regex]::Matches($raw,'(?<Name>' + ($names -join '|') + '):\s*'))
                $own=@(for($i=0;$i -lt $markers.Count;$i++){if($markers[$i].Groups['Name'].Value -ieq $record.Identity.Text){$i}})
                if($own.Count -eq 1){
                    $start=$markers[$own[0]].Index+$markers[$own[0]].Length
                    $end=if($own[0]+1 -lt $markers.Count){$markers[$own[0]+1].Index}else{$raw.Length}
                    $note=$raw.Substring($start,$end-$start).Trim(' ',';')
                }elseif($currentRecords.Count -gt 1){$trusted=$false}
            }
            if([string]::IsNullOrWhiteSpace($note) -or $note -match '(?i)\breadback\b[^.;]*(?:fail|could not|not verified|unavailable)|(?:fail|could not)[^.;]*\breadback\b|\bnot reverified\b|account-specific results are unavailable'){$trusted=$false}
        }
        # A grouped printer failure must not turn healthy sibling printers into
        # repairs. Keep a sibling only when it has its own issue or recorded work.
        if($Mode -eq 'Fix' -and $Row.ItemTitle -eq 'Printer' -and $record.Identity -and $record.Identity.Label -eq 'Printer Name'){
            $noChange=@($record.Fields | Where-Object {$_.Html -match 'class="fix-no-change"'}).Count -gt 0
            $printerWork=$AfterApply -and $note -match '(?i)Enabled Keep printed documents|not verified|manual|fail|could not|exception'
            if($noChange -and -not $printerWork){
                if($record.Heading){$specs.RemoveAt($specs.Count-1)}
                continue
            }
        }
        if($Mode -eq 'Fix' -and $Row.ItemTitle -eq 'Printer' -and -not @($record.Fields | Where-Object {$_.Kind -ne 'Field' -or $_.Label -ne 'Printer Name'}).Count){
            if($record.Heading){$specs.RemoveAt($specs.Count-1)}
            continue
        }
        if($Mode -eq 'Fix' -and $Row.ItemTitle -eq 'Printer' -and -not $record.Heading){
            $printerName=@($record.Fields | Where-Object {$_.Kind -eq 'Field' -and $_.Label -eq 'Printer Name'})
            if($printerName.Count -eq 1){$specs.Add([pscustomobject]@{Kind='Heading';Html=('<div class="config-item-title">Printer - '+[Net.WebUtility]::HtmlEncode($printerName[0].Text)+'</div>')})}
        }
        $seen=@{}
        foreach($field in $record.Fields){
            $label=[string]$field.Label
            $ordinal=if($seen.ContainsKey($label)){[int]$seen[$label]}else{0};$seen[$label]=$ordinal+1
            $printerIdentity=$Row.ItemTitle -eq 'Printer' -and $label -eq 'Printer Name'
            $beforeHtml=if($noBaseline -and -not $printerIdentity){'Not recorded'}else{$field.Html}
            $before=ConvertTo-ThoroughSettingValue -Html $beforeHtml -State $field.State -Description $field.Description
            if($Mode -eq 'Final'){
                $identityField=$field.Label -in @('Account Name','Printer Name','Service Name','Task Name','Ports')
                if($AfterApply -and -not $trusted -and -not $readOnly -and $field.Kind -eq 'Field' -and -not $identityField){
                    $value=ConvertTo-ThoroughSettingValue -Html 'Not verified' -State unverified -Description $note
                }else{$value=ConvertTo-ThoroughSettingValue -Html $field.Html -State $field.State -Description $field.Description}
            }else{
                $afterHtml='Not verified';$afterState='unverified'
                if($AfterApply -and $field.Kind -eq 'Text' -and $field.Html -match 'class="fix-no-change"'){$afterHtml='&#8212;';$afterState=''}
                elseif(-not $AfterApply -or $readOnly){$afterHtml='Not applied'}
                elseif($trusted){
                    $postLabel=if($Row.ItemTitle -eq 'lodctr /R Performance Counter' -and $label -eq 'Audit'){'Rebuild State'}else{$label}
                    $candidates=@($post.Fields|Where-Object {$_.Kind -eq $field.Kind -and $_.Label -ieq $postLabel})
                    $beforeCount=@($record.Fields|Where-Object {$_.Kind -eq $field.Kind -and $_.Label -ieq $label}).Count
                    # Duplicate property names retain their occurrence only when
                    # both records contain the same number. Never guess a match.
                    if($candidates.Count -eq $beforeCount -and $ordinal -lt $candidates.Count){$afterHtml=$candidates[$ordinal].Html;$afterState=$candidates[$ordinal].State}
                    elseif($Row.ItemTitle -eq 'Firewall Inbound Port' -and $Row.Status -eq 'Pass' -and $label -in @('Missing Allow Rules (Ports)','Unverified Ports') -and -not $candidates.Count){$afterHtml='None';$afterState='match'}
                }
                $valueNote=$note
                if($Row.ItemTitle -eq 'Printer' -and $label -eq 'Printer status' -and $field.Kind -eq 'Field'){
                    $observedStatus=if($AfterApply){Convert-ReportHtmlToTerminalText $afterHtml}else{$field.Text}
                    if($observedStatus -in @('Not available','Offline','Paused','Error')){
                        $afterHtml='Manual Action Required';$afterState='manual'
                        $valueNote='Printer status requires manual attention; this check does not repair availability or resume queues.'
                    }
                }
                $value=ConvertTo-ThoroughSettingValue -Html $afterHtml -State $afterState -Description $valueNote
            }
            if($Mode -eq 'Fix' -and $printerIdentity){$value=''}
            $displayLabel=if($Row.ItemTitle -eq 'lodctr /R Performance Counter' -and $label -eq 'Audit'){'Rebuild State'}else{$label}
            $specs.Add([pscustomobject]@{Kind='Value';Label=$displayLabel;Before=$before;Value=$value})
        }
    }
    if(-not $specs.Count -and $Mode -eq 'Fix' -and $Row.ItemTitle -eq 'Printer'){return}
    if(-not $specs.Count){$specs.Add([pscustomobject]@{Kind='Value';Label='Details';Before='Not recorded';Value=(ConvertTo-ThoroughSettingValue 'Not verified' 'unverified' '')})}
    for($index=0;$index -lt $specs.Count;$index++){
        $entry=$specs[$index]
        $identity=if($index -eq 0){'<td class="setting-component" rowspan="'+$specs.Count+'">'+$ComponentHtml+'</td>'+$(if($Mode -eq 'Fix'){'<td class="setting-commands" rowspan="'+$specs.Count+'">'+$CommandHtml+'</td>'})}else{''}
        if($entry.Kind -eq 'Heading'){
            $span=if($Mode -eq 'Fix'){3}else{2}
            '<tr class="setting-record-row">'+$identity+'<td class="setting-record-heading" colspan="'+$span+'">'+$entry.Html+'</td></tr>'
        }else{
            $before=if($Mode -eq 'Fix'){'<td class="setting-before">'+$entry.Before+'</td>'}else{''}
            '<tr class="setting-value-row">'+$identity+'<td class="setting-label">'+[Net.WebUtility]::HtmlEncode($entry.Label)+'</td>'+$before+'<td class="setting-current">'+$entry.Value+'</td></tr>'
        }
    }
}

function Get-ThoroughSettingColumnStyle {
    $style=(Get-ThoroughAuditColumnStyle).Replace('audit-report','setting-report').Replace('audit-setting','setting-label').Replace('audit-required','setting-before').Replace('audit-findings','setting-current').Replace('audit-','setting-')
    $style+"`n"+@'
    .setting-report .setting-value-row td { border-top-color:#e4e7eb; border-bottom-color:#e4e7eb; }
    .setting-report .setting-observed.finding-manual { padding:1px 4px; border:1px solid #d3a83e; border-radius:2px; background:#ffe3a0; color:#593900; }
    .fix-report .checks thead tr:last-child th:nth-child(4) { background:#dfeaf7; }
    .fix-report .checks thead tr:last-child th:nth-child(5),
    .final-report .checks thead tr:last-child th:nth-child(3) { background:#f7efd8; }
    .final-report .checks thead tr:last-child th:nth-child(2) { background:#e9ecf0; }
    @media screen { .final-report .checks { min-width:600px; } }
'@
}

function Get-ThoroughSettingHoverScript {
    (Get-ThoroughAuditHoverScript).Replace('audit','setting')
}

function Get-ThoroughAuditAdditionalHtml {
    # These are operator references, not audit findings or executable actions.
    $nmapScript=@'
cd $env:TEMP
Invoke-WebRequest -Uri "https://nmap.org/dist/nmap-7.95-setup.exe" -OutFile "nmap-setup.exe"
Start-Process ".\nmap-setup.exe" -Wait
'@
    $nmapButton=(ConvertTo-ReportCommandBoxes (New-ReportCommand @($nmapScript))).Replace('<code>','<code style="white-space:pre-wrap">')
    $printerUrl=[Net.WebUtility]::HtmlEncode('https://download-center.epson.com/download/?module_id=fa99ba54-3151-4dbc-8b3c-31ed9d314d6b%3A1.50&device_id=TM-m30III&os=WIN1064&region=DE&language=en')
    @"
<section class="report-additional" aria-labelledby="additional-heading">
<h2 id="additional-heading">ADDITIONAL</h2>
<table aria-label="Manual installation resources">
    <colgroup><col style="width:25%"><col style="width:75%"></colgroup>
    <thead><tr><th scope="col">Resource</th><th scope="col">Manual Download / Installation</th></tr></thead>
    <tbody>
        <tr><td><strong>Nmap</strong></td><td>Copy the script and run it in PowerShell to open the installation wizard.$nmapButton</td></tr>
        <tr><td><strong>Printer Utility</strong></td><td><a href="$printerUrl" target="_blank" rel="noopener noreferrer">Download Epson Printer Utility</a><br>Download the utility from the Epson page, then run the downloaded installer.</td></tr>
    </tbody>
</table>
</section>
"@
}

function New-ThoroughReportSnapshot {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory=$true)][ValidateSet('Audit','Fix','Final')][string]$DisplayMode,
        [string]$ClientLocation,[string]$DeviceType,[string]$Hostname,[string]$LauncherKioskId,
        [string]$RequestedKioskId,[string]$KioskUserName,[bool]$AfterApply=$false,$AuditSource=$null,[AllowEmptyCollection()][object[]]$BeforeRows=@(),[string]$AgentName,[string]$LauncherRestaurantId)
    # Presentation flags are separate from the execution gate. Rendering another
    # view never enables repairs or reruns a component check.
    $isApplyReport=$DisplayMode -eq 'Fix';$isFinalReport=$DisplayMode -eq 'Final'
    $isAuditReport=$DisplayMode -eq 'Audit'
    $reportHostname=$Hostname;$reportKioskId=$LauncherKioskId;$KioskId=$RequestedKioskId;$kioskUser=$KioskUserName
    if([string]::IsNullOrWhiteSpace($AgentName) -and $AuditSource -and $AuditSource.PSObject.Properties['AgentName']){$AgentName=[string]$AuditSource.AgentName}
    $preparedBy=if([string]::IsNullOrWhiteSpace($AgentName) -or $AgentName -eq 'Not provided'){'Not provided'}else{$AgentName.Trim()}
    $generatedAt=if($AuditSource){$AuditSource.GeneratedAt}else{Format-ThoroughReportDateTime -Value ([DateTimeOffset]::UtcNow) -TimeZone BST}
$reportId = if($AuditSource){$AuditSource.ReportId}else{New-ThoroughReportId}
$reportDeviceLabel = Get-ThoroughReportDeviceLabel -DeviceType $deviceType -LauncherKioskId $reportKioskId -RequestedKioskId $KioskId
$reportRestaurantId=if([string]::IsNullOrWhiteSpace($LauncherRestaurantId)){'Not detected'}else{$LauncherRestaurantId.Trim()}
$reportDeviceType=$deviceType.ToUpperInvariant()
$deviceDisplayName=[Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($deviceType.ToLowerInvariant())
$reportDevice=if([string]::IsNullOrWhiteSpace($deviceDisplayName)){'Not verified'}
elseif($reportDeviceLabel -match ('^'+[regex]::Escape($reportDeviceType)+'-(\d+)$')){
    $deviceDisplayName+'-'+([uint32]$Matches[1]).ToString([Globalization.CultureInfo]::InvariantCulture)
}elseif($reportDeviceLabel.StartsWith($reportDeviceType+' - ')){
    $deviceDisplayName+' - '+$reportDeviceLabel.Substring($reportDeviceType.Length+3)
}else{$deviceDisplayName+' (number not verified)'}
$reportTitle = Get-ThoroughReportTitle -IsApply $isApplyReport -IsFinal ([bool]$isFinalReport)
$htmlHeader = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$reportTitle</title>
<style>
    * { box-sizing: border-box; }
    body { margin: 0; padding: 24px; background: #fff; color: #222; font: 13px/1.45 Arial, Helvetica, sans-serif; }
    .report { max-width: 1280px; margin: 0 auto; }
    @media screen { .report { max-width: 1000px; } }
    h1 { font-size: 23px; line-height: 1.25; color: #253b53; margin: 0; padding-bottom: 12px; border-bottom: 1px solid #253b53; }
    h2 { font-size: 15px; color: #253b53; margin: 24px 0 10px; }
    table { width: 100%; border-collapse: collapse; table-layout: fixed; margin-bottom: 16px; }
    th, td { border: 1px solid #b9bfc5; padding: 8px; text-align: left; vertical-align: top; overflow-wrap: anywhere; word-wrap: break-word; }
    th { background: #eceef0; font-weight: 600; }
    .metadata th { width: 16%; }
    .metadata td { width: 34%; }
    .section-title { background: #f1f2f3; color: #222; font-size: 13px; }
    .device-title { font-weight: 600; }
    .command-copy { display: block; width: 100%; margin: 0 0 6px; padding: 7px; border: 1px solid #c5cbd1; border-radius: 3px; background: #f7f8f9; color: #253b53; text-align: left; cursor: pointer; }
    .command-copy:last-child { margin-bottom: 0; }
    .command-copy:hover { background: #eef1f4; border-color: #7d8c9a; }
    .command-copy:focus { outline: 2px solid #526f8c; outline-offset: 2px; }
    .command-copy code { display: block; font-size: 11px; }
    .copy-feedback { display: block; margin-top: 4px; font: 10px/1.3 Arial, sans-serif; color: #626b73; }
    .command-copy[data-copied="true"] .copy-feedback { color: #245638; }
    .kv-block { line-height: 1.5; }
    .kv-label { font-weight: 600; }
    .finding-value { display: block; width: fit-content; max-width: 100%; margin: 2px 0; padding: 1px 4px; border-radius: 3px; }
    .finding-match { background: #e8f5e9; color: #1b5e20; }
    .finding-mismatch { background: #fdecec; color: #9b1c1c; }
    .finding-unverified { background: #fff8e1; color: #7a5a00; }
    .config-group-title { font-weight:600; margin:0 0 14px; color:#253b53; }
    .config-item-title { font-weight:600; margin:0 0 9px; padding:6px 9px; border-left:3px solid #708192; background:#f3f5f7; color:#253b53; line-height:1.5; }
    .config-item-title:first-child, .config-group-title + .config-item-title { margin-top:0; }
    .config-item-title + .kv-block > div { margin-top:2px; margin-bottom:2px; }
    .block-divider { height:0; margin:14px 0; padding:0; border:0; border-top:1px solid #b9bfc5; }
    .aligned-record { display:flow-root; min-width:0; }
    .fix-required { font-size:11px; color:#626b73; margin:0 0 6px 4px; }
    .badge { font-size: 11px; font-weight: bold; text-transform: uppercase; }
    .badge-pass { color: #245638; }
    .badge-fail { color: #922b21; }
    code { font: 10px/1.4 Consolas, monospace; white-space: normal; overflow-wrap: anywhere; }
    .legend, .report-footer { font-size: 11px; color: #555; }
    .report-footer { display:flex; justify-content:space-between; align-items:baseline; flex-wrap:wrap; gap:8px 24px; border-top: 1px solid #b9bfc5; margin-top: 24px; padding-top: 8px; break-inside:avoid; }
    .report-prepared-by { margin-left:auto; text-align:right; max-width:100%; overflow-wrap:anywhere; }
    @page { size: A4 portrait; margin: 12mm; }
    @media print {
        body { padding: 0; font-size: 9pt; }
        h1 { font-size: 17pt; }
        th, td { padding: 5px; }
        thead { display: table-header-group; }
        tr { break-inside: avoid; page-break-inside: avoid; }
        h2 { break-after: avoid; }
        .badge { color: #222; }
        .finding-value, .config-item-title { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        .copy-feedback { display: none; }
        .command-copy { background: transparent; border-color: #ddd; color: #222; cursor: default; }
    }
    @media screen and (max-width: 700px) {
        body { padding: 12px; }
        .table-scroll { overflow-x: auto; }
        .checks { min-width: 720px; }
        h1 { font-size: 20px; }
    }
</style>
</head>
<body>
<main class="report">
<h1>$($reportTitle.ToUpperInvariant())</h1>
<h2>CLIENT DETAILS</h2>
<table class="metadata" aria-label="Client and device details">
    <tr><th>Client Type</th><td>$([Net.WebUtility]::HtmlEncode($script:KioskClientSettings.ClientType))</td><th>Branch</th><td>$([Net.WebUtility]::HtmlEncode($clientLocation))</td></tr>
    <tr><th>Restaurant ID</th><td>$([Net.WebUtility]::HtmlEncode($reportRestaurantId))</td><th>Hostname</th><td>$([Net.WebUtility]::HtmlEncode($reportHostname))</td></tr>
    <tr><th>Device</th><td>$([Net.WebUtility]::HtmlEncode($reportDevice))</td><th>Prepared by</th><td>$([Net.WebUtility]::HtmlEncode($preparedBy))</td></tr>
</table>
<h2>CONFIGURATION CHECK</h2>
"@

$reportRows = @(if($isFinalReport){Get-ThoroughFinalReportRows -Rows $Rows -ConfirmedKioskUser $KioskUserName -AfterApply $AfterApply}else{Get-ThoroughReportDisplayRows -Rows $Rows})
$baselineReportRows=@()
if($isApplyReport -and $AfterApply -and $BeforeRows.Count){
    $baselineReportRows=@(Get-ThoroughReportDisplayRows -Rows $BeforeRows)
    foreach($before in $baselineReportRows){
        $matching=@($reportRows|Where-Object {$_.SectionNumber -eq $before.SectionNumber -and (Get-ThoroughReportComponentName $_.ItemTitle) -eq (Get-ThoroughReportComponentName $before.ItemTitle)})
        if(-not $matching.Count){
            $unverified=$before|Select-Object *
            $unverified.Status='Fail';$unverified.FoundStateHtml='Not verified. This component was not available during Apply.'
            $unverified.ActionTaken='The component was not reverified during Apply. Manual action required.'
            $reportRows+=,$unverified
        }
    }
}
$groupedSections = $reportRows | Group-Object SectionNumber | Sort-Object { [int]$_.Name }
$htmlSections = foreach ($group in $groupedSections) {
    $secName = [Net.WebUtility]::HtmlEncode($group.Group[0].SectionTitle)
    $secNum = [Net.WebUtility]::HtmlEncode($group.Name)
    $tableRows = foreach ($row in $group.Group) {
        $checkHtml = '<div class="device-title">{0}</div>' -f ([Net.WebUtility]::HtmlEncode((Get-ThoroughReportComponentName $row.ItemTitle)))
        $commandHtml=ConvertTo-ReportCommandBoxes $row.Shortcut
        $findingRow=$row;$hasBeforeRow=$false
        if($isApplyReport -and $AfterApply -and $baselineReportRows.Count){
            $before=Get-ThoroughBeforeFindingRow -Row $row -BeforeRows $baselineReportRows
            if($before){$findingRow=$before;$hasBeforeRow=$true}
        }
        $accountView=Get-AccountReportView $findingRow
        $stateHtml=if ($null -ne $accountView) { $accountView.FindingsHtml } else { Format-ReportState $findingRow.ItemTitle $findingRow.FoundStateHtml }
        if ($isFinalReport -and $row.ItemTitle -eq 'lodctr /R Performance Counter' -and $row.Status -eq 'Bypass') {
            $stateHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{'Rebuild State'='Not executed (read-only verification)'})
        }
        if($isFinalReport){$stateHtml=Format-ThoroughFinalServiceRecovery -Row $row -Html $stateHtml}
        $stateHtml=Format-ThoroughReportFieldLabels $stateHtml
        $requirementHtml=Format-ThoroughReportFieldLabels (Get-ReportRequirement $findingRow)
        $stateHtml=Format-ThoroughReportFindingHighlights -Row $findingRow -FindingsHtml $stateHtml -RequirementHtml $requirementHtml -KioskAccountName $kioskUser
        if($isAuditReport){
            ConvertTo-ThoroughAuditRows -Row $row -ComponentHtml $checkHtml -CommandHtml $commandHtml -RequirementHtml $requirementHtml -FindingsHtml $stateHtml -AccountView $accountView
        } elseif ($isApplyReport) {
            $accountFix=if($hasBeforeRow){
                Get-ThoroughFixAccountBeforeView -Row $row -BeforeView $accountView -AfterView (Get-AccountReportView $row) -RequirementHtml $requirementHtml
            }else{
                Get-ThoroughFixAccountReportView -Row $row -AccountView $accountView -RequirementHtml $requirementHtml -AfterApply $AfterApply -AuditBased:([bool]$AuditSource)
            }
            if($null -ne $accountFix){
                if(-not $accountFix.RetainedCount){continue}
                $stateHtml=$accountFix.FindingsHtml;$appliedHtml=$accountFix.AppliedHtml;$commandHtml=$accountFix.CommandHtml
            }else{
                $changedLabels=@()
                if($AfterApply -and $hasBeforeRow -and $row.ItemTitle -eq 'Kiosk Launch Architecture'){
                    $oldFields=Get-ThoroughReportHighlightFields $findingRow.FoundStateHtml
                    $newFields=Get-ThoroughReportHighlightFields $row.FoundStateHtml
                    $changedLabels=@('URL origin','Restaurant ID','Kiosk ID','Host name' | Where-Object {$oldFields.ContainsKey($_) -and $newFields.ContainsKey($_) -and $oldFields[$_] -cne $newFields[$_]})
                }
                $stateHtml=Format-ThoroughFixFindings -Row $findingRow -FindingsHtml $stateHtml -RequirementHtml $requirementHtml -AfterApply:($AfterApply -and -not $hasBeforeRow) -ChangedLabels $changedLabels
                $appliedHtml=Get-ThoroughReportAppliedHtml -Row $row -AuditBased:([bool]$AuditSource) -FindingsHtml $stateHtml
            }
            if(-not (Test-ThoroughFixReportRow -Row $row -FindingsHtml $stateHtml -AppliedHtml $appliedHtml -AfterApply $AfterApply)){continue}
            $postAccount=Get-AccountReportView $row
            $postHtml=if($postAccount){$postAccount.FindingsHtml}else{Format-ReportState $row.ItemTitle $row.FoundStateHtml}
            $postHtml=Format-ThoroughReportFieldLabels $postHtml
            $postHtml=Format-ThoroughReportFindingHighlights -Row $row -FindingsHtml $postHtml -RequirementHtml (Format-ThoroughReportFieldLabels (Get-ReportRequirement $row)) -KioskAccountName $kioskUser
            ConvertTo-ThoroughSettingRows -Row $row -Mode Fix -ComponentHtml $checkHtml -CommandHtml $commandHtml -FindingsHtml $stateHtml -CurrentHtml $postHtml -AppliedHtml $appliedHtml -AfterApply $AfterApply -HasBeforeRow $hasBeforeRow
        } else {
            ConvertTo-ThoroughSettingRows -Row $row -Mode Final -ComponentHtml $checkHtml -FindingsHtml $stateHtml -CurrentHtml $stateHtml -AfterApply $AfterApply
        }
    }
    if(($isApplyReport -or $isFinalReport) -and -not @($tableRows).Count){continue}
    $columnCount=if($isFinalReport){3}else{5}
    if($isApplyReport){
        $columnWidths='<col style="width:17%"><col style="width:23%"><col style="width:20%"><col style="width:20%"><col style="width:20%">'
        $columnHeaders='<th scope="col">Component</th><th scope="col">Shortcut / Command</th><th scope="col">Setting</th><th scope="col">Findings</th><th scope="col">Applied</th>'
    }else{
        $columnWidths='<col style="width:25%"><col style="width:30%"><col style="width:45%">'
        $columnHeaders='<th scope="col">Component</th><th scope="col">Setting</th><th scope="col">Status</th>'
    }
    if($isAuditReport){
        $columnCount=5
        $columnWidths='<col style="width:17%"><col style="width:23%"><col style="width:21%"><col style="width:18%"><col style="width:21%">'
        $columnHeaders='<th scope="col">Component</th><th scope="col">Shortcut / Command</th><th scope="col">Setting</th><th scope="col">Required</th><th scope="col">Findings</th>'
    }
    @"
<div class="table-scroll">
<table class="checks" aria-label="$secName">
    <colgroup>$columnWidths</colgroup>
    <thead>
        <tr><th colspan="$columnCount" class="section-title">$secNum. $secName</th></tr>
        <tr>$columnHeaders</tr>
    </thead>
    <tbody>$($tableRows -join "`n")</tbody>
</table>
</div>
"@
}

if($isApplyReport -and -not @($htmlSections).Count){$message=if($reportRows.Count){'No fixes required.'}else{'No findings available. Please run Audit Report.'};$htmlSections='<p class="fix-empty" role="status">'+$message+'</p>'}

$htmlFooter = @"
<p class="legend">Green = Matched requirement or collected value; Red = Mismatched requirement or missing value; Amber = Not verified; Uncolored = Informational only. AppSettings values are a configuration record, not confirmation of the site assignment.</p>
<footer class="report-footer"><span>Retain with the device configuration records.</span><span class="report-generated-at"><strong>Generated Time:</strong> $([Net.WebUtility]::HtmlEncode($generatedAt))</span></footer>
$(Get-ThoroughReportCopyScript)
$(Get-ThoroughReportBlockAlignmentScript)
</main>
</body>
</html>
"@

$finalHtml = $htmlHeader + ($htmlSections -join "`n") + $htmlFooter
if($isAuditReport){
    $finalHtml=$finalHtml.Replace('<p class="legend">',(Get-ThoroughAuditAdditionalHtml)+"`n"+'<p class="legend">')
    $finalHtml=$finalHtml.Replace('<body>','<body class="audit-report">').Replace('</style>',(Get-ThoroughAuditColumnStyle)+"`n</style>")
    $finalHtml=$finalHtml.Replace('Green = Matched requirement or collected value; Red = Mismatched requirement or missing value; Amber = Not verified; Uncolored = Informational only.','Red = Requirement not met or missing value; Amber = Not verified; Plain values = Matched, collected or informational values.')
    $finalHtml=$finalHtml.Replace('</main>',(Get-ThoroughAuditHoverScript)+"`n</main>")
}
if(-not $isAuditReport){
    $bodyClass=if($isFinalReport){'final-report setting-report'}else{'fix-report setting-report'}
    $finalHtml=$finalHtml.Replace('<body>','<body class="'+$bodyClass+'">').Replace('</style>',(Get-ThoroughSettingColumnStyle)+"`n</style>")
    $finalHtml=$finalHtml.Replace('</main>',(Get-ThoroughSettingHoverScript)+"`n</main>")
    $legend=if($isFinalReport){'Status shows the latest recorded setting values. This report records the observed configuration without applying repairs. Red = Requirement not met or missing value; Amber = Not verified. AppSettings values are a configuration record, not confirmation of the site assignment.'}else{'Findings shows recorded pre-fix values when available; Applied shows recorded post-fix values. Not applied = No fix was run; Not verified = A post-fix value could not be verified. Red = Requirement not met or missing value; Amber = Not verified. Hover over Applied values for recorded action details.'}
    $finalHtml=[regex]::Replace($finalHtml,'(?is)<p class="legend">.*?</p>','<p class="legend">'+$legend+'</p>')
}
    if($isFinalReport -and $AfterApply){
        $finalHtml=$finalHtml.Replace('This report records the observed configuration without applying repairs.','This report records the actual post-fix configuration observed during Apply Fix. No additional repairs were run to generate this view.')
    }
    $hostLabel=if($Hostname -and $Hostname -notin @('Not verified','Not detected')){$Hostname}else{'Unknown'}
    $hostLabel=($hostLabel -replace '[<>:"/\\|?*\x00-\x1F]','_').Trim().TrimEnd('.')
    if(-not $hostLabel){$hostLabel='Unknown'};if($hostLabel.Length -gt 60){$hostLabel=$hostLabel.Substring(0,60)}
    [pscustomobject]@{Mode=$DisplayMode;ReportId=$reportId;RestaurantId=$reportRestaurantId;GeneratedAt=$generatedAt;AgentName=$preparedBy;
        Origin=$(if($AuditSource){'Audit observations'}elseif($AfterApply){'Apply Fix readback'}elseif($DisplayMode -eq 'Final'){'Read-only verification'}else{$DisplayMode});
        HtmlBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($finalHtml));
        Observations=$(if($DisplayMode -eq 'Audit'){@(Copy-ThoroughObservationRows $reportRows)}else{$null});
        ExportFileName=(('Thorough Check Report - '+$script:KioskClientSettings.ClientType+' - ')+$hostLabel+'.html')}
}

function New-ThoroughReportBundleHtml {
    param([Parameter(Mandatory=$true)]$State)
    $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 12 -Compress)))
    $template=@'
<!doctype html>
<html lang="en" data-thorough-bundle-version="1">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Thorough Check Reports</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f3f5f7;color:#253b53;font:14px/1.5 Arial,Helvetica,sans-serif}
.bundle-header{padding:20px 0 16px;background:#fff;border-bottom:1px solid #d7dde3}
.bundle-intro,.bundle-toolbar{width:calc(100% - 48px);max-width:1200px;margin:auto}
.bundle-header h1{font-size:24px;margin:4px 0 5px}
.bundle-toolbar{display:flex;align-items:center;gap:18px;padding-top:18px;flex-wrap:wrap}.bundle-toolbar label{font-size:12px;font-weight:bold}
.bundle-toolbar select{margin-left:8px;padding:8px 28px 8px 10px;border:1px solid #b9c3cd;border-radius:4px;background:#fff;color:#253b53;font:inherit}
.bundle-tabs{display:flex;gap:4px;padding:4px;border:1px solid #d7dde3;border-radius:6px;background:#f3f5f7}
.bundle-tabs button{padding:8px 20px;border:0;border-radius:3px;background:transparent;color:#526272;font:inherit;cursor:pointer}
.bundle-tabs button[aria-selected="true"]{background:#253b53;color:#fff}
.bundle-actions{margin-left:auto;display:flex;gap:8px}.bundle-actions[hidden]{display:none}
.bundle-action{padding:8px 12px;border:1px solid #b9c3cd;border-radius:4px;background:#fff;color:#253b53;font:inherit;cursor:pointer}
.bundle-action:hover{background:#eef1f4}.bundle-toolbar button:focus-visible,.bundle-toolbar select:focus-visible{outline:2px solid #526f8c;outline-offset:3px}
.bundle-description{width:calc(100% - 48px);max-width:1200px;padding:12px 0;margin:auto;font-size:12px;color:#526272;min-height:42px}
.bundle-frame{display:block;width:calc(100% - 48px);max-width:1200px;height:calc(100vh - 235px);min-height:480px;margin:0 auto 20px;border:1px solid #d7dde3;border-radius:4px;background:#fff}
.bundle-empty{max-width:900px;margin:40px auto;padding:32px;background:#fff;border:1px solid #d7dde3;border-radius:4px;color:#253b53}.bundle-empty h2{margin-top:0;font-size:20px}
#print-report{display:none}.bundle-message{width:calc(100% - 48px);max-width:1200px;margin:auto;padding:0 0 8px;color:#9b1c1c;font-size:12px}
@media(max-width:700px){.bundle-header{padding:16px 0}.bundle-intro,.bundle-toolbar,.bundle-description,.bundle-message{width:calc(100% - 24px)}.bundle-header h1{font-size:21px}.bundle-toolbar{gap:12px}.bundle-tabs{flex-wrap:wrap}.bundle-tabs button{padding:8px 12px}.bundle-actions{margin-left:0}.bundle-description{padding:12px 0}.bundle-frame{width:calc(100% - 24px);height:70vh}}
@media print{body{padding:0!important;margin:0!important;background:#fff!important}.bundle-ui,.bundle-frame{display:none!important}#print-report{display:block!important}}
</style>
</head>
<body>
<header class="bundle-header bundle-ui">
  <div class="bundle-intro"><h1>Thorough Check Reports</h1></div>
  <div class="bundle-toolbar">
    __CLIENT_CONTROL__
    <div class="bundle-tabs" role="tablist" aria-label="Report view">
      <button type="button" role="tab" id="tab-Audit" data-mode="Audit" aria-controls="report-frame" aria-selected="false" tabindex="-1">Audit</button>
      <button type="button" role="tab" id="tab-Fix" data-mode="Fix" aria-controls="report-frame" aria-selected="false" tabindex="-1">Fix</button>
      <button type="button" role="tab" id="tab-Final" data-mode="Final" aria-controls="report-frame" aria-selected="false" tabindex="-1">Final</button>
    </div>
    <div class="bundle-actions" id="bundle-actions" hidden>
      <button type="button" class="bundle-action" id="print-final">Print</button>
    </div>
  </div>
</header>
<p class="bundle-description bundle-ui" id="bundle-description" aria-live="polite"></p>
<p class="bundle-message bundle-ui" id="bundle-message" role="status" hidden></p>
<iframe class="bundle-frame" id="report-frame" title="Report view" role="tabpanel" aria-labelledby="tab-Final"></iframe>
<div id="print-report" aria-hidden="true"></div>
<noscript><p class="bundle-empty">JavaScript is required to switch between the reports saved inside this file.</p></noscript>
<script id="thorough-report-state" type="application/octet-stream">__STATE_DATA__</script>
<script>
(function(){
'use strict';
function decode(text){var bytes=Uint8Array.from(atob(text),function(c){return c.charCodeAt(0);});return new TextDecoder('utf-8',{fatal:true}).decode(bytes);}
var state=JSON.parse(decode(document.getElementById('thorough-report-state').textContent.trim()));
var clients=state.Catalog||[state],selection=document.getElementById('bundle-client'),frame=document.getElementById('report-frame');
var mode=state.LatestMode||'Final',active=clients[0],modes=['Audit','Fix','Final'];
var labels={Audit:'Audit',Fix:'Fix',Final:'Thorough Check Report'};
var descriptions={Audit:'Saved audit findings and required configuration.',Fix:'Items requiring attention and recorded actions.',Final:'Recorded final configuration and verification results.'};
if(selection){clients.forEach(function(client,index){var option=document.createElement('option');option.value=String(index);option.textContent=client.ClientType;selection.appendChild(option);});}

function message(text){var el=document.getElementById('bundle-message');el.textContent=text;el.hidden=!text;}
function preparePrint(){
  var root=document.getElementById('print-report'),previous=document.getElementById('final-print-style');root.replaceChildren();if(previous)previous.remove();
  var snapshot=active.Reports.Final;
  if(!snapshot){var note=document.createElement('p');note.textContent='Thorough Check Report has not been generated. Run Audit Report or Apply Fix first.';root.appendChild(note);return;}
  var parsed=new DOMParser().parseFromString(decode(snapshot.HtmlBase64),'text/html');
  parsed.querySelectorAll('script').forEach(function(script){script.remove();});
  var style=document.createElement('style');style.id='final-print-style';style.media='print';style.textContent=Array.from(parsed.querySelectorAll('style'),function(el){return el.textContent;}).join('\n');document.head.appendChild(style);
  var report=parsed.querySelector('main.report');if(!report)throw new Error('Final report content is unavailable.');root.appendChild(report.cloneNode(true));
}
function update(){
  message('');var snapshot=active.Reports[mode];
  document.querySelectorAll('[data-mode]').forEach(function(button){var selected=button.dataset.mode===mode;button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;});
  frame.setAttribute('aria-labelledby','tab-'+mode);frame.title=active.ClientType+' '+labels[mode];
  document.getElementById('bundle-actions').hidden=mode!=='Final'||!snapshot;
  document.getElementById('bundle-description').textContent=descriptions[mode]+(snapshot?(snapshot.Origin==='Audit observations'?' Based on Audit.':'')+' Saved: '+snapshot.GeneratedAt+' | Restaurant ID: '+(snapshot.RestaurantId||'Not detected'):' Not run.');
  if(snapshot){frame.srcdoc=decode(snapshot.HtmlBase64);}
  else{var empty=document.implementation.createHTMLDocument(labels[mode]);var main=empty.createElement('main');main.style.cssText='font:14px/1.5 Arial,sans-serif;color:#253b53;padding:32px';var title=empty.createElement('h2');title.textContent=labels[mode]+' has not been run';var note=empty.createElement('p');note.textContent='Run this mode in Device Management to add its results to this file.';main.append(title,note);empty.body.appendChild(main);frame.srcdoc='<!doctype html>'+empty.documentElement.outerHTML;}
  preparePrint();
}
if(selection){selection.addEventListener('change',function(){active=clients[Number(selection.value)];update();});}
document.querySelectorAll('[data-mode]').forEach(function(button){
  button.addEventListener('click',function(){mode=button.dataset.mode;update();});
  button.addEventListener('keydown',function(event){var index=modes.indexOf(mode),next;if(event.key==='ArrowRight')next=(index+1)%modes.length;else if(event.key==='ArrowLeft')next=(index+modes.length-1)%modes.length;else if(event.key==='Home')next=0;else if(event.key==='End')next=modes.length-1;else return;event.preventDefault();mode=modes[next];update();document.getElementById('tab-'+mode).focus();});
});

document.getElementById('print-final').addEventListener('click',function(){if(mode==='Final'&&active.Reports.Final){preparePrint();window.print();}});
var originalTitle=document.title;
window.addEventListener('beforeprint',function(){preparePrint();if(active.Reports.Final){document.title=(active.Reports.Final.ExportFileName||'Thorough Check Report').replace(/\.html$/i,'');}});
window.addEventListener('afterprint',function(){document.title=originalTitle;});
if(modes.indexOf(mode)<0)mode='Final';update();
}());
</script>
</body>
</html>
'@
    $clientControl=if($State.PSObject.Properties['Catalog'] -and $State.TestOnly){'<label for="bundle-client">Client<select id="bundle-client" aria-label="Report client"></select></label>'}else{''}
    $template.Replace('__STATE_DATA__',$data).Replace('__CLIENT_CONTROL__',$clientControl)
}

function Read-ThoroughReportBundleState {
    param([Parameter(Mandatory=$true)][string]$Html)
    $match=[regex]::Match($Html,'(?is)<script id="thorough-report-state" type="application/octet-stream">([A-Za-z0-9+/=\s]+)</script>')
    if(-not $Html.Contains('data-thorough-bundle-version="1"') -or -not $match.Success -or $Html -notmatch '(?is)</body>\s*</html>\s*$'){throw 'The existing combined report is not a supported, complete report file. It was preserved.'}
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    $state=$utf8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json -ErrorAction Stop
    if($state.Version -ne 1 -or $state.ClientType -notin @('SaaS','Subway') -or [string]::IsNullOrWhiteSpace([string]$state.ComputerName) -or $state.BundleId -notmatch '^OMK-\d{6}$' -or $null -eq $state.Reports){throw 'The existing combined report has invalid identity or report data. It was preserved.'}
    foreach($property in $state.Reports.PSObject.Properties){
        if($property.Name -notin @('Audit','Fix','Final')){throw 'The existing combined report contains an unsupported report mode.'}
        $snapshot=$property.Value
        if($null -eq $snapshot){continue}
        if($snapshot.Mode -cne $property.Name -or $snapshot.ReportId -notmatch '^OMK-\d{6}$'){throw 'A saved report snapshot has invalid mode or identity.'}
        $metadataCell=if($snapshot.PSObject.Properties['RestaurantId']){'<th>Restaurant ID</th><td>'+[Net.WebUtility]::HtmlEncode([string]$snapshot.RestaurantId)+'</td>'}else{'<th>Report ID</th><td>'+$snapshot.ReportId+'</td>'}
        $document=$utf8.GetString([Convert]::FromBase64String([string]$snapshot.HtmlBase64))
        $metadataValid=$document.Contains($metadataCell)
        if(-not $metadataValid -and $snapshot.PSObject.Properties['RestaurantId']){
            $metadataValid=$document.Contains('<dt>Restaurant ID</dt><dd>'+[Net.WebUtility]::HtmlEncode([string]$snapshot.RestaurantId)+'</dd>')
        }
        if($document -notmatch '(?is)<!doctype html>.*<main class="report">' -or -not $metadataValid -or $document -notmatch '(?is)</body>\s*</html>\s*$'){throw 'A saved report snapshot is incomplete or inconsistent.'}
    }
    $state
}

function Save-ThoroughReportBundle {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][ValidateSet('SaaS','Subway')][string]$ClientType,
        [Parameter(Mandatory=$true)][string]$ComputerName,[Parameter(Mandatory=$true)][object[]]$Snapshots,
        [Parameter(Mandatory=$true)][ValidateSet('Audit','Fix','Final')][string]$PreferredMode)
    $fullPath=[IO.Path]::GetFullPath($Path)
    if([IO.Path]::GetExtension($fullPath) -ine '.html' -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($fullPath))){throw 'The combined report destination must be an HTML file in an existing report folder.'}
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{$lockName='Local\OMKReport-'+[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToUpperInvariant()))).Replace('-','')}finally{$hasher.Dispose()}
    $mutex=[Threading.Mutex]::new($false,$lockName);$owned=$false;$stage=$null
    try{
        try{$owned=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Another run is updating this combined report. Please retry after that run finishes.'}
        $reports=[ordered]@{Audit=$null;Fix=$null;Final=$null}
        $created=[DateTimeOffset]::Now.ToString('o');$bundleId=New-ThoroughReportId
        if([IO.File]::Exists($fullPath)){
            $existing=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($fullPath))
            if($existing.ClientType -cne $ClientType -or $existing.ComputerName -ine $ComputerName){throw 'The existing combined report belongs to another client or computer. It was preserved.'}
            foreach($mode in @('Audit','Fix','Final')){if($existing.Reports.PSObject.Properties[$mode]){$reports[$mode]=$existing.Reports.$mode}}
            $created=$existing.CreatedAt;$bundleId=$existing.BundleId
        }
        foreach($snapshot in $Snapshots){
            if($snapshot.Mode -notin @('Audit','Fix','Final')){throw 'An incoming report snapshot has an unsupported mode.'}
            # Audit-derived views fill unrun modes and refresh earlier Audit
            # views, while actual Fix/Final observations retain precedence.
            $previous=$reports[$snapshot.Mode]
            if($snapshot.PSObject.Properties['Origin'] -and $snapshot.Origin -eq 'Audit observations' -and $previous -and
                (-not $previous.PSObject.Properties['Origin'] -or $previous.Origin -ne 'Audit observations')){continue}
            $reports[$snapshot.Mode]=$snapshot
        }
        $state=[pscustomobject]@{Version=1;ClientType=$ClientType;ComputerName=$ComputerName;BundleId=$bundleId;CreatedAt=$created;UpdatedAt=[DateTimeOffset]::Now.ToString('o');LatestMode=$PreferredMode;Reports=[pscustomobject]$reports}
        $html=New-ThoroughReportBundleHtml $state
        [void](Read-ThoroughReportBundleState $html)
        $stage=$fullPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($stage,$html,(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($fullPath)){[IO.File]::Replace($stage,$fullPath,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($stage,$fullPath)}
        if([IO.File]::ReadAllText($fullPath) -cne $html){throw 'The saved combined report failed readback verification.'}
        $fullPath
    }finally{
        if($stage -and [IO.File]::Exists($stage)){[IO.File]::Delete($stage)}
        if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

function ConvertTo-ThoroughFinalReportHtml {
    param ([Parameter(Mandatory=$true)][string]$Html)
    # Use the same observed values and results; omit commands and the comparison column.
    $tables=@([regex]::Matches($Html,'(?is)<table class="checks"[^>]*>.*?</table>'))
    for($index=$tables.Count-1;$index -ge 0;$index--){
        $table=$tables[$index]
        $hasStatus=$table.Value.Contains('<th>Status</th>')
        $body=[regex]::Match($table.Value,'(?is)<tbody>(.*?)</tbody>')
        if(-not $body.Success){throw 'Final report table has no findings body.'}
        $rows=foreach($row in [regex]::Matches($body.Groups[1].Value,'(?is)<tr\b[^>]*>.*?</tr>')){
            $cells=@([regex]::Matches($row.Value,'(?is)<td\b[^>]*>.*?</td>'))
            $expected=if($hasStatus){5}else{4}
            if($cells.Count -ne $expected){throw 'Final report table has an unexpected column count.'}
            $component=$cells[0].Value
            $selected=@($component,$cells[3].Value)
            if($hasStatus){$selected+=$cells[4].Value}
            '<tr>'+($selected -join '')+'</tr>'
        }
        $updated=$table.Value.Remove($body.Index,$body.Length).Insert($body.Index,'<tbody>'+($rows -join "`n")+'</tbody>')
        $updated=$updated.Replace('<th>Shortcut / Command</th>','').Replace('<th>Required Configuration</th>','').Replace('<th>Findings</th>','<th>Final Configuration</th>')
        $widths=if($hasStatus){'<col style="width:23%"><col style="width:65%"><col style="width:12%">'}else{'<col style="width:23%"><col style="width:77%">'}
        $updated=[regex]::Replace($updated,'(?is)<colgroup>.*?</colgroup>','<colgroup>'+$widths+'</colgroup>')
        $updated=$updated.Replace(('colspan="'+$expected+'"'),('colspan="'+($expected-2)+'"'))
        $Html=$Html.Remove($table.Index,$table.Length).Insert($table.Index,$updated)
    }
    # Remove semantic color styles and any highlight markup in saved snapshots.
    $Html=[regex]::Replace($Html,'(?i)class="finding-value finding-(?:match|mismatch|unverified)"','class="final-value"')
    $Html=[regex]::Replace($Html,'(?is)\.(?:finding-(?:match|mismatch|unverified)|badge-pass|badge-fail)\s*\{[^}]*\}','')
    $neutralStyle=@"
    .final-value { display:block; margin:2px 0; }
    .component-context { margin-top:4px; color:#626b73; font-size:11px; }
    h1, h2, .command-copy, .command-copy code, .badge, .copy-feedback,
    .command-copy[data-copied="true"] .copy-feedback { color:#222; }
    h1 { border-color:#777; }
    .command-copy { background:#f7f7f7; border-color:#c7c7c7; }
    .command-copy:hover { background:#eee; border-color:#888; }
    .command-copy:focus { outline-color:#777; }
"@
    $Html=$Html.Replace('</style>',$neutralStyle+"`n</style>")
    $Html=[regex]::Replace($Html,'(?is)<p class="legend">.*?</p>','<p class="legend">Pass = Requirement met; Fail = Requirement not met or not verified. This report records the observed configuration without applying repairs. AppSettings values are a configuration record, not confirmation of the site assignment.</p>')
    return $Html
}

function Get-ThoroughReportAppliedHtml {
    param ([Parameter(Mandatory=$true)]$Row,[switch]$AuditBased,[string]$FindingsHtml)
    if($Row.SectionTitle -eq 'AppSettings Check'){
        if($Row.Status -eq 'Remediated' -and $Row.ItemTitle -in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')){
            return '<div class="applied-result"><strong>Completed</strong><div>'+[string]$Row.ActionTaken+'</div></div>'
        }
        if(Test-ThoroughAppSettingsReview $Row){return '<div class="applied-result"><strong>Manual Review Required</strong><div>Expected values are not configured. Please check manually.</div></div>'}
        return 'Read Only'
    }
    if($Row.PSObject.Properties['LegacyServiceRows']){
        $blocks=foreach($service in $Row.LegacyServiceRows){
            $name=[regex]::Replace([string]$service.ItemTitle,'\s+\(Legacy\)$','')
            if([string]::IsNullOrWhiteSpace($name)){$name='Not verified'}
            $headingName=[Net.WebUtility]::HtmlEncode($name).Replace('[','&#91;').Replace(']','&#93;')
            '<div class="config-item-title">'+$headingName+'</div>'+(Get-ThoroughReportAppliedHtml -Row $service -AuditBased:$AuditBased)
        }
        return Format-ThoroughReportFieldLabels ($blocks -join '')
    }

    if($AuditBased){
        $passed=$Row.Status -in @('Pass','Online','Remediated') -or ($Row.Status -eq 'Offline' -and $Row.ItemSub -eq 'Type: Old Payment Service')
        $label=if($passed -and $FindingsHtml -notmatch 'finding-(?:mismatch|unverified)'){'No Change Needed'}else{'Not Applied'}
        return '<div class="applied-result"><strong>'+$label+'</strong></div>'
    }
    # Presentation only: use recorded actions and preserve partial repairs,
    # verification limits and manual instructions without changing the result.
    $note=Convert-ReportHtmlToTerminalText ([string]$Row.ActionTaken)
    if ([string]::IsNullOrWhiteSpace($note) -or $note -eq '-') {
        return '<div class="applied-result"><strong>Not Verified</strong><div>No action was recorded. Please check manually.</div></div>'
    }
    $passed=$Row.Status -in @('Pass','Online','Remediated') -or ($Row.Status -eq 'Offline' -and $Row.ItemSub -eq 'Type: Old Payment Service')
    $readOnlyCheck=$Row.ItemTitle -in @('Kiosk Auto-Login','SELISE-KIOSK Startup Folder')
    $parts=@($note -split ';\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $changePattern='(?i)\b(?:Allowed password changes|Updated launcher URL origin|Updated Local Network Allowlist|Enabled (?:Keep printed documents|Password Never Expires|User Cannot Change Password)|Updated (?:launcher|Zabbix) hostname|Startup set to (?:Automatic|Manual|Disabled)|Service (?:started|stopped|stop requested)|Crash recovery configured|Recovery actions (?:configured|set to Take No Action)|PrintService log enabled|Created (?:missing |the )?desktop shortcut|Created (?:missing )?(?:Payment Service )?restart task|(?:Created|Updated) inbound TCP \d+ rule|Installed missing (?:Nmap|Zabbix Agent)|Performance counters rebuilt|Added (?:only --disable-pinch|Local Network Allowlist|Translation|Visual Search|Edge Gestures))\b'
    $hasRecordedChange=$note -match $changePattern
    $noChangeOnly=$true
    $hasNoChangeNote=$false
    foreach($part in $parts){
        # Account, printer and port groups prefix their notes with an identity.
        $plain=if($part -match '(?i)^All recovery actions:'){$part}else{[regex]::Replace($part,'^[^:;]+:\s*','').Trim()}
        if($plain -match '(?i)^(?:No changes? needed[.!]?\s*)+$'){$hasNoChangeNote=$true;continue}
        if($part -match '(?i)\bno changes? (?:needed|made|applied)\b'){$hasNoChangeNote=$true}
        if($plain -notmatch '(?i)^(?:Requested password settings are enabled|Service settings verified|Firewall rule verified|Operational log verified enabled|Existing installation retained|Version check passed|Readback verified|Verified Stopped / (?:Disabled|Manual)|All recovery actions: Take No Action)[.!]?$'){$noChangeOnly=$false}
    }
    $label=if(-not $passed){'Manual Action Required'}
        elseif($readOnlyCheck){'Verified'}
        elseif($hasRecordedChange){'Completed'}
        elseif($noChangeOnly -and ($hasNoChangeNote -or $note -match '(?i)^(?:Operational log verified enabled|Existing installation retained)')){'No Change Needed'}
        else{'Verified'}

    $details=New-Object 'Collections.Generic.List[string]'
    foreach($part in $parts){
        # Remove duplicate generic no-op text; keep identity-specific notes.
        if($passed -and $part -match '(?i)^(?:No changes? needed[.!]?\s*)+$'){continue}
        if($label -eq 'Manual Action Required'){
            $part=[regex]::Replace($part,'(?i)(?<!\S)Manual action required[.!]?(?=\s|$)','').Trim()
            if(-not $part){continue}
        }
        $text=switch -Regex ($part){
            '(?i)^readback verified[.!]?$' {'Configuration verified.';break}
            '(?i)^target readback verified[.!]?$' {'Shortcut target verified.';break}
            '(?i)^lodctr returned exit code 0[.!]?$' {'Exit code: 0.';break}
            default {$part}
        }
        if($text -match '(?i)^(?:service|startup|recovery|version|monitoring|existing|verify|required|content|failed|task)\b'){$text=$text.Substring(0,1).ToUpperInvariant()+$text.Substring(1)}
        $details.Add(('<div>'+[Net.WebUtility]::HtmlEncode($text)+'</div>'))
    }
    '<div class="applied-result"><strong>'+[Net.WebUtility]::HtmlEncode($label)+'</strong>'+($details -join '')+'</div>'
}

function Get-ThoroughReportTitle {
    param ([bool]$IsApply, [bool]$IsFinal=$false)
    if ($IsFinal) { return 'Thorough Check Report' }
    if ($IsApply) { return 'Thorough Check Fix Report' }
    'Thorough Check Audit Report'
}

function Format-ReportAction {
    param ([string]$Html)
    # Keep failure reasons and verification limits; put each statement on its own line.
    if ([string]::IsNullOrWhiteSpace($Html)) { return 'No action recorded' }
    '<div class="kv-block">' + (($Html -split '<br\s*/?>|; ' | ForEach-Object {
        '<div>' + $_ + '</div>'
    }) -join '') + '</div>'
}

function New-ReportCommand {
    param ([string[]]$Commands)
    ($Commands | ForEach-Object { '<code>' + [Net.WebUtility]::HtmlEncode($_) + '</code>' }) -join '<br>'
}

function ConvertTo-ReportCommandBoxes {
    param ([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '&mdash;' }
    $matches=[regex]::Matches($Html,'(?is)<code\b[^>]*>(.*?)</code>')
    $commands=if ($matches.Count) {
        foreach ($match in $matches) { [Net.WebUtility]::HtmlDecode($match.Groups[1].Value).Trim() }
    } else {
        $plain=$Html -replace '(?i)<br\s*/?>|</div>',"`n"
        $plain=[Net.WebUtility]::HtmlDecode(($plain -replace '<[^>]+>',''))
        $plain -split '\r?\n' | ForEach-Object { $_.Trim() }
    }
    $boxes=foreach ($command in $commands) {
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        $encoded=[Net.WebUtility]::HtmlEncode($command)
        $label=[Net.WebUtility]::HtmlEncode('Copy command: '+$command)
        '<button type="button" class="command-copy" data-command="{0}" aria-label="{1}" title="Click to copy command"><code>{0}</code><span class="copy-feedback" aria-live="polite">Click to copy</span></button>' -f $encoded,$label
    }
    if (@($boxes).Count -eq 0) { return '&mdash;' }
    $boxes -join ''
}

function Get-ThoroughReportCopyScript {
    @'
<script>
(function () {
    'use strict';
    function showFeedback(button, message, copied) {
        button.querySelector('.copy-feedback').textContent = message;
        button.setAttribute('data-copied', copied ? 'true' : 'false');
    }
    function legacyCopy(text) {
        var active = document.activeElement;
        var selection = window.getSelection();
        var ranges = [];
        if (selection) {
            for (var i = 0; i < selection.rangeCount; i++) ranges.push(selection.getRangeAt(i).cloneRange());
        }
        var field = document.createElement('textarea');
        field.value = text;
        field.setAttribute('readonly', '');
        field.style.cssText = 'position:fixed;left:-9999px;top:0;';
        document.body.appendChild(field);
        try {
            field.focus();
            field.select();
            field.setSelectionRange(0, text.length);
            return document.execCommand('copy') === true;
        } catch (error) {
            return false;
        } finally {
            field.remove();
            if (active && active.focus) active.focus({ preventScroll: true });
            if (selection) {
                selection.removeAllRanges();
                ranges.forEach(function (range) { selection.addRange(range); });
            }
        }
    }
    document.addEventListener('click', function (event) {
        var button = event.target.closest('button.command-copy');
        if (!button) return;
        var text = button.getAttribute('data-command');
        window.clearTimeout(button.copyFeedbackTimer);
        showFeedback(button, 'Copying...', false);
        function complete(copied) {
            showFeedback(button, copied ? 'Copied' : 'Copy failed. Please try again.', copied);
            if (copied) {
                button.copyFeedbackTimer = window.setTimeout(function () {
                    showFeedback(button, 'Click to copy', false);
                }, 2000);
            }
        }
        function fallback() { complete(legacyCopy(text)); }
        if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
            try {
                navigator.clipboard.writeText(text).then(function () { complete(true); }, fallback);
            } catch (error) { fallback(); }
        } else { fallback(); }
    });
}());
</script>
'@
}

function Format-ThoroughReportDateTime {
    param([object]$Value,[ValidateSet('Full','Date','Time')][string]$Part='Full',
        [ValidateSet('Device','BST')][string]$TimeZone='Device',
        [TimeZoneInfo]$DeviceTimeZone=[TimeZoneInfo]::Local)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $instant=$null;$date=[datetime]::MinValue
    if($Value -is [datetimeoffset]){$instant=$Value}
    elseif($Value -is [datetime]){
        if($Value.Kind -eq [DateTimeKind]::Unspecified){$date=$Value}
        else{$instant=[datetimeoffset]$Value}
    }else{
        $text=([string]$Value).Trim()
        if(-not $text){return $text}
        # Also accept a previously formatted timestamp without inventing a zone.
        $parseText=$text -replace ' \(UTC([+-]\d{2}:\d{2})\)$',' $1' -replace ' BST$',' +06:00'
        if($parseText -match '(?:Z|[+-]\d{2}:\d{2})$'){
            $parsed=[datetimeoffset]::MinValue
            $formats=[string[]]@('dd-MMM-yyyy HH:mm:ss zzz','yyyy-MM-ddTHH:mm:sszzz','yyyy-MM-ddTHH:mm:ss.FFFFFFFzzz','yyyy-MM-ddTHH:mm:ssK','yyyy-MM-ddTHH:mm:ss.FFFFFFFK','d MMM yyyy, h:mm tt zzz','d MMMM yyyy, h:mm:ss tt zzz','d MMMM yyyy, h:mm:ss.FFFFFFF tt zzz','d MMMM yyyy, h:mm tt zzz')
            if(-not [datetimeoffset]::TryParseExact($parseText,$formats,$culture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){return $text}
            $instant=$parsed
        }else{
            $formats=[string[]]@('dd-MMM-yyyy HH:mm:ss','yyyy-MM-ddTHH:mm:ss','yyyy-MM-ddTHH:mm:ss.FFFFFFF','d MMM yyyy, h:mm tt','d MMMM yyyy, h:mm:ss tt','d MMMM yyyy, h:mm:ss.FFFFFFF tt','d MMMM yyyy, h:mm tt')
            if(-not [datetime]::TryParseExact($parseText,$formats,$culture,[Globalization.DateTimeStyles]::None,[ref]$date)){return $text}
        }
    }
    if($TimeZone -eq 'BST'){
        if($null -eq $instant){
            # Offset-free task values are device-local, even on a device outside Bangladesh.
            try{$instant=[datetimeoffset]([TimeZoneInfo]::ConvertTimeToUtc($date,$DeviceTimeZone))}catch{return [string]$Value}
        }
        $date=$instant.ToOffset([TimeSpan]::FromHours(6)).DateTime
    }elseif($null -ne $instant){
        $date=[TimeZoneInfo]::ConvertTime([datetimeoffset]$instant,$DeviceTimeZone).DateTime
    }
    $display=switch($Part){'Date'{$date.ToString('dd MMM yyyy',$culture)};'Time'{$date.ToString('h:mm tt',$culture)};default{$date.ToString('dd MMM yyyy, h:mm tt',$culture)}}
    if($TimeZone -eq 'BST' -and $Part -ne 'Date'){$display+=' BST'}
    $display
}

function Format-ThoroughReportDuration {
    param([string]$Value)
    $text=$Value.Trim()
    if($text -notmatch '^P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$'){return $Value}
    try{$duration=[Xml.XmlConvert]::ToTimeSpan($text)}catch{return $Value}
    $parts=New-Object 'Collections.Generic.List[string]'
    foreach($unit in @(@('Days','day'),@('Hours','hour'),@('Minutes','minute'))){
        $number=$duration.($unit[0])
        if($number){$parts.Add(([string]$number+' '+$unit[1]+$(if($number -ne 1){'s'})))}
    }
    $seconds=($duration.Ticks % [TimeSpan]::TicksPerMinute)/[double][TimeSpan]::TicksPerSecond
    if($seconds){$parts.Add(($seconds.ToString('0.#######',[Globalization.CultureInfo]::InvariantCulture)+' second'+$(if($seconds -ne 1){'s'})))}
    if(-not $parts.Count){return '0 seconds'}
    $parts -join ', '
}

function Format-ThoroughReportTriggerDetails {
    param([string]$Value,[TimeZoneInfo]$DeviceTimeZone=[TimeZoneInfo]::Local)
    if([string]::IsNullOrWhiteSpace($Value)){return $Value}
    $known=@('Daily','Weekly','Monthly','MonthlyDOW','Time','Boot','Logon','Idle','Event','Registration','SessionStateChange','Trigger')
    $results=New-Object 'Collections.Generic.List[string]'
    foreach($raw in @($Value -split '\s+\|\s+')){
        $tokens=@($raw -split ';\s*');$kind=$tokens[0].Trim()
        if($kind -notin $known){$results.Add($raw);continue}
        $values=[ordered]@{};$flags=New-Object 'Collections.Generic.List[string]'
        foreach($token in @($tokens | Select-Object -Skip 1)){
            $match=[regex]::Match($token,'^([^:]+):\s*(.*)$')
            if($match.Success){$values[$match.Groups[1].Value.Trim()]=$match.Groups[2].Value.Trim()}
            elseif($token.Trim()){$flags.Add($token.Trim())}
        }
        $used=@{};$pieces=New-Object 'Collections.Generic.List[string]'
        $frequency=switch($kind){
            'Daily'{'Daily schedule'};'Weekly'{'Weekly schedule'};'Monthly'{'Monthly schedule'};'MonthlyDOW'{'Monthly weekday schedule'}
            'Time'{'Once'};'Boot'{'At system startup'};'Logon'{'At user sign-in'};'Idle'{'When the computer is idle'}
            'Event'{'When the event occurs'};'Registration'{'When the task is registered'};'SessionStateChange'{'When the session changes'};default{'Trigger'}
        }
        if($kind -in @('Daily','Weekly')){
            $key=if($kind -eq 'Daily'){'DaysInterval'}else{'WeeksInterval'}
            if($values.Contains($key)){
                $interval=0
                if([int]::TryParse($values[$key],[ref]$interval) -and $interval -gt 0){
                    $unit=if($kind -eq 'Daily'){'day'}else{'week'}
                    $frequency=if($interval -eq 1 -and $kind -eq 'Daily'){'Everyday'}elseif($interval -eq 1){'Every '+$unit}else{'Every '+$interval+' '+$unit+'s'}
                    $used[$key]=$true
                }
            }
        }
        $startDate='';$startTime='';$startKnown=$false
        if($values.Contains('Start')){
            $startDate=Format-ThoroughReportDateTime -Value $values['Start'] -Part Date -DeviceTimeZone $DeviceTimeZone
            $startTime=Format-ThoroughReportDateTime -Value $values['Start'] -Part Time -DeviceTimeZone $DeviceTimeZone
            $startKnown=$startDate -cne $values['Start']
        }
        if($startKnown -and $kind -in @('Daily','Weekly','Monthly','MonthlyDOW')){$frequency+=' at '+$startTime}
        elseif($startKnown -and $kind -eq 'Time'){$frequency+=' on '+$startDate+' at '+$startTime}
        $pieces.Add($frequency)
        if($values.Contains('Enabled')){
            $state=switch($values['Enabled']){'True'{'Enabled'};'False'{'Disabled'};default{'State: '+$values['Enabled']}}
            if($state -ne 'Enabled'){$pieces.Add($state)};$used['Enabled']=$true
        }
        if($values.Contains('Start')){
            if(-not $startKnown){$pieces.Add('Start: '+$values['Start']+' (Not verified)')}
            # Recurring schedules show their device-local time; Next Run supplies the date.
            elseif($kind -notin @('Time','Daily','Weekly','Monthly','MonthlyDOW')){$pieces.Add('Starts '+(Format-ThoroughReportDateTime $values['Start'] -DeviceTimeZone $DeviceTimeZone))}
            $used['Start']=$true
        }
        if($values.Contains('End')){$pieces.Add('Ends '+(Format-ThoroughReportDateTime $values['End'] -DeviceTimeZone $DeviceTimeZone));$used['End']=$true}
        if($values.Contains('Repetition Interval')){
            $pieces.Add('Repeats every '+(Format-ThoroughReportDuration $values['Repetition Interval']))
            $used['Repetition Interval']=$true
            if($values.Contains('Repetition Duration')){$pieces[$pieces.Count-1]+=' for '+(Format-ThoroughReportDuration $values['Repetition Duration']);$used['Repetition Duration']=$true}
        }
        foreach($key in $values.Keys){
            if($used.ContainsKey($key)){continue}
            $label=[regex]::Replace([string]$key,'(?<=[a-z])(?=[A-Z])',' ')
            $label=$label.Substring(0,1).ToUpperInvariant()+$label.Substring(1).ToLowerInvariant()
            $detail=if($key -in @('Delay','RandomDelay','Repetition Duration')){Format-ThoroughReportDuration $values[$key]}else{$values[$key]}
            $pieces.Add($label+': '+$detail)
        }
        foreach($flag in $flags){$pieces.Add($flag)}
        $results.Add(($pieces -join (' '+[char]183+' ')))
    }
    $results -join ' | '
}

function Format-ReportState {
    param ([string]$Item, [string]$Html)
    if($Item -eq 'Nmap Diagnostic Tool' -and $Html -match '^<div'){
        $values=Get-ThoroughReportHighlightFields $Html
        $fields=[ordered]@{}
        if($values.ContainsKey('Tool State')){$fields['Tool State']=$values['Tool State']}
        elseif($values.ContainsKey('Installed')){$fields['Tool State']=if($values['Installed'] -eq 'Yes'){'Installed'}else{$values['Installed']}}
        if($values.ContainsKey('Version')){$fields['Version']=$values['Version']}
        if($fields.Count){return ConvertTo-ReportDefinitionHtml $fields}
    }
    if($Item -eq 'Kiosk Launch Task'){return Get-KioskLaunchTaskReportState $Html}
    if($Item -in @('Payment Service Restart Task','PaymentService Restart Task')){
        # Project collected task data into the six requested report fields.
        # The original observation, requirements and verification result stay intact.
        $parts=New-Object 'Collections.Generic.List[string]'
        $blocks=@([regex]::Split($Html,'(?=<div class="config-item-title">)') | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
        if(-not $blocks.Count){$blocks=@('')}
        foreach($block in $blocks){
            $values=Get-ThoroughReportHighlightFields $block
            $title=[regex]::Match($block,'<div class="config-item-title">\[Task \d+\]</div>')
            if($title.Success){$parts.Add($title.Value)}
            $missing=$values.ContainsKey('Task') -and $values['Task'] -eq 'Not found'
            $unknown='Not verified. Please check manually.'
            $name=if($values.ContainsKey('Task Name') -and -not [string]::IsNullOrWhiteSpace($values['Task Name'])){$values['Task Name']}elseif($missing){'Not found'}else{$unknown}
            $enabled=if($values.ContainsKey('Task Status')){[string]$values['Task Status']}elseif($values.ContainsKey('Task Enabled')){[string]$values['Task Enabled']}else{''}
            $taskStatus=switch($enabled){'Yes'{'Active'};'Enable'{'Active'};'Active'{'Active'};'No'{'Disabled'};'Disable'{'Disabled'};'Disabled'{'Disabled'};default{$unknown}}
            $target=if(-not $missing -and $values.ContainsKey('Restart Target')){$values['Restart Target']}elseif(-not $missing -and $values.ContainsKey('Target')){$values['Target']}else{$unknown}
            $trigger=if($values.ContainsKey('Trigger Details')){$values['Trigger Details']}elseif($values.ContainsKey('Trigger Time')){$values['Trigger Time']}elseif($missing){'Not configured'}else{$unknown}
            $historyFallback=if($missing){'Not recorded'}elseif($values.ContainsKey('Run History') -or -not $values.ContainsKey('Task Name')){$unknown}else{'Not recorded'}
            $fields=[ordered]@{
                'Task Name'=$name
                'Task Status'=$taskStatus
                'Target'=$target
                'Trigger Time'=$trigger
                'Last Run'=$(if($values.ContainsKey('Last Run')){$values['Last Run']}else{$historyFallback})
                'Next Run'=$(if($values.ContainsKey('Next Run')){$values['Next Run']}else{$historyFallback})
            }
            $fields['Trigger Time']=Format-ThoroughReportTriggerDetails $fields['Trigger Time']
            foreach($historyLabel in @('Last Run','Next Run')){$fields[$historyLabel]=Format-ThoroughReportDateTime -Value $fields[$historyLabel]}
            $parts.Add((ConvertTo-ReportDefinitionHtml $fields))
        }
        return ($parts -join '')
    }
    # Existing structured states are already escaped at their data boundary.
    if ($Html -match '^<div') { return $Html }
    $labels = @{
        'PrintService Operational Log' = 'Log State'
        'Inbound TCP 5009 Rule' = 'Rule'
        'Nmap Diagnostic Tool' = 'Tool State'
        'Kiosk Auto-Login' = 'Auto-Login'
    }
    if ($Item -match '^Inbound TCP [0-9-]+ Rules?$') { $labels[$Item] = 'Rule' }
    $lines = foreach ($line in ($Html -split '<br\s*/?>')) {
        if ($line -match '^([^:<>]+): (.*)$') {
            '<div><span class="kv-label">{0}:</span> {1}</div>' -f $Matches[1], $Matches[2]
        } elseif ($labels.ContainsKey($Item)) {
            '<div><span class="kv-label">{0}:</span> {1}</div>' -f $labels[$Item], $line
        } else { '<div>{0}</div>' -f $line }
    }
    '<div class="kv-block">' + ($lines -join '') + '</div>'
}

function Convert-ReportHtmlToTerminalText {
    param ([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '-' }
    $text = $Html -replace '(?i)<br\s*/?>', '; '
    $text = $text -replace '(?i)</div>\s*<div[^>]*>', '; '
    $text = $text -replace '(?i)</?(div|span|code)[^>]*>', ''
    $text = $text -replace '<[^>]+>', ''
    $text = [Net.WebUtility]::HtmlDecode($text)
    return (($text -replace '\s*;\s*', '; ') -replace '\s+', ' ').Trim(' ', ';')
}

function Get-ThoroughAppSettingsReportRows {
    param ($Source)
    $config = $Source.ConfigurationSnapshot
    $provider = ([string](Get-ThoroughPaymentConfigValue $config 'PaymentService')).Trim().ToUpperInvariant()
    $providerValue = Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $config 'PaymentService')
    $service = if ($Source.PSObject.Properties['ConfigurationServiceName']) { $Source.ConfigurationServiceName } else { 'Not recorded' }
    $path = if ($Source.PSObject.Properties['ConfigurationPath']) { $Source.ConfigurationPath } else { 'Not recorded' }
    $sourceExpected = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Directory'='Running Payment Service'; 'File'='appsettings.json' })
    $sourceObserved = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Payment Service'=$service; 'File Path'=$path })
    New-ThoroughAppSettingsGroupRow $Source 'AppSettings file' $sourceExpected $sourceObserved $false
    $providerExpected = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'PaymentService'='SIX, NETS / NEXIDE, or PRINT' })
    $providerObserved = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'PaymentService'=$providerValue })
    New-ThoroughAppSettingsGroupRow $Source 'PaymentService' $providerExpected $providerObserved ($provider -notin @('SIX','NETS','NEXIDE','PRINT'))

    # Payment terminal and payout sections follow the selected payment provider.
    # PRINT omits payment terminals and payout schedules; print and endpoint groups remain.
    if ($provider -in @('SIX','NETS','NEXIDE')) {
        $collection = if ($provider -eq 'SIX') { 'SixTerminals' } else { 'NetsTerminals' }
        $fields = if ($provider -eq 'SIX') { @('KioskId','TerminalId','Currency','LogDirectory','IsDeferredInitiation') } else { @('PosId','KioskId','TerminalIPAddress','TerminalId','Currency','Language','IsSetupEnabled') }
        $paymentConfig = Get-ThoroughPaymentConfigValue $config 'PaymentConfiguration'
        $terminals = @(Get-ThoroughPaymentConfigValue $paymentConfig $collection)
        $expectedValues = [ordered]@{}
        foreach ($field in $fields) { $expectedValues[$field] = '' }
        $expectedHtml = '<div class="config-group-title">[' + $collection + ']</div>' + (ConvertTo-ReportDefinitionHtml $expectedValues)
        $actualParts = [Collections.Generic.List[string]]::new()
        $actualParts.Add('<div class="config-group-title">[' + $collection + ']</div>')
        $missing = $false
        if ($terminals.Count -eq 0 -or $null -eq $terminals[0]) { $terminals = @($null); $missing = $true }
        for ($index=0; $index -lt $terminals.Count; $index++) {
            $actualValues = [ordered]@{}
            foreach ($field in $fields) {
                $value = Get-ThoroughPaymentConfigValue $terminals[$index] $field
                if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0 -and $field -ne 'TerminalId')) { $missing=$true }
                $actualValues[$field] = Format-ThoroughPaymentAuditValue $value
            }
            if ($terminals.Count -gt 1) { $actualParts.Add('<div class="config-item-title">[Terminal ' + ($index+1) + ']</div>') }
            $actualParts.Add((ConvertTo-ReportDefinitionHtml $actualValues))
        }
        New-ThoroughAppSettingsGroupRow $Source 'PaymentConfiguration' $expectedHtml ($actualParts -join '') $missing
    }

    $scheduleConfig = Get-ThoroughPaymentConfigValue $config 'ScheduleConfiguration'
    $nested = Get-ThoroughPaymentConfigValue $scheduleConfig 'Schedules'
    $schedules = if ($null -ne $nested) { @($nested) } else { @($scheduleConfig) }
    $kitchenSchedules = @($schedules | Where-Object { [string](Get-ThoroughPaymentConfigValue $_ 'Provider') -ieq 'KitchenTicketPrint' })
    $scheduleExpected = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Provider'='KitchenTicketPrint'; 'BranchUUID'=''; 'IsKioskPrintingEnabled'=''; 'IsEnabled'='' })
    $missing=$false
    if ($kitchenSchedules.Count -eq 0) { $kitchenSchedules=@($null); $missing=$true }
    $scheduleParts = [Collections.Generic.List[string]]::new()
    for ($index=0; $index -lt $kitchenSchedules.Count; $index++) {
        $actualValues=[ordered]@{}
        foreach ($field in @('Provider','BranchUUID','IsKioskPrintingEnabled','IsEnabled')) {
            $value = Get-ThoroughPaymentConfigValue $kitchenSchedules[$index] $field
            if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0 -and $field -ne 'TerminalId')) { $missing=$true }
            $actualValues[$field] = Format-ThoroughPaymentAuditValue $value
        }
        if ($kitchenSchedules.Count -gt 1) { $scheduleParts.Add('<div class="config-item-title">Kitchen print schedule ' + ($index+1) + '</div>') }
        $scheduleParts.Add((ConvertTo-ReportDefinitionHtml $actualValues))
    }
    New-ThoroughAppSettingsGroupRow $Source 'ScheduleConfiguration' $scheduleExpected ($scheduleParts -join '') $missing

    if($provider -in @('SIX','NETS','NEXIDE')){
        $payoutSchedules=@(Get-ThoroughPayoutSchedules -Schedules $schedules -Provider $provider)
        $payoutExpected=ConvertTo-ReportDefinitionHtml ([ordered]@{'Provider'='SIX, NETS, NEXIDE';'IsEnabled'='False / True'})
        $payoutParts=[Collections.Generic.List[string]]::new()
        $missing=$false
        if($payoutSchedules.Count -eq 0){$payoutSchedules=@($null);$missing=$true}
        for($index=0;$index -lt $payoutSchedules.Count;$index++){
            $actualValues=[ordered]@{}
            foreach($field in @('Provider','IsEnabled')){
                $value=Get-ThoroughPaymentConfigValue $payoutSchedules[$index] $field
                if($null -eq $value -or ($value -is [string] -and $value.Length -eq 0)){$missing=$true}
                $actualValues[$field]=Format-ThoroughPaymentAuditValue $value
            }
            $terminalLabel=if($provider -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'}
            $payoutParts.Add('<div class="config-item-title">'+$terminalLabel+'</div>')
            $payoutParts.Add((ConvertTo-ReportDefinitionHtml $actualValues))
        }
        New-ThoroughAppSettingsGroupRow $Source 'Payout Scheduler' $payoutExpected ($payoutParts -join '') $missing
    }

    $printConfig=Get-ThoroughPaymentConfigValue $config 'Print'
    $printRequirements=[ordered]@{ 'PrinterName'=''; 'KioskPrinterName'='' }
    $printValues=[ordered]@{}; $missing=$false
    foreach ($field in @('PrinterName','KioskPrinterName')) {
        $value=Get-ThoroughPaymentConfigValue $printConfig $field
        if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0 -and $field -ne 'TerminalId')) { $missing=$true }
        $printValues[$field]=Format-ThoroughPaymentAuditValue $value
    }
    if($Source.PSObject.Properties['ConfigurationServiceVersion'] -and (Test-ThoroughPaymentServiceV13 ([string]$Source.ConfigurationServiceVersion))){
        $value=Get-ThoroughPaymentConfigValue $printConfig 'KioskPrinterDisableChineseMode'
        $modeBoolean=$false
        if([bool]::TryParse([string]$value,[ref]$modeBoolean)){$value=$modeBoolean}
        $printRequirements['KioskPrinterDisableChineseMode']='True'
        $printValues['KioskPrinterDisableChineseMode']=Format-ThoroughPaymentAuditValue $value
        if(([string]$value).Trim() -ine 'true'){$missing=$true}
    }
    $printExpected=ConvertTo-ReportDefinitionHtml $printRequirements
    $printRow=New-ThoroughAppSettingsGroupRow $Source 'Print' $printExpected (ConvertTo-ReportDefinitionHtml $printValues) $missing
    if($printRequirements.Contains('KioskPrinterDisableChineseMode') -and $printValues['KioskPrinterDisableChineseMode'] -ine 'True'){
        $printRow.ActionTaken='Disable Chinese Mode requires True for Payment Service v13; this setting is read-only. Review printer values manually.'
    }
    if($Source.PSObject.Properties['PrinterInventory']){$printRow | Add-Member -NotePropertyName PrinterInventory -NotePropertyValue @($Source.PrinterInventory)}
    $printRow
    foreach ($endpoint in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')) {
        $value=Get-ThoroughPaymentConfigValue $config $endpoint
        $requiredEndpoints=Get-ThoroughServiceEndpointRequirements
        $expectedHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{ $endpoint=$requiredEndpoints[$endpoint] })
        $actualHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{ $endpoint=(Format-ThoroughPaymentAuditValue $value) })
        $endpointRow=New-ThoroughAppSettingsGroupRow $Source $endpoint $expectedHtml $actualHtml (([string]$value).Trim() -cne $requiredEndpoints[$endpoint])
        if($endpointRow.Status -eq 'Fail'){$endpointRow.ActionTaken='Service URL does not match the required URL.'}
        if($Source.PSObject.Properties['EndpointRepairError'] -and $endpointRow.Status -eq 'Fail'){$endpointRow.ActionTaken=[Net.WebUtility]::HtmlEncode([string]$Source.EndpointRepairError)}
        if($Source.PSObject.Properties['EndpointRepair'] -and $Source.EndpointRepair.Changed -and $Source.EndpointRepair.ChangedKeys -contains $endpoint -and $endpointRow.Status -eq 'Pass'){
            $endpointRow.Status='Remediated'
            $endpointRow.ActionTaken=[Net.WebUtility]::HtmlEncode('Updated AppSettings service URL; file readback verified. Backup: '+$Source.EndpointRepair.BackupPath+'. Payment Service runtime activation was not verified.')
        }
        $endpointRow
    }
}

function New-ThoroughPrinterReportRow {
    param ([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][object[]]$Rows)
    $requirements=ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Printer Name'='Brand/Model'; 'Printer status'='Active / Idle'; 'Keep printed documents'='Enabled' })
    $findingParts=[Collections.Generic.List[string]]::new()
    $commands=[Collections.Generic.List[string]]::new()
    $seenCommands=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actions=[Collections.Generic.List[string]]::new()
    $multiple=$Rows.Count -gt 1
    $verified=$true
    $printerNumber=0
    foreach ($printer in $Rows) {
        $detected=$printer.ItemSub -eq 'Type: Receipt / POS Printer' -and -not [string]::IsNullOrWhiteSpace([string]$printer.ItemTitle)
        $name=if ($detected) { [string]$printer.ItemTitle } else { 'No printer detected' }
        $blockTitle=if ($detected) { $printerNumber++; 'Printer '+$printerNumber } else { 'No printer detected' }
        $heading=if ($multiple) { '<div class="config-item-title">['+$blockTitle+']</div>' } else { '' }
        $state=[string]$printer.FoundStateHtml
        if ([string]::IsNullOrWhiteSpace($state)) { $state='Not verified. Please check manually.'; $verified=$false }
        $findingParts.Add($heading+$state)
        if (-not $detected -or $printer.Status -ne 'Pass') { $verified=$false }
        foreach ($command in [regex]::Matches([string]$printer.Shortcut,'(?is)<code\b[^>]*>(.*?)</code>')) {
            $text=[Net.WebUtility]::HtmlDecode($command.Groups[1].Value)
            if (-not [string]::IsNullOrWhiteSpace($text) -and $seenCommands.Add($text)) { $commands.Add($text) }
        }
        $actions.Add(([Net.WebUtility]::HtmlEncode($name)+': '+[string]$printer.ActionTaken))
    }
    [pscustomobject]@{
        SectionNumber=$Rows[0].SectionNumber; SectionTitle=$Rows[0].SectionTitle
        ItemTitle='Printer'; ItemSub='Type: Printer Group'
        Shortcut=(New-ReportCommand -Commands $commands.ToArray())
        ExpectedHtml=$requirements
        FoundStateHtml=('<div class="printer-stack">'+($findingParts -join '<hr>')+'</div>')
        Status=$(if ($verified) { 'Pass' } else { 'Fail' })
        ActionTaken=($actions -join '; ')
    }
}

function New-ThoroughFirewallReportRow {
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][object[]]$Rows)
    $required=New-Object 'Collections.Generic.List[int]'
    $seenRequired=New-Object 'Collections.Generic.HashSet[int]'
    $observed=New-Object 'Collections.Generic.List[object]'
    $missing=New-Object 'Collections.Generic.List[int]'
    $unknown=New-Object 'Collections.Generic.List[int]'
    $notes=New-Object 'Collections.Generic.List[string]'
    $verified=$true
    foreach($row in $Rows){
        $portText=if($row.PSObject.Properties['FirewallPort']){[string]$row.FirewallPort}else{([string]$row.ItemTitle -replace '^Inbound TCP\s+|\s+Rules?$','')}
        $ports=New-Object 'Collections.Generic.List[int]'
        foreach($token in ($portText -split ',')){
            if($token -match '^\s*(\d+)\s*-\s*(\d+)\s*$'){
                $first=[int]$Matches[1];$last=[int]$Matches[2]
                if($first -ge 1 -and $last -le 65535 -and $last -ge $first){for($port=$first;$port -le $last;$port++){$ports.Add($port)}}
            }elseif($token -match '^\s*\d+\s*$'){$port=[int]$token;if($port -ge 1 -and $port -le 65535){$ports.Add($port)}}
        }
        $readKnown=$row.PSObject.Properties['FirewallReadVerified'] -and [bool]$row.FirewallReadVerified
        $snapshots=if($row.PSObject.Properties['FirewallObservations']){@($row.FirewallObservations | Where-Object {$null -ne $_})}else{@()}
        foreach($snapshot in $snapshots){$observed.Add($snapshot)}
        foreach($port in $ports){
            if(-not $seenRequired.Add($port)){continue}
            $required.Add($port)
            if(-not $readKnown -or ($row.Status -in @('Pass','Online','Remediated') -and $snapshots.Count -eq 0)){$unknown.Add($port);$verified=$false;continue}
            $covered=@($snapshots | Where-Object {
                [string]$_.Direction -eq 'Inbound' -and [string]$_.Protocol -eq 'TCP' -and [string]$_.Enabled -eq 'Yes' -and [string]$_.Action -eq 'Allow' -and
                (Test-FirewallPortMatch -Ports $_.Ports -Port $port)
            }).Count -gt 0
            if(-not $covered){$missing.Add($port);$verified=$false}
            if($row.Status -notin @('Pass','Online','Remediated')){$verified=$false}
        }
        if($ports.Count -eq 0){$verified=$false}
        $notes.Add($portText+': '+[string]$row.ActionTaken)
    }
    if($required.Count -eq 0){$verified=$false}
    $fields=[ordered]@{}
    foreach($field in @('Direction','Protocol','Ports','Enabled','Action')){
        $values=New-Object 'Collections.Generic.List[string]'
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($snapshot in $observed){
            foreach($entry in @($snapshot.$field)){
                foreach($value in $(if($field -eq 'Ports'){([string]$entry -split ',')}else{@([string]$entry)})){
                    $value=$value.Trim()
                    if($value -and $seen.Add($value)){$values.Add($value)}
                }
            }
        }
        $fields[$field]=if($values.Count){$values -join ', '}else{'Not verified. Please check manually.'}
        if($values.Count -eq 0){$verified=$false;if($missing.Count -gt 0 -and $unknown.Count -eq 0){$fields[$field]='None'}}
    }
    if($fields['Ports'] -like 'Not verified*' -and $missing.Count -gt 0 -and $unknown.Count -eq 0){$fields['Ports']='None'}
    $fields['Ports']=$fields['Ports'].Replace('Any','All ports (Any)').Replace('*','All ports (Any)')
    if($missing.Count){$fields['Missing Allow Rules (Ports)']=$missing -join ', '}
    if($unknown.Count){$fields['Unverified Ports']='Not verified: '+($unknown -join ', ')+'. Please check manually.'}
    [pscustomobject]@{
        SectionNumber=$Rows[0].SectionNumber;SectionTitle=$Rows[0].SectionTitle
        ItemTitle='Firewall Inbound Port';ItemSub='Type: Firewall Rule Group'
        Shortcut=(New-ReportCommand @('wf.msc'))
        ExpectedHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{Direction='Inbound';Protocol='TCP';Ports=($required -join ', ');Enabled='Yes';Action='Allow'}))
        FoundStateHtml=(ConvertTo-ReportDefinitionHtml $fields)
        Status=$(if($verified){'Pass'}else{'Fail'});ActionTaken=($notes -join '; ')
    }
}

function New-ThoroughLegacyServiceReportRow {
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][object[]]$Rows)
    # Report projection only: preserve each service's observations and recorded actions.
    $findings=New-Object 'Collections.Generic.List[string]'
    $commands=New-Object 'Collections.Generic.List[string]'
    $seenCommands=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $verified=$true
    foreach($service in $Rows){
        $name=[regex]::Replace([string]$service.ItemTitle,'\s+\(Legacy\)$','')
        if([string]::IsNullOrWhiteSpace($name)){$name='Not verified';$verified=$false}
        $state=[string]$service.FoundStateHtml
        if([string]::IsNullOrWhiteSpace($state)){$state='Not verified. Please check manually.';$verified=$false}
        $headingName=[Net.WebUtility]::HtmlEncode($name).Replace('[','&#91;').Replace(']','&#93;')
        $findings.Add(('<div class="config-item-title">'+$headingName+'</div>')+(Format-ReportState $service.ItemTitle $state))
        if($service.Status -notin @('Pass','Online','Remediated','Offline')){$verified=$false}
        foreach($command in [regex]::Matches([string]$service.Shortcut,'(?is)<code\b[^>]*>(.*?)</code>')){
            $text=[Net.WebUtility]::HtmlDecode($command.Groups[1].Value)
            if(-not [string]::IsNullOrWhiteSpace($text) -and $seenCommands.Add($text)){$commands.Add($text)}
        }
    }
    [pscustomobject]@{
        SectionNumber=$Rows[0].SectionNumber;SectionTitle=$Rows[0].SectionTitle
        ItemTitle='Legacy Payment Services';ItemSub='Type: Old Payment Service'
        Shortcut=(New-ReportCommand -Commands $commands.ToArray())
        ExpectedHtml=(Get-ReportRequirement -Row $Rows[0])
        FoundStateHtml=('<div class="legacy-service-stack">'+($findings -join '')+'</div>')
        Status=$(if($verified){'Pass'}else{'Fail'})
        ActionTaken=($Rows.ActionTaken -join '; ')
        LegacyServiceRows=@($Rows)
    }
}

function Get-ThoroughReportDisplayRows {
    param ([object[]]$Rows)
    $printerSections=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $firewallSections=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $legacySections=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        # Retire the removed rename check from fresh views of saved observations.
        if($row.ItemTitle -eq 'Windows Computer Name'){continue}
        if ($row.ItemSub -in @('Type: Receipt / POS Printer','Type: Receipt / Hardware')) {
            $sectionKey=[string]$row.SectionNumber+'|'+[string]$row.SectionTitle
            if ($printerSections.Add($sectionKey)) {
                $printers=@($Rows | Where-Object { $_.SectionNumber -eq $row.SectionNumber -and $_.SectionTitle -eq $row.SectionTitle -and $_.ItemSub -in @('Type: Receipt / POS Printer','Type: Receipt / Hardware') })
                New-ThoroughPrinterReportRow -Rows $printers
            }
        } elseif ($row.ItemTitle -match '^Inbound TCP [0-9,-]+ Rules?$') {
            $sectionKey=[string]$row.SectionNumber+'|'+[string]$row.SectionTitle
            if($firewallSections.Add($sectionKey)) {
                $firewalls=@($Rows | Where-Object { $_.SectionNumber -eq $row.SectionNumber -and $_.SectionTitle -eq $row.SectionTitle -and $_.ItemTitle -match '^Inbound TCP [0-9,-]+ Rules?$' })
                New-ThoroughFirewallReportRow -Rows $firewalls
            }
        } elseif ($row.ItemSub -eq 'Type: Old Payment Service' -and -not $row.PSObject.Properties['LegacyServiceRows']) {
            $sectionKey=[string]$row.SectionNumber+'|'+[string]$row.SectionTitle
            if($legacySections.Add($sectionKey)){
                $services=@($Rows | Where-Object { $_.SectionNumber -eq $row.SectionNumber -and $_.SectionTitle -eq $row.SectionTitle -and $_.ItemSub -eq 'Type: Old Payment Service' -and -not $_.PSObject.Properties['LegacyServiceRows'] })
                New-ThoroughLegacyServiceReportRow -Rows $services
            }
        } elseif ($row.PSObject.Properties['ConfigurationSnapshot'] -and $null -ne $row.ConfigurationSnapshot) {
            Get-ThoroughAppSettingsReportRows -Source $row
        } else { $row }
    }
}

function ConvertTo-ReportDefinitionHtml {
    param ([Collections.IDictionary]$Values)
    $items = foreach ($key in $Values.Keys) {
        '<div><span class="kv-label">{0}:</span> {1}</div>' -f ([Net.WebUtility]::HtmlEncode([string]$key)), ([Net.WebUtility]::HtmlEncode([string]$Values[$key]))
    }
    '<div class="kv-block">' + ($items -join '') + '</div>'
}

function Get-AccountReportView {
    param ($Row)
    if ($Row.ItemTitle -notmatch '^(KIOSK Account|Local Account:|Administrative Account|SELISE Local Accounts)') { return $null }
    $administrative=$Row.ItemTitle -match '^Administrative Account'
    $expectedName=if ($administrative) { 'Admin, Administrator' } else { 'SELISE or SELISE-KIOSK' }
    $expectedPrivilege='Standard or Administrator'
    $hasKioskPasswordRequirement=$false
    $raw=[string]$Row.FoundStateHtml
    $missing=$raw -match '(?is)Account Status:</span>\s*Missing\s*</div>' -or $raw.Trim() -match '^Account Missing(?:\. Please create manually\.)?$'
    $identityParts=[Collections.Generic.List[string]]::new()
    $accountNames=[Collections.Generic.List[string]]::new()
    $findingParts=[Collections.Generic.List[string]]::new()
    $records=[Collections.Generic.List[object]]::new()
    $names=@([regex]::Matches($raw,'(?is)<div><span class=["'']kv-label["'']>Account Name:</span>\s*(?<Value>.*?)</div>'))
    if (-not $missing -and $names.Count -gt 0) {
        for ($index=0; $index -lt $names.Count; $index++) {
            $name=[Net.WebUtility]::HtmlDecode(($names[$index].Groups['Value'].Value -replace '<[^>]+>','').Trim())
            $end=if ($index+1 -lt $names.Count) { $names[$index+1].Index } else { $raw.Length }
            $chunk=$raw.Substring($names[$index].Index,$end-$names[$index].Index)
            $privilegeMatch=[regex]::Match($chunk,'(?is)<div><span class=["'']kv-label["'']>Account Privilege:</span>\s*(?<Value>.*?)</div>')
            $privilege=if ($privilegeMatch.Success) { [Net.WebUtility]::HtmlDecode(($privilegeMatch.Groups['Value'].Value -replace '<[^>]+>','').Trim()) } else { 'Not verified' }
            $privilege=switch($privilege){
                'Local Administrator' { 'Administrator' }
                'Standard Local User' { 'Standard' }
                'Standard User' { 'Standard' }
                'Local user' { 'Standard' }
                default { $privilege }
            }
            $identity=[ordered]@{ 'Account Name'=$name; 'Account Privilege'=$privilege }
            $accountNames.Add($name)
            $stateMatch=[regex]::Match($chunk,'(?is)<div><span class=["'']kv-label["'']>Account Status:</span>\s*(?<Value>.*?)</div>')
            $accountStatus=if ($stateMatch.Success) { [Net.WebUtility]::HtmlDecode(($stateMatch.Groups['Value'].Value -replace '<[^>]+>','').Trim()) } else { 'Not verified' }
            $accountStatus=switch ($accountStatus) { 'Enabled' { 'Active' }; 'Active' { 'Active' }; 'Disabled' { 'Disabled' }; default { 'Not verified' } }
            $findings=[ordered]@{ 'Account Name'=$name; 'Account Privilege'=$privilege; 'Account Status'=$accountStatus }
            $administrativeAccount=$administrative -or $privilege -eq 'Administrator' -or $name -in @('Admin','Administrator')
            $findingLabels=@('Password Never Expires')
            if(-not $administrativeAccount){$findingLabels+='User Cannot Change Password';$hasKioskPasswordRequirement=$true}
            foreach ($label in $findingLabels) {
                $match=[regex]::Match($chunk,'(?is)<div><span class=["'']kv-label["'']>'+[regex]::Escape($label)+':</span>\s*(?<Value>.*?)</div>')
                $findings[$label]=if ($match.Success) { [Net.WebUtility]::HtmlDecode(($match.Groups['Value'].Value -replace '<[^>]+>','').Trim()) } else { 'Not verified' }
            }
            $number=if ($names.Count -gt 1) { '<div class="config-item-title">[Account '+($index+1)+']</div>' } else { '' }
            $identityParts.Add($number+(ConvertTo-ReportDefinitionHtml $identity))
            $findingBody=ConvertTo-ReportDefinitionHtml $findings
            $findingParts.Add($number+$findingBody)
            $records.Add([pscustomobject]@{AccountName=$name;HeadingHtml=$number;FindingsHtml=$findingBody;AdministrativePolicy=[bool]$administrativeAccount})
        }
    } else {
        $identity=[ordered]@{ 'Account Name'=$expectedName; 'Account Privilege'=$expectedPrivilege }
        $identityParts.Add((ConvertTo-ReportDefinitionHtml $identity))
        $findingParts.Add($(if ($missing) { 'Account Missing. Please create manually.' } elseif ($raw -match '^Not verified\.') { $raw } else { 'Account not verified. Please check manually.' }))
    }
    if($administrative -and $accountNames.Count -gt 0 -and $Row.PSObject.Properties['AccountResults']){
        $known=@($accountNames|Where-Object {$identity=$_;@($Row.AccountResults|Where-Object AccountName -IEQ $identity).Count -eq 1})
        if($known.Count -eq $accountNames.Count){$expectedName=$known -join ', '}
    }
    $expected=[ordered]@{
        'Account Name'=$(if (-not $administrative -and $accountNames.Count) { $accountNames -join ', ' } else { $expectedName })
        'Account Privilege'=$expectedPrivilege
        'Account Status'='Active / Disabled'
        'Password Never Expires'='Enabled'
        'User Cannot Change Password'='Enabled'
    }
    if($administrative -or ($accountNames.Count -gt 0 -and -not $hasKioskPasswordRequirement)){$expected.Remove('User Cannot Change Password')}
    [pscustomobject]@{ IdentityHtml=($identityParts -join '<hr>'); ExpectedHtml=(ConvertTo-ReportDefinitionHtml $expected); FindingsHtml=($findingParts -join '<hr>'); Records=$records.ToArray() }
}

function Get-ThoroughFinalReportRows {
    param([object[]]$Rows,[string]$ConfirmedKioskUser,[bool]$AfterApply)
    # Final-only projections use recorded evidence and never mutate source rows.
    foreach($row in @(Get-ThoroughReportDisplayRows -Rows $Rows)){
        if($row.ItemTitle -eq 'Printer' -and $row.SectionTitle -ne 'AppSettings Check'){Get-ThoroughFinalPrinterRow -Row $row -AfterApply $AfterApply}
        elseif($row.ItemTitle -match '^Administrative Account'){Get-ThoroughFinalAdministrativeAccountRow -Row $row -AfterApply $AfterApply}
        else{Get-ThoroughFinalKioskAccountRow -Row $row -ConfirmedUser $ConfirmedKioskUser}
    }
}

function Get-ThoroughReportHighlightFields {
    param ([string]$Html)
    $values=@{}
    foreach($field in [regex]::Matches($Html,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>[^<]*)')){
        $label=[Net.WebUtility]::HtmlDecode($field.Groups['Label'].Value).Trim()
        $values[$label]=[Net.WebUtility]::HtmlDecode($field.Groups['Value'].Value).Trim()
    }
    return $values
}

function Get-ThoroughReportCollectedValueState {
    param($Row,[string]$Label,[string]$Value,[Collections.IDictionary]$Requirements)
    # Classify recorded values only; do not query the device or change check results.
    if($Row.Status -eq 'Bypass'){return ''}
    if($Row.ItemTitle -eq 'Kiosk Launch Task' -and $Label -in @('Task Name','Trigger Time','Last Run','Next Run')){
        if($Value -match '(?i)not verified|unknown|unavailable'){return 'unverified'}
        if($Label -in @('Last Run','Next Run') -and $Value -eq 'Not recorded'){return 'collected'}
        if($Value -match '^(?:Missing|Not found|Not configured)$' -or -not $Value){return 'missing'}
        return 'collected'
    }
    if($Row.SectionTitle -eq 'AppSettings Check'){
        $actual=([string]$Value).Trim()
        if($Row.ItemTitle -in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl') -and $Requirements -and $Requirements.Contains($Label) -and $Requirements[$Label]){
            if($actual -match '(?i)\bnot\s+verified\b|^(?:unknown|unavailable)(?:[.\s(]|$)'){return 'unverified'}
            if($actual -ceq [string]$Requirements[$Label]){return 'endpoint-match'}
            return 'endpoint-mismatch'
        }
        # AppSettings colors describe collected data, including False and zero.
        if($actual -match '(?i)\bnot\s+verified\b|\bmanual\s+action\s+required\b|^(?:unknown|unavailable)(?:[.\s(]|$)|\bnot available\b'){return 'unverified'}
        if(-not $actual -or $actual -eq '(empty)' -or $actual -match '(?i)^(?:Missing|Not found|Not detected|No printer detected|Not recorded|Not configured|Not readable)(?:[.!](?:\s.*)?)?$'){return 'unverified'}
        if($Row.ItemTitle -in @('Print','Printer') -and $Label -in @('KioskPrinterDisableChineseMode','Disable Chinese Mode') -and $Requirements -and $Requirements.Contains($Label)){
            if($actual -ieq 'true'){return 'required-match'}
            return 'required-mismatch'
        }
        if($Row.ItemTitle -in @('Print','Printer') -and $Label -in @('PrinterName','Kitchen Printer','KioskPrinterName','Kiosk/POS Printer')){
            $connection=if($Label -in @('KioskPrinterName','Kiosk/POS Printer')){'USB'}else{'IP'}
            if($Row.PSObject.Properties['PrinterInventory']){
                $matching=@($Row.PrinterInventory | Where-Object { $_ -and [string]$_.Name -ieq $actual })
                if($matching.Count -eq 1 -and $matching[0].ConnectionType -eq $connection){return 'printer-match'}
            }
            return 'informational'
        }
        return 'collected'
    }
    $targeted=($Label -eq 'Printer Name' -and $Requirements -and $Requirements.Contains('Printer Name') -and $Requirements['Printer Name'] -eq 'Brand/Model') -or
        ($Label -eq 'Launcher Path' -and $Requirements -and $Requirements.Contains('Launch Script') -and $Requirements['Launch Script'] -eq 'Available') -or
        ($Label -eq 'Location' -and $Requirements -and $Requirements.Contains('Location') -and $Requirements['Location'] -eq 'Path') -or
        ($Label -eq 'Version' -and $Requirements -and $Requirements.Contains('Version') -and $Requirements['Version'] -eq '0.0.0.0') -or
        ($Row.ItemTitle -in @('Payment Service Restart Task','PaymentService Restart Task') -and $Label -in @('Task Name','Trigger Time','Last Run','Next Run'))
    if(-not $targeted){return ''}
    $actual=([string]$Value).Trim()
    if($actual -match '(?i)\bnot\s+verified\b|^(?:unknown|unavailable)(?:[.\s(]|$)'){return 'unverified'}
    if(-not $actual -or $actual -match '(?i)^(?:Missing|Not found|Not detected|No printer detected|Not recorded|Not configured|Not readable|No trigger configured)(?:[.!](?:\s.*)?)?$'){return 'missing'}
    'collected'
}

function Get-ThoroughReportFindingComparison {
    param ($Row,[string]$Label,[string]$Value,[Collections.IDictionary]$Requirements,[string]$KioskAccountName)
    # Compare reported values only. Never query a device or derive the row status.
    if($Row.Status -eq 'Bypass'){return ''}
    $presence=Get-ThoroughReportCollectedValueState -Row $Row -Label $Label -Value $Value -Requirements $Requirements
    if($presence -eq 'collected'){return 'match'}
    if($presence -eq 'printer-match'){return 'match'}
    if($presence -eq 'endpoint-match'){return 'match'}
    if($presence -eq 'endpoint-mismatch'){return 'mismatch'}
    if($presence -eq 'required-match'){return 'match'}
    if($presence -eq 'required-mismatch'){return 'mismatch'}
    if($presence -eq 'informational'){return ''}
    if($presence -eq 'missing'){return 'mismatch'}
    if($presence -eq 'unverified'){return ''}
    $actual=$Value.Trim()
    if($Label -ieq 'Host name' -and $Row.ItemTitle -in @('Kiosk Launch Architecture','Zabbix Agent 2')){
        $expectedHost=if($Row.PSObject.Properties['ExpectedHostName']){[string]$Row.ExpectedHostName}elseif($Requirements -and $Requirements.Contains($Label)){[string]$Requirements[$Label]}else{'Not detected'}
        if($Row.ItemTitle -eq 'Zabbix Agent 2'){
            if(-not (Test-ZabbixMonitoringHostname $expectedHost) -or -not (Test-ZabbixMonitoringHostname $actual)){return 'unverified'}
            if($actual -ceq $expectedHost){return 'match'}
        }else{
            if(-not (Test-ThoroughHostname $expectedHost) -or -not (Test-ThoroughHostname $actual)){return 'unverified'}
            if($actual -ieq $expectedHost){return 'match'}
        }
        return 'unverified'
    }
    if($actual -match '(?i)\bnot verified\b|^(?:not detected|not recorded|unknown|unavailable)(?:[.\s(]|$)'){return ''}
    if($Row.ItemTitle -in @('Payment Service Restart Task','PaymentService Restart Task')){


        if($Label -eq 'Target'){
            $sourceRequirements=if($Row.PSObject.Properties['ExpectedHtml']){Get-ThoroughReportHighlightFields ([string]$Row.ExpectedHtml)}else{@{}}
            $service=if($sourceRequirements.ContainsKey('Restart Target')){[string]$sourceRequirements['Restart Target']}elseif($sourceRequirements.ContainsKey('Target')){[string]$sourceRequirements['Target']}else{''}
            if([string]::IsNullOrWhiteSpace($service) -or $service -eq 'Payment Service' -or $service -match '(?i)not verified|not detected|unknown'){return ''}
            if($actual -ieq $service.Trim()){return 'match'}
            return 'mismatch'
        }
    }
    if($Row.ItemTitle -eq 'Kiosk Launch Task' -and $Label -eq 'Target'){
        if($actual -match '^(?:Missing|Not found|Not configured)$' -or -not $actual){return 'mismatch'}
        $source=if($Row.PSObject.Properties['ExpectedHtml']){Get-ThoroughReportHighlightFields $Row.ExpectedHtml}else{@{}}
        if($source.ContainsKey('Script Path') -and $source['Script Path'] -notmatch '^Not '){return $(if($actual -ieq $source['Script Path']){'match'}else{'mismatch'})}
        return ''
    }
    $referenceLabel=$Label
    if($Label -eq 'Service Name'){$referenceLabel='Expected Names'}
    elseif($Label -eq 'Tool State' -and $Row.ItemTitle -eq 'Nmap Diagnostic Tool'){$referenceLabel=if($Requirements.Contains('Tool State')){'Tool State'}else{'Installed'}}
    elseif($Label -eq 'Rebuild State' -and $Row.ItemTitle -like 'lodctr /R*'){$referenceLabel='Apply Fix'}

    if($Label -eq 'Rule' -and $Row.ItemTitle -match '^Inbound TCP '){$expected='Available'}
    elseif($Requirements.Contains($referenceLabel)){$expected=[string]$Requirements[$referenceLabel]}
    else{return ''}
    $expected=$expected.Trim()
    if($expected -match '(?i)\bnot verified\b|^(?:not detected|not recorded|unknown|unavailable)(?:[.\s(]|$)'){return ''}
    # Other placeholders without a collected-value rule remain informational.
    if([string]::IsNullOrWhiteSpace($expected) -or $expected -in @('Path','Launcher hostname','0.0.0.0')){return ''}
    if($Label -eq 'Default User' -and $expected -eq 'Kiosk account'){
        if([string]::IsNullOrWhiteSpace($KioskAccountName)){return ''}
        $expected=$KioskAccountName.Trim()
    }
    if($Label -eq 'Tool State' -and $expected -eq 'Yes'){$expected='Installed'}
    if($Label -eq 'Rebuild State'){$actual=$actual -replace ':\s*',' '}
    if($Label -eq 'Account Privilege' -and $expected -eq 'Standard or Administrator'){
        if($actual -in @('Standard','Standard Local User','Standard User','Local user','Administrator','Local Administrator')){return 'match'}
        return 'mismatch'
    }
    if($Label -eq 'Account Privilege' -and $expected -eq 'Local user' -and $actual -in @('Standard Local User','Standard User')){$actual='Local user'}
    if($expected -eq 'Configured' -and $Label -in @('Restaurant ID','Kiosk ID','Host name')){
        if([string]::IsNullOrWhiteSpace($actual) -or $actual -match '^(?:Not configured|Missing)(?:[.\s]|$)'){return 'mismatch'}
        return 'match'
    }
    if($expected -eq 'Readable' -and $Label -eq 'Version'){
        if([string]::IsNullOrWhiteSpace($actual) -or $actual -match '^(?:Missing|Not readable|Error)(?:[.\s]|$)'){return 'mismatch'}
        return 'match'
    }
    if($expected -eq 'Available' -and $Label -in @('Startup BAT','Desktop Shortcut')){
        if($actual -eq 'Available' -or ($Label -eq 'Startup BAT' -and $actual -eq 'LaunchKiosk.bat') -or ($Label -eq 'Desktop Shortcut' -and $actual -in @('Launch Kiosk.lnk','LaunchKiosk.lnk'))){return 'match'}
        return 'mismatch'
    }

    if($Label -eq 'Ports' -and $Row.ItemTitle -eq 'Firewall Inbound Port'){
        $actual=$actual.Replace('All ports (Any)','Any')
        foreach($portText in ($expected -split ',\s*')){
            $covered=$false
            foreach($token in ($actual -split ',\s*')){
                if($token -eq $portText){$covered=$true;break}
                if($token -match '^(\d+)\s*-\s*(\d+)$' -and [int]$portText -ge [int]$Matches[1] -and [int]$portText -le [int]$Matches[2]){$covered=$true;break}
            }
            if(-not $covered){return 'mismatch'}
        }
        return 'match'
    }
    if($actual -ieq $expected){return 'match'}
    if($Label -in @('Account Name','Account Status','Service Name','Printer status')){
        $options=@($expected -split '\s*(?:,|\bor\b|/)\s*' | Where-Object {$_})
        if($options -icontains $actual){return 'match'}
    }
    return 'mismatch'
}

function Format-ThoroughReportFindingHighlights {
    param ($Row,[string]$FindingsHtml,[string]$RequirementHtml,[string]$KioskAccountName)
    if($Row.Status -eq 'Bypass'){
        # A counter rebuild is intentionally not executed during Audit.
        if($Row.ItemTitle -eq 'lodctr /R Performance Counter'){
            return [regex]::Replace($FindingsHtml,'(?is)<div>(?<Body><span class="kv-label">Audit:</span>\s*Not executed)</div>','<div class="finding-value finding-unverified" title="Not executed in Audit mode">${Body}</div>')
        }
        return $FindingsHtml
    }
    $unverifiedPattern='(?i)\bnot\s+verified\b'
    $requirements=Get-ThoroughReportHighlightFields $RequirementHtml
    $pattern='(?is)<div>(?<Body><span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>[^<]*))</div>'
    $highlighted=[regex]::Replace($FindingsHtml,$pattern,[Text.RegularExpressions.MatchEvaluator]{
        param($field)
        $label=[Net.WebUtility]::HtmlDecode($field.Groups['Label'].Value).Trim()
        $value=[Net.WebUtility]::HtmlDecode($field.Groups['Value'].Value).Trim()
        $presence=Get-ThoroughReportCollectedValueState -Row $Row -Label $label -Value $value -Requirements $requirements
        $comparison=if($presence -eq 'unverified' -or $value -match $unverifiedPattern){'unverified'}else{
            Get-ThoroughReportFindingComparison -Row $Row -Label $label -Value $value -Requirements $requirements -KioskAccountName $KioskAccountName
        }
        if(-not $comparison){return $field.Value}
        $description=switch($comparison){
            'match' {'Matches required configuration'}
            'mismatch' {'Does not match required configuration'}
            'unverified' {'Value not verified; manual review required'}
        }
        if($presence -eq 'collected'){$description='Value collected'}
        elseif($presence -eq 'printer-match'){$description=if($label -in @('KioskPrinterName','Kiosk/POS Printer')){'Matches installed USB printer'}else{'Matches installed IP printer'}}
        elseif($presence -eq 'endpoint-match'){$description='Matches required service URL'}
        elseif($presence -eq 'missing'){$description='Value not collected'}
        '<div class="finding-value finding-'+$comparison+'" title="'+$description+'">'+$field.Groups['Body'].Value+'</div>'
    })
    if($FindingsHtml.Trim() -eq 'Account Missing. Please create manually.'){
        return '<div class="finding-value finding-mismatch" title="Does not match required configuration">'+$FindingsHtml+'</div>'
    }
    if($highlighted -notmatch 'class="finding-value'){
        if($Row.SectionTitle -eq 'AppSettings Check' -and $Row.ItemTitle -in @('Print','Printer') -and $FindingsHtml -match 'class="kv-label">'){return $highlighted}
        $text=[Net.WebUtility]::HtmlDecode(($FindingsHtml -replace '<[^>]+>',' ')).Trim()
        if($Row.SectionTitle -eq 'AppSettings Check'){
            $presence=Get-ThoroughReportCollectedValueState -Row $Row -Label '' -Value $text -Requirements $requirements
            $color=switch($presence){'collected'{'match'};'missing'{'mismatch'};'unverified'{'unverified'}}
            $description=switch($presence){'collected'{'Value collected'};'missing'{'Value not collected'};'unverified'{'Value not verified; manual review required'}}
            if($color){return '<div class="finding-value finding-'+$color+'" title="'+$description+'">'+$FindingsHtml+'</div>'}
        }
        if($text -match $unverifiedPattern){
            return '<div class="finding-value finding-unverified" title="Value not verified; manual review required">'+$FindingsHtml+'</div>'
        }
    }
    return $highlighted
}

function Get-ReportRequirement {
    param ($Row)
    if($Row.SectionTitle -eq 'AppSettings Check' -and $Row.ItemTitle -in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')){
        $requiredEndpoints=Get-ThoroughServiceEndpointRequirements
        return ConvertTo-ReportDefinitionHtml ([ordered]@{$Row.ItemTitle=$requiredEndpoints[$Row.ItemTitle]})
    }
    if($Row.ItemTitle -eq 'Nmap Diagnostic Tool'){
        return ConvertTo-ReportDefinitionHtml ([ordered]@{'Tool State'='Installed';'Version'='Readable'})
    }
    if($Row.ItemTitle -eq 'System & Browser Policies'){
        return ConvertTo-ReportDefinitionHtml ([ordered]@{'Local Network Allowlist'=$script:KioskClientSettings.Origin;'Translation'='Disabled';'Visual Search'='Disabled';'Edge Gestures'='Disabled';'Pinch-to-Zoom'='Disabled'})
    }
    if($Row.ItemTitle -eq 'Kiosk Launch Task'){
        return ConvertTo-ReportDefinitionHtml ([ordered]@{'Task Name'='Launch Kiosk';'Task Status'='Active';'Target'='Existing kiosk launcher';'Trigger Time'='At user logon';'Last Run'='Informational'})
    }
    if($Row.PSObject.Properties['RecordedRequirementHtml']){return [string]$Row.RecordedRequirementHtml}
    # Task requirements are display examples; verification uses the selected service.
    if($Row.ItemTitle -in @('Payment Service Restart Task','PaymentService Restart Task')){
        return ConvertTo-ReportDefinitionHtml ([ordered]@{
            'Task Name'='e.g. Restart PS';'Task Status'='Active';'Target'='Payment Service'
            'Trigger Time'='time';'Last Run'='date & time';'Next Run'='date & time'
        })
    }
    if ($Row.PSObject.Properties['ExpectedHtml']) { return $Row.ExpectedHtml }
    $accountView=Get-AccountReportView $Row
    if ($null -ne $accountView) { return $accountView.ExpectedHtml }
    if ($Row.ItemSub -eq 'Type: Payment Gateway Middleware') {
        return ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Expected Names'=$script:KioskClientSettings.PaymentServiceRequirement; 'Service State'='Running'; 'Startup type'='Automatic'; 'First failure'='Restart the service'; 'Second failure'='Restart the service'; 'Subsequent failures'='Take No Action'; 'Version'='Readable' })
    }
    if ($Row.ItemSub -eq 'Type: Infrastructure Monitoring') {
        return ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Service State'='Running'; 'Startup type'='Automatic'; 'First failure'='Restart the service'; 'Second failure'='Restart the service'; 'Subsequent failures'='Take No Action'; 'Host Name'=$(if ($Row.PSObject.Properties['ExpectedHostName']) {$Row.ExpectedHostName} else {'Not detected'}) })
    }
    $values = switch -Regex ($Row.ItemTitle) {
        '^Administrative Account' { [ordered]@{ 'Account Status'='Active / Disabled'; 'Password Never Expires'='Enabled' }; break }
        '^(KIOSK Account|Local Account:|SELISE Local Accounts)' {
            [ordered]@{ 'Account Status'='Active / Disabled'; 'Password Never Expires'='Enabled'; 'User Cannot Change Password'='Enabled' }; break
        }
        '^Kiosk Launch Architecture$' {
            [ordered]@{ 'Launch Script'='Available'; 'URL origin'=$script:KioskClientSettings.Origin; 'Restaurant ID'='Configured'; 'Kiosk ID'='Configured'; 'Host name'=$(if($Row.PSObject.Properties['ExpectedHostName']){$Row.ExpectedHostName}else{'Not detected'}) }; break
        }
        '^SELISE-KIOSK Startup Folder$' { [ordered]@{ 'Location'='Path'; 'Startup BAT'='Available'; 'Desktop Shortcut'='Available' }; break }
        '^Kiosk Auto-Login$' {
            [ordered]@{ 'Automatic Sign-In'='Enabled'; 'Default User'='Kiosk account'; 'Default Domain'='Local computer'; 'Automatic Sign-In Limit'='Unlimited' }; break
        }
        '^System & Browser Policies$' {
            [ordered]@{ 'Local Network Allowlist'=$script:KioskClientSettings.Origin; 'Translation'='Disabled'; 'Visual Search'='Disabled'; 'Edge Gestures'='Disabled'; 'Pinch-to-Zoom'='Disabled' }; break
        }
        '^PrintService Operational Log$' { [ordered]@{ 'Log State'='Enabled' }; break }
        '^Windows Update' {
            [ordered]@{ 'Service State'='Stopped'; 'Startup type'='Disabled'; 'First failure'='Take No Action'; 'Second failure'='Take No Action'; 'Subsequent failures'='Take No Action' }; break
        }
        '^Inbound TCP' {
            [ordered]@{ 'Direction'='Inbound'; 'Protocol'='TCP'; 'Ports'=($Row.ItemTitle -replace '^Inbound TCP\s+|\s+Rules?$',''); 'Enabled'='Yes'; 'Action'='Allow' }; break
        }
        '^Nmap Diagnostic Tool$' { [ordered]@{ 'Installed'='Yes'; 'Version'='Readable' }; break }
        '^lodctr /R' { [ordered]@{ 'Apply Fix'='Exit code 0' }; break }
        '^Payment Service appsettings.json$' { [ordered]@{ 'Source'='Running Payment Service directory'; 'File'='appsettings.json'; 'Inspection'='Read only' }; break }
        '^Unexpected interruption$' { [ordered]@{ 'Execution'='All component checks completed' }; break }
    }
    if ($null -eq $values) {
        $values = switch ($Row.ItemSub) {
            'Type: Receipt / POS Printer' { [ordered]@{ 'Printer Name'='Brand/Model'; 'Printer status'='Active / Idle'; 'Keep printed documents'='Enabled' } }
            'Type: Receipt / Hardware' { [ordered]@{ 'Printer Name'='Brand/Model'; 'Printer status'='Active / Idle'; 'Keep printed documents'='Enabled' } }
            'Type: Old Payment Service' { [ordered]@{ 'Service State'='Stopped'; 'Startup type'='Manual'; 'First failure'='Take No Action'; 'Second failure'='Take No Action'; 'Subsequent failures'='Take No Action' } }
            { $_ -in @('Type: Payment Gateway Middleware','Type: Infrastructure Monitoring') } { [ordered]@{ 'Service State'='Running'; 'Startup type'='Automatic'; 'Restart recovery'='Configured' } }
            { $_ -in @('Type: Middleware Service','Type: Payment Middleware') } { [ordered]@{ 'Payment service'='Detected'; 'Primary service'='Identified without ambiguity' } }
            default { [ordered]@{ 'Verification'='Completed for this check' } }
        }
    }
    ConvertTo-ReportDefinitionHtml $values
}

function New-ThoroughReportId {
    # Display ID only. File paths continue to use the collision-resistant run ID.
    'OMK-{0:D6}' -f (Get-Random -Minimum 0 -Maximum 1000000)
}

function Get-ThoroughReportDeviceLabel {
    param ([string]$DeviceType, [string]$LauncherKioskId, [string]$RequestedKioskId)
    $device=$DeviceType.ToUpperInvariant()
    foreach ($candidate in @($LauncherKioskId,$RequestedKioskId)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -in @('Not detected','Not verified')) { continue }
        $id=$candidate.Trim()
        $numberText=$null
        if ($id -match ('^(?:'+[regex]::Escape($device)+'[-_\s]*)?(\d+)$')) { $numberText=$Matches[1] }
        [uint32]$number=0
        if ($null -ne $numberText -and [uint32]::TryParse($numberText,[ref]$number)) { return '{0}-{1:D2}' -f $device,$number }
        return '{0} - {1}' -f $device,$id
    }
    return '{0} (number not verified)' -f $device
}

function Update-ZabbixServiceReport {
    param($Row,[string]$Hostname)
    try{
        $freshAgent=Get-AuditService -ServiceName 'Zabbix Agent 2'
        if(-not $freshAgent){throw 'Zabbix service unavailable after hostname verification.'}
        $freshRecovery=Get-ServiceRecoveryDetails -ServiceName 'Zabbix Agent 2'
        $Row.RecoveryDetails=$freshRecovery
        $Row.FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceState $freshAgent.State -StartupType $freshAgent.StartMode -Recovery $freshRecovery -HostName $Hostname
        if($freshAgent.State -ne 'Running' -or $freshAgent.StartMode -ne 'Auto' -or -not $freshRecovery.Verified -or $freshRecovery.First -ne 'Restart the service' -or $freshRecovery.Second -ne 'Restart the service' -or $freshRecovery.Subsequent -ne 'Take No Action'){$Row.Status='Fail';$Row.ActionTaken+='; Final Zabbix service/recovery readback requires attention.'}
    }catch{
        $Row.Status='Fail';$Row.ActionTaken+='; Final Zabbix state was not verified: '+$_.Exception.Message
        $Row.FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceState 'Not verified' -StartupType 'Not verified' -Recovery ([pscustomobject]@{First='Not verified';Second='Not verified';Subsequent='Not verified'}) -HostName $Hostname
    }
}

function Copy-ThoroughObservationRows {
    param([AllowEmptyCollection()][object[]]$Rows)
    # Persist only values already used by the report. Never copy the full
    # appsettings document, credentials, account objects or arbitrary metadata.
    foreach($row in $Rows){
        if($null -eq $row){continue}
        $clean=[ordered]@{}
        foreach($name in @('SectionNumber','SectionTitle','ItemTitle','ItemSub','Shortcut','FoundStateHtml','Status','ActionTaken','ExpectedHtml','RecordedRequirementHtml','ExpectedHostName')){
            if($row.PSObject.Properties[$name]){$clean[$name]=[string]$row.$name}
        }
        if($row.PSObject.Properties['AccountResults']){
            $clean.AccountResults=@(foreach($account in @($row.AccountResults)){
                if($null -eq $account){continue}
                $entry=[ordered]@{}
                foreach($name in @('AccountName','Status','Action','StateHtml')){
                    if($account.PSObject.Properties[$name]){$entry[$name]=[string]$account.$name}
                }
                if($account.PSObject.Properties['AccountPolicyChanged'] -and $account.AccountPolicyChanged -is [bool]){$entry.AccountPolicyChanged=$account.AccountPolicyChanged}
                [pscustomobject]$entry
            })
        }
        if($row.PSObject.Properties['LegacyServiceRows']){$clean.LegacyServiceRows=@(Copy-ThoroughObservationRows @($row.LegacyServiceRows))}
        [pscustomobject]$clean
    }
}

function Find-ThoroughExistingBundle {
    param([string]$Path,[string]$ClientType,[string]$ComputerName)
    if([IO.File]::Exists($Path)){
        $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($Path))
        if($state.ClientType -cne $ClientType -or $state.ComputerName -ine $ComputerName){throw 'The destination report belongs to another client or Windows computer.'}
        return [pscustomobject]@{Path=$Path;State=$state}
    }
    $folder=[IO.Path]::GetDirectoryName($Path)
    if(-not [IO.Directory]::Exists($folder)){return $null}
    $matches=[Collections.Generic.List[object]]::new()
    foreach($candidate in [IO.Directory]::GetFiles($folder,('Thorough Check Reports - '+$ClientType+' - *.html'))){
        try {$state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($candidate))}
        catch {continue}
        if($state.ClientType -ceq $ClientType -and $state.ComputerName -ieq $ComputerName){$matches.Add([pscustomobject]@{Path=$candidate;State=$state})}
    }
    if($matches.Count -gt 1){throw 'Multiple reports match this client and Windows computer. Please select the intended report before retrying.'}
    if($matches.Count){return $matches[0]}
    return $null
}

function Get-ThoroughSnapshotObservations {
    param($Snapshot)
    if($null -eq $Snapshot){return}
    if($Snapshot.PSObject.Properties['Observations'] -and @($Snapshot.Observations).Count){
        $rows=@($Snapshot.Observations)
        foreach($row in $rows){
            foreach($field in @('SectionNumber','SectionTitle','ItemTitle','FoundStateHtml','Status','Shortcut','ActionTaken')){
                if(-not $row.PSObject.Properties[$field]){throw 'Saved Audit observations are incomplete.'}
            }
            $section=0
            if(-not [int]::TryParse([string]$row.SectionNumber,[ref]$section) -or $section -lt 1 -or $section -gt 99){throw 'Saved Audit observations have an invalid section.'}
        }
        return Copy-ThoroughObservationRows $rows
    }
    # Older reports contain complete Audit HTML but no structured observations.
    # Recover presentation data only; none of these values drive device writes.
    $html=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))
    foreach($table in [regex]::Matches($html,'(?is)<table class="checks"[^>]*>.*?</table>')){
        $section=[regex]::Match($table.Value,'(?is)<th[^>]*class="section-title"[^>]*>(?<Number>\d+)\.\s*(?<Title>.*?)</th>')
        $body=[regex]::Match($table.Value,'(?is)<tbody>(.*?)</tbody>')
        if(-not $section.Success -or -not $body.Success){continue}
        foreach($row in [regex]::Matches($body.Groups[1].Value,'(?is)<tr\b[^>]*>.*?</tr>')){
            $cells=@([regex]::Matches($row.Value,'(?is)<td\b[^>]*>(.*?)</td>')|ForEach-Object {$_.Groups[1].Value})
            if($cells.Count -ne 4){continue}
            $title=[regex]::Match($cells[0],'(?is)<div class="device-title">(.*?)</div>')
            if(-not $title.Success){continue}
            $findings=[regex]::Replace($cells[3],'(?is)<div class="finding-value finding-(?:match|mismatch|unverified)"[^>]*>','<div>')
            $status=if($cells[3] -match 'finding-(?:mismatch|unverified)|(?i:not verified|not configured|missing)'){'Fail'}else{'Pass'}
            [pscustomobject]@{
                SectionNumber=[int]$section.Groups['Number'].Value
                SectionTitle=[Net.WebUtility]::HtmlDecode($section.Groups['Title'].Value)
                ItemTitle=[Net.WebUtility]::HtmlDecode($title.Groups[1].Value)
                ItemSub='Saved Audit observation';Shortcut=$cells[1];FoundStateHtml=$findings
                Status=$status;ActionTaken='Audit observations; no changes applied'
                RecordedRequirementHtml=$cells[2]
            }
        }
    }
}

function Get-ThoroughBeforeFindingRow {
    param($Row,[AllowEmptyCollection()][object[]]$BeforeRows)
    $title=Get-ThoroughReportComponentName $Row.ItemTitle
    $matching=@($BeforeRows|Where-Object {$_.SectionNumber -eq $Row.SectionNumber -and (Get-ThoroughReportComponentName $_.ItemTitle) -eq $title})
    if($matching.Count -ne 1){return $null}
    $before=$matching[0]|Select-Object *
    $before.ItemTitle=$Row.ItemTitle
    if($Row.PSObject.Properties['ExpectedHostName']){
        $before|Add-Member NoteProperty ExpectedHostName ([string]$Row.ExpectedHostName) -Force
        if($before.PSObject.Properties['RecordedRequirementHtml']){
            $values=Get-ThoroughReportHighlightFields $before.RecordedRequirementHtml
            $label=if($Row.ItemTitle -eq 'Kiosk Launch Architecture'){'Host name'}else{'Host Name'}
            $values[$label]=[string]$Row.ExpectedHostName
            $before.RecordedRequirementHtml=ConvertTo-ReportDefinitionHtml $values
        }
    }
    return $before
}

function Test-ThoroughAppSettingsReview {
    param($Row)
    $requirements=Get-ThoroughReportHighlightFields (Get-ReportRequirement $Row)
    $fields=@([regex]::Matches([string]$Row.FoundStateHtml,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>[^<]*)'))
    if(-not $fields.Count){
        $value=Convert-ReportHtmlToTerminalText ([string]$Row.FoundStateHtml)
        return (Get-ThoroughReportCollectedValueState -Row $Row -Label '' -Value $value -Requirements @{}) -ne 'collected'
    }
    foreach($field in $fields){
        $label=[Net.WebUtility]::HtmlDecode($field.Groups['Label'].Value)
        $value=[Net.WebUtility]::HtmlDecode($field.Groups['Value'].Value)
        if((Get-ThoroughReportCollectedValueState -Row $Row -Label $label -Value $value -Requirements $requirements) -notin @('collected','printer-match','informational','endpoint-match','required-match')){return $true}
    }
    return $false
}

function Read-AuditReportChoice {
    do {
        $choice = ([string](Read-Host 'Generate HTML report? [Y/N]')).Trim()
        if ($choice -notmatch '^[YyNn]$') { Write-Host 'Please enter Y or N.' -ForegroundColor Yellow }
    } until ($choice -match '^[YyNn]$')
    return $choice -match '^[Yy]$'
}

function Add-LauncherReportDetails {
    param ($Result, [string]$Path, [string]$ShortcutPath, [string]$StartupBatchPath)
    $values = [ordered]@{
        'Launcher Path' = $Path
        'Restaurant ID' = 'Not detected'
        'Host Name' = 'Not detected'
        'URL' = 'Not detected'
        'KIOSK ID' = 'Not detected'
        'Desktop Shortcut' = $(if ($ShortcutPath -and (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { 'Available' } else { 'Missing' })
    }
    if ($StartupBatchPath) {
        $values['Startup BAT'] = if (Test-Path -LiteralPath $StartupBatchPath -PathType Leaf) { 'Available' } else { 'Missing. Manual action required.' }
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $strings = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -or ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0) }, $true)
        $urls = @($strings | ForEach-Object {
            [regex]::Matches($_.Value, $script:KioskClientSettings.LauncherUrlPattern) | ForEach-Object { $_.Value }
        } | Select-Object -Unique)
        if ($urls.Count -eq 1) {
            $values['URL'] = $urls[0]
            foreach ($pair in @(@('Restaurant ID', 'restaurantId'), @('Host Name', 'host'), @('KIOSK ID', 'kioskId'))) {
                $match = [regex]::Match($urls[0], ('[?&]{0}=([^&#]*)' -f $pair[1]))
                if ($match.Success -and $match.Groups[1].Value) {
                    $decoded = [uri]::UnescapeDataString($match.Groups[1].Value.Replace('+', ' ')).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($decoded)) { $values[$pair[0]] = $decoded }
                }
            }
        }
    }
    # Keep full verification data separate from the five report fields.
    $urlOrigin='Not detected'
    if ($values['URL'] -ne 'Not detected') {
        $displayUri=$null
        $urlOrigin=if ([uri]::TryCreate([string]$values['URL'],[UriKind]::Absolute,[ref]$displayUri)) { $displayUri.GetLeftPart([UriPartial]::Authority) } else { 'Not verified' }
    }
    $displayValues=[ordered]@{
        'Launcher Path'=$values['Launcher Path']
        'URL origin'=$urlOrigin
        'Restaurant ID'=$values['Restaurant ID']
        'Kiosk ID'=$values['KIOSK ID']
        'Host name'=$values['Host Name']
    }
    $html = ConvertTo-ReportDefinitionHtml $displayValues
    $Result | Add-Member -NotePropertyName StateHtml -NotePropertyValue $html -Force
    $Result | Add-Member -NotePropertyName LauncherValues -NotePropertyValue $values -Force
    $Result | Add-Member -NotePropertyName Shortcut -NotePropertyValue ('<code>' + [Net.WebUtility]::HtmlEncode(('notepad "{0}"' -f $Path)) + '</code>') -Force
    return $Result
}

function New-AccountReportCommand {
    param ([string[]]$AccountNames)
    $commands=[Collections.Generic.List[string]]::new()
    $commands.Add('lusrmgr.msc')
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $AccountNames) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $seen.Add($name)) { continue }
        $commands.Add(('net user "{0}"' -f $name))
    }
    New-ReportCommand -Commands $commands.ToArray()
}

function ConvertTo-ServiceFindingHtml {
    param ([string]$ServiceState, [string]$StartupType, $Recovery, [string]$ServiceName, [string]$Version, [string]$HostName)
    $startup=if ($StartupType -eq 'Auto') { 'Automatic' } else { $StartupType }
    $values=[ordered]@{}
    if ($PSBoundParameters.ContainsKey('ServiceName')) { $values['Service Name']=$ServiceName }
    $values['Service State']=$ServiceState
    $values['Startup type']=$startup
    $values['First failure']=$Recovery.First
    $values['Second failure']=$Recovery.Second
    $values['Subsequent failures']=$Recovery.Subsequent
    if ($PSBoundParameters.ContainsKey('Version')) { $values['Version']=$Version }
    if ($PSBoundParameters.ContainsKey('HostName')) { $values['Host Name']=$HostName }
    $lines=foreach ($key in $values.Keys) {
        '<div><span class="kv-label">{0}:</span> {1}</div>' -f ([Net.WebUtility]::HtmlEncode($key)),([Net.WebUtility]::HtmlEncode([string]$values[$key]))
    }
    '<div class="kv-block">'+($lines -join '')+'</div>'
}

function ConvertTo-ThoroughPaymentReportHtml {
    param ([Parameter(Mandatory = $true)][string[]]$Lines)
    $rows = foreach ($line in $Lines) {
        $indented = $line.StartsWith('  ')
        $content = $line.Trim()
        $style = if ($indented) { ' style="margin-left:16px"' } else { '' }
        if ($content -match '^([^:]+):\s*(.*)$') {
            '<div{0}><span class="kv-label">{1}:</span>{2}</div>' -f $style,
                ([Net.WebUtility]::HtmlEncode($Matches[1])),
                $(if ($Matches[2].Length -gt 0) { ' ' + [Net.WebUtility]::HtmlEncode($Matches[2]) } else { '' })
        } else {
            '<div{0}>{1}</div>' -f $style, ([Net.WebUtility]::HtmlEncode($content))
        }
    }
    '<div class="kv-block">' + ($rows -join '') + '</div>'
}
