<#
.SYNOPSIS
    SELISE client, device and operation launcher.
.DESCRIPTION
    Phase 1 provides navigation and validates selections. Operations remain
    unavailable until their reviewed handlers are added and marked Ready.
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$architectureRoot = $PSScriptRoot
$corePath = Join-Path $architectureRoot 'Core'
foreach ($module in @('Validation.psm1', 'Context.psm1', 'Menu.psm1', 'Reporting.psm1', 'PackageLoader.psm1', 'KioskClient.psm1')) {
    Import-Module (Join-Path $corePath $module) -Force -ErrorAction Stop
}
$clientsConfiguration = Import-PowerShellDataFile (Join-Path $architectureRoot 'Config\Clients.psd1')
$operationsConfiguration = Import-PowerShellDataFile (Join-Path $architectureRoot 'Config\Operations.psd1')
$paymentPackagesConfiguration = Import-PowerShellDataFile (Join-Path $architectureRoot 'Config\PaymentPackages.psd1')

# Enable the retained Thorough Check sources in addition to configured handlers.
$thoroughCheckOperation = @($operationsConfiguration.Operations | Where-Object { $_.Id -eq 'ThoroughCheck' }) | Select-Object -First 1
if (-not $thoroughCheckOperation) { throw 'The Thorough Check operation is missing from Config\Operations.psd1.' }
$thoroughCheckHandler = Join-Path $architectureRoot 'Checks\KIOSK\ThoroughCheck.ps1'
$sourceRoot = $architectureRoot
$thoroughCheckSources = [ordered]@{
    SaaS   = Join-Path $sourceRoot 'KioskThoroughCheck.ps1'
    Subway = Join-Path $sourceRoot 'KioskThoroughCheck.ps1'
}
if (-not (Test-Path -LiteralPath $thoroughCheckHandler -PathType Leaf)) {
    throw "The Thorough Check handler is missing: $thoroughCheckHandler"
}
foreach ($sourceEntry in $thoroughCheckSources.GetEnumerator()) {
    [void](Get-KioskClientSettings -ClientType $sourceEntry.Key -ProjectRoot $architectureRoot)
    if (-not (Test-Path -LiteralPath $sourceEntry.Value -PathType Leaf)) {
        throw "The $($sourceEntry.Key) Thorough Check source is missing: $($sourceEntry.Value)"
    }
}
$thoroughCheckOperation.ReadySelections = @(
    'SaaS|KIOSK|Audit',
    'SaaS|KIOSK|Apply',
    'SaaS|KIOSK|Final',
    'Subway|KIOSK|Audit',
    'Subway|KIOSK|Apply',
    'Subway|KIOSK|Final'
)
$thoroughCheckOperation.ImplementationState = 'Ready'

$screen = 'Client'
$selectedClient = $null
$selectedDevice = $null
$selectedOperation = $null
$selectedPackage = $null
$selectedMode = $null
$clientLocation = $null
$agentName = $null
$lastResult = $null
$exitRequested = $false

function Get-PaymentMenuItems {
    param ($PackagesConfiguration, $Client, [string]$Device, $Operation)
    $items = New-Object 'Collections.Generic.List[object]'
    $compatiblePackages = @($PackagesConfiguration.Packages | Where-Object {
        $_.Client -eq $Client.Id -and $_.Devices -contains $Device
    })
    foreach ($package in $compatiblePackages) {
        $installReady = Test-OperationSelectionReady $Operation $Client.Id $Device 'Apply'
        $items.Add([pscustomobject]@{
            Id                  = [string]$package.Id
            DisplayName         = [string]$package.DisplayName
            Description         = ''
            SelectionType       = 'Package'
            Package             = $package
            ImplementationState = if ($installReady) { 'Ready' } else { 'Pending' }
        })
    }
    foreach ($paymentMode in @(
        @{ Id = 'Audit'; DisplayName = 'Audit Report' }
        @{ Id = 'Uninstall'; DisplayName = 'Remove Payment Service' }
    )) {
        $modeReady = Test-OperationSelectionReady $Operation $Client.Id $Device $paymentMode.Id
        $items.Add([pscustomobject]@{
            Id                  = $paymentMode.Id
            DisplayName         = $paymentMode.DisplayName
            Description         = ''
            SelectionType       = 'Mode'
            Package             = $null
            ImplementationState = if ($modeReady) { 'Ready' } else { 'Pending' }
        })
    }
    return $items.ToArray()
}

