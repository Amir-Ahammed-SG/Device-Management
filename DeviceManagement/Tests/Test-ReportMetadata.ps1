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
        [pscustomobject]@{ Status='Pass'; Action='Fixture'; State='Fixture'; LauncherValues=@{ 'KIOSK ID'='Kiosk-2'; 'Host Name'='Not detected' } }
    }
    function Add-ResultEntry { param($Section,$Title,$Item,$Result) }
    $reportKioskId=$null
    $reportHostname='Not verified'
    $statements=($launcherTry.Body.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
    . ([scriptblock]::Create($statements))
    if ($reportKioskId -cne 'Kiosk-2' -or $reportHostname -cne 'Not verified') { throw 'Independent kiosk ID capture failed' }
    Write-Host "PASS: $sourceName OMK-prefixed six-digit report IDs, configured device numbers and unverified-number fallback"
}
