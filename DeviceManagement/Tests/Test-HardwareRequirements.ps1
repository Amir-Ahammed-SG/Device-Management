
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# Run selected hardware blocks with fake printers and logs. No device changes.
$ErrorActionPreference='Stop'
$parent=$projectRoot
function Assert-Hardware {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
function Reset-HardwareFixture {
    $script:printerNames=@('Receipt'); $script:printerState='Normal'; $script:keepPrinted=$true
    $script:printerReadError=$false; $script:cimReadError=$false; $script:keepNoEffect=$false
    $script:keepWrites=0; $script:queueWrites=0; $script:rows=[Collections.Generic.List[object]]::new()
}
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $sourcePath=Join-Path $parent $sourceName
    $source=[KioskTestSource]::ReadAllText($sourcePath)
    $tokens=$null; $errors=$null
    $ast=[KioskTestSource]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
    Assert-Hardware ($errors.Count -eq 0) 'Source parser errors'
    $definitions=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $start=$source.IndexOf('# 1.1 Multi-Printer Discovery'); $end=$source.IndexOf('# 1.2 PrintService Event Log',$start)
    $printerBlock=[scriptblock]::Create($source.Substring($start,$end-$start))
    $logStart=$end; $logEnd=$source.IndexOf('# GROUP 2:',$logStart)
    $logBlock=[scriptblock]::Create($source.Substring($logStart,$logEnd-$logStart))
    function Start-AuditStep {param($Number,$Name)}
    function Write-AuditOperation {param($Message)}
    function Get-Printer {
        [CmdletBinding()]param($Name)
        if ($script:printerReadError) {throw 'Fixture printer access denied'}
        foreach ($printerName in $script:printerNames) { [pscustomobject]@{Name=$printerName;PrinterStatus=$script:printerState;KeepPrintedJobs=$script:keepPrinted;WorkOffline=$false} }
    }
    function Get-CimInstance {
        [CmdletBinding()]param($ClassName)
        Assert-Hardware ($ClassName -eq 'Win32_Printer') 'Unexpected CIM query'
        if ($script:cimReadError) {throw 'Fixture CIM access denied'}
        foreach ($printerName in $script:printerNames) {[pscustomobject]@{Name=$printerName;PrinterStatus=3;DetectedErrorState=0;WorkOffline=$false;KeepPrintedJobs=$script:keepPrinted}}
    }
    function Set-Printer {
        [CmdletBinding()]param($Name,$KeepPrintedJobs)
        Assert-Hardware ($Name -eq 'Receipt' -and $KeepPrintedJobs -eq $true) 'Unexpected printer setting change'
        $script:keepWrites++
        if (-not $script:keepNoEffect) {$script:keepPrinted=$true}
    }
    function Invoke-CimMethod { [CmdletBinding()]param($InputObject,$MethodName) $script:queueWrites++; throw 'Printer queue mutation is forbidden' }
    function Resume-PrintJob {throw 'Unexpected print-job mutation'}
    function Add-AuditEntry {
        param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken)
        $script:rows.Add([pscustomobject]@{ItemTitle=$ItemTitle;ItemSub=$ItemSub;Findings=$FoundStateHtml;Status=$Status;Action=$ActionTaken})
    }
    foreach ($itemSub in @('Type: Receipt / POS Printer','Type: Receipt / Hardware')) {
        $requirement=Get-ReportRequirement ([pscustomobject]@{ItemTitle='Printers';ItemSub=$itemSub})
        $labels=@([regex]::Matches($requirement,'kv-label">([^<]+):') | ForEach-Object {$_.Groups[1].Value})
        Assert-Hardware (($labels -join '|') -ceq 'Printer Name|Printer status|Keep printed documents') 'Printer requirements contain removed or missing fields'
        Assert-Hardware ($requirement -match 'Printer Name:</span> BIXOLON or EPSON' -and $requirement -match 'Printer status:</span> Active / Idle' -and $requirement -match 'Keep printed documents:</span> Enabled') 'Printer name, status examples or retention requirement incorrect'
        Assert-Hardware ($requirement -notmatch 'Queue|Readable') 'Removed queue requirement remains'
    }
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($state in @('Normal','Printing','Paused','Offline','NotAvailable','Error',1,4096)) {
            Reset-HardwareFixture; $script:printerState=$state
            . $printerBlock
            $row=$script:rows[-1]
            Assert-Hardware (($row.Status -eq 'Pass') -eq ($state -in @('Normal','Printing'))) "Printer status result incorrect: $state"
            Assert-Hardware ($script:queueWrites -eq 0 -and $script:keepWrites -eq 0) 'Printer status inspection changed printer settings'
            Assert-Hardware ($row.Findings -match 'Printer Name:</span> Receipt' -and $row.Findings -notmatch 'Printer detection|Queue paused|Queue settings') 'Printer Findings omit the printer name or include removed fields'
            Assert-Hardware ($row.Findings -match 'Printer status:</span> (Active|Idle|Paused|Offline|Not available|Error)</div>' -and $row.Findings -match 'Keep printed documents:</span> Enabled') 'Printer Findings do not use the requested status and retention labels'
            if ($state -notin @('Normal','Printing')) {
                $expected=switch([string]$state){'Paused'{'Paused'};'1'{'Paused'};'Offline'{'Offline'};'NotAvailable'{'Not available'};'4096'{'Not available'};default{'Error'}}
                Assert-Hardware ($row.Findings.Contains('Printer status:</span> '+$expected+'</div>') -and $row.Status -eq 'Fail') 'An unhealthy printer lost its specific state or was reported healthy'
            }
        }
        foreach ($state in @('Normal','Paused')) {
            Reset-HardwareFixture; $script:printerState=$state; $script:keepPrinted=$false
            . $printerBlock
            Assert-Hardware ($script:keepWrites -eq [int]$mode -and $script:queueWrites -eq 0) 'Retention repair made unapproved changes'
            Assert-Hardware (($script:rows[-1].Status -eq 'Pass') -eq ($mode -and $state -eq 'Normal')) 'Retention or paused state was not reflected in status'
            Assert-Hardware ($script:rows[-1].Findings.Contains(('Keep printed documents:</span> '+$(if ($mode) {'Enabled'} else {'Disabled'})))) 'Retention Findings do not use Enabled/Disabled'
        }
        Reset-HardwareFixture; $script:printerNames=@()
        . $printerBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:rows[-1].Findings -ceq 'Not verified. Please check manually.') 'Missing printer did not use the manual verification message'
        Reset-HardwareFixture; $script:printerNames=@('Microsoft Print to PDF','OneNote')
        . $printerBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:rows[-1].Findings -ceq 'Not verified. Please check manually.') 'Excluded virtual queues were counted as detected printers'
        Reset-HardwareFixture; $script:printerReadError=$true
        . $printerBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:rows[-1].Findings -ceq 'Not verified. Please check manually.') 'Unreadable discovery did not request manual verification'
        Reset-HardwareFixture; $script:cimReadError=$true
        . $printerBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:rows[-1].Findings -ceq 'Not verified. Please check manually.') 'CIM failure claimed verified printer information'
        Reset-HardwareFixture; $script:printerNames=@('<Receipt> & "Desk"','Receipt 2')
        . $printerBlock
        Assert-Hardware ($script:rows.Count -eq 2 -and $script:rows[0].Findings -match 'Printer Name:</span> &lt;Receipt&gt; &amp; &quot;Desk&quot;' -and $script:rows[1].Findings -match 'Printer Name:</span> Receipt 2') 'Printer names were not recorded individually or HTML encoded'
        Reset-HardwareFixture; $script:keepPrinted=$null
        . $printerBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:rows[-1].Findings -match 'Printer Name:</span> Receipt' -and $script:rows[-1].Findings -match 'Keep printed documents:</span> Not verified\. Please check manually\.' -and $script:keepWrites -eq 0) 'Unavailable retention data was invented or silently changed'
    }
    Reset-HardwareFixture; $script:ApplyChanges=$true; $script:keepPrinted=$false; $script:keepNoEffect=$true
    . $printerBlock
    Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:keepWrites -eq 1 -and $script:queueWrites -eq 0) 'Retention repair without readback success was reported as Pass'

    function Get-WinEvent {[CmdletBinding()]param($ListLog,[switch]$Force) [pscustomobject]@{IsEnabled=$script:logEnabled}}
    function wevtutil.exe {
        $script:logWrites++
        Assert-Hardware (($args -join '|') -eq 'sl|Microsoft-Windows-PrintService/Operational|/e:true') 'Unexpected event-log change'
        $global:LASTEXITCODE=$script:logExit
        if ($script:logExit -eq 0 -and -not $script:logNoEffect) {$script:logEnabled=$true}
    }
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($enabled in @($false,$true)) {
            Reset-HardwareFixture; $script:logEnabled=$enabled; $script:logWrites=0; $script:logExit=0; $script:logNoEffect=$false
            . $logBlock
            Assert-Hardware (($script:rows[-1].Status -eq 'Pass') -eq ($enabled -or $mode)) 'PrintService log status incorrect'
            Assert-Hardware ($script:logWrites -eq $(if ($mode -and -not $enabled) {1} else {0})) 'PrintService log was rewritten or changed during Audit'
        }
    }
    foreach ($failure in @('exit','readback')) {
        Reset-HardwareFixture; $script:ApplyChanges=$true; $script:logEnabled=$false; $script:logWrites=0; $script:logExit=$(if ($failure -eq 'exit') {5} else {0}); $script:logNoEffect=$true
        . $logBlock
        Assert-Hardware ($script:rows[-1].Status -eq 'Fail' -and $script:logWrites -eq 1) 'Failed event-log repair was reported as Pass'
    }
    Write-Output "PASS: $sourceName Hardware fields, detection/status, retention-only Apply, no queue resume, Audit safety and PrintService log readback"
}