function Invoke-PaymentMenuChoice {
    param ($Selection, $Client, [string]$Device, $Operation, $ClientsConfiguration, $OperationsConfiguration, [string]$RootPath, [string]$ClientLocation)
    if ($Selection.SelectionType -eq 'Package') {
        $package = $Selection.Package
        $mode = 'Apply'
    } else {
        $package = $null
        $mode = $Selection.Id
    }
    $validated = Assert-RunSelection -ClientsConfiguration $ClientsConfiguration -OperationsConfiguration $OperationsConfiguration `
        -ClientId $Client.Id -Device $Device -OperationId $Operation.Id -Mode $mode
    $context = New-DeviceManagementContext -ClientType $validated.Client.Id -DeviceType $Device `
        -Operation $validated.Operation.Id -Mode $mode -ClientLocation $ClientLocation -RootPath $RootPath `
        -SelectedPackage $package
    $result = Invoke-ConfiguredOperation -RootPath $RootPath -Operation $validated.Operation -Context $context
    return [pscustomobject]@{ Mode = $mode; Package = $package; Result = $result }
}

function Get-HtmlReportRowTitle {
    param ([Parameter(Mandatory = $true)][string]$RowHtml)

    $titleMatch = [regex]::Match($RowHtml, '(?is)<div\s+class=["'']device-title["'']>(?<Title>.*?)</div>')
    if (-not $titleMatch.Success) { return $null }
    return [Net.WebUtility]::HtmlDecode(($titleMatch.Groups['Title'].Value -replace '<[^>]+>', '').Trim())
}

function Get-HtmlReportRowCells {
    param ([Parameter(Mandatory = $true)][string]$RowHtml)

    return @([regex]::Matches($RowHtml, '(?is)<td\b[^>]*>(?<Content>.*?)</td>') | ForEach-Object {
        $_.Groups['Content'].Value.Trim()
    })
}

function Get-HtmlReportRowStatus {
    param ([Parameter(Mandatory = $true)][string]$RowHtml)

    $statusMatch = [regex]::Match($RowHtml, '(?is)<span\s+class=["'']badge[^"'']*["'']>(?<Status>[^<]+)</span>')
    if (-not $statusMatch.Success) { return 'Fail' }
    return [Net.WebUtility]::HtmlDecode($statusMatch.Groups['Status'].Value.Trim())
}

function Get-ConsolidatedStatus {
    param ([Parameter(Mandatory = $true)][string[]]$Statuses)

    foreach ($status in @('Fail', 'Offline', 'Remediated', 'Bypass', 'Online', 'Pass')) {
        if ($Statuses -contains $status) { return $status }
    }
    return 'Fail'
}

function New-ConsolidatedAccountReportRow {
    param (
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Subtitle,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames,
        [Parameter(Mandatory = $true)][string]$NotFoundLabel,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$SourceRows,
        [switch]$Administrative
    )

    $sourceDetails = foreach ($sourceRow in $SourceRows) {
        $cells = @(Get-HtmlReportRowCells -RowHtml $sourceRow.Value)
        if ($cells.Count -lt 5) { continue }
        [pscustomobject]@{
            Title  = Get-HtmlReportRowTitle -RowHtml $sourceRow.Value
            Status = Get-HtmlReportRowStatus -RowHtml $sourceRow.Value
            State  = $cells[2]
            Action = $cells[4]
            Html   = $sourceRow.Value
        }
    }

    if ($Administrative) {
        $displayRows = @($sourceDetails)
    } else {
        $displayRows = @($sourceDetails | Where-Object {
            $_.Html -notmatch '(?is)Account Status:</span>\s*Missing' -and
            $_.Html -notmatch '(?is)Account is missing\.'
        })
        $errorRows = @($sourceDetails | Where-Object { $_.Title -eq 'SELISE Local Accounts' })
        if ($displayRows.Count -eq 0 -and $errorRows.Count -gt 0) { $displayRows = $errorRows }
    }

    $encodedTitle = [Net.WebUtility]::HtmlEncode($Title)
    $encodedSubtitle = [Net.WebUtility]::HtmlEncode($Subtitle)
    $shortcutLines = [Collections.Generic.List[string]]::new()
    $shortcutLines.Add('<code>lusrmgr.msc</code>')
    foreach ($name in $ExpectedNames) {
        $shortcutLines.Add(('<code>net user &quot;{0}&quot;</code>' -f [Net.WebUtility]::HtmlEncode($name)))
    }

    if ($displayRows.Count -eq 0) {
        $status = 'Fail'
        $stateHtml = '<div class="empty-state"><span class="empty-icon">!</span><div><strong>{0}:</strong> Not found</div></div>' -f ([Net.WebUtility]::HtmlEncode($NotFoundLabel))
        $expectedText = $ExpectedNames -join ' or '
        $actionHtml = '<div class="kv-block"><div>Create {0}. No account was created.</div></div>' -f ([Net.WebUtility]::HtmlEncode($expectedText))
    } else {
        $status = Get-ConsolidatedStatus -Statuses @($displayRows.Status)
        $stateParts = foreach ($row in $displayRows) {
            $rowTitle = if ($row.Title -match ':\s*(.+)$') { $Matches[1] } else { $row.Title }
            '<div class="account-entry"><div class="account-entry-title">{0}</div>{1}</div>' -f ([Net.WebUtility]::HtmlEncode($rowTitle)), $row.State
        }
        $actionParts = foreach ($row in $displayRows) {
            $rowTitle = if ($row.Title -match ':\s*(.+)$') { $Matches[1] } else { $row.Title }
            '<div class="account-entry"><div class="account-entry-title">{0}</div>{1}</div>' -f ([Net.WebUtility]::HtmlEncode($rowTitle)), $row.Action
        }
        $stateHtml = '<div class="account-stack">{0}</div>' -f ($stateParts -join '')
        $actionHtml = '<div class="account-stack">{0}</div>' -f ($actionParts -join '')
    }

    $badgeClass = 'badge-' + $status.ToLowerInvariant()
    return @"
<tr>
    <td style='width: 25%;'>
        <div class='device-title'>$encodedTitle</div>
        <div class='device-sub'>$encodedSubtitle</div>
    </td>
    <td style='width: 22%;'>$($shortcutLines -join '<br>')</td>
    <td style='width: 23%;'>$stateHtml</td>
    <td style='width: 10%;'><span class='badge $badgeClass'>$status</span></td>
    <td style='width: 20%;'>$actionHtml</td>
</tr>
"@
}

function Set-HtmlReportMetric {
    param (
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$Value
    )

    $pattern = '(?is)(<div[^>]*>\s*' + [regex]::Escape($Label) + '\s*</div>\s*<div\s+class=["'']stat-val["''][^>]*>)[^<]*(</div>)'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) { return $Html }
    $replacement = $match.Groups[1].Value + ('{0:D2}' -f $Value) + $match.Groups[2].Value
    return $Html.Substring(0, $match.Index) + $replacement + $Html.Substring($match.Index + $match.Length)
}

function Update-HtmlReportSummary {
    param ([Parameter(Mandatory = $true)][string]$Html)

    $reportRows = @([regex]::Matches($Html, '(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {
        $_.Value -match '(?is)<span\s+class=["'']badge'
    })
    $passed = 0
    $failed = 0
    foreach ($row in $reportRows) {
        $status = Get-HtmlReportRowStatus -RowHtml $row.Value
        $oldPaymentOffline = $status -eq 'Offline' -and $row.Value -match '(?is)Type:\s*Old Payment Service'
        if ($status -in @('Pass', 'Online', 'Remediated') -or $oldPaymentOffline) { $passed++ }
        elseif ($status -eq 'Fail' -or $status -eq 'Offline') { $failed++ }
    }
    $skipped = $reportRows.Count - $passed - $failed

    $Html = Set-HtmlReportMetric -Html $Html -Label 'Total Checks' -Value $reportRows.Count
    $Html = Set-HtmlReportMetric -Html $Html -Label 'Passed / Expected State' -Value $passed
    $Html = Set-HtmlReportMetric -Html $Html -Label 'Skipped / Not verified' -Value $skipped
    return Set-HtmlReportMetric -Html $Html -Label 'Failed' -Value $failed
}

function Get-ProfessionalReportStyle {
    return @'
<style>
    :root {
        --navy-950: #0b1324;
        --navy-900: #10213f;
        --navy-700: #203b64;
        --blue-600: #1769e0;
        --blue-100: #e8f1ff;
        --slate-700: #334155;
        --slate-500: #64748b;
        --slate-200: #e2e8f0;
        --slate-100: #f1f5f9;
        --surface: #ffffff;
        --canvas: #f4f7fb;
        --pass: #15803d;
        --fail: #c62828;
        --warning: #b45309;
        --info: #0369a1;
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--canvas); color: #172033; font-family: "Segoe UI", Arial, sans-serif; font-size: 13px; line-height: 1.5; }
    .report-header { color: #fff; background: linear-gradient(125deg, var(--navy-950), var(--navy-700)); padding: 30px max(32px, calc((100% - 1480px) / 2)); border-bottom: 4px solid #4c9aff; }
    .brand-lockup { display: flex; align-items: center; gap: 16px; }
    .brand-mark { width: 48px; height: 48px; border: 1px solid rgba(255,255,255,.35); border-radius: 12px; display: grid; place-items: center; background: rgba(255,255,255,.1); font-size: 25px; font-weight: 800; }
    .eyebrow { color: #a9cbff; font-size: 11px; font-weight: 700; letter-spacing: .14em; }
    h1 { margin: 1px 0 2px; font-size: 25px; line-height: 1.2; font-weight: 700; }
    .header-subtitle { margin: 0; color: #dbeafe; font-size: 13px; }
    .meta { display: flex; flex-wrap: wrap; gap: 8px 22px; margin-top: 22px; padding-top: 17px; border-top: 1px solid rgba(255,255,255,.18); color: #e5efff; font-size: 12px; }
    .meta strong { color: #fff; }
    .report-content { width: min(1480px, calc(100% - 48px)); margin: 26px auto 40px; }
    .summary-grid { display: grid; grid-template-columns: repeat(4, minmax(150px, 1fr)); gap: 14px; margin-bottom: 28px; }
    .stat-card { position: relative; overflow: hidden; min-height: 104px; padding: 20px 22px; background: var(--surface); border: 1px solid var(--slate-200); border-radius: 12px; box-shadow: 0 5px 16px rgba(15, 23, 42, .05); text-align: left; }
    .stat-card::before { content: ""; position: absolute; inset: 0 auto 0 0; width: 4px; background: var(--blue-600); }
    .stat-card:nth-child(2)::before { background: var(--pass); }
    .stat-card:nth-child(3)::before { background: var(--warning); }
    .stat-card:nth-child(4)::before { background: var(--fail); }
    .stat-card > div:first-child { color: var(--slate-500) !important; font-size: 11px !important; font-weight: 700 !important; letter-spacing: .05em; text-transform: uppercase; }
    .stat-val { margin-top: 5px; font-size: 30px; line-height: 1.1; font-weight: 750; color: var(--navy-900); }
    .section-title { margin: 27px 0 10px; color: var(--navy-900); font-size: 14px; font-weight: 750; letter-spacing: .055em; text-transform: uppercase; }
    table { width: 100%; margin: 0 0 22px; border-spacing: 0; border: 1px solid #d8e0eb; border-radius: 11px; background: var(--surface); box-shadow: 0 4px 14px rgba(15, 23, 42, .045); overflow: hidden; table-layout: fixed; }
    thead { background: #edf3fa; }
    th { padding: 11px 13px; color: #3b4d67; border-bottom: 1px solid #d8e0eb; font-size: 10.5px; font-weight: 750; letter-spacing: .055em; text-align: left; text-transform: uppercase; }
    td { padding: 13px; border-top: 1px solid #e8edf4; color: #27364d; font-size: 12px; vertical-align: top; overflow-wrap: anywhere; }
    tbody tr:first-child td { border-top: 0; }
    tbody tr:nth-child(even) { background: #fbfcfe; }
    tbody tr:hover { background: #f4f8fd; }
    .device-title { margin-bottom: 3px; color: #10213f; font-size: 12.5px; font-weight: 700; }
    .device-sub { color: var(--slate-500); font-size: 11px; }
    .kv-block { font-size: 11.5px; line-height: 1.55; }
    .kv-label { color: #46566d; font-weight: 650; }
    code { display: inline-block; max-width: 100%; margin: 1px 0 4px; padding: 3px 7px; color: #17355f; border: 1px solid #dce5f0; border-radius: 5px; background: #f3f7fc; font-family: Consolas, "Courier New", monospace; font-size: 10.5px; white-space: normal; overflow-wrap: anywhere; }
    .badge { display: inline-flex; min-width: 64px; justify-content: center; padding: 4px 9px; border-radius: 999px; font-size: 10px; font-weight: 750; letter-spacing: .035em; text-transform: uppercase; }
    .badge-pass { color: #11602d; background: #dcfce7; }
    .badge-fail { color: #9f1d1d; background: #fee2e2; }
    .badge-remediated { color: #92400e; background: #fef3c7; }
    .badge-online { color: #075985; background: #e0f2fe; }
    .badge-offline { color: #475569; background: #e2e8f0; }
    .badge-bypass { color: #475569; border: 1px solid #cbd5e1; background: #f8fafc; }
    .account-stack { display: grid; gap: 9px; }
    .account-entry { padding: 9px 10px; border: 1px solid #dde6f1; border-radius: 7px; background: #f8fafc; }
    .account-entry-title { margin-bottom: 5px; color: #1e4d85; font-size: 11px; font-weight: 750; letter-spacing: .03em; text-transform: uppercase; }
    .empty-state { display: flex; align-items: center; gap: 9px; padding: 10px; color: #8f1e1e; border: 1px solid #fecaca; border-radius: 7px; background: #fff7f7; }
    .empty-icon { flex: 0 0 22px; height: 22px; display: grid; place-items: center; border-radius: 50%; color: #fff; background: var(--fail); font-weight: 800; }
    .report-footer { width: min(1480px, calc(100% - 48px)); margin: -18px auto 30px; color: var(--slate-500); font-size: 10.5px; text-align: right; }
    @media (max-width: 900px) {
        .summary-grid { grid-template-columns: repeat(2, minmax(140px, 1fr)); }
        .report-content, .report-footer { width: calc(100% - 24px); }
        .report-header { padding: 24px 18px; }
        table { display: block; overflow-x: auto; min-width: 880px; }
    }
    @media print {
        @page { size: A4 landscape; margin: 10mm; }
        body { background: #fff; color: #000; font-size: 9px; }
        .report-header { padding: 15px 18px; border-bottom-width: 2px; print-color-adjust: exact; -webkit-print-color-adjust: exact; }
        .report-content { width: 100%; margin: 15px auto; }
        .summary-grid { margin-bottom: 16px; }
        .stat-card { min-height: auto; padding: 10px 12px; box-shadow: none; break-inside: avoid; }
        .stat-val { font-size: 20px; }
        .section-title { margin-top: 17px; break-after: avoid; }
        table { box-shadow: none; break-inside: auto; }
        tr { break-inside: avoid; break-after: auto; }
        th, td { padding: 7px; }
        .report-footer { width: 100%; margin: 0; }
    }
</style>
'@
}

function Update-ThoroughCheckHtmlReport {
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('KIOSK', 'POS', 'KDS')][string]$DeviceType,
        [Parameter(Mandatory = $true)][string]$ClientType
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Report file was not found: $Path" }
    $html = [IO.File]::ReadAllText($Path)

    # Combined reports own their tabbed layout and embedded snapshots. Validate
    # their contents before returning; the legacy formatter must not rewrite them.
    if($html.Contains('data-thorough-bundle-version="1"')){
        if($html -notmatch '(?is)<!doctype html>.*id="report-frame".*id="print-report".*</body>\s*</html>\s*$'){throw 'The combined report is incomplete.'}
        $data=[regex]::Match($html,'(?is)<script id="thorough-report-state" type="application/octet-stream">([A-Za-z0-9+/=\s]+)</script>')
        if(-not $data.Success){throw 'The combined report has no embedded report data.'}
        $encoding=New-Object Text.UTF8Encoding($false,$true)
        $saved=$encoding.GetString([Convert]::FromBase64String($data.Groups[1].Value)) | ConvertFrom-Json -ErrorAction Stop
        if($saved.Version -ne 1 -or $saved.ClientType -cne $ClientType -or $saved.BundleId -notmatch '^OMK-\d{6}$' -or -not $saved.ComputerName){throw 'The combined report identity is invalid.'}
        $count=0
        foreach($property in $saved.Reports.PSObject.Properties){
            if($property.Name -notin @('Audit','Fix','Final')){throw 'The combined report contains an unsupported mode.'}
            $snapshot=$property.Value;if($null -eq $snapshot){continue};$count++
            if($snapshot.Mode -cne $property.Name -or $snapshot.ReportId -notmatch '^OMK-\d{6}$'){throw 'An embedded report has an invalid identity.'}
            $metadataCell=if($snapshot.PSObject.Properties['RestaurantId']){'<th>Restaurant ID</th><td>'+[Net.WebUtility]::HtmlEncode([string]$snapshot.RestaurantId)+'</td>'}else{'<th>Report ID</th><td>'+$snapshot.ReportId+'</td>'}
            $document=$encoding.GetString([Convert]::FromBase64String([string]$snapshot.HtmlBase64))
            $metadataValid=$document.Contains($metadataCell)
            if(-not $metadataValid -and $snapshot.PSObject.Properties['RestaurantId']){
                $metadataValid=$document.Contains('<dt>Restaurant ID</dt><dd>'+[Net.WebUtility]::HtmlEncode([string]$snapshot.RestaurantId)+'</dd>')
            }
            if(-not $metadataValid -or $document -notmatch '(?is)<main class="report">.*</main>\s*</body>\s*</html>\s*$'){throw 'An embedded report is incomplete.'}
        }
        if(-not $count){throw 'The combined report contains no completed report snapshots.'}
        return
    }

    # Current Thorough Check sources already render the approved plain report.
    # Validate it before returning; the legacy formatter below assumes summary
    # cards and five differently ordered cells, and must not rewrite this layout.
    if ($html -match '(?is)<h1\b[^>]*>\s*(?:THOROUGH CHECK (?:(?:AUDIT|REMEDIATION) )?REPORT|DEVICE CONFIGURATION VERIFICATION REPORT)\s*</h1>') {
        $requiredStructure = @(
            '(?is)<!DOCTYPE html>.*<html\b',
            '(?is)<main\s+class=["'']report["'']>',
            '(?is)(?:<table\s+class=["'']metadata["''][^>]*>.*?</table>|<dl\s+class=["'']client-details["''][^>]*>.*?</dl>)',
            '(?is)(?:<dt>Restaurant ID</dt>\s*<dd>[^<]+</dd>|<th>Restaurant ID</th>\s*<td>[^<]+</td>|<th>Report ID</th>\s*<td>(?:OMK-\d{6}|\d{8})</td>)',
            '(?is)(?:<th>Branch</th>\s*<td>.*?</td>|<dt>Branch</dt>\s*<dd>.*?</dd>)',
            '(?is)<h2>(?:CONFIGURATION CHECK(?: RESULTS)?|CONFIGURATION VERIFICATION)</h2>',
            '(?is)<footer\s+class=["'']report-footer["'']>.*?</footer>',
            '(?is)</main>\s*</body>\s*</html>\s*$'
        )
        foreach ($pattern in $requiredStructure) {
            if ($html -notmatch $pattern) { throw 'The configuration verification report failed structural verification; the original report was preserved.' }
        }
        return
    }
    if ($html -match 'data-device-management-format=["'']2["'']') { return }

    $deviceAccountNames = switch ($DeviceType) {
        'KIOSK' { @('SELISE', 'SELISE-KIOSK') }
        'POS'   { @('SELISE', 'SELISE-POS') }
        'KDS'   { @('SELISE', 'SELISE-KDS') }
    }
    $rowMatches = @([regex]::Matches($html, '(?is)<tr\b[^>]*>.*?</tr>'))
    $localAccountRows = @($rowMatches | Where-Object {
        $rowTitle = Get-HtmlReportRowTitle -RowHtml $_.Value
        $rowTitle -like 'Local Account:*' -or $rowTitle -eq 'SELISE Local Accounts'
    })

    if ($localAccountRows.Count -gt 0) {
        $candidateRows = @($localAccountRows | Where-Object {
            $rowTitle = Get-HtmlReportRowTitle -RowHtml $_.Value
            if ($rowTitle -eq 'SELISE Local Accounts') {
                $true
            } else {
                $accountName = ($rowTitle -replace '^Local Account:\s*', '').Trim()
                $deviceAccountNames -contains $accountName
            }
        })
        $deviceRow = New-ConsolidatedAccountReportRow -Title "$DeviceType Account" `
            -Subtitle ('Accepted names: {0}' -f ($deviceAccountNames -join ' or ')) `
            -ExpectedNames $deviceAccountNames -NotFoundLabel "$DeviceType Account" -SourceRows $candidateRows
        $html = $html.Replace($localAccountRows[0].Value, $deviceRow)
        foreach ($row in @($localAccountRows | Select-Object -Skip 1)) { $html = $html.Replace($row.Value, '') }
    }

    $rowMatches = @([regex]::Matches($html, '(?is)<tr\b[^>]*>.*?</tr>'))
    $administrativeRows = @($rowMatches | Where-Object {
        (Get-HtmlReportRowTitle -RowHtml $_.Value) -like 'Administrative Account*'
    })
    if ($administrativeRows.Count -gt 0) {
        $adminNames = @($administrativeRows | ForEach-Object {
            $rowTitle = Get-HtmlReportRowTitle -RowHtml $_.Value
            if ($rowTitle -match ':\s*(.+)$') { $Matches[1] }
        } | Where-Object { $_ } | Select-Object -Unique)
        if ($adminNames.Count -eq 0) { $adminNames = @('Admin or Administrator') }
        $adminRow = New-ConsolidatedAccountReportRow -Title 'Administrative Accounts' `
            -Subtitle ('{0} account(s) evaluated' -f $administrativeRows.Count) -ExpectedNames $adminNames `
            -NotFoundLabel 'Administrative Account' -SourceRows $administrativeRows -Administrative
        $html = $html.Replace($administrativeRows[0].Value, $adminRow)
        foreach ($row in @($administrativeRows | Select-Object -Skip 1)) { $html = $html.Replace($row.Value, '') }
    }

    $style = Get-ProfessionalReportStyle
    $html = [regex]::Replace($html, '(?is)<style>.*?</style>', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $style }, 1)
    $reportTitle = '{0} {1} Thorough Check Report' -f $ClientType, $DeviceType
    $headerMatch = [regex]::Match($html, '(?is)<div\s+class=["'']header["'']>\s*<h1>.*?</h1>\s*<div\s+class=["'']meta["'']>(?<Meta>.*?)</div>\s*</div>')
    if ($headerMatch.Success) {
        $newHeader = @"
<header class="report-header">
    <div class="brand-lockup">
        <div class="brand-mark">S</div>
        <div>
            <div class="eyebrow">SELISE &bull; DEVICE OPERATIONS</div>
            <h1>$reportTitle</h1>
            <p class="header-subtitle">System health, configuration compliance, and remediation results</p>
        </div>
    </div>
    <div class="meta">$($headerMatch.Groups['Meta'].Value.Trim())</div>
</header>
"@
        $html = $html.Substring(0, $headerMatch.Index) + $newHeader + $html.Substring($headerMatch.Index + $headerMatch.Length)
    }
    $html = $html -replace '(?is)<title>.*?</title>', ('<title>SELISE {0}</title>' -f $reportTitle)
    $html = $html -replace '(?i)<body>', '<body data-device-management-format="2">'
    $html = $html -replace '(?i)(<div\s+class=["'']summary-grid["'']>)', '<main class="report-content">$1'
    $html = $html -replace '(?i)</body>', '</main><footer class="report-footer">Generated by SELISE Device Management</footer></body>'
    $html = Update-HtmlReportSummary -Html $html

    if ($html -notmatch 'data-device-management-format="2"' -or $html -notmatch '<main class="report-content">' -or $html -notmatch '</html>') {
        throw 'The formatted report failed structural verification.'
    }

    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $directory ('.{0}.{1}.bak' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $html, [Text.UTF8Encoding]::new($false))
        $written = [IO.File]::ReadAllText($temporaryPath)
        if ($written -notmatch 'data-device-management-format="2"' -or $written.Length -lt 1000) {
            throw 'The temporary formatted report failed readback verification.'
        }
        [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        $verified = [IO.File]::ReadAllText($Path)
        if ($verified -notmatch 'data-device-management-format="2"') {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) { [IO.File]::Copy($backupPath, $Path, $true) }
            throw 'The final formatted report failed readback verification; the original report was restored.'
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Update-ThoroughCheckOperationResult {
    param (
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$DeviceType,
        [Parameter(Mandatory = $true)][string]$ClientType
    )

    $pathMatch = [regex]::Match([string]$Result.Message, '(?i)Report:\s*(?<Path>.+?\.html)\s*$')
    if (-not $pathMatch.Success) { return $Result }
    $reportPath = $pathMatch.Groups['Path'].Value.Trim()
    try {
        Update-ThoroughCheckHtmlReport -Path $reportPath -DeviceType $DeviceType -ClientType $ClientType
        $Result.Message = [string]$Result.Message + ' Professional report format applied.'
    } catch {
        Write-Warning ("The Thorough Check completed, but report formatting failed: {0}" -f $_.Exception.Message)
        $Result.Message = [string]$Result.Message + ' Report formatting was not applied; the original report was preserved.'
    }
    return $Result
}

while (-not $exitRequested) {
    switch ($screen) {
        'Client' {
            Show-DeviceManagementHeader 'Main Menu'
            $mainItems=@($clientsConfiguration.Clients)+@([pscustomobject]@{Id='OtherTools';DisplayName='Other Tools';ImplementationState='Ready'})
            $selection = Read-NumberedSelection -Items $mainItems -AllowExit -Prompt 'Select option'
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            if ($selection.Id -eq 'OtherTools') { $screen='OtherTools'; break }
            $selectedClient = $selection
            $selectedDevice = $null
            $selectedOperation = $null
            $selectedPackage = $null
            $clientLocation = $null
            $agentName = $null
            $screen = 'Device'
        }
        'OtherTools' {
            Show-DeviceManagementHeader -Title 'Other Tools'
            $tools=@(
                [pscustomobject]@{Id='PaymentCronJob';DisplayName='Payment Cron Job';ImplementationState='Ready'}
                [pscustomobject]@{Id='KioskLauncherTask';DisplayName='Kiosk Launcher Task Scheduler';ImplementationState='Ready'}
                [pscustomobject]@{Id='ZabbixInstaller';DisplayName='Zabbix Installer';ImplementationState='Ready'}
                [pscustomobject]@{Id='NmapInstaller';DisplayName='Nmap Installer';ImplementationState='Ready'}
            )
            $selection=Read-NumberedSelection -Items $tools -AllowBack -AllowExit -Prompt 'Select option'
            if($selection -eq '__BACK__'){$screen='Client';break}
            if($selection -eq '__EXIT__'){$exitRequested=$true;break}
            Show-DeviceManagementHeader -Title $selection.DisplayName -Breadcrumb ('Other Tools > '+$selection.DisplayName)
            try{
                $toolResult=Invoke-DeviceManagementOtherTool -RootPath $architectureRoot -ToolId $selection.Id
                if(-not $toolResult.ReturnToMenu){[void](Read-Host '  Press Enter to return to Other Tools')}
            }catch{
                Write-Host ('  Failed: '+$_.Exception.Message) -ForegroundColor Red
                [void](Read-Host '  Press Enter to return to Other Tools')
            }
        }
        'Device' {
            Show-DeviceManagementHeader -Title 'Select Device' -Breadcrumb $selectedClient.DisplayName
            $devices = @($selectedClient.Devices | ForEach-Object { [pscustomobject]@{ Id = $_; DisplayName = $_; Description = '' } })
            $selection = Read-NumberedSelection -Items $devices -AllowBack -AllowExit -Prompt 'Select option'
            if ($selection -eq '__BACK__') { $screen = 'Client'; break }
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            $selectedDevice = $selection.Id
            $selectedOperation = $null
            $selectedPackage = $null
            $screen = 'Operation'
        }
        'Operation' {
            Show-DeviceManagementHeader -Title 'Select Operation' -Breadcrumb ("{0} > {1}" -f $selectedClient.DisplayName, $selectedDevice)
            $availableOperations = @(Get-DeviceOperations $operationsConfiguration $selectedDevice $selectedClient.Id)
            $selection = Read-NumberedSelection -Items $availableOperations -AllowBack -AllowExit -Prompt 'Select option'
            if ($selection -eq '__BACK__') { $screen = 'Device'; break }
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            $selectedOperation = $selection
            $selectedPackage = $null
            if ($selectedOperation.Id -eq 'KioskInstallation') {
                if (Test-OperationSelectionReady $selectedOperation $selectedClient.Id $selectedDevice 'Apply') {
                    $screen = 'Browser'
                    break
                }
                $selectedMode = 'Apply'
                $validated = Assert-RunSelection -ClientsConfiguration $clientsConfiguration -OperationsConfiguration $operationsConfiguration `
                    -ClientId $selectedClient.Id -Device $selectedDevice -OperationId $selectedOperation.Id -Mode $selectedMode
                $context = New-DeviceManagementContext -ClientType $validated.Client.Id -DeviceType $selectedDevice `
                    -Operation $validated.Operation.Id -Mode $selectedMode -RootPath $architectureRoot
                $lastResult = Invoke-ConfiguredOperation -RootPath $architectureRoot -Operation $validated.Operation -Context $context
                $screen = 'Result'
            }
            else {
                $screen = if ($selectedOperation.Id -eq 'PaymentService') { 'Package' } else { 'Mode' }
            }
        }
        'Browser' {
            Show-DeviceManagementHeader -Title 'Select Kiosk Browser' -Breadcrumb ("{0} > {1} > KIOSK Installation" -f $selectedClient.DisplayName, $selectedDevice)
            $browsers = @(
                [pscustomobject]@{ Id = 'Edge'; DisplayName = 'Microsoft Edge'; Description = '' }
            )
            $selection = Read-NumberedSelection -Items $browsers -AllowBack -AllowExit -Prompt 'Select option'
            if ($selection -eq '__BACK__') { $screen = 'Operation'; break }
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            $selectedMode = 'Apply'
            $validated = Assert-RunSelection -ClientsConfiguration $clientsConfiguration -OperationsConfiguration $operationsConfiguration `
                -ClientId $selectedClient.Id -Device $selectedDevice -OperationId $selectedOperation.Id -Mode $selectedMode
            $context = New-DeviceManagementContext -ClientType $validated.Client.Id -DeviceType $selectedDevice `
                -Operation $validated.Operation.Id -Mode $selectedMode -Browser $selection.Id -RootPath $architectureRoot
            $lastResult = Invoke-ConfiguredOperation -RootPath $architectureRoot -Operation $validated.Operation -Context $context
            $screen = 'Result'
        }
        'Package' {
            Show-DeviceManagementHeader -Title 'Select Payment Package' -Breadcrumb ("{0} > {1} > Payment Service" -f $selectedClient.DisplayName, $selectedDevice)
            $paymentMenuItems = @(Get-PaymentMenuItems $paymentPackagesConfiguration $selectedClient $selectedDevice $selectedOperation)
            $selection = Read-NumberedSelection -Items $paymentMenuItems -AllowBack -AllowExit -Prompt 'Select option'
            if ($selection -eq '__BACK__') { $screen = 'Operation'; break }
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            $paymentRun = Invoke-PaymentMenuChoice $selection $selectedClient $selectedDevice $selectedOperation `
                $clientsConfiguration $operationsConfiguration $architectureRoot $clientLocation
            $selectedPackage = $paymentRun.Package
            $selectedMode = $paymentRun.Mode
            $lastResult = $paymentRun.Result
            $screen = 'Result'
        }
        'Mode' {
            Show-DeviceManagementHeader -Title 'Select Mode' -Breadcrumb ("{0} > {1} > {2}" -f $selectedClient.DisplayName, $selectedDevice, $selectedOperation.DisplayName)
            $availableModes = @(Get-OperationModes $operationsConfiguration $selectedOperation $selectedClient.Id $selectedDevice)
            $selection = Read-NumberedSelection -Items $availableModes -AllowBack -AllowExit -Prompt 'Select option'
            if ($selection -eq '__BACK__') {
                $screen = 'Operation'
                break
            }
            if ($selection -eq '__EXIT__') { $exitRequested = $true; break }
            $selectedMode = $selection.Id
            if ($selectedOperation.Id -eq 'ThoroughCheck' -and $selectedMode -eq 'Audit' -and [string]::IsNullOrWhiteSpace($agentName)) {
                do { $agentName = ([string](Read-Host '  Agent Name')).Trim() } while ([string]::IsNullOrWhiteSpace($agentName))
            }
            if ((($selectedOperation.Id -eq 'ThoroughCheck' -and $selectedMode -eq 'Audit') -or ($selectedOperation.Id -notin @('ThoroughCheck','PaymentService') -and $selectedMode -eq 'Apply')) -and [string]::IsNullOrWhiteSpace($clientLocation)) {
                $clientLocationPrompt = '  Branch Name'
                do { $clientLocation = Read-Host $clientLocationPrompt } while ([string]::IsNullOrWhiteSpace($clientLocation))
            }
            $validated = Assert-RunSelection -ClientsConfiguration $clientsConfiguration -OperationsConfiguration $operationsConfiguration `
                -ClientId $selectedClient.Id -Device $selectedDevice -OperationId $selectedOperation.Id -Mode $selectedMode
            $context = New-DeviceManagementContext -ClientType $validated.Client.Id -DeviceType $selectedDevice `
                -Operation $validated.Operation.Id -Mode $selectedMode -ClientLocation $clientLocation -AgentName $agentName -RootPath $architectureRoot `
                -SelectedPackage $selectedPackage
            $lastResult = Invoke-ConfiguredOperation -RootPath $architectureRoot -Operation $validated.Operation -Context $context
            if ($selectedOperation.Id -eq 'ThoroughCheck') {
                $lastResult = Update-ThoroughCheckOperationResult -Result $lastResult -DeviceType $selectedDevice -ClientType $selectedClient.DisplayName
            }
            $screen = 'Result'
        }
        'Result' {
            $preserveOperationOutput = ($selectedOperation.Id -eq 'ThoroughCheck' -and $lastResult.Message -match 'KIOSK Thorough Check completed') -or
                ($selectedMode -eq 'Audit' -and $selectedOperation.Id -eq 'PaymentService') -or
                $selectedOperation.Id -eq 'KioskInstallation'
            if (-not $preserveOperationOutput) {
                Show-DeviceManagementHeader -Title 'Operation Result' -Breadcrumb ("{0} > {1} > {2}" -f $selectedClient.DisplayName, $selectedDevice, $selectedOperation.DisplayName)
            }
            if (-not $preserveOperationOutput -or $selectedOperation.Id -eq 'KioskInstallation') {
                $color = if ($lastResult.Status -eq 'Fail') { 'Red' } elseif ($lastResult.Status -eq 'Unavailable') { 'Yellow' } else { 'Green' }
                Write-Host ("  Status  : {0}" -f $lastResult.Status) -ForegroundColor $color
                Write-Host ("  Details : {0}" -f $lastResult.Message) -ForegroundColor $color
            }
            $canApplyFromResult = $selectedOperation.Id -eq 'ThoroughCheck' -and $selectedMode -eq 'Audit' -and
                $lastResult.Message -match 'KIOSK Thorough Check completed' -and
                (Test-OperationSelectionReady -Operation $selectedOperation -ClientId $selectedClient.Id -Device $selectedDevice -Mode 'Apply')
            Show-DeviceManagementNavigation -AllowApplyFix:$canApplyFromResult -AllowMainMenu -AllowBack -AllowExit
            $resultChoices = if ($canApplyFromResult) { @('2', '3', '8', '0') } else { @('3', '8', '0') }
            do {
                $choice = ([string](Read-Host '  Select option')).Trim()
                if ($choice -notin $resultChoices) {
                    $hint = if ($canApplyFromResult) { 'Enter 2, 3, 8 or 0.' } else { 'Enter 3, 8 or 0.' }
                    Write-Host ('  Invalid selection. ' + $hint) -ForegroundColor Yellow
                }
            } while ($choice -notin $resultChoices)
            if ($choice -eq '2' -and $canApplyFromResult) {
                $selectedMode = 'Apply'
                $validated = Assert-RunSelection -ClientsConfiguration $clientsConfiguration -OperationsConfiguration $operationsConfiguration `
                    -ClientId $selectedClient.Id -Device $selectedDevice -OperationId $selectedOperation.Id -Mode $selectedMode
                $context = New-DeviceManagementContext -ClientType $validated.Client.Id -DeviceType $selectedDevice `
                    -Operation $validated.Operation.Id -Mode $selectedMode -ClientLocation $clientLocation -AgentName $agentName -RootPath $architectureRoot `
                    -SelectedPackage $selectedPackage
                $lastResult = Invoke-ConfiguredOperation -RootPath $architectureRoot -Operation $validated.Operation -Context $context
                $lastResult = Update-ThoroughCheckOperationResult -Result $lastResult -DeviceType $selectedDevice -ClientType $selectedClient.DisplayName
                $screen = 'Result'
            }
            elseif ($choice -eq '3') { $screen = 'Client' }
            elseif ($choice -eq '8') {
                if ($selectedOperation.Id -eq 'PaymentService') { $screen = 'Package' }
                elseif ($selectedOperation.Id -eq 'KioskInstallation') { $screen = 'Browser' }
                else { $screen = 'Mode' }
            }
            else { $exitRequested = $true }
        }
    }
}

exit 0
