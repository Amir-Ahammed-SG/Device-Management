<#
.SYNOPSIS
    Subway Kiosk health audit with an interactive Audit / Apply mode menu.
.DESCRIPTION
    Without mode switches, choose Audit Mode or Apply Mode from the menu.
    -AuditOnly/-WhatIf only read system state. -FinalReport saves a plain configuration report without repairs.
    Apply Mode/-Apply configures the kiosk; existing passwords are never reset.
    POS is reserved and currently rejected before any checks or changes.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [switch]$Apply,
    [switch]$AuditOnly,
    [switch]$FinalReport,
    [ValidateSet('KIOSK', 'POS')][string]$DeviceType = 'KIOSK',
    [string]$ClientLocation,
    [string]$AgentName,
    [string]$RestaurantId,
    [string]$KioskId,
    [string]$KioskHostname,
    [Security.SecureString]$KioskPassword,
    [switch]$ArchitectureRun,
    [string]$ArchitectureResultPath
)

if (@($Apply,$AuditOnly,$FinalReport | Where-Object { $_ }).Count -gt 1) { throw 'Use only one of -Apply, -AuditOnly or -FinalReport.' }
if ($DeviceType -ne 'KIOSK') { throw 'POS setup is not available yet. No checks or changes were performed.' }
if (-not [Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell as Administrator.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run Windows PowerShell as Administrator.'
}

function Get-ThoroughDeviceHostname {
    # Keep unavailable detection explicit; never substitute a shortened environment name.
    try {
        $systems=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property DNSHostName -ErrorAction Stop)
        if($systems.Count -ne 1) { return 'Not detected' }
        $name=([string]$systems[0].DNSHostName).Trim()
        if($name.Length -lt 1 -or $name.Length -gt 63 -or $name -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') { return 'Not detected' }
        return $name
    } catch { return 'Not detected' }
}

function Confirm-KioskApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param ()
    # Invoke-Expression does not provide a script-level PSCmdlet. This advanced
    # function owns its PSCmdlet and honors inherited WhatIf/Confirm preferences.
    $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Apply kiosk configuration and repair settings')
}

