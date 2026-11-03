$projectRoot = Split-Path $PSScriptRoot -Parent
# Load definitions and a mocked launcher-result block only; never run device checks.
$ErrorActionPreference='Stop'
$root=Split-Path $projectRoot -Parent
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $sourceName),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    foreach ($index in 1..12) { if ((New-ThoroughReportId) -cnotmatch '^OMK-[0-9]{6}$') { throw 'Report ID does not match OMK-000000' } }
    $cases=@(
        @{ Launcher='Kiosk-1'; Requested='Kiosk-2'; Expected='KIOSK-01' },
        @{ Launcher='kiosk-01'; Requested=''; Expected='KIOSK-01' },
        @{ Launcher='KIOSK105'; Requested=''; Expected='KIOSK-105' },
        @{ Launcher='7'; Requested=''; Expected='KIOSK-07' },
        @{ Launcher='Not detected'; Requested='Kiosk-3'; Expected='KIOSK-03' },
        @{ Launcher=''; Requested=''; Expected='KIOSK (number not verified)' },
        @{ Launcher='Front Desk'; Requested=''; Expected='KIOSK - Front Desk' }
    )
    foreach ($case in $cases) {
        $actual=Get-ThoroughReportDeviceLabel -DeviceType KIOSK -LauncherKioskId $case.Launcher -RequestedKioskId $case.Requested
        if ($actual -cne $case.Expected) { throw "Unexpected device label: $actual" }
    }
    # A known kiosk ID must not be lost just because the launcher hostname is missing.
    $launcherTry=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text -match "Start-AuditStep 4 'Kiosk profile and launcher'"},$true) | Sort-Object { $_.Body.Extent.Text.Length } | Select-Object -First 1
    function Start-AuditStep { param($Number,$Name) }
    function Invoke-KioskLauncherConfiguration {
        param($UserName,$Restaurant,$Kiosk,$Hostname)
        [pscustomobject]@{ Status='Pass'; Action='Fixture'; State='Fixture'; LauncherValues=@{ 'KIOSK ID'='Kiosk-2'; 'Restaurant ID'='R-123'; 'Host Name'='Not detected' } }
    }
    function Add-ResultEntry { param($Section,$Title,$Item,$Result) $auditRows.Add([pscustomobject]@{}) }
    $auditRows=[Collections.Generic.List[psobject]]::new()
    $reportRestaurantId='Not detected'
    $reportKioskId=$null
    $reportHostname='Not verified'
    $statements=($launcherTry.Body.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
    . ([scriptblock]::Create($statements))
    if ($reportKioskId -cne 'Kiosk-2' -or $reportHostname -cne 'Not verified') { throw 'Independent kiosk ID capture failed' }
    if($reportRestaurantId -cne 'R-123'){throw 'Restaurant ID was not captured from launcher values.'}
    foreach($mode in @('Audit','Fix','Final')){
        foreach($restaurant in @('R-123','R & <123>','')){
            $snapshot=New-ThoroughReportSnapshot -Rows @() -DisplayMode $mode -LauncherRestaurantId $restaurant -DeviceType KIOSK -Hostname 'WINDOWS-HOST'
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            $expected=if($restaurant){$restaurant}else{'Not detected'}
            if(-not $html.Contains(('<th>Restaurant ID</th><td>'+[Net.WebUtility]::HtmlEncode($expected)+'</td>')) -or $html.Contains('<th>Report ID</th>')){throw 'Restaurant metadata is missing, unsafe or still displays Report ID.'}
            if(-not $html.Contains('<th>Hostname</th><td>WINDOWS-HOST</td>')){throw 'Header hostname changed.'}
            $state=[pscustomobject]@{Version=1;ClientType=$(if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'});ComputerName='FIXTURE-PC';BundleId='OMK-123456';Reports=[pscustomobject]@{Audit=$null;Fix=$null;Final=$null};LatestMode=$mode}
            $state.Reports.$mode=$snapshot
            $bundle=New-ThoroughReportBundleHtml $state
            $read=Read-ThoroughReportBundleState $bundle
            if($read.Reports.$mode.RestaurantId -cne $expected){throw 'Restaurant ID did not round-trip.'}
            # Old reports keep their original Report ID cell and no RestaurantId property.
            $oldTable='<table class="metadata"><tr><th>Report ID</th><td>'+$snapshot.ReportId+'</td><th>Branch</th><td>Legacy branch</td></tr></table>'
            $oldHtml=[regex]::Replace($html,'(?is)<table class="metadata"[^>]*>.*?</table>',$oldTable)
            $oldSnapshot=[pscustomobject]@{Mode=$mode;ReportId=$snapshot.ReportId;GeneratedAt=$snapshot.GeneratedAt;HtmlBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($oldHtml))}
            $state.Reports.$mode=$oldSnapshot
            $null=Read-ThoroughReportBundleState (New-ThoroughReportBundleHtml $state)
            $legacyRestaurantHtml=$oldHtml.Replace(('<th>Report ID</th><td>'+$snapshot.ReportId+'</td>'),('<th>Restaurant ID</th><td>'+[Net.WebUtility]::HtmlEncode($expected)+'</td>'))
            $legacyRestaurant=[pscustomobject]@{Mode=$mode;ReportId=$snapshot.ReportId;RestaurantId=$expected;GeneratedAt=$snapshot.GeneratedAt;HtmlBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($legacyRestaurantHtml))}
            $state.Reports.$mode=$legacyRestaurant
            $null=Read-ThoroughReportBundleState (New-ThoroughReportBundleHtml $state)
            $state.Reports.$mode=$snapshot
            $snapshot.RestaurantId='TAMPERED'
            try { $null=Read-ThoroughReportBundleState (New-ThoroughReportBundleHtml $state);throw 'Tampered metadata accepted' }
            catch {if($_.Exception.Message -eq 'Tampered metadata accepted'){throw}}
        }
    }
    Write-Host "PASS: $sourceName OMK-prefixed six-digit report IDs, configured device numbers and unverified-number fallback"
}
