$projectRoot = Split-Path $PSScriptRoot -Parent
# Load definitions and the report finalizer only. No production checks execute.
$ErrorActionPreference='Stop'
$VerbosePreference='SilentlyContinue'
$parent=Split-Path $projectRoot -Parent
$previewFolder=Join-Path $projectRoot 'output\console-progress'
New-Item -ItemType Directory -Path $previewFolder -Force | Out-Null
function Assert-ConsoleProgress { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
foreach ($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $parent $name),[ref]$tokens,[ref]$errors)
    Assert-ConsoleProgress ($errors.Count -eq 0) 'Source parse failed'
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    $outerTry=$ast.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($outerTry.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n")
    $client=if ($name -like 'Subway*') { 'Subway' } else { 'SaaS' }
    $script:consoleLines=[Collections.Generic.List[string]]::new()
    function Write-Host { [CmdletBinding()]param([object]$Object,[ConsoleColor]$ForegroundColor) $script:consoleLines.Add([string]$Object) }
    function Write-Progress { throw 'Floating progress must not be used' }
    function Read-AuditReportChoice {
        Assert-ConsoleProgress (($script:consoleLines -join "`n") -match 'Audit completed') 'Prompt appeared before Audit completion'
        $script:consoleLines.Add(' Generate HTML report? [Y/N]: N')
        return $false
    }
    foreach ($isApply in @($false,$true)) {
        $script:ApplyChanges=$isApply
        $mode=if ($isApply) { 'Apply' } else { 'Audit' }
        $script:consoleLines.Clear()
        $auditRows=[Collections.Generic.List[psobject]]::new()
        Write-ThoroughConsoleHeader -Client $client -Device KIOSK -Branch 'Sample Branch' -IsApply $isApply
        $diagnostics=@(& { Start-AuditStep 1 'Printers'; Write-AuditOperation "Reading service 'fixture'..." } 4>&1)
        Assert-ConsoleProgress ($diagnostics.Count -eq 0) 'Routine diagnostics leaked into the default log'
        Add-AuditEntry 1 Hardware 'Receipt Printer' '' '' 'Idle' Pass 'Settings verified'
        $missing=New-MissingAccountResult -RequestedName 'SELISE or SELISE-KIOSK'
        Add-AuditEntry 2 Kiosk 'KIOSK Account' '' '' $missing.StateHtml Fail $missing.Action
        $longAction='Administrator: Required password properties were not verified; Custom administrator: Access denied; Detailed readback information retained'
        Add-AuditEntry 5 Security 'Administrative Accounts' '' '' 'Fixture state' Fail $longAction
        Add-AuditEntry 3 Services 'Windows Update (wuauserv)' '' '' 'Running' Fail 'Service remains Running; Recovery readback failed'
        $counterStatus=if ($isApply) { 'Pass' } else { 'Bypass' }
        Add-AuditEntry 5 Security 'lodctr /R Performance Counter' '' '' 'Fixture state' $counterStatus 'Health was not verified'
        Add-AuditEntry 3 Services 'Legacy payment service' 'Type: Old Payment Service' '' 'Stopped' Offline 'Expected stopped'
        Add-AuditEntry 3 Services 'Unverified service' '' '' 'Unreadable' '' 'Access denied &lt;fixture&gt;'
        if ($isApply) { Add-AuditEntry 3 Services 'Repaired service' '' '' 'Verified running' Remediated 'Repair verified' }
        Add-AuditEntry 3 Services 'Offline service' '' '' 'Stopped' Offline 'Service unexpectedly stopped'
        $ClientLocation='Sample Branch'; $DeviceType='KIOSK'; $reportKioskId='1'; $KioskId=$null
        $reportHostname='FIXTURE-KIOSK'; $runId='fixture-console'
        $outputFolder=if ($isApply) { $previewFolder } else { Join-Path $previewFolder ($client+'-declined') }
        $reportPath=Join-Path $outputFolder ($client+'-'+$mode+'.html')
        . $render
        $content=$script:consoleLines -join "`n"
        $expectedTitle=if ($isApply) { 'THOROUGH CHECK REPORT' } else { 'THOROUGH CHECK AUDIT REPORT' }
        Assert-ConsoleProgress ($content.Contains('SELISE | '+$expectedTitle) -and $content -match ('Client : '+$client) -and $content -match ('Mode\s+: '+$(if($isApply){'Apply Fix'}else{'Audit'}))) 'Header identity missing'
        Assert-ConsoleProgress ($content -match '\[01\]\s+PASS\s+Receipt Printer') 'Numbered status not aligned'
        Assert-ConsoleProgress ([regex]::Matches($content,'Account Missing\. Please create manually\. Dependent kiosk checks skipped\.').Count -eq 1) 'Missing account explanation missing or duplicated'
        Assert-ConsoleProgress ($content -match '\[06\]\s+STOPPED\s+Legacy payment service') 'Expected stopped state mislabelled'
        Assert-ConsoleProgress ($content -match '\[07\]\s+UNKNOWN\s+Unverified service' -and $content -match 'Access denied <fixture>') 'Unverified state or HTML decoding lost'
        Assert-ConsoleProgress ($content -match 'OFFLINE\s+Offline service') 'Unexpected offline state mislabelled'
        Assert-ConsoleProgress ($content -notmatch 'step elapsed|total elapsed|\[\d{2}:\d{2}:\d{2}\]|Reading service|Required Configuration|Findings|Kiosk audit|<div|&lt;') 'Verbose or detailed report content leaked'
        Assert-ConsoleProgress ($auditRows[2].ActionTaken -ceq $longAction -and $auditRows[5].Status -ceq 'Offline') 'Console presentation altered report data'
        $completion=if ($isApply) { 'Apply Fix completed' } else { 'Audit completed' }
        Assert-ConsoleProgress ([regex]::Matches($content,[regex]::Escape($completion)).Count -eq 1) 'Completion missing or duplicated'
        if ($isApply) {
            Assert-ConsoleProgress ($content -match 'FIXED\s+Repaired service' -and $content -notmatch 'Generate HTML report') 'Apply status or report flow incorrect'
            Assert-ConsoleProgress ($content.IndexOf('Report saved:') -lt $content.IndexOf($completion)) 'Apply completion appeared before report saving'
            Assert-ConsoleProgress ([IO.File]::ReadAllText($reportPath).Contains('<th>Status</th>')) 'Fix status missing from HTML report'
        } else {
            Assert-ConsoleProgress ($content -match 'SKIP\s+Performance Counter' -and $content -match 'health not verified') 'Skipped work reported as verified'
            Assert-ConsoleProgress (-not (Test-Path -LiteralPath $outputFolder)) 'Declining HTML created output'
        }
        [IO.File]::WriteAllText((Join-Path $previewFolder ($client+'-'+$mode+'.txt')),$content,[Text.UTF8Encoding]::new($false))
        Microsoft.PowerShell.Utility\Write-Host "PASS: $client / $mode console output, truthful statuses, unchanged recorded data and completion order"
    }
    $script:consoleLines.Clear()
    $longToken='https://example.test/'+('x'*140)
    Write-ThoroughConsoleLine $longToken -Indent '    ' -Width 42
    Assert-ConsoleProgress (@($script:consoleLines | Where-Object { $_.Length -gt 42 }).Count -eq 0) 'Wrapped line exceeded width'
    Assert-ConsoleProgress (($script:consoleLines | ForEach-Object { $_.TrimStart() }) -join '' -ceq $longToken) 'Wrapping lost token characters'
    # A deferred service row must print once using its refined version/hostname status.
    $script:consoleLines.Clear()
    $auditRows=[Collections.Generic.List[psobject]]::new()
    Add-AuditEntry 3 Services 'Payment Gateway Middleware' 'Type: Payment Gateway Middleware' '' 'Running' Pass 'Settings verified' -DeferConsole
    Assert-ConsoleProgress ($script:consoleLines.Count -eq 0 -and $auditRows.Count -eq 1) 'Deferred row printed before final verification'
    $auditRows[0].Status='Fail'; $auditRows[0].ActionTaken+='; Payment Service details not verified: executable unreadable.'
    Write-ThoroughConsoleEntry -Row $auditRows[0] -Number 1
    Assert-ConsoleProgress (($script:consoleLines -join "`n") -match '\[01\]\s+FAIL\s+Payment Gateway' -and ($script:consoleLines -join "`n") -notmatch 'PASS|Settings verified') 'Refined failure printed as an earlier success'
    Assert-ConsoleProgress ((Get-ThoroughConsoleNote -ItemTitle 'Zabbix Agent 2' -Status Fail -ActionTaken 'Verified; Zabbix monitoring hostname was not verified.') -eq 'Monitoring hostname could not be verified.') 'Hostname failure explanation lost'
}
# Evaluate only the launcher's preservation expression against both modes.
$tokens=$null; $errors=$null
$launcher=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'Start-DeviceManagement.ps1'),[ref]$tokens,[ref]$errors)
Assert-ConsoleProgress ($errors.Count -eq 0) 'Launcher parse failed'
$assignment=$launcher.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$preserveOperationOutput'},$true) | Select-Object -First 1
foreach ($fixture in @(
    @{Mode='Audit';Operation='ThoroughCheck';Message='Subway KIOSK Thorough Check completed with failed checks.';Expected=$true},
    @{Mode='Apply';Operation='ThoroughCheck';Message='SaaS KIOSK Thorough Check completed.';Expected=$true},
    @{Mode='Apply';Operation='ThoroughCheck';Message='SaaS KIOSK Thorough Check could not start or complete.';Expected=$false},
    @{Mode='Audit';Operation='ThoroughCheck';Message='Source file missing';Expected=$false},
    @{Mode='Audit';Operation='PaymentService';Message='Audit finished';Expected=$true},
    @{Mode='Apply';Operation='PaymentService';Message='Install finished';Expected=$false}
)) {
    $selectedMode=$fixture.Mode; $selectedOperation=[pscustomobject]@{Id=$fixture.Operation}; $lastResult=[pscustomobject]@{Message=$fixture.Message}
    . ([scriptblock]::Create($assignment.Extent.Text))
    Assert-ConsoleProgress ($preserveOperationOutput -eq $fixture.Expected) 'Launcher console preservation changed error handling or mode scope'
}
Microsoft.PowerShell.Utility\Write-Host 'PASS: launcher preserves completed Thorough Check logs in both modes and displays startup errors'