do {
$script:AuditRunTimer = [Diagnostics.Stopwatch]::StartNew()
$script:AuditStepTimer = $null
$script:ApplyChanges = $false
$reportHostname = Get-ThoroughDeviceHostname
$reportKioskId = $null
$reportRestaurantId = 'Not detected'
if (-not $Apply -and -not $AuditOnly -and -not $FinalReport -and -not $WhatIfPreference) {
    Write-Host "`n  SELISE | KIOSK SYSTEM CHECK" -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  Select an operation' -ForegroundColor White
    Write-Host ''
    Write-Host '  [1] Audit Report' -ForegroundColor White
    Write-Host '      Review current settings and generate a report.' -ForegroundColor Gray
    Write-Host '      System configuration remains unchanged.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [2] Apply Fix' -ForegroundColor White
    Write-Host '      Apply kiosk settings, verify results and save a report.' -ForegroundColor Gray
    Write-Host ''

    Write-Host ''
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    do {
        $modeChoice = ([string](Read-Host '  Select option')).Trim()
        if ($modeChoice -notin @('1', '2')) {
            Write-Host 'Invalid option. Please enter 1 or 2.' -ForegroundColor Yellow
        }
    } until ($modeChoice -in @('1', '2'))
    if ($modeChoice -eq '2') { $Apply = $true }

    else { $AuditOnly = $true }
}
if ($Apply -and -not $WhatIfPreference) {
    $script:ApplyChanges = Confirm-KioskApply -ErrorAction Stop
}
$runMode = if ($FinalReport) { 'THOROUGH CHECK REPORT' } elseif ($script:ApplyChanges) { 'APPLY' } else { 'AUDIT ONLY' }

$ProgressPreference = 'SilentlyContinue'
$outputFolder = 'C:\Thorough Check'
# Apply mode always writes a report. Audit mode creates the folder only after
# the operator chooses to generate the HTML report.
if ($script:ApplyChanges -and -not (Test-Path -LiteralPath $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
}
$runId = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
function Get-KioskReportPath {
    param ([string]$Folder, [string]$Client, [string]$Computer, [bool]$IsApply, [string]$RunId, [bool]$IsFinal=$false)
    # A stable client/computer filename lets independently run modes update one
    # report. Branch labels and launcher hostnames may change between runs.
    $computerLabel=($Computer -replace '[<>:"/\\|?*\x00-\x1F]','_').Trim().TrimEnd('.')
    if([string]::IsNullOrWhiteSpace($computerLabel)){$computerLabel='Unknown'}
    if($computerLabel.Length -gt 60){$computerLabel=$computerLabel.Substring(0,60).TrimEnd(' ','.')}
    Join-Path $Folder ('Thorough Check Reports - Subway - '+$computerLabel+'.html')
}
$reportPath = Get-KioskReportPath -Folder $outputFolder -Client $ClientLocation -Computer $env:COMPUTERNAME -IsApply $script:ApplyChanges -RunId $runId -IsFinal ([bool]$FinalReport)
$auditRows = [System.Collections.Generic.List[PSObject]]::new()

function Test-CanApply { return [bool]$script:ApplyChanges }

function Write-ThoroughConsoleLine {
    param ([string]$Text, [string]$Indent='', [ConsoleColor]$Color='Gray', [int]$Width=0)
    if ($Width -le 0) {
        try { $Width=[int]$Host.UI.RawUI.WindowSize.Width-1 } catch { $Width=100 }
        if ($Width -lt 24) { $Width=100 }
    }
    $Width=[Math]::Max(24,[Math]::Min(100,$Width))
    $remaining=($Text -replace '[\x00-\x1f\x7f]+',' ').Trim()
    $available=[Math]::Max(1,$Width-$Indent.Length)
    do {
        if ($remaining.Length -le $available) { Write-Host ($Indent+$remaining) -ForegroundColor $Color; break }
        $split=$remaining.LastIndexOf(' ',$available)
        if ($split -le 0) { $split=$available }
        Write-Host ($Indent+$remaining.Substring(0,$split).TrimEnd()) -ForegroundColor $Color
        $remaining=$remaining.Substring($split).TrimStart()
    } while ($remaining.Length -gt 0)
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
    foreach($fieldLabel in @(@('PrinterName','Kitchen Printer'),@('KioskPrinterName','Kiosk/POS Printer'))){
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


function Format-ThoroughFinalServiceRecovery {
    param([Parameter(Mandatory=$true)]$Row,[AllowEmptyString()][string]$Html)
    # Final presentation only; summarize observed actions without changing any result.
    if($Row.ItemSub -notin @('Type: Payment Gateway Middleware','Type: Infrastructure Monitoring','Type: Windows Update Engine','Type: Old Payment Service')){return $Html}
    $requirements=Get-ThoroughReportHighlightFields (Get-ReportRequirement $Row)
    $labels=@('First failure','Second failure','Subsequent failures')
    $blockPattern='(?is)<div class="kv-block">(?<Body>(?:<div(?: class="service-recovery-summary")?>(?:<span class="kv-label">[^<]*</span>)?[^<]*</div>\s*)*)</div>'
    [regex]::Replace($Html,$blockPattern,[Text.RegularExpressions.MatchEvaluator]{
        param($block)
        $body=$block.Groups['Body'].Value
        if($body.Contains('class="service-recovery-summary"')){return $block.Value}
        $observed=Get-ThoroughReportHighlightFields $body
        $unknown=$false;$mismatched=$false
        if($Row.PSObject.Properties['RecoveryDetails'] -and $Row.RecoveryDetails.PSObject.Properties['Verified'] -and -not $Row.RecoveryDetails.Verified){$unknown=$true}
        foreach($label in $labels){
            if(-not $requirements.ContainsKey($label) -or [string]::IsNullOrWhiteSpace([string]$requirements[$label])){$unknown=$true;continue}
            $actual=if($observed.ContainsKey($label)){([string]$observed[$label]).Trim()}else{''}
            if(-not $actual -or $actual -match '(?i)not verified|not detected|not recorded|unknown|unavailable'){$unknown=$true;continue}
            if($actual -ine ([string]$requirements[$label]).Trim()){$mismatched=$true}
        }
        $summary=if($mismatched){'Not Configured'}elseif($unknown){'Not Verified'}else{'Configured'}
        $line='<div class="service-recovery-summary"><span class="kv-label">Recovery:</span> '+$summary+'</div>'
        $render=[pscustomobject]@{Written=$false}
        $body=[regex]::Replace($body,'(?is)<div><span class="kv-label">(?:First failure|Second failure|Subsequent failures):</span>\s*[^<]*</div>',[Text.RegularExpressions.MatchEvaluator]{
            param($field)
            if($render.Written){return ''}
            $render.Written=$true
            $line
        })
        if(-not $render.Written){$body+=$line}
        '<div class="kv-block">'+$body+'</div>'
    })
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
    param($Row,[string]$FindingsHtml,[string]$RequirementHtml,[bool]$AfterApply=$false,[bool]$RecordScope=$false)
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
    if($issues.Count){
        $required=Get-ThoroughReportHighlightFields $RequirementHtml
        $selected=New-Object 'Collections.Generic.List[string]'
        foreach($field in $fields){
            $labelMatch=[regex]::Match($field.Value,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>')
            $label=if($labelMatch.Success){[Net.WebUtility]::HtmlDecode($labelMatch.Groups['Label'].Value).Trim()}else{''}
            $issue=$field.Value -match 'class="finding-value finding-(?:mismatch|unverified)"'
            if(-not $issue -and $label -notin @('Account Name','Printer Name','Task Name','Service Name','Ports')){continue}
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

function Get-ThoroughAuditClientLocation {
    param([string]$Path,[string]$ClientType,[string]$ComputerName)
    # Report filenames may use the launcher hostname. Match saved Audit identity,
    # in this report folder only, without changing files or guessing conflicts.
    $paths=New-Object 'Collections.Generic.List[string]'
    if([IO.File]::Exists($Path)){[void]$paths.Add($Path)}
    try {
        $folder=[IO.Path]::GetDirectoryName($Path)
        if($ClientType -cin @('SaaS','Subway') -and [IO.Directory]::Exists($folder)){
            foreach($candidate in [IO.Directory]::GetFiles($folder,('Thorough Check Reports - '+$ClientType+' - *.html'))){
                if(-not $paths.Contains($candidate)){[void]$paths.Add($candidate)}
            }
        }
    } catch { return $null }
    $branches=New-Object 'Collections.Generic.List[string]'
    foreach($candidate in $paths){
        try {
            $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($candidate))
            if($state.ClientType -cne $ClientType -or $state.ComputerName -ine $ComputerName){continue}
            $audit=$state.Reports.Audit
            if($null -eq $audit){continue}
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($audit.HtmlBase64))
            $match=[regex]::Match($html,'(?is)(?:<th>\s*Branch\s*</th>\s*<td\b[^>]*>(?<Branch>.*?)</td>|<dt>\s*Branch\s*</dt>\s*<dd\b[^>]*>(?<Branch>.*?)</dd>)')
            if(-not $match.Success){continue}
            $branch=[Net.WebUtility]::HtmlDecode(($match.Groups['Branch'].Value -replace '<[^>]+>',''))
            if([string]::IsNullOrWhiteSpace($branch) -or $branch.Trim() -in @('Not provided','Not verified')){continue}
            if(-not $branches.Contains($branch)){[void]$branches.Add($branch)}
            if($branches.Count -gt 1){return $null}
        } catch {
            # Preserve unreadable/unsupported reports. Their data is not trusted.
            continue
        }
    }
    if($branches.Count -eq 1){return $branches[0]}
    return $null
}

function Get-ThoroughAuditAgentName {
    param([string]$Path,[string]$ClientType,[string]$ComputerName)
    # Reuse only a uniquely identified saved Audit. Never guess a Windows user
    # or attribute a legacy report to the person running Apply.
    try {
        $existing=Find-ThoroughExistingBundle -Path $Path -ClientType $ClientType -ComputerName $ComputerName
        if($existing -and $existing.State.Reports.Audit){
            $audit=$existing.State.Reports.Audit
            if($audit.PSObject.Properties['AgentName'] -and -not [string]::IsNullOrWhiteSpace([string]$audit.AgentName) -and $audit.AgentName -ne 'Not provided'){
                return [string]$audit.AgentName
            }
        }
    } catch { return $null }
    return $null
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
    foreach($label in @('Last Run','Next Run')){$fields[$label]=if($v.ContainsKey($label)){Format-ThoroughReportDateTime -Value $v[$label]}elseif($missing){'Not recorded'}else{$unknown}}
    ConvertTo-ReportDefinitionHtml $fields
}

function Get-KioskLaunchTaskHistory {
    param([object[]]$Tasks)
    $fields=[ordered]@{'Last Run'='Not recorded';'Next Run'='Not recorded'}
    if($Tasks.Count -eq 1){
        try{
            if(-not [string]$Tasks[0].TaskPath){throw 'Task path unavailable'}
            $info=Get-ScheduledTaskInfo -TaskName 'Launch Kiosk' -TaskPath ([string]$Tasks[0].TaskPath) -ErrorAction Stop
            foreach($label in @('Last Run','Next Run')){
                $property=if($label -eq 'Last Run'){'LastRunTime'}else{'NextRunTime'}
                $value=$info.$property
                $fields[$label]=if($value -is [datetime] -and $value.Year -gt 1900){$value.ToString('dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)}elseif($value -is [datetime]){'Not recorded'}else{'Not verified'}
            }
        }catch{$fields['Last Run']='Not verified';$fields['Next Run']='Not verified'}
    }elseif($Tasks.Count -gt 1){$fields['Last Run']='Not verified';$fields['Next Run']='Not verified'}
    $fields
}

function ConvertTo-ThoroughAuditRows {
    param($Row,[string]$ComponentHtml,[string]$CommandHtml,[string]$RequirementHtml,[string]$FindingsHtml,$AccountView)
    $FindingsHtml=Expand-ThoroughUnavailableFields -Html $FindingsHtml -RequirementHtml $RequirementHtml
    $required=@(Read-ThoroughAuditFields $RequirementHtml)
    $observed=@(Read-ThoroughAuditFields $FindingsHtml)
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
            $class=if($entry.State -in @('mismatch','unverified')){' finding-'+$entry.State}else{''}
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
    .audit-report .audit-observed { overflow-wrap:anywhere; }
    .audit-report .audit-observed.finding-mismatch { padding:1px 4px; border-radius:2px; background:#fdecec; color:#9b1c1c; }
    .audit-report .audit-observed.finding-unverified,
    .audit-report .finding-value.finding-unverified { padding:1px 4px; border:1px solid #d3a83e; border-radius:2px; background:#ffe3a0; color:#593900; }
    .audit-report .finding-match { background:transparent; color:inherit; }
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
            $identity=@($record.Fields|Where-Object {$_.Kind -eq 'Field' -and $_.Label -ieq $label -and -not [string]::IsNullOrWhiteSpace($_.Text) -and $_.Text -notmatch '(?i)^(?:not verified|not detected|unknown|missing|not found)'})
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
    if($plain -match '(?i)\bnot\s+verified\b|^(?:not detected|not recorded|not applied|unknown|unavailable|not executed)(?:[.\s(]|$)'){$State='unverified'}
    $class=if($State -in @('mismatch','unverified')){' finding-'+$State}else{''}
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
    $noBaseline=$Mode -eq 'Fix' -and $AfterApply -and -not $HasBeforeRow
    # A retained repair may have only an old generic no-change summary. Show the
    # recorded post-fix properties without inventing their missing pre-fix values.
    if($noBaseline -and $FindingsHtml -match 'class="fix-no-change"' -and -not @($records.Fields|Where-Object Kind -EQ 'Field').Count){$records=$currentRecords}
    $specs=[Collections.Generic.List[object]]::new()
    foreach($record in $records){
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
        $readOnly=$Row.SectionTitle -eq 'AppSettings Check'
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
        $seen=@{}
        foreach($field in $record.Fields){
            $label=[string]$field.Label
            $ordinal=if($seen.ContainsKey($label)){[int]$seen[$label]}else{0};$seen[$label]=$ordinal+1
            $beforeHtml=if($noBaseline){'Not recorded'}else{$field.Html}
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
                }
                $value=ConvertTo-ThoroughSettingValue -Html $afterHtml -State $afterState -Description $note
            }
            $displayLabel=if($Row.ItemTitle -eq 'lodctr /R Performance Counter' -and $label -eq 'Audit'){'Rebuild State'}else{$label}
            $specs.Add([pscustomobject]@{Kind='Value';Label=$displayLabel;Before=$before;Value=$value})
        }
    }
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
    <tr><th>Client Type</th><td>Subway</td><th>Branch</th><td>$([Net.WebUtility]::HtmlEncode($clientLocation))</td></tr>
    <tr><th>Restaurant ID</th><td>$([Net.WebUtility]::HtmlEncode($reportRestaurantId))</td><th>Hostname</th><td>$([Net.WebUtility]::HtmlEncode($reportHostname))</td></tr>
    <tr><th>Device</th><td>$([Net.WebUtility]::HtmlEncode($reportDevice))</td><th>Prepared by</th><td>$([Net.WebUtility]::HtmlEncode($preparedBy))</td></tr>
</table>
<h2>CONFIGURATION CHECK</h2>
"@

$reportRows = @(Get-ThoroughReportDisplayRows -Rows $Rows)
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
                $stateHtml=Format-ThoroughFixFindings -Row $findingRow -FindingsHtml $stateHtml -RequirementHtml $requirementHtml -AfterApply:($AfterApply -and -not $hasBeforeRow)
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
    if($isApplyReport -and -not @($tableRows).Count){continue}
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
<footer class="report-footer"><span>Retain with the device configuration records.<br><span class="report-generated-at"><strong>Generated Time:</strong> $([Net.WebUtility]::HtmlEncode($generatedAt))</span></span><span class="report-prepared-by"><strong>Prepared by:</strong> $([Net.WebUtility]::HtmlEncode($preparedBy))</span></footer>
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
        ExportFileName=('Thorough Check Report - Subway - '+$hostLabel+'.html')}
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
    <div class="bundle-actions" id="final-actions" hidden>
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
  document.getElementById('final-actions').hidden=mode!=='Final'||!snapshot;
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
    $readOnlyCheck=$Row.ItemTitle -in @('Kiosk Auto-Login','SELISE-KIOSK Startup Folder','Payment Service Restart Task','PaymentService Restart Task')
    $parts=@($note -split ';\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $changePattern='(?i)\b(?:Allowed password changes|Enabled (?:Keep printed documents|Password Never Expires|User Cannot Change Password)|Updated (?:launcher|Zabbix) hostname|Startup set to (?:Automatic|Manual|Disabled)|Service (?:started|stopped|stop requested)|Crash recovery configured|Recovery actions (?:configured|set to Take No Action)|PrintService log enabled|Created (?:missing |the )?desktop shortcut|(?:Created|Updated) inbound TCP \d+ rule|Installed missing (?:Nmap|Zabbix Agent)|Performance counters rebuilt|Added (?:only --disable-pinch|Local Network Allowlist|Translation|Visual Search|Edge Gestures))\b'
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

function Write-ThoroughConsoleHeader {
    param ([string]$Client, [string]$Device, [string]$Branch, [bool]$IsApply, [bool]$IsFinal=$false)
    $mode=if ($IsFinal) { 'Thorough Check Report' } elseif ($IsApply) { 'Apply Fix' } else { 'Audit' }
    Write-Host ''
    Write-Host ('-'*60) -ForegroundColor DarkGray
    Write-ThoroughConsoleLine ('SELISE | '+(Get-ThoroughReportTitle -IsApply $IsApply -IsFinal $IsFinal).ToUpperInvariant()) -Indent ' ' -Color Cyan
    Write-Host ('-'*60) -ForegroundColor DarkGray
    Write-ThoroughConsoleLine ('Client : '+$Client) -Indent ' '
    Write-ThoroughConsoleLine ('Device : '+$Device) -Indent ' '
    Write-ThoroughConsoleLine ('Mode   : '+$mode) -Indent ' '
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch -ne 'Not provided') {
        Write-ThoroughConsoleLine ('Branch : '+$Branch) -Indent ' '
    }
    Write-Host ('-'*60) -ForegroundColor DarkGray
}

function Start-AuditStep {
    param ([int]$Number, [string]$Name)
    # Retain timing for diagnostics without overlaying the menu or result log.
    if ($null -eq $script:AuditRunTimer) { $script:AuditRunTimer = [Diagnostics.Stopwatch]::StartNew() }
    $script:AuditStepTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Verbose ('Step {0}: {1}' -f $Number,$Name)
}

function Write-AuditOperation {
    param ([string]$Message)
    Write-Verbose $Message
}

function Get-ThoroughConsoleNote {
    param ([string]$ItemTitle, [string]$FoundStateHtml, [string]$Status, [string]$ActionTaken)
    if ($ItemTitle -eq 'KIOSK Account' -and $FoundStateHtml -match '(?i)Missing') {
        return 'Account Missing. Please create manually. Dependent kiosk checks skipped.'
    }
    if ($ItemTitle -eq 'Administrative Accounts' -and $FoundStateHtml -match '(?is)Account Status:</span>\s*Missing\s*</div>|^\s*Account Missing(?:[.\s]|$)') { return 'Account Missing. Please create manually.' }
    if ($Status -eq 'Bypass' -and $ItemTitle -like 'lodctr /R*') { return 'Not performed in Audit mode; health not verified.' }
    if ($ItemTitle -eq 'Payment Gateway Middleware' -and $ActionTaken -match 'Payment Service version could not be detected') { return 'Payment Service version could not be detected.' }
    if ($ItemTitle -eq 'Payment Gateway Middleware' -and $ActionTaken -match 'Payment Service details not verified') { return 'Payment Service details could not be verified. See HTML report for details.' }
    if ($ItemTitle -eq 'Zabbix Agent 2' -and $ActionTaken -match 'hostname was not verified') { return 'Monitoring hostname could not be verified.' }
    if ($ItemTitle -eq 'Administrative Accounts') { return 'Account settings were not verified. See HTML report for details.' }
    if ($ItemTitle -like 'Windows Update*') { return 'Required service settings were not verified. See HTML report for details.' }
    $text=Convert-ReportHtmlToTerminalText $ActionTaken
    $text=($text -split ';\s*',2)[0]
    $text=($text -split '(?<=\.)\s+(?=[A-Z])',2)[0]
    if ($text -eq '-') { return 'Check not verified. See HTML report for details.' }
    if ($text.Length -gt 140) {
        $cut=$text.LastIndexOf(' ',110)
        if ($cut -le 0) { $cut=110 }
        $text=$text.Substring(0,$cut).TrimEnd()+ '... See HTML report for details.'
    }
    $text
}

function Add-AuditEntry {
    param ([int]$SectionNumber, [string]$SectionTitle, [string]$ItemTitle, [string]$ItemSub,
        [string]$Shortcut, [string]$FoundStateHtml, [string]$Status, [string]$ActionTaken, [switch]$DeferConsole)
    $auditRows.Add([PSCustomObject]@{
        SectionNumber = $SectionNumber; SectionTitle = $SectionTitle; ItemTitle = $ItemTitle
        ItemSub = $ItemSub; Shortcut = $Shortcut; FoundStateHtml = $FoundStateHtml
        Status = $Status; ActionTaken = $ActionTaken
    })
    if (-not $DeferConsole) { Write-ThoroughConsoleEntry -Row $auditRows[$auditRows.Count-1] -Number $auditRows.Count }
}

function Write-ThoroughConsoleEntry {
    param ($Row, [int]$Number)
    if((Get-Variable -Name BeforeApplyInspection -Scope Script -ErrorAction SilentlyContinue) -and $script:BeforeApplyInspection){return}
    $ItemTitle=$Row.ItemTitle; $ItemSub=$Row.ItemSub; $Status=$Row.Status
    $FoundStateHtml=$Row.FoundStateHtml; $ActionTaken=$Row.ActionTaken
    $legacyStopped=$Status -eq 'Offline' -and $ItemSub -eq 'Type: Old Payment Service'
    $label=if ($legacyStopped) { 'STOPPED' } else {
        switch ($Status) {
            'Pass' { 'PASS' }
            'Online' { 'ONLINE' }
            'Remediated' { 'FIXED' }
            'Fail' { 'FAIL' }
            'Offline' { 'OFFLINE' }
            'Bypass' { 'SKIP' }
            default { 'UNKNOWN' }
        }
    }
    $color=if ($legacyStopped -or $Status -eq 'Bypass') { 'DarkGray' } elseif ($Status -in @('Fail','Offline')) { 'Red' } elseif ($Status -in @('Pass','Online','Remediated')) { 'Green' } else { 'Yellow' }
    Write-Host ''
    Write-ThoroughConsoleLine ('[{0:D2}] {1,-7} {2}' -f $Number,$label,(Get-ThoroughReportComponentName $ItemTitle)) -Indent ' ' -Color $color
    if (-not $legacyStopped -and $Status -notin @('Pass','Online','Remediated')) {
        $note=Get-ThoroughConsoleNote -ItemTitle $ItemTitle -FoundStateHtml $FoundStateHtml -Status $Status -ActionTaken $ActionTaken
        Write-ThoroughConsoleLine $note -Indent (' '*14) -Color $color
    }
}

function Complete-ThoroughConsole {
    param ([bool]$IsApply, [int]$FailedCount, [bool]$IsFinal=$false)
    $mode=if ($IsFinal) { 'Thorough Check Report' } elseif ($IsApply) { 'Apply Fix' } else { 'Audit' }
    Write-Host ''
    Write-Host ('-'*60) -ForegroundColor DarkGray
    $message=if ($FailedCount -gt 0) { '{0} completed. {1} check(s) require attention.' -f $mode,$FailedCount } else { $mode+' completed.' }
    Write-ThoroughConsoleLine $message -Indent ' ' -Color $(if ($FailedCount -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host ''
}


function New-CheckResult {
    param ([string]$Status, [string]$Action, [string]$State)
    [pscustomobject]@{ Status = $Status; Action = $Action; State = $State }
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

function Get-ThoroughPayoutSchedules {
    param($Schedules,[string]$Provider)
    $selected=$Provider.Trim().ToUpperInvariant()
    if($selected -notin @('SIX','NETS','NEXIDE')){return}
    foreach($schedule in @($Schedules)){
        $scheduleProvider=([string](Get-ThoroughPaymentConfigValue $schedule 'Provider')).Trim().ToUpperInvariant()
        if($scheduleProvider -ceq $selected){$schedule}
    }
}

function New-ThoroughAppSettingsGroupRow {
    param ($Source, [string]$Name, [string]$ExpectedHtml, [string]$ObservedHtml, [bool]$Missing)
    [pscustomobject]@{
        SectionNumber=$Source.SectionNumber; SectionTitle=$Source.SectionTitle
        ItemTitle=$Name; ItemSub='appsettings.json'
        Shortcut=$Source.Shortcut; FoundStateHtml=$ObservedHtml; ExpectedHtml=$ExpectedHtml
        Status=$(if ($Missing) { 'Fail' } else { 'Pass' })
        ActionTaken=$(if ($Missing) { 'One or more values could not be collected; no configuration values changed' } else { 'Read only; no configuration values changed' })
    }
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
    $printExpected=ConvertTo-ReportDefinitionHtml ([ordered]@{ 'PrinterName'=''; 'KioskPrinterName'='' })
    $printValues=[ordered]@{}; $missing=$false
    foreach ($field in @('PrinterName','KioskPrinterName')) {
        $value=Get-ThoroughPaymentConfigValue $printConfig $field
        if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0 -and $field -ne 'TerminalId')) { $missing=$true }
        $printValues[$field]=Format-ThoroughPaymentAuditValue $value
    }
    New-ThoroughAppSettingsGroupRow $Source 'Print' $printExpected (ConvertTo-ReportDefinitionHtml $printValues) $missing
    foreach ($endpoint in @('MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')) {
        $value=Get-ThoroughPaymentConfigValue $config $endpoint
        $expectedHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{ $endpoint='' })
        $actualHtml=ConvertTo-ReportDefinitionHtml ([ordered]@{ $endpoint=(Format-ThoroughPaymentAuditValue $value) })
        New-ThoroughAppSettingsGroupRow $Source $endpoint $expectedHtml $actualHtml ([string]::IsNullOrWhiteSpace([string]$value))
    }
}

function New-ThoroughPrinterReportRow {
    param ([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][object[]]$Rows)
    $requirements=ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Printer Name'='BIXOLON or EPSON'; 'Printer status'='Active / Idle / Error'; 'Keep printed documents'='Enabled' })
    $findingParts=[Collections.Generic.List[string]]::new()
    $commands=[Collections.Generic.List[string]]::new()
    $seenCommands=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actions=[Collections.Generic.List[string]]::new()
    $multiple=$Rows.Count -gt 1
    $verified=$true
    $printerNumber=0
    foreach ($printer in $Rows) {
        $detected=$printer.ItemSub -eq 'Type: Receipt / POS Printer' -and -not [string]::IsNullOrWhiteSpace([string]$printer.ItemTitle)
        $name=if ($detected) { [string]$printer.ItemTitle } else { 'Not verified' }
        $blockTitle=if ($detected) { $printerNumber++; 'Printer '+$printerNumber } else { 'Not verified' }
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
        if($values.Count -eq 0){$verified=$false}
    }
    if($fields['Ports'] -like 'Not verified*' -and $missing.Count -gt 0 -and $unknown.Count -eq 0){$fields['Ports']='Not found'}
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

function ConvertTo-FirewallRuleObservation {
    param($Filter,$Rule)
    [pscustomobject]@{
        Direction=[string]$Rule.Direction
        Protocol=$(if([string]$Filter.Protocol -in @('TCP','6')){'TCP'}else{[string]$Filter.Protocol})
        Ports=@($Filter.LocalPort | ForEach-Object {[string]$_})
        Enabled=$(switch([string]$Rule.Enabled){'True'{'Yes'};'False'{'No'};default{[string]$Rule.Enabled}})
        Action=[string]$Rule.Action
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
        # AppSettings colors describe collected data, including False and zero.
        if($actual -match '(?i)\bnot\s+verified\b|\bmanual\s+action\s+required\b|^(?:unknown|unavailable)(?:[.\s(]|$)|\bnot available\b'){return 'unverified'}
        if(-not $actual -or $actual -eq '(empty)' -or $actual -match '(?i)^(?:Missing|Not found|Not detected|Not recorded|Not configured|Not readable)(?:[.!](?:\s.*)?)?$'){return 'unverified'}
        return 'collected'
    }
    $targeted=($Label -eq 'Launcher Path' -and $Requirements -and $Requirements.Contains('Launch Script') -and $Requirements['Launch Script'] -eq 'Available') -or
        ($Label -eq 'Location' -and $Requirements -and $Requirements.Contains('Location') -and $Requirements['Location'] -eq 'Path') -or
        ($Label -eq 'Version' -and $Requirements -and $Requirements.Contains('Version') -and $Requirements['Version'] -eq '0.0.0.0') -or
        ($Row.ItemTitle -in @('Payment Service Restart Task','PaymentService Restart Task') -and $Label -in @('Task Name','Trigger Time','Last Run','Next Run'))
    if(-not $targeted){return ''}
    $actual=([string]$Value).Trim()
    if($actual -match '(?i)\bnot\s+verified\b|^(?:unknown|unavailable)(?:[.\s(]|$)'){return 'unverified'}
    if(-not $actual -or $actual -match '(?i)^(?:Missing|Not found|Not detected|Not recorded|Not configured|Not readable|No trigger configured)(?:[.!](?:\s.*)?)?$'){return 'missing'}
    'collected'
}

function Get-ThoroughReportFindingComparison {
    param ($Row,[string]$Label,[string]$Value,[Collections.IDictionary]$Requirements,[string]$KioskAccountName)
    # Compare reported values only. Never query a device or derive the row status.
    if($Row.Status -eq 'Bypass'){return ''}
    $presence=Get-ThoroughReportCollectedValueState -Row $Row -Label $Label -Value $Value -Requirements $Requirements
    if($presence -eq 'collected'){return 'match'}
    if($presence -eq 'missing'){return 'mismatch'}
    if($presence -eq 'unverified'){return ''}
    $actual=$Value.Trim()
    if($Label -ieq 'Host name' -and $Row.ItemTitle -in @('Kiosk Launch Architecture','Zabbix Agent 2')){
        $expectedHost=if($Row.PSObject.Properties['ExpectedHostName']){[string]$Row.ExpectedHostName}elseif($Requirements -and $Requirements.Contains($Label)){[string]$Requirements[$Label]}else{'Not detected'}
        if(-not (Test-ThoroughHostname $expectedHost) -or -not (Test-ThoroughHostname $actual)){return 'unverified'}
        if($Row.ItemTitle -eq 'Zabbix Agent 2'){
            if($actual -ceq $expectedHost){return 'match'}
        }elseif($actual -ieq $expectedHost){return 'match'}
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
    elseif($Label -eq 'Tool State' -and $Row.ItemTitle -eq 'Nmap Diagnostic Tool'){$referenceLabel='Installed'}
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
        if($actual -eq 'Available' -or ($Label -eq 'Startup BAT' -and $actual -eq 'LaunchKiosk.bat') -or ($Label -eq 'Desktop Shortcut' -and $actual -eq 'Launch Kiosk.lnk')){return 'match'}
        return 'mismatch'
    }
    if($Label -eq 'Printer Name' -and $expected -eq 'BIXOLON or EPSON'){
        if($actual -match '^(?:BIXOLON|EPSON)(?:\b|[_-])'){return 'match'}
        return 'mismatch'
    }
    if($Label -eq 'Ports' -and $Row.ItemTitle -eq 'Firewall Inbound Port'){
        foreach($portText in ($expected -split ',\s*')){
            $covered=$false
            foreach($token in ($actual -split ',\s*')){
                if($token -in @('Any','*') -or $token -eq $portText){$covered=$true;break}
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
        elseif($presence -eq 'missing'){$description='Value not collected'}
        '<div class="finding-value finding-'+$comparison+'" title="'+$description+'">'+$field.Groups['Body'].Value+'</div>'
    })
    if($FindingsHtml.Trim() -eq 'Account Missing. Please create manually.'){
        return '<div class="finding-value finding-mismatch" title="Does not match required configuration">'+$FindingsHtml+'</div>'
    }
    if($highlighted -notmatch 'class="finding-value'){
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
    if($Row.ItemTitle -eq 'Kiosk Launch Task'){
        return ConvertTo-ReportDefinitionHtml ([ordered]@{'Task Name'='Launch Kiosk';'Task Status'='Active';'Target'='Existing kiosk launcher';'Trigger Time'='At user logon';'Last Run'='Informational';'Next Run'='Informational'})
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
        return ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Expected Names'='SubwayLocal or AspPaymentSubwayProd'; 'Service State'='Running'; 'Startup type'='Automatic'; 'First failure'='Restart the service'; 'Second failure'='Restart the service'; 'Subsequent failures'='Take No Action'; 'Version'='Readable' })
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
            [ordered]@{ 'Launch Script'='Available'; 'Restaurant ID'='Configured'; 'Kiosk ID'='Configured'; 'Host name'=$(if($Row.PSObject.Properties['ExpectedHostName']){$Row.ExpectedHostName}else{'Not detected'}); 'URL origin'='https://kiosk.subway.ch' }; break
        }
        '^SELISE-KIOSK Startup Folder$' { [ordered]@{ 'Location'='Path'; 'Startup BAT'='Available'; 'Desktop Shortcut'='Available' }; break }
        '^Kiosk Auto-Login$' {
            [ordered]@{ 'Automatic Sign-In'='Enabled'; 'Default User'='Kiosk account'; 'Default Domain'='Local computer'; 'Automatic Sign-In Limit'='Unlimited' }; break
        }
        '^System & Browser Policies$' {
            [ordered]@{ 'Local Network Allowlist'='https://kiosk.subway.ch'; 'Translation'='Disabled'; 'Visual Search'='Disabled'; 'Edge Gestures'='Disabled'; 'Pinch-to-Zoom'='Disabled' }; break
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
            'Type: Receipt / POS Printer' { [ordered]@{ 'Printer Name'='BIXOLON or EPSON'; 'Printer status'='Active / Idle / Error'; 'Keep printed documents'='Enabled' } }
            'Type: Receipt / Hardware' { [ordered]@{ 'Printer Name'='BIXOLON or EPSON'; 'Printer status'='Active / Idle / Error'; 'Keep printed documents'='Enabled' } }
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

function Test-ThoroughHostname {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253){return $false}
    foreach($label in $Value.Split('.')){
        if($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$'){return $false}
    }
    return $true
}

function Read-ThoroughFixHostname {
    param([string]$SuggestedName,[string]$SuppliedName)
    if(-not (Test-CanApply)){throw 'Hostname input is available only during Apply Fix.'}
    if(-not [string]::IsNullOrWhiteSpace($SuppliedName)){
        $name=$SuppliedName.Trim()
        if(-not (Test-ThoroughHostname $name)){throw 'The supplied hostname is invalid.'}
        return $name
    }
    do {
        $prompt=if(Test-ThoroughHostname $SuggestedName){
            Write-Host 'Press Enter to keep it, or type a different hostname.' -ForegroundColor Gray
            'Hostname ['+$SuggestedName+']'
        }else{'Hostname'}
        $name=([string](Read-Host $prompt)).Trim()
        if(-not $name -and (Test-ThoroughHostname $SuggestedName)){$name=$SuggestedName}
        if(Test-ThoroughHostname $name){return $name}
        Write-Host 'Enter a valid hostname, or press Enter to confirm the suggested name.' -ForegroundColor Yellow
    } while($true)
}

function Read-ThoroughTextFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    foreach($entry in @($full,[IO.Path]::GetDirectoryName($full))){
        if(([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked configuration path requires manual review.'}
    }
    $bytes=[IO.File]::ReadAllBytes($full)
    $encoding=[Text.UTF8Encoding]::new($false,$true);$offset=0
    if($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0){$encoding=[Text.UTF32Encoding]::new($false,$true,$true);$offset=4}
    elseif($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255){$encoding=[Text.UTF32Encoding]::new($true,$true,$true);$offset=4}
    elseif($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){$offset=3}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254){$encoding=[Text.UnicodeEncoding]::new($false,$true,$true);$offset=2}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255){$encoding=[Text.UnicodeEncoding]::new($true,$true,$true);$offset=2}
    [pscustomobject]@{Path=$full;Bytes=$bytes;Encoding=$encoding;PreambleLength=$offset;Text=$encoding.GetString($bytes,$offset,$bytes.Length-$offset)}
}

function Write-ThoroughTextChange {
    param([Parameter(Mandatory=$true)]$Original,[Parameter(Mandatory=$true)][string]$Text,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Configuration writes are disabled outside Apply Fix.'}
    if($Text -ceq $Original.Text){return [pscustomobject]@{Changed=$false;BackupPath=$null}}
    if([string]::IsNullOrWhiteSpace($BackupFolder)){
        $BackupFolder='C:\Thorough Check\Restore Points'
    }
    $body=$Original.Encoding.GetBytes($Text)
    $candidate=[byte[]]::new($Original.PreambleLength+$body.Length)
    if($Original.PreambleLength){[Buffer]::BlockCopy($Original.Bytes,0,$candidate,0,$Original.PreambleLength)}
    [Buffer]::BlockCopy($body,0,$candidate,$Original.PreambleLength,$body.Length)
    $stream=$null;$started=$false;$backup=$null
    try {
        $stream=[IO.File]::Open($Original.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $current=Read-KioskPinchStream $stream
        if([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'The configuration changed during inspection; no changes were made.'}
        [void][IO.Directory]::CreateDirectory($BackupFolder)
        $backup=Join-Path $BackupFolder ([IO.Path]::GetFileName($Original.Path)+'.'+[guid]::NewGuid().ToString('N')+'.bak')
        $backupStream=[IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$backupStream.Write($Original.Bytes,0,$Original.Bytes.Length);$backupStream.Flush($true)}finally{$backupStream.Dispose()}
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'Configuration backup verification failed.'}
        $started=$true
        Write-KioskPinchStream -Stream $stream -Bytes $candidate
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($candidate)){throw 'Configuration write readback failed.'}
    } catch {
        $reason=$_.Exception.Message
        if($started){
            try {
                Write-KioskPinchStream -Stream $stream -Bytes $Original.Bytes
                if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'Restore readback failed.'}
                $reason+=' Original configuration restored.'
            } catch {$reason+=' Original configuration restoration could not be verified. Please check manually.'}
        }
        throw $reason
    } finally {if($stream){$stream.Dispose()}}
    [pscustomobject]@{Changed=$true;BackupPath=$backup;Path=$Original.Path;BeforeBytes=$Original.Bytes;AfterBytes=$candidate}
}

function Restore-ThoroughTextChange {
    param([Parameter(Mandatory=$true)]$Change)
    if(-not (Test-CanApply)){throw 'Configuration restoration requires Apply Fix.'}
    $stream=[IO.File]::Open($Change.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Change.AfterBytes)){throw 'The configuration changed again; automatic restoration was stopped.'}
        Write-KioskPinchStream -Stream $stream -Bytes $Change.BeforeBytes
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Change.BeforeBytes)){throw 'Restoration readback failed.'}
    } finally {$stream.Dispose()}
}

function Set-KioskLauncherHostname {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Hostname,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Launcher repair is disabled outside Apply Fix.'}
    if(-not (Test-ThoroughHostname $Hostname)){throw 'The confirmed launcher hostname is invalid.'}
    $original=Read-ThoroughTextFile $Path
    if($original.Text -match '(?im)^# SIG # Begin signature block'){throw 'The launcher is signed; hostname changes require manual review.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($original.Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The launcher has invalid syntax; no changes made.'}
    $strings=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -or ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0)},$true))
    $targets=@(foreach($literal in $strings){foreach($url in [regex]::Matches($literal.Value,'https://[A-Za-z0-9.-]+/[^\s"'']*')){[pscustomobject]@{Literal=$literal;Url=$url.Value}}})
    if($targets.Count -ne 1){throw 'A single static launcher URL could not be verified; no hostname changed.'}
    $target=$targets[0]
    $inspection=Resolve-KioskUrl -Url $target.Url
    if($inspection.Issues.Count){throw (($inspection.Issues -join '; ')+'. No hostname changed.')}
    $match=[regex]::Match($target.Url,'[?&]host=(?<Value>[^&#]*)')
    if(-not $match.Success){throw 'A unique host parameter is required.'}
    $old=[uri]::UnescapeDataString($match.Groups['Value'].Value.Replace('+',' '))
    if($old -ieq $Hostname){return [pscustomobject]@{Changed=$false;BackupPath=$null;PreviousHostname=$old;Hostname=$Hostname}}
    $url=$target.Url.Remove($match.Groups['Value'].Index,$match.Groups['Value'].Length).Insert($match.Groups['Value'].Index,[uri]::EscapeDataString($Hostname))
    $raw=$target.Literal.Extent.Text
    if([regex]::Matches($raw,[regex]::Escape($target.Url)).Count -ne 1){throw 'An escaped or ambiguous launcher URL requires manual review.'}
    $replacement=$raw.Replace($target.Url,$url)
    $updated=$original.Text.Remove($target.Literal.Extent.StartOffset,$raw.Length).Insert($target.Literal.Extent.StartOffset,$replacement)
    $null=[Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The proposed launcher failed syntax validation.'}
    $change=Write-ThoroughTextChange -Original $original -Text $updated -BackupFolder $BackupFolder
    $change|Add-Member NoteProperty PreviousHostname $old
    $change|Add-Member NoteProperty Hostname $Hostname
    return $change
}

function Get-ZabbixHostnameSetting {
    param([string]$CommandLine,[string]$DefaultConfigurationPath=(Join-Path $env:ProgramFiles 'Zabbix Agent 2\zabbix_agent2.conf'))
    if([string]::IsNullOrWhiteSpace($CommandLine)){throw 'The Zabbix service command line is unavailable.'}
    $match=[regex]::Match($CommandLine,'(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))')
    $root=if($match.Success){if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}}else{$DefaultConfigurationPath}
    $root=[Environment]::ExpandEnvironmentVariables($root)
    if(-not [IO.Path]::IsPathRooted($root)){throw 'A relative Zabbix configuration path requires manual review.'}
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($root)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $settings=[Collections.Generic.List[object]]::new()
    while($pending.Count){
        $path=$pending.Dequeue()
        if(-not $seen.Add([IO.Path]::GetFullPath($path))){continue}
        if($seen.Count -gt 100){throw 'Too many Zabbix configuration includes.'}
        $file=Read-ThoroughTextFile $path
        foreach($line in [regex]::Matches($file.Text,'(?m)^[^\r\n]*')){
            $entry=[regex]::Match($line.Value,'^\s*Hostname\s*=\s*(?<Value>[^\r\n]*?)\s*$')
            if($entry.Success){
                if([string]::IsNullOrWhiteSpace($entry.Groups['Value'].Value) -or $entry.Groups['Value'].Value.Contains(',')){throw 'An empty or multi-host Hostname setting requires manual review.'}
                $settings.Add([pscustomobject]@{File=$file;Value=$entry.Groups['Value'].Value;Offset=$line.Index+$entry.Groups['Value'].Index;Length=$entry.Groups['Value'].Length})
            } elseif($line.Value -match '^\s*Include\s*=\s*(.+?)\s*$'){
                $include=[Environment]::ExpandEnvironmentVariables($Matches[1])
                if(-not [IO.Path]::IsPathRooted($include)){$include=Join-Path ([IO.Path]::GetDirectoryName($root)) $include}
                foreach($included in @(Get-ChildItem -Path $include -File -ErrorAction Stop)){$pending.Enqueue($included.FullName)}
            }
        }
    }
    if($settings.Count -ne 1){throw 'A single explicit Zabbix Hostname setting is required; dynamic or multiple settings need manual review.'}
    return $settings[0]
}

function Set-ZabbixDeviceHostname {
    param([Parameter(Mandatory=$true)][string]$CommandLine,[Parameter(Mandatory=$true)][string]$Hostname,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Zabbix hostname repair is disabled outside Apply Fix.'}
    if(-not (Test-ThoroughHostname $Hostname)){throw 'The Windows device hostname could not be verified.'}
    $setting=Get-ZabbixHostnameSetting -CommandLine $CommandLine
    if($setting.Value -ceq $Hostname){return [pscustomobject]@{Changed=$false;BackupPath=$null}}
    $text=$setting.File.Text.Remove($setting.Offset,$setting.Length).Insert($setting.Offset,$Hostname)
    $change=Write-ThoroughTextChange -Original $setting.File -Text $text -BackupFolder $BackupFolder
    try {
        if((Get-ZabbixConfiguredHostname -CommandLine $CommandLine) -cne $Hostname){throw 'Zabbix hostname readback did not match the Windows hostname.'}
        $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        if($service.Status -ne 'Running'){throw 'The Zabbix service is not running; hostname activation could not be verified.'}
        Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
        if((Get-ZabbixConfiguredHostname -CommandLine $CommandLine) -cne $Hostname){throw 'Zabbix hostname changed during service verification.'}
    } catch {
        $reason=$_.Exception.Message
        try {
            Restore-ThoroughTextChange $change
            $reason+=' Previous Zabbix configuration restored.'
            $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
            if($service.Status -eq 'Running'){Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
            else {Start-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
            (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
        } catch {$reason+=' Zabbix restoration/service state requires manual verification.'}
        throw $reason
    }
    return $change
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

function Get-ThoroughFixAccountBeforeView {
    param($Row,$BeforeView,$AfterView,[string]$RequirementHtml)
    if(-not $BeforeView -or -not @($BeforeView.Records).Count){return $null}
    $records=[Collections.Generic.List[object]]::new()
    foreach($record in $BeforeView.Records){$records.Add($record)}
    if($AfterView){
        foreach($record in $AfterView.Records){
            if(-not @($records|Where-Object {$_.AccountName -ieq $record.AccountName}).Count){$records.Add($record)}
        }
    }
    $metadata=if($Row.PSObject.Properties['AccountResults']){@($Row.AccountResults)}else{@()}
    $findings=[Collections.Generic.List[string]]::new()
    $applied=[Collections.Generic.List[string]]::new()
    $names=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $records.Count;$index++){
        $account=$records[$index]
        $own=@($metadata|Where-Object {$_ -and $_.PSObject.Properties['AccountName'] -and $_.AccountName -ieq $account.AccountName})
        $result=$Row|Select-Object *
        $uncertain=$own.Count -ne 1 -or -not $own[0].PSObject.Properties['Status'] -or [string]::IsNullOrWhiteSpace([string]$own[0].Status)
        if($uncertain){$result.Status='Unknown';$result.ActionTaken='Account-specific results were not verified. Manual action required.'}
        else {$result.Status=[string]$own[0].Status;$result.ActionTaken=[Net.WebUtility]::HtmlEncode([string]$own[0].Action)}
        $state=Format-ThoroughReportFieldLabels ([string]$account.FindingsHtml)
        $state=Format-ThoroughReportFindingHighlights -Row $Row -FindingsHtml $state -RequirementHtml $RequirementHtml
        $action=Get-ThoroughReportAppliedHtml -Row $result -FindingsHtml $state
        $keep=Test-ThoroughFixReportRow -Row $result -FindingsHtml $state -AppliedHtml $action -AfterApply $true
        if(-not $uncertain -and $own[0].PSObject.Properties['AccountPolicyChanged'] -and $own[0].AccountPolicyChanged -eq $true){$keep=$true}
        if(-not $keep){continue}
        $findingRecord=$result|Select-Object *
        $findingRecord.Status=if($state -match 'finding-(?:mismatch|unverified)'){'Fail'}else{'Pass'}
        $findingRecord.ActionTaken=''
        $body=Format-ThoroughFixFindings -Row $findingRecord -FindingsHtml $state -RequirementHtml $RequirementHtml -AfterApply $false -RecordScope $true
        $heading=Format-ThoroughReportFieldLabels ([string]$account.HeadingHtml)
        if(-not $heading -and $records.Count -gt 1){$heading='<div class="config-item-title">Account '+($index+1).ToString('D2')+'</div>'}
        if($uncertain){$action='<div class="applied-result"><strong>Not Verified</strong><div>Account-specific results are unavailable. Please check manually.</div></div>'}
        $findings.Add($heading+$body);$applied.Add($heading+$action);$names.Add([string]$account.AccountName)
    }
    [pscustomobject]@{RetainedCount=$findings.Count;FindingsHtml=($findings -join '<hr class="block-divider">');AppliedHtml=($applied -join '<hr class="block-divider">');CommandHtml=(ConvertTo-ReportCommandBoxes (New-AccountReportCommand -AccountNames $names.ToArray()))}
}

function Test-ThoroughAppSettingsReview {
    param($Row)
    $fields=@([regex]::Matches([string]$Row.FoundStateHtml,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>[^<]*)'))
    if(-not $fields.Count){
        $value=Convert-ReportHtmlToTerminalText ([string]$Row.FoundStateHtml)
        return (Get-ThoroughReportCollectedValueState -Row $Row -Label '' -Value $value -Requirements @{}) -ne 'collected'
    }
    foreach($field in $fields){
        $label=[Net.WebUtility]::HtmlDecode($field.Groups['Label'].Value)
        $value=[Net.WebUtility]::HtmlDecode($field.Groups['Value'].Value)
        if((Get-ThoroughReportCollectedValueState -Row $Row -Label $label -Value $value -Requirements @{}) -ne 'collected'){return $true}
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

function Add-ResultEntry {
    param ([int]$Section, [string]$Title, [string]$Item, [object]$Result)
    $shortcut = ''
    $stateHtml = [Net.WebUtility]::HtmlEncode($Result.State)
    $actionHtml = [Net.WebUtility]::HtmlEncode($Result.Action)
    if ($Result.PSObject.Properties['StateHtml']) { $stateHtml = $Result.StateHtml }
    if ($Result.PSObject.Properties['Shortcut']) { $shortcut = $Result.Shortcut }
    if ($Item -in @('Kiosk Auto-Login', 'System & Browser Policies')) { $shortcut = '<code>regedit</code>' }
    if ($Item -eq 'Kiosk Auto-Login') {
        $shortcut = New-ReportCommand @('regedit', 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon', 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName')
    }
    if ($Item -eq 'System & Browser Policies') {
        $shortcut = New-ReportCommand @('regedit', 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Edge" /s', 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" /v AllowEdgeSwipe')
    }
    if ($Result.PSObject.Properties['DetectedAccountNames'] -or $Result.PSObject.Properties['AccountName']) {
        $names=if ($Result.PSObject.Properties['DetectedAccountNames']) { @($Result.DetectedAccountNames) } else { @([string]$Result.AccountName) }
        $shortcut=New-AccountReportCommand -AccountNames $names
        if ($Result.PSObject.Properties['StateHtml']) { $stateHtml = $Result.StateHtml }
        $actionHtml = [Net.WebUtility]::HtmlEncode($Result.Action)
    }
    $rowCountBefore = if ($Result.PSObject.Properties['AccountResults']) { $auditRows.Count } else { -1 }
    Add-AuditEntry -SectionNumber $Section -SectionTitle $Title -ItemTitle $Item -ItemSub 'Verified configuration' `
        -Shortcut $shortcut -FoundStateHtml $stateHtml `
        -Status $Result.Status -ActionTaken $actionHtml
    # Attach metadata only to the row just created for this exact component.
    if ($Result.PSObject.Properties['AccountResults'] -and $auditRows.Count -eq ($rowCountBefore + 1)) {
        $row = $auditRows[$rowCountBefore]
        if ($row.SectionNumber -eq $Section -and $row.SectionTitle -eq $Title -and $row.ItemTitle -eq $Item) {
            $row | Add-Member -NotePropertyName AccountResults -NotePropertyValue @($Result.AccountResults)
        }
    }
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
            [regex]::Matches($_.Value, 'https://[A-Za-z0-9.-]+/[^\s"'']*') | ForEach-Object { $_.Value }
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
        'Restaurant ID'=$values['Restaurant ID']
        'Kiosk ID'=$values['KIOSK ID']
        'Host name'=$values['Host Name']
        'URL origin'=$urlOrigin
    }
    $html = ConvertTo-ReportDefinitionHtml $displayValues
    $Result | Add-Member -NotePropertyName StateHtml -NotePropertyValue $html -Force
    $Result | Add-Member -NotePropertyName LauncherValues -NotePropertyValue $values -Force
    $Result | Add-Member -NotePropertyName Shortcut -NotePropertyValue ('<code>' + [Net.WebUtility]::HtmlEncode(('notepad "{0}"' -f $Path)) + '</code>') -Force
    return $Result
}

function Resolve-KioskUrl {
    param([string]$Url,[string]$Restaurant,[string]$Kiosk,[string]$Hostname)
    $issues=[Collections.Generic.List[string]]::new()
    $blocked=[Collections.Generic.List[string]]::new()
    $missing=[Collections.Generic.List[string]]::new()
    $parameters=@{}
    $queryStart=$Url.IndexOf('?')
    $prefix=if ($queryStart -ge 0) {$Url.Substring(0,$queryStart)} else {$Url}
    if ($prefix -ine 'https://kiosk.subway.ch/#/onboarding/login') {$blocked.Add('Unexpected Subway kiosk URL path')}
    if (-not $Url.StartsWith('https://kiosk.subway.ch/',[StringComparison]::OrdinalIgnoreCase)) {$blocked.Add('Unexpected kiosk URL origin')}
    if ($queryStart -ge 0) {
        foreach ($part in $Url.Substring($queryStart+1).Split('&')) {
            if (-not $part) {continue}
            $pair=$part -split '=',2
            $key=[uri]::UnescapeDataString($pair[0]).ToLowerInvariant()
            if ($key -notin @('restaurantid','kioskid','host','hostname')) {continue}
            if (-not $parameters.ContainsKey($key)) {$parameters[$key]=@()}
            $parameters[$key]+=$(if ($pair.Count -eq 2) {[uri]::UnescapeDataString($pair[1].Replace('+',' ')).Trim()} else {''})
            $canonical=@{restaurantid='restaurantId';kioskid='kioskId';host='host';hostname='hostname'}[$key]
            if ($pair[0] -cne $canonical) {$blocked.Add("Noncanonical $canonical parameter")}
        }
    }
    if ($parameters.ContainsKey('hostname')) {$blocked.Add('Unsupported hostname parameter requires manual review')}
    foreach ($key in @('restaurantId','kioskId','host')) {
        $values=@($parameters[$key.ToLowerInvariant()])
        if ($values.Count -gt 1) {$blocked.Add("Duplicate or conflicting $key")}
        elseif (-not $values.Count -or [string]::IsNullOrWhiteSpace([string]$values[0])) {$missing.Add($key)}
    }
    foreach ($issue in $blocked) {$issues.Add($issue)}
    foreach ($key in $missing) {$issues.Add('Missing '+$key)}
    [pscustomobject]@{URL=$Url;Issues=@($issues);BlockedIssues=@($blocked);Missing=@($missing)}
}





function Repair-LauncherDetails {
    param([string]$Path,[string]$ShortcutPath,[string]$Restaurant,[string]$Kiosk,[string]$Hostname)
    # Inspect existing values; Apply may update only the confirmed host parameter.
    $result=Add-LauncherReportDetails (New-CheckResult 'Fail' 'Launcher inspected; existing values preserved.' '') $Path $ShortcutPath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {$result.Action='Launcher script is missing. Manual action required.';return $result}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {$result.Action='Launcher syntax is invalid. Manual action required.';return $result}
    $url=$result.LauncherValues['URL']
    if ($url -eq 'Not detected') {$result.Action='A single supported static URL was not identified. Manual action required.';return $result}
    $inspection=Resolve-KioskUrl -Url $url
    if ($inspection.Issues.Count) {$result.Action=($inspection.Issues -join '; ')+'. Manual action required. No launcher values changed.';return $result}
    $expected=if(Test-CanApply){$Hostname}else{Get-ThoroughDeviceHostname}
    if(-not (Test-ThoroughHostname $expected)){$result.Action='The expected device/launcher hostname is not verified. Manual action required.';return $result}
    if($result.LauncherValues['Host Name'] -ine $expected){
        if(-not (Test-CanApply)){$result.Action='Launcher hostname differs from the Windows device hostname. Apply Fix can update the host parameter.';return $result}
        try {
            $change=Set-KioskLauncherHostname -Path $Path -Hostname $expected
            $result=Add-LauncherReportDetails $result $Path $ShortcutPath
            if($result.LauncherValues['Host Name'] -ine $expected){throw 'Launcher hostname readback failed.'}
            $result.Action='Updated launcher hostname from '+$change.PreviousHostname+' to '+$expected+'; readback verified. Backup: '+$change.BackupPath+'. Restart Edge to load the updated launcher.'
        } catch {$result.Action='Launcher hostname could not be fully verified: '+$_.Exception.Message+' Manual action required.';return $result}
    }else{$result.Action='Existing launcher values verified without changes. Verify operation after sign-in.'}
    $result.Status='Pass'
    return $result
}

function Get-LocalAccount {
    param ([string]$UserName)
    # Enumerate with terminating errors: access/command errors must not look like a missing account.
    @(Get-LocalUser -ErrorAction Stop) | Where-Object { $_.Name -ieq $UserName } | Select-Object -First 1
}

function Get-LocalAccountProperties {
    param ([Parameter(Mandatory = $true)][string]$UserName)
    $entry = Open-ThoroughLocalAccount $UserName
    $rawFlags = $entry.InvokeGet('UserFlags')
    $expired = $entry.InvokeGet('PasswordExpired')
    $locked = $entry.InvokeGet('IsAccountLocked')
    if ($null -eq $rawFlags -or $null -eq $expired -or $null -eq $locked) {
        throw "Account properties could not all be read for $UserName."
    }
    $flags = [int]$rawFlags
    [pscustomobject]@{
        PasswordNeverExpires = [bool]($flags -band 0x10000)
        UserCannotChangePassword = [bool]($flags -band 0x40)
        MustChangePassword = [bool]$expired
        Disabled = [bool]($flags -band 0x2)
        LockedOut = [bool]$locked
    }
}

function Get-LocalAdministratorSidSet {
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @(Get-LocalGroupMember -Group $administrators -ErrorAction Stop)) {
        if ($member.SID) { [void]$set.Add([string]$member.SID.Value) }
    }
    return ,$set
}

function Get-LocalAccountPrivilege {
    param ([Parameter(Mandatory = $true)]$Account, [Parameter(Mandatory = $true)]$AdministratorSids)
    if ($AdministratorSids.Contains([string]$Account.SID.Value)) { return 'Local Administrator' }
    return 'Standard Local User'
}

function Get-AdministrativeLocalAccounts {
    $administratorSids = Get-LocalAdministratorSidSet
    $accounts = @(Get-LocalUser -ErrorAction Stop | Where-Object {
        $_.Name -ieq 'Admin' -or $_.Name -ieq 'Administrator' -or ($_.Enabled -and $administratorSids.Contains([string]$_.SID.Value))
    } | Sort-Object -Property @{Expression={if ($_.Name -ieq 'Admin') {0} elseif ($_.Name -ieq 'Administrator') {1} else {2}}},Name)
    $activeAccounts=@($accounts | Where-Object { $_.Enabled })
    if ($activeAccounts.Count) { $accounts=$activeAccounts }
    [pscustomobject]@{ Accounts = $accounts; AdministratorSids = $administratorSids }
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

function New-MissingAccountResult {
    param ([Parameter(Mandatory = $true)][string]$RequestedName, [string]$Privilege = 'Not available', [switch]$Administrative)
    $result = New-CheckResult 'Fail' "Account Missing. Please create manually: $RequestedName. No account was created." 'Account missing'
    $result | Add-Member -NotePropertyName AccountName -NotePropertyValue $RequestedName
    $result | Add-Member -NotePropertyName DetectedAccountNames -NotePropertyValue ([string[]]@())
    $result | Add-Member -NotePropertyName Shortcut -NotePropertyValue (New-AccountReportCommand -AccountNames @())
    $state=[ordered]@{'Account Name'=$RequestedName;'Account Privilege'=$Privilege;'Account Status'='Missing';'Password Never Expires'='Not applicable'}
    if(-not $Administrative){$state['User Cannot Change Password']='Not applicable'}
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue (ConvertTo-ReportDefinitionHtml $state)
    return $result
}

function Open-ThoroughLocalAccount {
    param([Parameter(Mandatory=$true)][string]$UserName)
    $entry=[ADSI]('WinNT://{0}/{1},user' -f $env:COMPUTERNAME,$UserName)
    return ,$entry
}

function Enable-LocalAccountPasswordFlags {
    param([Parameter(Mandatory=$true)][string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword,[switch]$AllowPasswordChange)
    if(-not (Test-CanApply)){throw 'Account changes are disabled outside Apply Fix.'}
    if($UserCannotChangePassword -and $AllowPasswordChange){throw 'Conflicting password-change settings were requested.'}
    # Change only approved UserFlags bits; keep identity, activation and unrelated flags intact.
    # https://learn.microsoft.com/windows/win32/adsi/modifying-user-cannot-change-password-winnt-provider
    $entry=Open-ThoroughLocalAccount $UserName
    $raw=$entry.InvokeGet('UserFlags')
    if($null -eq $raw){throw 'The existing account flags could not be read; nothing was changed.'}
    $before=[int]$raw;$setMask=0;$clearMask=0
    if($PasswordNeverExpires){$setMask=$setMask -bor 0x10000}
    if($UserCannotChangePassword){$setMask=$setMask -bor 0x40}
    if($AllowPasswordChange){$clearMask=0x40}
    $managedMask=$setMask -bor $clearMask
    $target=($before -bor $setMask) -band (-bnot $clearMask)
    if($target -eq $before){return [pscustomobject]@{Changed=$false;BeforeFlags=$before;AfterFlags=$before}}
    $entry.Put('UserFlags',$target)
    $entry.SetInfo()
    $entry.RefreshCache(@('UserFlags'))
    $readback=$entry.InvokeGet('UserFlags')
    if($null -eq $readback){throw 'The password settings could not be read back after update.'}
    $after=[int]$readback
    if(($after -band $setMask) -ne $setMask -or ($after -band $clearMask) -ne 0){throw 'The requested password settings were not verified after update.'}
    if(($after -band (-bnot $managedMask)) -ne ($before -band (-bnot $managedMask))){throw 'An unrelated account flag changed; manual verification is required.'}
    [pscustomobject]@{Changed=$true;BeforeFlags=$before;AfterFlags=$after}
}

function Invoke-ExistingAccountPolicy {
    param([Parameter(Mandatory=$true)]$Account,[Parameter(Mandatory=$true)]$AdministratorSids,[switch]$ReportPrivilegeOnly,[switch]$Administrative)
    $privilege=Get-LocalAccountPrivilege -Account $Account -AdministratorSids $AdministratorSids
    $administrativePolicy=$Administrative -or $privilege -eq 'Local Administrator' -or $Account.Name -in @('Admin','Administrator')
    $requireCannot=-not $administrativePolicy
    $properties=Get-LocalAccountProperties -UserName $Account.Name
    if($null -eq $properties -or $null -eq $properties.PasswordNeverExpires -or $null -eq $properties.UserCannotChangePassword){throw 'Required account properties could not be verified; no changes made.'}
    $beforeNever=[bool]$properties.PasswordNeverExpires
    $beforeCannot=[bool]$properties.UserCannotChangePassword
    $changes=[Collections.Generic.List[string]]::new()
    $failure=$null;$write=$null
    $needsPasswordChange=if($administrativePolicy){$beforeCannot}else{-not $beforeCannot}
    if($Account.Enabled -and (Test-CanApply) -and (-not $beforeNever -or $needsPasswordChange)){
        try {
            $write=Enable-LocalAccountPasswordFlags -UserName $Account.Name -PasswordNeverExpires:(-not $beforeNever) -UserCannotChangePassword:($requireCannot -and -not $beforeCannot) -AllowPasswordChange:$administrativePolicy
        } catch {$failure=$_.Exception.Message}
        try {$properties=Get-LocalAccountProperties -UserName $Account.Name}
        catch {
            $properties=[pscustomobject]@{PasswordNeverExpires=$null;UserCannotChangePassword=$null}
            $failure=(@($failure,'Password-setting readback could not be completed: '+$_.Exception.Message)|Where-Object {$_}) -join '; '
        }
        if(-not $beforeNever -and $properties.PasswordNeverExpires -eq $true){$changes.Add('Enabled Password Never Expires')}
        if($requireCannot -and -not $beforeCannot -and $properties.UserCannotChangePassword -eq $true){$changes.Add('Enabled User Cannot Change Password')}
        if($administrativePolicy -and $beforeCannot -and $properties.UserCannotChangePassword -eq $false){$changes.Add('Allowed password changes')}
    }
    $verified=$properties.PasswordNeverExpires -eq $true -and $(if($administrativePolicy){$properties.UserCannotChangePassword -eq $false}else{$properties.UserCannotChangePassword -eq $true})
    $status=if($verified -and -not $failure){'Pass'}else{'Fail'}
    if($failure){
        $action=(@(($changes -join '; '),('Password settings update could not be fully verified: '+$failure),'Manual action required')|Where-Object {$_}) -join '; '
    } elseif(-not $Account.Enabled -and -not $verified){$action='Disabled account; password properties inspected without changes. Required password properties are not enabled. Manual review required.'}
    elseif($changes.Count -and $verified){$action=($changes -join '; ')+'; readback verified'}
    elseif($verified){$action='Requested password settings are enabled; no changes needed'}
    elseif(Test-CanApply){$action='Required password settings were not verified after Apply; account identity, privilege and enabled state were preserved. Manual action required.'}
    elseif($requireCannot){$action='Audit only: Password Never Expires and User Cannot Change Password must both be enabled'}
    else {$action='Audit only: Password Never Expires must be enabled and password changes must be allowed'}
    $never=if($null -eq $properties.PasswordNeverExpires){'Not verified'}elseif($properties.PasswordNeverExpires){'Enabled'}else{'Disabled'}
    $state=[ordered]@{
        'Account Name'=[string]$Account.Name;'Account Privilege'=$privilege
        'Account Status'=$(if($Account.Enabled){'Enabled'}else{'Disabled'})
        'Password Never Expires'=$never
    }
    if($requireCannot){
        $state['User Cannot Change Password']=if($null -eq $properties.UserCannotChangePassword){'Not verified'}elseif($properties.UserCannotChangePassword){'Enabled'}else{'Disabled'}
    }
    $result=New-CheckResult $status $action 'Account present'
    $result|Add-Member NoteProperty AccountName ([string]$Account.Name)
    $result|Add-Member NoteProperty AccountPolicyChanged ([bool]($changes.Count -or ($write -and $write.Changed)))
    $result|Add-Member NoteProperty DetectedAccountNames @([string]$Account.Name)
    $result|Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml $state)
    return $result
}


function Get-TargetLocalAccounts {
    param ([Parameter(Mandatory = $true)][string[]]$Names)
    $allAccounts = @(Get-LocalUser -ErrorAction Stop)
    foreach ($name in $Names) {
        $account = @($allAccounts | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        [pscustomobject]@{ RequestedName = $name; Account = $account }
    }
}

function Join-AccountCheckResults {
    param ([object[]]$Results, [string]$MissingName)
    if (@($Results).Count -eq 0) { return New-MissingAccountResult -RequestedName $MissingName }
    $status = if (@($Results | Where-Object { $_.Status -ne 'Pass' }).Count) { 'Fail' } else { 'Pass' }
    $result = New-CheckResult $status '' 'Account properties recorded'
    $states = foreach ($entry in $Results) {
        if ($entry.PSObject.Properties['StateHtml']) { $entry.StateHtml }
        else { '<div>' + [Net.WebUtility]::HtmlEncode($entry.State) + '</div>' }
    }
    $actions = foreach ($entry in $Results) {
        $name = if ($entry.PSObject.Properties['AccountName']) { $entry.AccountName } else { 'Account' }
        $name + ': ' + $entry.Action
    }
    $result.Action = $actions -join '; '
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue ('<div class="account-stack">' + ($states -join '<hr>') + '</div>')
    $detectedNames=@(foreach ($entry in $Results) {
        if ($entry.PSObject.Properties['DetectedAccountNames']) { $entry.DetectedAccountNames }
        elseif ($entry.PSObject.Properties['AccountName']) { [string]$entry.AccountName }
    })
    $result | Add-Member -NotePropertyName DetectedAccountNames -NotePropertyValue $detectedNames
    $result | Add-Member -NotePropertyName Shortcut -NotePropertyValue (New-AccountReportCommand -AccountNames $detectedNames)
    # Preserve each account result for report projections; aggregate outcomes are unchanged.
    $result | Add-Member -NotePropertyName AccountResults -NotePropertyValue @($Results)
    return $result
}

function Get-KioskAutoLoginUserName {
    $path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    $domain=[string]$key.GetValue('DefaultDomainName')
    if ($key.GetValue('AutoAdminLogon') -eq '1' -and ([string]::IsNullOrWhiteSpace($domain) -or $domain -eq '.' -or $domain -ieq $env:COMPUTERNAME)) { return [string]$key.GetValue('DefaultUserName') }
    return $null
}

function Get-KioskAccountCheck {
    # Discover existing kiosk users; Apply changes only the two required password properties.
    $users=@(Get-LocalUser -ErrorAction Stop)
    $autoLoginUser=try {Get-KioskAutoLoginUserName} catch {$null}
    $candidates=@(foreach ($user in $users) {
        $known=$user.Name -in @('SELISE','SELISE-KIOSK')
        $profile=$null; $hasLauncher=$false
        try {
            $profile=Get-KioskProfilePath -UserName $user.Name
            if ($profile) { $hasLauncher=Test-Path -LiteralPath (Join-Path $profile 'Scripts\LaunchKiosk.ps1') -PathType Leaf }
        } catch { if (-not $known -and $user.Name -ine $autoLoginUser) { continue } }
        if ($known -or $hasLauncher -or $user.Name -ieq $autoLoginUser) { [pscustomobject]@{Account=$user;HasLauncher=$hasLauncher} }
    })
    $activeCandidates=@($candidates | Where-Object { $_.Account.Enabled })
    if ($activeCandidates.Count) { $candidates=$activeCandidates }
    if (-not $candidates.Count) {
        $message=if (-not $users.Count) {'Account Missing. Please create manually.'} else {'Not verified. Kiosk account could not be identified from the existing setup. Please check manually.'}
        $result=New-CheckResult 'Fail' $message $message
        $result | Add-Member NoteProperty StateHtml $message
        $result | Add-Member NoteProperty DetectedAccountNames ([string[]]@())
        $result | Add-Member NoteProperty Shortcut (New-AccountReportCommand -AccountNames @())
        return [pscustomobject]@{Account=$null;Result=$result}
    }
    $selected=@($candidates | Where-Object {$_.Account.Name -ieq $autoLoginUser})
    if ($selected.Count -ne 1) {
        $withLauncher=@($candidates | Where-Object {$_.HasLauncher})
        if ($withLauncher.Count -eq 1) { $selected=$withLauncher }
        elseif ($withLauncher.Count -gt 1) {
            $result=New-CheckResult 'Fail' 'Multiple kiosk profiles contain launcher scripts; selection requires manual review.' 'Not verified. Multiple kiosk launcher profiles found. Please check manually.'
            $result | Add-Member NoteProperty StateHtml $result.State
            $result | Add-Member NoteProperty DetectedAccountNames ([string[]]@($withLauncher | ForEach-Object {$_.Account.Name}))
            $result | Add-Member NoteProperty Shortcut (New-AccountReportCommand -AccountNames $result.DetectedAccountNames)
            return [pscustomobject]@{Account=$null;Result=$result}
        } else {
            $selected=@($candidates | Where-Object {$_.Account.Name -ieq 'SELISE-KIOSK'})
            if (-not $selected.Count) { $selected=@($candidates | Select-Object -First 1) }
        }
    }
    $administratorSids=Get-LocalAdministratorSidSet
    $results=@(foreach ($candidate in $candidates) {
        $account=$candidate.Account
        $privilege=Get-LocalAccountPrivilege -Account $account -AdministratorSids $administratorSids
        try {
            $entry=Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $administratorSids -ReportPrivilegeOnly
        } catch {
            $entry=New-CheckResult 'Fail' $_.Exception.Message 'Account present; required properties not verified'
            $entry | Add-Member NoteProperty AccountName ([string]$account.Name)
            $entry | Add-Member NoteProperty DetectedAccountNames @([string]$account.Name)
            $entry | Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$account.Name;'Account Privilege'=$privilege;'Account Status'=$(if ($account.Enabled) {'Enabled'} else {'Disabled'});'Password Never Expires'='Not verified';'User Cannot Change Password'='Not verified'}))
        }
        $entry
    })
    [pscustomobject]@{Account=$selected[0].Account;Result=(Join-AccountCheckResults -Results $results -MissingName 'Existing kiosk account')}
}

function Get-AdministrativeAccountCheck {
    $discovered = Get-AdministrativeLocalAccounts
    $results = @(foreach ($account in $discovered.Accounts) {
        try { Invoke-ExistingAccountPolicy -Account $account -AdministratorSids $discovered.AdministratorSids -Administrative }
        catch {
            $failed = New-CheckResult 'Fail' $_.Exception.Message ('Account properties could not be read: ' + $account.Name)
            $failed | Add-Member -NotePropertyName AccountName -NotePropertyValue $account.Name
            $failed | Add-Member -NotePropertyName StateHtml -NotePropertyValue (ConvertTo-ReportDefinitionHtml ([ordered]@{
                'Account Name'=$account.Name
                'Account Privilege'=(Get-LocalAccountPrivilege -Account $account -AdministratorSids $discovered.AdministratorSids)
                'Account Status'=$(if ($account.Enabled) {'Enabled'} else {'Disabled'})
                'Password Never Expires'='Not verified'
            }))
            $failed
        }
    })
    if(-not $results.Count){return New-MissingAccountResult -RequestedName 'Admin, Administrator' -Administrative}
    Join-AccountCheckResults -Results $results -MissingName 'Admin, Administrator'
}

function Get-KioskProfilePath {
    param ([string]$UserName)
    $account = Get-LocalAccount $UserName
    if (-not $account) { return $null }
    $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($account.SID.Value)"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $profile = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ($profile.ProfileImagePath) { return [Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath) }
}

function Initialize-KioskProfile {
    param ([string]$UserName)
    # Thorough Check may inspect an existing profile, never create one.
    $path = Get-KioskProfilePath $UserName
    if (-not $path) { throw "Windows profile for '$UserName' is missing; no profile or launcher files were created." }
    return $path
}

function Test-KioskAutoLogin {
    param([string]$UserName)
    $account=Get-LocalAccount $UserName
    if (-not $account) {throw 'Kiosk account is unavailable; auto-login cannot be verified.'}
    $path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    $domain=[string]$key.GetValue('DefaultDomainName')
    $localDomain=[string]::IsNullOrWhiteSpace($domain) -or $domain -eq '.' -or $domain -ieq $env:COMPUTERNAME
    $count=$key.GetValue('AutoLogonCount')
    $unlimited=$null -eq $count -or ($count -is [string] -and $count.Length -eq 0)
    $user=[string]$key.GetValue('DefaultUserName')
    $enabled=$key.GetValue('AutoAdminLogon') -eq '1'
    $configured=$account.Enabled -and $enabled -and $user -ieq $UserName -and $localDomain -and $unlimited
    $result=New-CheckResult $(if ($configured) {'Pass'} else {'Fail'}) 'Existing auto-login settings recorded without changes; verify actual sign-in manually.' 'Auto-login inspected'
    $result | Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml ([ordered]@{'Automatic Sign-In'=$(if ($enabled) {'Enabled'} else {'Disabled'});'Default User'=$user;'Default Domain'=$(if ($localDomain) {'Local computer'} else {$domain});'Automatic Sign-In Limit'=$(if ($unlimited) {'Unlimited'} else {[string]$count})}))
    return $result
}

# Collect report identity in Audit; Apply reuses the session or saved Audit.
if([string]::IsNullOrWhiteSpace($AgentName) -or $AgentName -eq 'Not provided'){
    if($AuditOnly){
        do {$AgentName=([string](Read-Host 'Agent Name')).Trim()} while([string]::IsNullOrWhiteSpace($AgentName))
    }else{
        $AgentName=Get-ThoroughAuditAgentName -Path $reportPath -ClientType 'Subway' -ComputerName $env:COMPUTERNAME
        if([string]::IsNullOrWhiteSpace($AgentName)){$AgentName='Not provided'}
    }
}
if([string]::IsNullOrWhiteSpace($ClientLocation) -or $ClientLocation -eq 'Not provided'){
    if($AuditOnly){
        do {$ClientLocation=Read-Host 'Branch Name'} while([string]::IsNullOrWhiteSpace($ClientLocation))
    }else{
        $ClientLocation=Get-ThoroughAuditClientLocation -Path $reportPath -ClientType 'Subway' -ComputerName $env:COMPUTERNAME
        if([string]::IsNullOrWhiteSpace($ClientLocation)){$ClientLocation='Not provided'}
    }
}

# Resolve one saved bundle by Windows computer identity, including older launcher-based filenames.
$existingBundle=Find-ThoroughExistingBundle -Path $reportPath -ClientType 'Subway' -ComputerName $env:COMPUTERNAME
if($existingBundle){$reportPath=$existingBundle.Path}
$savedBeforeRows=@()
if($script:ApplyChanges -and $existingBundle){
    $savedBeforeRows=@(Get-ThoroughSnapshotObservations $existingBundle.State.Reports.Audit)
}
if($script:ApplyChanges){
    $KioskHostname=Read-ThoroughFixHostname -SuggestedName (Get-ThoroughDeviceHostname) -SuppliedName $KioskHostname
}
$applyRequested=[bool]$script:ApplyChanges
$beforeApplyRows=@()
$script:BeforeApplyInspection=$false

Write-ThoroughConsoleHeader -Client 'Subway' -Device $DeviceType -Branch $ClientLocation -IsApply $script:ApplyChanges -IsFinal ([bool]$FinalReport)

# Each component reports local failures. A finalizer also saves partial results after unexpected errors.
try {
foreach($inspectOnly in $(if($applyRequested){@($true,$false)}else{@($false)})){
    $script:BeforeApplyInspection=[bool]$inspectOnly
    $script:ApplyChanges=$applyRequested -and -not $inspectOnly
    $auditRows.Clear()
    if($inspectOnly){Write-Host 'Checking current configuration before applying fixes...' -ForegroundColor Cyan}

# =============================================================
# GROUP 1: HARDWARE & PERIPHERALS
# =============================================================
$sec1Num = 1
$sec1Title = 'Hardware & Peripherals'

function Get-PrinterHealth {
    param ($Printer, $CimPrinter)
    $state = [string]$Printer.PrinterStatus
    [uint32]$statusBits = 0
    $numericStatus = [uint32]::TryParse($state, [ref]$statusBits)
    $paused = if ($numericStatus) { ($statusBits -band 1) -ne 0 } else { $state -match '(^|,\s*)Paused($|,)' }
    $offline = ($Printer.WorkOffline -eq $true -or $CimPrinter.WorkOffline -eq $true -or $CimPrinter.PrinterStatus -eq 7 -or $state -match 'Offline' -or ($numericStatus -and ($statusBits -band 128) -ne 0))
    $reportedError = ($CimPrinter.DetectedErrorState -ge 3)
    # Busy / Printing / Processing are working states, not an offline printer.
    if ($numericStatus) {
        [uint32]$workingBits = 256 + 512 + 1024 + 8192 + 16384 + 32768 + 65536 + 16777216
        $healthy = ($statusBits -band (-bnot $workingBits)) -eq 0
    } else {
        $badStates = @($state -split ',\s*' | Where-Object { $_ -notmatch '^(Normal|Printing|Busy|Processing|Initializing|WarmingUp|IOActive|Waiting|PowerSave)$' })
        $healthy = (-not [string]::IsNullOrWhiteSpace($state)) -and $badStates.Count -eq 0
    }
    $active = ($state -match 'Printing|Busy|Processing|Initializing|WarmingUp|IOActive' -or
        ($numericStatus -and ($statusBits -band (256 + 512 + 1024 + 16384 + 32768)) -ne 0) -or $CimPrinter.PrinterStatus -in @(4, 5))
    $displayState = if ($offline) { 'Offline' } elseif ($paused) { 'Paused' } elseif (-not $healthy -or $reportedError) { 'Error' } elseif ($active) { 'Active' } else { 'Idle' }
    [PSCustomObject]@{ Paused = [bool]$paused; Healthy = [bool]($displayState -in @('Idle','Active')); State = $displayState }
}

# 1.1 Multi-Printer Discovery
Start-AuditStep 1 'Printer detection, status and document retention'
try {
    Write-AuditOperation 'Waiting for Windows printer discovery...'
    $installedPrinters = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch 'OneNote|PDF|XPS|Fax' })
    Write-AuditOperation 'Reading printer hardware state from Windows CIM...'
    $cimPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)
    if ($installedPrinters.Count -eq 0) { throw 'No physical printer detected. Check connection and printer driver.' }
    foreach ($ptr in $installedPrinters) {
        $pName = $ptr.Name
        $printerAction = 'No changes needed'
        $printerChanges = [Collections.Generic.List[string]]::new()
        $printerStatus = 'Fail'
        $printerState = 'Not verified. Please check manually.'
        $keepPrintedState = 'Not verified. Please check manually.'
        try {
            $cimPrinter = @($cimPrinters | Where-Object { $_.Name -eq $pName }) | Select-Object -First 1
            if (-not $cimPrinter) { throw 'Win32_Printer state is unavailable for this queue.' }
            $health = Get-PrinterHealth -Printer $ptr -CimPrinter $cimPrinter
            $printerState = if ($health.Healthy) { $health.State } else { 'Error' }
            $keepPrinted = $ptr.KeepPrintedJobs
            if ($null -eq $keepPrinted) { $keepPrinted = $cimPrinter.KeepPrintedJobs }
            if ($null -eq $keepPrinted) { throw 'Cannot read Keep printed documents setting.' }
            $keepPrintedState = if ($keepPrinted) { 'Enabled' } else { 'Disabled' }
            if (-not $keepPrinted -and (Test-CanApply)) {
                Set-Printer -Name ([WildcardPattern]::Escape($pName)) -KeepPrintedJobs $true -ErrorAction Stop
                $ptr = Get-Printer -Name ([WildcardPattern]::Escape($pName)) -ErrorAction Stop
                $keepPrinted = $ptr.KeepPrintedJobs
                if ($null -eq $keepPrinted) { $keepPrintedState = 'Not verified. Please check manually.'; throw 'Cannot verify Keep printed documents setting.' }
                $keepPrintedState = if ($keepPrinted) { 'Enabled' } else { 'Disabled' }
                if (-not $keepPrinted) { throw 'Keep printed documents could not be enabled.' }
                $printerChanges.Add('Enabled Keep printed documents')
            }
            
            $printerState = if ($health.Healthy) { $health.State } else { 'Error' }
            if ($health.Healthy -and $keepPrinted) { $printerStatus = 'Pass' }
            if (-not $keepPrinted) { $printerChanges.Add('Enable Keep printed documents in Apply Mode') }
            if ($health.State -eq 'Offline') { $printerChanges.Add('Check printer connection') }
            elseif ($printerState -in @('Error','Paused')) { $printerChanges.Add('Check printer status manually') }
            if ($printerChanges.Count -gt 0) { $printerAction = $printerChanges -join '; ' }
        } catch {
            $printerAction = $_.Exception.Message
        }
        $printerHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Printer Name'=$pName; 'Printer status'=$printerState; 'Keep printed documents'=$keepPrintedState })
        $printerShortcut = New-ReportCommand @('control printers', ('rundll32 printui.dll,PrintUIEntry /o /n "{0}"' -f $pName))
        Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle $pName -ItemSub 'Type: Receipt / POS Printer' -Shortcut $printerShortcut -FoundStateHtml $printerHtml -Status $printerStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($printerAction))
    }
} catch {
    Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle 'Physical Printers' -ItemSub 'Type: Receipt / Hardware' -Shortcut '<code>control printers</code>' -FoundStateHtml 'Not verified. Please check manually.' -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))
}

# 1.2 PrintService Event Log
Start-AuditStep 2 'PrintService event log'
$logName = 'Microsoft-Windows-PrintService/Operational'
$logStatus = 'Fail'
$logFound = 'Not verified'
try {
    $printLog = Get-WinEvent -ListLog $logName -Force -ErrorAction Stop
    $logAction = 'Operational log verified enabled'
    if (-not $printLog.IsEnabled) {
        if (Test-CanApply) {
            & wevtutil.exe sl $logName /e:true 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wevtutil returned exit code $LASTEXITCODE." }
            $printLog = Get-WinEvent -ListLog $logName -Force -ErrorAction Stop
            $logAction = 'PrintService log enabled and verified'
        } else { $logAction = 'Audit only; enable PrintService log in Apply mode' }
    }
    $logFound = if ($printLog.IsEnabled) { 'Enabled' } else { 'Disabled' }
    if ($printLog.IsEnabled) { $logStatus = 'Pass' }
    elseif (Test-CanApply) { throw 'PrintService log is still disabled after enabling it.' }
} catch { $logAction = "PrintService log check failed: $($_.Exception.Message)" }
Add-AuditEntry -SectionNumber $sec1Num -SectionTitle $sec1Title -ItemTitle 'PrintService Operational Log' -ItemSub 'Type: Event Viewer Channel' -Shortcut '<code>eventvwr.msc</code>' -FoundStateHtml ([System.Net.WebUtility]::HtmlEncode($logFound)) -Status $logStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($logAction))

# =============================================================
# GROUP 2: KIOSK APPLICATION & POLICIES (POS is rejected at entry)
# =============================================================
$sec2Num = 2
$sec2Title = 'Kiosk Application & Policies'
$kioskUser = 'SELISE-KIOSK'





function Test-KioskStartupBatch {
    param ([string]$Batch, [string]$LaunchPath)
    if (-not (Test-Path -LiteralPath $Batch -PathType Leaf)) { return $false }
    $content = [IO.File]::ReadAllText($Batch)
    $matches = [regex]::Matches($content, '(?im)\bpowershell(?:\.exe)?\b[^\r\n]*?\s-File\s+"([^"]+)"')
    if ($matches.Count -ne 1) { return $false }
    $target = $matches[0].Groups[1].Value
    if ($target.StartsWith('%USERPROFILE%', [StringComparison]::OrdinalIgnoreCase)) {
        $profile = Split-Path (Split-Path $LaunchPath -Parent) -Parent
        $target = $profile + $target.Substring('%USERPROFILE%'.Length)
    }
    if (-not [IO.Path]::IsPathRooted($target) -or $target -match '%') { return $false }
    return [IO.Path]::GetFullPath($target).Equals([IO.Path]::GetFullPath($LaunchPath),[StringComparison]::OrdinalIgnoreCase)
}

function Test-KioskDesktopShortcut {
    param ([string]$Batch, [string]$LaunchPath, [string]$Shortcut)
    if (-not (Test-Path -LiteralPath $Shortcut -PathType Leaf)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Shortcut)
    if ($link.TargetPath -ieq $Batch -and [string]::IsNullOrWhiteSpace($link.Arguments)) { return $true }
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $LaunchPath
    return ($link.TargetPath -ieq $powerShell -and $link.Arguments -ceq $arguments)
}

function Verify-KioskLaunchTargets {
    param ([string]$Batch, [string]$Shortcut, [string]$LaunchPath)
    if ([string]::IsNullOrWhiteSpace($LaunchPath)) {
        throw 'Launcher path is required for read-only target verification; no files changed.'
    }
    if (-not (Test-KioskStartupBatch -Batch $Batch -LaunchPath $LaunchPath)) { throw 'Startup BAT is missing or its launcher target could not be verified; no Startup files changed.' }
    if (-not (Test-KioskDesktopShortcut -Batch $Batch -LaunchPath $LaunchPath -Shortcut $Shortcut)) { throw 'Desktop shortcut is missing or its target differs; existing shortcut preserved.' }
    return 'Startup BAT and desktop shortcut targets inspected; existing files preserved.'
}

function Invoke-KioskLauncherConfiguration {
    param ([string]$UserName, [string]$Restaurant, [string]$Kiosk, [string]$Hostname)
    $base = Initialize-KioskProfile $UserName
    $launch = Join-Path $base 'Scripts\LaunchKiosk.ps1'
    $batch = Join-Path $base 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
    $desktop = Join-Path $base 'Desktop'
    $shortcut = Join-Path $desktop 'Launch Kiosk.lnk'
    $result = Repair-LauncherDetails -Path $launch -ShortcutPath $shortcut -Restaurant $Restaurant -Kiosk $Kiosk -Hostname $Hostname
    $result = Add-LauncherReportDetails $result $launch $shortcut $batch
    if (-not (Test-Path -LiteralPath $batch -PathType Leaf)) {
        $result.Status = 'Fail'
        $result.Action += ' Startup BAT is missing. Manual action required. Desktop shortcut was not created.'
        return $result
    }
    if ($result.Status -ne 'Pass') { return $result }
    $notes = [Collections.Generic.List[string]]::new()
    $notes.Add($result.Action)
    if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf) -and (Test-CanApply)) {
        $createdShortcut = $false
        try {
            if (-not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'Desktop folder is missing; no folders were created.' }
            if (-not (Test-KioskStartupBatch -Batch $batch -LaunchPath $launch)) { throw 'Existing Startup BAT target is not verified; desktop shortcut was not created.' }
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath=$batch; $link.Arguments=''
            $link.WorkingDirectory = Split-Path $launch -Parent
            $link.Description = 'Launch existing Kiosk Front-End'
            if (Test-Path -LiteralPath $shortcut) { throw 'Desktop shortcut appeared during inspection; existing file preserved.' }
            $createdShortcut = $true
            $link.Save()
            if (-not (Test-KioskDesktopShortcut -Batch $batch -LaunchPath $launch -Shortcut $shortcut)) { throw 'Created desktop shortcut target could not be verified.' }
            $notes.Add('Created missing desktop shortcut to the existing launcher; target readback verified.')
        } catch {
            if ($createdShortcut -and (Test-Path -LiteralPath $shortcut -PathType Leaf)) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction Stop }
            $result.Status='Fail'
            $notes.Add($_.Exception.Message)
        }
    }
    try { $notes.Add((Verify-KioskLaunchTargets -Batch $batch -Shortcut $shortcut -LaunchPath $launch)) }
    catch { $result.Status='Fail'; $notes.Add($_.Exception.Message) }
    $result = Add-LauncherReportDetails $result $launch $shortcut $batch
    $result.Action = $notes -join ' '
    return $result
}

function ConvertFrom-KioskEdgeArguments {
    param([string]$Text)
    $arguments=[Collections.Generic.List[string]]::new()
    $token=[Text.StringBuilder]::new()
    $quoted=$false; $started=$false
    for($index=0;$index -lt $Text.Length;$index++){
        $character=$Text[$index]
        if($character -eq '\'){
            $slashes=0
            while($index -lt $Text.Length -and $Text[$index] -eq '\'){$slashes++;$index++}
            if($index -lt $Text.Length -and $Text[$index] -eq '"'){
                [void]$token.Append(('\' * [int][Math]::Floor($slashes/2)))
                if($slashes % 2){[void]$token.Append('"')}else{$quoted=-not $quoted}
                $started=$true
            }else{
                [void]$token.Append(('\' * $slashes));$started=$true;$index--
            }
        }elseif($character -eq '"'){
            $quoted=-not $quoted;$started=$true
        }elseif([char]::IsWhiteSpace($character) -and -not $quoted){
            if($started){$arguments.Add($token.ToString());[void]$token.Clear();$started=$false}
        }else{[void]$token.Append($character);$started=$true}
    }
    if($quoted){throw 'Edge arguments contain unmatched quotes.'}
    if($started){$arguments.Add($token.ToString())}
    return ,$arguments.ToArray()
}

function Get-KioskPinchLaunchState {
    param([string]$Text)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Launcher syntax is invalid.'}
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(?:Microsoft\.PowerShell\.Management\\)?Start-Process$'},$true))
    if($commands.Count -ne 1){throw 'A single static Edge launch command could not be verified.'}
    $command=$commands[0]
    if($command.Parent -isnot [Management.Automation.Language.PipelineAst] -or $command.Parent.PipelineElements.Count -ne 1 -or $command.Parent.Parent -ne $ast.EndBlock){throw 'The Edge launch command is conditional or indirect; manual review is required.'}
    $elements=$command.CommandElements
    $fileExpression=$null;$argumentExpression=$null
    for($index=1;$index -lt $elements.Count;$index++){
        $element=$elements[$index]
        if($element -is [Management.Automation.Language.CommandParameterAst]){
            if($element.ParameterName -in @('FilePath','ArgumentList','WindowStyle','WorkingDirectory')){
                $expression=$element.Argument
                if($null -eq $expression){
                    if($index+1 -ge $elements.Count){throw 'An Edge launch parameter has no value.'}
                    $index++;$expression=$elements[$index]
                }
                if($expression -is [Management.Automation.Language.CommandParameterAst]){throw 'An Edge launch parameter has no value.'}
                if($element.ParameterName -eq 'FilePath'){
                    if($null -ne $fileExpression){throw 'Duplicate Edge executable parameter.'}
                    $fileExpression=$expression
                }elseif($element.ParameterName -eq 'ArgumentList'){
                    if($null -ne $argumentExpression){throw 'Duplicate Edge arguments parameter.'}
                    $argumentExpression=$expression
                }
            }elseif($element.ParameterName -notin @('Wait','PassThru')){throw 'An unsupported Edge launch parameter needs manual review.'}
        }elseif($index -eq 1 -and $null -eq $fileExpression){$fileExpression=$element}
        else{throw 'An unbound or splatted Edge launch argument needs manual review.'}
    }
    if($fileExpression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or [IO.Path]::GetFileName($fileExpression.Value) -notin @('msedge','msedge.exe')){throw 'The Edge executable is not a verified literal path.'}
    if($argumentExpression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $argumentExpression.StringConstantType.ToString() -notin @('SingleQuoted','DoubleQuoted')){throw 'Edge arguments are dynamic or use an unsupported format.'}
    $arguments=ConvertFrom-KioskEdgeArguments $argumentExpression.Value
    if($arguments -ccontains '--'){throw 'An Edge argument terminator prevents safe pinch configuration.'}
    $kioskPositions=@(for($index=0;$index -lt $arguments.Count;$index++){if($arguments[$index] -ceq '--kiosk'){$index}})
    if($kioskPositions.Count -ne 1 -or $kioskPositions[0]+1 -ge $arguments.Count){throw 'The kiosk URL argument could not be verified.'}
    $url=$arguments[$kioskPositions[0]+1]
    if((Resolve-KioskUrl -Url $url).Issues.Count){throw 'The kiosk URL or its identifiers need manual review.'}
    $pinchArguments=@($arguments | Where-Object {$_ -match '^--(?:disable|enable)-pinch(?:=|$)'})
    if($pinchArguments.Count -gt 1 -or ($pinchArguments.Count -eq 1 -and $pinchArguments[0] -cne '--disable-pinch')){throw 'A nonstandard or conflicting pinch argument needs manual review.'}
    [pscustomobject]@{Disabled=($pinchArguments.Count -eq 1);InsertOffset=($argumentExpression.Extent.EndOffset-1)}
}

function Read-KioskPinchStream {
    param([IO.Stream]$Stream)
    $copy=[IO.MemoryStream]::new()
    try{$Stream.Position=0;$Stream.CopyTo($copy);return ,$copy.ToArray()}finally{$copy.Dispose()}
}

function Write-KioskPinchStream {
    param([IO.FileStream]$Stream,[byte[]]$Bytes)
    $Stream.Position=0;$Stream.Write($Bytes,0,$Bytes.Length);$Stream.SetLength($Bytes.Length);$Stream.Flush($true)
}

function Invoke-KioskPinchZoomCheck {
    param([string]$UserName)
    $result=New-CheckResult 'Fail' 'Pinch-to-zoom configuration was not verified. Manual action required.' 'Not verified. Please check manually.'
    try{
        if([string]::IsNullOrWhiteSpace($UserName)){throw 'The selected kiosk account is unavailable.'}
        $profile=Get-KioskProfilePath $UserName
        if(-not $profile){throw 'The selected kiosk profile is unavailable.'}
        $launch=Join-Path $profile 'Scripts\LaunchKiosk.ps1'
        $batch=Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
        if(-not (Test-Path -LiteralPath $launch -PathType Leaf)){throw 'The kiosk launcher is missing.'}
        $original=[IO.File]::ReadAllBytes($launch)
        $encoding=[Text.UTF8Encoding]::new($false,$true);$preambleLength=0
        if($original.Length -ge 4 -and $original[0] -eq 255 -and $original[1] -eq 254 -and $original[2] -eq 0 -and $original[3] -eq 0){$encoding=[Text.UTF32Encoding]::new($false,$true,$true);$preambleLength=4}
        elseif($original.Length -ge 4 -and $original[0] -eq 0 -and $original[1] -eq 0 -and $original[2] -eq 254 -and $original[3] -eq 255){$encoding=[Text.UTF32Encoding]::new($true,$true,$true);$preambleLength=4}
        elseif($original.Length -ge 3 -and $original[0] -eq 239 -and $original[1] -eq 187 -and $original[2] -eq 191){$preambleLength=3}
        elseif($original.Length -ge 2 -and $original[0] -eq 255 -and $original[1] -eq 254){$encoding=[Text.UnicodeEncoding]::new($false,$true,$true);$preambleLength=2}
        elseif($original.Length -ge 2 -and $original[0] -eq 254 -and $original[1] -eq 255){$encoding=[Text.UnicodeEncoding]::new($true,$true,$true);$preambleLength=2}
        $text=$encoding.GetString($original,$preambleLength,$original.Length-$preambleLength)
        $state=Get-KioskPinchLaunchState $text
        if($state.Disabled){return New-CheckResult 'Pass' 'Touchscreen pinch-to-zoom disabling argument is configured. Verify touch behavior after restarting Edge.' 'Disabled'}
        $result.State='Not configured'
        $result.Action='The verified Edge launch command is missing --disable-pinch. Apply Fix can add this argument; touchscreen verification requires restarting Edge.'
        if(-not (Test-CanApply)){return $result}
        if($text -match '(?im)^# SIG # Begin signature block'){throw 'The launcher is signed and must be updated manually.'}
        foreach($path in @($launch,(Split-Path $launch -Parent))){if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked launcher path requires manual review.'}}
        if(-not (Test-KioskStartupBatch -Batch $batch -LaunchPath $launch)){throw 'The Startup BAT is missing or does not target this launcher.'}
        $updated=$text.Insert($state.InsertOffset,' --disable-pinch')
        if(-not (Get-KioskPinchLaunchState $updated).Disabled){throw 'The proposed pinch argument could not be verified.'}
        $body=$encoding.GetBytes($updated)
        $candidate=[byte[]]::new($preambleLength+$body.Length)
        if($preambleLength){[Buffer]::BlockCopy($original,0,$candidate,0,$preambleLength)}
        [Buffer]::BlockCopy($body,0,$candidate,$preambleLength,$body.Length)
        $stream=$null;$writeStarted=$false
        try{
            $stream=[IO.File]::Open($launch,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $lockedBytes=Read-KioskPinchStream $stream
            if([Convert]::ToBase64String($lockedBytes) -cne [Convert]::ToBase64String($original)){throw 'The launcher changed during inspection; existing content preserved.'}
            $writeStarted=$true
            Write-KioskPinchStream -Stream $stream -Bytes $candidate
            $readback=Read-KioskPinchStream $stream
            if([Convert]::ToBase64String($readback) -cne [Convert]::ToBase64String($candidate)){throw 'Launcher content readback did not match the single authorized change.'}
            $readbackText=$encoding.GetString($readback,$preambleLength,$readback.Length-$preambleLength)
            if(-not (Get-KioskPinchLaunchState $readbackText).Disabled){throw 'The pinch argument was not verified after writing.'}
        }catch{
            $failure=$_.Exception.Message
            if($writeStarted){
                try{
                    $stream.Position=0;$stream.Write($original,0,$original.Length);$stream.SetLength($original.Length);$stream.Flush($true)
                    $restored=Read-KioskPinchStream $stream
                    if([Convert]::ToBase64String($restored) -cne [Convert]::ToBase64String($original)){throw 'Restore readback mismatch.'}
                    $failure+=' Previous launcher bytes restored.'
                }catch{$failure+=' Launcher restoration could not be verified. Inspect the launcher manually.'}
            }
            throw $failure
        }finally{if($null -ne $stream){$stream.Dispose()}}
        return New-CheckResult 'Pass' 'Added only --disable-pinch to the verified Edge argument string; content readback verified. Restart Edge and verify touchscreen zoom. No backup or temporary files were created.' 'Disabled'
    }catch{
        $result.Status='Fail';$result.Action=$_.Exception.Message+' Manual action required. The launcher was not run.'
        return $result
    }
}

function Invoke-BrowserPolicyCheck {
    param([string]$UserName)
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $allow = "$edge\LocalNetworkAccessAllowedForUrls"
    $gestures = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI'
    $settings = @(
        @{Path=$allow; Name='1'; Value='https://kiosk.subway.ch'; Type='String'},
        @{Path=$edge; Name='TranslateEnabled'; Value=0; Type='DWord'},
        @{Path=$edge; Name='VisualSearchEnabled'; Value=0; Type='DWord'},
        @{Path=$gestures; Name='AllowEdgeSwipe'; Value=0; Type='DWord'}
    )
    $issues = [Collections.Generic.List[string]]::new()
    $changes = [Collections.Generic.List[string]]::new()
    $policyStates = [Collections.Generic.List[string]]::new()
    $labels = @{ '1'='Local Network Allowlist'; TranslateEnabled='Translation'; VisualSearchEnabled='Visual Search'; AllowEdgeSwipe='Edge Gestures' }
    foreach ($setting in $settings) {
        $keyExists = Test-Path -LiteralPath $setting.Path
        $key = if ($keyExists) { Get-Item -LiteralPath $setting.Path -ErrorAction Stop } else { $null }
        $valueExists = $null -ne $key -and $key.GetValueNames() -contains $setting.Name
        # Existing values are preserved even when they differ from the reference.
        if (-not $valueExists -and (Test-CanApply)) {
            if (-not $keyExists) {
                $missingKeys = [Collections.Generic.Stack[string]]::new()
                $candidate = $setting.Path
                while (-not (Test-Path -LiteralPath $candidate)) {
                    $missingKeys.Push($candidate)
                    $candidate = Split-Path $candidate -Parent
                    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'Cannot locate an existing policy registry parent.' }
                }
                foreach ($missingKey in $missingKeys) { New-Item -Path $missingKey -ErrorAction Stop | Out-Null }
            }
            New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value $setting.Value -PropertyType $setting.Type -ErrorAction Stop | Out-Null
            $changes.Add('Added '+$labels[$setting.Name])
            $key = Get-Item -LiteralPath $setting.Path -ErrorAction Stop
            $valueExists = $key.GetValueNames() -contains $setting.Name
        }
        $value = if ($valueExists) { $key.GetValue($setting.Name) } else { $null }
        $display = if (-not $valueExists) { 'Not configured' } elseif ($setting.Type -eq 'String') { [string]$value } elseif ($value -eq 0) { 'Disabled' } elseif ($value -eq 1) { 'Enabled' } else { 'Unrecognized value' }
        $policyStates.Add($labels[$setting.Name]+': '+[Net.WebUtility]::HtmlEncode($display))
        if (-not $valueExists -or $value -cne $setting.Value -or $key.GetValueKind($setting.Name).ToString() -ne $setting.Type) { $issues.Add($labels[$setting.Name]) }
    }
    if ((Test-Path -LiteralPath $allow) -and (Get-Item -LiteralPath $allow -ErrorAction Stop).GetValueNames() -contains '2') {
        $issues.Add('Obsolete allowlist entry 2 (preserved)')
        $policyStates.Add('Obsolete allowlist entry: Present (preserved)')
    }
    $pinch=Invoke-KioskPinchZoomCheck -UserName $UserName
    $policyStates.Add('Pinch-to-Zoom: '+[Net.WebUtility]::HtmlEncode($pinch.State))
    if($pinch.Status -ne 'Pass'){$issues.Add('Pinch-to-Zoom')}
    $action = if ($changes.Count) { ($changes -join '; ')+'. Existing policy values preserved.' } else { 'Existing policy values preserved; no changes made.' }
    if ($issues.Count) { $action += ' Manual review required: '+($issues -join ', ')+'.' }
    else { $action += ' Required policy values verified.' }
    $action += ' '+$pinch.Action
    $result = New-CheckResult $(if ($issues.Count) { 'Fail' } else { 'Pass' }) $action 'Browser policies inspected'
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue ($policyStates -join '<br>')
    return $result
}

function Get-KioskLaunchTaskInventory {
    # A failed enumeration is not evidence that a task is missing.
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object {[string]$_.TaskName -ieq 'Launch Kiosk'})
}

function Get-KioskLaunchTaskContext {
    param([string]$UserName,$Account)
    $issues=[Collections.Generic.List[string]]::new()
    $context=[pscustomobject]@{UserName=$UserName;UserId='Not verified';Sid='';ScriptPath='Not verified';ProgramPath=(Join-Path $PSHOME 'powershell.exe');WorkingDirectory='';LauncherFile='Not verified';StartupBat='Not verified';Ready=$false;Reason=''}
    try{
        if($null -eq $Account -or [string]$Account.Name -ine $UserName){throw 'The selected kiosk account was not verified.'}
        $fresh=Get-LocalAccount $UserName
        if($null -eq $fresh -or $null -eq $fresh.SID -or -not [string]$fresh.SID.Value){throw 'The selected local account SID is unavailable.'}
        if($null -eq $Account.SID -or [string]$Account.SID.Value -cne [string]$fresh.SID.Value){throw 'The selected local account identity changed; no task was created.'}
        $context.Sid=[string]$fresh.SID.Value
        if([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)){throw 'The local computer name is unavailable.'}
        $context.UserId=$env:COMPUTERNAME+'\'+$UserName
        if($fresh.Enabled -isnot [bool] -or -not $fresh.Enabled){$issues.Add('The selected kiosk account is disabled or its enabled state is unverified.')}
        $profile=Get-KioskProfilePath $UserName
        if([string]::IsNullOrWhiteSpace($profile)){throw 'The selected kiosk user profile is unavailable.'}
        $profile=[IO.Path]::GetFullPath($profile).TrimEnd('\')
        if($profile -notmatch '^[A-Za-z]:\\'){throw 'The kiosk profile must be a verified local Windows path.'}
        $context.ScriptPath=[IO.Path]::GetFullPath((Join-Path $profile 'Scripts\LaunchKiosk.ps1'))
        $context.WorkingDirectory=[IO.Path]::GetDirectoryName($context.ScriptPath)
        $startup=Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
        $context.StartupBat=if(Test-Path -LiteralPath $startup -PathType Leaf -ErrorAction Stop){'Also present (unchanged)'}else{'Not present'}
        $context.LauncherFile=if(Test-Path -LiteralPath $context.ScriptPath -PathType Leaf -ErrorAction Stop){'Available'}else{'Missing'}
        if($context.LauncherFile -ne 'Available'){$issues.Add('The existing LaunchKiosk.ps1 file is missing.')}
        if(-not (Test-Path -LiteralPath $context.ProgramPath -PathType Leaf -ErrorAction Stop)){$issues.Add('Windows PowerShell executable is unavailable.')}
        foreach($target in @($context.ScriptPath,$context.ProgramPath)){
            if(-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction Stop)){continue}
            $current=$target
            while($current){
                $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked launcher or executable path requires manual review.'}
                $parent=[IO.Path]::GetDirectoryName($current)
                if($parent -eq $current){break};$current=$parent
            }
        }
    }catch{$issues.Add($_.Exception.Message)}
    $context.Ready=$issues.Count -eq 0
    $context.Reason=$issues -join ' '
    $context
}

function Test-KioskLaunchTaskIdentity {
    param([string]$Identity,$Context)
    if(-not $Context.Sid){return $false}
    $Identity -ieq $Context.Sid -or $Identity -ieq $Context.UserId -or $Identity -ieq ('.\'+$Context.UserName)
}

function Read-KioskLaunchTaskArguments {
    param([string]$Arguments)
    # Inspect native argument tokens only. Never evaluate a task command line.
    $result=[pscustomobject]@{Known=$false;ScriptPath='Not verified';ProfileLoading='Not verified';ExecutionPolicy='Not verified';WindowStyle='Not verified'}
    $tokens=[Collections.Generic.List[string]]::new();$end=0
    foreach($match in [regex]::Matches($Arguments,'"(?<Quoted>[^"]*)"|(?<Bare>[^\s"]+)')){
        if(($tokens.Count -gt 0 -and $match.Index -eq $end) -or $Arguments.Substring($end,$match.Index-$end).Trim()){return $result}
        $tokens.Add($(if($match.Groups['Quoted'].Success){$match.Groups['Quoted'].Value}else{$match.Groups['Bare'].Value}))
        $end=$match.Index+$match.Length
    }
    if($Arguments.Substring($end).Trim()){return $result}
    $seen=@{}
    for($i=0;$i -lt $tokens.Count;$i++){
        $key=$tokens[$i].ToLowerInvariant()
        if($seen.ContainsKey($key)){return $result};$seen[$key]=$true
        switch($key){
            '-noprofile' {$result.ProfileLoading='Disabled'}
            '-executionpolicy' {if(++$i -ge $tokens.Count){return $result};$result.ExecutionPolicy=$tokens[$i]}
            '-windowstyle' {if(++$i -ge $tokens.Count){return $result};$result.WindowStyle=$tokens[$i]}
            '-file' {if(++$i -ge $tokens.Count){return $result};$result.ScriptPath=$tokens[$i]}
            default {return $result}
        }
    }
    $result.Known=$seen.Count -eq 4 -and $seen.ContainsKey('-noprofile') -and $seen.ContainsKey('-executionpolicy') -and $seen.ContainsKey('-windowstyle') -and $seen.ContainsKey('-file')
    $result
}

function Get-KioskLaunchTaskFields {
    param($Context,[string]$Availability='Missing')
    $fields=[ordered]@{
        'Task Name'='Launch Kiosk';'Task Path'='\';'Task'=$Availability;'Task State'='Not configured';'Task Enabled'='Not configured'
        'Run As'='Not configured';'Logon Type'='Not configured';'Run Level'='Not configured';'Trigger'='Not configured';'Logon User'='Not configured'
        'Startup Delay'='Not configured';'Program'='Not configured';'Script Path'='Not configured';'Profile Loading'='Not configured'
        'Execution Policy'='Not configured';'Window Style'='Not configured';'Working Directory'='Not configured';'Execution Time Limit'='Not configured'
        'Start On Battery'='Not configured';'Stop On Battery'='Not configured';'Start When Available'='Not configured'
        'Launcher File'=$Context.LauncherFile;'Startup BAT'=$Context.StartupBat
    }
    if($Availability -eq 'Not verified'){foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}}
    $fields
}

function Get-KioskLaunchTaskRequirements {
    param($Context)
    [ordered]@{
        'Task Name'='Launch Kiosk';'Task Path'='\';'Task'='Available';'Task State'='';'Task Enabled'='Yes'
        'Run As'=$Context.UserId;'Logon Type'='Interactive';'Run Level'='Limited';'Trigger'='At logon';'Logon User'=$Context.UserId
        'Startup Delay'='5 seconds';'Program'='Windows PowerShell';'Script Path'=$Context.ScriptPath;'Profile Loading'='Disabled'
        'Execution Policy'='Bypass';'Window Style'='Hidden';'Working Directory'='';'Execution Time Limit'='Unlimited'
        'Start On Battery'='Yes';'Stop On Battery'='No';'Start When Available'='Yes';'Launcher File'='Available';'Startup BAT'=''
    }
}

function Read-KioskLaunchTaskSnapshot {
    param([AllowEmptyCollection()][object[]]$Tasks,$Context)
    $fields=Get-KioskLaunchTaskFields $Context
    if($Tasks.Count -eq 0){return [pscustomobject]@{Fields=$fields;Verified=$true;Passed=$false;Reason='Launch Kiosk task is missing.'}}
    if($Tasks.Count -ne 1){
        $fields['Task']='Multiple matches';$fields['Task Path']=($Tasks|ForEach-Object {[string]$_.TaskPath}) -join ', '
        foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task Path','Task','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}
        return [pscustomobject]@{Fields=$fields;Verified=$false;Passed=$false;Reason='Multiple Launch Kiosk tasks require manual review; existing tasks were preserved.'}
    }
    $task=$Tasks[0];$fields['Task']='Available';$fields['Task Path']=[string]$task.TaskPath;$fields['Task State']=[string]$task.State
    $reader=$null;$inputText=$null
    try{
        if(-not [string]$task.TaskPath){throw 'Task folder could not be verified.'}
        $xml=Export-ScheduledTask -TaskName 'Launch Kiosk' -TaskPath ([string]$task.TaskPath) -ErrorAction Stop
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $inputText=[IO.StringReader]::new([string]$xml);$reader=[Xml.XmlReader]::Create($inputText,$settings)
        $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
        if($document.DocumentElement.LocalName -ne 'Task' -or $document.DocumentElement.NamespaceURI -ne 'http://schemas.microsoft.com/windows/2004/02/mit/task'){throw 'Unrecognized scheduled task definition.'}
        $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('t',$document.DocumentElement.NamespaceURI)
        $text={param([string]$Path) $node=$document.SelectSingleNode($Path,$ns);if($node){$node.InnerText}else{''}}
        $yesNo={param([string]$Value) if($Value -ieq 'true'){'Yes'}elseif($Value -ieq 'false'){'No'}else{'Not verified'}}
        $fields['Task Enabled']=& $yesNo (& $text '/t:Task/t:Settings/t:Enabled')
        if($fields['Task State'] -eq 'Disabled'){$fields['Task Enabled']='No'}
        $principals=@($document.SelectNodes('/t:Task/t:Principals/t:Principal',$ns))
        if($principals.Count -ne 1){throw 'The task principal is missing or ambiguous.'}
        $principal=& $text '/t:Task/t:Principals/t:Principal/t:UserId'
        $fields['Run As']=if(Test-KioskLaunchTaskIdentity $principal $Context){$Context.UserId}else{$principal}
        $logon=& $text '/t:Task/t:Principals/t:Principal/t:LogonType'
        $fields['Logon Type']=if($logon -eq 'InteractiveToken'){'Interactive'}elseif($logon){$logon}else{'Not verified'}
        $level=& $text '/t:Task/t:Principals/t:Principal/t:RunLevel'
        $fields['Run Level']=switch($level){'LeastPrivilege'{'Limited'};'HighestAvailable'{'Highest'};default{'Not verified'}}
        $triggers=@($document.SelectNodes('/t:Task/t:Triggers/*',$ns))
        if($triggers.Count -eq 1 -and $triggers[0].LocalName -eq 'LogonTrigger'){
            $enabled=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:Enabled'
            $fields['Trigger']=if($enabled -ieq 'true'){'At logon'}elseif($enabled -ieq 'false'){'Disabled logon trigger'}else{'Not verified'}
            $triggerUser=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:UserId'
            $fields['Logon User']=if(Test-KioskLaunchTaskIdentity $triggerUser $Context){$Context.UserId}elseif($triggerUser){$triggerUser}else{'Any user'}
            $delay=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:Delay'
            try{$duration=[Xml.XmlConvert]::ToTimeSpan($delay);$fields['Startup Delay']=$duration.TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)+' seconds'}catch{$fields['Startup Delay']='Not verified'}
        }else{$fields['Trigger']=if($triggers.Count -gt 1){'Multiple triggers'}else{'Not a logon trigger'};$fields['Logon User']='Not verified';$fields['Startup Delay']='Not verified'}
        $actions=@($document.SelectNodes('/t:Task/t:Actions/*',$ns))
        if($actions.Count -eq 1 -and $actions[0].LocalName -eq 'Exec'){
            $program=& $text '/t:Task/t:Actions/t:Exec/t:Command'
            $fields['Program']=if($program -ieq $Context.ProgramPath -or $program -ieq 'powershell.exe'){'Windows PowerShell'}else{$program}
            $arguments=Read-KioskLaunchTaskArguments (& $text '/t:Task/t:Actions/t:Exec/t:Arguments')
            if($arguments.Known){
                $fields['Script Path']=$arguments.ScriptPath;$fields['Profile Loading']=$arguments.ProfileLoading
                $fields['Execution Policy']=$arguments.ExecutionPolicy;$fields['Window Style']=$arguments.WindowStyle
            }else{foreach($key in @('Script Path','Profile Loading','Execution Policy','Window Style')){$fields[$key]='Not verified'}}
            $directory=& $text '/t:Task/t:Actions/t:Exec/t:WorkingDirectory'
            $fields['Working Directory']=if($directory){$directory}else{'(default)'}
        }else{foreach($key in @('Program','Script Path','Profile Loading','Execution Policy','Window Style','Working Directory')){$fields[$key]='Not verified'}}
        $limit=& $text '/t:Task/t:Settings/t:ExecutionTimeLimit'
        try{$duration=[Xml.XmlConvert]::ToTimeSpan($limit);$fields['Execution Time Limit']=if($duration -eq [TimeSpan]::Zero){'Unlimited'}else{$limit}}catch{$fields['Execution Time Limit']='Not verified'}
        $disallow=& $text '/t:Task/t:Settings/t:DisallowStartIfOnBatteries'
        $fields['Start On Battery']=if($disallow -ieq 'false'){'Yes'}elseif($disallow -ieq 'true'){'No'}else{'Not verified'}
        $fields['Stop On Battery']=& $yesNo (& $text '/t:Task/t:Settings/t:StopIfGoingOnBatteries')
        $fields['Start When Available']=& $yesNo (& $text '/t:Task/t:Settings/t:StartWhenAvailable')
        $required=Get-KioskLaunchTaskRequirements $Context
        $passed=$Context.Ready
        foreach($key in $required.Keys){if($required[$key] -and [string]$fields[$key] -ine [string]$required[$key]){$passed=$false}}
        [pscustomobject]@{Fields=$fields;Verified=$true;Passed=$passed;Reason=$(if($passed){'Existing task definition verified; no task was changed or executed.'}else{'Existing task configuration requires manual review; task preserved. '+$Context.Reason})}
    }catch{
        foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task Path','Task','Task State','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}
        [pscustomobject]@{Fields=$fields;Verified=$false;Passed=$false;Reason='Task definition could not be verified: '+$_.Exception.Message}
    }finally{if($reader){$reader.Dispose()};if($inputText){$inputText.Dispose()}}
}

function Open-KioskLaunchTaskScheduler {
    $service=New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $service
}

function New-KioskLaunchTaskDefinition {
    param($Service,$Context)
    $definition=$service.NewTask(0)
    $definition.RegistrationInfo.Description='Start the existing kiosk launcher five seconds after the selected local user logs on.'
    $definition.Principal.UserId=$Context.Sid;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=0
    $trigger=$definition.Triggers.Create(9);$trigger.UserId=$Context.Sid;$trigger.Delay='PT5S';$trigger.Enabled=$true
    $action=$definition.Actions.Create(0);$action.Path=$Context.ProgramPath
    $action.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Context.ScriptPath+'"'
    $action.WorkingDirectory=$Context.WorkingDirectory
    $definition.Settings.Enabled=$true;$definition.Settings.DisallowStartIfOnBatteries=$false
    $definition.Settings.StopIfGoingOnBatteries=$false;$definition.Settings.StartWhenAvailable=$true
    $definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.MultipleInstances=2
    $definition
}

function Register-MissingKioskLaunchTask {
    param($Context)
    if(-not (Test-CanApply) -or -not $Context.Ready){throw 'Missing-task creation requires approved Apply and verified kiosk prerequisites.'}
    $service=Open-KioskLaunchTaskScheduler
    $definition=New-KioskLaunchTaskDefinition $service $Context
    $root=$service.GetFolder('\')
    # TASK_CREATE (2) fails if another writer creates this task concurrently.
    # Never use TASK_CREATE_OR_UPDATE, a password, deletion or task execution.
    [void]$root.RegisterTaskDefinition('Launch Kiosk',$definition,2,$Context.Sid,$null,3,$null)
}

function Get-KioskLaunchTaskCheck {
    param([string]$UserName,$Account)
    $context=Get-KioskLaunchTaskContext $UserName $Account
    $status='Fail';$note='Task not verified; no task was changed.';$fields=Get-KioskLaunchTaskFields $context 'Not verified'
    $created=$false;$failure=$null
    try{
        $tasks=@(Get-KioskLaunchTaskInventory)
        $snapshot=Read-KioskLaunchTaskSnapshot -Tasks $tasks -Context $context
        if($tasks.Count -eq 0 -and (Test-CanApply)){
            if(-not $context.Ready){$note='Missing task was not created: '+$context.Reason}
            else{
                # Read again after preflight. TASK_CREATE also protects the final race.
                $tasks=@(Get-KioskLaunchTaskInventory)
                if($tasks.Count -eq 0){
                    try{Register-MissingKioskLaunchTask $context;$created=$true}catch{$failure=$_.Exception.Message}
                    $tasks=@(Get-KioskLaunchTaskInventory)
                }
                $snapshot=Read-KioskLaunchTaskSnapshot -Tasks $tasks -Context $context
                if($failure){$note='Task creation failed: '+$failure+' Existing tasks were preserved. '+$snapshot.Reason}
                elseif($created -and $snapshot.Passed){$status='Remediated';$note='Created missing Launch Kiosk task; readback verified. The task was not executed.'}
                elseif($created -and $snapshot.Verified){$note='Created missing Launch Kiosk task; readback shows configuration mismatches. Manual action required. '+$snapshot.Reason}
                elseif($created){$note='Task creation returned, but configuration readback was not verified. Manual action required. '+$snapshot.Reason}
                else{$note=$snapshot.Reason;if($snapshot.Passed){$status='Pass'}}
            }
        }else{$note=$snapshot.Reason;if($snapshot.Passed){$status='Pass'}}
        $fields=$snapshot.Fields
    }catch{$note='Task Scheduler verification failed: '+$_.Exception.Message+' No existing task was replaced.';if($created){$note+=' Creation returned, but readback was not verified; manual review required.'}}
    if($context.StartupBat -eq 'Also present (unchanged)'){$note+=' Startup BAT also exists; both logon launch paths remain configured.'}
    $history=if($fields['Task'] -eq 'Available' -and $tasks.Count -eq 1){Get-KioskLaunchTaskHistory $tasks}elseif($fields['Task'] -eq 'Missing'){Get-KioskLaunchTaskHistory @()}else{[ordered]@{'Last Run'='Not verified';'Next Run'='Not verified'}}
    foreach($label in $history.Keys){$fields[$label]=$history[$label]}
    $result=New-CheckResult $status $note 'Kiosk launch task inspected'
    $result|Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml $fields)
    $result|Add-Member NoteProperty ExpectedHtml (ConvertTo-ReportDefinitionHtml (Get-KioskLaunchTaskRequirements $context))
    $result
}

function Invoke-KioskLaunchTaskCheck {
    param([string]$UserName,$Account)
    $result=Get-KioskLaunchTaskCheck $UserName $Account
    Add-AuditEntry -SectionNumber 2 -SectionTitle 'Kiosk Application & Policies' -ItemTitle 'Kiosk Launch Task' -ItemSub 'Type: Missing-only logon task repair' -Shortcut (New-ReportCommand @('taskschd.msc','schtasks.exe /Query /TN "\Launch Kiosk" /XML')) -FoundStateHtml $result.StateHtml -Status $result.Status -ActionTaken ([Net.WebUtility]::HtmlEncode($result.Action))
    $auditRows[$auditRows.Count-1]|Add-Member NoteProperty ExpectedHtml $result.ExpectedHtml
}

$kioskAccount = $null
try {
    Start-AuditStep 3 'SELISE local accounts'
    $accountCheck = Get-KioskAccountCheck
    $kioskAccount = $accountCheck.Account
    if ($null -ne $kioskAccount) { $kioskUser = [string]$kioskAccount.Name }
    Add-ResultEntry $sec2Num $sec2Title 'KIOSK Account' $accountCheck.Result
} catch { Add-ResultEntry $sec2Num $sec2Title 'KIOSK Account' (New-CheckResult 'Fail' $_.Exception.Message 'Local account lookup or property inspection failed; kiosk prerequisites were not verified') }

if ($null -ne $kioskAccount) {
try {
    Start-AuditStep 4 'Kiosk profile and launcher'
    $result = Invoke-KioskLauncherConfiguration -UserName $kioskUser -Restaurant $RestaurantId -Kiosk $KioskId -Hostname $KioskHostname
    if ($result.PSObject.Properties['LauncherValues'] -and -not [string]::IsNullOrWhiteSpace([string]$result.LauncherValues['Restaurant ID'])) { $reportRestaurantId = [string]$result.LauncherValues['Restaurant ID'] }
    if ($result.PSObject.Properties['LauncherValues'] -and $result.LauncherValues['KIOSK ID'] -notin @($null,'','Not detected')) { $reportKioskId = [string]$result.LauncherValues['KIOSK ID'] }
    Add-ResultEntry $sec2Num $sec2Title 'Kiosk Launch Architecture' $result
    $auditRows[-1]|Add-Member NoteProperty ExpectedHostName $(if(Test-CanApply){$KioskHostname}else{Get-ThoroughDeviceHostname})
} catch { Add-ResultEntry $sec2Num $sec2Title 'Kiosk Launch Architecture' (New-CheckResult 'Fail' $_.Exception.Message 'Launcher configuration failed') }

try {
    $profile = Get-KioskProfilePath $kioskUser
    if (-not $profile) { throw 'SELISE-KIOSK Windows profile is not available. Sign in as SELISE-KIOSK once to initialize it.' }
    $startupPath = Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    $startupLauncher = Join-Path $startupPath 'LaunchKiosk.bat'
    $desktopShortcut = Join-Path $profile 'Desktop\Launch Kiosk.lnk'
    $startupLauncherAvailable = Test-Path -LiteralPath $startupLauncher -PathType Leaf -ErrorAction Stop
    $desktopShortcutAvailable = Test-Path -LiteralPath $desktopShortcut -PathType Leaf -ErrorAction Stop
    $startupHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{
        'Location' = $startupPath
        'Startup BAT' = $(if ($startupLauncherAvailable) { [IO.Path]::GetFileName($startupLauncher) } else { 'Missing. Manual action required.' })
        'Desktop Shortcut' = $(if ($desktopShortcutAvailable) { [IO.Path]::GetFileName($desktopShortcut) } else { 'Missing. Manual action required.' })
    })
    $startupStatus = if ($startupLauncherAvailable -and $desktopShortcutAvailable) { 'Pass' } else { 'Fail' }
    $startupAction = if ($startupStatus -eq 'Pass') { 'Startup BAT and kiosk desktop shortcut are available; filenames recorded. No files were changed.' } else { 'Startup BAT or kiosk desktop shortcut is missing. Manual action required. No files were changed.' }
    Add-AuditEntry $sec2Num $sec2Title 'SELISE-KIOSK Startup Folder' 'Type: User Startup' (New-ReportCommand @('explorer.exe "' + $startupPath + '"')) $startupHtml $startupStatus $startupAction
} catch {
    $startupHtml = ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Location'='Not verified. Please check manually.'; 'Startup BAT'='Not verified. Please check manually.'; 'Desktop Shortcut'='Not verified. Please check manually.' })
    Add-AuditEntry $sec2Num $sec2Title 'SELISE-KIOSK Startup Folder' 'Type: User Startup' '<code>explorer.exe</code>' $startupHtml 'Fail' ([Net.WebUtility]::HtmlEncode($_.Exception.Message))
}

try {
    Start-AuditStep 5 'Kiosk auto-login'
    $result = Test-KioskAutoLogin -UserName $kioskUser
    Add-ResultEntry $sec2Num $sec2Title 'Kiosk Auto-Login' $result
} catch { Add-ResultEntry $sec2Num $sec2Title 'Kiosk Auto-Login' (New-CheckResult 'Fail' $_.Exception.Message 'Auto-login verification failed') }

Start-AuditStep 6 'System and Edge policies'
try { Add-ResultEntry $sec2Num $sec2Title 'System & Browser Policies' (Invoke-BrowserPolicyCheck -UserName $kioskUser) }
catch { Add-ResultEntry $sec2Num $sec2Title 'System & Browser Policies' (New-CheckResult 'Fail' $_.Exception.Message 'Policy configuration failed') }
} else {
    Write-Verbose 'Kiosk account unavailable: launcher, startup, auto-login and browser-policy checks were omitted.'
}

Invoke-KioskLaunchTaskCheck -UserName $kioskUser -Account $kioskAccount

# =============================================================
# GROUP 3: CORE BACKGROUND SERVICES
# =============================================================
$sec3Num = 3
$sec3Title = 'Core Background Services'
$secAppNum = 5
$secAppTitle = 'AppSettings Check'

function Get-AuditService {
    param([Parameter(Mandatory = $true)][string]$ServiceName)
    # Escape WQL literals and retrieve only the requested service on each readback.
    $escapedServiceName = $ServiceName.Replace('\', '\\').Replace("'", "\'")
    Write-AuditOperation "Reading service '$ServiceName'..."
    return Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedServiceName'" -OperationTimeoutSec 30 -ErrorAction Stop |
        Where-Object { $_.Name -eq $ServiceName } | Select-Object -First 1
}

function Get-ServiceRecoverySnapshot {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not ('KioskAudit.ServiceRecoverySettings' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace KioskAudit {
    public sealed class RecoveryPolicySnapshot {
        public UInt32 ResetPeriod;
        public int[] ActionTypes = new int[0];
        public UInt32[] DelaysMs = new UInt32[0];
    }
    public static class ServiceRecoverySettings {
        [StructLayout(LayoutKind.Sequential)]
        private struct FailureActions {
            public UInt32 ResetPeriod;
            public IntPtr RebootMessage;
            public IntPtr Command;
            public UInt32 ActionCount;
            public IntPtr Actions;
        }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenSCManager(string machine, string database, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig2(IntPtr service, UInt32 level, IntPtr buffer, UInt32 length, out UInt32 needed);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfig2(IntPtr service, UInt32 level, ref FailureActions policy);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        private static void Validate(RecoveryPolicySnapshot value) {
            if (value == null || value.ActionTypes == null || value.DelaysMs == null || value.ActionTypes.Length != value.DelaysMs.Length)
                throw new InvalidOperationException("Recovery action and timing data could not be verified.");
        }
        private static int ActionAt(RecoveryPolicySnapshot value, int index) {
            return value.ActionTypes.Length == 0 ? 0 : value.ActionTypes[Math.Min(index, value.ActionTypes.Length - 1)];
        }
        private static UInt32 DelayAt(RecoveryPolicySnapshot value, int index) {
            return value.DelaysMs.Length == 0 ? 0U : value.DelaysMs[Math.Min(index, value.DelaysMs.Length - 1)];
        }
        public static bool MatchesActions(RecoveryPolicySnapshot value, bool restartFirstTwo) {
            Validate(value);
            int count = Math.Max(3, value.ActionTypes.Length);
            for (int index = 0; index < count; index++) {
                int expected = restartFirstTwo && index < 2 ? 1 : 0;
                if (ActionAt(value, index) != expected) return false;
            }
            return true;
        }
        public static RecoveryPolicySnapshot WithRequiredActions(RecoveryPolicySnapshot current, bool restartFirstTwo) {
            Validate(current);
            int count = Math.Max(3, current.ActionTypes.Length);
            RecoveryPolicySnapshot result = new RecoveryPolicySnapshot();
            result.ResetPeriod = current.ResetPeriod;
            result.ActionTypes = new int[count];
            result.DelaysMs = new UInt32[count];
            for (int index = 0; index < count; index++) {
                result.ActionTypes[index] = restartFirstTwo && index < 2 ? 1 : 0;
                // Windows repeats the last entry for further failures. Preserve
                // that existing delay when a missing action slot must be added.
                // An absent action array has no configured delay (zero).
                result.DelaysMs[index] = DelayAt(current, index);
            }
            return result;
        }
        public static bool TimingMatches(RecoveryPolicySnapshot before, RecoveryPolicySnapshot after) {
            Validate(before); Validate(after);
            if (before.ResetPeriod != after.ResetPeriod) return false;
            int count = Math.Max(before.DelaysMs.Length, after.DelaysMs.Length);
            for (int index = 0; index < count; index++) {
                if (DelayAt(before, index) != DelayAt(after, index)) return false;
            }
            return true;
        }
        private static IntPtr ReadBuffer(IntPtr service, out FailureActions policy, out UInt32 allocated) {
            UInt32 needed;
            bool first = QueryServiceConfig2(service, 2, IntPtr.Zero, 0, out needed);
            int error = Marshal.GetLastWin32Error();
            if (!first && error != 122) throw new Win32Exception(error);
            if (needed < Marshal.SizeOf(typeof(FailureActions)) || needed > Int32.MaxValue)
                throw new InvalidOperationException("Invalid recovery configuration buffer.");
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            allocated = needed;
            try {
                if (!QueryServiceConfig2(service, 2, buffer, allocated, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
                policy = (FailureActions)Marshal.PtrToStructure(buffer, typeof(FailureActions));
                return buffer;
            } catch { Marshal.FreeHGlobal(buffer); throw; }
        }
        private static RecoveryPolicySnapshot Snapshot(FailureActions policy, IntPtr buffer, UInt32 allocated) {
            RecoveryPolicySnapshot value = new RecoveryPolicySnapshot();
            value.ResetPeriod = policy.ResetPeriod;
            if (policy.ActionCount == 0) return value;
            long start = buffer.ToInt64(), actions = policy.Actions.ToInt64();
            long bytes = (long)policy.ActionCount * 8;
            if (policy.ActionCount > Int32.MaxValue || policy.Actions == IntPtr.Zero || actions < start || bytes > allocated || actions - start > allocated - bytes)
                throw new InvalidOperationException("Invalid recovery action/timing array.");
            value.ActionTypes = new int[(int)policy.ActionCount];
            value.DelaysMs = new UInt32[(int)policy.ActionCount];
            for (int index = 0; index < value.ActionTypes.Length; index++) {
                value.ActionTypes[index] = Marshal.ReadInt32(policy.Actions, index * 8);
                value.DelaysMs[index] = unchecked((UInt32)Marshal.ReadInt32(policy.Actions, index * 8 + 4));
            }
            return value;
        }
        private static RecoveryPolicySnapshot ReadHandle(IntPtr service) {
            FailureActions policy; UInt32 allocated;
            IntPtr buffer = ReadBuffer(service, out policy, out allocated);
            try { return Snapshot(policy, buffer, allocated); }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        public static RecoveryPolicySnapshot Read(string name) {
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
            try {
                manager = OpenSCManager(null, null, 1);
                if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                service = OpenService(manager, name, 1);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                return ReadHandle(service);
            } finally {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                if (manager != IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
        public static void SetActions(string name, bool restartFirstTwo) {
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero, buffer = IntPtr.Zero, actions = IntPtr.Zero;
            try {
                manager = OpenSCManager(null, null, 1);
                if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                // Query/change configuration; restart actions also require SERVICE_START.
                service = OpenService(manager, name, restartFirstTwo ? 0x13U : 0x3U);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                FailureActions policy; UInt32 allocated;
                buffer = ReadBuffer(service, out policy, out allocated);
                RecoveryPolicySnapshot before = Snapshot(policy, buffer, allocated);
                if (MatchesActions(before, restartFirstTwo)) return;
                RecoveryPolicySnapshot desired = WithRequiredActions(before, restartFirstTwo);
                actions = Marshal.AllocHGlobal(checked(desired.ActionTypes.Length * 8));
                for (int index = 0; index < desired.ActionTypes.Length; index++) {
                    Marshal.WriteInt32(actions, index * 8, desired.ActionTypes[index]);
                    Marshal.WriteInt32(actions, index * 8 + 4, unchecked((int)desired.DelaysMs[index]));
                }
                // Preserve the original reset period and every effective delay.
                // Null message/command pointers mean leave those values unchanged.
                policy.ResetPeriod = desired.ResetPeriod;
                policy.RebootMessage = IntPtr.Zero;
                policy.Command = IntPtr.Zero;
                policy.ActionCount = (UInt32)desired.ActionTypes.Length;
                policy.Actions = actions;
                if (!ChangeServiceConfig2(service, 2, ref policy)) throw new Win32Exception(Marshal.GetLastWin32Error());
                RecoveryPolicySnapshot after = ReadHandle(service);
                if (!MatchesActions(after, restartFirstTwo) || !TimingMatches(before, after))
                    throw new InvalidOperationException("Recovery action readback failed or existing timing was not preserved.");
            } finally {
                if (actions != IntPtr.Zero) Marshal.FreeHGlobal(actions);
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                if (manager != IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
    }
}
'@
    }
    [KioskAudit.ServiceRecoverySettings]::Read($ServiceName)
}

function Set-ServiceRecoveryActionPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName,[switch]$RestartFirstTwo)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    [void](Get-ServiceRecoverySnapshot -ServiceName $ServiceName)
    [KioskAudit.ServiceRecoverySettings]::SetActions($ServiceName,[bool]$RestartFirstTwo)
}

function Read-ServiceRecoveryPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    $snapshot=Get-ServiceRecoverySnapshot -ServiceName $ServiceName
    [KioskAudit.ServiceRecoverySettings]::MatchesActions($snapshot,$true)
}

function Invoke-ServiceRecoveryRepair {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    Set-ServiceRecoveryActionPolicy -ServiceName $ServiceName -RestartFirstTwo
    if (-not (Read-ServiceRecoveryPolicy -ServiceName $ServiceName)) {throw 'Required recovery actions were not verified after Apply.'}
    return $true
}

function Read-ServiceNoActionRecoveryPolicy {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    $snapshot=Get-ServiceRecoverySnapshot -ServiceName $ServiceName
    [KioskAudit.ServiceRecoverySettings]::MatchesActions($snapshot,$false)
}

function Invoke-ServiceNoActionRecoveryRepair {
    param([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not (Test-CanApply)) {throw 'Recovery changes are disabled in Audit mode.'}
    Set-ServiceRecoveryActionPolicy -ServiceName $ServiceName
    if (-not (Read-ServiceNoActionRecoveryPolicy -ServiceName $ServiceName)) {throw 'Take No Action recovery was not verified after Apply.'}
    return $true
}


function Get-ServiceRecoveryActionTypes {
    param ([Parameter(Mandatory=$true)][string]$ServiceName)
    if (-not ('KioskAudit.ServiceRecoveryReportReader' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace KioskAudit {
    public static class ServiceRecoveryReportReader {
        [StructLayout(LayoutKind.Sequential)]
        private struct FailureActions {
            public UInt32 ResetPeriod;
            public IntPtr RebootMessage;
            public IntPtr Command;
            public UInt32 ActionCount;
            public IntPtr Actions;
        }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenSCManager(string machine, string database, UInt32 access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, UInt32 access);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig2(IntPtr service, UInt32 level, IntPtr buffer, UInt32 length, out UInt32 needed);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);
        public static int[] ReadActionTypes(string name) {
            IntPtr manager=IntPtr.Zero, service=IntPtr.Zero, buffer=IntPtr.Zero;
            try {
                manager=OpenSCManager(null,null,1);
                if(manager==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                service=OpenService(manager,name,1);
                if(service==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                UInt32 needed;
                bool first=QueryServiceConfig2(service,2,IntPtr.Zero,0,out needed);
                int error=Marshal.GetLastWin32Error();
                if(!first && error!=122) throw new Win32Exception(error);
                if(needed==0 || needed>Int32.MaxValue) throw new InvalidOperationException("Invalid recovery buffer size.");
                buffer=Marshal.AllocHGlobal((int)needed);
                UInt32 allocated=needed;
                if(!QueryServiceConfig2(service,2,buffer,allocated,out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
                FailureActions policy=(FailureActions)Marshal.PtrToStructure(buffer,typeof(FailureActions));
                if(policy.ActionCount==0) return new int[0];
                long start=buffer.ToInt64(), actions=policy.Actions.ToInt64();
                long bytes=(long)policy.ActionCount*8;
                if(policy.Actions==IntPtr.Zero || actions<start || bytes>allocated || actions-start>allocated-bytes)
                    throw new InvalidOperationException("Invalid recovery action array.");
                int[] result=new int[(int)policy.ActionCount];
                for(int index=0;index<result.Length;index++) result[index]=Marshal.ReadInt32(policy.Actions,index*8);
                return result;
            } finally {
                if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if(service!=IntPtr.Zero) CloseServiceHandle(service);
                if(manager!=IntPtr.Zero) CloseServiceHandle(manager);
            }
        }
    }
}
'@
    }
    [KioskAudit.ServiceRecoveryReportReader]::ReadActionTypes($ServiceName)
}

function ConvertFrom-ServiceRecoveryActionTypes {
    param ([AllowEmptyCollection()][int[]]$Types)
    $names=@{ 0='Take No Action'; 1='Restart the service'; 2='Restart the computer'; 3='Run a program' }
    $values=for ($index=0;$index -lt 3;$index++) {
        $action=if ($Types.Count -eq 0) { 0 } else { $Types[[Math]::Min($index,$Types.Count-1)] }
        if ($names.ContainsKey($action)) { $names[$action] } else { 'Unknown action ('+$action+')' }
    }
    if ($Types.Count -gt 3) {
        $subsequent=@(for ($index=2;$index -lt $Types.Count;$index++) {
            $action=$Types[$index]
            if ($names.ContainsKey($action)) { $names[$action] } else { 'Unknown action ('+$action+')' }
        }) | Select-Object -Unique
        $values[2]=$subsequent -join ' / '
    }
    [pscustomobject]@{ First=$values[0]; Second=$values[1]; Subsequent=$values[2]; Verified=(@($Types | Where-Object { $_ -notin @(0,1,2,3) }).Count -eq 0); Error='' }
}

function Get-ServiceRecoveryDetails {
    param ([Parameter(Mandatory=$true)][string]$ServiceName)
    try { ConvertFrom-ServiceRecoveryActionTypes -Types @(Get-ServiceRecoveryActionTypes -ServiceName $ServiceName) }
    catch { [pscustomobject]@{ First='Not verified'; Second='Not verified'; Subsequent='Not verified'; Verified=$false; Error=$_.Exception.Message } }
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


function Invoke-RequiredServiceCheck {
    param([string]$ServiceName, [string]$ItemTitle, [string]$ItemSub, [switch]$DeferConsole)
    $serviceStatus = 'Fail'
    $serviceState = 'Not verified'
    $startupState = 'Not verified'
    $recoveryState = 'Not verified'
    $serviceActions = [System.Collections.Generic.List[string]]::new()
    try {
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service is not installed; install it before retrying.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        if (Test-CanApply) {
            if ($serviceSnapshot.StartMode -ne 'Auto') {
                Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
                $serviceActions.Add('Startup set to Automatic')
            }
            if ($serviceSnapshot.State -ne 'Running') {
                Start-Service -Name $ServiceName -ErrorAction Stop
                $waitService = Get-Service -Name $ServiceName -ErrorAction Stop
                $waitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
                $serviceActions.Add('Service started')
            }
        }
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service disappeared during verification.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        $recoveryValid = Read-ServiceRecoveryPolicy -ServiceName $ServiceName
        if (-not $recoveryValid -and (Test-CanApply)) {
            $recoveryValid = Invoke-ServiceRecoveryRepair -ServiceName $ServiceName
            $serviceActions.Add('Crash recovery configured and verified')
        }
        $serviceSnapshot = Get-AuditService -ServiceName $ServiceName
        if (-not $serviceSnapshot) { throw 'Service disappeared during final verification.' }
        $serviceState = [string]$serviceSnapshot.State
        $startupState = [string]$serviceSnapshot.StartMode
        $recoveryState = if ($recoveryValid) { 'Verified' } else { 'Required restart policy is missing' }
        if ($serviceState -ne 'Running' -or $startupState -ne 'Auto' -or -not $recoveryValid) {
            throw "Required Running / Automatic / restart recovery. Found: $serviceState / $startupState / $recoveryState."
        }
        $serviceStatus = 'Pass'
        if ($serviceActions.Count -eq 0) { $serviceActions.Add('Service settings verified; no changes needed') }
    } catch {
        $serviceActions.Add("Failed: $($_.Exception.Message)")
        if (-not (Test-CanApply)) { $serviceActions.Add('Audit only: no changes made; run apply mode after review') }
        # Preserve truthful current state even when a repair failed halfway through.
        try {
            $failedSnapshot = Get-AuditService -ServiceName $ServiceName
            if ($failedSnapshot) {
                $serviceState = [string]$failedSnapshot.State
                $startupState = [string]$failedSnapshot.StartMode
            }
        } catch { $serviceActions.Add('Current service state could not be refreshed') }
    }
    $recoveryDetails=Get-ServiceRecoveryDetails -ServiceName $ServiceName
    if (-not $recoveryDetails.Verified) {
        $serviceStatus='Fail'
        $serviceActions.Add('Recovery actions not verified: '+$recoveryDetails.Error)
    }
    $findingArguments=@{ ServiceState=$serviceState; StartupType=$startupState; Recovery=$recoveryDetails }
    if ($ItemSub -eq 'Type: Payment Gateway Middleware') { $findingArguments.ServiceName=$ServiceName; $findingArguments.Version='Not verified' }
    $serviceFound=ConvertTo-ServiceFindingHtml @findingArguments
    $serviceShortcut = '<code>services.msc</code>'
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle $ItemTitle -ItemSub $ItemSub -Shortcut $serviceShortcut -FoundStateHtml $serviceFound -Status $serviceStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode(($serviceActions -join '; '))) -DeferConsole:$DeferConsole
    $auditRows[$auditRows.Count-1] | Add-Member -NotePropertyName RecoveryDetails -NotePropertyValue $recoveryDetails
}

function Get-PaymentExecutablePath {
    param ($Service)
    $commandLine = [Environment]::ExpandEnvironmentVariables([string]$Service.PathName).Trim()
    $match = [regex]::Match($commandLine, '^(?:"([^"]+\.exe)"|(.+?\.exe))(?=\s|$)', 'IgnoreCase')
    if (-not $match.Success) { throw "Executable path is not readable for $($Service.Name)." }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Get-PaymentExecutableVersion {
    param ($Service)
    $path = Get-PaymentExecutablePath $Service
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
    if (-not $info.FileVersion) { throw "Executable version is missing for $($Service.Name)." }
    [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Get-ThoroughPaymentVersionDetails {
    param ([Parameter(Mandatory = $true)][string]$ExecutablePath)
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath).FileVersion
    if ([string]::IsNullOrWhiteSpace($fileVersion)) { $fileVersion = 'Not detected' }
    $executableFolder = Split-Path $ExecutablePath -Parent
    $packageVersion = $null
    foreach ($versionFile in @(
        (Join-Path $executableFolder 'version.txt'),
        (Join-Path (Split-Path $executableFolder -Parent) 'version.txt')
    )) {
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $candidate = ([IO.File]::ReadAllText($versionFile)).Trim()
            $parsed = $null
            if ([version]::TryParse($candidate, [ref]$parsed)) { $packageVersion = $candidate; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($packageVersion)) { $packageVersion = $fileVersion }
    [pscustomobject]@{ Version = $packageVersion; ExecutableFileVersion = $fileVersion }
}

function Remove-ThoroughPaymentJsonComments {
    param ([Parameter(Mandatory = $true)][string]$Text)
    $output = New-Object Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($lineComment) {
            if ($character -eq "`r" -or $character -eq "`n") { $lineComment = $false; [void]$output.Append($character) }
            continue
        }
        if ($blockComment) {
            if ($character -eq '*' -and $next -eq '/') { $blockComment = $false; $index++; continue }
            if ($character -eq "`r" -or $character -eq "`n") { [void]$output.Append($character) }
            continue
        }
        if ($inString) {
            [void]$output.Append($character)
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; [void]$output.Append($character); continue }
        if ($character -eq '/' -and $next -eq '/') { $lineComment = $true; $index++; continue }
        if ($character -eq '/' -and $next -eq '*') { $blockComment = $true; $index++; continue }
        [void]$output.Append($character)
    }
    if ($blockComment) { throw 'appsettings.json contains an unterminated block comment.' }
    $output.ToString()
}

function ConvertFrom-ThoroughPaymentJson {
    param ([Parameter(Mandatory = $true)][string]$Text)
    Remove-ThoroughPaymentJsonComments $Text | ConvertFrom-Json -ErrorAction Stop
}

function Get-ThoroughPaymentConfigValue {
    param ($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $null
    }
    $property = $Object.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Find-ThoroughPaymentConfigValues {
    param ($Object, [Parameter(Mandatory = $true)][string]$Name, [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 20 -or $Object -is [string] -or $Object -is [ValueType]) { return }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { Write-Output $Object[$key] }
            Find-ThoroughPaymentConfigValues $Object[$key] $Name ($Depth + 1)
        }
        return
    }
    if ($Object -is [Collections.IEnumerable]) {
        foreach ($item in $Object) { Find-ThoroughPaymentConfigValues $item $Name ($Depth + 1) }
        return
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ieq $Name) { Write-Output $property.Value }
        Find-ThoroughPaymentConfigValues $property.Value $Name ($Depth + 1)
    }
}

function Format-ThoroughPaymentAuditValue {
    param ($Value)
    if ($null -eq $Value) { return 'Not configured' }
    if ($Value -is [string] -and $Value.Length -eq 0) { return '(empty)' }
    if ($Value -is [bool]) { return $Value.ToString() }
    return [string]$Value
}

function Add-ThoroughPaymentTerminalLines {
    param (
        [Parameter(Mandatory = $true)][Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)][string]$Label,
        $Terminals,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )
    $items = @($Terminals)
    if ($items.Count -eq 0 -or $null -eq $items[0]) {
        $Lines.Add("  ${Label}: Not configured")
        return
    }
    for ($index = 0; $index -lt $items.Count; $index++) {
        foreach ($field in $Fields) {
            $value = Get-ThoroughPaymentConfigValue $items[$index] $field
            $Lines.Add(("  {0} {1} {2}: {3}" -f $Label, ($index + 1), $field, (Format-ThoroughPaymentAuditValue $value)))
        }
    }
}

function Get-ThoroughPaymentConfigurationAuditLines {
    param (
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ConfigurationPath
    )
    $lines = New-Object 'Collections.Generic.List[string]'
    $provider = ([string](Get-ThoroughPaymentConfigValue $Configuration 'PaymentService')).Trim().ToUpperInvariant()
    $providerDisplay = if ([string]::IsNullOrWhiteSpace($provider)) { 'Not configured' } else { $provider }
    $lines.Add('AppSettings File:')
    $lines.Add('  Payment Service: ' + $ServiceName)
    $lines.Add('  File Path: ' + $ConfigurationPath)
    $lines.Add('  PaymentService: ' + $providerDisplay)

    $paymentConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'PaymentConfiguration'
    $lines.Add('PaymentConfiguration:')
    switch ($provider) {
        'PRINT' {
            $lines.Add('  Terminal Sections: Ignored for PRINT')
        }
        'SIX' {
            $lines.Add('  SixTerminals:')
            Add-ThoroughPaymentTerminalLines $lines 'SixTerminal' (Get-ThoroughPaymentConfigValue $paymentConfiguration 'SixTerminals') @('KioskId', 'TerminalId', 'Currency', 'LogDirectory', 'IsDeferredInitiation')
        }
        { $_ -in @('NETS', 'NEXIDE') } {
            $lines.Add('  NetsTerminals:')
            $terminals = Get-ThoroughPaymentConfigValue $paymentConfiguration 'NetsTerminals'
            Add-ThoroughPaymentTerminalLines $lines 'NetsTerminal' $terminals @('PosId', 'KioskId', 'TerminalIPAddress', 'TerminalId', 'Currency', 'Language', 'IsSetupEnabled')
        }
        default {
            $lines.Add('  Terminal Sections: Not configured')
        }
    }

    $scheduleConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'ScheduleConfiguration'
    $nestedSchedules = Get-ThoroughPaymentConfigValue $scheduleConfiguration 'Schedules'
    $schedules = if ($null -ne $nestedSchedules) { @($nestedSchedules) } else { @($scheduleConfiguration) }
    $kioskPrintSchedules = @($schedules | Where-Object { [string](Get-ThoroughPaymentConfigValue $_ 'Provider') -ieq 'KitchenTicketPrint' })
    if ($kioskPrintSchedules.Count -eq 0) {
        $lines.Add('WebApp Printer:')
        foreach ($field in @('Provider', 'BranchUUID', 'IsKioskPrintingEnabled', 'IsEnabled')) { $lines.Add("  ${field}: Not configured") }
    } else {
        for ($index = 0; $index -lt $kioskPrintSchedules.Count; $index++) {
            $label = if ($kioskPrintSchedules.Count -eq 1) { 'WebApp Printer:' } else { 'WebApp Printer {0}:' -f ($index + 1) }
            $lines.Add($label)
            foreach ($field in @('Provider', 'BranchUUID', 'IsKioskPrintingEnabled', 'IsEnabled')) {
                $lines.Add("  ${field}: " + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $kioskPrintSchedules[$index] $field)))
            }
        }
    }
    if($provider -in @('SIX','NETS','NEXIDE')){
        $payoutSchedules=@(Get-ThoroughPayoutSchedules -Schedules $schedules -Provider $provider)
        if($payoutSchedules.Count -eq 0){
            $lines.Add(('Cron Job - '+$(if($provider -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'})+':'))
            foreach($field in @('Provider','IsEnabled')){$lines.Add("  ${field}: Not configured")}
        }else{
            for($index=0;$index -lt $payoutSchedules.Count;$index++){
                $label='Cron Job - '+$(if($provider -eq 'SIX'){'SIX Terminal'}else{'NETS Terminal'})+':'
                $lines.Add($label)
                foreach($field in @('Provider','IsEnabled')){$lines.Add("  ${field}: "+(Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $payoutSchedules[$index] $field)))}
            }
        }
    }
    $printConfiguration = Get-ThoroughPaymentConfigValue $Configuration 'Print'
    $lines.Add('Print:')
    $lines.Add('  Kitchen Printer: ' + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $printConfiguration 'PrinterName')))
    $lines.Add('  Kiosk/POS Printer: ' + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $printConfiguration 'KioskPrinterName')))
    $lines.Add('Service Endpoints:')
    foreach ($endpoint in @('MonitoringServiceBaseUrl', 'CmsGatewayBaseUrl', 'OrderServiceBaseUrl')) {
        $lines.Add("  ${endpoint}: " + (Format-ThoroughPaymentAuditValue (Get-ThoroughPaymentConfigValue $Configuration $endpoint)))
    }
    return $lines.ToArray()
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

function Select-PaymentPrimary {
    param ([object[]]$Services)
    $candidates = @($Services | Where-Object { $_.State -eq 'Running' })
    if ($candidates.Count -eq 0) { $candidates = @($Services) }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    $ranked = @($candidates | ForEach-Object {
        [pscustomobject]@{ Service = $_; Version = Get-PaymentExecutableVersion $_ }
    } | Sort-Object Version -Descending)
    if ($ranked.Count -eq 0) { throw 'No payment service found.' }
    if ($ranked[0].Version -eq $ranked[1].Version) { throw 'Multiple payment services have the same latest executable version; primary selection requires review.' }
    $ranked[0].Service
}

function Find-SubwayPaymentServices {
    param ([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Services)

    $expectedNames = @('SubwayLocal', 'AspPaymentSubwayProd')
    $expectedServices = @($Services | Where-Object { $expectedNames -contains [string]$_.Name })
    $runningExpectedServices = @($expectedServices | Where-Object { $_.State -eq 'Running' })
    if ($runningExpectedServices.Count -gt 0) { return $expectedServices }

    $runningFallbackServices = @($Services | Where-Object {
        $_.State -eq 'Running' -and (
            $_.PathName -match 'Kiosk Payment Middleware\.exe' -or
            $_.Name -match '^AspPayment' -or
            $_.DisplayName -match 'Payment\s*Middleware|AspPayment'
        )
    })
    if ($runningFallbackServices.Count -gt 0) { return $runningFallbackServices }

    return $expectedServices
}

function Invoke-LegacyPaymentServiceCheck {
    param (
        [Parameter(Mandatory=$true)]$LegacyService,
        [Parameter(Mandatory=$true)][string]$PrimaryServiceName,
        [Parameter(Mandatory=$true)][bool]$PrimaryVerified
    )
    $serviceName=[string]$LegacyService.Name
    $status='Fail'
    $state='Not verified'
    $startup='Not verified'
    $action='Legacy service was not verified'
    $legacyChanges=New-Object 'Collections.Generic.List[string]'
    try {
        if ($serviceName -ieq $PrimaryServiceName) { throw 'Primary service cannot be handled as a legacy service.' }
        $snapshot=Get-AuditService -ServiceName $serviceName
        if (-not $snapshot) { throw 'Legacy service is missing.' }
        $state=[string]$snapshot.State
        $startup=[string]$snapshot.StartMode
        # Complete read-only recovery preflight before changing this service.
        $noAction=Read-ServiceNoActionRecoveryPolicy -ServiceName $serviceName
        if (Test-CanApply) {
            if (-not $PrimaryVerified) { throw 'Primary service verification failed; secondary service preserved.' }
            $primary=Get-AuditService -ServiceName $PrimaryServiceName
            if (-not $primary -or $primary.State -ne 'Running' -or $primary.StartMode -ne 'Auto' -or -not (Read-ServiceRecoveryPolicy -ServiceName $PrimaryServiceName)) {
                throw 'Primary service settings no longer pass verification; secondary service preserved.'
            }
            # Prevent automatic restart before stopping an older payment service.
            if (-not $noAction) { $noAction=Invoke-ServiceNoActionRecoveryRepair -ServiceName $serviceName; $legacyChanges.Add('Recovery actions set to Take No Action') }
            if (-not $noAction) { throw 'Take No Action recovery could not be verified; remaining changes skipped.' }
            if ($startup -ne 'Manual') { Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop; $legacyChanges.Add('Startup set to Manual') }
            if ($state -ne 'Stopped') {
                Stop-Service -Name $serviceName -ErrorAction Stop
                $legacyChanges.Add('Service stop requested')
                $waitService=Get-Service -Name $serviceName -ErrorAction Stop
                $waitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
            }
        }
        $snapshot=Get-AuditService -ServiceName $serviceName
        if (-not $snapshot) { throw 'Legacy service disappeared during verification.' }
        $state=[string]$snapshot.State
        $startup=[string]$snapshot.StartMode
        $noAction=Read-ServiceNoActionRecoveryPolicy -ServiceName $serviceName
        if ($state -ne 'Stopped' -or $startup -ne 'Manual' -or -not $noAction) { throw 'Stopped / Manual with first, second and subsequent failures set to Take No Action is required.' }
        $status='Offline'
        $action=if($legacyChanges.Count){($legacyChanges -join '; ')+'; readback verified'}else{'No change needed; verified Stopped / Manual; all recovery actions: Take No Action'}
        if (-not (Test-CanApply)) { $action+='; Audit only: no changes made' }
    } catch { $action=($legacyChanges -join '; '); if($action){$action+='; '}; $action+='Failed: '+$_.Exception.Message }
    # Read back actual state after any partial failure; never substitute expected values.
    try {
        $snapshot=Get-AuditService -ServiceName $serviceName
        if ($snapshot) { $state=[string]$snapshot.State; $startup=[string]$snapshot.StartMode }
        else { $state='Missing'; $startup='Not verified'; $status='Fail' }
    } catch { $state='Not verified'; $startup='Not verified'; $status='Fail'; $action+='; current service state unreadable' }
    $recovery=Get-ServiceRecoveryDetails -ServiceName $serviceName
    if (-not $recovery.Verified -or $recovery.First -ne 'Take No Action' -or $recovery.Second -ne 'Take No Action' -or $recovery.Subsequent -ne 'Take No Action' -or $state -ne 'Stopped' -or $startup -ne 'Manual') {
        $status='Fail'
        if ($action -notlike 'Failed:*') { $action+='; final service/recovery readback did not meet the requirements' }
    }
    $found=ConvertTo-ServiceFindingHtml -ServiceState $state -StartupType $startup -Recovery $recovery
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle "$serviceName (Legacy)" -ItemSub 'Type: Old Payment Service' -Shortcut '<code>services.msc</code>' -FoundStateHtml $found -Status $status -ActionTaken ([Net.WebUtility]::HtmlEncode($action))
}

function Read-PaymentTaskScriptText {
    param([string]$Path,[string]$WorkingDirectory)
    $pathValue=$Path.Trim('"')
    if($pathValue -match '[%$]' -or $pathValue.StartsWith('\\')){throw 'Task script path is dynamic or remote.'}
    if(-not [IO.Path]::IsPathRooted($pathValue)){
        if(-not [IO.Path]::IsPathRooted($WorkingDirectory) -or $WorkingDirectory.StartsWith('\\') -or $WorkingDirectory -match '[%$]'){throw 'Task script working directory is not a verified local path.'}
        $pathValue=Join-Path $WorkingDirectory $pathValue
    }
    if($pathValue -notmatch '^[A-Za-z]:\\'){throw 'Task script is not on a local Windows drive.'}
    $file=Get-Item -LiteralPath $pathValue -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length -gt 262144){throw 'Task script is unavailable or exceeds the inspection limit.'}
    [IO.File]::ReadAllText($file.FullName)
}

function Get-PaymentTaskLiteral {
    param($Expression,[Collections.IDictionary]$Variables)
    if($Expression -is [Management.Automation.Language.StringConstantExpressionAst]){return [string]$Expression.Value}
    if($Expression -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $Expression.NestedExpressions.Count -eq 0){return [string]$Expression.Value}
    if($Expression -is [Management.Automation.Language.VariableExpressionAst] -and $Variables.Contains($Expression.VariablePath.UserPath)){return [string]$Variables[$Expression.VariablePath.UserPath]}
    throw 'Task service target is not a verified literal value.'
}

function Get-PaymentTaskPowerShellOperations {
    param([string]$Text,[int]$Depth=0)
    if($Depth -gt 2 -or $Text.Length -gt 262144){throw 'Task action exceeds the inspection limit.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.DynamicParamBlock){throw 'Task action syntax or parameters require manual verification.'}
    $variables=@{}
    foreach($statement in $ast.EndBlock.Statements){
        if($statement -is [Management.Automation.Language.AssignmentStatementAst]){
            if($statement.Operator.ToString() -ne 'Equals' -or $statement.Left -isnot [Management.Automation.Language.VariableExpressionAst]){throw 'Dynamic task variable assignment requires manual verification.'}
            $right=$statement.Right
            if($right -is [Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1){$right=$right.PipelineElements[0]}
            if($right -isnot [Management.Automation.Language.CommandExpressionAst]){throw 'Task variable assignment is not static.'}
            $variables[$statement.Left.VariablePath.UserPath]=Get-PaymentTaskLiteral $right.Expression $variables
            continue
        }
        if($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1){throw 'Conditional or indirect task action requires manual verification.'}
        $command=$statement.PipelineElements[0]
        if($command -isnot [Management.Automation.Language.CommandAst]){throw 'Task action is not a verified service command.'}
        $elements=$command.CommandElements
        if($command.InvocationOperator.ToString() -eq 'Ampersand' -and $elements.Count -eq 1 -and $elements[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]){
            Get-PaymentTaskPowerShellOperations -Text $elements[0].ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}') -Depth ($Depth+1)
            continue
        }
        $name=$command.GetCommandName() -replace '^Microsoft\.PowerShell\.Management\\',''
        if($name -in @('Write-Host','Write-Output','Write-Verbose','Start-Sleep')){continue}
        if($name -notin @('Restart-Service','Stop-Service','Start-Service')){throw 'Unsupported task command requires manual verification.'}
        $target=$null
        for($index=1;$index -lt $elements.Count;$index++){
            $element=$elements[$index]
            if($element -is [Management.Automation.Language.CommandParameterAst]){
                if($element.ParameterName -in @('Force','PassThru')){continue}
                if($element.ParameterName -notin @('Name','ErrorAction')){throw 'Unsupported service command parameter.'}
                $argument=$element.Argument
                if($null -eq $argument){$index++;if($index -ge $elements.Count){throw 'Service parameter has no value.'};$argument=$elements[$index]}
                $value=Get-PaymentTaskLiteral $argument $variables
                if($element.ParameterName -eq 'Name'){if($null -ne $target){throw 'Service target is ambiguous.'};$target=$value}
            }else{
                if($null -ne $target){throw 'Multiple service targets require manual verification.'}
                $target=Get-PaymentTaskLiteral $element $variables
            }
        }
        if([string]::IsNullOrWhiteSpace($target) -or $target.IndexOfAny([char[]]'*?[]') -ge 0){throw 'Task service target is missing or contains a wildcard.'}
        [pscustomobject]@{Operation=($name -replace '-Service$','').ToLowerInvariant();Target=$target}
    }
}

function Get-PaymentTaskBatchOperations {
    param([string]$Text)
    foreach($line in @($Text -split '\r?\n|&&')){
        $line=$line.Trim().TrimStart('@')
        if(-not $line -or $line -match '^(?i:rem(?:\s|$)|::|echo\s+off$|timeout\s+/t\s+\d+(?:\s+/nobreak)?$)'){continue}
        if(($line -replace '"[^"]*"','') -match '[&|<>()^]'){throw 'Batch action contains an unsupported shell operator.'}
        $parts=ConvertFrom-KioskEdgeArguments $line
        if($parts.Count -lt 3 -or [IO.Path]::GetFileName($parts[0]) -notin @('net','net.exe','sc','sc.exe') -or $parts[1] -notin @('stop','start')){throw 'Batch action is conditional or unsupported; please check manually.'}
        if($parts.Count -gt 3 -and ($parts.Count -ne 4 -or $parts[3] -ne '/y')){throw 'Batch action contains unsupported service arguments.'}
        if($parts[2] -match '[%$*?\[\]]'){throw 'Batch service target is dynamic.'}
        [pscustomobject]@{Operation=$parts[1].ToLowerInvariant();Target=$parts[2]}
    }
}

function Get-PaymentRestartTaskAction {
    param($Action,[string]$ServiceName)
    $execute=[string](Get-ThoroughPaymentConfigValue $Action 'Execute')
    $arguments=[string](Get-ThoroughPaymentConfigValue $Action 'Arguments')
    $workingDirectory=[string](Get-ThoroughPaymentConfigValue $Action 'WorkingDirectory')
    $summary=($execute+' '+$arguments).Trim()
    $operations=@();$verified=$false;$reason=''
    try{
        $program=[IO.Path]::GetFileName($execute.Trim('"'))
        if($program -in @('powershell','powershell.exe','pwsh','pwsh.exe')){
            $parts=ConvertFrom-KioskEdgeArguments $arguments
            $modeIndex=-1
            for($index=0;$index -lt $parts.Count;$index++){if($parts[$index] -in @('-Command','-c','-File','-f','-EncodedCommand','-enc')){$modeIndex=$index;break}}
            if($modeIndex -lt 0 -or $modeIndex+1 -ge $parts.Count){throw 'PowerShell task action has no readable command or script.'}
            $mode=$parts[$modeIndex];$tail=@($parts | Select-Object -Skip ($modeIndex+1))
            if($mode -in @('-File','-f')){
                if($tail.Count -ne 1){throw 'Parameterized task script requires manual verification.'}
                $code=Read-PaymentTaskScriptText $tail[0] $workingDirectory
            }elseif($mode -in @('-EncodedCommand','-enc')){
                if($tail.Count -ne 1 -or $tail[0].Length -gt 349528){throw 'Encoded task action requires manual verification.'}
                $code=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($tail[0]))
            }else{$code=$tail -join ' '}
            $operations=@(Get-PaymentTaskPowerShellOperations $code)
        }elseif($program -in @('cmd','cmd.exe')){
            $match=[regex]::Match($arguments,'(?is)^\s*(?:(?:/d|/s)\s+)*/c\s+(.+)$')
            if(-not $match.Success){throw 'Command task action has no supported /c command.'}
            $code=$match.Groups[1].Value.Trim()
            if($code.StartsWith('""') -and $code.EndsWith('""')){$code=$code.Substring(1,$code.Length-2)}
            $fileMatch=[regex]::Match($code,'(?is)^(?:"([^"\r\n]+\.(?:bat|cmd))"|([^\s"]+\.(?:bat|cmd)))$')
            if($fileMatch.Success){$scriptPath=if($fileMatch.Groups[1].Success){$fileMatch.Groups[1].Value}else{$fileMatch.Groups[2].Value};$code=Read-PaymentTaskScriptText $scriptPath $workingDirectory}
            elseif($code.StartsWith('"') -and $code.EndsWith('"')){$code=$code.Substring(1,$code.Length-2)}
            $operations=@(Get-PaymentTaskBatchOperations $code)
        }elseif([IO.Path]::GetExtension($program) -in @('.bat','.cmd')){
            if(-not [string]::IsNullOrWhiteSpace($arguments)){throw 'Parameterized batch action requires manual verification.'}
            $operations=@(Get-PaymentTaskBatchOperations (Read-PaymentTaskScriptText $execute $workingDirectory))
        }elseif($program -in @('net','net.exe','sc','sc.exe')){
            $operations=@(Get-PaymentTaskBatchOperations ($program+' '+$arguments))
        }else{throw 'Task action type requires manual verification.'}
        $verified=$true
    }catch{$reason=$_.Exception.Message;$operations=@()}
    [pscustomobject]@{Summary=$summary;Operations=$operations;Verified=$verified;Reason=$reason;ReferencesService=($summary.IndexOf($ServiceName,[StringComparison]::OrdinalIgnoreCase) -ge 0)}
}

function Get-PaymentRestartTaskSchedule {
    param($Task)
    $details=New-Object 'Collections.Generic.List[string]'
    $active=0;$unknown=$false
    $triggers=@(Get-ThoroughPaymentConfigValue $Task 'Triggers' | Where-Object {$null -ne $_})
    foreach($trigger in $triggers){
        $class=Get-ThoroughPaymentConfigValue $trigger 'CimClass'
        $type=[string](Get-ThoroughPaymentConfigValue $class 'CimClassName')
        if(-not $type){$type='Trigger'}else{$type=$type -replace '^MSFT_Task','' -replace 'Trigger$',''}
        $enabled=Get-ThoroughPaymentConfigValue $trigger 'Enabled'
        $start=[string](Get-ThoroughPaymentConfigValue $trigger 'StartBoundary')
        $end=[string](Get-ThoroughPaymentConfigValue $trigger 'EndBoundary')
        $parts=New-Object 'Collections.Generic.List[string]';$parts.Add($type)
        if($enabled -isnot [bool]){$unknown=$true;$parts.Add('Enabled: Not verified')}else{$parts.Add('Enabled: '+$enabled)}
        if($start){$parts.Add('Start: '+$start)}
        if($end){$parts.Add('End: '+$end)}
        foreach($field in @('DaysInterval','WeeksInterval','DaysOfWeek','DaysOfMonth','MonthsOfYear','Delay','RandomDelay')){
            $value=Get-ThoroughPaymentConfigValue $trigger $field
            if($null -ne $value -and [string]$value -ne ''){$parts.Add($field+': '+$value)}
        }
        $repetition=Get-ThoroughPaymentConfigValue $trigger 'Repetition'
        foreach($field in @('Interval','Duration')){$value=[string](Get-ThoroughPaymentConfigValue $repetition $field);if($value){$parts.Add('Repetition '+$field+': '+$value)}}
        $usable=$enabled -is [bool] -and $enabled
        if($end){$endTime=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($end,[ref]$endTime)){$unknown=$true;$usable=$false}elseif($endTime -le [DateTimeOffset]::Now){$usable=$false;$parts.Add('Expired')}}
        if($start){
            $startTime=[DateTimeOffset]::MinValue
            if(-not [DateTimeOffset]::TryParse($start,[ref]$startTime)){$unknown=$true;$usable=$false}
            elseif($type -eq 'Time' -and $startTime -le [DateTimeOffset]::Now){
                $interval=[string](Get-ThoroughPaymentConfigValue $repetition 'Interval')
                $duration=[string](Get-ThoroughPaymentConfigValue $repetition 'Duration')
                if(-not $interval){$usable=$false;$parts.Add('Elapsed one-time trigger')}
                elseif($duration){try{if($startTime.Add([Xml.XmlConvert]::ToTimeSpan($duration)) -le [DateTimeOffset]::Now){$usable=$false;$parts.Add('Repetition period expired')}}catch{$unknown=$true;$usable=$false}}
            }
        }
        if($usable){$active++}
        $details.Add(($parts -join '; '))
    }
    [pscustomobject]@{Configured=($triggers.Count -gt 0);Enabled=($active -gt 0);Unknown=$unknown;Details=($details -join ' | ')}
}

function Invoke-PaymentRestartTaskCheck {
    param([string]$PaymentProvider,[string]$ServiceName)
    if(([string]$PaymentProvider).Trim().ToUpperInvariant() -notin @('NETS','NEXIDE')){return}
    $expected=ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Available';'Task Enabled'='Yes';'Restart Target'=$ServiceName;'Schedule'='Configured';'Schedule Enabled'='Yes'})
    $status='Fail';$note='Task not verified. Please check Task Scheduler manually.'
    $parts=New-Object 'Collections.Generic.List[string]'
    try{
        if([string]::IsNullOrWhiteSpace($ServiceName)){throw 'Selected Payment Service name is unavailable.'}
        $tasks=@(Get-ScheduledTask -ErrorAction Stop)
        $records=New-Object 'Collections.Generic.List[object]'
        foreach($task in $tasks){
            $name=[string](Get-ThoroughPaymentConfigValue $task 'TaskName')
            $path=[string](Get-ThoroughPaymentConfigValue $task 'TaskPath')
            $actions=@(Get-ThoroughPaymentConfigValue $task 'Actions' | Where-Object {$null -ne $_})
            $summaries=New-Object 'Collections.Generic.List[string]'
            $operations=New-Object 'Collections.Generic.List[object]'
            $actionVerified=$actions.Count -gt 0
            $nameHint=$name -match '(?i)restart' -and ($name -match '(?i)payment' -or $name.IndexOf($ServiceName,[StringComparison]::OrdinalIgnoreCase) -ge 0)
            $referencesService=$false
            foreach($action in $actions){
                $evidence=Get-PaymentRestartTaskAction $action $ServiceName
                $summaries.Add($evidence.Summary)
                if(-not $evidence.Verified){$actionVerified=$false}
                if($evidence.ReferencesService){$referencesService=$true}
                foreach($operation in $evidence.Operations){$operations.Add($operation)}
            }
            $restartTargets=@{};$stopped=@{}
            foreach($operation in $operations){
                if($operation.Operation -eq 'restart' -or ($operation.Operation -eq 'start' -and $stopped.ContainsKey($operation.Target))){$restartTargets[$operation.Target]=$true;[void]$stopped.Remove($operation.Target)}
                if($operation.Operation -eq 'stop'){$stopped[$operation.Target]=$true;[void]$restartTargets.Remove($operation.Target)}
            }
            $restarts=@($restartTargets.Keys)
            $targetVerified=$actionVerified -and $restarts -icontains $ServiceName
            $related=$nameHint -or (-not $actionVerified -and $referencesService)
            if(-not $targetVerified -and -not $related){continue}
            $enabled=Get-ThoroughPaymentConfigValue (Get-ThoroughPaymentConfigValue $task 'Settings') 'Enabled'
            $state=[string](Get-ThoroughPaymentConfigValue $task 'State')
            $enabledKnown=$enabled -is [bool] -and $state -in @('Ready','Running','Queued','Disabled')
            $taskEnabled=$enabledKnown -and $enabled -and $state -ne 'Disabled'
            $schedule=Get-PaymentRestartTaskSchedule $task
            $fields=[ordered]@{'Task Name'=$name;'Task Location'=$path;'Task'='Available';'Task State'=$state;'Task Enabled'=$(if(-not $enabledKnown){'Not verified'}elseif($taskEnabled){'Yes'}else{'No'});'Restart Target'=$(if($targetVerified){$ServiceName}elseif($actionVerified -and $restarts.Count){$restarts -join ', '}else{'Not verified. Please check manually.'});'Schedule'=$(if($schedule.Configured){'Configured'}else{'Missing'});'Schedule Enabled'=$(if($schedule.Unknown){'Not verified'}elseif($schedule.Enabled){'Yes'}else{'No'});'Trigger Details'=$(if($schedule.Details){$schedule.Details}else{'No trigger configured'});'Action'=($summaries -join ' | ')}
            $historyVerified=$true
            try{
                $info=Get-ScheduledTaskInfo -TaskName $name -TaskPath $path -ErrorAction Stop
                foreach($field in @('LastRunTime','NextRunTime','LastTaskResult')){
                    $value=Get-ThoroughPaymentConfigValue $info $field
                    $label=switch($field){'LastRunTime'{'Last Run'};'NextRunTime'{'Next Run'};default{'Last Result'}}
                    $fields[$label]=if($null -eq $value){'Not recorded'}elseif($value -is [datetime] -and $value.Year -le 1900){'Not recorded'}elseif($value -is [datetime]){$value.ToString('dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)}else{[string]$value}
                }
            }catch{$historyVerified=$false;$fields['Run History']='Not verified. Please check Task Scheduler manually.'}
            $records.Add([pscustomobject]@{Html=(ConvertTo-ReportDefinitionHtml $fields);Passed=($targetVerified -and $taskEnabled -and $schedule.Configured -and $schedule.Enabled -and -not $schedule.Unknown -and $historyVerified)})
        }
        if($records.Count -eq 0){
            $parts.Add((ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Not found';'Restart Target'=$ServiceName;'Verification'='No verified restart task found. Please check Task Scheduler manually.'})))
            $note='Restart task not found. Please configure or verify it manually.'
        }else{
            for($index=0;$index -lt $records.Count;$index++){
                if($records.Count -gt 1){$parts.Add('<div class="config-item-title">[Task '+($index+1)+']</div>')}
                $parts.Add($records[$index].Html)
            }
            if(@($records | Where-Object {-not $_.Passed}).Count -eq 0){$status='Pass';$note='Existing restart task and schedule verified. No task was changed or executed.'}
        }
    }catch{
        $parts.Add((ConvertTo-ReportDefinitionHtml ([ordered]@{'Task'='Not verified. Please check Task Scheduler manually.';'Restart Target'=$ServiceName})))
        $note='Task Scheduler check not verified: '+$_.Exception.Message
    }
    Add-AuditEntry -SectionNumber 3 -SectionTitle 'Core Background Services' -ItemTitle 'Payment Service Restart Task' -ItemSub 'Type: Read-only Scheduled Task Verification' -Shortcut (New-ReportCommand @('taskschd.msc')) -FoundStateHtml ($parts -join '') -Status $status -ActionTaken ([Net.WebUtility]::HtmlEncode($note))
    $auditRows[$auditRows.Count-1] | Add-Member -NotePropertyName ExpectedHtml -NotePropertyValue $expected
}


# 3.1 Payment Middleware
Start-AuditStep 7 'Payment middleware services'
$paymentServices = @()
$paymentDiscoveryError = $null
$detectedPaymentProvider = 'Not detected'
$selectedPaymentServiceName = $null
$appSettingsRowAdded = $false
try {
    $allServices = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $paymentServices = @(Find-SubwayPaymentServices -Services $allServices)
    if ($paymentServices.Count -eq 0 -and (Test-CanApply)) {
        do {
            $manualServiceName = Read-Host "Please enter EXACT Service Name for Payment Middleware (or type 'skip')"
        } until (-not [string]::IsNullOrWhiteSpace($manualServiceName))
        if ($manualServiceName -ne 'skip') {
            $paymentServices = @($allServices | Where-Object { $_.Name -eq $manualServiceName })
        }
    }
} catch { $paymentDiscoveryError = $_.Exception.Message }

if ($paymentServices.Count -gt 0) {
    try {
    $primaryService = Select-PaymentPrimary $paymentServices
    $selectedPaymentServiceName = [string]$primaryService.Name
    Invoke-RequiredServiceCheck -ServiceName $primaryService.Name -ItemTitle 'Payment Gateway Middleware' -ItemSub 'Type: Payment Gateway Middleware' -DeferConsole
    $primaryServiceRow = $auditRows[$auditRows.Count - 1]
    $primaryExecutablePath = $null
    $primaryServiceState = [string]$primaryService.State
    try {
        $primaryExecutablePath = Get-PaymentExecutablePath $primaryService
        if (-not (Test-Path -LiteralPath $primaryExecutablePath -PathType Leaf)) { throw "Service executable not found: $primaryExecutablePath" }
        $versionDetails = Get-ThoroughPaymentVersionDetails $primaryExecutablePath
        $currentPrimary = Get-AuditService -ServiceName $primaryService.Name
        if (-not $currentPrimary) { throw 'Primary Payment Service disappeared during detail verification.' }
        $primaryServiceState = [string]$currentPrimary.State
        $currentStartup = if ($currentPrimary.StartMode -eq 'Auto') { 'Automatic' } else { [string]$currentPrimary.StartMode }
        $primaryServiceRow.FoundStateHtml=ConvertTo-ServiceFindingHtml -ServiceName $currentPrimary.Name -ServiceState $currentPrimary.State -StartupType $currentPrimary.StartMode -Recovery $primaryServiceRow.RecoveryDetails -Version $versionDetails.Version
        if ([string]::IsNullOrWhiteSpace($versionDetails.Version) -or $versionDetails.Version -in @('Not detected','Not verified')) {
            $primaryServiceRow.Status='Fail'
            $primaryServiceRow.ActionTaken += '; Payment Service version could not be detected.'
        }
    } catch {
        $primaryServiceRow.Status = 'Fail'
        $existingAction = Convert-ReportHtmlToTerminalText $primaryServiceRow.ActionTaken
        $primaryServiceRow.ActionTaken = [Net.WebUtility]::HtmlEncode(($existingAction + '; Payment Service details not verified: ' + $_.Exception.Message).Trim(' ', ';'))
    }

    Write-ThoroughConsoleEntry -Row $primaryServiceRow -Number $auditRows.Count

    $configurationStatus = 'Pass'
    $configurationFound = '<div class="kv-block">Not verified</div>'
    $configurationAction = 'Configuration read from appsettings.json; no configuration values changed'
    $configurationPath = $null
    $configurationLines = @()
    $configurationSnapshot = $null
    try {
        if ($primaryServiceState -ne 'Running') { throw 'A running Payment Service was not found; appsettings.json was not inspected.' }
        if ([string]::IsNullOrWhiteSpace($primaryExecutablePath)) { throw 'Payment Service executable path is unavailable.' }
        $configurationPath = Join-Path (Split-Path $primaryExecutablePath -Parent) 'appsettings.json'
        if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw "appsettings.json not found: $configurationPath" }
        $configuration = ConvertFrom-ThoroughPaymentJson ([IO.File]::ReadAllText($configurationPath))
        $configurationSnapshot = $configuration
        $providerValue = ([string](Get-ThoroughPaymentConfigValue $configuration 'PaymentService')).Trim().ToUpperInvariant()
        $detectedPaymentProvider = if ([string]::IsNullOrWhiteSpace($providerValue)) { 'Not configured' } else { $providerValue }
        $configurationLines = @(Get-ThoroughPaymentConfigurationAuditLines -Configuration $configuration -ServiceName $primaryService.Name -ConfigurationPath $configurationPath)
        $configurationFound = ConvertTo-ThoroughPaymentReportHtml $configurationLines
        $missingConfigurationValues = @($configurationLines | Where-Object {
            $_ -match ':\s*Not configured$' -or ($_ -match ':\s*\(empty\)$' -and $_ -notmatch 'TerminalId:\s*\(empty\)$')
        })
        if ($missingConfigurationValues.Count -gt 0) {
            $configurationStatus = 'Fail'
            $configurationAction = "Configuration was read without changes, but $($missingConfigurationValues.Count) required value(s) are not configured"
        }
    } catch {
        $configurationStatus = 'Fail'
        $configurationAction = "AppSettings check failed: $($_.Exception.Message)"
    }
    $configurationShortcut = if ($configurationPath) { New-ReportCommand @('notepad.exe "' + $configurationPath + '"') } else { '<code>appsettings.json</code>' }
    Add-AuditEntry -SectionNumber $secAppNum -SectionTitle $secAppTitle -ItemTitle 'Payment Service appsettings.json' -ItemSub 'Type: Read-only Configuration Inspection' -Shortcut $configurationShortcut -FoundStateHtml $configurationFound -Status $configurationStatus -ActionTaken ([Net.WebUtility]::HtmlEncode($configurationAction))
    if ($null -ne $configurationSnapshot) {
        $configurationRow = $auditRows[$auditRows.Count - 1]
        $configurationRow | Add-Member -NotePropertyName ConfigurationSnapshot -NotePropertyValue $configurationSnapshot
        $configurationRow | Add-Member -NotePropertyName ConfigurationServiceName -NotePropertyValue $primaryService.Name
        $configurationRow | Add-Member -NotePropertyName ConfigurationPath -NotePropertyValue $configurationPath
    }
    $appSettingsRowAdded = $true

    foreach ($legacy in @($paymentServices | Where-Object { $_.Name -ne $primaryService.Name })) {
        Invoke-LegacyPaymentServiceCheck -LegacyService $legacy -PrimaryServiceName $primaryService.Name -PrimaryVerified ($primaryServiceRow.Status -eq 'Pass')
    }
    } catch {
        Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Payment service selection' -ItemSub 'Type: Payment Middleware' -Shortcut '<code>services.msc</code>' -FoundStateHtml 'Primary not verified' -Status 'Fail' -ActionTaken ([Net.WebUtility]::HtmlEncode($_.Exception.Message))
    }
} else {
    $paymentAction = if ($paymentDiscoveryError) { "Service discovery failed: $paymentDiscoveryError" } else { 'Service not detected. Install Payment Middleware or provide its exact service name in apply mode.' }
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Payment Middleware Service' -ItemSub 'Type: Middleware Service' -Shortcut '<code>services.msc</code>' -FoundStateHtml '<div class="kv-block">Service not detected</div>' -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($paymentAction))
}
if (-not $appSettingsRowAdded) {
    $appSettingsAction = if ($paymentDiscoveryError) { "AppSettings check failed because Payment Service discovery failed: $paymentDiscoveryError" } else { 'AppSettings check requires a running Payment Service; no configuration file was changed' }
    Add-AuditEntry -SectionNumber $secAppNum -SectionTitle $secAppTitle -ItemTitle 'Payment Service appsettings.json' -ItemSub 'Type: Read-only Configuration Inspection' -Shortcut '<code>appsettings.json</code>' -FoundStateHtml '<div class="kv-block">Running Payment Service or configuration path not available</div>' -Status 'Fail' -ActionTaken ([Net.WebUtility]::HtmlEncode($appSettingsAction))
}

# Read-only for Audit, Apply Fix and Thorough Check Report; only selected NETS / NEXIDE.
Invoke-PaymentRestartTaskCheck -PaymentProvider $detectedPaymentProvider -ServiceName $selectedPaymentServiceName

function Get-ZabbixConfiguredHostname {
    param ([string]$CommandLine, [string]$DefaultConfigurationPath = (Join-Path $env:ProgramFiles 'Zabbix Agent 2\zabbix_agent2.conf'))
    $configMatch = [regex]::Match($CommandLine, '(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))')
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 'Not verified (service path unavailable)' }
    if (-not $configMatch.Success) {
        if (-not (Test-Path -LiteralPath $DefaultConfigurationPath -PathType Leaf)) { return 'Not verified (service config path not specified; default file missing)' }
        $path=$DefaultConfigurationPath
    } else { $path = if ($configMatch.Groups[1].Success) { $configMatch.Groups[1].Value } else { $configMatch.Groups[2].Value } }
    $path = [Environment]::ExpandEnvironmentVariables($path)
    if (-not [IO.Path]::IsPathRooted($path)) { return 'Not verified (relative service config path)' }
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($path)
    $visited = @{}
    $hostnames = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        $file = $pending.Dequeue()
        if ($visited.ContainsKey($file)) { continue }
        if ($visited.Count -ge 100) { throw 'Too many Zabbix include files.' }
        $visited[$file] = $true
        foreach ($line in (Get-Content -LiteralPath $file -ErrorAction Stop)) {
            if ($line -match '^\s*Hostname\s*=\s*(.*?)\s*$' -and $Matches[1]) { $hostnames.Add($Matches[1]) }
            elseif ($line -match '^\s*HostnameItem\s*=\s*(.*?)\s*$' -and $Matches[1]) { $items.Add($Matches[1]) }
            elseif ($line -match '^\s*Include\s*=\s*(.*?)\s*$' -and $Matches[1]) {
                $include = $Matches[1]
                if (-not [IO.Path]::IsPathRooted($include)) { $include = Join-Path (Split-Path $path -Parent) $include }
                foreach ($entry in (Get-ChildItem -Path $include -File -ErrorAction Stop)) { $pending.Enqueue($entry.FullName) }
            }
        }
    }
    if ($hostnames.Count -eq 1) { return $hostnames[0] }
    if ($hostnames.Count -gt 1) { return 'Not verified (multiple Hostname settings)' }
    if ($items.Count) { return 'Dynamic / not verified (HostnameItem=' + ($items -join ', ') + ')' }
    return 'Dynamic / not verified (default system.hostname)'
}

# Function definitions inserted into both production scripts by the updater.
function New-ZabbixInstallCommand {
    param([Parameter(Mandatory=$true)][string]$Hostname)
    if ([string]::IsNullOrWhiteSpace($Hostname) -or $Hostname -in @('Not detected','Not verified') -or $Hostname -match '["\x00\r\n]') {
        throw 'Zabbix hostname is unavailable or invalid. Installation was not started.'
    }
    $hostnameData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Hostname))
    $template=@'
$ErrorActionPreference='Stop'
$stage=$null
try {
    $hostname=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HOSTNAME_DATA__'))
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $stage=Join-Path $temporaryRoot ('ThoroughCheck-Zabbix-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $zipPath=Join-Path $stage 'zabbix.zip'
    $packageRoot=Join-Path $stage 'package'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn-ito.selisesme.com/omk/zabbix/zabbix.zip' -OutFile $zipPath -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $destination=[IO.Path]::GetFullPath($packageRoot).TrimEnd('\')+'\'
        foreach ($entry in $archive.Entries) {
            $target=[IO.Path]::GetFullPath((Join-Path $packageRoot $entry.FullName))
            if (-not $target.StartsWith($destination,[StringComparison]::OrdinalIgnoreCase)) {throw 'Installer archive contains a path outside its package folder.'}
        }
    } finally {$archive.Dispose()}
    Expand-Archive -LiteralPath $zipPath -DestinationPath $packageRoot -ErrorAction Stop
    $installers=@(Get-ChildItem -LiteralPath $packageRoot -Filter 'zabbix-msi-install.ps1' -File -Recurse -ErrorAction Stop)
    if ($installers.Count -ne 1) {throw 'A single Zabbix PowerShell installer could not be identified.'}
    $installer=$installers[0].FullName
    $msi=Join-Path $installers[0].DirectoryName 'zabbix.msi'
    $monitoring=Join-Path $installers[0].DirectoryName 'omk-monitoring.conf'
    foreach ($file in @($msi,$monitoring)) {if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {throw ('Installer file missing: '+$file)}}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or 'Hostname' -notin @($ast.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})) {throw 'Installer does not support the required Hostname parameter.'}
    $global:LASTEXITCODE=0
    & $installer -MsiPath $msi -Hostname $hostname -ScriptSource $monitoring -LogPath (Join-Path $stage 'install.log')
    if ($LASTEXITCODE -ne 0) {throw ('Zabbix installer returned exit code '+$LASTEXITCODE)}
    $service=Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
    # The MSI starts the agent before its monitoring include file is copied.
    # Restart only this newly installed agent so that it loads that file.
    if ($service.Status -eq 'Running') {Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
    else {Start-Service -Name 'Zabbix Agent 2' -ErrorAction Stop}
    (Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
    $resolvedStage=[IO.Path]::GetFullPath($stage)
    if (-not $resolvedStage.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedStage) -notmatch '^ThoroughCheck-Zabbix-[0-9a-f]{32}$') {throw 'Temporary installer cleanup target could not be verified.'}
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction Stop
    exit 0
} catch {
    [Console]::Error.WriteLine(('Zabbix installation failed: '+$_.Exception.Message+'. Installer files/log retained at: '+$stage))
    exit 1
}
'@
    return $template.Replace('__HOSTNAME_DATA__',$hostnameData)
}

function Invoke-ZabbixAgentInstall {
    param([Parameter(Mandatory=$true)][string]$Hostname)
    if (-not (Test-CanApply)) {throw 'Zabbix installation is disabled in Audit mode.'}
    $command=New-ZabbixInstallCommand -Hostname $Hostname
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait -NoNewWindow -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) {throw ('Zabbix installer failed (exit code '+$process.ExitCode+'). Review installer output.')}
}


# 3.2 Zabbix Agent 2
Start-AuditStep 8 'Zabbix Agent 2'
$zabbixInstallError = $null
$zabbixInstalledThisRun = $false
$zabbixExpectedHostname = Get-ThoroughDeviceHostname
try {
    $zabbixService = Get-AuditService -ServiceName 'Zabbix Agent 2'
    if (-not $zabbixService -and (Test-CanApply)) {
        [void](New-ZabbixInstallCommand -Hostname $zabbixExpectedHostname)
        Invoke-ZabbixAgentInstall -Hostname $zabbixExpectedHostname
        $zabbixService = Get-AuditService -ServiceName 'Zabbix Agent 2'
        if (-not $zabbixService) { throw 'Installer exited but Zabbix Agent 2 service is still missing.' }
        $zabbixInstalledThisRun = $true
    }
} catch { $zabbixInstallError = $_.Exception.Message }
if ($zabbixInstallError) {
    Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Zabbix Agent 2' -ItemSub 'Type: Infrastructure Monitoring' -Shortcut '<code>services.msc</code>' -FoundStateHtml (ConvertTo-ServiceFindingHtml -ServiceState 'Not verified' -StartupType 'Not verified' -Recovery ([pscustomobject]@{First='Not verified';Second='Not verified';Subsequent='Not verified'}) -HostName 'Not verified') -Status 'Fail' -ActionTaken ([System.Net.WebUtility]::HtmlEncode($zabbixInstallError))
    $auditRows[-1] | Add-Member NoteProperty ExpectedHostName $zabbixExpectedHostname
} else {
    Invoke-RequiredServiceCheck -ServiceName 'Zabbix Agent 2' -ItemTitle 'Zabbix Agent 2' -ItemSub 'Type: Infrastructure Monitoring' -DeferConsole
    $zabbixRow = $auditRows[$auditRows.Count - 1]
    if ($zabbixInstalledThisRun) { $zabbixRow.ActionTaken='Installed missing Zabbix Agent; service presence verified; '+$zabbixRow.ActionTaken }
    $zabbixRow | Add-Member NoteProperty ExpectedHostName $zabbixExpectedHostname
    try { $agentHostname = Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName }
    catch { $agentHostname = 'Not verified (configuration unreadable)' }
    if((Test-CanApply) -and $agentHostname -cne $zabbixExpectedHostname){
        try{
            $hostnameChange=Set-ZabbixDeviceHostname -CommandLine $zabbixService.PathName -Hostname $zabbixExpectedHostname
            if($hostnameChange.Changed){$zabbixRow.ActionTaken+='; Updated Zabbix hostname to '+$zabbixExpectedHostname+'; service restarted and readback verified; Backup: '+$hostnameChange.BackupPath}
            $agentHostname=Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName
        }catch{
            $zabbixRow.Status='Fail';$zabbixRow.ActionTaken+='; Zabbix hostname update was not verified: '+$_.Exception.Message+'. Manual action required.'
            try{$agentHostname=Get-ZabbixConfiguredHostname -CommandLine $zabbixService.PathName}catch{$agentHostname='Not verified'}
        }
    }
    $zabbixRow.FoundStateHtml += ConvertTo-ReportDefinitionHtml ([ordered]@{'Host Name'=$agentHostname})
    if ($agentHostname -match 'Not verified|Dynamic /') { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Zabbix monitoring hostname was not verified.' }
    elseif ([string]::IsNullOrWhiteSpace($zabbixExpectedHostname) -or $zabbixExpectedHostname -in @('Not verified','Not detected')) { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Windows device hostname unavailable; hostname match requires manual verification.' }
    elseif ($agentHostname -cne $zabbixExpectedHostname) { $zabbixRow.Status='Fail'; $zabbixRow.ActionTaken += '; Zabbix hostname differs from the expected hostname; existing configuration preserved. Manual action required.' }
    Write-ThoroughConsoleEntry -Row $zabbixRow -Number $auditRows.Count
}

# 3.3 Windows Update Service
Start-AuditStep 9 'Windows Update service'
$wuStatus = 'Fail'
$wuState = 'Not verified'
$wuStartup = 'Not verified'
$wuRecovery = 'Not verified'
$wuAction = 'Audit only: no changes made'
$wuChanges=New-Object 'Collections.Generic.List[string]'
try {
    $wuauserv = Get-AuditService -ServiceName 'wuauserv'
    if (-not $wuauserv) { throw 'Windows Update service is missing.' }
    $wuState = [string]$wuauserv.State
    $wuStartup = [string]$wuauserv.StartMode
    $wuRecoveryValid = Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv'
    if (Test-CanApply) {
        if (-not $wuRecoveryValid) { $wuRecoveryValid = Invoke-ServiceNoActionRecoveryRepair -ServiceName 'wuauserv'; $wuChanges.Add('Recovery actions set to Take No Action') }
        if (-not $wuRecoveryValid) { throw 'Windows Update recovery settings could not be verified; remaining repairs skipped.' }
        if ($wuauserv.StartMode -ne 'Disabled') { Set-Service -Name 'wuauserv' -StartupType Disabled -ErrorAction Stop; $wuChanges.Add('Startup set to Disabled') }
        if ($wuauserv.State -ne 'Stopped') {
            Stop-Service -Name 'wuauserv' -Force -ErrorAction Stop
            $wuChanges.Add('Service stop requested')
            $wuWaitService = Get-Service -Name 'wuauserv' -ErrorAction Stop
            $wuWaitService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
    }
    $wuauserv = Get-AuditService -ServiceName 'wuauserv'
    if (-not $wuauserv) { throw 'Windows Update service disappeared during verification.' }
    $wuState = [string]$wuauserv.State
    $wuStartup = [string]$wuauserv.StartMode
    $wuRecoveryValid = Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv'
    $wuRecovery = if ($wuRecoveryValid) { 'First, second and subsequent failures: Take No Action' } else { 'One or more failure actions are configured' }
    if ($wuState -ne 'Stopped' -or $wuStartup -ne 'Disabled' -or -not $wuRecoveryValid) { throw 'Windows Update must be Stopped / Disabled with all recovery actions set to Take No Action; run Apply mode or investigate the service error.' }
    $wuStatus = 'Pass'
    $wuAction = if ($wuChanges.Count) { ($wuChanges -join '; ')+'; readback verified' } else { 'No change needed; verified Stopped / Disabled; all recovery actions: Take No Action' }
} catch {
    $wuAction = ($wuChanges -join '; '); if ($wuAction) { $wuAction+='; ' }; $wuAction += "Failed: $($_.Exception.Message)"
    try {
        $wuFailedSnapshot = Get-AuditService -ServiceName 'wuauserv'
        if ($wuFailedSnapshot) {
            $wuState = [string]$wuFailedSnapshot.State
            $wuStartup = [string]$wuFailedSnapshot.StartMode
        }
        try {
            $wuRecovery = if (Read-ServiceNoActionRecoveryPolicy -ServiceName 'wuauserv') { 'First, second and subsequent failures: Take No Action' } else { 'One or more failure actions are configured' }
        } catch { $wuRecovery = 'Not verified' }
    } catch { $wuAction += '; Current state could not be refreshed' }
}
$wuRecoveryDetails=Get-ServiceRecoveryDetails -ServiceName 'wuauserv'
if (-not $wuRecoveryDetails.Verified) { $wuStatus='Fail'; $wuAction += '; Recovery actions not verified: '+$wuRecoveryDetails.Error }
$wuFound=ConvertTo-ServiceFindingHtml -ServiceState $wuState -StartupType $wuStartup -Recovery $wuRecoveryDetails
Add-AuditEntry -SectionNumber $sec3Num -SectionTitle $sec3Title -ItemTitle 'Windows Update (wuauserv)' -ItemSub 'Type: Windows Update Engine' -Shortcut '<code>services.msc</code>' -FoundStateHtml $wuFound -Status $wuStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($wuAction))

# GROUP 5: SECURITY, NETWORK & SYSTEM INTEGRITY
$sec4Num = 4
$sec4Title = 'Security, Network & System Integrity'
# 4.1 Inbound Port 5009 Firewall Rule
function Test-FirewallPortMatch {
    param ($Ports, [int]$Port)
    foreach ($entry in @($Ports)) {
        foreach ($piece in ([string]$entry -split ',')) {
            $piece = $piece.Trim()
            if ($piece -in @('Any', '*') -or $piece -eq [string]$Port) { return $true }
            if ($piece -match '^(\d+)\s*-\s*(\d+)$' -and $Port -ge [int]$matches[1] -and $Port -le [int]$matches[2]) { return $true }
        }
    }
    return $false
}

function Test-FirewallAny {
    param ($Value, [switch]$AllowEmpty)
    $items = @($Value)
    if ($items.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($items -join ''))) { return [bool]$AllowEmpty }
    return ($items.Count -eq 1 -and ([string]$items[0]).Trim() -in @('Any', '*'))
}

function Get-KioskFirewallState {
    param ([int]$Port = 5009)
    # Presence check only: an enabled inbound TCP Allow rule explicitly listing this port.
    # No connectivity, profile, address-scope or block-rule audit is performed here.
    $filters = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        [string]$_.Protocol -in @('TCP', '6') -and (Test-FirewallPortMatch -Ports $_.LocalPort -Port $Port)
    })
    $observations=New-Object 'Collections.Generic.List[object]'
    foreach ($filter in $filters) {
        $rules = @(Get-NetFirewallRule -AssociatedNetFirewallPortFilter $filter -PolicyStore ActiveStore -ErrorAction Stop)
        $allowRules=@($rules | Where-Object {
            [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Allow'
        })
        if ($allowRules.Count -gt 0) {
            $matching=@($allowRules | ForEach-Object { ConvertTo-FirewallRuleObservation -Filter $filter -Rule $_ })
            return [pscustomobject]@{ Verified = $true; HasAllow = $true; Details = 'Available'; Observations=$matching }
        }
        foreach($rule in $rules){$observations.Add((ConvertTo-FirewallRuleObservation -Filter $filter -Rule $rule))}
    }
    [pscustomobject]@{ Verified = $false; HasAllow = $false; Details = 'Missing'; Observations=$observations.ToArray() }
}

function Invoke-KioskFirewallPortCheck {
    param ([Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][string]$RulePurpose)
    $fwStatus = 'Fail'
    $fwFound = 'Not verified'
    $fwAction = 'Firewall state was not verified'
    $firewallState = $null
    try {
        $firewallState = Get-KioskFirewallState -Port $Port
        $fwAction = 'Firewall rule verified; no changes needed'
        if (-not $firewallState.HasAllow) {
            if (Test-CanApply) {
                $managedRuleName = "SELISE-Kiosk-TCP-$Port-Inbound"
                $managedRule = @(Get-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
                if ($managedRule.Count -eq 0) {
                    New-NetFirewallRule -Name $managedRuleName -DisplayName "Allow Port $Port Inbound ($RulePurpose)" -PolicyStore PersistentStore -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow -Enabled True -Profile Any -ErrorAction Stop | Out-Null
                    $fwAction = "Created inbound TCP $Port rule"
                } else {
                    Set-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -Direction Inbound -Action Allow -Enabled True -Profile Any -ErrorAction Stop | Out-Null
                    $managedRule = Get-NetFirewallRule -Name $managedRuleName -PolicyStore PersistentStore -ErrorAction Stop
                    Get-NetFirewallPortFilter -AssociatedNetFirewallRule $managedRule -ErrorAction Stop |
                        Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port -ErrorAction Stop | Out-Null
                    $fwAction = "Updated inbound TCP $Port rule"
                }
                $firewallState = Get-KioskFirewallState -Port $Port
                if ($firewallState.Verified) { $fwAction += '; readback verified' }
            } else {
                $fwAction = "Audit only: an inbound TCP $Port allow rule is required"
            }
        }
        $fwFound = if ($firewallState.HasAllow) { 'Available' } else { 'Missing' }
        if ($firewallState.Verified) { $fwStatus = 'Pass' }
        elseif (Test-CanApply) { $fwAction = "TCP $Port Allow rule could not be verified after configuration." }
    } catch { $fwAction = "Firewall verification or creation failed: $($_.Exception.Message)" }
    $entryCount=if($null -ne $auditRows){$auditRows.Count}else{-1}
    Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle "Inbound TCP $Port Rule" -ItemSub 'Type: Firewall Rule Presence' -Shortcut '<code>wf.msc</code>' -FoundStateHtml ([System.Net.WebUtility]::HtmlEncode($fwFound)) -Status $fwStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($fwAction))
    if($null -ne $auditRows -and $auditRows.Count -eq $entryCount+1){
        $row=$auditRows[$auditRows.Count-1]
        $readVerified=$null -ne $firewallState -and $fwFound -ne 'Not verified'
        $snapshot=if($readVerified -and $firewallState.PSObject.Properties['Observations']){@($firewallState.Observations)}else{@()}
        $row | Add-Member -NotePropertyName FirewallPort -NotePropertyValue $Port
        $row | Add-Member -NotePropertyName FirewallReadVerified -NotePropertyValue $readVerified
        $row | Add-Member -NotePropertyName FirewallObservations -NotePropertyValue $snapshot
    }
}

Start-AuditStep 10 'Required inbound firewall rules'
Invoke-KioskFirewallPortCheck -Port 5009 -RulePurpose 'SELISE Kiosk'
if ($detectedPaymentProvider -in @('NETS','NEXIDE')) {
    foreach ($nexiPort in @(4100, 4101, 4102, 4103)) {
        Invoke-KioskFirewallPortCheck -Port $nexiPort -RulePurpose 'NETS / Nexi Payment Terminal'
    }
}

# 4.2 Local Administrative Accounts
Start-AuditStep 11 'Administrative accounts'
try {
    Add-ResultEntry $sec4Num $sec4Title 'Administrative Accounts' (Get-AdministrativeAccountCheck)
} catch { Add-ResultEntry $sec4Num $sec4Title 'Administrative Accounts' (New-CheckResult 'Fail' $_.Exception.Message 'Account checks failed') }

# 4.3 Nmap Tool (Windows 10 Local Installer)
Start-AuditStep 12 'Nmap executable and version'
function Get-NmapExecutable {
    $command = Get-Command -Name nmap.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    foreach ($location in @('C:\Program Files (x86)\Nmap\nmap.exe', 'C:\Program Files\Nmap\nmap.exe')) {
        if (Test-Path -LiteralPath $location -PathType Leaf) { return $location }
    }
    # Honor a custom destination without reinstalling an existing installation.
    foreach ($keyPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Nmap', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Nmap')) {
        if (Test-Path -LiteralPath $keyPath) {
            $entry = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            if ($entry.InstallLocation) {
                $location = Join-Path $entry.InstallLocation 'nmap.exe'
                if (Test-Path -LiteralPath $location -PathType Leaf) { return $location }
            }
        }
    }
    return $null
}

function Get-NmapVersion {
    param ([Parameter(Mandatory)][string]$Path)
    # --version has no scan targets and makes no network scan requests.
    $versionOutput = (& $Path --version 2>&1 | Out-String).Trim()
    $versionExitCode = $LASTEXITCODE
    if ($versionExitCode -ne 0) { throw "Nmap --version failed with exit code $versionExitCode." }
    if ($versionOutput -notmatch '(?m)^Nmap version\s+(\S+)') { throw 'Nmap returned no recognizable version information.' }
    [PSCustomObject]@{ Version = $matches[1]; Output = $versionOutput }
}

function Get-LocalNmapInstaller {
    param ([Parameter(Mandatory)][AllowEmptyString()][string]$ScriptDirectory)
    if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) { throw 'Cannot resolve the script directory for the local Nmap package.' }
    $packageDirectory = Join-Path $ScriptDirectory 'DeviceManagement\Packages\Nmap'
    $manifestPath = Join-Path $packageDirectory 'NmapPackage.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Local Nmap package is missing. Run Save-NmapPackage.ps1 in '$packageDirectory' on the preparation PC, then copy that folder with the scripts."
    }
    $package = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
    if ($package.Version -notmatch '^\d+(\.\d+)+$' -or $package.FileName -cne ('nmap-{0}-setup.exe' -f $package.Version) -or $package.SHA256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The local Nmap package manifest is invalid; prepare the package again.'
    }
    $installerPath = Join-Path $packageDirectory $package.FileName
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "Local Nmap installer is missing: $installerPath" }
    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ne $package.SHA256) { throw 'Local Nmap installer checksum mismatch; installation was not started. Prepare the package again.' }
    return $installerPath
}

$nmapStatus = 'Fail'
$nmapPath = $null
$nmapDetectionVerified = $false
$nmapAction = 'Not installed'
$nmapVersion = $null
try {
    $nmapPath = Get-NmapExecutable
    $nmapDetectionVerified = $true
    if (-not $nmapPath) {
        $isWin10 = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption -match 'Windows 10'
        if (Test-CanApply) {
            $nmapDetectionVerified = $false
            if ($isWin10) {
                $installerPath = Get-LocalNmapInstaller -ScriptDirectory $PSScriptRoot
                # The public Nmap installer requires interaction. /S is an OEM-only feature.
                Write-Host '  Nmap setup will open. Complete the wizard to continue the check.' -ForegroundColor Cyan
                $installerProcess = Start-Process -FilePath $installerPath -Wait -PassThru -ErrorAction Stop
                if ($installerProcess.ExitCode -ne 0) { throw "Local Nmap installer returned exit code $($installerProcess.ExitCode); installation was cancelled or failed." }
                $nmapAction = 'Installed missing Nmap using the local setup wizard; existing installations are not upgraded'
            } else {
                $wingetCommand = Get-Command -Name winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $wingetCommand) { throw 'winget is unavailable; install Nmap manually from https://nmap.org/download.html' }
                & $wingetCommand.Source install --id Insecure.Nmap --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --no-upgrade 2>&1 | Out-Null
                $wingetExitCode = $LASTEXITCODE
                if ($wingetExitCode -ne 0) { throw "Nmap installer returned exit code $wingetExitCode; verify installation manually." }
                $nmapAction = 'Installed missing Nmap using winget; existing installations are not upgraded'
            }
            $nmapPath = Get-NmapExecutable
            $nmapDetectionVerified = $true
            if (-not $nmapPath) { throw 'Installer reported success but nmap.exe is still missing.' }
        } elseif ($isWin10) {
            $nmapAction = 'Audit only: Nmap missing; Apply Fix would open the local Nmap setup wizard'
        } else { $nmapAction = 'Audit only: Nmap missing; apply mode would attempt silent installation using winget' }
    } else { $nmapAction = 'Existing installation retained' }
    if ($nmapPath) {
        $nmapVersion = Get-NmapVersion -Path $nmapPath
        $nmapAction += '; version check passed'
        $nmapStatus = 'Pass'
    }
} catch {
    $nmapStatus = 'Fail'
    $nmapAction = "Nmap check or installation failed: $($_.Exception.Message)"
    if (-not $nmapDetectionVerified) {
        try {
            $nmapPath = Get-NmapExecutable
            $nmapDetectionVerified = $true
        } catch { $nmapPath = $null }
    }
}
$nmapToolState = if (-not $nmapDetectionVerified) { 'Not verified. Please check manually.' } elseif ($nmapPath) { 'Installed' } else { 'Not installed. Please install manually.' }
$nmapDetails = [ordered]@{ 'Tool State'=$nmapToolState }
if ($nmapPath) {
    $nmapDetails['Version'] = if ($null -ne $nmapVersion) { $nmapVersion.Version } else { 'Not verified. Please check manually.' }
    $nmapDetails['Executable Path'] = $nmapPath
}
$nmapFound = ConvertTo-ReportDefinitionHtml $nmapDetails
Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle 'Nmap Diagnostic Tool' -ItemSub 'Type: Executable / Version Check' -Shortcut '<code>nmap --version</code>' -FoundStateHtml $nmapFound -Status $nmapStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($nmapAction))

# 4.4 lodctr /R Performance Counter Rebuild
Start-AuditStep 13 'Performance counters'
$lodctrStatus = 'Bypass'
$lodctrState = 'Not executed (audit only)'
$lodctrAction = 'Audit only: performance counter rebuild skipped; health was not verified'
if (Test-CanApply) {
    try {
        $lodctrProcess = Start-Process -FilePath 'lodctr.exe' -ArgumentList '/R' -Wait -WindowStyle Hidden -PassThru -ErrorAction Stop
        $lodctrState = "Exit code: $($lodctrProcess.ExitCode)"
        if ($lodctrProcess.ExitCode -ne 0) { throw "lodctr /R failed with exit code $($lodctrProcess.ExitCode)." }
        $lodctrStatus = 'Pass'
        $lodctrAction = 'Performance counters rebuilt; lodctr returned exit code 0'
    } catch {
        $lodctrStatus = 'Fail'
        if ($lodctrState -eq 'Not executed (audit only)') { $lodctrState = 'Execution error' }
        $lodctrAction = "Performance counter rebuild failed: $($_.Exception.Message)"
    }
}
$lodctrFound = if ($script:ApplyChanges) {
    ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Rebuild State'=($lodctrState -replace ' \(audit only\)$','') })
} else {
    ConvertTo-ReportDefinitionHtml ([ordered]@{ 'Audit'='Not executed' })
}
Add-AuditEntry -SectionNumber $sec4Num -SectionTitle $sec4Title -ItemTitle 'lodctr /R Performance Counter' -ItemSub 'Type: System Performance Rebuild' -Shortcut '<code>perfmon</code>' -FoundStateHtml $lodctrFound -Status $lodctrStatus -ActionTaken ([System.Net.WebUtility]::HtmlEncode($lodctrAction))


# END COMPONENT CHECKS
    if($inspectOnly){$beforeApplyRows=@(Copy-ThoroughObservationRows @(Get-ThoroughReportDisplayRows -Rows $auditRows.ToArray()))}
}
} catch {
    $interruption=if($script:BeforeApplyInspection){'Pre-Apply inspection was interrupted; no repairs were started.'}else{'Partial run; earlier changes may already have been applied'}
    if($script:BeforeApplyInspection){$script:ApplyChanges=$applyRequested}
    Add-ResultEntry 6 'Execution' 'Unexpected interruption' (New-CheckResult 'Fail' $_.Exception.Message $interruption)
} finally {
    $script:BeforeApplyInspection=$false
    $totalCount = $auditRows.Count
    $passCount = @($auditRows | Where-Object { $_.Status -in @('Pass','Online','Remediated') -or ($_.Status -eq 'Offline' -and $_.ItemSub -eq 'Type: Old Payment Service') }).Count
    $failCount = @($auditRows | Where-Object { $_.Status -eq 'Fail' -or ($_.Status -eq 'Offline' -and $_.ItemSub -ne 'Type: Old Payment Service') }).Count
    $skipCount = $totalCount - $passCount - $failCount
    $totalChecksStr = '{0:D2}' -f $totalCount
    $passedCountStr = '{0:D2}' -f $passCount
    $failedCountStr = '{0:D2}' -f $failCount
    $skippedCountStr = '{0:D2}' -f $skipCount

    if (-not $script:ApplyChanges) { Complete-ThoroughConsole -IsApply $false -FailedCount $failCount -IsFinal ([bool]$FinalReport) }
    $generateReport = [bool]($script:ApplyChanges -or $FinalReport)
    if (-not $script:ApplyChanges -and -not $FinalReport) {
        $generateReport = Read-AuditReportChoice
    }

    if ($generateReport) {
        if ($script:ApplyChanges) { Start-AuditStep 14 'Writing HTML report' }
        if (-not (Test-Path -LiteralPath $outputFolder)) {
            New-Item -ItemType Directory -Path $outputFolder -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
        }

$snapshotModes=if($script:ApplyChanges){@('Fix','Final')}elseif($FinalReport){@('Final')}else{@('Audit','Fix','Final')}
$auditSource=$null
$snapshots=@(foreach($snapshotMode in $snapshotModes){
    $snapshot=New-ThoroughReportSnapshot -Rows $auditRows.ToArray() -DisplayMode $snapshotMode -ClientLocation $clientLocation -AgentName $AgentName -DeviceType $deviceType -Hostname $reportHostname -LauncherKioskId $reportKioskId -LauncherRestaurantId $reportRestaurantId -RequestedKioskId $KioskId -KioskUserName $kioskUser -AfterApply:([bool]$script:ApplyChanges) -AuditSource $auditSource -BeforeRows $(if($script:ApplyChanges){if($savedBeforeRows.Count){$savedBeforeRows}else{$beforeApplyRows}}else{@()})
    if($snapshotMode -eq 'Audit'){$auditSource=$snapshot}
    $snapshot
})
$preferredMode=if($script:ApplyChanges){'Fix'}elseif($FinalReport){'Final'}else{'Audit'}
$reportPath=Save-ThoroughReportBundle -Path $reportPath -ClientType 'Subway' -ComputerName $env:COMPUTERNAME -Snapshots $snapshots -PreferredMode $preferredMode
    if ($script:ApplyChanges) {
        Write-Host "Report saved: $reportPath" -ForegroundColor Cyan
        Complete-ThoroughConsole -IsApply $true -FailedCount $failCount
    } else {
        if ($FinalReport) { Write-Host "Report saved: $reportPath" -ForegroundColor Gray }
        else { Write-Host "`nAudit report saved to:`n$reportPath" -ForegroundColor Green }
    }
    }
}
$global:LASTEXITCODE = if ($failCount -gt 0) { 1 } else { 0 }
if ($ArchitectureRun -and -not [string]::IsNullOrWhiteSpace($ArchitectureResultPath)) {
    [IO.File]::WriteAllText($ArchitectureResultPath, 'Completed', [Text.UTF8Encoding]::new($false))
}
if ($ArchitectureRun) {
    $nextOption = '0'
} else {
    Write-Host "`n  [3] Main Menu`n  [0] Exit" -ForegroundColor Cyan
    do {
        $nextOption = ([string](Read-Host '  Select option')).Trim()
        if ($nextOption -notin @('3', '0')) { Write-Host 'Please select 3 or 0.' -ForegroundColor Yellow }
    } until ($nextOption -in @('3', '0'))
}
if ($nextOption -eq '3') {
    $Apply = $false; $AuditOnly = $false; $FinalReport = $false
    $RestaurantId = ''; $KioskId = ''; $KioskHostname = ''; $KioskPassword = $null
}
} while ($nextOption -eq '3')
exit $global:LASTEXITCODE

