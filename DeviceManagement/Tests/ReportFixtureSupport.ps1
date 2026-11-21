# Definitions and synthetic observations only. No device checks are executed.
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
foreach($part in Get-ChildItem (Join-Path $script:KioskTestProjectRoot 'Core\Kiosk') -Filter '*.ps1' -File){. $part.FullName}
function New-ReportFixtureRows {
    param([switch]$MissingAccount)
    $kiosk=[pscustomobject]@{SectionNumber=1;SectionTitle='Accounts';ItemTitle='KIOSK Account';ItemSub='Verified configuration';Status='Fail';ActionTaken='Manual action required';Shortcut=(New-AccountReportCommand @('SELISE-KIOSK'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='SELISE-KIOSK';'Account Privilege'='Standard';'Account Status'='Active';'Password Never Expires'='Disabled';'User Cannot Change Password'='Enabled'}))}
    if($MissingAccount){$kiosk.Shortcut=New-AccountReportCommand @();$kiosk.FoundStateHtml='Account Missing. Please create manually.'}
    $admin=[pscustomobject]@{SectionNumber=1;SectionTitle='Accounts';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Status='Fail';ActionTaken='Manual action required';Shortcut=(New-AccountReportCommand @('Administrator'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'='Administrator';'Account Privilege'='Administrator';'Account Status'='Active';'Password Never Expires'='Disabled'}))}
    $config=[pscustomobject]@{SectionNumber=2;SectionTitle='Services';ItemTitle='Fixture configuration';ItemSub='Read-only configuration';Status='Fail';ActionTaken='Read only; manual review required';Shortcut=(New-ReportCommand @('notepad.exe "C:\Sample & Support\appsettings.json"'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{Provider='NETS';Endpoint='https://example.test/orders?a=1&b=2'}))}
    @($kiosk,$admin,$config)
}
function New-KioskReportFixtures {
    $root=$script:KioskTestProjectRoot
    $layout=Join-Path $root 'output\report-layout';$combined=Join-Path $root 'output\single-file-reports'
    [void][IO.Directory]::CreateDirectory($layout);[void][IO.Directory]::CreateDirectory($combined)
    $utf8=[Text.UTF8Encoding]::new($false)
    foreach($client in @('SaaS','Subway')){
        Set-KioskTestClient $client
        $snapshots=[ordered]@{}
        foreach($mode in @('Audit','Fix','Final')){
            $identity=[pscustomobject]@{ReportId='OMK-123456';GeneratedAt='14 Nov 2026, 10:00 AM BST'}
            $snapshot=New-ThoroughReportSnapshot -Rows (New-ReportFixtureRows) -DisplayMode $mode -AuditSource $identity -AfterApply:($mode -eq 'Fix') -ClientLocation 'Fixture & <Branch>' -AgentName 'Fixture Agent' -DeviceType KIOSK -Hostname 'DEVICE-01' -LauncherRestaurantId R1 -LauncherKioskId K1 -KioskUserName 'SELISE-KIOSK'
            $snapshots[$mode]=$snapshot
            $filename=$client+'-'+$(if($mode -eq 'Fix'){'Apply-Fix'}else{$mode})+'-preview.html'
            [IO.File]::WriteAllText((Join-Path $layout $filename),$utf8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64)),$utf8)
            $missing=New-ThoroughReportSnapshot -Rows (New-ReportFixtureRows -MissingAccount) -DisplayMode $mode -AuditSource $identity -AfterApply:($mode -eq 'Fix') -Hostname 'DEVICE-01'
            [IO.File]::WriteAllText((Join-Path $layout $filename.Replace('-preview.html','-missing-account-preview.html')),$utf8.GetString([Convert]::FromBase64String($missing.HtmlBase64)),$utf8)
        }
        $state=[pscustomobject]@{Version=1;ClientType=$client;ComputerName='FIXTURE-PC';BundleId='OMK-123456';CreatedAt='2026-11-14';UpdatedAt='2026-11-14';LatestMode='Audit';Reports=[pscustomobject]$snapshots}
        [IO.File]::WriteAllText((Join-Path $combined ($client+'-Combined.html')),(New-ThoroughReportBundleHtml $state),$utf8)
        $state.Reports.Audit=$null
        [IO.File]::WriteAllText((Join-Path $combined ($client+'-Missing-Audit.html')),(New-ThoroughReportBundleHtml $state),$utf8)
    }
}
